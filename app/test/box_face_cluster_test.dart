import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/box/box_face_cluster.dart';
import 'package:tuantu_app/box/box_face_const.dart';
import 'package:tuantu_app/box/box_face_emb.dart';
import 'package:tuantu_app/box/box_faces.dart';

Float32List _unit(List<double> v) {
  var n = 0.0;
  for (final x in v) {
    n += x * x;
  }
  n = math.sqrt(n);
  return Float32List.fromList([for (final x in v) x / n]);
}

void main() {
  test('identical vectors: sim=1, cos_dist=0, l2=0', () {
    final a = _unit([1, 0, 0, 0]);
    final m = facePairMetrics(a, a);
    expect(m.sim, closeTo(1, 1e-6));
    expect(m.cosineDistance, closeTo(0, 1e-6));
    expect(m.l2, closeTo(0, 1e-6));
  });

  test('orthogonal unit vectors: sim=0, cos_dist=1, l2=sqrt(2)', () {
    final a = _unit([1, 0, 0, 0]);
    final b = _unit([0, 1, 0, 0]);
    final m = facePairMetrics(a, b);
    expect(m.sim, closeTo(0, 1e-6));
    expect(m.cosineDistance, closeTo(1, 1e-6));
    expect(m.l2, closeTo(math.sqrt(2), 1e-6));
  });

  test('sim 0.50 ⇔ cosineDistance 0.50 ⇔ L2 1.0', () {
    // 对单位向量，L2^2 = 2(1-sim)。sim=0.5 → L2=1。
    final a = _unit([1, 0]);
    final b = _unit([0.5, math.sqrt(0.75)]);
    final m = facePairMetrics(a, b);
    expect(m.sim, closeTo(0.5, 1e-6));
    expect(m.cosineDistance, closeTo(0.5, 1e-6));
    expect(m.l2, closeTo(1.0, 1e-6));
    expect(facesAreNeighbors(m.sim), isTrue);
    expect(facesAreNeighbors(0.49), isFalse);
  });

  test('DBSCAN: two tight pairs stay two persons; far point is noise', () {
    final a1 = _unit([1, 0, 0]);
    final a2 = _unit([0.95, 0.3122, 0]); // sim ≈ 0.95
    final b1 = _unit([0, 1, 0]);
    final b2 = _unit([0.1, 0.995, 0]); // near b1
    final noise = _unit([0, 0, 1]);
    final labels = dbscanFaces([a1, a2, b1, b2, noise]);
    expect(labels[0], labels[1]);
    expect(labels[2], labels[3]);
    expect(labels[0], isNot(labels[2]));
    expect(labels[4], -1);
    expect(labels[0], greaterThanOrEqualTo(0));
    expect(labels[2], greaterThanOrEqualTo(0));
  });

  test('DBSCAN: singleton stays ungrouped (minPts=2)', () {
    final a = _unit([1, 0, 0]);
    expect(dbscanFaces([a]), [-1]);
  });

  test('识别中途：先攒 4 张且有新脸才聚，之后每 8 张；队列空不插队', () {
    expect(
      shouldReclusterDuringScan(
        analyzedSinceCluster: 3,
        queueRemaining: 20,
        newFacesSinceCluster: 5,
        alreadyClusteredOnce: false,
      ),
      isFalse,
    );
    expect(
      shouldReclusterDuringScan(
        analyzedSinceCluster: 4,
        queueRemaining: 20,
        newFacesSinceCluster: 5,
        alreadyClusteredOnce: false,
      ),
      isTrue,
    );
    expect(
      shouldReclusterDuringScan(
        analyzedSinceCluster: 4,
        queueRemaining: 20,
        newFacesSinceCluster: 0,
        alreadyClusteredOnce: false,
      ),
      isFalse,
    );
    expect(
      shouldReclusterDuringScan(
        analyzedSinceCluster: 7,
        queueRemaining: 10,
        newFacesSinceCluster: 3,
        alreadyClusteredOnce: true,
      ),
      isFalse,
    );
    expect(
      shouldReclusterDuringScan(
        analyzedSinceCluster: 8,
        queueRemaining: 10,
        newFacesSinceCluster: 3,
        alreadyClusteredOnce: true,
      ),
      isTrue,
    );
    expect(
      shouldReclusterDuringScan(
        analyzedSinceCluster: 8,
        queueRemaining: 0,
        newFacesSinceCluster: 3,
        alreadyClusteredOnce: true,
      ),
      isFalse,
    );
  });

  test('后台聚类只传人脸向量，不捕获 FaceEngine 的 Timer', () async {
    final a = _unit([1, 0, 0]);
    final b = _unit([0.95, 0.3122, 0]);
    final packed = await clusterFacesOffload([a, b]);
    final labels = (packed[1] as List).cast<int>();
    expect(labels, hasLength(2));
    expect(labels[0], labels[1]);
    expect(labels[0], greaterThanOrEqualTo(0));
  });

  test('sqflite 风格的 BLOB view 在主 isolate 解码后仍能聚成一个人', () {
    Float32List emb(double x0, double x1) {
      final v = Float32List(kFaceEmbDim);
      v[0] = x0;
      v[1] = x1;
      return l2Normalize(v);
    }

    final a = emb(1, 0);
    final b = emb(0.95, 0.3122);
    final viewA = Uint8List.sublistView(encodeFaceEmb(a));
    final viewB = Uint8List.sublistView(encodeFaceEmb(b));
    final prep = prepareFaceClusterRows([
      {'id': 1, 'embedding': viewA},
      {'id': 2, 'embedding': viewB},
    ]);
    expect(prep.nBad, 0);
    expect(prep.ids, [1, 2]);
    expect(prep.embs, hasLength(2));
    final labels = dbscanFaces(prep.embs);
    expect(labels[0], labels[1]);
    expect(labels[0], greaterThanOrEqualTo(0));
  });

  test('copyFaceEmbBytes 复制出自有 buffer，不再是 view', () {
    final blob = encodeFaceEmb(l2Normalize(Float32List(kFaceEmbDim)..[0] = 1));
    final view = Uint8List.sublistView(blob);
    final owned = copyFaceEmbBytes(view);
    expect(owned, isNotNull);
    expect(owned!.length, kFaceEmbBytes);
    expect(owned.offsetInBytes, 0);
    expect(owned.lengthInBytes, owned.buffer.lengthInBytes);
  });

  test('原始 BLOB 在后台 isolate 解码后再聚类', () async {
    Float32List emb(double x0, double x1) {
      final v = Float32List(kFaceEmbDim);
      v[0] = x0;
      v[1] = x1;
      return l2Normalize(v);
    }

    final a = emb(1, 0);
    final b = emb(0.95, 0.3122);
    final packed = await clusterFacesFromRawOffload([
      [1, encodeFaceEmb(a)],
      [2, encodeFaceEmb(b)],
    ]);
    final labels = (packed[1] as List).cast<int>();
    final ids = (packed[2] as List).cast<int>();
    expect(ids, [1, 2]);
    expect(labels, hasLength(2));
    expect(labels[0], labels[1]);
    expect(labels[0], greaterThanOrEqualTo(0));
  });

  test('DBSCAN minPts=2 chains A-B-C even when A-C is below threshold', () {
    // 第二阶段基线：当前实现把阈值图的连通分量并成一簇。
    final a = _unit([1.0, 0.0, 0.0]);
    final b = _unit([0.70, 0.71414, 0.0]);
    final c = _unit([0.30, 0.95394, 0.0]);
    final ab = faceCosineSim(a, b);
    final bc = faceCosineSim(b, c);
    final ac = faceCosineSim(a, c);
    expect(ab, greaterThanOrEqualTo(kClusterThreshold));
    expect(bc, greaterThanOrEqualTo(kClusterThreshold));
    expect(ac, lessThan(kClusterThreshold));
    final labels = dbscanFaces([a, b, c]);
    expect(labels[0], labels[1]);
    expect(labels[1], labels[2]);
    expect(labels[0], isNot(-1));
  });

  test('重聚类保住还在簇里的手动封面脸', () {
    final mean = _unit([1, 0, 0]);
    final specs = preservePersonIdentities(
      groups: [
        [10, 11, 12],
      ],
      means: [mean],
      oldFaceToPerson: {10: 7, 11: 7},
      oldPersons: {
        7: OldPersonSnap(id: 7, mean: mean, coverFaceId: 11),
      },
    );
    expect(specs.single.coverFaceId, 11);
  });

  test('封面脸不在新簇里则丢弃，不把别的脸硬套上去', () {
    final mean = _unit([1, 0, 0]);
    final specs = preservePersonIdentities(
      groups: [
        [10, 11],
      ],
      means: [mean],
      oldFaceToPerson: {10: 7, 11: 7},
      oldPersons: {
        7: OldPersonSnap(id: 7, mean: mean, coverFaceId: 99),
      },
    );
    expect(specs.single.coverFaceId, isNull);
  });

  test('重聚类按脸重叠保住改名和认领', () {
    final mean = _unit([1, 0, 0]);
    final old = {
      7: OldPersonSnap(
        id: 7,
        name: '小明',
        createdAt: 1,
        mean: mean,
        claimUserIds: [3],
      ),
    };
    final specs = preservePersonIdentities(
      groups: [
        [10, 11, 12],
      ],
      means: [mean],
      oldFaceToPerson: {10: 7, 11: 7},
      oldPersons: old,
    );
    expect(specs, hasLength(1));
    expect(specs.first.keepId, 7);
    expect(specs.first.name, '小明');
    expect(specs.first.claimUserIds, [3]);
    expect(specs.first.createdAt, 1);
  });

  test('重聚类两人保持各自名字，新簇不抢名', () {
    final a = _unit([1, 0, 0]);
    final b = _unit([0, 1, 0]);
    final c = _unit([0, 0, 1]);
    final specs = preservePersonIdentities(
      groups: [
        [1, 2],
        [3, 4],
        [5, 6],
      ],
      means: [a, b, c],
      oldFaceToPerson: {1: 10, 2: 10, 3: 20, 4: 20},
      oldPersons: {
        10: OldPersonSnap(id: 10, name: '甲', mean: a, claimUserIds: [1]),
        20: OldPersonSnap(id: 20, name: '乙', mean: b, claimUserIds: [2]),
      },
    );
    expect(specs[0].keepId, 10);
    expect(specs[0].name, '甲');
    expect(specs[0].claimUserIds, [1]);
    expect(specs[1].keepId, 20);
    expect(specs[1].name, '乙');
    expect(specs[2].keepId, isNull);
    expect(specs[2].name, isNull);
    expect(specs[2].claimUserIds, isEmpty);
  });

  test('两个人物并成一簇时多数派留名，两个认领撞簇转待确认', () {
    final mean = _unit([1, 0, 0]);
    final specs = preservePersonIdentities(
      groups: [
        [1, 2, 3, 4, 5],
      ],
      means: [mean],
      oldFaceToPerson: {1: 1, 2: 1, 3: 1, 4: 2, 5: 2},
      oldPersons: {
        1: OldPersonSnap(id: 1, name: '大组', mean: mean, claimUserIds: [8]),
        2: OldPersonSnap(id: 2, name: '小组', mean: mean, claimUserIds: [9]),
      },
    );
    expect(specs.single.keepId, 1);
    expect(specs.single.name, '大组');
    // 一对一：不静默保留任何一个账号，全部转入待确认。
    expect(specs.single.claimUserIds, isEmpty);
    expect(specs.single.pendingClaimUserIds.toSet(), {8, 9});
  });

  test('已有待确认关系随人物簇迁移，且不会和有效认领重复', () {
    final mean = _unit([1, 0, 0]);
    final specs = preservePersonIdentities(
      groups: [
        [1, 2],
      ],
      means: [mean],
      oldFaceToPerson: {1: 7, 2: 7},
      oldPersons: {
        7: OldPersonSnap(
          id: 7,
          mean: mean,
          claimUserIds: [3],
          pendingClaimUserIds: [3, 4],
        ),
      },
    );
    expect(specs.single.claimUserIds, [3]);
    expect(specs.single.pendingClaimUserIds, [4]);
  });

  test('团员标记随簇迁移：团员优先，绝不静默丢标记', () {
    final mean = _unit([1, 0, 0]);
    final specs = preservePersonIdentities(
      groups: [
        [1, 2, 3],
      ],
      means: [mean],
      oldFaceToPerson: {1: 1, 2: 1, 3: 2},
      oldPersons: {
        1: OldPersonSnap(
            id: 1,
            name: '甲',
            mean: mean,
            memberStatus: 2,
            memberMarkedBy: 5,
            memberMarkedAt: 1.0),
        2: OldPersonSnap(
            id: 2,
            name: null,
            mean: mean,
            memberStatus: 1,
            memberMarkedBy: 6,
            memberMarkedAt: 2.0),
      },
    );
    expect(specs.single.keepId, 1);
    // 团员(1) > 非团员(2) > 未标记(0)，保留贡献者的修改人和时间。
    expect(specs.single.memberStatus, 1);
    expect(specs.single.memberMarkedBy, 6);
    expect(specs.single.memberMarkedAt, 2.0);
  });

  test('同人拆成两簇时大簇留名，小簇不占用原 id', () {
    final mean = _unit([1, 0, 0]);
    final specs = preservePersonIdentities(
      groups: [
        [1, 2, 3],
        [4, 5],
      ],
      means: [mean, mean],
      oldFaceToPerson: {1: 4, 2: 4, 3: 4, 4: 4, 5: 4},
      oldPersons: {
        4: OldPersonSnap(id: 4, name: '阿花', mean: mean, claimUserIds: [1]),
      },
    );
    expect(specs[0].keepId, 4);
    expect(specs[0].name, '阿花');
    expect(specs[1].keepId, isNull);
    expect(specs[1].name, isNull);
  });
}
