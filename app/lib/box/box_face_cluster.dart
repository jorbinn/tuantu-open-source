/// DBSCAN 人脸聚类。禁止并查集 / 连通分量单链接 union。
library;

import 'dart:collection';
import 'dart:typed_data';

import 'box_face_const.dart';

/// DBSCAN-lite。
///
/// - 邻域含自己；[kMinPts] = 2 时两人脸即可成簇
/// - 只有 core（|N| >= minPts）才能扩展
/// - border 可挂到某个 core 的簇
/// - 其余为 noise（返回 -1），不进人物主列表
///
/// 返回与 [embs] 等长的标签：>=0 为簇 id，-1 为未分组。
List<int> dbscanFaces(List<Float32List> embs) {
  final n = embs.length;
  if (n == 0) return const [];
  final sim = List<Float32List>.generate(n, (_) => Float32List(n));
  for (var i = 0; i < n; i++) {
    sim[i][i] = 1;
    for (var j = i + 1; j < n; j++) {
      final s = faceCosineSim(embs[i], embs[j]);
      sim[i][j] = s;
      sim[j][i] = s;
    }
  }

  List<int> region(int i) {
    final out = <int>[];
    for (var j = 0; j < n; j++) {
      if (facesAreNeighbors(sim[i][j])) out.add(j);
    }
    return out;
  }

  // -2 未访问，-1 noise，>=0 簇
  final labels = List<int>.filled(n, -2);
  var cid = 0;
  for (var i = 0; i < n; i++) {
    if (labels[i] != -2) continue;
    final nbs = region(i);
    if (nbs.length < kMinPts) {
      labels[i] = -1;
      continue;
    }
    labels[i] = cid;
    final seed = Queue<int>();
    final queued = List<bool>.filled(n, false);
    queued[i] = true;
    for (final j in nbs) {
      if (j == i) continue;
      seed.add(j);
      queued[j] = true;
    }
    while (seed.isNotEmpty) {
      final j = seed.removeFirst();
      if (labels[j] == -1) {
        labels[j] = cid; // border：曾经是 noise，挂到当前簇，不扩展
        continue;
      }
      if (labels[j] != -2) continue;
      labels[j] = cid;
      final nbs2 = region(j);
      if (nbs2.length >= kMinPts) {
        for (final k in nbs2) {
          if (queued[k]) continue;
          queued[k] = true;
          seed.add(k);
        }
      }
    }
    cid++;
  }
  return labels;
}

class FaceSimHistogram {
  FaceSimHistogram({
    required this.n,
    required this.nPairs,
    required this.minSim,
    required this.maxSim,
    required this.meanSim,
    required this.lt035,
    required this.b035_045,
    required this.b045_050,
    required this.b050_055,
    required this.b055_070,
    required this.ge070,
  });
  final int n;
  final int nPairs;
  final double minSim;
  final double maxSim;
  final double meanSim;
  final int lt035;
  final int b035_045;
  final int b045_050;
  final int b050_055;
  final int b055_070;
  final int ge070;

  @override
  String toString() =>
      'n=$n pairs=$nPairs min=${minSim.toStringAsFixed(3)} max=${maxSim.toStringAsFixed(3)} '
      'mean=${meanSim.toStringAsFixed(3)} '
      '<0.35=$lt035 0.35-0.45=$b035_045 0.45-0.50=$b045_050 '
      '0.50-0.55=$b050_055 0.55-0.70=$b055_070 >=0.70=$ge070';
}

