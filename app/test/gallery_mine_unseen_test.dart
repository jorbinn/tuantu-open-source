/// 「有我的 · 只看未看过」数据库回归：view=mine_unseen 必须在 SQL 里同时满足
/// 「包含我认领的人脸」和「我没看过」，分页时过滤要发生在 LIMIT 之前，
/// 否则客户端过滤会让翻页漏图。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
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
    root = Directory.systemTemp.createTempSync('tuantu_mine_unseen_');
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

  Future<String> join(String name, String deviceId) async {
    final c = HttpClient();
    final r = await c.postUrl(Uri.parse('$base/api/join'));
    r.headers.contentType = ContentType.json;
    r.write(jsonEncode({'name': name, 'device_id': deviceId}));
    final resp = await r.close();
    final text = await resp.transform(utf8.decoder).join();
    c.close();
    return (jsonDecode(text) as Map)['token'] as String;
  }

  Future<int> upload(String token, String name, int tint) async {
    const boundary = '----MineUnseen';
    final body = <List<int>>[
      utf8.encode('--$boundary\r\n'
          'Content-Disposition: form-data; name="files"; filename="$name"\r\n'
          '\r\n'),
      _jpeg(12, 12, 30, 60, tint),
      utf8.encode('\r\n--$boundary--\r\n'),
    ];
    final c = HttpClient();
    final r = await c.postUrl(Uri.parse('$base/api/upload'));
    r.headers.set('X-Token', token);
    r.headers.contentType =
        ContentType.parse('multipart/form-data; boundary=$boundary');
    r.add(body.expand((e) => e).toList());
    final resp = await r.close();
    final text = await resp.transform(utf8.decoder).join();
    c.close();
    final d = jsonDecode(text) as Map;
    final accepted = d['accepted'] as List;
    expect(accepted.length, 1, reason: '$name 应上传成功');
    return (accepted[0] as Map)['id'] as int;
  }

  Future<Map<String, dynamic>> galleryRaw(String token, String view,
      {int limit = 60,
      double? cursor,
      int? cursorId,
      int? seed,
      List<int> exclude = const []}) async {
    final uri = Uri.parse('$base/api/gallery').replace(queryParameters: {
      'view': view,
      'limit': '$limit',
      'sort': 'upload',
      if (cursor != null) 'cursor': '$cursor',
      if (cursorId != null) 'cursor_id': '$cursorId',
      if (seed != null) 'seed': '$seed',
      if (exclude.isNotEmpty) 'exclude': exclude.join(','),
    });
    final c = HttpClient();
    final r = await c.getUrl(uri);
    r.headers.set('X-Token', token);
    final resp = await r.close();
    final text = await resp.transform(utf8.decoder).join();
    c.close();
    return Map<String, dynamic>.from(jsonDecode(text) as Map);
  }

  Future<List<int>> gallery(String token, String view,
      {int limit = 60,
      double? cursor,
      int? cursorId,
      int? seed,
      List<int> exclude = const []}) async {
    final d = await galleryRaw(token, view,
        limit: limit,
        cursor: cursor,
        cursorId: cursorId,
        seed: seed,
        exclude: exclude);
    return [
      for (final e in (d['items'] as List)) (e as Map)['id'] as int,
    ];
  }

  test('mine 返回全部认领作品，mine_unseen 只留没看过的，翻页不漏图', () async {
    final alice = await join('alice', 'device-alice');
    final bob = await join('bob', 'device-bob');

    // 两张「有我的」+ 一张无关照片
    final a1 = await upload(alice, 'me1.jpg', 90);
    final a2 = await upload(alice, 'me2.jpg', 120);
    final plain = await upload(alice, 'plain.jpg', 150);

    // 认领的人物挂在 a1、a2 的脸上；bob 没有认领任何人物
    final now = BoxDb.now();
    final pid = await db.exec(
        'INSERT INTO persons(mean_emb, created_at) VALUES(?,?)',
        [Uint8List(16), now]);
    for (final aid in [a1, a2]) {
      await db.exec(
          'INSERT INTO faces(asset_id,x,y,w,h,embedding,person_id) '
          'VALUES(?,?,?,?,?,?,?)',
          [aid, 1, 1, 10, 10, Uint8List(16), pid]);
    }
    final aliceId = (await db.userByDevice('device-alice'))!['id'];
    await db.exec(
        'INSERT INTO person_claims(person_id, user_id, created_at) '
        'VALUES(?,?,?)',
        [pid, aliceId, now]);

    // alice 看过 a1，没看过 a2
    final c = HttpClient();
    final r = await c.postUrl(Uri.parse('$base/api/seen'));
    r.headers.set('X-Token', alice);
    r.headers.contentType = ContentType.json;
    r.write(jsonEncode({'asset_id': a1}));
    await r.close().then((resp) => resp.drain<void>());
    c.close();

    // mine：两张都在
    final mine = await gallery(alice, 'mine');
    expect(mine.toSet(), {a1, a2}, reason: 'mine 不能被看过状态影响');
    expect(mine, isNot(contains(plain)), reason: '没有认领人物的不算「有我的」');

    // mine_unseen：只剩没看过的 a2
    final unseen = await gallery(alice, 'mine_unseen');
    expect(unseen, [a2], reason: '看过的一张必须被数据库过滤掉，而不是客户端事后过滤');

    // 别人看过不算：bob 看了 a2 后，alice 的 mine_unseen 仍含 a2
    final cb = HttpClient();
    final rb = await cb.postUrl(Uri.parse('$base/api/seen'));
    rb.headers.set('X-Token', bob);
    rb.headers.contentType = ContentType.json;
    rb.write(jsonEncode({'asset_id': a2}));
    await rb.close().then((resp) => resp.drain<void>());
    cb.close();
    expect(await gallery(alice, 'mine_unseen'), [a2],
        reason: '「未看过」只看当前用户自己的 views');

    // 分页：过滤必须发生在 LIMIT 之前（每页 1 张，第一页只有 a2，第二页为空）
    final page1 = await galleryRaw(alice, 'mine_unseen', limit: 1);
    expect([for (final e in page1['items'] as List) (e as Map)['id']], [a2]);
    final page2 = await gallery(alice, 'mine_unseen',
        limit: 1,
        cursor: (page1['cursor'] as num?)?.toDouble(),
        cursorId: (page1['cursor_id'] as num?)?.toInt());
    expect(page2, isEmpty, reason: '看过的 a1 不允许在后续页漏出来，否则客户端过滤会漏图');

    // bob 的 mine / mine_unseen：没有认领 → 空
    expect(await gallery(bob, 'mine'), isEmpty);
    expect(await gallery(bob, 'mine_unseen'), isEmpty);
  });

  test('推荐优先多人合照、同一人物重复脸只算一次，并支持刷新排除', () async {
    final token = await join('alice', 'device-alice');
    final repeatedPersonPhoto = await upload(token, 'single.jpg', 90);
    final groupPhoto = await upload(token, 'group.jpg', 120);

    final people = <int>[];
    for (var i = 0; i < 4; i++) {
      people.add(await db.exec(
          "INSERT INTO persons(mean_emb, name, created_at, member_status) "
          "VALUES(x'00000000', ?, 1.0, 1)", ['团员$i']));
    }
    // single.jpg 虽然有四张脸记录，但都属于同一个团员，只能算 1 人。
    for (var i = 0; i < 4; i++) {
      await db.exec(
          "INSERT INTO faces(asset_id,x,y,w,h,embedding,person_id) "
          "VALUES(?,1,1,10,10,x'00000000',?)",
          [repeatedPersonPhoto, people.first]);
    }
    // group.jpg 有四位不同团员，应获得最高档合照权重。
    for (final pid in people) {
      await db.exec(
          "INSERT INTO faces(asset_id,x,y,w,h,embedding,person_id) "
          "VALUES(?,1,1,10,10,x'00000000',?)", [groupPhoto, pid]);
    }

    final recommended = await gallery(token, 'recommended', limit: 2, seed: 7);
    expect(recommended, [groupPhoto, repeatedPersonPhoto]);

    final refreshed = await gallery(token, 'recommended',
        limit: 1, seed: 8, exclude: [groupPhoto]);
    expect(refreshed, [repeatedPersonPhoto],
        reason: '图库够用时，新一批不应重复上一批的内容');

    final c = HttpClient();
    final seen = await c.postUrl(Uri.parse('$base/api/seen'));
    seen.headers.set('X-Token', token);
    seen.headers.contentType = ContentType.json;
    seen.write(jsonEncode({'asset_id': groupPhoto}));
    await seen.close().then((response) => response.drain<void>());
    c.close();
    expect(await gallery(token, 'recommended', limit: 2, seed: 7),
        contains(groupPhoto),
        reason: '看过只是降低权重，推荐不能像旧未看过筛选一样永久排除');
  });
}

Uint8List _jpeg(int w, int h, int r, int g, int b) {
  final img = im.Image(width: w, height: h);
  im.fill(img, color: im.ColorRgb8(r, g, b));
  return Uint8List.fromList(im.encodeJpg(img, quality: 80));
}
