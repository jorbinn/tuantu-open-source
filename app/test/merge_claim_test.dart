/// 合并人物：不同账号认领必须显式选择保留谁、团员状态冲突规则、
/// 名字收养、待确认记录跟随。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tuantu_app/box/box_db.dart';
import 'package:tuantu_app/box/box_http.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory root;
  late BoxDb db;
  late BoxHttp box;
  late HttpServer server;
  late String base;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('tuantu_merge_');
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
    return (resp.statusCode, Map<String, dynamic>.from(jsonDecode(text) as Map));
  }

  Future<int> seedPerson(String? name,
      {int memberStatus = 0, int faces = 1}) async {
    final id = await db.exec(
        "INSERT INTO persons(mean_emb, name, created_at, member_status) VALUES(x'00000000', ?, 1.0, ?)",
        [name, memberStatus]);
    for (var i = 0; i < faces; i++) {
      final aid = await db.exec(
          "INSERT INTO assets(uploader_id, sha256, orig_name, ext, kind, size, taken_at, created_at, time_source) "
          "VALUES(1,?,'f.jpg','jpg','image',10,1000.0,1000.0,'exif')", ['h-$id-$i']);
      await db.exec(
          'INSERT INTO faces(asset_id, x, y, w, h, embedding, person_id) VALUES(?,1,1,10,10,x\'00000000\',?)',
          [aid, id]);
    }
    return id;
  }

  test('不同账号的认领：不指定保留谁时 409 列出认领详情', () async {
    final t1 = await join('甲');
    final t2 = await join('乙');
    final u1 = (await db.userByToken(t1))!['id'] as int;
    final u2 = (await db.userByToken(t2))!['id'] as int;
    final p1 = await seedPerson('甲脸');
    final p2 = await seedPerson('甲脸2');
    await post(t1, '/api/persons/$p1/claim', {});
    await post(t2, '/api/persons/$p2/claim', {});
    final (s, b) = await post(t1, '/api/persons/merge', {'ids': [p1, p2]});
    expect(s, 409);
    final claims = ((b['conflict'] as Map)['claims'] as List).cast<Map>();
    expect(claims.length, 2);
    expect(claims.map((c) => c['user_name']).toSet(), {'甲', '乙'});
    // 什么都没动
    expect(
        (await db.q('SELECT COUNT(*) c FROM persons')).first['c'], 2);
    expect(u1 + u2 > 0, isTrue);
  });

  test('指定保留谁的认领：合并后一对一、其余转记录', () async {
    final t1 = await join('甲');
    final t2 = await join('乙');
    final u1 = (await db.userByToken(t1))!['id'] as int;
    final u2 = (await db.userByToken(t2))!['id'] as int;
    final p1 = await seedPerson('甲脸', faces: 3);
    final p2 = await seedPerson('甲脸2', faces: 1);
    await post(t1, '/api/persons/$p1/claim', {});
    await post(t2, '/api/persons/$p2/claim', {});
    final (s, b) = await post(t1, '/api/persons/merge', {
      'ids': [p1, p2],
      'keep_claim_user': u1,
    });
    expect(s, 200, reason: b.toString());
    final keep = b['id'] as int;
    expect(keep, p1, reason: '脸多的留下');
    final claims =
        await db.q('SELECT user_id FROM person_claims WHERE person_id=?', [keep]);
    expect(claims.map((c) => c['user_id']), [u1]);
    final rec = await db.q(
        "SELECT resolved_at FROM claim_pending WHERE person_id=? AND user_id=? AND reason='merge'",
        [keep, u2]);
    expect(rec.single['resolved_at'], isNotNull, reason: '乙的认领转合并记录');
    final row = await db.qOne('SELECT claimed_by, name FROM persons WHERE id=?', [keep]);
    expect(row?['claimed_by'], u1);
    expect(row?['name'], '甲脸');
  });

  test('全部取消：合并后无人认领', () async {
    final t1 = await join('甲');
    final t2 = await join('乙');
    final p1 = await seedPerson('a', faces: 2);
    final p2 = await seedPerson('b', faces: 1);
    await post(t1, '/api/persons/$p1/claim', {});
    await post(t2, '/api/persons/$p2/claim', {});
    final (s, _) = await post(t1, '/api/persons/merge', {
      'ids': [p1, p2],
      'keep_claim_user': 'none',
    });
    expect(s, 200);
    expect((await db.q('SELECT COUNT(*) c FROM person_claims')).first['c'], 0);
  });

  test('同一账号认领两个被并人物：自动保持一对一，无需选择', () async {
    final t1 = await join('甲');
    final u1 = (await db.userByToken(t1))!['id'] as int;
    final p1 = await seedPerson('a', faces: 2);
    final p2 = await seedPerson('b', faces: 1);
    await post(t1, '/api/persons/$p1/claim', {});
    // 直接 SQL 模拟历史多认领迁移前的合并场景会被索引挡住，
    // 这里通过「认领 A 后合并 A、B」由合并路径自然保留唯一认领。
    final (s, _) = await post(t1, '/api/persons/merge', {'ids': [p1, p2]});
    expect(s, 200);
    final claims = await db.q('SELECT person_id, user_id FROM person_claims');
    expect(claims.length, 1);
    expect(claims.single['user_id'], u1);
    expect(claims.single['person_id'], p1);
  });

  test('团员状态冲突：团员压过非团员，同优先级保 keep 的标记人', () async {
    final t1 = await join('甲');
    final t2 = await join('乙');
    final u1 = (await db.userByToken(t1))!['id'] as int;
    final u2 = (await db.userByToken(t2))!['id'] as int;
    // keep（脸多）= 非团员；被并的 = 团员。团员标记不能静默丢。
    final p1 = await seedPerson('a', faces: 3, memberStatus: 2);
    final p2 = await seedPerson('b', faces: 1, memberStatus: 1);
    await db.run(
        'UPDATE persons SET member_marked_by=?, member_marked_at=? WHERE id=?',
        [u2, 7.0, p2]);
    final (s, _) = await post(t1, '/api/persons/merge', {'ids': [p1, p2]});
    expect(s, 200);
    final row = await db.qOne(
        'SELECT member_status, member_marked_by, member_marked_at FROM persons WHERE id=?',
        [p1]);
    expect(row?['member_status'], 1, reason: '团员 > 非团员');
    expect(row?['member_marked_by'], u2, reason: '保留原标记人');
    expect(row?['member_marked_at'], 7.0);
    expect(u1, isNotNull);
  });

  test('keep 没名字时收养被并人物的名字', () async {
    final t1 = await join('甲');
    final p1 = await seedPerson(null, faces: 3);
    final p2 = await seedPerson('小明', faces: 1);
    final (s, _) = await post(t1, '/api/persons/merge', {'ids': [p1, p2]});
    expect(s, 200);
    final row = await db.qOne('SELECT name FROM persons WHERE id=?', [p1]);
    expect(row?['name'], '小明');
  });

  test('待确认记录跟随合并后的 person', () async {
    final t1 = await join('甲');
    final t2 = await join('乙');
    final u2 = (await db.userByToken(t2))!['id'] as int;
    final p1 = await seedPerson('a', faces: 3);
    final p2 = await seedPerson('b', faces: 1);
    await db.exec(
        "INSERT INTO claim_pending(person_id, user_id, created_at, pending_at, reason) VALUES(?,?,1.0,2.0,'migrate_user_multi')",
        [p2, u2]);
    final (s, _) = await post(t1, '/api/persons/merge', {'ids': [p1, p2]});
    expect(s, 200);
    final rows = await db.q(
        'SELECT person_id FROM claim_pending WHERE user_id=? AND resolved_at IS NULL',
        [u2]);
    expect(rows.single['person_id'], p1);
  });
}
