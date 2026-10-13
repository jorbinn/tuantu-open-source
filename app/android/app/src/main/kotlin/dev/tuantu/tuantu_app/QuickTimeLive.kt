package dev.tuantu.tuantu_app

import java.io.File
import java.io.RandomAccessFile

/** Bounded MOV metadata reader. Never modifies the library original or sample offsets. */
internal object QuickTimeLive {
    data class Box(val type: String, val start: Long, val data: Long, val end: Long)
    data class Transform(val a: Int, val b: Int, val c: Int, val d: Int) {
        val mirrored get() = a * d - b * c < 0
        val swapsAxes get() = a == 0
    }
    data class Info(val audioTracks: Int, val transform: Transform?, val patches: List<PcmPatch>)
    data class PcmPatch(val start: Long, val channels: Int, val rate: Int)

    private fun boxes(f: RandomAccessFile, start: Long, end: Long): List<Box> {
        val result = ArrayList<Box>()
        var p = start
        while (p < end) {
            require(end - p >= 8) { "Truncated MOV box" }
            f.seek(p)
            var size = f.readInt().toLong() and 0xffffffffL
            val type = ByteArray(4).also(f::readFully).toString(Charsets.ISO_8859_1)
            var header = 8L
            if (size == 1L) { require(end - p >= 16); size = f.readLong(); header = 16 }
            if (size == 0L) size = end - p
            require(size >= header && size <= end - p) { "Invalid MOV box $type" }
            result.add(Box(type, p, p + header, p + size))
            p += size
        }
        return result
    }

    private fun child(f: RandomAccessFile, parent: Box, type: String) =
        boxes(f, parent.data, parent.end).firstOrNull { it.type == type }

    private fun uint(f: RandomAccessFile, at: Long): Long {
        f.seek(at)
        return f.readInt().toLong() and 0xffffffffL
    }

    fun inspect(file: File): Info = RandomAccessFile(file, "r").use { f ->
        // Vendor trailers may follow the ISO portion: stop once moov is found.
        var p = 0L
        var moov: Box? = null
        while (p + 8 <= f.length()) {
            f.seek(p)
            var size = f.readInt().toLong() and 0xffffffffL
            val type = ByteArray(4).also(f::readFully).toString(Charsets.ISO_8859_1)
            var header = 8L
            if (size == 1L) { size = f.readLong(); header = 16 }
            if (size == 0L) size = f.length() - p
            require(size >= header && size <= f.length() - p) { "Invalid ISO container" }
            if (type == "moov") { moov = Box(type, p, p + header, p + size); break }
            p += size
        }
        requireNotNull(moov) { "Missing moov" }
        var audio = 0
        var transform: Transform? = null
        val patches = ArrayList<PcmPatch>()
        for (track in boxes(f, moov.data, moov.end).filter { it.type == "trak" }) {
            val media = child(f, track, "mdia") ?: continue
            val handler = child(f, media, "hdlr") ?: continue
            require(handler.end - handler.data >= 12)
            f.seek(handler.data + 8)
            val kind = ByteArray(4).also(f::readFully).toString(Charsets.ISO_8859_1)
            if (kind == "vide") {
                val tkhd = requireNotNull(child(f, track, "tkhd"))
                f.seek(tkhd.data)
                val version = f.readUnsignedByte()
                require(version == 0 || version == 1)
                val matrix = tkhd.data + if (version == 1) 52 else 40
                require(matrix + 36 <= tkhd.end)
                f.seek(matrix)
                val v = IntArray(9) { f.readInt() }
                // Orthogonal rotations/reflections only. Never silently discard a skew.
                require(listOf(v[0], v[1], v[3], v[4]).all { it in listOf(-65536, 0, 65536) } &&
                    v[2] == 0 && v[5] == 0 && v[8] == 0x40000000)
                val t = Transform(v[0] / 65536, v[1] / 65536, v[3] / 65536, v[4] / 65536)
                require(t.a * t.a + t.b * t.b == 1 && t.c * t.c + t.d * t.d == 1 &&
                    t.a * t.c + t.b * t.d == 0)
                require(transform == null) { "Multiple video tracks are not supported" }
                transform = t
            }
            if (kind != "soun") continue
            audio++
            val minf = requireNotNull(child(f, media, "minf"))
            val stbl = requireNotNull(child(f, minf, "stbl"))
            val stsd = requireNotNull(child(f, stbl, "stsd"))
            require(stsd.end - stsd.data >= 8)
            val entries = boxes(f, stsd.data + 8, stsd.end)
            require(entries.size.toLong() == uint(f, stsd.data + 4))
            for (entry in entries) {
                if (entry.type != "lpcm") continue
                // QuickTime v2 LPCM stores the actual rate/channels after the legacy
                // fields. Android sees this as application/octet-stream. Adapt only
                // packed signed little-endian 16-bit PCM; samples remain untouched.
                require(entry.end - entry.start >= 72)
                f.seek(entry.start + 16)
                require(f.readUnsignedShort() == 2) { "Unsupported LPCM version" }
                require(uint(f, entry.start + 36) == 72L)
                f.seek(entry.start + 40)
                val rate = f.readDouble()
                val channels = uint(f, entry.start + 48).toInt()
                val bits = uint(f, entry.start + 56)
                val flags = uint(f, entry.start + 60)
                val bytesPerPacket = uint(f, entry.start + 64)
                val framesPerPacket = uint(f, entry.start + 68)
                require(rate in 8000.0..48000.0 && rate == rate.toInt().toDouble() &&
                    channels in 1..2 && bits == 16L && flags == 12L &&
                    bytesPerPacket == channels * 2L && framesPerPacket == 1L) {
                    "Unsupported LPCM layout (must not discard audio)"
                }
                patches.add(PcmPatch(entry.start, channels, rate.toInt()))
            }
        }
        require(audio <= 1) { "Multiple audio tracks require explicit selection" }
        Info(audio, transform, patches)
    }

    fun extractorCopy(src: File, dest: File, info: Info): File {
        if (info.patches.isEmpty()) return src
        src.copyTo(dest, overwrite = true)
        RandomAccessFile(dest, "rw").use { f ->
            for (patch in info.patches) {
                f.seek(patch.start + 4)
                f.writeBytes("sowt")
                f.seek(patch.start + 16)
                f.writeShort(0) // v0 PCM description, same sized entry and same offsets
                f.seek(patch.start + 24)
                f.writeShort(patch.channels)
                f.writeShort(16)
                f.writeShort(0)
                f.writeShort(0)
                f.writeInt(patch.rate shl 16)
                // Keep a well-formed child box in the now unused v2 extension.
                f.writeInt(36)
                f.writeBytes("free")
                f.write(ByteArray(28))
            }
        }
        return dest
    }
}
