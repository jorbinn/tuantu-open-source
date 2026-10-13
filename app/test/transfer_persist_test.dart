// 传输任务：附件字段持久化往返、历史裁剪不丢未传任务。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/transfer.dart';
import 'package:tuantu_app/upload_prep.dart';

void main() {
  setUp(() {
    TransferStore.I.jobs.clear();
    TransferStore.I.running = false;
    TransferStore.I.peekBoxId = Api.peekBoxId;
    TransferStore.I.sendUpload = null;
    Api.I.configure('http://box-a.test:8000', 'token-a');
    Api.I.boxId = 'box-a';
    Api.I.userId = 1;
  });

  test('TransferJob 附件和读卡器任务字段能存能读', () {
    final j = TransferJob(
      id: '1',
      path: '/tmp/a.heic',
      name: 'a.heic',
      createdAt: 100,
      livePath: '/tmp/a.mov',
      liveRequired: true,
      previewPath: '/tmp/a.jpg',
      takenAt: 1770000000,
      sourceUri: 'content://card/DCIM/a.heic',
      uploaderId: 7,
      uploaderName: '摄影师',
      boxId: 'box-a',
      targetBase: 'http://192.168.50.42:8000',
      targetToken: 'tok-a',
      sessionUserId: 3,
    );
    final back = TransferJob.fromJson(j.toJson());
    expect(back.livePath, '/tmp/a.mov');
    expect(back.liveRequired, isTrue);
    expect(back.previewPath, '/tmp/a.jpg');
    expect(back.takenAt, 1770000000);
    expect(back.sourceUri, 'content://card/DCIM/a.heic');
    expect(back.uploaderId, 7);
    expect(back.uploaderName, '摄影师');
    expect(back.boxId, 'box-a');
    expect(back.targetBase, 'http://192.168.50.42:8000');
    expect(back.targetToken, 'tok-a');
    expect(back.sessionUserId, 3);
  });

  test('Live 必需标记杀进程后仍在，缺附件时不能当静图重试', () {
    final j = TransferJob(
      id: 'live-req',
      path: '/tmp/b.jpg',
      name: 'b.jpg',
      createdAt: 2,
      liveRequired: true,
    );
    expect(TransferJob.fromJson(j.toJson()).liveRequired, isTrue);
    expect(TransferJob.fromJson(j.toJson()).livePath, isNull);
  });

  test('缺目标信息的旧任务不能猜成当前盒子', () {
    final old = TransferJob.fromJson({
      'id': 'legacy',
      'path': '/tmp/a.jpg',
      'name': 'a.jpg',
      'createdAt': 1,
      'state': 'failed',
    });
    expect(
      transferDestinationError(job: old, remoteBoxId: 'box-a'),
      contains('旧任务'),
    );
  });

  test('同地址换盒子或重建库时拒绝发送', () {
    final j = TransferJob(
      id: '2',
      path: '/tmp/a.jpg',
      name: 'a.jpg',
      createdAt: 1,
      boxId: 'box-a',
      targetBase: 'http://192.168.50.42:8000',
      targetToken: 'tok-a',
    );
    expect(
      transferDestinationError(job: j, remoteBoxId: 'box-b'),
      contains('已更换'),
    );
    expect(
      transferDestinationError(job: j, remoteBoxId: null),
      contains('已更换'),
      reason: '旧服务没有 box_id 也不能当成原来那个盒子',
    );
  });

  test('旧服务没有 box_id 时，只要任务也没有，就仍发往记下的地址和 token', () {
    final j = TransferJob(
      id: '3',
      path: '/tmp/a.jpg',
      name: 'a.jpg',
      createdAt: 1,
      targetBase: 'http://192.168.50.42:8000',
      targetToken: 'tok-old',
    );
    expect(transferDestinationError(job: j, remoteBoxId: null), isNull);
  });

  test('301 个任务裁剪：排队中的不被裁掉', () {
    final store = TransferStore.I;
    store.jobs.clear();
    // 350 个已结束的旧任务 + 5 个排队中的新任务
    for (var i = 0; i < 350; i++) {
      final j = TransferJob(
        id: 'old$i',
        path: '/tmp/o$i.jpg',
        name: 'o$i.jpg',
        createdAt: 1000 + i,
        state: 'done',
      );
      store.jobs.add(j);
    }
    for (var i = 0; i < 5; i++) {
      final j = TransferJob(
        id: 'q$i',
        path: '/tmp/q$i.jpg',
        name: 'q$i.jpg',
        createdAt: 9000 + i,
        state: i == 0 ? 'uploading' : 'queued',
      );
      store.jobs.add(j);
    }
    store.trimHistory();
    expect(store.jobs.length, lessThanOrEqualTo(305));
    for (var i = 0; i < 5; i++) {
      expect(store.jobs.any((j) => j.id == 'q$i'), isTrue,
          reason: '排队/上传中的任务不允许被历史裁剪掉');
    }
    // 裁掉的是最旧的已结束任务
    expect(store.jobs.any((j) => j.id == 'old0'), isFalse);
  });

  test('新建任务绑到当前盒子；切会话后不会发到新盒子', () async {
    final store = TransferStore.I;
    final tmp = File('${Directory.systemTemp.path}/tuantu_tx_bind.jpg')
      ..writeAsBytesSync([1, 2, 3]);
    final job = store.add(tmp.path, day: '2026-01-01');
    expect(job.boxId, 'box-a');
    expect(job.targetBase, 'http://box-a.test:8000');
    expect(job.targetToken, 'token-a');
    expect(job.sessionUserId, 1);

    Api.I.configure('http://box-b.test:8000', 'token-b');
    Api.I.boxId = 'box-b';
    Api.I.userId = 9;

    final sent = <String>[];
    store.peekBoxId = (base) async =>
        base.contains('box-a') ? 'box-b' : 'box-b'; // 同地址已换成新盒子
    store.sendUpload = (j, path,
        {live, preview, extra = const {}, asUserId}) async {
      sent.add('${j.targetBase}|${j.targetToken}|$asUserId');
      return {
        'accepted': [
          {'id': 1}
        ]
      };
    };
    await store.retry(job);
    expect(sent, isEmpty, reason: '地址上的盒子身份变了，不能把照片传到新库');
    expect(job.state, 'failed');
    expect(job.err, contains('已更换'));
    try {
      tmp.deleteSync();
    } catch (_) {}
  });

  test('在途上传保持原盒子，不跟随 Api.I 切换', () async {
    final store = TransferStore.I;
    final tmp = File('${Directory.systemTemp.path}/tuantu_tx_inflight.jpg')
      ..writeAsBytesSync([1, 2, 3]);
    final job = store.add(tmp.path, day: '2026-01-01');
    final gate = Completer<void>();
    final entered = Completer<void>();
    final captured = <String>[];
    store.peekBoxId = (base) async => 'box-a';
    store.sendUpload = (j, path,
        {live, preview, extra = const {}, asUserId}) async {
      captured.add('${j.targetBase}|${j.targetToken}|${j.boxId}');
      entered.complete();
      await gate.future;
      return {
        'accepted': [
          {'id': 8}
        ]
      };
    };
    final running = store.run();
    await entered.future;
    Api.I.configure('http://box-b.test:8000', 'token-b');
    Api.I.boxId = 'box-b';
    Api.I.userId = 2;
    gate.complete();
    await running;
    expect(captured, ['http://box-a.test:8000|token-a|box-a']);
    expect(job.state, 'done');
    try {
      tmp.deleteSync();
    } catch (_) {}
  });

  test('上传断线退避后恢复，重试仍固定原盒子和账号', () async {
    final store = TransferStore.I;
    final dir = Directory.systemTemp.createTempSync('tuantu_tx_weak_');
    final file = File('${dir.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
    final job = store.add(file.path, day: '2026-01-01');
    var uploads = 0;
    final targets = <String>[];
    store.peekBoxId = (_) async => 'box-a';
    store.sendUpload = (j, path,
        {live, preview, extra = const {}, asUserId}) async {
      targets.add('${j.targetBase}|${j.targetToken}|${j.boxId}');
      uploads++;
      if (uploads <= 2) {
        Api.I.configure('http://box-b.test:8000', 'token-b');
        Api.I.boxId = 'box-b';
        throw const SocketException('Connection reset by peer');
      }
      return {'accepted': [{'id': 81}]};
    };
    try {
      await store.run();
      expect(uploads, 3);
      expect(job.state, 'done');
      expect(targets.toSet(), {'http://box-a.test:8000|token-a|box-a'});
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('同一批并发上传只探测一次盒子身份', () async {
    final store = TransferStore.I;
    final dir = Directory.systemTemp.createTempSync('tuantu_tx_identity_');
    final a = File('${dir.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
    final b = File('${dir.path}/b.jpg')..writeAsBytesSync([4, 5, 6]);
    store.add(a.path, day: '2026-01-01');
    store.add(b.path, day: '2026-01-01');
    var probes = 0;
    final probeEntered = Completer<void>();
    final probeGate = Completer<void>();
    store.peekBoxId = (_) async {
      probes++;
      if (!probeEntered.isCompleted) probeEntered.complete();
      await probeGate.future;
      return 'box-a';
    };
    store.sendUpload = (job, path,
            {live, preview, extra = const {}, asUserId}) async =>
        {
          'accepted': [
            {'id': path.endsWith('a.jpg') ? 1 : 2}
          ]
        };

    final running = store.run();
    await probeEntered.future;
    await Future<void>.delayed(Duration.zero);
    expect(probes, 1, reason: '两个 worker 应共用同一个在途探测');
    probeGate.complete();
    await running;
    expect(probes, 1);
    expect(store.jobs.every((j) => j.state == 'done'), isTrue);
    dir.deleteSync(recursive: true);
  });

  test('原始文件名从入队到 meta/去重都保留，不覆盖缓存路径', () {
    final store = TransferStore.I;
    final job = store.add(
      '/var/mobile/Caches/id123_mtime_oIMG_1234.HEIC',
      name: 'IMG_1234.HEIC',
      day: '2026-04-01',
      takenAt: 1775000000,
    );
    expect(job.path, '/var/mobile/Caches/id123_mtime_oIMG_1234.HEIC');
    expect(job.name, 'IMG_1234.HEIC');
    expect(transferJobName(name: '', path: job.path),
        'id123_mtime_oIMG_1234.HEIC');
    job.state = 'done';
    expect(store.uploadedKeys, contains(uploadKey('IMG_1234.HEIC', '2026-04-01')));
    expect(store.uploadedKeys,
        isNot(contains(uploadKey('id123_mtime_oIMG_1234.HEIC', '2026-04-01'))));
    final extra = jsonEncode({
      job.name: {'taken_at': job.takenAt}
    });
    expect(extra, contains('IMG_1234.HEIC'));
    expect(jsonDecode(extra)['IMG_1234.HEIC']['taken_at'], 1775000000);
  });

  test('历史任务和文件/读卡器入口仍用各自的 name 字段', () {
    final old = TransferJob.fromJson({
      'id': 'legacy',
      'path': '/tmp/cache_xxx.jpg',
      'name': 'DSC_0001.JPG',
      'createdAt': 1,
      'state': 'failed',
    });
    expect(old.name, 'DSC_0001.JPG');
    expect(old.path, '/tmp/cache_xxx.jpg');
    final card = TransferStore.I.addCard(
      uri: 'content://card/DCIM/IMG_9.HEIC',
      name: 'IMG_9.HEIC',
      day: '2026-01-01',
      uploaderId: 2,
      uploaderName: '团员',
      takenAt: 10,
    );
    expect(card.path, '');
    expect(card.name, 'IMG_9.HEIC');
  });

  test('300 张以上批量入队只落一份队列，排队任务不被裁掉', () {
    final store = TransferStore.I;
    store.jobs.clear();
    for (var i = 0; i < 20; i++) {
      store.jobs.add(TransferJob(
        id: 'old$i',
        path: '/tmp/o$i.jpg',
        name: 'o$i.jpg',
        createdAt: i,
        state: 'done',
      ));
    }
    final added = store.addAll([
      for (var i = 0; i < 310; i++)
        (
          path: '/tmp/cache_$i.heic',
          name: 'IMG_${i.toString().padLeft(4, '0')}.HEIC',
          day: '2026-05-01',
          livePath: null,
          liveRequired: false,
          previewPath: null,
          takenAt: 1770000000 + i,
        ),
    ]);
    expect(added, hasLength(310));
    expect(added.first.name, 'IMG_0000.HEIC');
    expect(added.first.path, '/tmp/cache_0.heic');
    expect(store.jobs.where((j) => j.active).length, 310);
    expect(store.jobs.length, lessThanOrEqualTo(330));
    expect(store.jobs.where((j) => j.state == 'queued').length, 310);
  });

  test('恢复的旧失败任务缺目标信息时直接失败，不发到当前盒子', () async {
    final store = TransferStore.I;
    store.jobs.add(TransferJob(
      id: 'old-fail',
      path: '/tmp/x.jpg',
      name: 'x.jpg',
      createdAt: 1,
      state: 'failed',
      status: '❌ 失败',
    ));
    final sent = <String>[];
    store.peekBoxId = (base) async {
      sent.add('peek:$base');
      return 'box-a';
    };
    store.sendUpload = (j, path,
        {live, preview, extra = const {}, asUserId}) async {
      sent.add('send');
      return {
        'accepted': [
          {'id': 1}
        ]
      };
    };
    await store.retryFailed();
    expect(sent, isEmpty);
    expect(store.jobs.single.state, 'failed');
    expect(store.jobs.single.err, contains('旧任务'));
  });
}
