package dev.tuantu.tuantu_app.vpn

import java.net.InetAddress

/** IPv4 / TCP / UDP 头解析与组包（代理 VPN 用）。 */
internal object Packet {
    const val TCP = 6
    const val UDP = 17
    const val FIN = 0x01
    const val SYN = 0x02
    const val RST = 0x04
    const val PSH = 0x08
    const val ACK = 0x10

    fun isIpv4(buf: ByteArray, len: Int): Boolean =
        len >= 20 && ((buf[0].toInt() ushr 4) and 0x0f) == 4

    fun ihl(buf: ByteArray): Int = (buf[0].toInt() and 0x0f) * 4
    fun protocol(buf: ByteArray): Int = buf[9].toInt() and 0xff
    fun srcIp(buf: ByteArray): Int = read32(buf, 12)
    fun dstIp(buf: ByteArray): Int = read32(buf, 16)

    fun tcpSrcPort(buf: ByteArray, iph: Int): Int = read16(buf, iph)
    fun tcpDstPort(buf: ByteArray, iph: Int): Int = read16(buf, iph + 2)
    fun tcpSeq(buf: ByteArray, iph: Int): Long = read32(buf, iph + 4).toLong() and 0xffffffffL
    fun tcpAck(buf: ByteArray, iph: Int): Long = read32(buf, iph + 8).toLong() and 0xffffffffL
    fun tcpDataOff(buf: ByteArray, iph: Int): Int = ((buf[iph + 12].toInt() and 0xff) ushr 4) * 4
    fun tcpFlags(buf: ByteArray, iph: Int): Int = buf[iph + 13].toInt() and 0x3f
    fun tcpKey(buf: ByteArray, iph: Int): String =
        "${srcIp(buf)}:${tcpSrcPort(buf, iph)}-${dstIp(buf)}:${tcpDstPort(buf, iph)}"

    fun udpSrcPort(buf: ByteArray, iph: Int): Int = read16(buf, iph)
    fun udpDstPort(buf: ByteArray, iph: Int): Int = read16(buf, iph + 2)

    fun ipToAddr(ip: Int): InetAddress = InetAddress.getByAddress(
        byteArrayOf(
            (ip ushr 24).toByte(),
            (ip ushr 16).toByte(),
            (ip ushr 8).toByte(),
            ip.toByte(),
        )
    )

    fun addrToIp(addr: InetAddress): Int {
        val b = addr.address
        if (b.size != 4) return 0
        return ((b[0].toInt() and 0xff) shl 24) or
            ((b[1].toInt() and 0xff) shl 16) or
            ((b[2].toInt() and 0xff) shl 8) or
            (b[3].toInt() and 0xff)
    }

    fun buildTcp(
        srcIp: Int,
        dstIp: Int,
        srcPort: Int,
        dstPort: Int,
        seq: Long,
        ack: Long,
        flags: Int,
        payload: ByteArray?,
        mss: Boolean = false,
    ): ByteArray {
        val opt = if (mss && flags and SYN != 0) 4 else 0
        val tcpHdr = 20 + opt
        val pay = payload?.size ?: 0
        val total = 20 + tcpHdr + pay
        val buf = ByteArray(total)
        writeIp(buf, total, TCP, srcIp, dstIp)
        val o = 20
        write16(buf, o, srcPort)
        write16(buf, o + 2, dstPort)
        write32(buf, o + 4, seq.toInt())
        write32(buf, o + 8, ack.toInt())
        buf[o + 12] = ((tcpHdr / 4) shl 4).toByte()
        buf[o + 13] = flags.toByte()
        buf[o + 14] = 0xff.toByte()
        buf[o + 15] = 0xff.toByte()
        if (opt == 4) {
            buf[o + 20] = 2
            buf[o + 21] = 4
            buf[o + 22] = 0x05
            buf[o + 23] = 0xb4.toByte()
        }
        if (pay > 0 && payload != null) {
            System.arraycopy(payload, 0, buf, 20 + tcpHdr, pay)
        }
        val tcs = checksum(buf, o, tcpHdr + pay, pseudo(srcIp, dstIp, TCP, tcpHdr + pay))
        write16(buf, o + 16, tcs)
        return buf
    }

    fun buildUdp(
        srcIp: Int,
        dstIp: Int,
        srcPort: Int,
        dstPort: Int,
        payload: ByteArray,
    ): ByteArray {
        val udpLen = 8 + payload.size
        val total = 20 + udpLen
        val buf = ByteArray(total)
        writeIp(buf, total, UDP, srcIp, dstIp)
        write16(buf, 20, srcPort)
        write16(buf, 22, dstPort)
        write16(buf, 24, udpLen)
        System.arraycopy(payload, 0, buf, 28, payload.size)
        var csum = checksum(buf, 20, udpLen, pseudo(srcIp, dstIp, UDP, udpLen))
        if (csum == 0) csum = 0xffff
        write16(buf, 26, csum)
        return buf
    }

    private fun writeIp(buf: ByteArray, total: Int, proto: Int, srcIp: Int, dstIp: Int) {
        buf[0] = 0x45
        write16(buf, 2, total)
        buf[6] = 0x40
        buf[8] = 64
        buf[9] = proto.toByte()
        write32(buf, 12, srcIp)
        write32(buf, 16, dstIp)
        write16(buf, 10, checksum(buf, 0, 20))
    }

    private fun read16(buf: ByteArray, o: Int): Int =
        ((buf[o].toInt() and 0xff) shl 8) or (buf[o + 1].toInt() and 0xff)

    private fun read32(buf: ByteArray, o: Int): Int = (read16(buf, o) shl 16) or read16(buf, o + 2)

    private fun write16(buf: ByteArray, o: Int, v: Int) {
        buf[o] = (v ushr 8).toByte()
        buf[o + 1] = v.toByte()
    }

    private fun write32(buf: ByteArray, o: Int, v: Int) {
        write16(buf, o, (v ushr 16) and 0xffff)
        write16(buf, o + 2, v and 0xffff)
    }

    private fun pseudo(srcIp: Int, dstIp: Int, proto: Int, len: Int): Long {
        var s = 0L
        s += (srcIp ushr 16) and 0xffff
        s += srcIp and 0xffff
        s += (dstIp ushr 16) and 0xffff
        s += dstIp and 0xffff
        s += proto
        s += len
        return s
    }

    private fun checksum(data: ByteArray, off: Int, len: Int, extra: Long = 0L): Int {
        var sum = extra
        var i = 0
        while (i < len - 1) {
            sum += ((data[off + i].toInt() and 0xff) shl 8) or (data[off + i + 1].toInt() and 0xff)
            i += 2
        }
        if (len and 1 != 0) sum += (data[off + len - 1].toInt() and 0xff) shl 8
        while (sum ushr 16 != 0L) sum = (sum and 0xffffL) + (sum ushr 16)
        return sum.toInt().inv() and 0xffff
    }
}
