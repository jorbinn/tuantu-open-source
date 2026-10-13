/// 人脸推理 isolate：InsightFace buffalo_l（SCRFD-10G 检测 + ArcFace R50 512 维）。
/// 不要上 2d106det.onnx。非法五点直接 rejected，禁止检测框五官比例模板 warp。
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as im;
import 'package:onnxruntime/onnxruntime.dart';

import 'box_face_const.dart';
import 'box_face_emb.dart';

const _strides = [8, 16, 32];
const _anchors = 2;
var _dbgChips = 0;

void faceIsoMain(SendPort out) {
  final inn = ReceivePort();
  out.send(inn.sendPort);
  OrtSession? det;
  OrtSession? rec;
  inn.listen((msg) {
    if (msg is! Map) return;
    final cmd = msg['cmd']?.toString();
    try {
      if (cmd == 'init') {
        OrtEnv.instance.init();
        // fromFile：R50 约 174MB。fromBuffer 会在建 session 后立刻 free
        // 模型字节，ORT 若没拷走权重，识别输出会塌缩成几乎同一个向量。
        final detOpt = OrtSessionOptions()
          ..setIntraOpNumThreads(1)
          ..setInterOpNumThreads(1);
        final recOpt = OrtSessionOptions()
          ..setIntraOpNumThreads(1)
          ..setInterOpNumThreads(1);
        det = OrtSession.fromFile(File(msg['det'] as String), detOpt);
        rec = OrtSession.fromFile(File(msg['rec'] as String), recOpt);
        out.send({
          'ok': true,
          'req': msg['req'],
          'detIn': det!.inputNames,
          'detOut': det!.outputNames,
          'recIn': rec!.inputNames,
          'recOut': rec!.outputNames,
        });
        return;
      }
      if (cmd == 'run') {
        final id = msg['id'] as int;
        final path = msg['path'] as String;
        final ow = (msg['ow'] as num?)?.toInt() ?? 0;
        final oh = (msg['oh'] as num?)?.toInt() ?? 0;
        final result = _run(det!, rec!, id, path, ow, oh);
        out.send({
          'ok': true,
          'req': msg['req'],
          'id': id,
          'decoded': true,
          'rejected': result.rejected,
          'faces': [
            for (final f in result.faces)
              {
                'x': f['x'],
                'y': f['y'],
                'w': f['w'],
                'h': f['h'],
                'emb': [for (final x in (f['emb'] as Float32List)) x],
              },
          ],
        });
        return;
      }
    } catch (e, st) {
      final decode = e is FaceDecodeException || '$e'.contains('decode_failed');
      out.send({
        'ok': false,
        'req': msg['req'],
        'id': msg['id'],
        'err': decode ? 'decode_failed' : '$e\n$st',
      });
    }
  });
}

class _RunResult {
  _RunResult(this.faces, this.rejected);
  final List<Map<String, Object>> faces;
  final int rejected;
}

class FaceDecodeException implements Exception {
  const FaceDecodeException();
  @override
  String toString() => 'decode_failed';
}

_RunResult _run(
    OrtSession det, OrtSession rec, int id, String path, int ow, int oh) {
  final bytes = File(path).readAsBytesSync();
  var img = im.decodeImage(bytes);
  if (img == null) throw const FaceDecodeException();
  // image 包解码后已是 RGB，禁止再当 BGR swap。
  img = img.convert(numChannels: 3);
  final origW = ow > 0 ? ow : img.width;
  final origH = oh > 0 ? oh : img.height;
  final sx0 = origW / img.width;
  final sy0 = origH / img.height;

  final dets = _detect(det, img);
  if (dets.isEmpty) return _RunResult(const [], 0);
  final out = <Map<String, Object>>[];
  var rejected = 0;
  for (final d in dets) {
    final x = (d.x * sx0).round();
    final y = (d.y * sy0).round();
    final w = (d.w * sx0).round();
    final h = (d.h * sy0).round();
    final shortSide = math.min(w, h);
    if (shortSide < kMinFacePx) {
      rejected++;
      continue;
    }
    if (!_kpsLooksLikeFace(d)) {
      rejected++;
      continue;
    }
    Float32List? emb;
    try {
      final dbg = _dbgChips < 12
          ? '${File(path).parent.path}${Platform.pathSeparator}dbg_${id}_$x.jpg'
          : null;
      emb = _embed(rec, img, d, dbgPath: dbg);
    } catch (_) {
      emb = null;
    }
    if (emb == null) {
      rejected++;
      continue;
    }
    out.add({'x': x, 'y': y, 'w': w, 'h': h, 'emb': emb});
    if (out.length >= kMaxFaces) break;
  }
  if (out.length >= 2) {
    final a = out[0]['emb'] as Float32List;
    final b = out[1]['emb'] as Float32List;
    // ignore: avoid_print
    print(
        '[face] $id pairSim=${faceCosineSim(a, b).toStringAsFixed(6)} n=${out.length} ${inspectFaceEmb(a)}');
  }
  return _RunResult(out, rejected);
}

