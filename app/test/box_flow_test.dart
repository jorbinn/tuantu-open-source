/// 盒子端到端：真实 HttpServer + ffi SQLite，验证上传补全、删除清理、分页。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tuantu_app/box/box_db.dart';
import 'package:tuantu_app/box/box_http.dart';
import 'package:tuantu_app/box/box_faces.dart' show writeFaceAnalysisIfPresent;
import 'package:tuantu_app/live_photo.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory root;
  late BoxDb db;
  late BoxHttp box;
  late HttpServer server;
  late String base;
  var handled = 0;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('tuantu_box_flow_');
    db = await BoxDb.open(p.join(root.path, 't.db'));
    box = BoxHttp(db, root);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    handled = 0;
    server.listen((req) async {
      try {
        await box.handle(req);
      } catch (_) {}
      handled++;
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await db.close();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<String> join(String name, {String? deviceId}) async {
    final c = HttpClient();
    final r = await _postJson(c, '$base/api/join', {
      'name': name,
      if (deviceId != null) 'device_id': deviceId,
    });
    c.close();
    return r['token'] as String;
  }

  test(
    'embedded Live round trip, concurrent recovery and status remain intact',
    () async {
      final token = await join('live-roundtrip');
      final clip = File('test/fixtures/live/sample.mp4').readAsBytesSync();
      final motion = buildMotionPhotoJpeg(
        _jpeg(96, 64, 150, 30, 90),
        clip,
        presentationTimestampUs: 500000,
      );
      final upload = await _upload(
        base,
        token,
        '----MotionRoundTrip',
        files: [('roundtrip_MP.jpg', motion)],
      );
      final item = upload['accepted'][0] as Map;
      final id = item['id'];
      expect(item['live_ready'], true);
      expect((await _getBytes(base, '/api/asset/$id/raw')).bytes, motion);
      final sidecar = File(p.join(root.path, 'orig', '$id.live.mp4'));
      await sidecar.delete();
      final requests = [
        for (var i = 0; i < 8; i++) _getBytes(base, '/api/asset/$id/live'),
      ];
      expect(
        (await _getJson(
          base,
          '',
          '/api/status',
        ).timeout(const Duration(seconds: 1)))['service'],
        'tuantu',
      );
      for (final response in await Future.wait(requests)) {
        expect(response.status, 200);
        expect(response.bytes, clip);
      }
      expect(
        (await db.qOne('SELECT live_pts FROM assets WHERE id=?', [
          id,
        ]))!['live_pts'],
        500000,
      );
      expect(File('${sidecar.path}.recover').existsSync(), false);
    },
  );

  test('HTTP Range有版本校验，If-Range不匹配必须返回整个新文件', () async {
    final token = await join('range-version', deviceId: 'range-version');
    final bytes = _jpeg(64, 64, 30, 60, 90);
    final upload = await _upload(base, token, 'range-version',
        files: [('range.jpg', bytes)]);
    final id = upload['accepted'][0]['id'];
    final client = HttpClient();
    try {
      final url = Uri.parse('$base/api/asset/$id/raw');
      final first = await (await client.getUrl(url)).close();
      final etag = first.headers.value('etag');
      await first.drain<void>();
      expect(etag, isNotNull);
      for (final valid in [true, false]) {
        final request = await client.getUrl(url);
        request.headers.set('Range', 'bytes=20-');
        request.headers.set('If-Range', valid ? etag! : '"old-version"');
        final response = await request.close();
        expect(response.statusCode, valid ? 206 : 200);
        final body = await response.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(body, valid ? bytes.sublist(20) : bytes);
      }
    } finally {
      client.close(force: true);
    }
  });

  test('集中加入50台新设备不碰撞，重连返回原账号', () async {
    final tokens = await Future.wait([
      for (var i = 0; i < 50; i++) join('集中加入$i', deviceId: 'join-burst-$i'),
    ]);
    expect(tokens.toSet(), hasLength(50));
    expect(tokens.every((t) => base64Url.decode(t).length == 32), isTrue);
    for (var i = 0; i < 50; i++) {
      expect(await join('改名$i', deviceId: 'join-burst-$i'), tokens[i]);
    }
  });

  group('连接生命线与设备身份', () {
    test('delete cannot interleave final face existence check and write', () async {
      final token = await join('face-delete-race');
      final uploaded = await _upload(base, token, 'face-delete',
          files: [('face-delete.jpg', _jpeg(32, 32, 40, 50, 60))]);
      final id = uploaded['accepted'][0]['id'] as int;
      final entered = Completer<void>();
      final release = Completer<void>();
      final write = writeFaceAnalysisIfPresent(db, id, (tx) async {
        entered.complete();
        await release.future;
        await tx.exec('INSERT INTO faces(asset_id,x,y,w,h,embedding) VALUES(?,?,?,?,?,?)',
            [id, 0, 0, 10, 10, Uint8List(16)]);
      });
      await entered.future;
      final client = HttpClient();
      final deleteReq = await client.deleteUrl(Uri.parse('$base/api/asset/$id'));
      deleteReq.headers.set('X-Token', token);
      final deletion = deleteReq.close();
      release.complete();
      expect(await write, true);
      final response = await deletion;
      expect(response.statusCode, 200);
      await response.drain<void>();
      client.close(force: true);
      expect(firstInt(await db.q('SELECT COUNT(*) FROM faces WHERE asset_id=?', [id])), 0);
      var called = false;
      expect(await writeFaceAnalysisIfPresent(db, id, (_) async { called = true; }), false);
      expect(called, false);
    });
    test(
      'preparing upload is hidden before pagination; status stays live',
      () async {
        final token = await join('publish-test', deviceId: 'publish-device');
        final old = await _upload(
          base,
          token,
          'old',
          files: [('old.jpg', _jpeg(48, 32, 10, 20, 30))],
        );
        final entered = Completer<void>();
        final release = Completer<void>();
        box.debugBeforeUploadPreparation = () async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        };
        final upload = _upload(
          base,
          token,
          'pending',
          files: [('new.jpg', _jpeg(48, 32, 20, 30, 40))],
        );
        await entered.future;
        try {
          expect(firstInt(await db.q('SELECT COUNT(*) c FROM assets')), 2);
          expect(
            firstInt(await db.q('SELECT COUNT(*) c FROM published_assets')),
            1,
          );
          final page = await _getJson(base, token, '/api/gallery?limit=1');
          expect(
            (page['items'] as List).single['id'],
            old['accepted'][0]['id'],
          );
          expect(
            (await _getJson(
              base,
              '',
              '/api/status',
            ).timeout(const Duration(seconds: 1)))['service'],
            'tuantu',
          );
        } finally {
          release.complete();
          await upload;
        }
        final ready = await db.qOne('SELECT id FROM assets WHERE orig_name=?', [
          'new.jpg',
        ]);
        expect(
          (await _getBytes(base, '/api/asset/${ready!['id']}/thumb')).status,
          200,
        );
        expect(
          firstInt(await db.q('SELECT COUNT(*) c FROM pending_uploads')),
          0,
        );
        expect(
          firstInt(await db.q('SELECT COUNT(*) c FROM published_assets')),
          2,
        );
      },
    );

    test(
      'concurrent historical-date dedupe uses the inserted date immediately',
      () async {
        final token = await join('date-race', deviceId: 'date-race-device');
        final responses = await Future.wait([
          for (var i = 0; i < 10; i++)
            _upload(
              base,
              token,
              'date-$i',
              files: [('historic.jpg', _jpeg(24, 24, i * 10, 20, 30))],
              meta: {
                'historic.jpg': {'taken_at': 1700000000},
              },
            ),
        ]);
        expect(
          responses.fold<int>(0, (n, r) => n + (r['accepted'] as List).length),
          1,
        );
        expect(firstInt(await db.q('SELECT COUNT(*) c FROM assets')), 1);
      },
    );

    test(
      'EXIF-date retry without client meta does not insert another copy',
      () async {
        final token = await join('exif-dedupe', deviceId: 'exif-device');
        final photo = im.Image(width: 32, height: 32);
        photo.exif.exifIfd['DateTimeOriginal'] = '2023:11:14 10:20:30';
        final jpeg = im.encodeJpg(photo);
        final first = await _upload(
          base,
          token,
          'exif-first',
          files: [('camera.jpg', jpeg)],
        );
        final second = await _upload(
          base,
          token,
          'exif-second',
          files: [('camera.jpg', jpeg)],
        );
        expect(first['accepted'], hasLength(1));
        expect(second['accepted'], isEmpty);
        expect(firstInt(await db.q('SELECT COUNT(*) c FROM assets')), 1);
      },
    );
    test('时间线和删除关联表的并发索引已建立', () async {
      final assetIndexes = {
        for (final row in await db.q('PRAGMA index_list(assets)')) row['name'],
      };
      expect(assetIndexes, contains('idx_assets_timeline_id'));
      expect(assetIndexes, contains('idx_assets_created_id'));
      expect(assetIndexes, contains('idx_assets_uploader_created_id'));
      expect(assetIndexes, contains('idx_assets_uploader_name_taken'));
      final viewIndexes = {
        for (final row in await db.q('PRAGMA index_list(views)')) row['name'],
      };
      final decisionIndexes = {
        for (final row in await db.q('PRAGMA index_list(decisions)'))
          row['name'],
      };
      expect(viewIndexes, contains('idx_views_asset'));
      expect(decisionIndexes, contains('idx_decisions_asset'));
    });

    test('同一设备改名重连仍是原账号；不同设备允许同名', () async {
      final first = await join('小明', deviceId: 'device-a');
      final renamedAttempt = await join('另一个名字', deviceId: 'device-a');
      final sameNameOtherDevice = await join('小明', deviceId: 'device-b');

      expect(renamedAttempt, first, reason: '设备身份固定，重连输入不能创建新账号');
      expect(sameNameOtherDevice, isNot(first), reason: '同名设备不能串成同一账号');
      expect(firstInt(await db.q('SELECT COUNT(*) c FROM users')), 2);
      final mine = await db.userByDevice('device-a');
      expect(mine?['name'], '小明', reason: '盒子返回并保留这个设备原来的显示名');
    });

    test('升级后的设备接管同名旧账号并保留 token', () async {
      final legacy = await join('老用户');
      final claimed = await join('老用户', deviceId: 'device-old-user');
      expect(claimed, legacy);
      expect((await db.userByDevice('device-old-user'))?['token'], legacy);
      expect(firstInt(await db.q('SELECT COUNT(*) c FROM users')), 1);
    });

    test('旧库迁移保留用户 id/token，并解除名字唯一限制', () async {
      final path = p.join(root.path, 'legacy.db');
      final raw = await databaseFactory.openDatabase(path);
      await raw.execute('''CREATE TABLE users(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT UNIQUE NOT NULL,
        token TEXT UNIQUE NOT NULL,
        is_admin INTEGER DEFAULT 0,
        avatar INTEGER NOT NULL DEFAULT 0,
        created_at REAL NOT NULL
      )''');
      await raw.insert('users', {
        'id': 7,
        'name': '原账号',
        'token': 'keep-token',
        'is_admin': 0,
        'avatar': 0,
        'created_at': 1.0,
      });
      await raw.close();

      final migrated = await BoxDb.open(path);
      final token = await migrated.ensureDeviceUser('device-legacy', '原账号');
      await migrated.ensureDeviceUser('device-new', '原账号');
      expect(token, 'keep-token');
      expect((await migrated.userByDevice('device-legacy'))?['id'], 7);
      expect(
        firstInt(
          await migrated.q('SELECT COUNT(*) c FROM users WHERE name=?', [
            '原账号',
          ]),
        ),
        2,
      );
      await migrated.close();
    });

    test('评论列表和刚发出的评论带上用户当前头像', () async {
      final alice = await join('alice');
      final bob = await join('bob');
      final photo = _jpeg(24, 24, 10, 20, 30);
      final up = await _upload(
        base,
        alice,
        '----CmtAv',
        files: [('a.jpg', photo)],
      );
      final id = (up['accepted'][0] as Map)['id'] as int;
      final bobUser = await db.userByName('bob');
      final bobId = bobUser!['id'] as int;
      await db.run('UPDATE users SET avatar=? WHERE id=?', [99, bobId]);

      final posted = await _postJsonToken(
        base,
        bob,
        '/api/asset/$id/comments',
        {'body': '好看'},
      );
      expect(posted['avatar'], '/api/user/$bobId/avatar?v=99');

      final listed = await _getJson(base, alice, '/api/asset/$id/comments');
      final comments = listed['comments'] as List;
      expect(comments, hasLength(1));
      expect(comments.single['avatar'], '/api/user/$bobId/avatar?v=99');
      expect(comments.single['name'], 'bob');
    });

    test('数据库事务繁忙时 status 仍立即响应', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final transaction = db.txn((tx) async {
        await tx.q('SELECT 1');
        entered.complete();
        await release.future;
      });
      await entered.future;
      final watch = Stopwatch()..start();
      final status = await _getJson(
        base,
        '',
        '/api/status',
      ).timeout(const Duration(milliseconds: 500));
      watch.stop();
      release.complete();
      await transaction;
      expect(status['service'], 'tuantu');
      expect(status['live_pair'], 1);
      expect(watch.elapsedMilliseconds, lessThan(500));
    });

    test('status 带稳定 box_id，不查库', () async {
      box.boxId = 'bx-test-identity';
      final entered = Completer<void>();
      final release = Completer<void>();
      final transaction = db.txn((tx) async {
        await tx.q('SELECT 1');
        entered.complete();
        await release.future;
      });
      await entered.future;
      final status = await _getJson(
        base,
        '',
        '/api/status',
      ).timeout(const Duration(milliseconds: 500));
      release.complete();
      await transaction;
      expect(status['box_id'], 'bx-test-identity');
      expect(status['service'], 'tuantu');
    });

    test('ensureBoxId 同库稳定、新库不同', () async {
      final a = await db.ensureBoxId();
      final b = await db.ensureBoxId();
      expect(a, b);
      expect(a, startsWith('bx-'));
      final otherPath = p.join(root.path, 'other.db');
      final other = await BoxDb.open(otherPath);
      final c = await other.ensureBoxId();
      await other.close();
      expect(c, isNot(a));
    });
  });

  group('问题1：上传中断与重试补附件', () {
    test('主文件传完附件未完时中断：不入库、无残留；重试后完整', () async {
      final token = await join('alice');
      final heic = utf8.encode('FAKE-HEIC-CONTENT-0123456789');
      const boundary = '----FlowBroken';
      final head = _multipartFull(boundary, [
        (name: 'files', filename: 'IMG_1.HEIC', data: heic),
      ]);
      final tail = _multipartFull(
        boundary,
        [(name: 'preview', filename: 'p.jpg', data: List.filled(8000, 9))],
        fields: {'meta': '{"IMG_1.HEIC": {"taken_at": 1770000000}}'},
      );
      final full = _concat(head, tail);

      // 1) 发送被掐断的请求（Content-Length 谎报，正文只给一半）
      await _sendBroken(
        base,
        '/api/upload',
        token,
        boundary,
        full,
        cutAt: head.length + 2000,
      );
      await _waitHandled(() => handled >= 1);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      var n = firstInt(await db.q('SELECT COUNT(*) c FROM assets'));
      expect(n, 0, reason: '附件没收完就断网，不允许出现半成品作品');
      expect(
        Directory(p.join(root.path, 'orig'))
            .listSync()
            .where((e) => p.basename(e.path).startsWith('_tmp_')),
        isEmpty,
        reason: '中断后不能残留临时文件',
      );

      // 2) 重试：整包重发（主文件 + preview + meta + live）
      final preview = _jpeg(30, 30, 80, 80, 80);
      final live = _ftyp(4000, 5);
      final r = await _upload(
        base,
        token,
        boundary,
        files: [('IMG_1.HEIC', heic)],
        preview: preview,
        live: live,
        meta: {
          'IMG_1.HEIC': {'taken_at': 1770000000},
        },
      );
      expect((r['repaired'] as List).length, 0);
      expect((r['accepted'] as List).length, 1);
      final id = (r['accepted'][0] as Map)['id'];

      final row = await db.qOne('SELECT * FROM assets WHERE id=?', [id]);
      expect(row, isNotNull);
      expect(row!['has_thumb'], 1, reason: 'preview 应已生成缩略图');
      expect(row['taken_at'], 1770000000.0, reason: 'meta 拍摄时间应已写入');
      expect(row['has_live'], 1, reason: '实况视频应已挂上');
      expect(
        File(p.join(root.path, 'orig', '$id.live.mp4')).existsSync(),
        true,
      );
      expect(File(p.join(root.path, 'thumbs', '$id.jpg')).existsSync(), true);
      final feed = await _getJson(
        base,
        token,
        '/api/gallery?view=all&limit=20',
      );
      final item = ((feed['items'] as List).first as Map);
      expect(item['live_ready'], 1);
    });

    test('乱码 live 附件不能把 has_live 标成真', () async {
      final token = await join('carol');
      const boundary = '----BadLive';
      final r = await _upload(
        base,
        token,
        boundary,
        files: [('IMG_bad.HEIC', utf8.encode('FAKE-HEIC-BAD'))],
        live: List.filled(4000, 9),
      );
      expect(r['accepted'], isNull);
      expect(firstInt(await db.q('SELECT COUNT(*) c FROM assets')), 0);
      expect(Directory(p.join(root.path, 'orig')).listSync(), isEmpty);
    });

    test('同作者重复上传补全缺失附件；跨作者保留各自作品', () async {
      final alice = await join('alice');
      final heic = utf8.encode('FAKE-HEIC-2');
      const boundary = '----FlowRepair';

      // alice 先传了主文件（没有附件——模拟上一次请求断在附件前）
      final r1 = await _upload(
        base,
        alice,
        boundary,
        files: [('IMG_2.HEIC', heic)],
        meta: {
          'IMG_2.HEIC': {'taken_at': 1770000123},
        },
      );
      final id = (r1['accepted'][0] as Map)['id'] as int;
      expect(
        (await db.qOne('SELECT has_thumb, has_live FROM assets WHERE id=?', [
          id,
        ])),
        {'has_thumb': 0, 'has_live': 0},
      );

      // alice 重试，这次带齐附件 → 补全
      final r2 = await _upload(
        base,
        alice,
        boundary,
        files: [('IMG_2.HEIC', heic)],
        preview: _jpeg(20, 20, 10, 200, 10),
        live: _ftyp(2500, 1),
        meta: {
          'IMG_2.HEIC': {'taken_at': 1770000123},
        },
      );
      expect(
          (r2['repaired'] as List),
          [
            {'id': id, 'name': 'IMG_2.HEIC', 'live_ready': true},
          ],
          reason: '同作者重传带附件应报「已补全」而不是「重复」');
      final row = await db.qOne('SELECT * FROM assets WHERE id=?', [id]);
      expect(row!['has_thumb'], 1);
      expect(row['has_live'], 1);
      expect(row['taken_at'], 1770000123.0);
      expect(
        firstInt(await db.q('SELECT COUNT(*) c FROM assets')),
        1,
        reason: '补全不能产生重复记录',
      );

      // bob 传同样内容 + 附件：是 bob 的独立作品，
      // 不得被 alice 的 SHA 记录挡住。
      final bob = await join('bob');
      final r3 = await _upload(
        base,
        bob,
        boundary,
        files: [('IMG_2.HEIC', heic)],
        preview: _jpeg(20, 20, 200, 10, 10),
        meta: {
          'IMG_2.HEIC': {'taken_at': 1666000000},
        },
      );
      expect((r3['accepted'] as List).length, 1);
      expect((r3['duplicates'] as List), isEmpty);
      expect((r3['repaired'] as List), isEmpty);
      final bobId = (await db.userByToken(bob))!['id'] as int;
      final after = await db.qOne('SELECT * FROM assets WHERE id=?', [id]);
      expect(after!['taken_at'], 1770000123.0, reason: '别人重传不能改拍摄时间');
      expect(after['uploader_id'], isNot(bobId));
      expect(firstInt(await db.q('SELECT COUNT(*) c FROM assets')), 2);
      final bobAsset = await db.qOne(
        'SELECT uploader_id FROM assets WHERE uploader_id=?',
        [bobId],
      );
      expect(bobAsset?['uploader_id'], bobId);
    });

    test('去重键是当前作者、原文件名和拍摄日', () async {
      final alice = await join('dedupe-key');
      const boundary = '----DedupeKey';
      final original = _jpeg(12, 12, 10, 20, 30);
      final changed = _jpeg(12, 12, 30, 20, 10);
      const taken = 1770000123;

      final first = await _upload(
        base,
        alice,
        boundary,
        files: [('same.jpg', original)],
        meta: {
          'same.jpg': {'taken_at': taken},
        },
      );
      final firstId = (first['accepted'][0] as Map)['id'] as int;
      final renamed = await _upload(
        base,
        alice,
        boundary,
        files: [('renamed.jpg', original)],
        meta: {
          'renamed.jpg': {'taken_at': taken},
        },
      );
      expect(
        (renamed['accepted'] as List),
        hasLength(1),
        reason: '同一内容改名后是另一件作品',
      );

      final sameNameDay = await _upload(
        base,
        alice,
        boundary,
        files: [('same.jpg', changed)],
        meta: {
          'same.jpg': {'taken_at': taken + 3600},
        },
      );
      expect(
        (sameNameDay['duplicates'] as List),
        hasLength(1),
        reason: '同作者同文件名同拍摄日应命中原作品',
      );
      expect(
        firstInt(
          await db.q('SELECT COUNT(*) c FROM assets WHERE id=?', [firstId]),
        ),
        1,
      );
      expect(firstInt(await db.q('SELECT COUNT(*) c FROM assets')), 2);
    });
  });

  group('存储卡代团员导入', () {
    test('盒子本机可列出团员，并把作品记到指定团员名下', () async {
      final host = await join('团长', deviceId: 'host-device');
      final photographer = await join('摄影师', deviceId: 'camera-owner');
      final photographerRow = await db.userByToken(photographer);
      final photographerId = photographerRow!['id'] as int;

      final users = await _getJson(base, host, '/api/users');
      expect(
        (users['items'] as List).map((e) => (e as Map)['name']),
        containsAll(['团长', '摄影师']),
      );

      final upload = await _upload(
        base,
        host,
        '----CardImport',
        files: [('DSCF0001.JPG', _jpeg(12, 12, 40, 90, 120))],
        asUserId: photographerId,
      );
      expect((upload['accepted'] as List), hasLength(1));
      final assetId = ((upload['accepted'] as List).first as Map)['id'] as int;
      final row = await db.qOne('SELECT uploader_id FROM assets WHERE id=?', [
        assetId,
      ]);
      expect(row?['uploader_id'], photographerId);
    });
  });

  group('问题2：删除作品清理全部关联', () {
    test(
      '删 Live Photo：faces/views/likes/comments/文件/人物封面全清，媒体接口 404',
      () async {
        final alice = await join('alice');
        final bob = await join('bob');
        final photo = _jpeg(24, 24, 60, 90, 130);
        final r = await _upload(
          base,
          alice,
          '----Del1',
          files: [('live.HEIC', utf8.encode('LIVE-HEIC'))],
          preview: photo,
          live: _ftyp(2000, 7),
        );
        final id = (r['accepted'][0] as Map)['id'] as int;

        // 造关联：bob 点赞、评论；alice 看过
        await _postWithToken(base, bob, '/api/like', {'asset_id': id});
        await _postWithToken(base, bob, '/api/asset/$id/comments', {
          'body': '好看',
        });
        await _postWithToken(base, alice, '/api/seen', {'asset_id': id});

        // 脸 + 人物 + 认领；另一张照片的脸也在这个人物上
        final now = BoxDb.now();
        await db.exec(
          'INSERT INTO faces(asset_id,x,y,w,h,embedding) VALUES(?,?,?,?,?,?)',
          [id, 1, 1, 10, 10, Uint8List(16)],
        );
        final faceId = await db.exec(
          'INSERT INTO faces(asset_id,x,y,w,h,embedding) VALUES(?,?,?,?,?,?)',
          [id, 2, 2, 20, 20, Uint8List(16)],
        );
        final pid = await db.exec(
          'INSERT INTO persons(mean_emb, created_at) VALUES(?,?)',
          [Uint8List(16), now],
        );
        await db.run('UPDATE faces SET person_id=? WHERE asset_id=?', [
          pid,
          id,
        ]);
        final bobId = (await db.userByName('bob'))!['id'];
        await db.exec(
          'INSERT OR IGNORE INTO person_claims(person_id, user_id, created_at) VALUES(?,?,?)',
          [pid, bobId, now],
        );
        final other = await _upload(
          base,
          bob,
          '----Del1',
          files: [('other.jpg', photo)],
        );
        final otherId = (other['accepted'][0] as Map)['id'] as int;
        await db.exec(
          'INSERT INTO faces(asset_id,x,y,w,h,embedding,person_id) VALUES(?,?,?,?,?,?,?)',
          [otherId, 3, 3, 30, 30, Uint8List(16), pid],
        );

        // 文件：webp 缩略图、脸裁剪缓存、人物封面缓存
        final thumbs = Directory(p.join(root.path, 'thumbs'));
        thumbs.createSync(recursive: true);
        File(p.join(thumbs.path, '$id.webp')).writeAsBytesSync(photo);
        File(p.join(thumbs.path, 'face_$faceId.jpg')).writeAsBytesSync(photo);
        File(p.join(thumbs.path, 'person_$pid.jpg')).writeAsBytesSync(photo);

        // 删除
        expect(
          await _httpStatus(base, alice, '/api/asset/$id', method: 'DELETE'),
          200,
        );

        // 数据库：作品和所有关联记录消失
        expect(await db.qOne('SELECT * FROM assets WHERE id=?', [id]), isNull);
        expect(
          firstInt(
            await db.q('SELECT COUNT(*) c FROM faces WHERE asset_id=?', [id]),
          ),
          0,
          reason: '删除作品的 faces 必须清掉，否则人物统计仍包含已删作品',
        );
        expect(
          firstInt(
            await db.q('SELECT COUNT(*) c FROM views WHERE asset_id=?', [id]),
          ),
          0,
        );
        expect(
          firstInt(
            await db.q('SELECT COUNT(*) c FROM likes WHERE asset_id=?', [id]),
          ),
          0,
        );
        expect(
          firstInt(
            await db.q('SELECT COUNT(*) c FROM comments WHERE asset_id=?', [
              id,
            ]),
          ),
          0,
        );
        // 人物保留（另一张照片还有脸），认领关系保留
        expect(
          await db.qOne('SELECT * FROM persons WHERE id=?', [pid]),
          isNotNull,
        );
        expect(
          firstInt(
            await db.q(
              'SELECT COUNT(*) c FROM person_claims WHERE person_id=?',
              [pid],
            ),
          ),
          1,
          reason: '不能误删别人的认领关系',
        );
        expect(
          firstInt(
            await db.q('SELECT COUNT(*) c FROM faces WHERE person_id=?', [pid]),
          ),
          1,
          reason: '只剩另一张照片的 1 张脸',
        );

        // 文件清理带重试，给足时间
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(
          File(p.join(root.path, 'orig', '$id.heic')).existsSync(),
          false,
          reason: '原件',
        );
        expect(
          File(p.join(root.path, 'orig', '$id.live.mp4')).existsSync(),
          false,
          reason: '实况视频',
        );
        expect(
          File(p.join(thumbs.path, '$id.jpg')).existsSync(),
          false,
          reason: 'jpg 缩略图',
        );
        expect(
          File(p.join(thumbs.path, '$id.webp')).existsSync(),
          false,
          reason: 'webp 缩略图',
        );
        expect(
          File(p.join(thumbs.path, 'face_$faceId.jpg')).existsSync(),
          false,
          reason: '脸裁剪缓存',
        );
        expect(
          File(p.join(thumbs.path, 'person_$pid.jpg')).existsSync(),
          false,
          reason: '人物封面缓存要失效，下次重新生成',
        );

        // 媒体接口不能再读到被删内容
        expect(await _httpStatus(base, null, '/api/asset/$id/thumb'), 404);
        expect(await _httpStatus(base, null, '/api/asset/$id/raw'), 404);
        expect(await _httpStatus(base, null, '/api/asset/$id/live'), 404);
        expect(
          await _httpStatus(base, null, '/api/asset/$id/face/$faceId'),
          404,
        );
      },
    );

    test('只能删自己的', () async {
      final alice = await join('alice');
      final bob = await join('bob');
      final r = await _upload(
        base,
        alice,
        '----Del2',
        files: [('a.jpg', _jpeg(10, 10, 1, 2, 3))],
      );
      final id = (r['accepted'][0] as Map)['id'];
      expect(
        await _httpStatus(base, bob, '/api/asset/$id', method: 'DELETE'),
        403,
      );
      expect(
        await _httpStatus(base, alice, '/api/asset/$id', method: 'DELETE'),
        200,
      );
    });

    test('孤儿清扫：库里不存在的作品文件与 _tmp_ 清掉，在库的保留', () async {
      final alice = await join('alice');
      final r = await _upload(
        base,
        alice,
        '----Sweep',
        files: [('keep.jpg', _jpeg(10, 10, 9, 9, 9))],
      );
      final keepId = (r['accepted'][0] as Map)['id'] as int;
      final orig = Directory(p.join(root.path, 'orig'));
      final thumbs = Directory(p.join(root.path, 'thumbs'))
        ..createSync(recursive: true);
      File(p.join(orig.path, '999.jpg')).writeAsBytesSync([1, 2, 3]);
      File(p.join(orig.path, '999.live.mp4')).writeAsBytesSync([4]);
      File(p.join(orig.path, '_tmp_live_abandoned')).writeAsBytesSync([5]);
      File(p.join(thumbs.path, '999.jpg')).writeAsBytesSync([6]);
      File(p.join(thumbs.path, 'face_888.jpg')).writeAsBytesSync([7]);
      File(p.join(thumbs.path, 'person_777.jpg')).writeAsBytesSync([8]);

      final removed = await box.sweepOrphanFiles();

      expect(
        File(p.join(orig.path, '$keepId.jpg')).existsSync(),
        true,
        reason: '在库的保留',
      );
      expect(File(p.join(orig.path, '999.jpg')).existsSync(), false);
      expect(File(p.join(orig.path, '999.live.mp4')).existsSync(), false);
      expect(
        File(p.join(orig.path, '_tmp_live_abandoned')).existsSync(),
        false,
      );
      expect(File(p.join(thumbs.path, '999.jpg')).existsSync(), false);
      expect(File(p.join(thumbs.path, 'face_888.jpg')).existsSync(), false);
      expect(File(p.join(thumbs.path, 'person_777.jpg')).existsSync(), false);
      expect(removed, greaterThanOrEqualTo(6));
    });

    test('清扫快照后新上传、在途临时文件和缩略图不被删', () async {
      final alice = await join('alice');
      final orig = Directory(p.join(root.path, 'orig'))
        ..createSync(recursive: true);
      final thumbs = Directory(p.join(root.path, 'thumbs'))
        ..createSync(recursive: true);
      File(p.join(orig.path, '999.jpg')).writeAsBytesSync([1, 2, 3]);
      File(p.join(orig.path, '_tmp_old_crash')).writeAsBytesSync([9]);

      final liveTmp = File(p.join(orig.path, '_tmp_writing_now'));
      liveTmp.writeAsBytesSync([7, 7, 7]);
      box.markLiveFile(liveTmp.path);

      final pause = Completer<void>();
      box.debugAfterOrphanSnapshot = () => pause.future;
      final sweepFut = box.sweepOrphanFiles();
      final up = await _upload(
        base,
        alice,
        '----SweepRace',
        files: [('fresh.jpg', _jpeg(10, 10, 3, 4, 5))],
      );
      final freshId = (up['accepted'][0] as Map)['id'] as int;
      final freshThumb = File(p.join(thumbs.path, '$freshId.jpg'));
      if (!freshThumb.existsSync()) {
        box.markLiveFile(freshThumb.path);
        freshThumb.writeAsBytesSync([8, 8]);
      }
      pause.complete();
      final removed = await sweepFut;
      box.debugAfterOrphanSnapshot = null;

      expect(
        File(p.join(orig.path, '$freshId.jpg')).existsSync(),
        true,
        reason: '快照后新入库的原片不能当孤儿删',
      );
      expect(liveTmp.existsSync(), true, reason: '正在写的临时文件不能删');
      expect(
        File(p.join(orig.path, '999.jpg')).existsSync(),
        false,
        reason: '历史孤儿仍要清',
      );
      expect(
        File(p.join(orig.path, '_tmp_old_crash')).existsSync(),
        false,
        reason: '上次中断的 _tmp_ 仍要清',
      );
      expect(removed, greaterThanOrEqualTo(2));
      box.unmarkLiveFile(liveTmp.path);
      box.unmarkLiveFile(freshThumb.path);
    });
  });

  group('问题3：相册分页复合游标', () {
    test('120 张同拍摄时间：翻完所有页不漏不重；旧客户端兼容', () async {
      final alice = await join('alice');
      // 120 张同秒 + 3 张更早的，全部走库直插（省时间）
      const stamp = 1770001000.0;
      final rows = <List<Object?>>[];
      for (var i = 0; i < 120; i++) {
        rows.add([
          alice.hashCode >= 0 ? 1 : 1,
          'sha-$i',
          'same_$i.jpg',
          'jpg',
          'image',
          10,
          8,
          null,
          null,
          stamp,
          0,
          1,
          stamp,
        ]);
      }
      for (var i = 0; i < 3; i++) {
        rows.add([
          1,
          'old-$i',
          'old_$i.jpg',
          'jpg',
          'image',
          10,
          8,
          null,
          null,
          1770000000.0,
          0,
          1,
          1770000000.0,
        ]);
      }
      final now = BoxDb.now();
      final uid = (await db.userByName('alice'))!['id'];
      for (final r in rows) {
        r[0] = uid;
        r[12] = now;
      }
      for (final r in rows) {
        await db.exec(
          'INSERT INTO assets(uploader_id, sha256, orig_name, ext, kind, size, width, height, '
          'duration, taken_at, has_thumb, analyzed, created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
          r,
        );
      }

      // 新客户端：cursor + cursor_id 复合游标
      final seen = <int>[];
      double? cur;
      int? curId;
      var pages = 0;
      while (true) {
        final qp = 'view=all&limit=20&sort=time'
            '${cur != null ? '&cursor=$cur' : ''}'
            '${curId != null ? '&cursor_id=$curId' : ''}';
        final d = await _getJson(base, alice, '/api/gallery?$qp');
        final items = (d['items'] as List).cast<Map>();
        if (items.isEmpty) break;
        seen.addAll(items.map((e) => e['id'] as int));
        cur = (d['cursor'] as num?)?.toDouble();
        curId = (d['cursor_id'] as num?)?.toInt();
        pages++;
        if (items.length < 20) break;
        if (pages > 20) fail('页数异常');
      }
      expect(seen.toSet().length, seen.length, reason: '不能重复');
      expect(seen.length, 123, reason: '120 张同秒 + 3 张早的，一张不漏');

      // 旧客户端：只传 cursor（无 cursor_id）也能翻页（允许同秒边界漏，但不得报错/死循环）
      final legacySeen = <int>[];
      var legacyCur = (await _getJson(
        base,
        alice,
        '/api/gallery?view=all&limit=20&sort=time',
      ))['cursor'];
      var first = true;
      var legacyPages = 0;
      while (legacyCur != null) {
        final d = first
            ? await _getJson(
                base,
                alice,
                '/api/gallery?view=all&limit=20&sort=time',
              )
            : await _getJson(
                base,
                alice,
                '/api/gallery?view=all&limit=20&sort=time&cursor=$legacyCur',
              );
        first = false;
        final items = (d['items'] as List).cast<Map>();
        if (items.isEmpty) break;
        legacySeen.addAll(items.map((e) => e['id'] as int));
        legacyCur = d['cursor'];
        legacyPages++;
        if (legacyPages > 20) fail('旧客户端死循环');
        if (items.length < 20) break;
      }
      expect(legacySeen.toSet().length, legacySeen.length, reason: '旧客户端不重复');
    });
  });

  group('信息流生命线：thumb 不等抽帧', () {
    test('没封面的视频 /api/thumb 立刻 404，不把请求挂到抽帧结束', () async {
      await join('alice');
      final uid = (await db.userByName('alice'))!['id'];
      final id = await db.exec(
        'INSERT INTO assets(uploader_id, sha256, orig_name, ext, kind, size, width, height, '
        'duration, taken_at, has_thumb, analyzed, created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
        [
          uid,
          'sha-vid-nocover',
          'clip.mp4',
          'mp4',
          'video',
          100,
          0,
          0,
          1.0,
          1.0,
          0,
          1,
          BoxDb.now(),
        ],
      );
      Directory(p.join(root.path, 'orig')).createSync(recursive: true);
      File(p.join(root.path, 'orig', '$id.mp4')).writeAsBytesSync([0, 0, 0, 1]);

      final sw = Stopwatch()..start();
      final code = await _httpStatus(base, null, '/api/asset/$id/thumb');
      sw.stop();
      expect(code, 404);
      expect(
        sw.elapsed,
        lessThan(const Duration(milliseconds: 800)),
        reason: '/api/thumb 不得等待抽帧',
      );
    });

    test('没封面的视频 thumb 与 status 并发，status 仍立刻是团图 JSON', () async {
      await join('alice');
      final uid = (await db.userByName('alice'))!['id'];
      final id = await db.exec(
        'INSERT INTO assets(uploader_id, sha256, orig_name, ext, kind, size, width, height, '
        'duration, taken_at, has_thumb, analyzed, created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
        [
          uid,
          'sha-vid-status',
          'clip2.mp4',
          'mp4',
          'video',
          100,
          0,
          0,
          1.0,
          1.0,
          0,
          1,
          BoxDb.now(),
        ],
      );
      Directory(p.join(root.path, 'orig')).createSync(recursive: true);
      File(p.join(root.path, 'orig', '$id.mp4')).writeAsBytesSync([0, 0, 0, 1]);

      final sw = Stopwatch()..start();
      final status = _getJson(base, 'unused', '/api/status');
      final thumb = _httpStatus(base, null, '/api/asset/$id/thumb');
      final results = await Future.wait([status, thumb]);
      sw.stop();
      final body = results[0] as Map<String, dynamic>;
      expect(body['service'], 'tuantu');
      expect(results[1], 404);
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 1200)));
    });

    test('已有封面的照片 thumb 立即 200', () async {
      final alice = await join('alice');
      final up = await _upload(
        base,
        alice,
        '----ThumbOk',
        files: [('ok.jpg', _jpeg(16, 16, 8, 8, 8))],
      );
      final id = (up['accepted'][0] as Map)['id'] as int;
      final sw = Stopwatch()..start();
      expect(await _httpStatus(base, null, '/api/asset/$id/thumb'), 200);
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 800)));
    });
  });

  group('人物封面并发与连接生命线', () {
    test(
        'seven concurrent uploaders preserve every thumbnail while status and gallery respond',
        () async {
      final tokens = [for (var i = 0; i < 7; i++) await join('uploader-$i')];
      var finished = false;
      var probes = 0;
      var peak = 0;
      final uploads = Future.wait([
        for (var i = 0; i < 7; i++)
          _upload(
            base,
            tokens[i],
            '----Mixed$i',
            files: [('mixed-$i.jpg', _jpeg(1200, 800, 30 + i * 20, 90, 150))],
          ),
      ]).whenComplete(() => finished = true);
      while (!finished) {
        final status = await _getJson(
          base,
          '',
          '/api/status',
        ).timeout(const Duration(seconds: 2));
        final running = status['diagnostics']['image_running'] as int;
        if (running > peak) peak = running;
        expect(running, lessThanOrEqualTo(2));
        await _getJson(
          base,
          tokens.first,
          '/api/gallery?view=all',
        ).timeout(const Duration(seconds: 2));
        probes++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final results = await uploads;
      expect(probes, greaterThan(0));
      expect(
        peak,
        greaterThan(0),
        reason: 'probe must overlap real image work',
      );
      for (final result in results) {
        expect(result['accepted'], hasLength(1));
        final id = result['accepted'][0]['id'];
        final thumb = await _getBytes(base, '/api/asset/$id/thumb');
        expect(thumb.status, 200);
        expect(im.decodeJpg(thumb.bytes), isNotNull);
      }
      final settled = await _getJson(base, '', '/api/status');
      expect(settled['diagnostics']['image_running'], 0);
      expect(settled['diagnostics']['image_queued'], 0);
    });

    test(
        'seven viewers share cover work, overload recovers, control and cached media stay available',
        () async {
      final token = await join('seven-viewers');
      final up = await _upload(
        base,
        token,
        '----SevenViewers',
        files: [('source.jpg', _jpeg(48, 48, 120, 90, 50))],
      );
      final aid = up['accepted'][0]['id'] as int;
      final ids = <int>[];
      for (var i = 0; i < 4; i++) {
        final pid = await db.exec(
          'INSERT INTO persons(mean_emb, created_at) VALUES(?,?)',
          [Uint8List(16), BoxDb.now()],
        );
        ids.add(pid);
        await db.exec(
          'INSERT INTO faces(asset_id,x,y,w,h,embedding,person_id) VALUES(?,?,?,?,?,?,?)',
          [aid, 6, 6, 28, 28, Uint8List(16), pid],
        );
      }
      final release = Completer<void>();
      final started = Completer<void>();
      var writes = 0;
      box = BoxHttp(
        db,
        root,
        personCoverConcurrency: 1,
        personCoverMaxQueued: 1,
        personCoverQueueTimeout: const Duration(milliseconds: 150),
        personCoverWriter: (payload) async {
          writes++;
          if (!started.isCompleted) started.complete();
          await release.future;
          return writePersonCover(payload);
        },
      );
      final path = '/api/person/${ids[0]}/cover';
      final shared = [for (var i = 0; i < 7; i++) _getBytes(base, path)];
      await started.future.timeout(const Duration(seconds: 2));
      final overflow = [
        for (final id in ids.skip(1)) _getBytes(base, '/api/person/$id/cover'),
      ];
      try {
        final status = await _getJson(
          base,
          token,
          '/api/status',
        ).timeout(const Duration(seconds: 1));
        expect(status['service'], 'tuantu');
        expect(status['diagnostics']['cover_queued'], lessThanOrEqualTo(1));
        expect((await _getBytes(base, '/api/asset/$aid/thumb')).status, 200);
        expect(
          (await _getJson(base, token, '/api/gallery?view=all'))['items'],
          isNotEmpty,
        );
        for (final result in await Future.wait(overflow)) {
          expect(
            result.status,
            503,
            reason: 'busy is retriable, not a missing cover',
          );
        }
        expect(
          writes,
          1,
          reason: 'seven viewers must share a single generation',
        );
      } finally {
        release.complete();
        await Future.wait(shared);
      }
      for (final result in await Future.wait(shared)) {
        expect(result.status, 200);
        expect(im.decodeJpg(result.bytes), isNotNull);
      }
      for (final id in ids.skip(1)) {
        expect((await _getBytes(base, '/api/person/$id/cover')).status, 200);
      }
      final settled = await _getJson(base, token, '/api/status');
      expect(settled['diagnostics']['cover_jobs'], 0);
      expect(settled['diagnostics']['image_running'], 0);
      expect(settled['diagnostics']['image_queued'], 0);
    });

    test(
        'cached public cover with token does not wait for SQLite; private routes still require auth',
        () async {
      final token = await join('cached-public');
      final cache = File(p.join(root.path, 'thumbs', 'person_123.jpg'));
      await cache.parent.create(recursive: true);
      await cache.writeAsBytes(_jpeg(32, 32, 70, 80, 90));
      final entered = Completer<void>();
      final release = Completer<void>();
      final transaction = db.txn((tx) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      try {
        expect(
          await _httpStatus(
            base,
            token,
            '/api/person/123/cover',
          ).timeout(const Duration(seconds: 1)),
          200,
        );
        expect(
          (await _getJson(
            base,
            '',
            '/api/status',
          ).timeout(const Duration(seconds: 1)))['service'],
          'tuantu',
        );
        expect(await _httpStatus(base, null, '/api/asset/1/detail'), 401);
        expect(await _httpStatus(base, null, '/api/asset/1/detail/cover'), 401);
      } finally {
        release.complete();
        await transaction;
      }
    });

    test('冷缓存多人并发只跑两个生成任务，status 仍立即响应', () async {
      final alice = await join('alice');
      final up = await _upload(
        base,
        alice,
        '----PersonCovers',
        files: [
          ('p1.jpg', _jpeg(48, 48, 180, 20, 20)),
          ('p2.jpg', _jpeg(48, 48, 20, 180, 20)),
          ('p3.jpg', _jpeg(48, 48, 20, 20, 180)),
          ('p4.jpg', _jpeg(48, 48, 120, 80, 20)),
        ],
      );
      final assetIds = [
        for (final a in (up['accepted'] as List))
          ((a as Map)['id'] as num).toInt(),
      ];
      final personIds = <int>[];
      for (final aid in assetIds) {
        final pid = await db.exec(
          'INSERT INTO persons(mean_emb, created_at) VALUES(?,?)',
          [Uint8List(16), BoxDb.now()],
        );
        personIds.add(pid);
        await db.exec(
          'INSERT INTO faces(asset_id,x,y,w,h,embedding,person_id) VALUES(?,?,?,?,?,?,?)',
          [aid, 6, 6, 28, 28, Uint8List(16), pid],
        );
      }

      final release = Completer<void>();
      final twoStarted = Completer<void>();
      var running = 0;
      var maxRunning = 0;
      var started = 0;
      box = BoxHttp(
        db,
        root,
        personCoverConcurrency: 2,
        personCoverWriter: (payload) async {
          running++;
          started++;
          if (running > maxRunning) maxRunning = running;
          if (started == 2 && !twoStarted.isCompleted) twoStarted.complete();
          try {
            await release.future;
            return writePersonCover(payload);
          } finally {
            running--;
          }
        },
      );

      final coverRequests = [
        for (final pid in personIds) _getBytes(base, '/api/person/$pid/cover'),
      ];
      await twoStarted.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final sw = Stopwatch()..start();
      final status = await _getJson(base, 'unused', '/api/status');
      sw.stop();
      expect(status['service'], 'tuantu');
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 500)));
      final diagnostics = Map<String, dynamic>.from(
        status['diagnostics'] as Map,
      );
      expect(diagnostics['cover_running'], 2);
      expect(diagnostics['cover_queued'], 2);

      release.complete();
      final covers = await Future.wait(coverRequests);
      expect(maxRunning, 2);
      for (final cover in covers) {
        expect(cover.status, 200);
        expect(cover.bytes.length, greaterThan(40));
        expect(
          im.decodeJpg(cover.bytes),
          isNotNull,
          reason: '返回必须是完整可解码 JPEG，不能只看 HTTP 200',
        );
      }
      final settled = await _getJson(base, 'unused', '/api/status');
      final settledDiagnostics = Map<String, dynamic>.from(
        settled['diagnostics'] as Map,
      );
      expect(settledDiagnostics['cover_running'], 0);
      expect(settledDiagnostics['cover_queued'], 0);
      expect(settledDiagnostics['cover_jobs'], 0);
    });

    test('删除封面来源时正在生成的旧任务不能复活缓存', () async {
      final alice = await join('cover-delete-race');
      final up = await _upload(
        base,
        alice,
        '----CoverDeleteRace',
        files: [('source.jpg', _jpeg(48, 48, 150, 80, 30))],
      );
      final aid = ((up['accepted'] as List).single as Map)['id'] as int;
      final pid = await db.exec(
        'INSERT INTO persons(mean_emb, created_at) VALUES(?,?)',
        [Uint8List(16), BoxDb.now()],
      );
      await db.exec(
        'INSERT INTO faces(asset_id,x,y,w,h,embedding,person_id) VALUES(?,?,?,?,?,?,?)',
        [aid, 6, 6, 28, 28, Uint8List(16), pid],
      );

      final started = Completer<void>();
      final release = Completer<void>();
      box = BoxHttp(
        db,
        root,
        personCoverWriter: (payload) async {
          started.complete();
          await release.future;
          await File(payload['out'] as String)
              .writeAsBytes(_jpeg(32, 32, 20, 40, 60));
          return true;
        },
      );

      final response = _getBytes(base, '/api/person/$pid/cover');
      await started.future.timeout(const Duration(seconds: 2));
      expect(
        await _httpStatus(base, alice, '/api/asset/$aid', method: 'DELETE'),
        200,
      );
      release.complete();

      expect((await response).status, 404);
      expect(
        File(p.join(root.path, 'thumbs', 'person_$pid.jpg')).existsSync(),
        isFalse,
      );
    });

    test('命中磁盘封面后不留死任务，文件删除后能重建', () async {
      final alice = await join('alice');
      final up = await _upload(
        base,
        alice,
        '----PersonCoverCache',
        files: [('cached.jpg', _jpeg(48, 48, 80, 120, 160))],
      );
      final aid = ((up['accepted'] as List).single as Map)['id'] as int;
      final pid = await db.exec(
        'INSERT INTO persons(mean_emb, created_at) VALUES(?,?)',
        [Uint8List(16), BoxDb.now()],
      );
      await db.exec(
        'INSERT INTO faces(asset_id,x,y,w,h,embedding,person_id) VALUES(?,?,?,?,?,?,?)',
        [aid, 6, 6, 28, 28, Uint8List(16), pid],
      );

      final path = '/api/person/$pid/cover';
      expect((await _getBytes(base, path)).status, 200, reason: '首次请求生成封面');
      expect(
        (await _getBytes(base, path)).status,
        200,
        reason: '第二次请求直接命中磁盘封面',
      );

      final afterCacheHit = await _getJson(base, 'unused', '/api/status');
      final diagnostics = Map<String, dynamic>.from(
        afterCacheHit['diagnostics'] as Map,
      );
      expect(diagnostics['cover_jobs'], 0, reason: '同步快返回也必须清掉任务登记');

      final cover = File(p.join(root.path, 'thumbs', 'person_$pid.jpg'));
      cover.deleteSync();
      final rebuilt = await _getBytes(base, path);
      expect(rebuilt.status, 200, reason: '重聚类等流程删除旧文件后，不能复用指向旧文件的完成任务');
      expect(im.decodeJpg(rebuilt.bytes), isNotNull);
      expect(cover.existsSync(), isTrue);
    });
  });

  group('点赞绝对状态与并发', () {
    test('连续 liked=true 不会被旧客户端切换抵成取消', () async {
      final alice = await join('alice');
      final up = await _upload(
        base,
        alice,
        '----LikeAbs',
        files: [('like.jpg', _jpeg(12, 12, 9, 9, 9))],
      );
      final id = (up['accepted'][0] as Map)['id'] as int;
      await Future.wait([
        _postJsonToken(base, alice, '/api/like', {'asset_id': id}),
        _postJsonToken(base, alice, '/api/like', {
          'asset_id': id,
          'liked': true,
        }),
        _postJsonToken(base, alice, '/api/like', {
          'asset_id': id,
          'liked': true,
        }),
      ]);
      final last = await _postJsonToken(base, alice, '/api/like', {
        'asset_id': id,
        'liked': true,
      });
      expect(last['liked'], isTrue);
      expect(last['likes'], 1);
      expect(
        firstInt(
          await db.q('SELECT COUNT(*) c FROM likes WHERE asset_id=?', [id]),
        ),
        1,
      );
    });

    test('旧客户端不带 liked 仍是切换，兼容旧包', () async {
      final alice = await join('alice');
      final up = await _upload(
        base,
        alice,
        '----LikeToggle',
        files: [('t.jpg', _jpeg(10, 10, 1, 2, 3))],
      );
      final id = (up['accepted'][0] as Map)['id'] as int;
      final a = await _postJsonToken(base, alice, '/api/like', {
        'asset_id': id,
      });
      expect(a['liked'], isTrue);
      final b = await _postJsonToken(base, alice, '/api/like', {
        'asset_id': id,
      });
      expect(b['liked'], isFalse);
      expect(b['likes'], 0);
    });

    test('删除后的过期点赞不能重建幽灵记录', () async {
      final alice = await join('alice');
      final up = await _upload(
        base,
        alice,
        '----LikeAfterDelete',
        files: [('gone.jpg', _jpeg(10, 10, 8, 7, 6))],
      );
      final id = (up['accepted'][0] as Map)['id'] as int;
      expect(
        await _httpStatus(base, alice, '/api/asset/$id', method: 'DELETE'),
        200,
      );
      final stale = await _postJsonToken(base, alice, '/api/like', {
        'asset_id': id,
        'liked': true,
      });
      expect(stale['detail'], '照片不存在');
      expect(
        firstInt(
          await db.q('SELECT COUNT(*) c FROM likes WHERE asset_id=?', [id]),
        ),
        0,
      );
    });
  });

  group('人物封面', () {
    test('从该人物的照片里选一张，裁对应的脸换成封面', () async {
      final alice = await join('alice');
      final red = _jpeg(80, 80, 200, 20, 20);
      final blue = _jpeg(80, 80, 20, 20, 200);
      final a1 = await _upload(
        base,
        alice,
        '----Cover',
        files: [('red.jpg', red)],
      );
      final a2 = await _upload(
        base,
        alice,
        '----Cover',
        files: [('blue.jpg', blue)],
      );
      final id1 = (a1['accepted'][0] as Map)['id'] as int;
      final id2 = (a2['accepted'][0] as Map)['id'] as int;
      final now = BoxDb.now();
      final pid = await db.exec(
        'INSERT INTO persons(mean_emb, created_at) VALUES(?,?)',
        [Uint8List(16), now],
      );
      await db.exec(
        'INSERT INTO faces(asset_id,x,y,w,h,embedding,person_id) VALUES(?,?,?,?,?,?,?)',
        [id1, 5, 5, 40, 40, Uint8List(16), pid],
      );
      final face2 = await db.exec(
        'INSERT INTO faces(asset_id,x,y,w,h,embedding,person_id) VALUES(?,?,?,?,?,?,?)',
        [id2, 10, 10, 20, 20, Uint8List(16), pid],
      );

      expect(
        await _httpStatus(base, alice, '/api/person/$pid/cover'),
        200,
        reason: '没手选时按最大脸自动出封面',
      );

      final set = await _postJsonToken(base, alice, '/api/persons/$pid/cover', {
        'asset_id': id2,
      });
      expect(set['ok'], true);
      expect(set['cover_face_id'], face2);
      expect(set['cover'], '/api/person/$pid/cover?c=$face2');
      final row = await db.qOne(
        'SELECT cover_face_id FROM persons WHERE id=?',
        [pid],
      );
      expect((row!['cover_face_id'] as num).toInt(), face2);
      expect(
        File(p.join(root.path, 'thumbs', 'person_$pid.jpg')).existsSync(),
        isTrue,
      );

      final green = _jpeg(80, 80, 20, 200, 20);
      final other = await _upload(
        base,
        alice,
        '----Cover',
        files: [('other.jpg', green)],
      );
      final otherId = (other['accepted'][0] as Map)['id'] as int;
      final bad = await _postJsonToken(base, alice, '/api/persons/$pid/cover', {
        'asset_id': otherId,
      });
      expect(bad['detail'], contains('没有这个人的脸'));
    });
  });
}

