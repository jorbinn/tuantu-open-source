/// 设备身份：名称只是展示文字，真正的账号键由安装时生成并永久保存。
library;

import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

class DeviceIdentity {
  static const deviceIdKey = 'device_id';
  static const displayNameKey = 'name';

  static Future<String> ensureId() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(deviceIdKey)?.trim() ?? '';
    if (saved.isNotEmpty) return saved;
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    // UUID v4 的版本位和变体位，服务端只把它当不透明稳定标识。
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final id = '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
    await prefs.setString(deviceIdKey, id);
    return id;
  }

  static Future<String?> savedName() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(displayNameKey)?.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  static Future<void> saveName(String value) async {
    final name = value.trim();
    if (name.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(displayNameKey, name);
  }
}
