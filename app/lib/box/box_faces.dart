/// 后台人脸队列：新图检测 + 全量 DBSCAN 聚类。禁止并查集单链接。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'box_db.dart';
import 'box_face_cluster.dart';
import 'box_face_const.dart';
import 'box_face_emb.dart';
import 'box_face_iso.dart';
import 'box_face_source.dart';

/// Match the HTTP automatic cover ordering, including stable area ties.
@visibleForTesting
int? effectivePersonCover(List<int> faces, int? chosen, Map<int, num> areas) {
  if (chosen != null && faces.contains(chosen)) return chosen;
  int? best;
  for (final id in faces) {
    if (best == null ||
        (areas[id] ?? 0) > (areas[best] ?? 0) ||
        ((areas[id] ?? 0) == (areas[best] ?? 0) && id < best)) {
      best = id;
    }
  }
  return best;
}

/// Recognition returns long after its input snapshot. Keep the final existence
/// check and all writes in one transaction with deletion.
@visibleForTesting
Future<bool> writeFaceAnalysisIfPresent(
        BoxDb db, int assetId, Future<void> Function(BoxDb tx) write) =>
    db.txn((tx) async {
      if (await tx.qOne('SELECT id FROM assets WHERE id=?', [assetId]) ==
          null) {
        return false;
      }
      await write(tx);
      return true;
    });

/// 在独立 isolate 中运行聚类。
///
/// 必须保持为顶层函数，并通过 [compute] 传参。直接在 [FaceEngine] 的实例方法里
/// 使用 `Isolate.run(() { ... })` 时，Dart 可能把整个方法上下文一并捕获；其中包含
/// Timer 等不可跨 isolate 发送的对象，最终导致检测到的人脸无法归入人物。
List<Object> _clusterFacesOffload(List<Float32List> embeddings) {
  final hist = faceSimHistogram(embeddings);
  final labels = dbscanFaces(embeddings);
  return <Object>[hist.toString(), labels];
}

/// 只向后台 isolate 传递可发送的人脸向量，避免捕获 [FaceEngine] 的运行状态。
@visibleForTesting
Future<List<Object>> clusterFacesOffload(List<Float32List> embeddings) {
  return compute<List<Float32List>, List<Object>>(
    _clusterFacesOffload,
    embeddings,
    debugLabel: 'tuantu-face-cluster',
  );
}

/// 解码 BLOB + DBSCAN 都在后台 isolate。输入是 `[id, embeddingBlob]` 行。
/// 返回 `[hist, labels, ids, nBad, embs]`。
List<Object> _clusterFacesFromRawOffload(List<List<Object?>> rows) {
  final ids = <int>[];
  final embs = <Float32List>[];
  var nBad = 0;
  for (final r in rows) {
    if (r.length < 2) {
      nBad++;
      continue;
    }
    final e = decodeFaceEmb(r[1]);
    if (e == null) {
      nBad++;
      continue;
    }
    ids.add((r[0] as num).toInt());
    embs.add(e);
  }
  if (embs.isEmpty) {
    return <Object>['n=0', <int>[], ids, nBad, embs];
  }
  final hist = faceSimHistogram(embs);
  final labels = dbscanFaces(embs);
  return <Object>[hist.toString(), labels, ids, nBad, embs];
}

@visibleForTesting
Future<List<Object>> clusterFacesFromRawOffload(List<List<Object?>> rows) {
  // sqflite 的 BLOB 经常是 _UnmodifiableUint8ArrayView，直接 compute 可能
  // 因不可发送的 buffer view 失败，表现为识别完成但人物为空。
  final owned = <List<Object?>>[
    for (final r in rows)
      if (r.length >= 2) <Object?>[r[0], copyFaceEmbBytes(r[1]) ?? r[1]],
  ];
  return compute<List<List<Object?>>, List<Object>>(
    _clusterFacesFromRawOffload,
    owned,
    debugLabel: 'tuantu-face-cluster-raw',
  );
}

/// 主 isolate 先解码成自有 Float32List，再交给后台聚类。
/// 不要把 sqflite 的 BLOB view 直接送进 isolate。
class FaceClusterPrep {
  const FaceClusterPrep({
    required this.ids,
    required this.embs,
    required this.nBad,
  });
  final List<int> ids;
  final List<Float32List> embs;
  final int nBad;
}

/// 识别还在跑时插一次全量 DBSCAN 的节奏。
/// 每张都聚会堵住后续识别；等全部完成人物又太晚。
const kReclusterFirstBatch = 4;
const kReclusterBatch = 8;

/// 队列未空时要不要暂停识别、先聚一轮。收尾清空队列仍走原来的全量聚类。
@visibleForTesting
bool shouldReclusterDuringScan({
  required int analyzedSinceCluster,
  required int queueRemaining,
  required int newFacesSinceCluster,
  required bool alreadyClusteredOnce,
}) {
  if (queueRemaining <= 0) return false;
  if (newFacesSinceCluster <= 0) return false;
  final batch = alreadyClusteredOnce ? kReclusterBatch : kReclusterFirstBatch;
  return analyzedSinceCluster >= batch;
}

