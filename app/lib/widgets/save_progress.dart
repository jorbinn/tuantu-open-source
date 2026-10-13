/// 下载入口：完成重复确认和权限检查后交给后台下载队列。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../download.dart';
import '../saver.dart';

Future<String> queueDownload(
  BuildContext context,
  CardItem item, {
  bool confirmRepeat = true,
}) async {
  if (confirmRepeat) {
    final alreadySaved = await Saver.alreadySaved(item);
    if (!context.mounted) return '已取消保存';
    if (alreadySaved) {
      final subject = item.kind == 'video' ? '这个视频' : '这张图片';
      final repeat = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('已下载'),
          content: Text('$subject已经下载过，是否重复保存？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('重复保存'),
            ),
          ],
        ),
      );
      if (repeat != true || !context.mounted) return '已取消保存';
    }
  }
  final permissionError = await Saver.ensurePermission();
  if (permissionError != null) throw permissionError;
  final result = DownloadStore.I.add(item, allowDuplicate: true);
  unawaited(DownloadStore.I.run());
  return result.added ? '已加入下载列表' : '已在下载列表中';
}

Future<int> queueDownloads(Iterable<CardItem> items) async {
  final permissionError = await Saver.ensurePermission();
  if (permissionError != null) throw permissionError;
  final added = DownloadStore.I.addAll(items, allowDuplicate: true);
  unawaited(DownloadStore.I.run());
  return added;
}
