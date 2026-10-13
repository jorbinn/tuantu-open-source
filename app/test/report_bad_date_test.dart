import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/card_reader.dart';
import 'package:tuantu_app/pages/report_list_page.dart';
import 'package:tuantu_app/report/report_snapshot.dart';
import 'package:tuantu_app/report/story_day.dart';
import 'package:tuantu_app/report/story_model.dart';
import 'package:tuantu_app/widgets/soft_error.dart';

import 'fixtures/story_sample.dart';

/// 盒子对 EXIF 0000:00:00 的照片按 SQLite strftime 给出 `0000-01-01`、
/// `-001-11-30` 这类日期；旧客户端对它们 `StoryDay.parse(...)!` 直接抛异常，
/// 整个「旅行故事」页变成灰块。
final _dirtyDays = <Map<String, dynamic>>[
  {'day': '2026-09-20', 'photos': 18, 'videos': 2, 'mine': 7, 'cover_id': 9},
  {'day': '9999-12-31', 'photos': 1, 'videos': 0, 'mine': 0, 'cover_id': 10},
  {'day': '1969-12-31', 'photos': 2, 'videos': 0, 'mine': 1, 'cover_id': 11},
  {'day': '0000-01-01', 'photos': '3', 'videos': null, 'mine': 0},
  {'day': '-001-11-30', 'photos': 4, 'videos': 1, 'mine': 'x'},
  {'day': null, 'photos': 1},
  {'day': 20260920, 'photos': 1},
];