@visibleForTesting
FaceClusterPrep prepareFaceClusterRows(Iterable<Map<String, Object?>> rows) {
  final ids = <int>[];
  final embs = <Float32List>[];
  var nBad = 0;
  for (final r in rows) {
    final e = decodeFaceEmb(r['embedding']);
    if (e == null) {
      nBad++;
      continue;
    }
    ids.add((r['id'] as num).toInt());
    embs.add(Float32List.fromList(e));
  }
  return FaceClusterPrep(ids: ids, embs: embs, nBad: nBad);
}

class FaceJob {
  FaceJob({required this.id, required this.name});
  final int id;
  String name;
  String status = '排队中';
  String state = 'queued';
  int faces = 0;
  bool get active => state == 'queued' || state == 'running';
}

class FaceEngine extends ChangeNotifier {
  FaceEngine._();
  static final FaceEngine I = FaceEngine._();

  BoxDb? _db;
  Directory? _root;
  Isolate? _iso;
  SendPort? _cmd;
  ReceivePort? _rp;
  bool ready = false;
  bool starting = false;
  String? lastError;
  int pending = 0;
  final _q = Queue<int>();
  final jobs = <FaceJob>[];
  bool _busy = false;
  bool _reclusterRetryScheduled = false;

  /// 人物页只在 pending 从 >0 变 0 时刷新会错过「识别早已完成、稍后才写出人物」这一拍。
  int clusterEpoch = 0;
  Completer<Map>? _wait;
  int _reqSeq = 0;
  int? _waitReq;
  int _sqliteRtLogged = 0;
  Timer? _idleScan;
  final _failTries = <String, int>{};

  List<FaceJob> get newestFirst {
    final copy = [...jobs];
    copy.sort((a, b) => b.id.compareTo(a.id));
    return copy;
  }

  Directory get orig => Directory(p.join(_root!.path, 'orig'));
  Directory get thumbs => Directory(p.join(_root!.path, 'thumbs'));

  Future<void> start(BoxDb db, Directory root) async {
    _db = db;
    _root = root;
    if (ready || starting) {
      await scanPending();
      if (ready) _armIdleScan();
      return;
    }
    starting = true;
    try {
      final det = await _ensureModel('det_10g.onnx');
      final rec = await _ensureModel('w600k_r50.onnx');
      _rp = ReceivePort();
      final hand = Completer<SendPort>();
      _rp!.listen((msg) {
        if (msg is SendPort && !hand.isCompleted) {
          hand.complete(msg);
          return;
        }
        _onMsg(msg);
      });
      _iso = await Isolate.spawn(faceIsoMain, _rp!.sendPort);
      _cmd = await hand.future.timeout(const Duration(seconds: 20));
      final ack = await _send({'cmd': 'init', 'det': det, 'rec': rec});
      if (ack['ok'] != true) {
        throw ack['err'] ?? '模型加载失败';
      }
      ready = true;
      lastError = null;
      debugPrint(
        '[face] ready detIn=${ack['detIn']} detOut=${ack['detOut']} recIn=${ack['recIn']} recOut=${ack['recOut']} metric=$kClusterMetric thr=$kClusterThreshold l2eps=$kL2Eps minPts=$kMinPts detScore=$kDetScore',
      );
      notifyListeners();
    } catch (e, st) {
      lastError = e.toString();
      ready = false;
      debugPrint('[face] start failed: $e\n$st');
      notifyListeners();
    } finally {
      starting = false;
    }
    if (ready) {
      await _migrateDbscan();
      await _migrateEmbDecodeV1();
      await scanPending();
      _armIdleScan();
      // 启动后立刻全量 DBSCAN 会堵死 HTTP 事件循环：团长本机看着还开着，
      // 其他手机 GET /api/status / UDP 信标全部超时，表现为「连不上盒子」。
      if (_q.isEmpty) {
        unawaited(
          Future<void>.delayed(const Duration(seconds: 8), () async {
            if (!ready) return;
            try {
              await _reclusterIfNeeded();
            } catch (e, st) {
              debugPrint('[face] delayed recluster failed: $e\n$st');
            }
          }),
        );
      }
      unawaited(() async {
        try {
          await _writeEmbEvidence();
        } catch (e, st) {
          debugPrint('[face] emb evidence failed: $e\n$st');
        }
      }());
    }
  }

  Future<void> stop() async {
    ready = false;
    _idleScan?.cancel();
    _idleScan = null;
    _q.clear();
    if (_wait != null && !_wait!.isCompleted) {
      _wait!.complete({'ok': false, 'err': 'stopped'});
    }
    _wait = null;
    _waitReq = null;
    _iso?.kill(priority: Isolate.immediate);
    _iso = null;
    _rp?.close();
    _rp = null;
    _cmd = null;
  }

  Future<void> scanPending() async {
    final db = _db;
    if (db == null) return;
    final rows = await db.q(
      "SELECT id FROM assets WHERE analyzed=0 AND kind IN ('image','video') ORDER BY id",
    );
    for (final r in rows) {
      enqueue(r['id'] as int);
    }
  }