class _Det {
  _Det(this.x, this.y, this.w, this.h, this.score, this.kps);
  double x, y, w, h, score;
  List<math.Point<double>> kps;
}

/// SCRFD-10G：640 letterbox、RGB、(x-127.5)/128，输出 9 个张量（score/bbox/kps × 3 stride）。
List<_Det> _detect(OrtSession det, im.Image img) {
  final scale = math.min(kDetNet / img.width, kDetNet / img.height);
  final newW = math.max(1, (img.width * scale).round());
  final newH = math.max(1, (img.height * scale).round());
  // InsightFace 同款：缩放到最长边=640，贴在 640×640 左上，其余填黑。pad=0。
  const padX = 0.0;
  const padY = 0.0;
  final resized = im.copyResize(img, width: newW, height: newH);
  final canvas = im.Image(width: kDetNet, height: kDetNet, numChannels: 3);
  im.fill(canvas, color: im.ColorRgb8(0, 0, 0));
  im.compositeImage(canvas, resized, dstX: padX.round(), dstY: padY.round());

  final nchw = Float32List(1 * 3 * kDetNet * kDetNet);
  var i = 0;
  for (var c = 0; c < 3; c++) {
    for (var y = 0; y < kDetNet; y++) {
      for (var x = 0; x < kDetNet; x++) {
        final p = canvas.getPixel(x, y);
        final v = (c == 0 ? p.rNormalized : c == 1 ? p.gNormalized : p.bNormalized) * 255.0;
        nchw[i++] = (v - 127.5) / 128.0;
      }
    }
  }

  final outs = _ortRun(det, nchw, [1, 3, kDetNet, kDetNet]);
  if (outs.length != 6 && outs.length != 9) {
    throw StateError('SCRFD 输出数量 ${outs.length}，期望 6 或 9');
  }
  const fmc = 3;
  final useKps = outs.length == 9;
  final cands = <_Det>[];

  for (var si = 0; si < _strides.length; si++) {
    final stride = _strides[si];
    final fh = kDetNet ~/ stride;
    final fw = kDetNet ~/ stride;
    final n = fh * fw * _anchors;
    final scores = outs[si];
    final bbox = outs[si + fmc];
    final kps = useKps ? outs[si + fmc * 2] : null;
    final ns = math.min(n, scores.length);
    for (var k = 0; k < ns; k++) {
      final score = scores[k];
      if (score < kDetScore) continue;
      if ((k + 1) * 4 > bbox.length) break;
      final cell = k ~/ _anchors;
      final cy = (cell ~/ fw) * stride.toDouble();
      final cx = (cell % fw) * stride.toDouble();
      final x1 = cx - bbox[k * 4] * stride;
      final y1 = cy - bbox[k * 4 + 1] * stride;
      final x2 = cx + bbox[k * 4 + 2] * stride;
      final y2 = cy + bbox[k * 4 + 3] * stride;
      final pts = <math.Point<double>>[];
      if (kps != null && (k + 1) * 10 <= kps.length) {
        for (var t = 0; t < 5; t++) {
          pts.add(math.Point(
            cx + kps[k * 10 + t * 2] * stride,
            cy + kps[k * 10 + t * 2 + 1] * stride,
          ));
        }
      }
      cands.add(_Det(x1, y1, x2 - x1, y2 - y1, score, pts));
    }
  }

  cands.sort((a, b) => b.score.compareTo(a.score));
  final keep = <_Det>[];
  final dead = List<bool>.filled(cands.length, false);
  for (var i = 0; i < cands.length; i++) {
    if (dead[i]) continue;
    keep.add(cands[i]);
    if (keep.length >= kMaxFaces) break;
    for (var j = i + 1; j < cands.length; j++) {
      if (!dead[j] && _iou(cands[i], cands[j]) > kDetNmsIou) dead[j] = true;
    }
  }

  // letterbox 反变换：canvas → 检测用图像素。五点必须落在原图像素系。
  for (final d in keep) {
    d.x = (d.x - padX) / scale;
    d.y = (d.y - padY) / scale;
    d.w /= scale;
    d.h /= scale;
    d.kps = [
      for (final p in d.kps)
        math.Point((p.x - padX) / scale, (p.y - padY) / scale)
    ];
  }
  return keep;
}

