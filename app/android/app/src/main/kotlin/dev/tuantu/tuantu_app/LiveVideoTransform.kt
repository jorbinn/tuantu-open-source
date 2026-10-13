package dev.tuantu.tuantu_app

import android.graphics.ImageFormat
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File

/** Physically applies mirrored MOV matrices that Android's rotation hint cannot express.
 * Only used for 8-bit video with a reflection; ordinary/HDR MP4 stays lossless.
 */
internal object LiveVideoTransform {
    fun bake(src: String, dest: String, transform: QuickTimeLive.Transform): Boolean {
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        var encoder: MediaCodec? = null
        var muxer: MediaMuxer? = null
        var success = false
        try {
            extractor.setDataSource(src)
            val track = (0 until extractor.trackCount).first {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
            }
            val format = extractor.getTrackFormat(track)
            val mime = requireNotNull(format.getString(MediaFormat.KEY_MIME))
            // The observed iPhone inputs are 8-bit AVC. Fail unsupported reflected
            // HDR rather than silently flattening its bit depth/color space.
            require(mime == MediaFormat.MIMETYPE_VIDEO_AVC)
            val profile = if (format.containsKey(MediaFormat.KEY_PROFILE))
                format.getInteger(MediaFormat.KEY_PROFILE) else 0
            require(profile != MediaCodecInfo.CodecProfileLevel.AVCProfileHigh10 &&
                profile != MediaCodecInfo.CodecProfileLevel.AVCProfileHigh422 &&
                profile != MediaCodecInfo.CodecProfileLevel.AVCProfileHigh444)
            val width = format.getInteger(MediaFormat.KEY_WIDTH)
            val height = format.getInteger(MediaFormat.KEY_HEIGHT)
            require(width % 2 == 0 && height % 2 == 0 && width.toLong() * height <= 4096L * 4096)
            val outWidth = if (transform.swapsAxes) height else width
            val outHeight = if (transform.swapsAxes) width else height
            val outputFormat = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, outWidth, outHeight)
            outputFormat.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            outputFormat.setInteger(MediaFormat.KEY_BIT_RATE, (width.toLong() * height * 6).coerceIn(4_000_000, 24_000_000).toInt())
            outputFormat.setInteger(MediaFormat.KEY_FRAME_RATE, if (format.containsKey(MediaFormat.KEY_FRAME_RATE))
                format.getInteger(MediaFormat.KEY_FRAME_RATE).coerceIn(1, 120) else 30)
            outputFormat.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            for (key in listOf(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.KEY_COLOR_RANGE, MediaFormat.KEY_COLOR_TRANSFER))
                if (format.containsKey(key)) outputFormat.setInteger(key, format.getInteger(key))
            val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            encoder = enc
            enc.configure(outputFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            enc.start()
            // No surface: decode the coded pixels, never apply the matrix twice.
            format.setInteger(MediaFormat.KEY_ROTATION, 0)
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            val dec = MediaCodec.createDecoderByType(mime)
            decoder = dec
            dec.configure(format, null, null, 0)
            dec.start()
            extractor.selectTrack(track)
            val mux = MediaMuxer(dest, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = mux
            var muxTrack = -1
            var inputEnd = false
            var decodeEnd = false
            var encodeEnd = false
            var pending = -1
            var frames = 0
            val decoded = MediaCodec.BufferInfo()
            val encoded = MediaCodec.BufferInfo()
            var lastPts = 0L
            var lastProgress = System.nanoTime()
            while (!encodeEnd) {
                require(System.nanoTime() - lastProgress < 30_000_000_000L) { "Video transform stalled" }
                if (!inputEnd && pending < 0) {
                    val index = dec.dequeueInputBuffer(1000)
                    if (index >= 0) {
                        val buffer = requireNotNull(dec.getInputBuffer(index))
                        buffer.clear()
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            dec.queueInputBuffer(index, 0, 0, lastPts, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputEnd = true
                        } else {
                            lastPts = extractor.sampleTime.coerceAtLeast(0)
                            dec.queueInputBuffer(index, 0, size, lastPts, 0)
                            extractor.advance()
                        }
                        lastProgress = System.nanoTime()
                    }
                }
                if (pending < 0 && !decodeEnd) pending = dec.dequeueOutputBuffer(decoded, 1000)
                if (pending >= 0) {
                    val index = enc.dequeueInputBuffer(1000)
                    if (index >= 0) {
                        val eos = decoded.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        if (decoded.size > 0) {
                            val image = requireNotNull(dec.getOutputImage(pending))
                            val target = requireNotNull(enc.getInputImage(index))
                            try { copy(image, target, transform) }
                            finally { image.close(); target.close() }
                            enc.queueInputBuffer(index, 0, outWidth * outHeight * 3 / 2,
                                decoded.presentationTimeUs.coerceAtLeast(0), if (eos) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0)
                            frames++
                        } else {
                            enc.queueInputBuffer(index, 0, 0, lastPts, if (eos) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0)
                        }
                        dec.releaseOutputBuffer(pending, false)
                        pending = -1
                        decodeEnd = eos
                        lastProgress = System.nanoTime()
                    }
                }
                val index = enc.dequeueOutputBuffer(encoded, 1000)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    require(muxTrack < 0)
                    muxTrack = mux.addTrack(enc.outputFormat)
                    mux.start()
                    lastProgress = System.nanoTime()
                } else if (index >= 0) {
                    if (encoded.size > 0 && encoded.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                        require(muxTrack >= 0)
                        mux.writeSampleData(muxTrack, requireNotNull(enc.getOutputBuffer(index)), encoded)
                    }
                    encodeEnd = encoded.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    enc.releaseOutputBuffer(index, false)
                    lastProgress = System.nanoTime()
                }
            }
            require(frames > 0 && muxTrack >= 0)
            mux.stop()
            success = true
            return true
        } catch (error: Exception) {
            android.util.Log.e("TuantuLive", "Cannot apply video display matrix", error)
            return false
        } finally {
            extractor.release()
            try { decoder?.stop() } catch (_: Exception) {}
            try { decoder?.release() } catch (_: Exception) {}
            try { encoder?.stop() } catch (_: Exception) {}
            try { encoder?.release() } catch (_: Exception) {}
            try { muxer?.release() } catch (_: Exception) {}
            if (!success) File(dest).delete()
        }
    }

