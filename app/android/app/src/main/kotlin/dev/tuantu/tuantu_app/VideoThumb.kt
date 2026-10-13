package dev.tuantu.tuantu_app

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

/**
 * 从视频抽一帧做成 JPEG 封面。MediaMetadataRetriever 只 seek 关键帧，不整片解码。
 */
object VideoThumb {
    private val io = Executors.newSingleThreadExecutor { r ->
        Thread(r, "tuantu-video-thumb").apply { isDaemon = true }
    }

    fun extractAsync(
        src: String,
        dest: String,
        maxWidth: Int,
        done: (Map<String, Any>) -> Unit,
    ) {
        io.execute {
            val out = try {
                extract(src, dest, maxWidth)
            } catch (e: Exception) {
                mapOf("ok" to false, "err" to (e.message ?: "fail"))
            }
            done(out)
        }
    }

    fun extract(src: String, dest: String, maxWidth: Int): Map<String, Any> {
        if (src.isEmpty() || dest.isEmpty()) return mapOf("ok" to false)
        val srcFile = File(src)
        if (!srcFile.exists() || srcFile.length() == 0L) return mapOf("ok" to false)

        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(src)
            var frame = retriever.getFrameAtTime(
                1_000_000L,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            )
            if (frame == null) {
                frame = retriever.getFrameAtTime(
                    0L,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                )
            }
            if (frame == null) frame = retriever.frameAtTime
            if (frame == null) return mapOf("ok" to false)

            val srcW = frame.width
            val srcH = frame.height
            val scaled: Bitmap = if (srcW > maxWidth && maxWidth > 0) {
                val h = (srcH.toLong() * maxWidth / srcW).toInt().coerceAtLeast(1)
                val s = Bitmap.createScaledBitmap(frame, maxWidth, h, true)
                if (s != frame) frame.recycle()
                s
            } else {
                frame
            }
            try {
                File(dest).parentFile?.mkdirs()
                FileOutputStream(File(dest)).use { out ->
                    if (!scaled.compress(Bitmap.CompressFormat.JPEG, 82, out)) {
                        return mapOf("ok" to false)
                    }
                }
                if (File(dest).length() == 0L) return mapOf("ok" to false)
                return mapOf("ok" to true, "width" to srcW, "height" to srcH)
            } finally {
                if (!scaled.isRecycled) scaled.recycle()
            }
        } finally {
            retriever.release()
        }
    }
}
