package dev.tuantu.tuantu_app.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.system.OsConstants
import io.flutter.plugin.common.EventChannel
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.InetAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 影石同款「代理模式」：本地 VPN 分流。
 * 公网 → 队友自己的蜂窝；192.168/10/172.16 → 热点 Wi-Fi（盒子）。
 * 流量不出本机，不是翻墙。
 *
 * 关键：必须 requestNetwork 把 4G 拉住。连上无网热点后，ColorOS 会把蜂窝挂起，
 * 只靠 allNetworks 扫到的接口绑不上，微信就上不了网。
 */
class ProxyVpnService : VpnService() {

    private var tun: ParcelFileDescriptor? = null
    private var tcp: TcpForwarder? = null
    private var udp: UdpForwarder? = null
    @Volatile private var looping = false
    private val tunLock = Any()
    private var cellCb: ConnectivityManager.NetworkCallback? = null
    private var wifiCb: ConnectivityManager.NetworkCallback? = null
    @Volatile private var cellNet: Network? = null
    @Volatile private var wifiNet: Network? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopProxy()
            return START_NOT_STICKY
        }
        if (running) return START_STICKY
        startForegroundNotif()
        Thread({
            if (!establishAndLoop()) {
                Handler(Looper.getMainLooper()).post {
                    try {
                        stopForeground(STOP_FOREGROUND_REMOVE)
                    } catch (_: Exception) {
                    }
                    stopSelf()
                }
            }
        }, "tt-vpn-boot").start()
        return START_STICKY
    }

    private fun startForegroundNotif() {
        val n = buildNotif()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, n)
        }
    }

    private fun acquireNets(): Boolean {
        val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        val latch = CountDownLatch(1)
        val cellReq = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        cellCb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                cellNet = network
                latch.countDown()
            }

            override fun onLost(network: Network) {
                if (cellNet == network) cellNet = null
            }
        }
        try {
            cm.requestNetwork(cellReq, cellCb!!)
        } catch (_: Exception) {
            return false
        }
        val wifiReq = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()
        wifiCb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                wifiNet = network
            }

            override fun onLost(network: Network) {
                if (wifiNet == network) wifiNet = null
            }
        }
        try {
            cm.requestNetwork(wifiReq, wifiCb!!)
        } catch (_: Exception) {
        }
        try {
            latch.await(8, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
        }
        if (cellNet == null) cellNet = findTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
        if (wifiNet == null) wifiNet = findTransport(NetworkCapabilities.TRANSPORT_WIFI)
        return cellNet != null
    }

    private fun releaseNets() {
        val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        try {
            cellCb?.let { cm.unregisterNetworkCallback(it) }
        } catch (_: Exception) {
        }
        try {
            wifiCb?.let { cm.unregisterNetworkCallback(it) }
        } catch (_: Exception) {
        }
        cellCb = null
        wifiCb = null
        cellNet = null
        wifiNet = null
    }

    private fun establishAndLoop(): Boolean {
        if (!acquireNets()) {
            emit(false)
            releaseNets()
            return false
        }
        val cellular = cellNet ?: run {
            emit(false)
            releaseNets()
            return false
        }
        val builder = Builder()
            .setSession("团图代理")
            .setMtu(1280)
            .addAddress("198.18.0.2", 32)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("223.5.5.5")
            .addDnsServer("8.8.8.8")
            .setBlocking(true)
        builder.allowFamily(OsConstants.AF_INET)
        builder.setUnderlyingNetworks(arrayOf(cellular))
        if (Build.VERSION.SDK_INT >= 29) builder.setMetered(false)
        try {
            builder.addDisallowedApplication(packageName)
        } catch (_: Exception) {
        }
        if (Build.VERSION.SDK_INT >= 33) {
            builder.excludeRoute(IpPrefix(InetAddress.getByName("10.0.0.0"), 8))
            builder.excludeRoute(IpPrefix(InetAddress.getByName("172.16.0.0"), 12))
            builder.excludeRoute(IpPrefix(InetAddress.getByName("192.168.0.0"), 16))
            builder.excludeRoute(IpPrefix(InetAddress.getByName("169.254.0.0"), 16))
        }
        val pfd = try {
            builder.establish()
        } catch (_: Exception) {
            null
        }
        if (pfd == null) {
            emit(false)
            releaseNets()
            return false
        }
        tun = pfd
        val out = FileOutputStream(pfd.fileDescriptor)
        val writeTun: (ByteArray) -> Unit = { pkt ->
            synchronized(tunLock) {
                try {
                    out.write(pkt)
                } catch (_: Exception) {
                }
            }
        }
        val pick: (InetAddress) -> Network? = { addr ->
            val lan = addr.isSiteLocalAddress || addr.isLinkLocalAddress
            if (lan) wifiNet ?: findTransport(NetworkCapabilities.TRANSPORT_WIFI)
            else cellNet ?: findTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
        }
        tcp = TcpForwarder(this, pick, writeTun)
        udp = UdpForwarder(this, pick, writeTun)
        looping = true
        running = true
        emit(true)
        Thread({ tunLoop(FileInputStream(pfd.fileDescriptor)) }, "tt-tun").apply {
            isDaemon = true
            start()
        }
        return true
    }

    private fun tunLoop(ins: FileInputStream) {
        val buf = ByteArray(32767)
        try {
            while (looping) {
                val n = ins.read(buf)
                if (n <= 0) break
                if (!Packet.isIpv4(buf, n)) continue
                when (Packet.protocol(buf)) {
                    Packet.TCP -> tcp?.handle(buf, n)
                    Packet.UDP -> udp?.handle(buf, n)
                }
            }
        } catch (_: Exception) {
        }
        if (looping) stopProxy()
    }

    private fun stopProxy() {
        looping = false
        running = false
        emit(false)
        try {
            tcp?.shutdown()
        } catch (_: Exception) {
        }
        try {
            udp?.shutdown()
        } catch (_: Exception) {
        }
        tcp = null
        udp = null
        try {
            tun?.close()
        } catch (_: Exception) {
        }
        tun = null
        releaseNets()
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        stopProxy()
        super.onDestroy()
    }

    override fun onRevoke() {
        stopProxy()
        super.onRevoke()
    }

    private fun findTransport(transport: Int): Network? {
        val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        return cm.allNetworks.firstOrNull { n ->
            val c = cm.getNetworkCapabilities(n) ?: return@firstOrNull false
            !c.hasTransport(NetworkCapabilities.TRANSPORT_VPN) && c.hasTransport(transport)
        }
    }

    @Suppress("DEPRECATION")
    private fun buildNotif(): Notification {
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(CH, "团图代理", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "连盒子热点时，让微信等走自己的流量"
                    setShowBadge(false)
                }
            )
            return Notification.Builder(this, CH)
                .setContentTitle("团图代理已开启")
                .setContentText("微信等走 4G，传照片仍走热点")
                .setSmallIcon(android.R.drawable.ic_lock_lock)
                .setOngoing(true)
                .build()
        }
        return Notification.Builder(this)
            .setContentTitle("团图代理已开启")
            .setContentText("微信等走 4G，传照片仍走热点")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .build()
    }

    companion object {
        const val ACTION_START = "dev.tuantu.proxy.START"
        const val ACTION_STOP = "dev.tuantu.proxy.STOP"
        private const val CH = "tuantu_proxy"
        private const val NOTIF_ID = 7

        @Volatile var running = false
        var sink: EventChannel.EventSink? = null

        fun hasCellular(ctx: Context): Boolean {
            val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            return cm.allNetworks.any { n ->
                val c = cm.getNetworkCapabilities(n) ?: return@any false
                !c.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                    c.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
            }
        }

        fun start(ctx: Context) {
            val i = Intent(ctx, ProxyVpnService::class.java).setAction(ACTION_START)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i)
            else ctx.startService(i)
        }

        fun stop(ctx: Context) {
            ctx.startService(Intent(ctx, ProxyVpnService::class.java).setAction(ACTION_STOP))
        }

        fun emit(v: Boolean) {
            Handler(Looper.getMainLooper()).post {
                try {
                    sink?.success(v)
                } catch (_: Exception) {
                }
            }
        }
    }
}