    private fun copy(src: Image, dst: Image, t: QuickTimeLive.Transform) {
        require(src.format == ImageFormat.YUV_420_888 && dst.format == ImageFormat.YUV_420_888)
        val crop = src.cropRect
        val target = dst.cropRect
        require(target.width() == (if (t.swapsAxes) crop.height() else crop.width()) &&
            target.height() == (if (t.swapsAxes) crop.width() else crop.height()))
        for (plane in 0..2) {
            val div = if (plane == 0) 1 else 2
            val width = crop.width() / div
            val height = crop.height() / div
            val outWidth = target.width() / div
            val outHeight = target.height() / div
            val input = src.planes[plane]
            val output = dst.planes[plane]
            val row = ByteArray((width - 1) * input.pixelStride + 1)
            val pixels = ByteArray(width * height)
            val inBase = input.buffer.position()
            for (y in 0 until height) {
                input.buffer.position(inBase + (crop.top / div + y) * input.rowStride + crop.left / div * input.pixelStride)
                input.buffer.get(row)
                for (x in 0 until width) pixels[y * width + x] = row[x * input.pixelStride]
            }
            val outBase = output.buffer.position()
            val xShift = if (t.a < 0 || t.c < 0) outWidth - 1 else 0
            val yShift = if (t.b < 0 || t.d < 0) outHeight - 1 else 0
            for (y in 0 until height) for (x in 0 until width) {
                val tx = t.a * x + t.c * y + xShift
                val ty = t.b * x + t.d * y + yShift
                output.buffer.put(outBase + (target.top / div + ty) * output.rowStride +
                    (target.left / div + tx) * output.pixelStride, pixels[y * width + x])
            }
        }
    }
}
