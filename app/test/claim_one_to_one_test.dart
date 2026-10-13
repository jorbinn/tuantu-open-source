/// 一对一认领回归：历史多对多迁移、认领/接替确认、并发防护、
/// 「不是我」语义、团员标记。真实 HttpServer + ffi SQLite。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tuantu_app/box/box_db.dart';
import 'package:tuantu_app/box/box_http.dart';

int firstInt(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) return 0;
  final v = rows.first.values.first;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return 0;
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory root;
  late BoxDb db;
  late BoxHttp box;
  late HttpServer server;
  late String base;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('tuantu_claim_');
    db = await BoxDb.open(p.join(root.path, 't.db'));
    box = BoxHttp(db, root);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      try {
        await box.handle(req);
      } catch (_) {}
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await db.close();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<String> join(String name) async {
    final c = HttpClient();
    final r = await c.postUrl(Uri.parse('$base/api/join'));
    r.headers.contentType = ContentType.json;
    r.write(jsonEncode({'name': name, 'device_id': 'dev-$name'}));
    final resp = await r.close();
    final body = await resp.transform(utf8.decoder).join();
    c.close();
    return (jsonDecode(body) as Map)['token'] as String;
  }

  /// 返回 (status, body)。
  Future<(int, Map<String, dynamic>)> post(
      String token, String path, Map<String, dynamic> body) async {
    final c = HttpClient();
    final r = await c.postUrl(Uri.parse('$base$path'));
    r.headers.set('X-Token', token);
    r.headers.contentType = ContentType.json;
    r.write(jsonEncode(body));
    final resp = await r.close();
    final text = await resp.transform(utf8.decoder).join();
    c.close();
    return (
      resp.statusCode,
      Map<String, dynamic>.from(jsonDecode(text) as Map)
    );
  }

  /// 直接种两个人物（绕过识别管线），返回人物 id 列表。
  Future<List<int>> seedPersons(int n) async {
    final ids = <int>[];
    for (var i = 0; i < n; i++) {
      final id = await db.exec(
          "INSERT INTO persons(mean_emb, created_at) VALUES(x'00000000', 1.0)");
      ids.add(id);
    }
    return ids;
  }

  group('历史多对多迁移', () {
    test('一人多认领/一人被多认领都进待确认，原关系保留，索引可建', () async {
      // 裸库造旧数据：全新库第一次 open 就有一对一索引，
      // 多对多状态必须在建索引之前先存在。
      final path = p.join(root.path, 'legacy_multi.db');
      final raw = await databaseFactory.openDatabase(path);
      await raw.execute('''
CREATE TABLE persons(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  mean_emb BLOB NOT NULL,
  name TEXT,
  claimed_by INTEGER,
  created_at REAL NOT NULL
)''');
      await raw.execute('''
CREATE TABLE person_claims(
  person_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  created_at REAL NOT NULL,
  PRIMARY KEY(person_id, user_id)
)''');
      final emb = Uint8List.fromList([0]);
      await raw.insert('persons', {
        'id': 1,
        'mean_emb': emb,
        'name': '甲脸',
        'claimed_by': 11,
        'created_at': 1.0
      });
      await raw.insert('persons', {
        'id': 2,
        'mean_emb': emb,
        'name': null,
        'claimed_by': null,
        'created_at': 1.0
      });
      // u11 认领 p1、p2（一人多认领）；p1 同时被 u11、u12 认领（多认领者）。
      await raw.insert('person_claims',
          {'person_id': 1, 'user_id': 11, 'created_at': 100.0});
      await raw.insert('person_claims',
          {'person_id': 2, 'user_id': 11, 'created_at': 200.0});
      await raw.insert('person_claims',
          {'person_id': 1, 'user_id': 12, 'created_at': 300.0});
      await raw.close();

      // BoxDb.open 触发迁移（onOpen -> _ensureSchema）。
      final db2 = await BoxDb.open(path);
      addTearDown(() => db2.close());
      // 冲突必须按迁移前的完整关系图判断：p1 同时关联两个账号，
      // 所以 u12 也不能因为 u11 先被移走而自动留下。
      final active =
          await db2.q('SELECT person_id, user_id FROM person_claims');
      expect(active, isEmpty);
      final pending = await db2.q(
          'SELECT person_id, user_id, created_at, resolved_at FROM claim_pending ORDER BY created_at');
      expect(pending.length, 3);
      expect(pending.map((r) => r['created_at']), [100.0, 200.0, 300.0],
          reason: '迁移记录保留原关系时间');
      expect(pending.every((r) => r['resolved_at'] == null), isTrue,
          reason: '处于待确认状态');

      final members =
          await db2.q('SELECT id, member_status FROM persons ORDER BY id');
      expect(members.every((p) => p['member_status'] == 1), isTrue,
          reason: '升级前已有认领的人物首次迁移为团员');

      // 一对一唯一索引已建立：先补两条合法认领，再验证两类越界。
      await db2.exec(
          'INSERT INTO person_claims(person_id, user_id, created_at) VALUES(?,?,1.0)',
          [1, 12]);
      await db2.exec(
          'INSERT INTO person_claims(person_id, user_id, created_at) VALUES(?,?,1.0)',
          [2, 11]);
      await expectLater(
        db2.exec(
            'INSERT INTO person_claims(person_id, user_id, created_at) VALUES(?,?,1.0)',
            [2, 12]),
        throwsA(anything),
        reason: '同一人物第二个认领被唯一索引挡住',
      );
      await expectLater(
        db2.exec(
            'INSERT INTO person_claims(person_id, user_id, created_at) VALUES(?,?,1.0)',
            [1, 11]),
        throwsA(anything),
        reason: '同一账号第二个认领被唯一索引挡住',
      );
      final pendingShown = await db2.q('''
SELECT cp.user_id FROM claim_pending cp
WHERE cp.resolved_at IS NULL AND cp.person_id=1''');
      expect(pendingShown.length, 2, reason: '直接验证索引不会擅自了结迁移待确认记录');
    });

    test('确认认领可了结待确认，原关系迁移记录不丢', () async {
      final t1 = await join('甲');
      final u1 = (await db.userByToken(t1))!['id'] as int;
      final [p1] = await seedPersons(1);
      await db.exec(
          "INSERT INTO claim_pending(person_id, user_id, created_at, pending_at, reason) VALUES(?,?,50.0,60.0,'migrate_user_multi')",
          [p1, u1]);
      final (status, body) = await post(t1, '/api/persons/$p1/claim', {});
      expect(status, 200);
      expect(body['ok'], true);
      final rows = await db.q(
          'SELECT resolved_at FROM claim_pending WHERE person_id=? AND user_id=?',
          [p1, u1]);
      expect(rows.single['resolved_at'], isNotNull, reason: '迁移记录保留但已了结');
    });
  });

  group('一对一认领与接替', () {
    test('无冲突认领直接成功并自动成为团员', () async {
      final t1 = await join('甲');
      final [p1] = await seedPersons(1);
      final (s, b) = await post(t1, '/api/persons/$p1/claim', {});
      expect(s, 200);
      expect(b['ok'], true);
      final row = await db.qOne(
          'SELECT member_status, claimed_by FROM persons WHERE id=?', [p1]);
      expect(row?['member_status'], 1, reason: '新认领自动团员');
      expect(row?['claimed_by'], (await db.userByToken(t1))!['id']);
    });

    test('我已认领 A 再认领 B：确认后解除 A 认领 B', () async {
      final t1 = await join('甲');
      final [pa, pb] = await seedPersons(2);
      await post(t1, '/api/persons/$pa/claim', {});
      // 认领 B：先 409 说明影响
      final (s1, b1) = await post(t1, '/api/persons/$pb/claim', {});
      expect(s1, 409);
      expect((b1['conflict'] as Map)['my_person'], isNotNull);
      expect((b1['conflict'] as Map)['person_user'], isNull);
      // 带 confirm + 期望值
      final u1 = (await db.userByToken(t1))!['id'] as int;
      final (s2, b2) = await post(t1, '/api/persons/$pb/claim', {
        'confirm': true,
        'expect_my_person': pa,
        'expect_person_user': -1,
      });
      expect(s2, 200);
      expect(b2['ok'], true);
      expect(
          firstInt(await db
              .q('SELECT COUNT(*) c FROM person_claims WHERE user_id=?', [u1])),
          1,
          reason: '一个账号只有一个有效认领');
      expect(
          firstInt(await db.q(
              'SELECT COUNT(*) c FROM person_claims WHERE person_id=?', [pb])),
          1);
      final oldRow =
          await db.qOne('SELECT claimed_by FROM persons WHERE id=?', [pa]);
      expect(oldRow?['claimed_by'], isNull);
    });

    test('B 已被他人认领：确认说明解除谁，接替留记录', () async {
      final t1 = await join('甲');
      final t2 = await join('乙');
      final u2 = (await db.userByToken(t2))!['id'] as int;
      final [pb] = await seedPersons(1);
      await post(t2, '/api/persons/$pb/claim', {});
      final (s1, b1) = await post(t1, '/api/persons/$pb/claim', {});
      expect(s1, 409);
      final c = b1['conflict'] as Map;
      expect((c['person_user'] as Map)['name'], '乙', reason: '确认框要说明将解除谁的关联');
      expect(c['my_person'], isNull);
      final (s2, _) = await post(t1, '/api/persons/$pb/claim', {
        'confirm': true,
        'expect_my_person': -1,
        'expect_person_user': u2,
      });
      expect(s2, 200);
      final rec = await db.q(
          "SELECT resolved_at FROM claim_pending WHERE person_id=? AND user_id=? AND reason='takeover'",
          [pb, u2]);
      expect(rec.single['resolved_at'], isNotNull, reason: '接替审计记录');
      expect(
          firstInt(await db.q(
              'SELECT COUNT(*) c FROM person_claims WHERE person_id=?', [pb])),
          1);
    });

    test('确认期间关系被改：期望不匹配返回最新状态，不覆盖', () async {
      final t1 = await join('甲');
      final t2 = await join('乙');
      final t3 = await join('丙');
      final [pb] = await seedPersons(1);
      final u3 = (await db.userByToken(t3))!['id'] as int;
      // t3 先认领了 B；甲的确认框看到的“B 被 t3 认领”。
      await post(t3, '/api/persons/$pb/claim', {});
      // 甲还没确认时，丙取消认领、乙认领了 B —— 甲的期望已过时。
      await post(t3, '/api/persons/$pb/unclaim', {});
      await post(t2, '/api/persons/$pb/claim', {});
      final u2 = (await db.userByToken(t2))!['id'] as int;
      final (s, b) = await post(t1, '/api/persons/$pb/claim', {
        'confirm': true,
        'expect_my_person': -1,
        'expect_person_user': u3, // 甲以为还是丙
      });
      expect(s, 409, reason: '状态变了不能直接覆盖用户没确认的成员');
      expect(((b['conflict'] as Map)['person_user'] as Map)['id'], u2,
          reason: '返回最新状态让甲重新确认');
      expect(
          firstInt(await db.q(
              'SELECT COUNT(*) c FROM person_claims WHERE person_id=?', [pb])),
          1,
          reason: '乙的认领没被误删');
      // 用最新状态再确认一次成功。
      final (s2, _) = await post(t1, '/api/persons/$pb/claim', {
        'confirm': true,
        'expect_my_person': -1,
        'expect_person_user': u2,
      });
      expect(s2, 200);
    });

    test('「不是我」只取消自己的认领，不动团员标记，可再次认领', () async {
      final t1 = await join('甲');
      final u1 = (await db.userByToken(t1))!['id'] as int;
      final [p1] = await seedPersons(1);
      await post(t1, '/api/persons/$p1/claim', {});
      await post(t1, '/api/persons/$p1/unclaim', {});
      final row = await db.qOne(
          'SELECT member_status, claimed_by FROM persons WHERE id=?', [p1]);
      expect(row?['member_status'], 1, reason: '取消认领不自动取消团员');
      expect(
          firstInt(await db
              .q('SELECT COUNT(*) c FROM person_claims WHERE user_id=?', [u1])),
          0);
      // 再次认领（无冲突路径）成功——不禁止再次认领。
      final (s, _) = await post(t1, '/api/persons/$p1/claim', {});
      expect(s, 200);
    });

    test('认领非团员人物需要确认，确认后恢复团员', () async {
      final t1 = await join('甲');
      final [p1] = await seedPersons(1);
      await post(t1, '/api/persons/$p1/member', {'status': 2});
      final (s1, b1) = await post(t1, '/api/persons/$p1/claim', {});
      expect(s1, 409, reason: '恢复团员要在确认框说明');
      expect(b1['conflict'], isNotNull);
      final (s2, _) = await post(t1, '/api/persons/$p1/claim', {
        'confirm': true,
        'expect_my_person': -1,
        'expect_person_user': -1,
      });
      expect(s2, 200);
      final row =
          await db.qOne('SELECT member_status FROM persons WHERE id=?', [p1]);
      expect(row?['member_status'], 1);
    });

    test('同时存在两种冲突时一次确认说明完整影响', () async {
      final t1 = await join('甲');
      final t2 = await join('乙');
      final [pa, pb] = await seedPersons(2);
      await post(t1, '/api/persons/$pa/claim', {});
      await post(t2, '/api/persons/$pb/claim', {});
      final (s, b) = await post(t1, '/api/persons/$pb/claim', {});
      expect(s, 409);
      final c = b['conflict'] as Map;
      expect(c['my_person'], isNotNull, reason: '我已认领 A');
      expect(c['person_user'], isNotNull, reason: 'B 已被他人认领');
    });
  });

  group('团员标记', () {
    test('已登录成员可改标记，保留修改人和时间；未认领也可标团员', () async {
      final t1 = await join('甲');
      final u1 = (await db.userByToken(t1))!['id'] as int;
      final [p1, p2] = await seedPersons(2);
      // p2 无人认领，直接标团员（个人报告需要）。
      final (s, _) = await post(t1, '/api/persons/$p2/member', {'status': 1});
      expect(s, 200);
      final row = await db.qOne(
          'SELECT member_status, member_marked_by, member_marked_at FROM persons WHERE id=?',
          [p2]);
      expect(row?['member_status'], 1);
      expect(row?['member_marked_by'], u1);
      expect(row?['member_marked_at'], isNotNull);
      // 标非团员只影响统计，不删媒体不解除认领。
      await post(t1, '/api/persons/$p2/member', {'status': 2});
      final row2 =
          await db.qOne('SELECT member_status FROM persons WHERE id=?', [p2]);
      expect(row2?['member_status'], 2);
      // 非法值拒绝。
      final (s3, _) = await post(t1, '/api/persons/$p1/member', {'status': 9});
      expect(s3, 400);
    });

    test('可一次标记多个人物；人物缺失时整批不修改', () async {
      final token = await join('甲');
      final uid = (await db.userByToken(token))!['id'] as int;
      final [p1, p2, p3] = await seedPersons(3);

      final (status, body) = await post(token, '/api/persons/members', {
        'ids': [p1, p2, p1],
        'status': 1,
      });
      expect(status, 200);
      expect(body['count'], 2, reason: '重复人物编号只更新一次');
      final marked = await db.q(
          'SELECT id, member_status, member_marked_by FROM persons ORDER BY id');
      expect(marked[0]['member_status'], 1);
      expect(marked[1]['member_status'], 1);
      expect(marked[0]['member_marked_by'], uid);
      expect(marked[1]['member_marked_by'], uid);
      expect(marked[2]['member_status'], 0);

      final (missingStatus, _) = await post(token, '/api/persons/members', {
        'ids': [p2, 999999],
        'status': 2,
      });
      expect(missingStatus, 404);
      final after = await db.qOne(
          'SELECT member_status FROM persons WHERE id=?', [p2]);
      expect(after?['member_status'], 1,
          reason: '整批校验失败时不能留下部分更新');

      final (invalidStatus, _) = await post(token, '/api/persons/members', {
        'ids': [p3],
        'status': 9,
      });
      expect(invalidStatus, 400);
    });

    test('人物列表带团员状态和待确认标记', () async {
      final t1 = await join('甲');
      final t2 = await join('乙');
      final u2 = (await db.userByToken(t2))!['id'] as int;
      final pid = await db.exec(
          "INSERT INTO persons(mean_emb, created_at) VALUES(x'00000000', 1.0)");
      // 给人物一张脸，才会出现在列表里。
      final aid = await db.exec(
          "INSERT INTO assets(uploader_id, sha256, orig_name, ext, kind, size, taken_at, created_at, time_source) "
          "VALUES(1,'h1','a.jpg','jpg','image',10,1000.0,1000.0,'exif')");
      await db.exec(
          'INSERT INTO faces(asset_id, x, y, w, h, embedding, person_id) VALUES(?,1,1,10,10,x\'00000000\',?)',
          [aid, pid]);
      await post(t1, '/api/persons/$pid/member', {'status': 1});
      await db.exec(
          "INSERT INTO claim_pending(person_id, user_id, created_at, pending_at, reason) VALUES(?,?,5.0,6.0,'migrate_user_multi')",
          [pid, u2]);
      final list = await _personsList(base, t1);
      final item = list.firstWhere((e) => e['id'] == pid) as Map;
      expect(item['member'], 1);
      expect((item['pending'] as List).length, 1);
      expect(((item['pending'] as List).first as Map)['name'], '乙');
    });
  });
}

Future<List<dynamic>> _personsList(String base, String token) async {
  final c = HttpClient();
  final r = await c.getUrl(Uri.parse('$base/api/persons'));
  r.headers.set('X-Token', token);
  final resp = await r.close();
  final text = await resp.transform(utf8.decoder).join();
  c.close();
  return jsonDecode(text) as List<dynamic>;
}
