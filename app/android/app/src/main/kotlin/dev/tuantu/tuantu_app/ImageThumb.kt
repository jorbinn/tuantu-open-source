package dev.tuantu.tuantu_app

import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.os.Build
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import kotlin.math.min
import kotlin.math.roundToInt

/** Decode to thumbnail size on workers, never allocate the full camera bitmap
 * on the platform/UI thread. ImageDecoder applies EXIF rotation/mirroring once.
 * Older Android/unsupported formats return null for the Dart isolate fallback. */
object ImageThumb {
    private val workers = Executors.newFixedThreadPool(2)

    fun extractAsync(path: String, callback: (Map<String, Any>?) -> Unit) {
        workers.execute {
            val result = try { extract(path) } catch (_: Exception) { null }
            callback(result)
        }
    }

    private fun extract(path: String): Map<String, Any>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null
        var width = 0
        var height = 0
        val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(File(path))) { decoder, info, _ ->
            width = info.size.width
            height = info.size.height
            require(width > 0 && height > 0)
            val scale = min(1.0, min(480.0 / width, 1600.0 / height))
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            decoder.setTargetSize(
                (width * scale).roundToInt().coerceAtLeast(1),
                (height * scale).roundToInt().coerceAtLeast(1),
            )
        }
        return try {
            val bytes = ByteArrayOutputStream()
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 82, bytes)) null
            else mapOf("jpeg" to bytes.toByteArray(), "width" to width, "height" to height)
        } finally {
            bitmap.recycle()
        }
    }
}
