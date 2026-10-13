/// 上传前准备：文件名+日期去重，以及大视频确认阈值。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const videoWarnBytes = 100 * 1024 * 1024;

const videoExts = {
  'mp4',
  'mov',
  'm4v',
  'mkv',
  'avi',
  '3gp',
  'webm',
  'ts',
  'mpg',
  'mpeg',
};

/// 盒子能直接解码出缩略图的格式。HEIC/HEIF/AVIF/TIFF 需要客户端带预览。
const previewExts = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'};

class PickedMedia {
  const PickedMedia({
    required this.path,
    required this.name,
    required this.day,
    required this.isVideo,
    required this.size,
    this.livePath,
    this.previewPath,
    this.takenAt,
    this.liveRequired = false,
    this.ownedFiles = const [],
  });

  final String path;
  final String name;
  final String day;
  final bool isVideo;
  final int size;
  final String? livePath;
  final bool liveRequired;

  /// Exact temporary files created by this selection, never album originals.
  final List<String> ownedFiles;
  Future<void> releaseOwnedFiles() async {
    for (final path in ownedFiles) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// 兼容预览（JPEG）：HEIC/视频等盒子解不动的格式，由本机生成一帧/一张。
  final String? previewPath;

  /// 拍摄时间（墙钟按 UTC 解释的 unix 秒），服务端可选字段，修正时间线归属。
  final int? takenAt;
}

/// 客户端随上传发送的元数据 JSON（旧盒子会忽略未知字段）。
String? buildUploadMeta(Iterable<PickedMedia> items) {
  final map = <String, dynamic>{};
  for (final m in items) {
    if (m.takenAt == null) continue;
    map[m.name] = {'taken_at': m.takenAt};
  }
  if (map.isEmpty) return null;
  return jsonEncode(map);
}

String mediaDay(DateTime d) {
  String p(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${p(d.month)}-${p(d.day)}';
}

/// 相册时间转「墙钟按 UTC 解释」的 unix 秒，与服务端 EXIF 解析口径一致。
int wallClockUtcSeconds(DateTime d) {
  return DateTime.utc(d.year, d.month, d.day, d.hour, d.minute, d.second)
          .millisecondsSinceEpoch ~/
      1000;
}

String uploadKey(String name, String day) =>
    '${name.trim().toLowerCase()}|$day';

bool isVideoName(String name) {
  final i = name.lastIndexOf('.');
  if (i < 0) return false;
  return videoExts.contains(name.substring(i + 1).toLowerCase());
}

bool shouldWarnVideos({required int videoCount, required int videoBytes}) =>
    videoCount > 2 || videoBytes > videoWarnBytes;

List<PickedMedia> excludeUploaded(List<PickedMedia> items, Set<String> keys) {
  return [
    for (final m in items)
      if (!keys.contains(uploadKey(m.name, m.day))) m
  ];
}

/// iOS 相册 ID 常含 `/L0/001` 这类斜杠，不能直接拼进临时文件名。
String compatiblePreviewFileName(String assetId, {int? nowMs}) {
  final ms = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final digest =
      sha256.convert(utf8.encode(assetId)).toString().substring(0, 16);
  return 'tuantu_preview_${digest}_$ms.jpg';
}

/// 安卓 Motion Photo 预览用的临时视频名。
///
/// 相册 ID 可能含 `/`，并且同一张图反复打开时应复用同一临时路径，避免
/// 每次预览都在缓存目录留下一个新文件。
String motionPreviewFileName(String assetId) {
  final digest =
      sha256.convert(utf8.encode(assetId)).toString().substring(0, 16);
  return 'tuantu_motion_preview_$digest.mp4';
}

/// iOS 上传用的文件名：`原名主干_<相册ID哈希8位>.<实际文件扩展名>`。
///
/// 教训（iOS 27）：实况照片的名字来自 PHAssetResource.originalFilename，
/// 有编辑/渲染版本的资源一律叫 `FullSizeRender.*`；导出的临时文件叫
/// `still.*`。盒子和客户端都按「作者+文件名+拍摄日」去重，于是同一天的
/// 第 N 张起全部撞名被当成「重复」。按相册 ID 追加稳定哈希后：
/// - 不同照片永远不同名（不再误判重复）；
/// - 同一张照片每次选择名字相同（真正的重复仍能被跳过）；
/// - 扩展名取实际上传文件，盒子按扩展名判断类型/预览不受影响。
/// 只在 iOS 调用；安卓命名保持不变。
String iosUploadName({
  required String assetId,
  required String filePath,
  String? preferredName,
}) {
  String lastSegment(String s) => s.split(RegExp(r'[\\/]')).last.trim();
  String extOf(String s) {
    final i = s.lastIndexOf('.');
    return i >= 0 && i < s.length - 1 ? s.substring(i + 1) : '';
  }

  final fileBase = lastSegment(filePath);
  final preferred = lastSegment(preferredName ?? '');
  final base = preferred.isNotEmpty ? preferred : fileBase;
  final ext = extOf(fileBase).isNotEmpty ? extOf(fileBase) : extOf(base);
  var stem = extOf(base).isNotEmpty
      ? base.substring(0, base.length - extOf(base).length - 1)
      : base;
  stem = stem.replaceAll(RegExp(r'[\x00-\x1f]'), '').trim();
  if (stem.isEmpty) stem = 'IMG';
  final tag = sha256.convert(utf8.encode(assetId)).toString().substring(0, 8);
  final name = stem.endsWith('_$tag') ? stem : '${stem}_$tag';
  return ext.isEmpty ? name : '$name.$ext';
}
