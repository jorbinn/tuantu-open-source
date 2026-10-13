import 'dart:io';

import 'package:flutter/services.dart';

/// Native code creates a durable local directory and verifies its backup flag
/// before Dart may create a database or accept any uploaded media.
Future<Directory> prepareIosBoxStorage({
  MethodChannel channel = const MethodChannel('dev.tuantu/box'),
}) async {
  final value =
      await channel.invokeMapMethod<String, dynamic>('prepareStorage');
  final path = value?['path'];
  if (value?['backupExcluded'] != true ||
      path is! String ||
      !path.startsWith('/') ||
      path == '/') {
    throw StateError('无法确认盒子数据已排除 iCloud 备份，未开启盒子');
  }
  final root = Directory(path);
  if (!await root.exists()) {
    throw StateError('盒子的本机存储目录不可用');
  }
  return root;
}