  /// 换成 DBSCAN（sim>=0.50）后旧人物簇作废，清空并重跑存量。
  Future<void> _migrateDbscan() async {
    final db = _db;
    final root = _root;
    if (db == null || root == null) return;
    final mark = File(p.join(root.path, '_face_emb_fromfile_v1'));
    if (mark.existsSync()) return;
    await db.run('DELETE FROM faces');
    await db.run('DELETE FROM persons');
    await db.run('DELETE FROM person_claims');
    final n = await db.run(
      "UPDATE assets SET analyzed=0 WHERE kind IN ('image','video')",
    );
    try {
      await mark.writeAsString('1', flush: true);
    } catch (_) {}
    debugPrint(
      '[face] migrate dbscan sim>=$kClusterThreshold, reset analyzed=0 rows=$n',
    );
  }

  /// 只修读取：复用已写入的 2048 字节 float32，不删 faces、不清 analyzed。
  /// 旧聚类来自被 List 抢先匹配的 2048 维字节值，需要按正确向量重建自动分组。
  Future<void> _migrateEmbDecodeV1() async {
    final db = _db;
    final root = _root;
    if (db == null || root == null) return;
    final mark = File(p.join(root.path, '_face_emb_decode_v1'));
    if (mark.existsSync()) return;
    try {
      await _recluster();
      await mark.writeAsString('1', flush: true);
      debugPrint(
        '[face] migrate emb-decode-v1: reclustered stored embeddings, no re-inference',
      );
    } catch (e, st) {
      debugPrint('[face] migrate emb-decode-v1 failed: $e\n$st');
    }
  }

  /// 手机上走生产 sqflite 写读，并抽样现有 faces BLOB。结果写到盒子目录供 adb pull。
  Future<void> _writeEmbEvidence() async {
    final db = _db;
    final root = _root;
    if (db == null || root == null) return;
    final out = File(p.join(root.path, '_face_emb_phase1.txt'));
    if (out.existsSync()) return;
    final buf = StringBuffer();
    buf.writeln('phase=1 face embedding evidence');
    buf.writeln('at=${DateTime.now().toIso8601String()}');
    buf.writeln('dim=$kFaceEmbDim bytes=$kFaceEmbBytes endian=le float32');

    final a = _probeUnit(0);
    final b = _probeUnit(1);
    final simBefore = faceCosineSim(a, b);
    await db.run(
      'CREATE TABLE IF NOT EXISTS _emb_rt(id INTEGER PRIMARY KEY, b BLOB)',
    );
    await db.run('DELETE FROM _emb_rt');
    await db.exec('INSERT INTO _emb_rt(id,b) VALUES(?,?)', [
      1,
      encodeFaceEmb(a),
    ]);
    await db.exec('INSERT INTO _emb_rt(id,b) VALUES(?,?)', [
      2,
      encodeFaceEmb(b),
    ]);
    final rt = await db.q('SELECT id, b FROM _emb_rt ORDER BY id');
    buf.writeln('sqlite_roundtrip rows=${rt.length}');
    Float32List? backA;
    Float32List? backB;
    for (final r in rt) {
      final raw = r['b'];
      final got = decodeFaceEmb(raw);
      final info = inspectFaceEmb(raw);
      buf.writeln('  id=${r['id']} $info');
      if ((r['id'] as num).toInt() == 1) backA = got;
      if ((r['id'] as num).toInt() == 2) backB = got;
    }
    if (backA != null && backB != null) {
      buf.writeln(
        '  maxAbsErrA=${faceEmbMaxAbsDiff(a, backA)} maxAbsErrB=${faceEmbMaxAbsDiff(b, backB)}',
      );
      buf.writeln(
        '  selfSimA=${faceCosineSim(a, backA)} pairBefore=$simBefore pairAfter=${faceCosineSim(backA, backB)}',
      );
      buf.writeln(
        '  unitNormA=${faceEmbNorm(backA)} unitNormB=${faceEmbNorm(backB)}',
      );
    }
    try {
      await db.run('DROP TABLE IF EXISTS _emb_rt');
    } catch (_) {}

    final faceCount = firstInt(await db.q('SELECT COUNT(*) c FROM faces')) ?? 0;
    final persons = await db.q('SELECT id, length(mean_emb) n FROM persons');
    buf.writeln('faces=$faceCount persons=${persons.length}');
    final hist = <int, int>{};
    for (final r in await db.q(
      'SELECT length(embedding) n, COUNT(*) c FROM faces GROUP BY n',
    )) {
      hist[(r['n'] as num?)?.toInt() ?? -1] = (r['c'] as num?)?.toInt() ?? 0;
    }
    var ok = 0, fail = 0, withNeg = 0;
    Float32List? first;
    int? firstId;
    // 只抽样解码，避免开盒子时把全库 embedding 在主 isolate 过一遍。
    final samples = await db.q(
      'SELECT id, asset_id, embedding FROM faces ORDER BY id LIMIT 24',
    );
    for (final r in samples) {
      final raw = r['embedding'];
      final e = decodeFaceEmb(raw);
      if (e == null) {
        fail++;
        if (fail <= 5) {
          buf.writeln(
            '  FAIL id=${r['id']} asset=${r['asset_id']} ${inspectFaceEmb(raw)}',
          );
        }
        continue;
      }
      ok++;
      if (e.any((x) => x < 0)) withNeg++;
      if (first == null) {
        first = e;
        firstId = (r['id'] as num).toInt();
        buf.writeln(
          '  sample id=$firstId asset=${r['asset_id']} ${inspectFaceEmb(raw)}',
        );
      } else if (ok == 2) {
        buf.writeln(
          '  pair $firstId-${r['id']} sim=${faceCosineSim(first, e)}',
        );
      }
    }
    buf.writeln(
      '  sampleDecodeOk=$ok sampleDecodeFail=$fail withNeg=$withNeg blobLenHist=$hist',
    );
    final sameAsset = await db.q('''
SELECT a.id id1, b.id id2, a.asset_id, a.embedding e1, b.embedding e2
FROM faces a JOIN faces b ON a.asset_id=b.asset_id AND a.id < b.id
ORDER BY a.asset_id, a.id LIMIT 8''');
    for (final r in sameAsset) {
      final e1 = decodeFaceEmb(r['e1']);
      final e2 = decodeFaceEmb(r['e2']);
      if (e1 == null || e2 == null) {
        buf.writeln(
          '  sameAsset FAIL asset=${r['asset_id']} ${r['id1']}-${r['id2']}',
        );
        continue;
      }
      buf.writeln(
        '  sameAsset asset=${r['asset_id']} ${r['id1']}-${r['id2']} sim=${faceCosineSim(e1, e2)} ${inspectFaceEmb(r['e1'])}',
      );
    }
    if (persons.isNotEmpty) {
      final ph = <int, int>{};
      for (final r in persons) {
        final n = (r['n'] as num?)?.toInt() ?? -1;
        ph[n] = (ph[n] ?? 0) + 1;
      }
      buf.writeln('  personMeanEmbLenHist=$ph');
    }

    await out.writeAsString(buf.toString(), flush: true);
    debugPrint('[face] evidence ${out.path}\n$buf');
  }

