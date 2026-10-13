/// 合照相册：成员脸数量 ≥ 2 的照片和视频。同一团员重复脸只算一次。
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
    root = Directory.systemTemp.createTempSync('tuantu_group_');
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

  var seq = 0;

  Future<String> join(String name) async {
    final c = HttpClient();
    final r = await c.postUrl(Uri.parse('$base/api/join'));
    r.headers.contentType = ContentType.json;
    r.write(jsonEncode({'name': name, 'device_id': 'dev-$name-${seq++}'}));
    final resp = await r.close();
    final text = await resp.transform(utf8.decoder).join();
    c.close();
    return (jsonDecode(text) as Map)['token'] as String;
  }

  Future<int> seedAsset(int uploader, {String kind = 'image'}) async {
    return db.exec('''
INSERT INTO assets(uploader_id, sha256, orig_name, ext, kind, size, taken_at, created_at, time_source)
VALUES(?,?,?,?,?,?,?,?,?)''', [
      uploader,
      'sha-${seq++}',
      kind == 'video' ? 'v.mp4' : 'f.jpg',
      kind == 'video' ? 'mp4' : 'jpg',
      kind,
      10,
      1000.0 + seq,
      2000.0 + seq,
      'exif',
    ]);
  }

  Future<int> seedPerson(String name, {int memberStatus = 1}) async {
    return db.exec(
        "INSERT INTO persons(mean_emb, name, created_at, member_status) "
        "VALUES(x'00000000', ?, 1.0, ?)",
        [name, memberStatus]);
  }

  Future<void> addFace(int asset, int person) async {
    await db.exec(
        "INSERT INTO faces(asset_id, x, y, w, h, embedding, person_id) "
        "VALUES(?,1,1,10,10,x'00000000',?)",
        [asset, person]);
  }

  Future<Map<String, dynamic>> getJson(String token, String path) async {
    final c = HttpClient();
    final r = await c.getUrl(Uri.parse('$base$path'));
    r.headers.set('X-Token', token);
    final resp = await r.close();
    final text = await resp.transform(utf8.decoder).join();
    c.close();
    expect(resp.statusCode, 200, reason: text);
    return Map<String, dynamic>.from(jsonDecode(text) as Map);
  }

  test('合照只收两位及以上不同团员的照片和视频', () async {
    final token = await join('alice');
    final uid = (await db.userByToken(token))!['id'] as int;
    final a = await seedPerson('甲');
    final b = await seedPerson('乙');
    final stranger = await seedPerson('路人', memberStatus: 0);

    final twoMembers = await seedAsset(uid);
    await addFace(twoMembers, a);
    await addFace(twoMembers, b);

    final videoTwo = await seedAsset(uid, kind: 'video');
    await addFace(videoTwo, a);
    await addFace(videoTwo, b);

    final oneMember = await seedAsset(uid);
    await addFace(oneMember, a);

    final samePersonTwice = await seedAsset(uid);
    await addFace(samePersonTwice, a);
    await addFace(samePersonTwice, a);

    final memberPlusStranger = await seedAsset(uid);
    await addFace(memberPlusStranger, a);
    await addFace(memberPlusStranger, stranger);

    final home = await getJson(token, '/api/gallery/home');
    expect((home['group'] as Map)['count'], 2,
        reason: '只有两人合照和两人视频算合照');

    final gallery = await getJson(token, '/api/gallery?view=group&limit=20');
    final ids = {
      for (final e in gallery['items'] as List) (e as Map)['id'] as int
    };
    expect(ids, {twoMembers, videoTwo});
    expect(ids, isNot(contains(oneMember)));
    expect(ids, isNot(contains(samePersonTwice)),
        reason: '同一团员重复脸不能凑成合照');
    expect(ids, isNot(contains(memberPlusStranger)),
        reason: '非团员脸不计入成员数量');
  });
}
