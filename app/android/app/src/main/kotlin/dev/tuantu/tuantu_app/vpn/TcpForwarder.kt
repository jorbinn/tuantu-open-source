package dev.tuantu.tuantu_app.vpn

import android.net.Network
import android.net.VpnService
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import kotlin.random.Random

/**
 * 把 tun 上的 TCP 流转成真实 Socket。
 * 公网目的地绑蜂窝，RFC1918 绑 Wi-Fi（连盒子）。
 */
internal class TcpForwarder(
    private val vpn: VpnService,
    private val pickNet: (InetAddress) -> Network?,
    private val writeTun: (ByteArray) -> Unit,
) {
    private val sessions = ConcurrentHashMap<String, Session>()
    private val opening = ConcurrentHashMap.newKeySet<String>()
    private val connecting = ConcurrentHashMap<String, Socket>()
    @Volatile private var stopped = false
    private val pool = Executors.newCachedThreadPool { r ->
        Thread(r, "tt-tcp").apply { isDaemon = true }
    }

    fun handle(buf: ByteArray, len: Int) {
        if (stopped) return
        val iph = Packet.ihl(buf)
        if (len < iph + 20) return
        val flags = Packet.tcpFlags(buf, iph)
        val key = Packet.tcpKey(buf, iph)
        if (flags and Packet.SYN != 0 && flags and Packet.ACK == 0) {
            if (stopped || sessions.containsKey(key) || !opening.add(key)) return
            val copy = buf.copyOf(len)
            if (!submit {
                    try {
                        if (!stopped) open(copy, key)
                    } finally {
                        opening.remove(key)
                    }
                }) {
                opening.remove(key)
            }
            return
        }
        val sess = sessions[key]
        if (sess == null) {
            if (flags and Packet.RST == 0) rst(buf, iph)
            return
        }
        sess.offer(buf.copyOf(len))
    }

    fun shutdown() {
        stopped = true
        sessions.values.forEach { it.close() }
        sessions.clear()
        connecting.values.forEach { sock ->
            try {
                sock.close()
            } catch (_: Exception) {
            }
        }
        connecting.clear()
        opening.clear()
        pool.shutdownNow()
    }

    private fun submit(task: Runnable): Boolean {
        if (stopped) return false
        return try {
            pool.execute {
                if (!stopped) task.run()
            }
            true
        } catch (_: RejectedExecutionException) {
            false
        }
    }

    private fun open(syn: ByteArray, key: String) {
        val iph = Packet.ihl(syn)
        val srcIp = Packet.srcIp(syn)
        val dstIp = Packet.dstIp(syn)
        val srcPort = Packet.tcpSrcPort(syn, iph)
        val dstPort = Packet.tcpDstPort(syn, iph)
        val clientSeq = Packet.tcpSeq(syn, iph)
        val dest = Packet.ipToAddr(dstIp)
        val lan = dest.isSiteLocalAddress || dest.isLinkLocalAddress
        val net = pickNet(dest)
        if (!lan && net == null) {
            rst(syn, iph)
            return
        }
        if (stopped) {
            rst(syn, iph)
            return
        }
        val sock = Socket()
        connecting[key] = sock
        try {
            if (stopped) throw java.io.IOException("proxy stopped")
            vpn.protect(sock)
            net?.bindSocket(sock)
            sock.tcpNoDelay = true
            sock.keepAlive = true
            sock.connect(InetSocketAddress(dest, dstPort), 8_000)
            if (stopped) throw java.io.IOException("proxy stopped")
        } catch (_: Exception) {
            rst(syn, iph)
            try {
                sock.close()
            } catch (_: Exception) {
            }
            return
        } finally {
            connecting.remove(key, sock)
        }
        if (stopped) {
            try {
                sock.close()
            } catch (_: Exception) {
            }
            rst(syn, iph)
            return
        }
        val sess = Session(srcIp, dstIp, srcPort, dstPort, sock, clientSeq)
        val prev = sessions.putIfAbsent(key, sess)
        if (prev != null || stopped) {
            sess.close()
            if (stopped) rst(syn, iph)
            return
        }
        sess.sendSynAck()
        if (!submit { sess.loopTun() }) {
            sess.close()
            return
        }
        if (!submit { sess.pumpSocket() }) {
            sess.close()
        }
    }

    private fun rst(buf: ByteArray, iph: Int) {
        writeTun(
            Packet.buildTcp(
                srcIp = Packet.dstIp(buf),
                dstIp = Packet.srcIp(buf),
                srcPort = Packet.tcpDstPort(buf, iph),
                dstPort = Packet.tcpSrcPort(buf, iph),
                seq = Packet.tcpAck(buf, iph),
                ack = (Packet.tcpSeq(buf, iph) + 1) and 0xffffffffL,
                flags = Packet.RST or Packet.ACK,
                payload = null,
            )
        )
    }

    private inner class Session(
        val srcIp: Int,
        val dstIp: Int,
        val srcPort: Int,
        val dstPort: Int,
        val sock: Socket,
        startClientSeq: Long,
    ) {
        @Volatile var alive = true
        var clientNext: Long = startClientSeq
        var ourSeq: Long = Random.nextInt().toLong() and 0xffffffffL
        private val q = LinkedBlockingQueue<ByteArray>(512)

        fun offer(p: ByteArray) {
            q.offer(p)
        }

        fun sendSynAck() {
            val pkt = Packet.buildTcp(
                srcIp = dstIp,
                dstIp = srcIp,
                srcPort = dstPort,
                dstPort = srcPort,
                seq = ourSeq,
                ack = (clientNext + 1) and 0xffffffffL,
                flags = Packet.SYN or Packet.ACK,
                payload = null,
                mss = true,
            )
            ourSeq = (ourSeq + 1) and 0xffffffffL
            clientNext = (clientNext + 1) and 0xffffffffL
            writeTun(pkt)
        }

        fun loopTun() {
            while (alive) {
                val p = try {
                    q.poll(500, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    break
                } ?: continue
                process(p)
            }
        }

        private fun process(buf: ByteArray) {
            if (!alive) return
            val iph = Packet.ihl(buf)
            val flags = Packet.tcpFlags(buf, iph)
            if (flags and Packet.RST != 0) {
                close()
                return
            }
            val payloadOff = iph + Packet.tcpDataOff(buf, iph)
            val payloadLen = buf.size - payloadOff
            if (payloadLen > 0) {
                try {
                    sock.getOutputStream().write(buf, payloadOff, payloadLen)
                } catch (_: Exception) {
                    close()
                    return
                }
                clientNext = (Packet.tcpSeq(buf, iph) + payloadLen) and 0xffffffffL
                writeTun(
                    Packet.buildTcp(
                        dstIp, srcIp, dstPort, srcPort,
                        ourSeq, clientNext, Packet.ACK, null,
                    )
                )
            }
            if (flags and Packet.FIN != 0) {
                clientNext = (clientNext + 1) and 0xffffffffL
                try {
                    sock.shutdownOutput()
                } catch (_: Exception) {
                }
                writeTun(
                    Packet.buildTcp(
                        dstIp, srcIp, dstPort, srcPort,
                        ourSeq, clientNext, Packet.ACK, null,
                    )
                )
            }
        }

        fun pumpSocket() {
            val buf = ByteArray(1360)
            try {
                val ins = sock.getInputStream()
                while (alive) {
                    val n = ins.read(buf)
                    if (n < 0) break
                    val payload = buf.copyOf(n)
                    writeTun(
                        Packet.buildTcp(
                            dstIp, srcIp, dstPort, srcPort,
                            ourSeq, clientNext,
                            Packet.PSH or Packet.ACK, payload,
                        )
                    )
                    ourSeq = (ourSeq + n) and 0xffffffffL
                }
            } catch (_: Exception) {
            }
            if (alive) {
                writeTun(
                    Packet.buildTcp(
                        dstIp, srcIp, dstPort, srcPort,
                        ourSeq, clientNext,
                        Packet.FIN or Packet.ACK, null,
                    )
                )
                ourSeq = (ourSeq + 1) and 0xffffffffL
            }
            close()
        }

        fun close() {
            if (!alive) return
            alive = false
            try {
                sock.close()
            } catch (_: Exception) {
            }
            sessions.remove("$srcIp:$srcPort-$dstIp:$dstPort")
        }
    }
}