  Float32List _probeUnit(int seed) {
    final v = Float32List(kFaceEmbDim);
    for (var i = 0; i < kFaceEmbDim; i++) {
      v[i] = ((i + seed * 17) % 11 - 5) * (i + 1) * 0.013;
    }
    v[0] = seed == 0 ? -0.55 : 0.42;
    v[1] = seed == 0 ? 0.31 : -0.37;
    return l2Normalize(v);
  }

  /// 传输页「补识别」：完全没检出脸的图重新排队。未分组（noise）不重跑。
  Future<void> requeueUnfaced() async {
    final db = _db;
    if (db == null) return;
    await db.run('''
UPDATE assets SET analyzed=0
WHERE kind IN ('image','video')
  AND id NOT IN (SELECT DISTINCT asset_id FROM faces)''');
    await scanPending();
    if (_q.isEmpty) {
      try {
        await _reclusterIfNeeded();
      } catch (e, st) {
        debugPrint('[face] requeue recluster failed: $e\n$st');
      }
    }
  }

  void enqueue(int assetId) {
    if (_q.contains(assetId)) return;
    _q.add(assetId);
    pending = _q.length + (_busy ? 1 : 0);
    if (jobs.every((j) => j.id != assetId)) {
      jobs.add(FaceJob(id: assetId, name: '照片 $assetId'));
      if (jobs.length > 400) jobs.removeRange(0, jobs.length - 400);
    }
    debugPrint(
      '[face] enqueue $assetId pending=$pending ready=$ready busy=$_busy',
    );
    notifyListeners();
    _pump();
  }

