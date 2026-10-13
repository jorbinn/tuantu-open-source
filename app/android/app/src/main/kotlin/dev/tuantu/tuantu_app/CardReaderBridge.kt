package dev.tuantu.tuantu_app

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.media.ExifInterface
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.hardware.usb.UsbManager
import android.util.Size
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.Executors

/** Android Storage Access Framework bridge used by the on-box card importer. */
class CardReaderBridge(private val activity: FlutterFragmentActivity) {
    private var channel: MethodChannel? = null
    private var pickerResult: MethodChannel.Result? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val thumbWorker = Executors.newFixedThreadPool(2)
    private var receiverRegistered = false

    private val picker = activity.registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { res ->
        val pending = pickerResult ?: return@registerForActivityResult
        pickerResult = null
        val uri = res.data?.data
        if (res.resultCode != Activity.RESULT_OK || uri == null) {
            pending.success(null)
            return@registerForActivityResult
        }
        try {
            val flags = res.data!!.flags and
                (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            activity.contentResolver.takePersistableUriPermission(uri, flags)
        } catch (_: Exception) {
            try {
                activity.contentResolver.takePersistableUriPermission(
                    uri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: Exception) {}
        }
        pending.success(mapOf("uri" to uri.toString(), "name" to displayName(uri)))
    }

    private val mountedReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            channel?.invokeMethod("storageMounted", intent?.action)
        }
    }
    private val mediaReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            channel?.invokeMethod("storageMounted", intent?.action)
        }
    }

    fun configure(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "dev.tuantu/card_reader")
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickTree" -> pickTree(result)
                "scanTree" -> background(result) {
                    scanTree(Uri.parse(call.argument<String>("uri") ?: ""))
                }
                "thumbnail" -> background(result, thumbWorker) {
                    thumbnail(Uri.parse(call.argument<String>("uri") ?: ""))
                }
                "copyToCache" -> background(result) {
                    copyToCache(
                        Uri.parse(call.argument<String>("uri") ?: ""),
                        call.argument<String>("name") ?: "media"
                    )
                }
                "space" -> result.success(mapOf(
                    "boxFree" to StatFs(activity.getExternalFilesDir(null)?.path ?: activity.filesDir.path).availableBytes,
                    "cacheFree" to StatFs(activity.cacheDir.path).availableBytes
                ))
                "consumeMountIntent" -> {
                    val attached = activity.intent?.action == UsbManager.ACTION_USB_DEVICE_ATTACHED
                    if (attached) activity.intent?.action = null
                    result.success(attached)
                }
                else -> result.notImplemented()
            }
        }
        registerReceiver()
    }

    fun dispose() {
        if (receiverRegistered) {
            try { activity.unregisterReceiver(mountedReceiver) } catch (_: Exception) {}
            try { activity.unregisterReceiver(mediaReceiver) } catch (_: Exception) {}
            receiverRegistered = false
        }
        worker.shutdown()
        thumbWorker.shutdown()
        channel = null
    }

    private fun registerReceiver() {
        if (receiverRegistered) return
        val usb = IntentFilter(UsbManager.ACTION_USB_DEVICE_ATTACHED)
        ContextCompat.registerReceiver(
            activity, mountedReceiver, usb, ContextCompat.RECEIVER_EXPORTED
        )
        val media = IntentFilter().apply {
            addAction(Intent.ACTION_MEDIA_MOUNTED)
            addDataScheme("file")
        }
        ContextCompat.registerReceiver(
            activity, mediaReceiver, media, ContextCompat.RECEIVER_EXPORTED
        )
        receiverRegistered = true
    }

    private fun pickTree(result: MethodChannel.Result) {
        if (pickerResult != null) {
            result.error("busy", "已经在选择存储卡", null)
            return
        }
        pickerResult = result
        picker.launch(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        })
    }

    private fun background(
        result: MethodChannel.Result,
        executor: java.util.concurrent.ExecutorService = worker,
        action: () -> Any?
    ) {
        executor.execute {
            try {
                val value = action()
                activity.runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                activity.runOnUiThread {
                    result.error("card_reader", e.message ?: e.javaClass.simpleName, null)
                }
            }
        }
    }

    private fun scanTree(tree: Uri): List<Map<String, Any?>> {
        if (tree.toString().isBlank()) return emptyList()
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        val out = ArrayList<Map<String, Any?>>()
        scanChildren(tree, rootId, "", out)
        return out.sortedByDescending { (it["takenAt"] as? Long) ?: 0L }
    }

    private fun scanChildren(
        tree: Uri,
        parentId: String,
        relative: String,
        out: MutableList<Map<String, Any?>>
    ) {
        if (out.size >= 20000) return
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED
        )
        activity.contentResolver.query(children, projection, null, null, null)?.use { c ->
            while (c.moveToNext() && out.size < 20000) {
                val id = c.getString(0)
                val name = c.getString(1) ?: continue
                val mime = c.getString(2) ?: ""
                val size = if (c.isNull(3)) 0L else c.getLong(3)
                val modified = if (c.isNull(4)) 0L else c.getLong(4)
                val childRelative = if (relative.isEmpty()) name else "$relative/$name"
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    scanChildren(tree, id, childRelative, out)
                    continue
                }
                val ext = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
                if (!supportedExtensions.contains(ext)) continue
                val uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)
                val taken = readTakenAt(uri, mime, modified)
                out.add(mapOf(
                    "uri" to uri.toString(),
                    "name" to name,
                    "path" to childRelative,
                    "mime" to mime,
                    "size" to size,
                    "modified" to modified,
                    "takenAt" to taken,
                    "isVideo" to videoExtensions.contains(ext),
                    "isRaw" to rawExtensions.contains(ext)
                ))
            }
        }
    }

    private fun readTakenAt(uri: Uri, mime: String, fallbackMillis: Long): Long {
        var millis = 0L
        try {
            if (mime.startsWith("image/") && Build.VERSION.SDK_INT >= 24) {
                activity.contentResolver.openFileDescriptor(uri, "r")?.use { fd ->
                    val exif = ExifInterface(fd.fileDescriptor)
                    val raw = exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL)
                        ?: exif.getAttribute(ExifInterface.TAG_DATETIME)
                    if (!raw.isNullOrBlank()) {
                        val format = SimpleDateFormat("yyyy:MM:dd HH:mm:ss", Locale.US)
                        format.timeZone = TimeZone.getTimeZone("UTC")
                        millis = format.parse(raw)?.time ?: 0L
                    }
                }
            } else if (mime.startsWith("video/")) {
                activity.contentResolver.openFileDescriptor(uri, "r")?.use { fd ->
                    val mmr = MediaMetadataRetriever()
                    try {
                        mmr.setDataSource(fd.fileDescriptor)
                        val raw = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DATE)
                        if (!raw.isNullOrBlank()) {
                            val compact = raw.take(15)
                            val format = SimpleDateFormat("yyyyMMdd'T'HHmmss", Locale.US)
                            format.timeZone = TimeZone.getTimeZone("UTC")
                            millis = format.parse(compact)?.time ?: 0L
                        }
                    } finally { mmr.release() }
                }
            }
        } catch (_: Exception) {}
        if (millis <= 0L) millis = wallClockMillis(fallbackMillis)
        return if (millis > 0L) millis / 1000L else 0L
    }

    private fun wallClockMillis(epochMillis: Long): Long {
        if (epochMillis <= 0L) return 0L
        val local = Calendar.getInstance().apply { timeInMillis = epochMillis }
        return Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            clear()
            set(
                local.get(Calendar.YEAR), local.get(Calendar.MONTH),
                local.get(Calendar.DAY_OF_MONTH), local.get(Calendar.HOUR_OF_DAY),
                local.get(Calendar.MINUTE), local.get(Calendar.SECOND)
            )
        }.timeInMillis
    }

    private fun thumbnail(uri: Uri): String? {
        if (Build.VERSION.SDK_INT < 29) return null
        val bmp = activity.contentResolver.loadThumbnail(uri, Size(360, 360), null)
        val dir = File(activity.cacheDir, "card_thumbs").apply { mkdirs() }
        val file = File(dir, "${uri.toString().hashCode()}.jpg")
        FileOutputStream(file).use { bmp.compress(Bitmap.CompressFormat.JPEG, 82, it) }
        bmp.recycle()
        return file.absolutePath
    }

    private fun copyToCache(uri: Uri, originalName: String): String {
        val clean = originalName.replace(Regex("[^A-Za-z0-9._() -]"), "_")
        val dir = File(activity.cacheDir, "card_import").apply { mkdirs() }
        val file = File(dir, "${UUID.randomUUID()}_$clean")
        val input = activity.contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("无法读取 $originalName")
        input.use { src -> FileOutputStream(file).use { dest -> src.copyTo(dest, 1024 * 1024) } }
        return file.absolutePath
    }

    private fun displayName(uri: Uri): String {
        try {
            activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { c -> if (c.moveToFirst()) return c.getString(0) ?: "存储卡" }
        } catch (_: Exception) {}
        return "存储卡"
    }

    companion object {
        private val videoExtensions = setOf(
            "mp4", "mov", "m4v", "mkv", "avi", "3gp", "webm", "ts", "mpg", "mpeg"
        )
        private val rawExtensions = setOf(
            "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "raf", "pef", "srw", "x3f", "3fr", "iiq"
        )
        private val supportedExtensions = setOf(
            "jpg", "jpeg", "png", "webp", "gif", "bmp", "tif", "tiff", "heic", "heif", "avif"
        ) + videoExtensions + rawExtensions
    }
}
