/// 安卓「代理模式」：连盒子热点时，其它 App 仍走自己的 4G。
/// 系统会显示 VPN 授权，实际是本机分流，流量不过任何服务器。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ProxyMode {
  static const _m = MethodChannel('dev.tuantu/proxy');
  static const _e = EventChannel('dev.tuantu/proxy_state');
  static const prefEnabled = 'proxy_enabled';
  static const prefAsked = 'proxy_asked';

  static bool get supported => Platform.isAndroid;

  static Future<bool> isRunning() async {
    if (!supported) return false;
    return await _m.invokeMethod('isRunning') == true;
  }

  static Future<bool> hasCellular() async {
    if (!supported) return false;
    return await _m.invokeMethod('hasCellular') == true;
  }

  static Future<bool> prepare() async {
    if (!supported) return false;
    return await _m.invokeMethod('prepare') == true;
  }

  /// 成功返回 null，失败返回原因。
  static Future<String?> start() async {
    if (!supported) return '仅安卓可用';
    if (!await hasCellular()) {
      return '请先打开手机的移动数据，再开代理。连上没网的热点后，系统可能把 4G 挂起，开一下飞行模式再关即可拉回。';
    }
    if (!await prepare()) return '需要允许「VPN 连接」才能分流';
    await _m.invokeMethod('start');
    for (var i = 0; i < 50; i++) {
      if (await isRunning()) return null;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return '启动失败。请确认移动数据开着，并关掉 Clash / 公司 VPN 再试';
  }

  static Future<void> stop() async {
    if (!supported) return;
    await _m.invokeMethod('stop');
  }

  static Stream<bool> runningStream() {
    if (!supported) return Stream.value(false);
    return _e.receiveBroadcastStream().map((e) => e == true);
  }

  static Future<bool> enabledPref() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(prefEnabled) ?? false;
  }

  static Future<void> setEnabledPref(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(prefEnabled, v);
  }

  static Future<bool> askedPref() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(prefAsked) ?? false;
  }

  static Future<void> markAsked() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(prefAsked, true);
  }

  static Future<String?> autostart() async {
    if (!supported) return null;
    if (!await enabledPref()) return null;
    if (await isRunning()) return null;
    return start();
  }

  /// 第一次弹出说明；已选过则按偏好自动开。
  static Future<String?> askIfNeeded(BuildContext context) async {
    if (!supported) return null;
    if (await askedPref()) return autostart();
    if (!context.mounted) return null;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('连盒子时微信还能上网？'),
        content: const Text(
          '团长的盒子没有外网。开启「代理模式」后：\n\n'
          '· 微信、地图走你自己的 4G\n'
          '· 传照片仍走热点，不耗流量\n\n'
          '系统会问是否允许 VPN——点允许即可。'
          '这是手机本地分流，不是翻墙，流量不过任何服务器。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('暂不'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开启'),
          ),
        ],
      ),
    );
    await markAsked();
    if (go == true) {
      await setEnabledPref(true);
      return start();
    }
    await setEnabledPref(false);
    return null;
  }
}