  void _armIdleScan() {
    _idleScan?.cancel();
    _idleScan = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!ready) return;
      if (_q.isNotEmpty) {
        _pump();
        return;
      }
      unawaited(scanPending());
    });
  }

  Future<String> _ensureModel(String name) async {
    final dir = await getApplicationSupportDirectory();
    final f = File(p.join(dir.path, 'models', name));
    if (!f.existsSync() || f.lengthSync() < 1000) {
      await f.parent.create(recursive: true);
      final data = await rootBundle.load('assets/models/$name');
      await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return f.path;
  }

  void _onMsg(dynamic msg) {
    if (msg is! Map || _wait == null || _wait!.isCompleted) return;
    final req = msg['req'];
    if (_waitReq != null && req != null && req != _waitReq) return;
    _wait!.complete(Map<String, dynamic>.from(msg));
  }

  Future<Map> _send(Map msg) async {
    final id = ++_reqSeq;
    msg['req'] = id;
    final c = Completer<Map>();
    _wait = c;
    _waitReq = id;
    _cmd!.send(msg);
    try {
      return await c.future.timeout(const Duration(seconds: 120));
    } on TimeoutException {
      if (_waitReq == id) {
        _wait = null;
        _waitReq = null;
      }
      return {'ok': false, 'err': 'timeout', 'req': id, 'id': msg['id']};
    }
  }

  Future<void> _pump() async {
    if (_busy || !ready) return;
    _busy = true;
    var didWork = false;
    var analyzedSinceCluster = 0;
    var clusteredOnce = _lastClusteredCount() > 0;
    var facesAtCluster = await _faceCount();
    try {
      while (_q.isNotEmpty && _db != null && ready) {
        final id = _q.removeFirst();
        pending = _q.length + 1;
        _setJob(id, state: 'running', status: '识别中…');
        notifyListeners();
        try {
          if (await _analyze(id)) {
            didWork = true;
            analyzedSinceCluster++;
          }
        } catch (e, st) {
          debugPrint('[face] asset $id failed: $e\n$st');
          _setJob(id, state: 'failed', status: '失败');
          try {
            await _db?.run('UPDATE assets SET analyzed=1 WHERE id=?', [id]);
          } catch (_) {}
        }
        notifyListeners();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final nFace = await _faceCount();
        if (shouldReclusterDuringScan(
          analyzedSinceCluster: analyzedSinceCluster,
          queueRemaining: _q.length,
          newFacesSinceCluster: nFace - facesAtCluster,
          alreadyClusteredOnce: clusteredOnce,
        )) {
          try {
            await _reclusterIfNeeded();
            clusteredOnce = true;
            analyzedSinceCluster = 0;
            facesAtCluster = nFace;
          } catch (e, st) {
            debugPrint('[face] mid-queue recluster failed: $e\n$st');
            _scheduleReclusterRetry();
          }
        }
      }
      pending = _q.length;
      if (_q.isEmpty) {
        if (didWork) {
          // 连传时等一会儿再聚，避免每张图都全量重聚把后续入队卡住。
          await Future<void>.delayed(const Duration(milliseconds: 1200));
          if (_q.isNotEmpty) return;
        }
        try {
          if (didWork) {
            await _recluster();
          } else {
            await _reclusterIfNeeded();
          }
        } catch (e, st) {
          debugPrint('[face] recluster failed: $e\n$st');
          _scheduleReclusterRetry();
        }
      }
    } finally {
      _busy = false;
      pending = _q.length;
      notifyListeners();
      if (_q.isNotEmpty && ready) {
        unawaited(_pump());
      }
    }
  }

  Future<int> _faceCount() async {
    final db = _db;
    if (db == null) return 0;
    return firstInt(await db.q('SELECT COUNT(*) c FROM faces')) ?? 0;
  }

  Future<void> _reclusterIfNeeded() async {
    final db = _db;
    final root = _root;
    if (db == null || root == null) return;
    final nFace = firstInt(await db.q('SELECT COUNT(*) c FROM faces')) ?? 0;
    if (nFace == 0) return;
    final nPerson = firstInt(await db.q('SELECT COUNT(*) c FROM persons')) ?? 0;
    final last = _lastClusteredCount();
    // noise 的 person_id 为空是预期；只有脸数量比上次聚类时多才重聚。
    if (nPerson > 0 && nFace <= last) return;
    await _recluster();
  }

  int _lastClusteredCount() {
    final root = _root;
    if (root == null) return 0;
    final f = File(p.join(root.path, '_face_last_n'));
    if (!f.existsSync()) return 0;
    return int.tryParse(f.readAsStringSync().trim()) ?? 0;
  }

  void _scheduleReclusterRetry() {
    if (_reclusterRetryScheduled || _db == null) return;
    _reclusterRetryScheduled = true;
    Future<void>.delayed(const Duration(seconds: 1), () async {
      _reclusterRetryScheduled = false;
      if (_db == null) return;
      if (_busy) {
        _scheduleReclusterRetry();
        return;
      }
      try {
        await _recluster();
      } catch (e, st) {
        debugPrint('[face] deferred recluster failed: $e\n$st');
      }
    });
  }

  void _rememberClusteredCount(int n) {
    final root = _root;
    if (root == null) return;
    try {
      File(p.join(root.path, '_face_last_n'))
          .writeAsStringSync('$n', flush: true);
    } catch (_) {}
  }

  /// 全量 DBSCAN。相册导入全部跑完后重聚一次。
  /// 会按脸重叠把旧人物的改名 / 认领 / 团员标记接回去，避免每次重聚都丢名字。
  Future<void> _recluster() async {
    final db = _db;
    if (db == null) return;
    // 进入慢计算前记下人物表版本：isolate 跑的这几秒里如果有人
    // 认领/改名/标记团员，本轮作废，下次用新快照重跑，绝不覆盖人工修改。
    final snapRev = db.personsRev;
    final oldFaceToPerson = <int, int>{};
    final faceAreas = <int, num>{};
    final oldAutoCovers = <int, int>{};
    for (final r in await db.q(
      'SELECT id, person_id, w*h area FROM faces WHERE person_id IS NOT NULL '
      'ORDER BY w*h DESC, id ASC',
    )) {
      oldFaceToPerson[(r['id'] as num).toInt()] =
          (r['person_id'] as num).toInt();
      final fid = (r['id'] as num).toInt();
      final pid = (r['person_id'] as num).toInt();
      faceAreas[fid] = (r['area'] as num?) ?? 0;
      oldAutoCovers.putIfAbsent(pid, () => fid);
    }
    final oldPersons = <int, OldPersonSnap>{};
    for (final r in await db.q(
      'SELECT id, name, mean_emb, created_at, member_status, member_marked_by, member_marked_at, cover_face_id FROM persons',
    )) {
      final id = (r['id'] as num).toInt();
      oldPersons[id] = OldPersonSnap(
        id: id,
        name: r['name']?.toString(),
        createdAt: (r['created_at'] as num?)?.toDouble(),
        mean: decodeFaceEmb(r['mean_emb']),
        memberStatus: (r['member_status'] as num?)?.toInt() ?? 0,
        memberMarkedBy: (r['member_marked_by'] as num?)?.toInt(),
        memberMarkedAt: (r['member_marked_at'] as num?)?.toDouble(),
        coverFaceId: (r['cover_face_id'] as num?)?.toInt(),
      );
    }
    for (final r in await db.q(
      'SELECT person_id, user_id FROM person_claims',
    )) {
      final pid = (r['person_id'] as num).toInt();
      final uid = (r['user_id'] as num).toInt();
      oldPersons[pid]?.claimUserIds.add(uid);
    }
    for (final r in await db.q(
      'SELECT person_id, user_id FROM claim_pending WHERE resolved_at IS NULL',
    )) {
      final pid = (r['person_id'] as num).toInt();
      final uid = (r['user_id'] as num).toInt();
      oldPersons[pid]?.pendingClaimUserIds.add(uid);
    }
    final rows = await db.q('SELECT id, embedding, w*h area FROM faces');
    for (final r in rows) {
      faceAreas[(r['id'] as num).toInt()] = (r['area'] as num?) ?? 0;
    }
    if (rows.isEmpty) return;
    // 主 isolate 先解码成自有向量：sqflite BLOB view 不能可靠送进 compute。
    // 解码几百张 512 维向量很快；N² DBSCAN 仍在后台 isolate。
    final prep = prepareFaceClusterRows(rows);
    if (prep.ids.isEmpty) {
      debugPrint(
        '[face] recluster abort: no valid embeddings rows=${rows.length} bad=${prep.nBad}',
      );
      return;
    }
    final ids = prep.ids;
    final embs = prep.embs;
    final nBad = prep.nBad;
    await Future<void>.delayed(Duration.zero);
    final packed = await clusterFacesOffload(embs);
    debugPrint('[face] ${packed[0]}');
    final labels = (packed[1] as List).cast<int>();
    debugPrint('[face] cluster-input n=${embs.length} bad=$nBad');
    await Future<void>.delayed(Duration.zero);
    final groups = <int, List<int>>{};
    var nNoise = 0;
    for (var i = 0; i < labels.length; i++) {
      final c = labels[i];
      if (c < 0) {
        nNoise++;
        continue;
      }
      groups.putIfAbsent(c, () => []).add(i);
    }
    final groupFaceIds = <List<int>>[];
    final groupMeans = <Float32List>[];
    for (final g in groups.values) {
      if (g.length < 2) continue;
      final dim = embs[g.first].length;
      final acc = Float32List(dim);
      for (final i in g) {
        for (var k = 0; k < dim; k++) {
          acc[k] += embs[i][k];
        }
      }
      for (var k = 0; k < dim; k++) {
        acc[k] /= g.length;
      }
      groupFaceIds.add([for (final i in g) ids[i]]);
      groupMeans.add(l2Normalize(acc));
    }
    final specs = preservePersonIdentities(
      groups: groupFaceIds,
      means: groupMeans,
      oldFaceToPerson: oldFaceToPerson,
      oldPersons: oldPersons,
    );
    // isolate 计算期间有人动过人物表：本轮作废，避免旧快照覆盖新的人工修改。
    if (db.personsRev != snapRev) {
      debugPrint(
        '[face] recluster aborted: persons changed during clustering (rev $snapRev -> ${db.personsRev})',
      );
      _scheduleReclusterRetry();
      return;
    }
    var nPerson = 0;
    final now = BoxDb.now();
    final committed = await db.txn((tx) async {
      // 上面的检查到真正取得 SQLite 写事务之间仍可能有人完成操作，
      // 因此在事务内部再核对共享版本号。
      if (db.personsRev != snapRev) return false;
      // 旧人物上的待确认先结束为历史记录；能映射到新簇的关系在下方重新激活。
      await tx.run(
        "UPDATE claim_pending SET resolved_at=?, reason='recluster_superseded' "
        'WHERE resolved_at IS NULL',
        [now],
      );
      await tx.run('DELETE FROM person_claims');
      await tx.run('DELETE FROM persons');
      await tx.run('UPDATE faces SET person_id=NULL');
      for (final spec in specs) {
        final claimedBy =
            spec.claimUserIds.isEmpty ? null : spec.claimUserIds.first;
        late final int pid;
        if (spec.keepId != null) {
          pid = spec.keepId!;
          await tx.exec(
            'INSERT INTO persons(id, mean_emb, name, claimed_by, created_at, '
            'member_status, member_marked_by, member_marked_at, cover_face_id) '
            'VALUES(?,?,?,?,?,?,?,?,?)',
            [
              pid,
              encodeFaceEmb(spec.mean),
              spec.name,
              claimedBy,
              spec.createdAt ?? BoxDb.now(),
              spec.memberStatus,
              spec.memberMarkedBy,
              spec.memberMarkedAt,
              spec.coverFaceId,
            ],
          );
        } else {
          pid = await tx.exec(
            'INSERT INTO persons(mean_emb, name, claimed_by, created_at, '
            'member_status, member_marked_by, member_marked_at, cover_face_id) '
            'VALUES(?,?,?,?,?,?,?,?)',
            [
              encodeFaceEmb(spec.mean),
              spec.name,
              claimedBy,
              BoxDb.now(),
              spec.memberStatus,
              spec.memberMarkedBy,
              spec.memberMarkedAt,
              spec.coverFaceId,
            ],
          );
        }
        for (final fid in spec.faceIds) {
          await tx.run('UPDATE faces SET person_id=? WHERE id=?', [pid, fid]);
        }
        // 一对一：有效认领最多一个；撞簇的账号转入待确认，不静默保留。
        for (final uid in spec.claimUserIds) {
          await tx.exec(
            'INSERT OR IGNORE INTO person_claims(person_id, user_id, created_at) VALUES(?,?,?)',
            [pid, uid, now],
          );
        }
        for (final uid in spec.pendingClaimUserIds) {
          await tx.run(
            "UPDATE claim_pending SET created_at=?, pending_at=?, "
            "reason='recluster_conflict', resolved_at=NULL "
            'WHERE person_id=? AND user_id=?',
            [now, now, pid, uid],
          );
          await tx.exec(
            'INSERT OR IGNORE INTO claim_pending(person_id, user_id, created_at, pending_at, reason) '
            "VALUES(?,?,?,?, 'recluster_conflict')",
            [pid, uid, now, now],
          );
        }
        nPerson++;
        final oldCover = oldPersons[pid]?.coverFaceId ?? oldAutoCovers[pid];
        final newCover = effectivePersonCover(
          spec.faceIds,
          spec.coverFaceId,
          faceAreas,
        );
        if (oldCover != newCover) {
          try {
            File(p.join(thumbs.path, 'person_$pid.jpg')).deleteSync();
          } catch (_) {}
        }
      }
      final kept = specs.map((s) => s.keepId).toSet();
      for (final pid in oldPersons.keys.where((id) => !kept.contains(id))) {
        try {
          File(p.join(thumbs.path, 'person_$pid.jpg')).deleteSync();
        } catch (_) {}
      }
      return true;
    });
    if (!committed) {
      debugPrint(
        '[face] recluster aborted before write: persons changed while waiting for transaction',
      );
      _scheduleReclusterRetry();
      return;
    }
    // 重聚类自身也改了人物表：版本号前进，让并发的其它快照失效。
    db.bumpPersonsRev();
    _rememberClusteredCount(ids.length);
    clusterEpoch++;
    notifyListeners();
    debugPrint(
      '[face] dbscan ${ids.length} faces -> $nPerson persons noise=$nNoise metric=$kClusterMetric thr=$kClusterThreshold minPts=$kMinPts',
    );
  }

  /// 素材没好或解码失败：先不写 analyzed=1，等封面/预览落盘后再扫到。
  /// 超过次数才永久放弃，避免空转。
  Future<bool> _deferAnalyze(int id, {required String reason}) async {
    final cap = switch (reason) {
      'not_ready' => kFaceNotReadyMaxTries,
      'decode_failed' => kFaceDecodeMaxTries,
      'timeout' => kFaceTimeoutMaxTries,
      _ => 1,
    };
    final key = '$id:$reason';
    final n = (_failTries[key] ?? 0) + 1;
    _failTries[key] = n;
    if (decideFaceRetry(reason: reason, tries: n) == FaceAnalyzeRetry.wait) {
      _setJob(id, state: 'queued', status: faceRetryStatus(reason, n, cap));
      return false;
    }
    _failTries.removeWhere((k, _) => k.startsWith('$id:'));
    try {
      await _db?.run('UPDATE assets SET analyzed=1 WHERE id=?', [id]);
    } catch (_) {}
    _setJob(
      id,
      state: 'failed',
      status: reason == 'not_ready' ? '没有可识别的图' : '识别失败',
    );
    return false;
  }

  void _setJob(
    int id, {
    String? state,
    String? status,
    int? faces,
    String? name,
  }) {
    FaceJob? j;
    for (final e in jobs) {
      if (e.id == id) {
        j = e;
        break;
      }
    }
    if (j == null) {
      j = FaceJob(id: id, name: name ?? '照片 $id');
      jobs.add(j);
    }
    if (name != null) j.name = name;
    if (state != null) j.state = state;
    if (status != null) j.status = status;
    if (faces != null) j.faces = faces;
  }

  Future<bool> _analyze(int id) async {
    final db = _db!;
    final a = await db.qOne('SELECT * FROM assets WHERE id=?', [id]);
    if (a == null) return false;
    _setJob(id, name: (a['orig_name'] ?? '照片 $id').toString());
    if ((a['analyzed'] as num?)?.toInt() == 1) {
      _setJob(id, state: 'done', status: '已处理');
      return false;
    }
    if (!ready || _cmd == null) {
      debugPrint(
        '[face] $id analyze skipped: ready=$ready cmd=${_cmd != null}',
      );
      return false;
    }
    final kind = (a['kind'] ?? 'image').toString();
    final ext = (a['ext'] ?? '').toString();
    final origF = File(p.join(orig.path, '$id.$ext'));
    final thumbF = File(p.join(thumbs.path, '$id.jpg'));
    final webpF = File(p.join(thumbs.path, '$id.webp'));
    final failedPaths = <String>{};
    late Map r;
    late FaceSourceCandidate src;
    while (true) {
      final candidates = faceSourceCandidates(
        kind: kind,
        origPath: origF.path,
        origExists: origF.existsSync(),
        thumbPath: thumbF.path,
        thumbExists: thumbF.existsSync(),
        webpPath: webpF.path,
        webpExists: webpF.existsSync(),
      );
      final next = nextFaceSource(candidates, failedPaths);
      if (next == null) {
        final notReady = faceMaterialNotReady(
          kind: kind,
          origExists: origF.existsSync(),
          hasPreview: candidates.isNotEmpty,
        );
        return _deferAnalyze(
          id,
          reason:
              notReady || candidates.isEmpty ? 'not_ready' : 'decode_failed',
        );
      }
      src = next;
      r = await _send({
        'cmd': 'run',
        'id': id,
        'path': src.path,
        'ow': a['width'] ?? 0,
        'oh': a['height'] ?? 0,
      });
      // 识别在 isolate 里可能跑很久：回来时作品可能已被删除。
      // 不再写 faces，避免出现引用已删作品的孤儿脸（人物统计会算上它们）。
      if (await db.qOne('SELECT id FROM assets WHERE id=?', [id]) == null) {
        _setJob(id, state: 'failed', status: '作品已删除');
        return false;
      }
      if (r['ok'] != false) break;
      debugPrint('[face] $id ${r['err']} src=${src.role}');
      if (isFaceDecodeFailed(r['err'])) {
        failedPaths.add(src.path);
        continue;
      }
      if (r['err'] == 'timeout') {
        return _deferAnalyze(id, reason: 'timeout');
      }
      return _deferAnalyze(id, reason: 'error');
    }
    _failTries.removeWhere((k, _) => k.startsWith('$id:'));
    final faces = (r['faces'] as List?) ?? const [];
    final rejected = (r['rejected'] as num?)?.toInt() ?? 0;
    debugPrint('[face] $id hits=${faces.length} rejected=$rejected');
    var n = 0;
    final committed = await writeFaceAnalysisIfPresent(db, id, (tx) async {
      Float32List? firstRecv;
      await tx.run('DELETE FROM faces WHERE asset_id=?', [id]);
      for (final raw in faces) {
        if (raw is! Map) continue;
        final payload = raw['emb'];
        final emb = decodeFaceEmb(payload);
        if (emb == null) {
          debugPrint(
            '[face] $id skip face: bad embedding ${inspectFaceEmb(payload)}',
          );
          continue;
        }
        if (n == 0) {
          debugPrint('[face] $id recv ${inspectFaceEmb(payload)}');
          firstRecv = emb;
        } else if (n == 1 && firstRecv != null) {
          debugPrint(
            '[face] $id recvPair sim=${faceCosineSim(firstRecv, emb).toStringAsFixed(6)}',
          );
        }
        // 先写入 faces，暂不绑 person；队列清空后全量 DBSCAN。
        final fid = await tx.exec(
          'INSERT INTO faces(asset_id,x,y,w,h,embedding) VALUES(?,?,?,?,?,?)',
          [
            id,
            raw['x'] ?? 0,
            raw['y'] ?? 0,
            raw['w'] ?? 1,
            raw['h'] ?? 1,
            encodeFaceEmb(emb),
          ],
        );
        if (_sqliteRtLogged < 4) {
          final row = await tx.qOne('SELECT embedding FROM faces WHERE id=?', [
            fid,
          ]);
          final backRaw = row?['embedding'];
          final back = decodeFaceEmb(backRaw);
          if (back == null) {
            debugPrint(
              '[face] sqlite-rt FAIL id=$fid ${inspectFaceEmb(backRaw)}',
            );
          } else {
            debugPrint(
              '[face] sqlite-rt id=$fid ${inspectFaceEmb(backRaw)} maxAbsErr=${faceEmbMaxAbsDiff(emb, back)} selfSim=${faceCosineSim(emb, back).toStringAsFixed(8)}',
            );
          }
          _sqliteRtLogged++;
        }
        n++;
      }
      await tx.run('UPDATE assets SET analyzed=1 WHERE id=?', [id]);
    });
    if (!committed) {
      _setJob(id, state: 'failed', status: '作品已删除');
      return false;
    }
    _setJob(
      id,
      state: 'done',
      faces: n,
      status: n == 0 ? '未检测到人脸' : '识别到 $n 张脸',
    );
    return true;
  }
}

/// 给定两张脸 embedding，打印 sim / cos_dist / L2，避免再混度量。
void debugFacePairMetrics(List<double> a, List<double> b) {
  final m = facePairMetrics(a, b);
  debugPrint('[face] pair $m');
}

int? firstInt(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) return null;
  final v = rows.first.values.first;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return null;
}
