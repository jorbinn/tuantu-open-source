/// Android Storage Access Framework bridge for camera cards and USB storage.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CardMedia {
  const CardMedia({
    required this.uri,
    required this.name,
    required this.relativePath,
    required this.size,
    required this.takenAt,
    required this.isVideo,
    required this.isRaw,
  });

  final String uri;
  final String name;
  final String relativePath;
  final int size;
  final int takenAt;
  final bool isVideo;
  final bool isRaw;

  String get day {
    // 相机没设时钟会写 0000:00:00（负秒数/远古年份）；超出 DateTime 范围
    // 会抛 RangeError。一律归到「日期未知」。
    if (takenAt <= 0 || takenAt > 8640000000000) return '日期未知';
    final d = DateTime.fromMillisecondsSinceEpoch(takenAt * 1000, isUtc: true);
    if (d.year < 1900 || d.year > 9999) return '日期未知';
    String p(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)}';
  }

  factory CardMedia.fromMap(Map<Object?, Object?> m) => CardMedia(
        uri: (m['uri'] ?? '').toString(),
        name: (m['name'] ?? '').toString(),
        relativePath: (m['path'] ?? '').toString(),
        size: (m['size'] as num?)?.toInt() ?? 0,
        takenAt: (m['takenAt'] as num?)?.toInt() ?? 0,
        isVideo: m['isVideo'] == true,
        isRaw: m['isRaw'] == true,
      );
}

class CardReader {
  CardReader._() {
    if (supported) _channel.setMethodCallHandler(_nativeCall);
  }

  static final CardReader I = CardReader._();
  static const _channel = MethodChannel('dev.tuantu/card_reader');
  static const _treePref = 'card_reader_tree_uri';
  static const _treeNamePref = 'card_reader_tree_name';

  bool get supported => Platform.isAndroid;
  void Function()? onStorageMounted;

  Future<void> _nativeCall(MethodCall call) async {
    if (call.method == 'storageMounted') onStorageMounted?.call();
  }

  Future<({String uri, String name})?> chooseTree() async {
    if (!supported) return null;
    final raw = await _channel.invokeMethod<Object?>('pickTree');
    if (raw is! Map) return null;
    final uri = (raw['uri'] ?? '').toString();
    if (uri.isEmpty) return null;
    final name = (raw['name'] ?? '存储卡').toString();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_treePref, uri);
    await prefs.setString(_treeNamePref, name);
    return (uri: uri, name: name);
  }

  Future<({String uri, String name})?> savedTree() async {
    final prefs = await SharedPreferences.getInstance();
    final uri = prefs.getString(_treePref);
    if (uri == null || uri.isEmpty) return null;
    return (uri: uri, name: prefs.getString(_treeNamePref) ?? '存储卡');
  }

  Future<List<CardMedia>> scan(String uri) async {
    final raw = await _channel.invokeMethod<Object?>('scanTree', {'uri': uri});
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) CardMedia.fromMap(e)
    ];
  }

  Future<String?> thumbnail(String uri) async {
    try {
      return await _channel.invokeMethod<String>('thumbnail', {'uri': uri});
    } catch (_) {
      return null;
    }
  }

  Future<String> copyToCache(String uri, String name) async {
    final path = await _channel
        .invokeMethod<String>('copyToCache', {'uri': uri, 'name': name});
    if (path == null || path.isEmpty) throw '存储卡文件无法读取';
    return path;
  }

  Future<({int boxFree, int cacheFree})?> space() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('space');
      if (raw is! Map) return null;
      return (
        boxFree: (raw['boxFree'] as num?)?.toInt() ?? 0,
        cacheFree: (raw['cacheFree'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> consumeMountIntent() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('consumeMountIntent') == true;
    } catch (_) {
      return false;
    }
  }
}
