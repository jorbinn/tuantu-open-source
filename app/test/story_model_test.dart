import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/report/story_day.dart';
import 'package:tuantu_app/report/story_model.dart';

import 'fixtures/story_sample.dart';

void main() {
  test('capture day remains a wall clock; fallback offset changes only real timestamps', () {
    final east = StoryDay.parse('2026-09-20', 480)!;
    final west = StoryDay.parse('2026-09-20', -420)!;
    expect(east.fromW, west.fromW);
    expect(east.from, east.fromW - 8 * 3600);
    expect(west.from, west.fromW + 7 * 3600);
    expect(east.to - east.from, 86400);
    expect(StoryDay.parse('2026-02-29', 0), isNull);
    expect(StoryDay.parse('2024-02-29', 0), isNotNull);
    expect(StoryDay.parse('2026-09-20', 900), isNull);
  });

  test(
    'personal and team narratives use different full counts with tied partners',
    () {
      final model = StoryModel(storySample());
      final personal = model.chapters(true);
      final team = model.chapters(false);
      expect(personal[1].number, 7);
      expect(team[1].number, 18);
      expect(personal[2].people.map((p) => p.count), [3, 3]);
      final text = personal.map((c) => '${c.title}${c.body}').join();
      expect(text, isNot(contains('最亲密')));
      expect(text, isNot(contains('上传者不一定是拍摄者')));
      expect(text, isNot(contains('依据已识别的人物')));
      expect(text, isNot(contains('你与 2 位团员同框')));
      expect(personal.first.title, contains('小雨'));
      expect(team.first.title, contains('我们'));
    },
  );

  test('one photo with no face produces a complete story and honest zero, not an empty-page error', () {
    final raw = storySample(photos: 1, appear: 0);
    raw['counts']['videos'] = 0;
    raw['person']['partners'] = [];
    raw['person']['photographers'] = [];
    raw['person']['others_photos'] = 0;
    raw['facts'] = {
      'my_uploads': 1,
      'my_videos': 0,
      'my_likes': 0,
      'my_comments': 0,
      'pending': 1,
      'time_fallback': 1,
    };
    final model = StoryModel(raw);
    final story = model.chapters(true);
    expect(story.length, greaterThanOrEqualTo(4));
    expect(story.first.body, '就这一张');
    expect(story[1].number, 0);
    expect(story[1].body, isEmpty);
    expect(story[1].metrics.firstWhere((m) => m.label == '你分享').value, 1);
    expect(story.last.kind, StoryChapterKind.closing);
    expect(model.methodology, contains('按上传日期归入'));
    expect(story.any((c) => c.kind == StoryChapterKind.responses), false);
  });

  test('no-appearance personal story can show own uploads, never unrelated team photos', () {
    final raw = storySample(appear: 0);
    raw['pool'] = [
      {'id': 1, 'kind': 'image', 'uploader_id': 11},
      {'id': 2, 'kind': 'image', 'uploader_id': 12},
    ];
    final model = StoryModel(raw);
    expect(model.photos(true), [1]);
    expect(model.chapters(true).first.body, '你也在这一天里');
  });

  test('他人出镜照尽可能铺墙，同框人物带对应合照', () {
    final raw = storySample();
    raw['pool'] = [
      for (var id = 1; id <= 12; id++)
        {
          'id': id,
          'kind': 'image',
          'uploader_id': id <= 10 ? 12 : 11,
          'persons': [1, if (id.isEven) 2, if (id % 3 == 0) 3],
          'likes': 13 - id,
          'comments': 0,
          'taken_w': id * 1000,
        },
    ];
    final model = StoryModel(raw);
    final story = model.chapters(true);
    final moments = story.firstWhere((c) => c.kind == StoryChapterKind.moments);
    final connections = story.firstWhere(
      (c) => c.kind == StoryChapterKind.connections,
    );

    expect(story.first.photoIds, [6], reason: '开场用人脸最多的合照');
    expect(moments.photoIds, List.generate(10, (i) => i + 1));
    expect(connections.people.first.name, '阿宁');
    expect(connections.people.first.photoIds, [2, 4, 6, 8, 10, 12]);
    expect(connections.links, hasLength(2));
    expect(model.selfPerson.name, '小雨');
  });
}
