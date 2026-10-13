package dev.tuantu.tuantu_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 前台服务：本机当团图盒子时，避免系统把进程杀掉。
 */
class BoxHostService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            running = false
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        val n = buildNotif()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, n)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    private fun buildNotif(): Notification {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CH, "团图盒子", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val b = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CH)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return b.setContentTitle("团图盒子开着")
            .setContentText("队友连你的热点就能传照片")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    companion object {
        const val ACTION_STOP = "dev.tuantu.box.STOP"
        private const val CH = "tuantu_box"
        private const val NOTIF_ID = 42
        @Volatile var running = false
        private var multicastLock: WifiManager.MulticastLock? = null

        fun start(ctx: Context) {
            val i = Intent(ctx, BoxHostService::class.java)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i)
            else ctx.startService(i)
            holdMulticast(ctx)
        }

        fun stop(ctx: Context) {
            ctx.startService(
                Intent(ctx, BoxHostService::class.java).setAction(ACTION_STOP)
            )
        }

        fun openWifiSettings(ctx: Context) {
            val i = Intent(Settings.ACTION_WIFI_SETTINGS)
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(i)
        }

        fun holdMulticast(ctx: Context) {
            try {
                if (multicastLock?.isHeld == true) return
                val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                val lock = wm.createMulticastLock("tuantu-mdns")
                lock.setReferenceCounted(false)
                lock.acquire()
                multicastLock = lock
            } catch (_: Exception) {
            }
        }

        fun boxHints(ctx: Context): List<String> {
            val out = mutableListOf<String>()
            out.addAll(lanIps())
            try {
                val cm = ctx.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                for (n in cm.allNetworks) {
                    val lp = cm.getLinkProperties(n) ?: continue
                    for (r in lp.routes) {
                        val gw = r.gateway ?: continue
                        if (gw is Inet4Address) {
                            val ip = gw.hostAddress ?: continue
                            if (ip != "0.0.0.0") out.add(ip)
                        }
                    }
                    if (Build.VERSION.SDK_INT >= 30) {
                        try {
                            val dhcp = lp.dhcpServerAddress?.hostAddress
                            if (!dhcp.isNullOrEmpty() && dhcp.contains('.')) out.add(dhcp)
                        } catch (_: Exception) {
                        }
                    }
                }
            } catch (_: Exception) {
            }
            return out.distinct()
        }

        fun lanIps(): List<String> {
            val out = mutableListOf<String>()
            try {
                val en = NetworkInterface.getNetworkInterfaces() ?: return out
                while (en.hasMoreElements()) {
                    val ni = en.nextElement()
                    val addrs = ni.inetAddresses
                    while (addrs.hasMoreElements()) {
                        val a = addrs.nextElement()
                        if (a is Inet4Address && !a.isLoopbackAddress) {
                            out.add(a.hostAddress ?: continue)
                        }
                    }
                }
            } catch (_: Exception) {
            }
            return out.distinct()
        }

        /** 无外网热点时，安卓会把流量改走 4G。把本进程绑到 Wi-Fi，才能连上盒子。 */
        fun bindWifi(ctx: Context, cb: (Boolean) -> Unit) {
            holdMulticast(ctx)
            val cm = ctx.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            fun use(n: Network): Boolean {
                return try {
                    cm.bindProcessToNetwork(n)
                } catch (_: Exception) {
                    false
                }
            }
            val wifiNets = cm.allNetworks.filter { n ->
                val cap = cm.getNetworkCapabilities(n)
                cap?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true ||
                    cap?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true
            }
            // Preserve the user-approved specifier network on dual-Wi-Fi phones.
            val bound = cm.boundNetworkForProcess
            if (bound != null && wifiNets.contains(bound) && use(bound)) {
                cb(true)
                return
            }
            val prefer = wifiNets.firstOrNull { n ->
                val cap = cm.getNetworkCapabilities(n)
                cap?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) != true
            } ?: wifiNets.firstOrNull()
            if (prefer != null && use(prefer)) {
                cb(true)
                return
            }
            val done = AtomicBoolean(false)
            val req = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build()
            val netCb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    if (done.compareAndSet(false, true)) {
                        cb(use(network))
                        try {
                            cm.unregisterNetworkCallback(this)
                        } catch (_: Exception) {
                        }
                    }
                }

                override fun onUnavailable() {
                    if (done.compareAndSet(false, true)) cb(false)
                }
            }
            try {
                if (Build.VERSION.SDK_INT >= 26) {
                    cm.requestNetwork(req, netCb, 4000)
                } else {
                    cm.requestNetwork(req, netCb)
                    Handler(Looper.getMainLooper()).postDelayed({
                        if (done.compareAndSet(false, true)) {
                            try {
                                cm.unregisterNetworkCallback(netCb)
                            } catch (_: Exception) {
                            }
                            cb(false)
                        }
                    }, 4000)
                }
            } catch (_: Exception) {
                if (done.compareAndSet(false, true)) cb(false)
            }
        }
    }
}