List<Float32List> _ortRun(OrtSession s, Float32List nchw, List<int> shape) {
  final input = OrtValueTensor.createTensorWithDataList(nchw, shape);
  final run = OrtRunOptions();
  try {
    final outs = s.run(run, {s.inputNames.first: input}, s.outputNames);
    final lists = <Float32List>[];
    for (final v in outs) {
      if (v is! OrtValueTensor) continue;
      lists.add(_flatF(v.value));
      v.release();
    }
    return lists;
  } finally {
    input.release();
    run.release();
  }
}

Float32List _flatF(dynamic data) {
  if (data is Float32List) return data;
  final raw = _flat(data is List ? data : [data]);
  return Float32List.fromList([
    for (final e in raw) (e as num).toDouble(),
  ]);
}

List<dynamic> _flat(List data) {
  final out = <dynamic>[];
  void walk(dynamic v) {
    if (v is List) {
      for (final e in v) {
        walk(e);
      }
    } else {
      out.add(v);
    }
  }

  walk(data);
  return out;
}

double _iou(_Det a, _Det b) {
  final x1 = math.max(a.x, b.x);
  final y1 = math.max(a.y, b.y);
  final x2 = math.min(a.x + a.w, b.x + b.w);
  final y2 = math.min(a.y + a.h, b.y + b.h);
  final inter = math.max(0, x2 - x1) * math.max(0, y2 - y1);
  final u = a.w * a.h + b.w * b.h - inter;
  return u <= 0 ? 0 : inter / u;
}

/// 五点几何合法才对齐：左眼在右眼左侧、双眼在鼻上方、眼距相对脸宽合理。
/// 非法五点：rejected，不写 embedding，不参与聚类。禁止框上五官模板回退。
bool _kpsLooksLikeFace(_Det d) {
  if (d.kps.length < 5) return false;
  final le = d.kps[0], re = d.kps[1], nose = d.kps[2], lm = d.kps[3], rm = d.kps[4];
  if (le.x >= re.x) return false;
  if (le.y > nose.y || re.y > nose.y) return false;
  if (nose.y > lm.y || nose.y > rm.y) return false;
  final span = (re.x - le.x).abs();
  if (span < d.w * 0.15 || span > d.w * 1.2) return false;
  return true;
}

/// 只用 SCRFD 五点做 InsightFace norm_crop；非法关键点丢弃该脸。
im.Image? _chip(im.Image img, _Det d) {
  if (!_kpsLooksLikeFace(d)) return null;
  return _align(img, d.kps);
}