Future<int> _httpStatus(
  String base,
  String? token,
  String path, {
  String method = 'GET',
}) async {
  final c = HttpClient();
  final req = method == 'DELETE'
      ? await c.deleteUrl(Uri.parse('$base$path'))
      : await c.getUrl(Uri.parse('$base$path'));
  if (token != null) req.headers.set('X-Token', token);
  final resp = await req.close();
  await resp.drain<void>();
  c.close();
  return resp.statusCode;
}

Future<Map<String, dynamic>> _getJson(
  String base,
  String token,
  String path,
) async {
  final c = HttpClient();
  final r = await c.getUrl(Uri.parse('$base$path'));
  r.headers.set('X-Token', token);
  final resp = await r.close();
  final text = await resp.transform(utf8.decoder).join();
  c.close();
  return Map<String, dynamic>.from(jsonDecode(text) as Map);
}

Future<({int status, Uint8List bytes})> _getBytes(
  String base,
  String path,
) async {
  final c = HttpClient();
  try {
    final r = await c.getUrl(Uri.parse('$base$path'));
    final resp = await r.close();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    return (status: resp.statusCode, bytes: builder.takeBytes());
  } finally {
    c.close(force: true);
  }
}

Future<Map<String, dynamic>> _postJsonToken(
  String base,
  String token,
  String path,
  Map<String, dynamic> body,
) async {
  final c = HttpClient();
  final r = await c.postUrl(Uri.parse('$base$path'));
  r.headers.set('X-Token', token);
  r.headers.contentType = ContentType.json;
  r.write(jsonEncode(body));
  final resp = await r.close();
  final text = await resp.transform(utf8.decoder).join();
  c.close();
  return Map<String, dynamic>.from(jsonDecode(text) as Map);
}

