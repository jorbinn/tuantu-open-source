package dev.tuantu.tuantu_app

import android.content.Context
import android.content.res.AssetManager
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.os.Build
import android.provider.MediaStore
import androidx.annotation.Keep
import java.io.File
import java.nio.ByteBuffer

@Keep
object LiveVideoCodec {
    /** The export profile is selected from the phone receiving the download. */
    fun targetProfile(): String {
        val device = "${Build.MANUFACTURER} ${Build.BRAND}".lowercase()
        return when {
            listOf("oppo", "oneplus", "realme", "oplus").any(device::contains) -> "oplus"
            listOf("vivo", "iqoo").any(device::contains) -> "vivo"
            else -> "google"
        }
    }

    /**
     * OriginOS indexes a Motion Photo when the MP4 ends with these uuid
     * boxes. The livephoto flag inside ExtInfo is what MediaStore copies
     * into the `live_photo` column. VCamera XMP alone is not enough.
     */
    fun appendVivoMotionBoxes(videoPath: String, assets: AssetManager): Boolean {
        return try {
            val estream = assets.open("live/vivoMediaEStream.uuid").use { it.readBytes() }
            val extinfo = assets.open("live/vivoMediaExtInfo.uuid").use { it.readBytes() }
            if (estream.size < 16 || extinfo.size < 16) return false
            java.io.FileOutputStream(File(videoPath), true).use { out ->
                out.write(estream)
                out.write(extinfo)
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    fun prepareLiveVideo(
        src: String,
        dest: String,
        profile: String,
        assets: AssetManager,
    ): Boolean {
        if (!remuxForMotionPhoto(src, dest)) return false
        if (profile == "vivo" && !appendVivoMotionBoxes(dest, assets)) return false
        return File(dest).length() > 1000
    }


    /**
     * Rewrap as Android-compatible MP4. Video and AAC are copied. PCM is
     * transcoded to AAC. Other audio is a hard failure — never report success
     * after dropping the soundtrack.
     */
    fun remuxForMotionPhoto(src: String, dest: String): Boolean {
        if (File(src).canonicalPath == File(dest).canonicalPath) return false
        val extractor = MediaExtractor()
        var transformedExtractor: MediaExtractor? = null
        val compatibleSource = File("$dest.pcm.mov")
        val transformedVideo = File("$dest.upright.mp4")
        var muxer: MediaMuxer? = null
        var encoder: MediaCodec? = null
        fun fail(): Boolean {
            try {
                muxer?.release()
            } catch (_: Exception) {
            }
            muxer = null
            try {
                File(dest).delete()
            } catch (_: Exception) {
            }
            return false
        }
        try {
            val sourceInfo = QuickTimeLive.inspect(File(src))
            val readable = QuickTimeLive.extractorCopy(File(src), compatibleSource, sourceInfo)
            extractor.setDataSource(readable.path)
            val video = ArrayList<Pair<Int, MediaFormat>>()
            val aac = ArrayList<Pair<Int, MediaFormat>>()
            val pcm = ArrayList<Pair<Int, MediaFormat>>()
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                when {
                    mime.startsWith("video/") -> video.add(index to format)
                    mime == MediaFormat.MIMETYPE_AUDIO_AAC || mime == "audio/mp4a-latm" ->
                        aac.add(index to format)
                    mime == MediaFormat.MIMETYPE_AUDIO_RAW || mime == "audio/raw" ->
                        pcm.add(index to format)
                    mime.startsWith("audio/") -> return false
                }
            }
            if (video.isEmpty()) return false
            // Android can mislabel unsupported MOV audio as application/octet-stream.
            // Compare against the container, not only MediaExtractor's MIME strings.
            require(aac.size + pcm.size == sourceInfo.audioTracks) { "Source audio was not exposed by Android" }
            var videoReader = extractor
            val transform = sourceInfo.transform
            if (transform?.mirrored == true) {
                require(LiveVideoTransform.bake(readable.path, transformedVideo.path, transform))
                val upright = MediaExtractor()
                transformedExtractor = upright
                upright.setDataSource(transformedVideo.path)
                video.clear()
                for (index in 0 until upright.trackCount) {
                    val format = upright.getTrackFormat(index)
                    if (format.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true)
                        video.add(index to format)
                }
                require(video.size == 1)
                videoReader = upright
            }

            File(dest).parentFile?.mkdirs()
            val outMuxer = MediaMuxer(dest, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = outMuxer
            val selected = LinkedHashMap<Int, Int>()
            for ((index, format) in video) {
                selected[index] = outMuxer.addTrack(format)
                videoReader.selectTrack(index)
            }

            var pcmIndex = -1
            var encoderTrack = -1
            if (aac.isNotEmpty()) {
                val (_, format) = aac.first()
                encoderTrack = outMuxer.addTrack(format)
            } else if (pcm.isNotEmpty()) {
                val (index, format) = pcm.first()
                encoder = startAacEncoder(format) ?: return fail()
                val outFormat = aacTrackFormat(format) ?: return fail()
                encoderTrack = outMuxer.addTrack(outFormat)
                pcmIndex = index
            }

            val rotation = if (transform?.mirrored == true) 0 else videoRotation(src)
            if (rotation != 0) outMuxer.setOrientationHint(rotation)
            outMuxer.start()
            var buffer = ByteBuffer.allocateDirect(1024 * 1024)
            val info = MediaCodec.BufferInfo()
            while (true) {
                val inputTrack = videoReader.sampleTrackIndex
                if (inputTrack < 0) break
                val outputTrack = selected[inputTrack]
                if (outputTrack == null) {
                    videoReader.advance()
                    continue
                }
                val sampleSize = videoReader.sampleSize
                if (sampleSize > buffer.capacity()) {
                    var capacity = buffer.capacity()
                    while (capacity < sampleSize) capacity *= 2
                    buffer = ByteBuffer.allocateDirect(capacity)
                }
                buffer.clear()
                val size = videoReader.readSampleData(buffer, 0)
                if (size < 0) break
                info.set(0, size, videoReader.sampleTime, videoReader.sampleFlags)
                outMuxer.writeSampleData(outputTrack, buffer, info)
                videoReader.advance()
            }
            // Use a separate pass for audio so transcoding video never drops it.
            for (i in 0 until extractor.trackCount) extractor.unselectTrack(i)
            val audioIndex = if (aac.isNotEmpty()) aac.first().first else pcmIndex
            if (audioIndex >= 0) {
                extractor.selectTrack(audioIndex)
                extractor.seekTo(0, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                var audioSamples = 0
                while (extractor.sampleTrackIndex >= 0) {
                    if (pcmIndex >= 0) {
                        if (!feedPcmSample(encoder!!, extractor, outMuxer, encoderTrack)) return fail()
                    } else {
                        val sampleSize = extractor.sampleSize
                        if (sampleSize > buffer.capacity()) buffer = ByteBuffer.allocateDirect(sampleSize.toInt())
                        buffer.clear()
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) break
                        info.set(0, size, extractor.sampleTime, extractor.sampleFlags)
                        outMuxer.writeSampleData(encoderTrack, buffer, info)
                        extractor.advance()
                    }
                    audioSamples++
                }
                require(audioSamples > 0) { "Source audio produced no samples" }
            }
            if (encoder != null && encoderTrack >= 0) {
                if (!finishAacEncoder(encoder, outMuxer, encoderTrack)) return fail()
            }
            outMuxer.stop()
            outMuxer.release()
            muxer = null
            return File(dest).length() > 1000
        } catch (error: Exception) {
            android.util.Log.e("TuantuLive", "Live remux failed", error)
            return fail()
        } finally {
            extractor.release()
            transformedExtractor?.release()
            try {
                encoder?.stop()
            } catch (_: Exception) {
            }
            try {
                encoder?.release()
            } catch (_: Exception) {
            }
            try {
                muxer?.release()
            } catch (_: Exception) {
            }
            compatibleSource.delete()
            transformedVideo.delete()
        }
    }

    fun validateDecodable(path: String): Boolean {
        val extractor = MediaExtractor()
        val retriever = MediaMetadataRetriever()
        try {
            extractor.setDataSource(path)
            var hasVideo = false
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) {
                    hasVideo = true
                    extractor.selectTrack(i)
                }
            }
            if (!hasVideo) return false
            var buffer = ByteBuffer.allocateDirect(1024 * 1024)
            var samples = 0
            while (true) {
                if (extractor.sampleTrackIndex < 0) break
                val sampleSize = extractor.sampleSize
                if (sampleSize > buffer.capacity()) {
                    var capacity = buffer.capacity()
                    while (capacity < sampleSize) capacity *= 2
                    buffer = ByteBuffer.allocateDirect(capacity)
                }
                buffer.clear()
                if (extractor.readSampleData(buffer, 0) <= 0) return false
                samples++
                extractor.advance()
            }
            if (samples <= 0) return false
            retriever.setDataSource(path)
            val durationMs = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_DURATION,
            )?.toLongOrNull() ?: return false
            if (durationMs <= 0) return false
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
            val timesUs = longArrayOf(
                0L,
                (durationMs * 1000L) / 2,
                (durationMs * 1000L - 1).coerceAtLeast(0),
            )
            var decoded = 0
            for (timeUs in timesUs) {
                val frame = retriever.getFrameAtTime(
                    timeUs,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                )
                if (frame != null) {
                    decoded++
                    frame.recycle()
                }
            }
            return decoded >= 2 || (decoded == 1 && durationMs < 400)
        } catch (_: Exception) {
            return false
        } finally {
            extractor.release()
            retriever.release()
        }
    }

