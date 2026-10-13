package dev.tuantu.tuantu_app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.provider.Settings
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel

/** System-approved, local-only Wi-Fi. Keep the request alive after navigation. */
class HotspotBridge(private val activity: MainActivity) {
    private val cm get() = activity.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val wm get() = activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private var reply: MethodChannel.Result? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var network: Network? = null
    private var ssid: String? = null
    private var requestAfterPermission: (() -> Unit)? = null
    private val permissions = activity.registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { result ->
        val next = requestAfterPermission
        requestAfterPermission = null
        if (reply == null) return@registerForActivityResult
        if (result.values.all { it }) next?.invoke() else finish("permission_denied")
    }

    fun state(): Map<String, Any> {
        val connected = cm.allNetworks.any { n ->
            cm.getNetworkCapabilities(n)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true &&
                cm.getLinkProperties(n)?.linkAddresses?.isNotEmpty() == true
        }
        val out = mutableMapOf<String, Any>("enabled" to wm.isWifiEnabled, "connected" to connected)
        val current = if (network != null && cm.getNetworkCapabilities(network) != null) ssid else {
            @Suppress("DEPRECATION")
            val value = try { wm.connectionInfo?.ssid?.trim('"') } catch (_: Exception) { null }
            value?.takeUnless { it == "<unknown ssid>" || it.isEmpty() }
        }
        if (connected && current != null) out["ssid"] = current
        return out
    }

    fun join(target: String, passphrase: String, result: MethodChannel.Result) {
        if (reply != null) { result.success("busy"); return }
        if (Build.VERSION.SDK_INT < 29) { result.success("manual"); return }
        if (!wm.isWifiEnabled) { result.success("wifi_off"); return }
        if (target.isEmpty() || target.toByteArray(Charsets.UTF_8).size > 32 || passphrase.length !in 8..63) {
            result.success("invalid_config"); return
        }
        if (state()["ssid"] == target && state()["connected"] == true) {
            result.success("connected"); return
        }
        reply = result
        val required = if (Build.VERSION.SDK_INT >= 33) {
            arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        }
        val connect = {
            if (Build.VERSION.SDK_INT < 33) {
                val location = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager
                if (!location.isLocationEnabled) {
                    finish("location_off")
                } else request(target, passphrase)
            } else request(target, passphrase)
        }
        if (required.all { ContextCompat.checkSelfPermission(activity, it) == PackageManager.PERMISSION_GRANTED }) {
            connect()
        } else {
            requestAfterPermission = connect
            permissions.launch(required)
        }
    }

    private fun request(target: String, passphrase: String) {
        if (Build.VERSION.SDK_INT < 29 || reply == null) return
        releaseNetwork()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(n: Network) = activity.runOnUiThread {
                if (callback !== this) return@runOnUiThread
                network = n
                ssid = target
                if (cm.bindProcessToNetwork(n)) finish("connected") else {
                    releaseNetwork(); finish("unavailable")
                }
            }
            override fun onUnavailable() = activity.runOnUiThread {
                if (callback !== this) return@runOnUiThread
                releaseNetwork()
                finish("unavailable")
            }
            override fun onLost(n: Network) = activity.runOnUiThread {
                if (callback !== this) return@runOnUiThread
                releaseNetwork()
                finish("unavailable")
            }
        }
        callback = cb
        try {
            val specifier = WifiNetworkSpecifier.Builder().setSsid(target)
                .setWpa2Passphrase(passphrase).build()
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .setNetworkSpecifier(specifier).build()
            cm.requestNetwork(request, cb, 30000)
        } catch (_: SecurityException) {
            releaseNetwork(); finish("permission_denied")
        } catch (_: Exception) {
            releaseNetwork(); finish("unavailable")
        }
    }
    private fun finish(code: String) {
        val result = reply
        reply = null
        requestAfterPermission = null
        result?.success(code)
    }
    fun cancelPending() {
        if (reply == null) return // Successful network stays alive on entering Home.
        releaseNetwork()
        finish("cancelled")
    }
    private fun releaseNetwork() {
        callback?.let { try { cm.unregisterNetworkCallback(it) } catch (_: Exception) {} }
        callback = null
        if (network != null && cm.boundNetworkForProcess == network) cm.bindProcessToNetwork(null)
        network = null
        ssid = null
    }
    fun close() { cancelPending(); releaseNetwork() }
    fun openSettings() {
        val action = if (Build.VERSION.SDK_INT >= 29) Settings.Panel.ACTION_WIFI else Settings.ACTION_WIFI_SETTINGS
        try { activity.startActivity(Intent(action)) }
        catch (_: Exception) { activity.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS)) }
    }
}
