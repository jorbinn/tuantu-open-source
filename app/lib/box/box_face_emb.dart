/// 人脸特征向量编解码与校验。
///
/// 存储约定：little-endian float32、恰好 [kFaceEmbDim] 维、[kFaceEmbBytes] 字节。
/// 数据库字节解码与推理数值列表转换必须分开，禁止用通用 List 猜测含义。
/// Uint8List 也是 List，旧实现先匹配 List 会把 2048 字节当成 2048 维非负整数。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// buffalo_l / w600k_r50 输出维数。禁止截取或拼接其它维数。
const kFaceEmbDim = 512;

/// 512 × float32。
const kFaceEmbBytes = kFaceEmbDim * 4;

/// 单位范数允许误差（float32 往返）。
const kFaceEmbUnitNormEps = 1e-4;

class FaceEmbInfo {
  const FaceEmbInfo({
    required this.ok,
    required this.sourceType,
    this.dim,
    this.norm,
    this.min,
    this.max,
    this.byteLength,
  });

  final bool ok;
  final String sourceType;
  final int? dim;
  final double? norm;
  final double? min;
  final double? max;
  final int? byteLength;

  @override
  String toString() {
    if (!ok) {
      return 'type=$sourceType bytes=$byteLength dim=$dim decode=FAIL';
    }
    return 'type=$sourceType bytes=$byteLength dim=$dim '
        'norm=${norm!.toStringAsFixed(6)} '
        'min=${min!.toStringAsFixed(4)} max=${max!.toStringAsFixed(4)}';
  }
}

/// 生产路径：把已校验的 512 维向量写成 little-endian float32 BLOB。
Uint8List encodeFaceEmb(Float32List e) {
  if (e.length != kFaceEmbDim) {
    throw ArgumentError.value(
        e.length, 'embedding.length', 'must be $kFaceEmbDim');
  }
  final b = ByteData(kFaceEmbBytes);
  for (var i = 0; i < kFaceEmbDim; i++) {
    b.setFloat32(i * 4, e[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

/// 生产路径：从 SQLite BLOB 或 isolate 数值列表恢复 512 维向量。
///
/// 分支顺序是正确性的一部分：必须先识别明确的字节类型，再处理数值列表。
Float32List? decodeFaceEmb(Object? v) {
  if (v == null) return null;

  final bytes = _asByteBlob(v);
  if (bytes != null) return _fromFloat32le(bytes);

  if (v is Float32List) return validateFaceEmb(v);
  if (v is Float64List) {
    if (v.length != kFaceEmbDim) return null;
    return validateFaceEmb(Float32List.fromList(v));
  }

  if (v is List) {
    // 某些平台 BLOB 可能不是 Uint8List，而是长度为 2048 的 List<int>。
    if (_isRawByteList(v)) {
      return _fromFloat32le(Uint8List.fromList(List<int>.from(v)));
    }
    if (v.length != kFaceEmbDim) return null;
    final o = Float32List(kFaceEmbDim);
    for (var i = 0; i < kFaceEmbDim; i++) {
      final e = v[i];
      if (e is! num) return null;
      o[i] = e.toDouble();
    }
    return validateFaceEmb(o);
  }
  return null;
}

/// 精确 512 维、全部有限、范数非零。不在这里偷偷 L2 normalize 或截断。
Float32List? validateFaceEmb(Float32List v) {
  if (v.length != kFaceEmbDim) return null;
  var n2 = 0.0;
  for (var i = 0; i < v.length; i++) {
    final x = v[i];
    if (x.isNaN || x.isInfinite) return null;
    n2 += x * x;
  }
  if (!(n2 > 1e-12) || n2.isNaN || n2.isInfinite) return null;
  return v;
}

double faceEmbNorm(List<double> v) {
  var n = 0.0;
  for (final x in v) {
    n += x * x;
  }
  return math.sqrt(n);
}

double faceEmbMaxAbsDiff(List<double> a, List<double> b) {
  if (a.length != b.length) return double.infinity;
  var m = 0.0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs();
    if (d > m) m = d;
  }
  return m;
}

int? faceEmbRawLength(Object? v) {
  if (v is TypedData) return v.lengthInBytes;
  if (v is ByteBuffer) return v.lengthInBytes;
  if (v is List) return v.length;
  return null;
}

FaceEmbInfo inspectFaceEmb(Object? v) {
  final type = v.runtimeType.toString();
  final byteLength = v is Uint8List
      ? v.length
      : v is ByteData
          ? v.lengthInBytes
          : v is TypedData
              ? v.lengthInBytes
              : null;
  final decoded = decodeFaceEmb(v);
  if (decoded == null) {
    return FaceEmbInfo(
      ok: false,
      sourceType: type,
      dim: v is List ? v.length : null,
      byteLength: byteLength ?? (v is List ? v.length : null),
    );
  }
  var min = decoded[0], max = decoded[0];
  for (final x in decoded) {
    if (x < min) min = x;
    if (x > max) max = x;
  }
  return FaceEmbInfo(
    ok: true,
    sourceType: type,
    dim: decoded.length,
    norm: faceEmbNorm(decoded),
    min: min,
    max: max,
    byteLength: byteLength,
  );
}

/// 复制一份自有字节，避免把 sqflite 的 buffer view 送进 isolate。
Uint8List? copyFaceEmbBytes(Object? v) {
  final bytes = _asByteBlob(v);
  if (bytes != null) return Uint8List.fromList(bytes);
  if (v is List && _isRawByteList(v)) {
    return Uint8List.fromList(List<int>.from(v));
  }
  return null;
}

Uint8List? _asByteBlob(Object? v) {
  if (v is Uint8List) return v;
  if (v is ByteData) {
    return v.buffer.asUint8List(v.offsetInBytes, v.lengthInBytes);
  }
  if (v is ByteBuffer) {
    if (v.lengthInBytes != kFaceEmbBytes) return null;
    return v.asUint8List();
  }
  return null;
}

bool _isRawByteList(List v) {
  if (v.length != kFaceEmbBytes) return false;
  for (final e in v) {
    if (e is! int || e < 0 || e > 255) return false;
  }
  return true;
}

Float32List? _fromFloat32le(Uint8List bytes) {
  if (bytes.length != kFaceEmbBytes) return null;
  final b = ByteData.sublistView(bytes);
  final o = Float32List(kFaceEmbDim);
  for (var i = 0; i < kFaceEmbDim; i++) {
    final x = b.getFloat32(i * 4, Endian.little);
    o[i] = x;
  }
  return validateFaceEmb(o);
}
