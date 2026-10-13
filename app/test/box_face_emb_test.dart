/// 第一阶段回归：生产编解码路径。先用与 box_faces.dart 旧 _asEmb 逐行相同的
/// 实现证明 Uint8List 被 List 分支抢走，再断言当前 decodeFaceEmb / encodeFaceEmb。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/box/box_face_const.dart';
import 'package:tuantu_app/box/box_face_emb.dart';

/// 修复前 box_faces.dart 的 _asEmb（List 分支在 Uint8List 之前）。
Float32List? legacyAsEmb(Object? v) {
  if (v is Float32List && v.length >= 128) return v;
  if (v is List && v.length >= 128) {
    return Float32List.fromList([for (final e in v) (e as num).toDouble()]);
  }
  if (v is Uint8List && v.length >= 512) {
    final n = v.length ~/ 4;
    final b = ByteData.sublistView(v);
    final o = Float32List(n);
    for (var i = 0; i < n; i++) {
      o[i] = b.getFloat32(i * 4, Endian.little);
    }
    return o;
  }
  return null;
}

Float32List signedUnitA() {
  final v = Float32List(kFaceEmbDim);
  for (var i = 0; i < kFaceEmbDim; i++) {
    v[i] = ((i % 7) - 3) * (i + 1) * 0.01;
  }
  v[0] = -0.55;
  v[1] = 0.31;
  v[2] = -0.22;
  v[3] = 0.08;
  return l2Normalize(v);
}

Float32List signedUnitB() {
  final v = Float32List(kFaceEmbDim);
  for (var i = 0; i < kFaceEmbDim; i++) {
    v[i] = ((i % 5) - 2) * (kFaceEmbDim - i) * 0.007;
  }
  v[10] = 0.72;
  v[20] = -0.41;
  return l2Normalize(v);
}

