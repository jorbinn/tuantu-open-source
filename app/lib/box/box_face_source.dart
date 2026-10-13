/// 人脸识别用哪张图、失败后要不要再等。
///
/// isolate 解码失败以前会被当成「没有人脸」并写 analyzed=1，HEIC 原件和
/// 还没抽到封面的视频就会永远漏识别。这里把「没有脸」「解不开」「素材没好」
/// 分开，坐标始终按作品原宽高换算。
library;

/// 等封面 / 等预览的次数上限。4 秒 idle 扫描大约对应两分钟。
const kFaceNotReadyMaxTries = 30;

/// 所有候选图都解不开时，再等几次（封面可能稍后才写出）。
const kFaceDecodeMaxTries = 3;

/// isolate 超时重试次数，与历史行为一致。
const kFaceTimeoutMaxTries = 3;

enum FaceAnalyzeRetry { wait, giveUp }

class FaceSourceCandidate {
  const FaceSourceCandidate({required this.path, required this.role});
  final String path;

  /// orig / thumb / webp
  final String role;
}

/// 识别候选：静图优先原件，失败后再用兼容预览；视频从不拿原片去解码。
List<FaceSourceCandidate> faceSourceCandidates({
  required String kind,
  required String origPath,
  required bool origExists,
  required String thumbPath,
  required bool thumbExists,
  required String webpPath,
  required bool webpExists,
}) {
  final out = <FaceSourceCandidate>[];
  if (kind == 'image' && origExists) {
    out.add(FaceSourceCandidate(path: origPath, role: 'orig'));
  }
  if (thumbExists) {
    out.add(FaceSourceCandidate(path: thumbPath, role: 'thumb'));
  }
  if (webpExists) {
    out.add(FaceSourceCandidate(path: webpPath, role: 'webp'));
  }
  return out;
}

FaceSourceCandidate? nextFaceSource(
  Iterable<FaceSourceCandidate> candidates,
  Set<String> failedPaths,
) {
  for (final c in candidates) {
    if (!failedPaths.contains(c.path)) return c;
  }
  return null;
}

/// 当前没有任何可解码静图。视频原件在、封面还没出 → 未就绪；
/// 静图原件也没有 → 同样未就绪（上传后预览可能稍后才落盘）。
bool faceMaterialNotReady({
  required String kind,
  required bool origExists,
  required bool hasPreview,
}) {
  if (hasPreview) return false;
  if (kind == 'video') return true;
  return !origExists;
}

FaceAnalyzeRetry decideFaceRetry({
  required String reason,
  required int tries,
}) {
  final cap = switch (reason) {
    'not_ready' => kFaceNotReadyMaxTries,
    'decode_failed' => kFaceDecodeMaxTries,
    'timeout' => kFaceTimeoutMaxTries,
    _ => 1,
  };
  return tries < cap ? FaceAnalyzeRetry.wait : FaceAnalyzeRetry.giveUp;
}

bool isFaceDecodeFailed(Object? err) {
  final s = err?.toString() ?? '';
  return s == 'decode_failed' || s.contains('decode_failed');
}

String faceRetryStatus(String reason, int tries, int cap) {
  return switch (reason) {
    'not_ready' => '等待可识别的图 ($tries/$cap)',
    'decode_failed' => '原件解不开，等待预览 ($tries/$cap)',
    'timeout' => '超时，稍后重试 ($tries/$cap)',
    _ => '识别失败',
  };
}
