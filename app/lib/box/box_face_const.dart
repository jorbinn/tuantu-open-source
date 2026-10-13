/// InsightFace buffalo_l 人脸流水线常量。改阈值先读注释，不要混用度量。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// SCRFD-10G 检测分。过拆/过并先查聚类度量，最后才动这个。
const kDetScore = 0.65;

/// SCRFD NMS IoU。
const kDetNmsIou = 0.4;

/// 原图人脸最短边（像素）。更小的框丢掉。
const kMinFacePx = 40;

/// 单张图最多保留的脸。
const kMaxFaces = 15;

/// 检测 letterbox 边长。
const kDetNet = 640;

/// ArcFace 对齐后边长。
const kRecSize = 112;

/// 聚类度量。全项目只选下面一种，禁止把 Immich cosine distance 和 L2 塞进同一个变量。
///
/// 推荐默认（与 Immich/mim 对齐）：
///   sim = dot(a,b)（已 L2 normalize）
///   合并条件：sim >= 0.50
///   等价：cosine distance = 1-sim <= 0.50
///   等价：单位向量 L2 <= 1.0，因为 L2² = 2(1-sim)
///
/// 若实现用 L2：eps 必须是 [kL2Eps]=1.0，绝不能写成 0.45/0.5
/// （0.5 的 L2 ⇔ sim ≈ 0.875，会严重过拆）。
/// 若实现用 cosine distance：阈值 0.50，不要和 L2 混用同一变量名。
///
/// 拧旋钮：
/// - 过拆：先确认度量没写错；再把 sim 阈值降到 0.45（不要直接降到 0.3）
/// - 过并：sim 提到 0.55，并确认不是并查集
/// - 最后才动 [kDetScore]
///
/// 验证（10 对同人 + 10 对异人的 sim 直方图）：
/// - 同人应大致 0.55～0.85
/// - 异人 < 0.35
/// - 若同人也 < 0.4：先查五点对齐 / letterbox 反变换 / RGB / L2 normalize，不要先拧阈值
enum FaceClusterMetric { similarity, cosineDistance, l2 }

const kClusterMetric = FaceClusterMetric.similarity;

/// 仅当 metric=similarity 或 cosineDistance。
const kClusterThreshold = 0.50;

/// 仅当 metric=l2。
const kL2Eps = 1.0;

/// DBSCAN minPts（邻域含自己）。旅行小库允许两人脸成簇。
const kMinPts = 2;

class FacePairMetrics {
  const FacePairMetrics({
    required this.sim,
    required this.cosineDistance,
    required this.l2,
  });
  final double sim;
  final double cosineDistance;
  final double l2;

  @override
  String toString() =>
      'sim=${sim.toStringAsFixed(4)} cos_dist=${cosineDistance.toStringAsFixed(4)} l2=${l2.toStringAsFixed(4)}';
}

/// 余弦相似度。输入应已 L2 normalize，此时 sim = dot(a,b)。
/// 禁止对不等长向量取最短长度凑相似度。
double faceCosineSim(List<double> a, List<double> b) {
  if (a.length != b.length) {
    throw ArgumentError(
        'embedding length mismatch: ${a.length} vs ${b.length}');
  }
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  final d = math.sqrt(na) * math.sqrt(nb);
  if (d < 1e-9) return 0;
  final s = dot / d;
  if (s > 1) return 1;
  if (s < -1) return -1;
  return s;
}

/// 单位向量欧氏距离。L2 = sqrt(2(1-sim))。
double faceL2(List<double> a, List<double> b) {
  if (a.length != b.length) {
    throw ArgumentError(
        'embedding length mismatch: ${a.length} vs ${b.length}');
  }
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    final d = a[i] - b[i];
    s += d * d;
  }
  return math.sqrt(s);
}

/// 给定两张脸 embedding，同时给出 sim / cosine distance / L2，避免再混度量。
FacePairMetrics facePairMetrics(List<double> a, List<double> b) {
  final sim = faceCosineSim(a, b);
  return FacePairMetrics(
    sim: sim,
    cosineDistance: 1.0 - sim,
    l2: faceL2(a, b),
  );
}

bool facesAreNeighbors(double sim) {
  switch (kClusterMetric) {
    case FaceClusterMetric.similarity:
      return sim >= kClusterThreshold;
    case FaceClusterMetric.cosineDistance:
      return (1.0 - sim) <= kClusterThreshold;
    case FaceClusterMetric.l2:
      final l2 = math.sqrt(math.max(0.0, 2.0 * (1.0 - sim)));
      return l2 <= kL2Eps;
  }
}

Float32List l2Normalize(Float32List v) {
  var n = 0.0;
  for (final x in v) {
    n += x * x;
  }
  n = math.sqrt(n);
  if (n < 1e-9) return v;
  final o = Float32List(v.length);
  for (var i = 0; i < v.length; i++) {
    o[i] = v[i] / n;
  }
  return o;
}