class _Adapter implements HttpClientAdapter {
  _Adapter(this.days, {this.next});
  final List<Map<String, dynamic>> days;
  final Object? next;
  final paths = <String>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    return ResponseBody.fromString(
      jsonEncode({
        'identity': {'person_id': 1, 'name': '小雨'},
        'days': days,
        'next': next,
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  test('splitStoryDays keeps valid days and buckets the rest', () {
    final split = splitStoryDays(_dirtyDays, 480);
    expect(split.dated.map((e) => e.day.key), ['2026-09-20']);
    final u = split.unknown!;
    expect(u.days, 6);
    expect(u.photos, 1 + 2 + 3 + 4 + 1 + 1);
    expect(u.videos, 1);
    expect(u.mine, 1);
  });

  test('StoryDay.tryParse rejects BC / pre-1970 / non-string days', () {
    for (final v in [
      '0000-01-01',
      '-001-11-30',
      '0001-01-01',
      '1969-12-31',
      '9999-12-31',
      '2026-02-30',
      '',
      null,
      42,
    ]) {
      expect(StoryDay.tryParse(v, 0), isNull, reason: '$v');
    }
    expect(StoryDay.tryParse('1970-01-01', 0)?.key, '1970-01-01');
  });

  testWidgets('report list with 0000/BC/missing dates renders, 时间未知 last',
      (tester) async {
    final adapter = _Adapter(_dirtyDays, next: '0000-01-01');
    Api.I.configure('http://story.test:8000', 'token');
    Api.I.dio.httpClientAdapter = adapter;
    await tester.pumpWidget(const MaterialApp(home: ReportListPage()));
    await _drain(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.text('2026年9月20日'), findsOneWidget);
    expect(find.text('时间未知'), findsOneWidget);
    expect(find.text('12 张照片 · 1 段视频'), findsOneWidget);
    // 游标是 0000 年：盒子会拒绝，不显示「更早的故事」。
    expect(find.text('更早的故事'), findsNothing);
    final dated = tester.getTopLeft(find.text('2026年9月20日')).dy;
    final unknown = tester.getTopLeft(find.text('时间未知')).dy;
    expect(unknown, greaterThan(dated));
    // 点「时间未知」不会去请求一个非法日期的故事。
    await tester.tap(find.text('时间未知'));
    await _drain(tester);
    expect(
        adapter.paths.where((p) => p.endsWith('/api/report/story')), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('report list with only undated photos shows the bucket',
      (tester) async {
    Api.I.configure('http://story.test:8000', 'token');
    Api.I.dio.httpClientAdapter = _Adapter([
      {'day': '0000-01-01', 'photos': 5, 'videos': 0, 'mine': 0},
    ]);
    await tester.pumpWidget(const MaterialApp(home: ReportListPage()));
    await _drain(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('时间未知'), findsOneWidget);
    expect(find.text('5 张照片 · 0 段视频'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('ReportSnapshot / card models tolerate dirty aggregates', () {
    final snap = ReportSnapshot.parse({
      'counts': null,
      'likes': 'NaN',
      'comments': -3,
      'members': [
        {'person_id': '1', 'name': '', 'photos': '9'},
        {'person_id': null, 'name': '坏'},
        'junk',
        {'person_id': 2.0, 'name': '阿宁', 'photos': 4},
      ],
      'pairs': [
        {'a': 1, 'b': 99, 'n': 9},
        {'a': null, 'b': 2, 'n': 3},
      ],
      'uploaders': [
        {'user_id': 'u', 'name': null, 'photos': '5', 'videos': null},
      ],
      'pool': [
        {'kind': 'image', 'likes': 3, 'comments': 1},
        {
          'id': '7',
          'kind': 'image',
          'likes': '4',
          'persons': 'bad',
          'taken_w': -62167219200,
        },
        {
          'id': 8,
          'kind': 'image',
          'persons': [1, 2],
          'taken_at': 'x'
        },
      ],
      'person': {
        'photos': 6,
        'others_photos': 60,
        'user_id': 11,
        'partners': [
          'junk',
          {'person_id': 2, 'photos': 3},
          {'person_id': null, 'photos': 3},
        ],
        'photographers': [
          {'user_id': 12, 'name': null, 'photos': '4'},
        ],
      },
    });
    expect(snap.photos, 0);
    expect(snap.likes, 0);
    expect(snap.comments, 0);
    expect(snap.members.map((m) => m.personId), [1, 2]);
    expect(snap.members.first.name, '团员');
    expect(snap.pairs.length, 1);
    expect(snap.pool.length, 2);
    final team = TeamCardModel(snap);
    expect(() => team.modules, returnsNormally);
    expect(team.egg?.text, contains('团员'));
    expect(team.photoIds.toSet(), {7, 8});

    final personal = PersonalCardModel(snap, 42);
    expect(personal.member.personId, 42);
    expect(personal.bestPartner?.bId, 2);
    expect(personal.topPhotographer?.photos, 4);
    expect(personal.partnerRows.length, 1);
    expect(personal.egg?.text, startsWith('100%'));
    expect(() => personal.photoIds, returnsNormally);

    // 没有 person 块时个人模型也不应抛异常。
    final bare = PersonalCardModel(ReportSnapshot.parse({}), 1);
    expect(bare.appearPhotos, 0);
    expect(bare.egg, isNull);
    expect(bare.photoIds, isEmpty);
  });

  test('StoryModel falls back to requested day and tolerates missing maps', () {
    final raw = storySample()
      ..['day'] = '0000-01-01'
      ..['facts'] = null
      ..['identity'] = 'bad';
    final requested = StoryDay.parse('2026-09-20', 480)!;
    final model = StoryModel(raw, requested: requested);
    expect(model.day.key, '2026-09-20');
    expect(model.name, '我');
    expect(() => model.chapters(true), returnsNormally);
    expect(() => model.chapters(false), returnsNormally);
    expect(model.methodology, isA<String>());
    expect(() => StoryModel({'day': '0000-01-01'}), throwsFormatException);
    expect(storyInt('12'), 12);
    expect(storyInt(double.nan), 0);
    expect(storyInt('abc'), 0);
  });

  test('card reader day label tolerates 0000 / huge timestamps', () {
    CardMedia at(int t) => CardMedia(
          uri: 'u',
          name: 'n',
          relativePath: '',
          size: 1,
          takenAt: t,
          isVideo: false,
          isRaw: false,
        );
    expect(at(-62167219200).day, '日期未知');
    expect(at(0).day, '日期未知');
    expect(at(9000000000000).day, '日期未知');
    expect(at(-2208988800 - 86400).day, '日期未知');
    expect(at(1790000000).day, '2026-09-21');
  });

  testWidgets('soft error widget replaces the gray block in release',
      (tester) async {
    final original = ErrorWidget.builder;
    late Widget w;
    try {
      installSoftErrorWidget(release: false);
      expect(ErrorWidget.builder, same(original));
      installSoftErrorWidget(release: true);
      w = ErrorWidget.builder(const FlutterErrorDetails(exception: 'x'));
    } finally {
      ErrorWidget.builder = original;
    }
    expect(w, isA<SoftErrorBox>());
    await tester.pumpWidget(w);
    expect(tester.takeException(), isNull);
  });
}
