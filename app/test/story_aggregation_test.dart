import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tuantu_app/box/box_db.dart';
import 'package:tuantu_app/box/box_http.dart';
import 'package:tuantu_app/report/story_day.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory root;
  late BoxDb db;
  late HttpServer server;
  late BoxHttp box;
  late String base, token;
  late int uid, pid;
  var seq = 0;
  final day = StoryDay.parse('2026-09-20', 480)!;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('story_test_');
    db = await BoxDb.open('${root.path}/box.db');
    token = await db.ensureDeviceUser('device-a', '甲');
    uid = (await db.userByToken(token))!['id'] as int;
    pid = await db.exec(
      "INSERT INTO persons(mean_emb,name,created_at,member_status) VALUES(x'00000000','甲',1,1)",
    );
    await db.exec(
      'INSERT INTO person_claims(person_id,user_id,created_at) VALUES(?,?,1)',
      [pid, uid],
    );
    box = BoxHttp(db, root);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen(box.handle);
  });
  tearDown(() async {
    await server.close(force: true);
    await db.close();
    root.deleteSync(recursive: true);
  });
  Future<Map<String, dynamic>> get(
    String path, {
    int status = 200,
    String? auth,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('$base$path'));
      request.headers.set('X-Token', auth ?? token);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      expect(response.statusCode, status, reason: body);
      return Map<String, dynamic>.from(jsonDecode(body));
    } finally {
      client.close(force: true);
    }
  }

  Future<int> asset({
    int? owner,
    int? taken,
    int? created,
    String? source = 'exif',
    String kind = 'image',
  }) => db.exec(
    '''
INSERT INTO assets(uploader_id,sha256,orig_name,ext,kind,size,taken_at,created_at,time_source)
VALUES(?,?,?,'jpg',?,1,?,?,?)
''',
    [
      owner ?? uid,
      's${seq++}',
      'photo.jpg',
      kind,
      taken ?? day.fromW + 100,
      created ?? day.to + 86400,
      source,
    ],
  );
  Future<void> face(int aid, int person) => db.exec(
    "INSERT INTO faces(asset_id,x,y,w,h,embedding,person_id) VALUES(?,0,0,10,10,x'00000000',?)",
    [aid, person],
  );
  const index = '/api/report/days?offset=480';
  const story = '/api/report/story?offset=480&day=2026-09-20';

  test('one photo creates a capture-day story even when uploaded much later and no faces', () async {
    await asset();
    final list = await get(index);
    expect((list['days'] as List).single['day'], '2026-09-20');
    final data = await get(story);
    expect(data['counts']['photos'], 1);
    expect(data['person']['photos'], 0);
    expect(data['facts']['my_uploads'], 1);
    expect(data['facts']['pending'], 1);
    expect(data['basis'], 'capture');
    expect(data['identity']['person_id'], pid);
  });

  test('date index and story use exactly one domain for EXIF, upload and legacy records', () async {
    await asset(taken: day.fromW, created: day.to + 100);
    await asset(taken: day.toW - 1, created: day.to + 100, source: 'meta');
    await asset(taken: day.fromW - 86400, created: day.from, source: 'upload');
    await asset(taken: day.from + 1, created: day.from + 1, source: null);
    await asset(taken: day.fromW + 200, created: day.to + 100, source: null);
    await asset(
      taken: day.toW,
      created: day.from,
    ); // belongs to next capture day
    await asset(
      taken: day.fromW,
      created: day.to,
      source: 'upload',
    ); // next upload day
    final list = await get(index);
    final current = (list['days'] as List).firstWhere(
      (d) => d['day'] == day.key,
    );
    expect(current['photos'], 5);
    final data = await get(story);
    expect(data['counts']['photos'], 5);
    expect(data['facts']['time_fallback'], 2);
    expect(data['time_note'], true);
    expect(
      (list['days'] as List).fold<int>(0, (n, d) => n + (d['photos'] as int)),
      7,
    );
  });

  test(
    'claims are mandatory on both endpoints; never trust claimed_by cache',
    () async {
      await db.run('UPDATE persons SET claimed_by=? WHERE id=?', [uid, pid]);
      await db.run('DELETE FROM person_claims');
      expect((await get(index, status: 409))['code'], 'claim_required');
      expect((await get(story, status: 409))['code'], 'claim_required');
      await get(story, auth: 'bad', status: 401);
    },
  );

  test('personal counts are exact across duplicate faces, interaction and different uploaders', () async {
    final otherToken = await db.ensureDeviceUser('device-b', '乙');
    final other = (await db.userByToken(otherToken))!['id'] as int;
    final partner = await db.exec(
      "INSERT INTO persons(mean_emb,name,created_at,member_status) VALUES(x'00000000','乙',1,1)",
    );
    final a = await asset(owner: other);
    await face(a, pid);
    await face(a, pid);
    await face(a, partner);
    await face(a, partner);
    await db.exec('INSERT INTO likes VALUES(?,?,1)', [a, uid]);
    await db.exec(
      "INSERT INTO comments(asset_id,user_id,body,created_at) VALUES(?,?,'喜欢',1)",
      [a, uid],
    );
    final unrelated = await asset();
    await db.exec('INSERT INTO likes VALUES(?,?,1)', [unrelated, other]);
    final data = await get('$story&person=$partner');
    expect(
      data['person']['person_id'],
      pid,
      reason: 'server derives the authenticated identity',
    );
    expect(data['person']['photos'], 1);
    expect(data['person']['others_photos'], 1);
    expect((data['person']['partners'] as List).single['photos'], 1);
    expect(data['likes'], 2);
    expect(data['facts']['my_likes'], 1);
    expect(data['facts']['my_comments'], 1);
    expect((await get(index))['days'][0]['mine'], 1);
    expect(data['pool'][0]['id'], a, reason: '同框人数多的照片必须进入候选池前列');
  });

  test(
    'later upload and deletion update the original day; removed day disappears',
    () async {
      final a = await asset();
      expect((await get(story))['counts']['photos'], 1);
      final b = await asset(created: day.to + 86400 * 10);
      expect((await get(story))['counts']['photos'], 2);
      await db.run('DELETE FROM assets WHERE id IN (?,?)', [a, b]);
      expect((await get(index))['days'], isEmpty);
      expect((await get(story))['counts']['photos'], 0);
    },
  );

  test(
    'pagination has no missing or duplicated days and ignores audio-only dates',
    () async {
      for (var i = 0; i < 35; i++) {
        await asset(taken: day.fromW - i * 86400);
      }
      await asset(taken: day.fromW + 86400, kind: 'audio');
      final first = await get(index);
      expect(first['days'], hasLength(30));
      final second = await get('$index&before=${first['next']}');
      expect(second['days'], hasLength(5));
      expect(second['next'], isNull);
      final dates = [
        ...first['days'],
        ...second['days'],
      ].map((d) => d['day']).toSet();
      expect(dates, hasLength(35));
    },
  );

  test(
    'invalid dates and offsets fail without affecting the memory-only status',
    () async {
      await get('/api/report/story?offset=480&day=2026-02-31', status: 400);
      await get('/api/report/story?offset=99999&day=2026-09-20', status: 400);
      await get('/api/report/days?offset=480&before=NaN', status: 400);
      final s = await get('/api/status');
      expect(s['service'], 'tuantu');
      expect(s['report_story'], 1);
    },
  );

  test('30个同时请求同一故事只聚合一次，后续请求重新读最新状态', () async {
    var builds = 0;
    final release = Completer<void>();
    final entered = Completer<void>();
    box.debugBeforeStoryBuild = () async {
      builds++;
      if (!entered.isCompleted) entered.complete();
      await release.future;
    };
    final requests = [for (var i = 0; i < 30; i++) get(story)];
    await entered.future;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect((await get('/api/status'))['diagnostics']['story_running'], 1);
    release.complete();
    final replies = await Future.wait(requests);
    expect(builds, 1);
    expect(replies.map((r) => r['identity']['person_id']).toSet(), {pid});
    await db.run('DELETE FROM person_claims WHERE user_id=?', [uid]);
    await get(story, status: 409);
    expect(builds, 2, reason: '不能把认领变更前的个人报告缓存给下一次请求');
  });

  test('30个不同已认领账号排队成功，个人身份不串号', () async {
    final identities = <String, int>{};
    for (var i = 0; i < 30; i++) {
      final t = await db.ensureDeviceUser('parallel-$i', '用户$i');
      final u = (await db.userByToken(t))!['id'];
      final p = await db.exec(
        "INSERT INTO persons(mean_emb,name,created_at,member_status) VALUES(x'00000000',?,1,1)",
        ['人物$i'],
      );
      await db.exec(
        'INSERT INTO person_claims(person_id,user_id,created_at) VALUES(?,?,1)',
        [p, u],
      );
      identities[t] = p;
    }
    box.debugBeforeStoryBuild = () =>
        Future<void>.delayed(const Duration(milliseconds: 10));
    await Future.wait([
      for (final e in identities.entries)
        () async {
          final r = await get(story, auth: e.key);
          expect(r['identity']['person_id'], e.value);
        }(),
    ]);
    final status = await get('/api/status');
    expect(status['diagnostics']['story_queued'], 0);
  });

  test('large photo pools never truncate factual appearance counts', () async {
    for (var i = 0; i < 47; i++) {
      final a = await asset();
      await face(a, pid);
    }
    final data = await get(story);
    expect(data['counts']['photos'], 47);
    expect(data['person']['photos'], 47);
    expect((data['pool'] as List).length, lessThanOrEqualTo(40));
  });

  test(
    'status remains responsive while report SQL waits for the database',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final transaction = db.txn((tx) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final report = get(story);
      try {
        final status = await get('/api/status')
            .timeout(const Duration(seconds: 2));
        expect(status['service'], 'tuantu');
      } finally {
        release.complete();
      }
      await transaction;
      await report;
    },
  );
}
