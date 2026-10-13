/// 旅行报告聚合回归：时间口径（墙钟/真实纪元/旧数据兼容）、分钟边界、
/// 按照片去重的出镜/同框、赞评总量、非团员只出媒体、个人报告。
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
    root = Directory.systemTemp.createTempSync('tuantu_report_');
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

  var userSeq = 0;
  Future<int> joinGetUid(String name) async {
    final c = HttpClient();
    final r = await c.postUrl(Uri.parse('$base/api/join'));
    r.headers.contentType = ContentType.json;
    r.write(jsonEncode({'name': name, 'device_id': 'dev-${userSeq++}'}));
    final resp = await r.close();
    final body = await resp.transform(utf8.decoder).join();
    c.close();
    final token = (jsonDecode(body) as Map)['token'] as String;
    final u = await db.userByToken(token);
    return u!['id'] as int;
  }

  Future<String> tokenOf(int uid) async {
    final u = await db.userById(uid);
    return u!['token'] as String;
  }

  Future<Map<String, dynamic>> report(String token,
      {required int fromW,
      required int toW,
      required int fromT,
      required int toT,
      int? person,
      int expectStatus = 200}) async {
    final q =
        'from_w=$fromW&to_w=$toW&from_t=$fromT&to_t=$toT${person != null ? '&person=$person' : ''}';
    final c = HttpClient();
    final r = await c.getUrl(Uri.parse('$base/api/report/data?$q'));
    r.headers.set('X-Token', token);
    final resp = await r.close();
    final text = await resp.transform(utf8.decoder).join();
    c.close();
    expect(resp.statusCode, expectStatus, reason: text);
    return Map<String, dynamic>.from(jsonDecode(text) as Map);
  }

  /// 种一张资产。wall/true 分别是 taken_at(墙钟域)/created_at(真实域) 秒；
  /// source 必填（null = 旧数据无来源），避免测试助手自作聪明猜来源。
  Future<int> seedAsset(int uploader,
      {String kind = 'image',
      double? wall,
      double? truth,
      required String? source,
      String sha = 'default'}) async {
    final taken = wall ?? (truth ?? 0.0);
    final created = truth ?? (wall ?? 0.0);
    return db.exec('''
INSERT INTO assets(uploader_id, sha256, orig_name, ext, kind, size, taken_at, created_at, time_source)
VALUES(?,?,?,?,?,?,?,?,?)''', [
      uploader,
      '$sha-${userSeq++}-${taken.toInt()}-$created',
      'f.jpg',
      kind == 'video' ? 'mp4' : 'jpg',
      kind,
      10,
      taken,
      created,
      source
    ]);
  }

  Future<int> seedPerson(String? name,
      {int memberStatus = 0, int? claimedBy}) async {
    final id = await db.exec(
        "INSERT INTO persons(mean_emb, name, created_at, member_status, claimed_by) VALUES(x'00000000', ?, 1.0, ?, ?)",
        [name, memberStatus, claimedBy]);
    // 报告读 person_claims（claimed_by 只是缓存），一并种上。
    if (claimedBy != null) {
      await db.exec(
          'INSERT INTO person_claims(person_id, user_id, created_at) VALUES(?,?,1.0)',
          [id, claimedBy]);
    }
    return id;
  }

  Future<void> addFace(int asset, int person) async {
    await db.exec(
        "INSERT INTO faces(asset_id, x, y, w, h, embedding, person_id) VALUES(?,1,1,10,10,x'00000000',?)",
        [asset, person]);
  }

  // 墙钟域 [1000, 1060)，真实域 [5000, 5060)。互不重叠，专测口径。
  const fw = 1000, tw = 1060, ft = 5000, tt = 5060;

  test('时间口径：exif 走墙钟域、upload 走真实域、旧数据只归属一个时间域', () async {
    final uid = await joinGetUid('甲');
    final t = await tokenOf(uid);
    await seedAsset(uid, wall: 1000, source: 'exif'); // 墙钟起点（含）
    await seedAsset(uid, wall: 1059.5, source: 'exif'); // 墙钟内
    await seedAsset(uid, wall: 1060, source: 'exif'); // 墙钟终点（不含）
    await seedAsset(uid, truth: 5000, source: 'upload'); // 真实起点（含）
    await seedAsset(uid, truth: 5059, source: 'upload');
    await seedAsset(uid, truth: 5060, source: 'upload'); // 不含
    // 旧版上传回填：taken_at==created_at，按上传真实域命中。
    await seedAsset(uid, wall: 5001, truth: 5001, source: null);
    // 旧版明确拍摄时间：taken_at!=created_at，只按墙钟域命中。
    await seedAsset(uid, wall: 1002, truth: 6000, source: null);
    // 旧数据：两个域都不在 → 不命中
    await seedAsset(uid, wall: 2000, truth: 6000, source: null);
    // exif 来源即使 created_at 撞进真实域也不该靠它命中（墙钟域外）
    await seedAsset(uid, wall: 9000, truth: 5002, source: 'exif');
    // upload 来源即使 taken_at 撞进墙钟域也不命中
    await seedAsset(uid, wall: 1001, truth: 9000, source: 'upload');

    final d = await report(t, fromW: fw, toW: tw, fromT: ft, toT: tt);
    final counts = d['counts'] as Map;
    expect(counts['photos'], 6,
        reason: 'exif×2 + upload×2 + 旧上传回填×1 + 旧拍摄时间×1');
  });

  test('同一来源覆盖整分钟边界：[开始, 结束+1分钟)', () async {
    final uid = await joinGetUid('甲');
    final t = await tokenOf(uid);
    // 结束分钟 1059+60=1060 不含：1060 不命中；1059.99 命中
    await seedAsset(uid, wall: 1059.99, source: 'exif');
    final d = await report(t, fromW: fw, toW: tw, fromT: ft, toT: tt);
    expect((d['counts'] as Map)['photos'], 1);
  });

  test('跨天范围 + 视频/照片/赞/评论总量（当前有效总量）', () async {
    final u1 = await joinGetUid('甲');
    final u2 = await joinGetUid('乙');
    final t = await tokenOf(u1);
    final a1 = await seedAsset(u1, wall: 1000, source: 'exif');
    final a2 = await seedAsset(u2, wall: 1010, source: 'exif');
    final v1 =
        await seedAsset(u2, kind: 'video', truth: 5000, source: 'upload');
    // 范围外的互动不计入
    final out = await seedAsset(u1, wall: 9999, source: 'exif');
    for (final aid in [a1, a2, out]) {
      await db.exec(
          'INSERT INTO likes(asset_id, user_id, created_at) VALUES(?,?,1.0)',
          [aid, u2]);
      await db.exec(
          'INSERT INTO likes(asset_id, user_id, created_at) VALUES(?,?,1.0)',
          [aid, u1]);
      await db.exec(
          'INSERT INTO comments(asset_id, user_id, body, created_at) VALUES(?,?,?,1.0)',
          [
            aid,
            u1 == u2 ? u1 : u2,
            'hi',
          ]);
    }
    final d = await report(t, fromW: fw, toW: tw, fromT: ft, toT: tt);
    expect((d['counts'] as Map)['photos'], 2);
    expect((d['counts'] as Map)['videos'], 1);
    expect(d['likes'], 4, reason: '两张范围内照片各 2 赞');
    expect(d['comments'], 2);
    final uploaders = (d['uploaders'] as List).cast<Map>();
    final byName = {for (final u in uploaders) u['name']: u};
    expect(byName['甲']!['photos'], 1);
    expect(byName['乙']!['photos'], 1);
    expect(byName['乙']!['videos'], 1);
    expect(v1, greaterThan(0));
  });

  test('出镜按照片去重；同框搭子按团员对统计；视频不算出镜', () async {
    final u1 = await joinGetUid('甲');
    final t = await tokenOf(u1);
    final p1 = await seedPerson('甲脸', memberStatus: 1, claimedBy: u1);
    final p2 = await seedPerson('乙脸', memberStatus: 1);
    final p3 = await seedPerson('路人', memberStatus: 2); // 非团员
    final a1 = await seedAsset(u1, wall: 1000, source: 'exif');
    await addFace(a1, p1);
    await addFace(a1, p1); // 同照片第二张脸：出镜只算一次
    await addFace(a1, p2);
    final a2 = await seedAsset(u1, wall: 1005, source: 'exif');
    await addFace(a2, p1);
    await addFace(a2, p2);
    // 视频里有 p1 的脸：不算出镜
    final v = await seedAsset(u1, kind: 'video', truth: 5000, source: 'upload');
    await addFace(v, p1);
    // 非团员 p3 的脸照常入库：不算人物统计，但照片计入媒体总量
    await addFace(a2, p3);

    final d = await report(t, fromW: fw, toW: tw, fromT: ft, toT: tt);
    final members = (d['members'] as List).cast<Map>();
    final m1 = members.firstWhere((m) => m['person_id'] == p1);
    final m2 = members.firstWhere((m) => m['person_id'] == p2);
    expect(members.where((m) => m['person_id'] == p3), isEmpty,
        reason: '非团员不进人物统计');
    expect(m1['photos'], 2);
    expect(m2['photos'], 2);
    final pairs = (d['pairs'] as List).cast<Map>();
    expect(pairs.first['n'], 2, reason: 'p1/p2 同框 2 张');
    expect(pairs.first['a'], p1 < p2 ? p1 : p2);
    expect((d['counts'] as Map)['photos'], 2, reason: '非团员照片仍在媒体总量');
    expect((d['counts'] as Map)['videos'], 1);
  });

  test('个人报告：出镜/别人镜头/摄影师原始数据；非团员人物 404', () async {
    final u1 = await joinGetUid('甲');
    final u2 = await joinGetUid('乙');
    final u3 = await joinGetUid('丙');
    final t = await tokenOf(u1);
    final p1 = await seedPerson('甲脸', memberStatus: 1, claimedBy: u1);
    // 甲出镜 3 张：2 张乙拍、1 张自己拍
    final a1 = await seedAsset(u2, wall: 1000, source: 'exif');
    await addFace(a1, p1);
    final a2 = await seedAsset(u2, wall: 1001, source: 'exif');
    await addFace(a2, p1);
    final a3 = await seedAsset(u1, wall: 1002, source: 'exif');
    await addFace(a3, p1);
    // 丙上传但甲不在场，不算
    await seedAsset(u3, wall: 1003, source: 'exif');

    final d =
        await report(t, fromW: fw, toW: tw, fromT: ft, toT: tt, person: p1);
    final person = d['person'] as Map;
    expect(person['photos'], 3);
    expect(person['user_id'], u1);
    final ph = (person['photographers'] as List).cast<Map>();
    final byUid = {for (final e in ph) e['user_id'] as int: e['photos'] as int};
    expect(byUid[u2], 2, reason: '乙拍了 2 张含甲的照片');
    expect(byUid[u1], 1, reason: '服务端返回全部上传者（甲自己拍的 1 张）；排除本人在客户端快照层做');
    expect(person['others_photos'], 2, reason: '完整范围聚合，不能从候选池反推总数');
    // 池里含甲的照片带 persons 标记
    final pool = (d['pool'] as List).cast<Map>();
    final mine = pool.where((e) => (e['persons'] as List).contains(p1));
    expect(mine.length, 3, reason: '个人报告池优先含本人照片');

    final pOutsider = await seedPerson('非团员', memberStatus: 0);
    await report(t,
        fromW: fw,
        toW: tw,
        fromT: ft,
        toT: tt,
        person: pOutsider,
        expectStatus: 404);
  });

  test('旧数据时间来源不明时 time_note 提示；已删除媒体不统计', () async {
    final uid = await joinGetUid('甲');
    final t = await tokenOf(uid);
    final legacy = await seedAsset(uid, wall: 5000, truth: 5000, source: null);
    final d = await report(t, fromW: fw, toW: tw, fromT: ft, toT: tt);
    expect(d['time_note'], true, reason: '回填行 taken_at==created_at 视为来源不明');

    await db.run('DELETE FROM assets WHERE id=?', [legacy]);
    final d2 = await report(t, fromW: fw, toW: tw, fromT: ft, toT: tt);
    expect((d2['counts'] as Map)['photos'], 0);
    expect(d2['time_note'], false);
  });

  test('未归类人脸不会让报告接口崩溃', () async {
    final uid = await joinGetUid('甲');
    final t = await tokenOf(uid);
    final asset = await seedAsset(uid, wall: 1000, source: 'exif');
    await db.exec(
        "INSERT INTO faces(asset_id,x,y,w,h,embedding,person_id) VALUES(?,1,1,10,10,x'00',NULL)",
        [asset]);
    final d = await report(t, fromW: fw, toW: tw, fromT: ft, toT: tt);
    expect((d['counts'] as Map)['photos'], 1);
    expect(d['members'], isEmpty);
  });

  test('未认领团员可出个人报告；单人团、纯风景也能出团队报告', () async {
    final u1 = await joinGetUid('甲');
    final t = await tokenOf(u1);
    // 纯风景：无任何人物
    await seedAsset(u1, wall: 1000, source: 'exif');
    final d = await report(t, fromW: fw, toW: tw, fromT: ft, toT: tt);
    expect((d['counts'] as Map)['photos'], 1);
    expect((d['members'] as List), isEmpty);
    expect((d['pairs'] as List), isEmpty);
    // 未认领团员
    final p = await seedPerson('独行者', memberStatus: 1);
    final a = await seedAsset(u1, wall: 1002, source: 'exif');
    await addFace(a, p);
    final dp =
        await report(t, fromW: fw, toW: tw, fromT: ft, toT: tt, person: p);
    expect((dp['person'] as Map)['photos'], 1);
    expect((dp['person'] as Map)['user_id'], isNull);
  });

  test('范围校验：起 >= 止 或超长直接 400', () async {
    final uid = await joinGetUid('甲');
    final t = await tokenOf(uid);
    await report(t,
        fromW: 100, toW: 100, fromT: 100, toT: 200, expectStatus: 400);
    await report(t,
        fromW: 0,
        toW: 500 * 86400,
        fromT: 0,
        toT: 500 * 86400,
        expectStatus: 400);
  });
}