FaceSimHistogram faceSimHistogram(List<Float32List> embs) {
  final n = embs.length;
  var minS = 1.0, maxS = -1.0, sum = 0.0, pairs = 0;
  var lt035 = 0, b035 = 0, b045 = 0, b050 = 0, b055 = 0, ge070 = 0;
  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      final s = faceCosineSim(embs[i], embs[j]);
      minS = s < minS ? s : minS;
      maxS = s > maxS ? s : maxS;
      sum += s;
      pairs++;
      if (s < 0.35) {
        lt035++;
      } else if (s < 0.45) {
        b035++;
      } else if (s < 0.50) {
        b045++;
      } else if (s < 0.55) {
        b050++;
      } else if (s < 0.70) {
        b055++;
      } else {
        ge070++;
      }
    }
  }
  if (pairs == 0) {
    minS = 0;
    maxS = 0;
  }
  return FaceSimHistogram(
    n: n,
    nPairs: pairs,
    minSim: minS,
    maxSim: maxS,
    meanSim: pairs == 0 ? 0 : sum / pairs,
    lt035: lt035,
    b035_045: b035,
    b045_050: b045,
    b050_055: b050,
    b055_070: b055,
    ge070: ge070,
  );
}

class OldPersonSnap {
  OldPersonSnap({
    required this.id,
    this.name,
    this.createdAt,
    this.mean,
    List<int>? claimUserIds,
    List<int>? pendingClaimUserIds,
    this.memberStatus = 0,
    this.memberMarkedBy,
    this.memberMarkedAt,
    this.coverFaceId,
  })  : claimUserIds = claimUserIds ?? [],
        pendingClaimUserIds = pendingClaimUserIds ?? [];

  final int id;
  final String? name;
  final double? createdAt;
  final Float32List? mean;
  final List<int> claimUserIds;
  final List<int> pendingClaimUserIds;

  /// 0=未标记 1=团员 2=非团员（旅行报告用）。
  final int memberStatus;
  final int? memberMarkedBy;
  final double? memberMarkedAt;
  final int? coverFaceId;

  bool get hasName {
    final n = name?.trim();
    return n != null && n.isNotEmpty;
  }
}

/// 团员标记的合并优先级：团员(1) > 非团员(2) > 未标记(0)。
/// 有人明确标过就绝不静默降级。
int memberStatusPriority(int s) => s == 1 ? 2 : (s == 2 ? 1 : 0);

class NewPersonSpec {
  NewPersonSpec({
    required this.faceIds,
    required this.mean,
    this.keepId,
    this.name,
    this.createdAt,
    this.claimUserIds = const [],
    this.pendingClaimUserIds = const [],
    this.memberStatus = 0,
    this.memberMarkedBy,
    this.memberMarkedAt,
    this.coverFaceId,
  });

  final List<int> faceIds;
  final Float32List mean;
  final int? keepId;
  final String? name;
  final double? createdAt;

  /// 有效认领（一对一约束下最多 1 个账号）。
  final List<int> claimUserIds;

  /// 因聚类拆分/合并产生冲突、转入待确认的账号。
  final List<int> pendingClaimUserIds;

  final int memberStatus;
  final int? memberMarkedBy;
  final double? memberMarkedAt;
  final int? coverFaceId;
}

