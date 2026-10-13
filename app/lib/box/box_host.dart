/// 安卓前台服务：让本机盒子在后台不被杀掉。
library;

import 'dart:io';

import 'package:flutter/services.dart';

class BoxHost {
  static const _m = MethodChannel('dev.tuantu/box');

  // Network binding/settings remain Android-only.
  static bool get supported => Platform.isAndroid;
  static bool get hostingSupported => Platform.isAndroid || Platform.isIOS;

  static Future<void> start() async {
    if (!hostingSupported) return;
    await _m.invokeMethod('start');
  }

  static Future<void> stop() async {
    if (!hostingSupported) return;
    await _m.invokeMethod('stop');
  }

  static Future<void> openWifiSettings() async {
    if (!supported) return;
    await _m.invokeMethod('openWifiSettings');
  }

  /// 无外网热点时把流量绑到 Wi-Fi，否则会走 4G，连不上盒子。
  static Future<bool> bindWifi() async {
    if (!supported) return false;
    try {
      return await _m
              .invokeMethod('bindWifi')
              .timeout(const Duration(seconds: 5), onTimeout: () => false) ==
          true;
    } catch (_) {
      return false;
    }
  }

  static Future<List<String>> lanIps() async {
    if (!supported) return const [];
    try {
      final v = await _m.invokeMethod('lanIps');
      if (v is List) {
        return [for (final e in v) e.toString()];
      }
    } catch (_) {}
    return const [];
  }

  /// 从视频抽一帧写成 JPEG。失败返回 null。
  static Future<Map<String, int>?> videoThumb({
    required String src,
    required String dest,
    int maxWidth = 480,
  }) async {
    if (!hostingSupported) return null;
    try {
      final v = await _m.invokeMethod('videoThumb', {
        'src': src,
        'dest': dest,
        'maxWidth': maxWidth,
      }).timeout(const Duration(seconds: 8));
      if (v is Map && v['ok'] == true) {
        return {
          'width': (v['width'] as num?)?.toInt() ?? 0,
          'height': (v['height'] as num?)?.toInt() ?? 0,
        };
      }
    } catch (_) {}
    return null;
  }

  /// 网关 / DHCP / 本机地址。热点上盒子往往不是 x.x.x.1。
  static Future<List<String>> boxHints() async {
    if (!supported) return const [];
    try {
      final v = await _m.invokeMethod('boxHints');
      if (v is List) {
        return [for (final e in v) e.toString()];
      }
    } catch (_) {}
    return lanIps();
  }
}