    private fun videoRotation(src: String): Int {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(src)
            retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION,
            )?.toIntOrNull() ?: 0
        } catch (_: Exception) {
            0
        } finally {
            retriever.release()
        }
    }

    private fun aacCsd(sampleRate: Int, channels: Int): ByteArray? {
        val rates = intArrayOf(
            96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000,
        )
        val srIndex = rates.indexOf(sampleRate)
        if (srIndex < 0 || channels !in 1..7) return null
        val bits = (2 shl 11) or (srIndex shl 7) or (channels shl 3)
        return byteArrayOf(((bits shr 8) and 0xFF).toByte(), (bits and 0xFF).toByte())
    }

    private fun aacTrackFormat(pcm: MediaFormat): MediaFormat? {
        val sampleRate = pcm.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val channels = pcm.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val csd = aacCsd(sampleRate, channels) ?: return null
        return MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC,
            sampleRate,
            channels,
        ).apply {
            setInteger(
                MediaFormat.KEY_AAC_PROFILE,
                MediaCodecInfo.CodecProfileLevel.AACObjectLC,
            )
            setInteger(MediaFormat.KEY_BIT_RATE, if (channels > 1) 128000 else 64000)
            setByteBuffer("csd-0", ByteBuffer.wrap(csd))
        }
    }

    private fun startAacEncoder(pcm: MediaFormat): MediaCodec? {
        return try {
            val sampleRate = pcm.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channels = pcm.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            val format = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_AAC,
                sampleRate,
                channels,
            )
            format.setInteger(
                MediaFormat.KEY_AAC_PROFILE,
                MediaCodecInfo.CodecProfileLevel.AACObjectLC,
            )
            format.setInteger(MediaFormat.KEY_BIT_RATE, if (channels > 1) 128000 else 64000)
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
            MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).apply {
                configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                start()
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun feedPcmSample(
        encoder: MediaCodec,
        extractor: MediaExtractor,
        muxer: MediaMuxer,
        track: Int,
    ): Boolean {
        var tries = 0
        while (tries++ < 64) {
            val inIndex = encoder.dequeueInputBuffer(100_000)
            if (inIndex < 0) {
                if (!drainAacEncoder(encoder, muxer, track, eos = false)) return false
                continue
            }
            val inBuf = encoder.getInputBuffer(inIndex) ?: return false
            inBuf.clear()
            val size = extractor.readSampleData(inBuf, 0)
            val time = extractor.sampleTime.coerceAtLeast(0)
            if (size < 0) {
                encoder.queueInputBuffer(
                    inIndex,
                    0,
                    0,
                    0,
                    MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                )
                extractor.advance()
                return drainAacEncoder(encoder, muxer, track, eos = false)
            }
            encoder.queueInputBuffer(inIndex, 0, size, time, 0)
            extractor.advance()
            return drainAacEncoder(encoder, muxer, track, eos = false)
        }
        return false
    }

    private fun finishAacEncoder(
        encoder: MediaCodec,
        muxer: MediaMuxer,
        track: Int,
    ): Boolean {
        for (attempt in 0 until 64) {
            val inIndex = encoder.dequeueInputBuffer(100_000)
            if (inIndex >= 0) {
                encoder.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                return drainAacEncoder(encoder, muxer, track, eos = true)
            }
            if (!drainAacEncoder(encoder, muxer, track, eos = false)) return false
        }
        return false
    }

    private fun drainAacEncoder(
        encoder: MediaCodec,
        muxer: MediaMuxer,
        track: Int,
        eos: Boolean,
    ): Boolean {
        val info = MediaCodec.BufferInfo()
        var spins = 0
        while (spins++ < 200) {
            val outIndex = encoder.dequeueOutputBuffer(info, if (eos) 100_000L else 0L)
            when {
                outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!eos) return true
                }
                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {}
                outIndex == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> {}
                outIndex >= 0 -> {
                    val buf = encoder.getOutputBuffer(outIndex)
                    if (buf != null &&
                        info.size > 0 &&
                        info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0
                    ) {
                        muxer.writeSampleData(track, buf, info)
                    }
                    val ended = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    encoder.releaseOutputBuffer(outIndex, false)
                    if (ended) return true
                }
                else -> return false
            }
        }
        return !eos
    }

    /**
     * null means this gallery has no public recognition signal.  Do not guess
     * vendor columns: vivo/OriginOS has no documented stable MediaStore field,
     * while OPlus exposes o_is_live_photo on supported releases.
     */
    fun galleryRecognizesMotionPhoto(
        context: Context,
        path: String,
        profile: String = "oplus",
    ): Boolean? {
        return try {
            when (profile) {
                "oplus" -> context.contentResolver.query(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    arrayOf("o_is_live_photo"),
                    "${MediaStore.MediaColumns.DATA}=?",
                    arrayOf(path),
                    null,
                )?.use { cursor ->
                    if (!cursor.moveToFirst()) null else cursor.getInt(0) == 1
                }
                "vivo" -> context.contentResolver.query(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    arrayOf("live_photo"),
                    "${MediaStore.MediaColumns.DATA}=?",
                    arrayOf(path),
                    null,
                )?.use { cursor ->
                    if (!cursor.moveToFirst() || cursor.isNull(0)) {
                        // OriginOS exposes the column but leaves it null when
                        // the file was not indexed as a motion photo. That is
                        // not "unknown": do not report success-as-verified.
                        // Returning null keeps the saved file (do not delete).
                        null
                    } else {
                        val value = cursor.getString(0).orEmpty()
                        if (value.contains("motionphoto") && value.contains('1')) true
                        else null
                    }
                }
                else -> null
            }
        } catch (_: Exception) {
            null
        }
    }

    fun stampStillOwner(path: String, profile: String) {
        if (profile != "oplus") return
        android.media.ExifInterface(path).apply {
            // ColorOS reads the suffix as a numeric bitmask, not free text.
            // Both verified WeChat exports use 0xA00020. Camera invalidates
            // Live by clearing bit 0x800000. This is a format flag, not data
            // copied from another photo's extended container.
            setAttribute(android.media.ExifInterface.TAG_USER_COMMENT, "oplus_10485792")
            saveAttributes()
        }
    }
}
