import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

class HotspotProfile {
  const HotspotProfile(this.ssid, this.passphrase);
  static const bundled = HotspotProfile(
    String.fromEnvironment('TUANTU_HOTSPOT_SSID'),
    String.fromEnvironment('TUANTU_HOTSPOT_PASSWORD'),
  );
  final String ssid;
  final String passphrase;
  bool get available => ssid.isNotEmpty && utf8.encode(ssid).length <= 32 &&
      passphrase.length >= 8 && passphrase.length <= 63;
  // Never include a Wi-Fi credential in diagnostics or error messages.
  @override
  String toString() => 'HotspotProfile(configured: $available)';
}

class WifiState {
  const WifiState({this.known = false, this.enabled = true,
    this.connected = false, this.ssid});
  final bool known;
  final bool enabled;
  final bool connected;
  final String? ssid;
  String? get networkName {
    final value = ssid?.replaceAll(RegExp(r'^"|"$'), '');
    return value == null || value.isEmpty || value == '<unknown ssid>'
        ? null : value;
  }
  bool canDiscover(HotspotProfile profile, {bool targetApproved = false}) {
    if (!profile.available) return !known || connected;
    return connected && (networkName == profile.ssid ||
        (networkName == null && targetApproved));
  }
  factory WifiState.fromMap(Map<dynamic, dynamic> value) => WifiState(
    known: true, enabled: value['enabled'] != false,
    connected: value['connected'] == true, ssid: value['ssid'] as String?,
  );
}

class HotspotAccess {
  HotspotAccess({MethodChannel? channel, bool? supported})
      : _channel = channel ?? const MethodChannel('dev.tuantu/hotspot'),
        supported = supported ?? (Platform.isAndroid || Platform.isIOS);
  static final I = HotspotAccess();
  final MethodChannel _channel;
  final bool supported;
  Future<WifiState> state() async {
    if (!supported) return const WifiState();
    try {
      final value = await _channel.invokeMapMethod('state')
          .timeout(const Duration(seconds: 3));
      return value == null ? const WifiState() : WifiState.fromMap(value);
    } catch (_) {
      // Unknown must not be treated as confirmed Wi-Fi-off or block manual use.
      return const WifiState();
    }
  }
  Future<String> join(HotspotProfile profile) async {
    if (!supported || !profile.available) return 'manual';
    try {
      return await _channel.invokeMethod<String>('join', {
        'ssid': profile.ssid, 'passphrase': profile.passphrase,
      }).timeout(const Duration(seconds: 60)) ?? 'unavailable';
    } on TimeoutException {
      await cancelPending();
      return 'timeout';
    } catch (_) {
      return 'unavailable';
    }
  }
  Future<void> cancelPending() async {
    if (!supported) return;
    try { await _channel.invokeMethod('cancelPending'); } catch (_) {}
  }
  Future<void> openSettings() async {
    if (!supported) return;
    try { await _channel.invokeMethod('openSettings'); } catch (_) {}
  }
}