/// 把新簇对回旧人物：先按脸重叠，再按均值相似度。用来保住改名和「这是我」。
List<NewPersonSpec> preservePersonIdentities({
  required List<List<int>> groups,
  required List<Float32List> means,
  required Map<int, int> oldFaceToPerson,
  required Map<int, OldPersonSnap> oldPersons,
  double meanSimThreshold = kClusterThreshold,
}) {
  if (groups.length != means.length) {
    throw ArgumentError('groups and means length mismatch');
  }
  final n = groups.length;
  final overlap = List.generate(n, (_) => <int, int>{});
  for (var c = 0; c < n; c++) {
    for (final fid in groups[c]) {
      final pid = oldFaceToPerson[fid];
      if (pid == null) continue;
      overlap[c][pid] = (overlap[c][pid] ?? 0) + 1;
    }
  }

  final candidates = <({int c, int pid, int n, bool named})>[];
  for (var c = 0; c < n; c++) {
    overlap[c].forEach((pid, cnt) {
      candidates.add((
        c: c,
        pid: pid,
        n: cnt,
        named: oldPersons[pid]?.hasName == true,
      ));
    });
  }
  candidates.sort((a, b) {
    final byN = b.n.compareTo(a.n);
    if (byN != 0) return byN;
    if (a.named != b.named) return a.named ? -1 : 1;
    return a.pid.compareTo(b.pid);
  });

  final usedC = <int>{};
  final usedP = <int>{};
  final keep = <int, int>{};
  for (final x in candidates) {
    if (usedC.contains(x.c) || usedP.contains(x.pid)) continue;
    usedC.add(x.c);
    usedP.add(x.pid);
    keep[x.c] = x.pid;
  }

  for (var c = 0; c < n; c++) {
    if (keep.containsKey(c)) continue;
    var bestPid = -1;
    var bestSim = -1.0;
    oldPersons.forEach((pid, snap) {
      if (usedP.contains(pid)) return;
      final m = snap.mean;
      if (m == null) return;
      final s = faceCosineSim(means[c], m);
      if (s > bestSim) {
        bestSim = s;
        bestPid = pid;
      }
    });
    if (bestPid >= 0 && bestSim >= meanSimThreshold) {
      keep[c] = bestPid;
      usedP.add(bestPid);
    }
  }

  final claims = List.generate(n, (_) => <int>{});
  final pendingClaims = List.generate(n, (_) => <int>{});
  final extraName = List<String?>.filled(n, null);
  // 各簇的团员标记候选：按优先级取最高的贡献者，保留标记人和时间。
  final memberCandidates =
      List.generate(n, (_) => <int, (int, int?, double?)>{});
  oldPersons.forEach((pid, snap) {
    var bestC = -1;
    var bestN = 0;
    for (var c = 0; c < n; c++) {
      final cnt = overlap[c][pid] ?? 0;
      if (cnt > bestN) {
        bestN = cnt;
        bestC = c;
      }
    }
    if (bestC < 0) {
      for (final e in keep.entries) {
        if (e.value == pid) {
          bestC = e.key;
          break;
        }
      }
    }
    if (bestC < 0) return;
    claims[bestC].addAll(snap.claimUserIds);
    pendingClaims[bestC].addAll(snap.pendingClaimUserIds);
    if (snap.hasName) extraName[bestC] ??= snap.name!.trim();
    if (snap.memberStatus != 0) {
      memberCandidates[bestC][pid] =
          (snap.memberStatus, snap.memberMarkedBy, snap.memberMarkedAt);
    }
  });

  String? nameOf(int c) {
    final pid = keep[c];
    final primary = pid == null ? null : oldPersons[pid]?.name?.trim();
    if (primary != null && primary.isNotEmpty) return primary;
    return extraName[c];
  }

  (int, int?, double?) memberOf(int c) {
    var best = (0, null as int?, null as double?);
    int bestPri = -1;
    memberCandidates[c].forEach((_, v) {
      final pri = memberStatusPriority(v.$1);
      if (pri > bestPri) {
        bestPri = pri;
        best = v;
      }
    });
    return best;
  }

  return [
    for (var c = 0; c < n; c++)
      () {
        final member = memberOf(c);
        // 一对一：多个账号的认领撞进同一个簇时不静默保留任何一个，
        // 全部转入待确认，由用户确认或合并流程整理。
        final active =
            claims[c].length <= 1 ? claims[c].toList() : const <int>[];
        final pending = <int>{
          ...pendingClaims[c],
          if (claims[c].length > 1) ...claims[c],
        }..removeAll(active);
        final coverFid = oldPersons[keep[c]]?.coverFaceId;
        return NewPersonSpec(
          faceIds: groups[c],
          mean: means[c],
          keepId: keep[c],
          name: nameOf(c),
          createdAt: keep[c] == null ? null : oldPersons[keep[c]!]?.createdAt,
          claimUserIds: active,
          pendingClaimUserIds: pending.toList(),
          memberStatus: member.$1,
          memberMarkedBy: member.$2,
          memberMarkedAt: member.$3,
          coverFaceId:
              coverFid != null && groups[c].contains(coverFid) ? coverFid : null,
        );
      }(),
  ];
}