Future<void> _postWithToken(
  String base,
  String token,
  String path,
  Map<String, dynamic> body,
) async {
  final c = HttpClient();
  final r = await c.postUrl(Uri.parse('$base$path'));
  r.headers.set('X-Token', token);
  r.headers.contentType = ContentType.json;
  r.write(jsonEncode(body));
  final resp = await r.close();
  await resp.drain<void>();
  c.close();
}

// ---------- helpers ----------

Uint8List _jpeg(int w, int h, int r, int g, int b) {
  final img = im.Image(width: w, height: h);
  im.fill(img, color: im.ColorRgb8(r, g, b));
  return Uint8List.fromList(im.encodeJpg(img, quality: 88));
}

List<int> _concat(List<int> a, List<int> b) => [...a, ...b];

List<int> _multipartFull(
  String boundary,
  List<({String name, String? filename, List<int> data})> parts, {
  Map<String, String> fields = const {},
}) {
  final out = BytesBuilder();
  for (final part in parts) {
    out.add(utf8.encode('--$boundary\r\n'));
    final fn = part.filename == null ? '' : '; filename="${part.filename}"';
    out.add(
      utf8.encode(
        'Content-Disposition: form-data; name="${part.name}"$fn\r\n\r\n',
      ),
    );
    out.add(part.data);
    out.add(utf8.encode('\r\n'));
  }
  fields.forEach((k, v) {
    out.add(utf8.encode('--$boundary\r\n'));
    out.add(
      utf8.encode('Content-Disposition: form-data; name="$k"\r\n\r\n$v\r\n'),
    );
  });
  out.add(utf8.encode('--$boundary--\r\n'));
  return out.takeBytes();
}