void main() {
  test('Uint8List is a List — the footgun', () {
    final blob = encodeFaceEmb(signedUnitA());
    expect(blob, isA<Uint8List>());
    expect(blob, isA<List>());
    expect(blob.length, kFaceEmbBytes);
  });

  test('legacy List-first decoder treats 2048-byte blob as 2048-dim bytes', () {
    final orig = signedUnitA();
    expect(orig.any((x) => x < 0), isTrue);
    expect(orig.length, 512);
    expect(faceEmbNorm(orig), closeTo(1.0, kFaceEmbUnitNormEps));

    final blob = encodeFaceEmb(orig);
    expect(blob.length, 2048);

    final bad = legacyAsEmb(blob);
    expect(bad, isNotNull);
    expect(bad!.length, 2048, reason: 'byte values promoted to 2048-dim vector');
    expect(bad.every((x) => x >= 0), isTrue, reason: 'bytes are non-negative');
    expect(faceEmbNorm(bad), isNot(closeTo(1.0, kFaceEmbUnitNormEps)));
    expect(faceEmbMaxAbsDiff(orig, bad), greaterThan(1e-3));

    final origB = signedUnitB();
    final blobB = encodeFaceEmb(origB);
    final simBefore = faceCosineSim(orig, origB);
    final simLegacy = faceCosineSim(bad, legacyAsEmb(blobB)!);
    expect((simBefore - simLegacy).abs(), greaterThan(1e-2),
        reason: 'legacy decode must distort pair similarity');
  });

  test('production encode/decode roundtrip keeps 512-dim signed unit', () {
    final orig = signedUnitA();
    expect(orig.any((x) => x < 0), isTrue);

    final blob = encodeFaceEmb(orig);
    expect(blob, isA<Uint8List>());
    expect(blob.length, kFaceEmbBytes);

    final got = decodeFaceEmb(blob);
    expect(got, isNotNull);
    expect(got!.length, kFaceEmbDim);
    expect(got.any((x) => x < 0), isTrue);
    expect(faceEmbMaxAbsDiff(orig, got), lessThanOrEqualTo(1e-6));
    expect(faceEmbNorm(got), closeTo(1.0, kFaceEmbUnitNormEps));
    expect((1.0 - faceCosineSim(orig, got)).abs(), lessThanOrEqualTo(1e-5));
  });

  test('isolate-style List<double> and Float32List both decode to 512', () {
    final orig = signedUnitA();
    final asList = [for (final x in orig) x];
    expect(asList, isNot(isA<Uint8List>()));
    expect(asList, isA<List>());

    final fromList = decodeFaceEmb(asList);
    final fromF32 = decodeFaceEmb(orig);
    expect(fromList, isNotNull);
    expect(fromF32, isNotNull);
    expect(fromList!.length, 512);
    expect(fromF32!.length, 512);
    expect(faceEmbMaxAbsDiff(orig, fromList), lessThanOrEqualTo(1e-6));
    expect(faceEmbMaxAbsDiff(orig, fromF32), lessThanOrEqualTo(1e-6));
  });

  test('UnmodifiableUint8ListView from sqlite-like BLOB still decodes to 512',
      () {
    final orig = signedUnitA();
    final blob = encodeFaceEmb(orig);
    final view = blob.asUnmodifiableView();
    expect(view, isA<Uint8List>());
    expect(view, isA<List>());
    final got = decodeFaceEmb(view);
    expect(got, isNotNull);
    expect(got!.length, 512);
    expect(faceEmbMaxAbsDiff(orig, got), lessThanOrEqualTo(1e-6));
  });

  test('plain List<int> of 2048 bytes is decoded as float32le, not as numbers',
      () {
    final orig = signedUnitA();
    final blob = encodeFaceEmb(orig);
    final asInts = List<int>.from(blob);
    expect(asInts, isNot(isA<Uint8List>()));
    expect(asInts.length, 2048);

    final got = decodeFaceEmb(asInts);
    expect(got, isNotNull);
    expect(got!.length, 512);
    expect(faceEmbMaxAbsDiff(orig, got), lessThanOrEqualTo(1e-6));
  });

  test('same pair similarity survives blob roundtrip; different people stay different',
      () {
    final a = signedUnitA();
    final b = signedUnitB();
    final simBefore = faceCosineSim(a, b);
    expect(simBefore, lessThan(0.99), reason: 'A and B must not be the same vector');

    final a2 = decodeFaceEmb(encodeFaceEmb(a))!;
    final b2 = decodeFaceEmb(encodeFaceEmb(b))!;
    final simAfter = faceCosineSim(a2, b2);
    expect((simBefore - simAfter).abs(), lessThanOrEqualTo(1e-5));
    expect(simAfter, lessThan(0.99));
    expect(faceEmbMaxAbsDiff(a, b), greaterThan(1e-3));
    expect(faceEmbMaxAbsDiff(a2, b2), greaterThan(1e-3));
  });

  test('rejects 128-dim, truncated blob, zero, NaN, Inf, 2048-dim numbers', () {
    expect(decodeFaceEmb(Float32List(128)), isNull);
    expect(decodeFaceEmb(Float32List(kFaceEmbDim)), isNull, reason: 'zero vector');

    final nan = Float32List(kFaceEmbDim);
    nan[0] = 1;
    nan[3] = double.nan;
    expect(decodeFaceEmb(nan), isNull);

    final inf = Float32List(kFaceEmbDim);
    inf[0] = double.infinity;
    inf[1] = 1;
    expect(decodeFaceEmb(inf), isNull);

    final trunc = encodeFaceEmb(signedUnitA()).sublist(0, kFaceEmbBytes - 1);
    expect(trunc.length, 2047);
    expect(decodeFaceEmb(trunc), isNull);

    final concat = Float32List(kFaceEmbDim * 2);
    final a = signedUnitA();
    concat.setAll(0, a);
    concat.setAll(kFaceEmbDim, signedUnitB());
    expect(decodeFaceEmb(concat), isNull);

    final asNumbers = Float32List.fromList(
        [for (final e in encodeFaceEmb(a)) e.toDouble()]);
    expect(asNumbers.length, 2048);
    expect(decodeFaceEmb(asNumbers), isNull,
        reason: '2048 numeric values are the legacy bug output, not a blob');
  });

  test('cosine/L2 refuse unequal lengths instead of min(len)', () {
    final a = signedUnitA();
    final b = Float32List.fromList([...a, 0.0]);
    expect(() => faceCosineSim(a, b), throwsArgumentError);
    expect(() => faceL2(a, b), throwsArgumentError);
  });

  test('float32 conversion error from List<double> is within 1e-6', () {
    final v64 = List<double>.generate(kFaceEmbDim, (i) {
      return math.sin(i * 0.017) * (i.isEven ? 1.0 : -1.0);
    });
    var n = 0.0;
    for (final x in v64) {
      n += x * x;
    }
    n = math.sqrt(n);
    for (var i = 0; i < v64.length; i++) {
      v64[i] /= n;
    }
    final decoded = decodeFaceEmb(v64)!;
    expect(decoded.length, 512);
    expect(faceEmbMaxAbsDiff(v64, decoded), lessThanOrEqualTo(1e-6),
        reason: 'f64→f32 of ~1e-1 values stays within 1e-6 abs');
    final back = decodeFaceEmb(encodeFaceEmb(decoded))!;
    expect(faceEmbMaxAbsDiff(decoded, back), lessThanOrEqualTo(1e-6));
  });
}
