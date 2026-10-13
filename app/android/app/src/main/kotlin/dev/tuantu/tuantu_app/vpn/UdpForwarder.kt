package dev.tuantu.tuantu_app.vpn

import android.net.Network
import android.net.VpnService
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/** UDP NAT：DNS / QUIC 等。公网走蜂窝，局域网走 Wi-Fi。 */
internal class UdpForwarder(
    private val vpn: VpnService,
    private val pickNet: (InetAddress) -> Network?,
    private val writeTun: (ByteArray) -> Unit,
) {
    private val nats = ConcurrentHashMap<String, Nat>()
    private val pool = Executors.newCachedThreadPool { r ->
        Thread(r, "tt-udp").apply { isDaemon = true }
    }

    fun handle(buf: ByteArray, len: Int) {
        val iph = Packet.ihl(buf)
        if (len < iph + 8) return
        val srcIp = Packet.srcIp(buf)
        val dstIp = Packet.dstIp(buf)
        val srcPort = Packet.udpSrcPort(buf, iph)
        val dstPort = Packet.udpDstPort(buf, iph)
        val payloadOff = iph + 8
        if (len < payloadOff) return
        val payload = buf.copyOfRange(payloadOff, len)
        val dest = Packet.ipToAddr(dstIp)
        val key = "$srcIp:$srcPort"
        val nat = nats[key] ?: newNat(key, srcIp, srcPort, dest) ?: return
        nat.last = System.currentTimeMillis()
        try {
            nat.sock.send(DatagramPacket(payload, payload.size, dest, dstPort))
        } catch (_: Exception) {
        }
        sweep()
    }

    fun shutdown() {
        nats.values.forEach { it.close() }
        nats.clear()
        pool.shutdownNow()
    }

    private fun newNat(key: String, srcIp: Int, srcPort: Int, dest: InetAddress): Nat? {
        val sock = DatagramSocket()
        try {
            vpn.protect(sock)
            val net = pickNet(dest)
            val lan = dest.isSiteLocalAddress || dest.isLinkLocalAddress
            if (!lan && net == null) {
                sock.close()
                return null
            }
            net?.bindSocket(sock)
            sock.soTimeout = 0
        } catch (_: Exception) {
            try { sock.close() } catch (_: Exception) {}
            return null
        }
        val nat = Nat(key, srcIp, srcPort, sock)
        nats[key] = nat
        pool.execute { nat.recvLoop() }
        return nat
    }

    private var lastSweep = 0L
    private fun sweep() {
        val now = System.currentTimeMillis()
        if (now - lastSweep < 15_000) return
        lastSweep = now
        nats.values.filter { now - it.last > 60_000 }.forEach { it.close() }
    }

    private inner class Nat(
        val key: String,
        val srcIp: Int,
        val srcPort: Int,
        val sock: DatagramSocket,
    ) {
        @Volatile var last = System.currentTimeMillis()
        @Volatile var alive = true

        fun recvLoop() {
            val buf = ByteArray(2048)
            while (alive) {
                val p = DatagramPacket(buf, buf.size)
                try {
                    sock.receive(p)
                } catch (_: Exception) {
                    break
                }
                last = System.currentTimeMillis()
                val addr = p.address ?: continue
                if (addr.address.size != 4) continue
                writeTun(
                    Packet.buildUdp(
                        srcIp = Packet.addrToIp(addr),
                        dstIp = srcIp,
                        srcPort = p.port,
                        dstPort = srcPort,
                        payload = p.data.copyOf(p.length),
                    )
                )
            }
            close()
        }

        fun close() {
            alive = false
            try {
                sock.close()
            } catch (_: Exception) {
            }
            nats.remove(key)
        }
    }
}