Future<Map<String, dynamic>> _postJson(
  HttpClient c,
  String url,
  Map<String, dynamic> body,
) async {
  final r = await c.postUrl(Uri.parse(url));
  r.headers.contentType = ContentType.json;
  r.write(jsonEncode(body));
  final resp = await r.close();
  final text = await resp.transform(utf8.decoder).join();
  return Map<String, dynamic>.from(jsonDecode(text) as Map);
}

Future<Map<String, dynamic>> _upload(
  String base,
  String token,
  String boundary, {
  required List<(String, List<int>)> files,
  List<int>? preview,
  List<int>? live,
  Map<String, dynamic>? meta,
  int? asUserId,
}) async {
  final parts = <({String name, String? filename, List<int> data})>[
    for (final f in files) (name: 'files', filename: f.$1, data: f.$2),
    if (live != null) (name: 'live', filename: 'l.mov', data: live),
    if (preview != null) (name: 'preview', filename: 'p.jpg', data: preview),
  ];
  final body = _multipartFull(
    boundary,
    parts,
    fields: {if (meta != null) 'meta': jsonEncode(meta)},
  );
  final c = HttpClient();
  final r = await c.postUrl(Uri.parse('$base/api/upload'));
  r.headers.set('X-Token', token);
  if (asUserId != null) r.headers.set('X-Tuantu-Import-User', '$asUserId');
  r.headers.contentType = ContentType.parse(
    'multipart/form-data; boundary=$boundary',
  );
  r.add(body);
  final resp = await r.close();
  final text = await resp.transform(utf8.decoder).join();
  c.close();
  return Map<String, dynamic>.from(jsonDecode(text) as Map);
}

/// 谎报 Content-Length、正文只发一半然后掐断连接。
Future<void> _sendBroken(
  String base,
  String path,
  String token,
  String boundary,
  List<int> body, {
  required int cutAt,
}) async {
  final uri = Uri.parse(base);
  final socket = await Socket.connect(uri.host, uri.port);
  final head =
      'POST $path HTTP/1.1\r\nHost: ${uri.host}:${uri.port}\r\nX-Token: $token\r\n'
      'Content-Type: multipart/form-data; boundary=$boundary\r\n'
      'Content-Length: ${body.length}\r\n\r\n';
  socket.write(head);
  socket.add(body.sublist(0, cutAt));
  await socket.flush();
  await Future<void>.delayed(const Duration(milliseconds: 100));
  socket.destroy();
}

List<int> _ftyp(int n, [int fill = 1]) {
  return File('test/fixtures/live/sample.mp4').readAsBytesSync();
}

Future<void> _waitHandled(bool Function() cond) async {
  for (var i = 0; i < 100 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
