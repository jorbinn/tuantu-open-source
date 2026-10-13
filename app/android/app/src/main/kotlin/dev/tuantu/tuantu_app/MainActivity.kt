package dev.tuantu.tuantu_app

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.VpnService
import android.os.Build
import java.io.File
import java.io.FileOutputStream
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import dev.tuantu.tuantu_app.vpn.ProxyVpnService
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val hotspot = HotspotBridge(this)
    private val cardReader = CardReaderBridge(this)
    private var vpnResult: MethodChannel.Result? = null
    private val vpnLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { res ->
        vpnResult?.success(res.resultCode == Activity.RESULT_OK)
        vpnResult = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "dev.tuantu/hotspot").setMethodCallHandler { call, result ->
            when (call.method) {
                "state" -> result.success(hotspot.state())
                "join" -> hotspot.join(call.argument<String>("ssid") ?: "",
                    call.argument<String>("passphrase") ?: "", result)
                "cancelPending" -> { hotspot.cancelPending(); result.success(null) }
                "openSettings" -> { hotspot.openSettings(); result.success(null) }
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, "dev.tuantu/proxy").setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(true)
                "hasCellular" -> result.success(ProxyVpnService.hasCellular(this))
                "isRunning" -> result.success(ProxyVpnService.running)
                "prepare" -> {
                    if (Build.VERSION.SDK_INT >= 33 &&
                        ContextCompat.checkSelfPermission(
                            this, Manifest.permission.POST_NOTIFICATIONS
                        ) != PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS), 41
                        )
                    }
                    val i: Intent? = VpnService.prepare(this)
                    if (i == null) {
                        result.success(true)
                    } else {
                        vpnResult = result
                        vpnLauncher.launch(i)
                    }
                }
                "start" -> {
                    ProxyVpnService.start(this)
                    result.success(null)
                }
                "stop" -> {
                    ProxyVpnService.stop(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, "dev.tuantu/box").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    if (Build.VERSION.SDK_INT >= 33 &&
                        ContextCompat.checkSelfPermission(
                            this, Manifest.permission.POST_NOTIFICATIONS
                        ) != PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS), 42
                        )
                    }
                    BoxHostService.start(this)
                    result.success(null)
                }
                "stop" -> {
                    BoxHostService.stop(this)
                    result.success(null)
                }
                "isRunning" -> result.success(BoxHostService.running)
                "openWifiSettings" -> {
                    BoxHostService.openWifiSettings(this)
                    result.success(null)
                }
                "bindWifi" -> {
                    BoxHostService.bindWifi(this) { ok ->
                        runOnUiThread { result.success(ok) }
                    }
                }
                "lanIps" -> result.success(BoxHostService.lanIps())
                "boxHints" -> result.success(BoxHostService.boxHints(this))
                "imageThumb" -> {
                    ImageThumb.extractAsync(call.argument<String>("src") ?: "") { out ->
                        runOnUiThread { result.success(out) }
                    }
                }
                "videoThumb" -> {
                    val src = call.argument<String>("src") ?: ""
                    val dest = call.argument<String>("dest") ?: ""
                    val maxWidth = call.argument<Int>("maxWidth") ?: 480
                    VideoThumb.extractAsync(src, dest, maxWidth) { out ->
                        runOnUiThread { result.success(out) }
                    }
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "dev.tuantu/proxy_state").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    ProxyVpnService.sink = sink
                    sink.success(ProxyVpnService.running)
                }

                override fun onCancel(args: Any?) {
                    ProxyVpnService.sink = null
                }
            }
        )
        MethodChannel(messenger, "dev.tuantu/media").setMethodCallHandler { call, result ->
            if (call.method == "livePhotoProfile") {
                result.success(LiveVideoCodec.targetProfile())
                return@setMethodCallHandler
            }
            if (call.method == "stampLiveStill") {
                val dest = call.argument<String>("dest") ?: ""
                val profile = call.argument<String>("profile") ?: LiveVideoCodec.targetProfile()
                Thread {
                    try {
                        LiveVideoCodec.stampStillOwner(dest, profile)
                        runOnUiThread { result.success(dest) }
                    } catch (e: Exception) {
                        runOnUiThread {
                            result.error("stampLiveStill", e.message, null)
                        }
                    }
                }.start()
                return@setMethodCallHandler
            }
            if (call.method == "normalizeLiveVideo") {
                val src = call.argument<String>("src") ?: ""
                val dest = call.argument<String>("dest") ?: ""
                val profile = call.argument<String>("profile") ?: LiveVideoCodec.targetProfile()
                Thread {
                    val ok = LiveVideoCodec.prepareLiveVideo(
                        src,
                        dest,
                        profile,
                        this.assets,
                    )
                    runOnUiThread {
                        if (ok) result.success(dest)
                        else result.error("normalizeLiveVideo", "remux failed", null)
                    }
                }.start()
                return@setMethodCallHandler
            }
            if (call.method == "isRecognizedMotionPhoto") {
                val path = call.argument<String>("path") ?: ""
                val profile = call.argument<String>("profile") ?: LiveVideoCodec.targetProfile()
                result.success(LiveVideoCodec.galleryRecognizesMotionPhoto(this, path, profile))
                return@setMethodCallHandler
            }
            if (call.method == "validateLiveVideo") {
                val src = call.argument<String>("src") ?: ""
                Thread {
                    val valid = LiveVideoCodec.validateDecodable(src)
                    runOnUiThread { result.success(valid) }
                }.start()
                return@setMethodCallHandler
            }
            if (call.method != "stillToJpeg") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val src = call.argument<String>("src") ?: ""
            val dest = call.argument<String>("dest") ?: ""
            val profile = call.argument<String>("profile") ?: LiveVideoCodec.targetProfile()
            Thread {
                try {
                    val bmp = StillImageCodec.decode(src)
                        ?: throw IllegalStateException("decode failed")
                    File(dest).parentFile?.mkdirs()
                    try {
                        FileOutputStream(dest).use { out ->
                            if (!bmp.compress(Bitmap.CompressFormat.JPEG, 92, out)) {
                                throw IllegalStateException("jpeg compress failed")
                            }
                        }
                        LiveVideoCodec.stampStillOwner(dest, profile)
                    } finally {
                        bmp.recycle()
                    }
                    runOnUiThread { result.success(dest) }
                } catch (e: Exception) {
                    runOnUiThread {
                        result.error("stillToJpeg", e.message, null)
                    }
                }
            }.start()
        }
        cardReader.configure(messenger)
    }

    override fun onDestroy() {
        hotspot.close()
        cardReader.dispose()
        super.onDestroy()
    }
}