Float32List? _embed(OrtSession rec, im.Image img, _Det d, {String? dbgPath}) {
  final aligned = _chip(img, d);
  if (aligned == null) return null;
  if (dbgPath != null && _dbgChips < 12) {
    try {
      File(dbgPath).writeAsBytesSync(im.encodeJpg(aligned, quality: 85));
      _dbgChips++;
    } catch (_) {}
  }
  // RGB、(x-127.5)/127.5、NCHW 1×3×112×112。像素已是 RGB，禁止 BGR swap。
  final nchw = Float32List(1 * 3 * kRecSize * kRecSize);
  var i = 0;
  for (var c = 0; c < 3; c++) {
    for (var y = 0; y < kRecSize; y++) {
      for (var x = 0; x < kRecSize; x++) {
        final p = aligned.getPixel(x, y);
        final v = (c == 0 ? p.rNormalized : c == 1 ? p.gNormalized : p.bNormalized) * 255.0;
        nchw[i++] = (v - 127.5) / 127.5;
      }
    }
  }
  final outs = _ortRun(rec, nchw, [1, 3, kRecSize, kRecSize]);
  if (outs.isEmpty) return null;
  final src = outs.first;
  if (src.length != kFaceEmbDim) {
    // ignore: avoid_print
    print('[face] rec out len=${src.length}, expect $kFaceEmbDim — reject (no truncate)');
    return null;
  }
  var rawMin = src[0], rawMax = src[0], rawSum = 0.0;
  final emb = Float32List(kFaceEmbDim);
  for (var k = 0; k < kFaceEmbDim; k++) {
    final x = src[k];
    if (x.isNaN || x.isInfinite) return null;
    emb[k] = x;
    if (x < rawMin) rawMin = x;
    if (x > rawMax) rawMax = x;
    rawSum += x;
  }
  final nrm = l2Normalize(emb);
  if (validateFaceEmb(nrm) == null) return null;
  final norm = faceEmbNorm(nrm);
  if ((norm - 1.0).abs() > kFaceEmbUnitNormEps) return null;
  if (_dbgChips <= 12) {
    // ignore: avoid_print
    print('[face] rec raw len=$kFaceEmbDim min=${rawMin.toStringAsFixed(3)} max=${rawMax.toStringAsFixed(3)} mean=${(rawSum / kFaceEmbDim).toStringAsFixed(3)} p0=${src[0].toStringAsFixed(3)} ${inspectFaceEmb(nrm)}');
    // ignore: avoid_print
    print('[face] rec after-l2 dim=${nrm.length} norm=${norm.toStringAsFixed(6)}');
  }
  return nrm;
}

const _dst = <math.Point<double>>[
  math.Point(38.2946, 51.6963),
  math.Point(73.5318, 51.5014),
  math.Point(56.0252, 71.7366),
  math.Point(41.5493, 92.3655),
  math.Point(70.7299, 92.2041),
];

im.Image? _align(im.Image img, List<math.Point<double>> src) {
  if (src.length < 5) return null;
  var msx = 0.0, msy = 0.0, mdx = 0.0, mdy = 0.0;
  for (var i = 0; i < 5; i++) {
    msx += src[i].x;
    msy += src[i].y;
    mdx += _dst[i].x;
    mdy += _dst[i].y;
  }
  msx /= 5;
  msy /= 5;
  mdx /= 5;
  mdy /= 5;
  var norm = 0.0, real = 0.0, imag = 0.0;
  for (var i = 0; i < 5; i++) {
    final sx = src[i].x - msx, sy = src[i].y - msy;
    final dx = _dst[i].x - mdx, dy = _dst[i].y - mdy;
    norm += sx * sx + sy * sy;
    real += sx * dx + sy * dy;
    imag += sx * dy - sy * dx;
  }
  if (norm < 1e-6) return null;
  final a = real / norm;
  final b = imag / norm;
  final tx = mdx - (a * msx - b * msy);
  final ty = mdy - (b * msx + a * msy);
  final n = a * a + b * b;
  if (n < 1e-12) return null;
  final out = im.Image(width: kRecSize, height: kRecSize, numChannels: 3);
  for (var y = 0; y < kRecSize; y++) {
    for (var x = 0; x < kRecSize; x++) {
      final dx = x - tx, dy = y - ty;
      final sx = (a * dx + b * dy) / n;
      final sy = (-b * dx + a * dy) / n;
      out.setPixel(x, y, _sample(img, sx, sy));
    }
  }
  return out;
}

im.Color _sample(im.Image img, double x, double y) {
  final x0 = x.floor().clamp(0, img.width - 1);
  final y0 = y.floor().clamp(0, img.height - 1);
  final x1 = (x0 + 1).clamp(0, img.width - 1);
  final y1 = (y0 + 1).clamp(0, img.height - 1);
  final ax = (x - x0).clamp(0.0, 1.0);
  final ay = (y - y0).clamp(0.0, 1.0);
  final p00 = img.getPixel(x0, y0);
  final p10 = img.getPixel(x1, y0);
  final p01 = img.getPixel(x0, y1);
  final p11 = img.getPixel(x1, y1);
  int ch(num a, num b, num c, num d) =>
      ((a * (1 - ax) + b * ax) * (1 - ay) + (c * (1 - ax) + d * ax) * ay).round();
  return im.ColorRgb8(
    ch(p00.r, p10.r, p01.r, p11.r),
    ch(p00.g, p10.g, p01.g, p11.g),
    ch(p00.b, p10.b, p01.b, p11.b),
  );
}
