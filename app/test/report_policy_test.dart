/// 报告客户端策略回归：时间口径换算、选图多样性/连拍抑制/换一版、
/// 阈值隐藏、并列展示、个人报告指标。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/report/report_policy.dart';
import 'package:tuantu_app/report/report_snapshot.dart';
import 'package:tuantu_app/upload_prep.dart';

void main() {
  group('ReportRange 时间口径', () {
    test('墙钟域 = 相机墙钟按 UTC；真实域 = 本机时区纪元；分钟含两端', () {
      final start = DateTime(2026, 9, 10, 8, 30);
      final end = DateTime(2026, 9, 12, 21, 0);
      final r = ReportRange(start: start, end: end);
      expect(r.fromW, wallClockUtcSeconds(start));
      expect(r.toW, wallClockUtcSeconds(end) + 60, reason: '结束分钟 + 1 分钟，闭区间');
      final offset = start.timeZoneOffset;
      expect(r.fromT - r.fromW, -offset.inSeconds,
          reason: '真实纪元 = 墙钟编码 - 时区偏移');
      expect(r.toT, end.millisecondsSinceEpoch ~/ 1000 + 60);
      expect(r.isValid, isTrue);
      expect(r.multiDay, isTrue);
      expect(r.label, contains('9月10日'));
      expect(r.label, contains('9月12日'));
    });

    test('同一天只显示日期一次；起 == 止（单独一分钟）合法；起 > 止非法', () {
      final d = DateTime(2026, 9, 10, 8, 30);
      expect(ReportRange(start: d, end: d).isValid, isTrue);
      expect(ReportRange(start: d, end: d).label, '9月10日 08:30 – 08:30');
      expect(
          ReportRange(start: d.add(const Duration(minutes: 1)), end: d).isValid,
          isFalse);
      expect(ReportRange(start: d, end: d).multiDay, isFalse);
    });

    test('默认范围：今天 00:00 到 23:59（覆盖到 23:59:59）', () {
      final r = ReportRange.defaultRange();
      final now = DateTime.now();
      expect(r.start, DateTime(now.year, now.month, now.day));
      expect(r.end, DateTime(now.year, now.month, now.day, 23, 59));
      expect(r.toW, wallClockUtcSeconds(r.end) + 60);
      expect(r.toT, r.end.millisecondsSinceEpoch ~/ 1000 + 60);
    });

    test('fromDates：开始当天 00:00，结束当天 23:59，跨天合法', () {
      final r = ReportRange.fromDates(
          DateTime(2026, 9, 10, 15, 40), DateTime(2026, 9, 12, 8, 1));
      expect(r.start, DateTime(2026, 9, 10));
      expect(r.end, DateTime(2026, 9, 12, 23, 59));
      expect(r.isValid, isTrue);
      expect(r.multiDay, isTrue);
    });
  });

  group('团队选图', () {
    Map<String, dynamic> photo(int id,
        {String kind = 'image',
        int? uploader,
        double? t,
        int likes = 0,
        List<int> persons = const []}) {
      return {
        'id': id,
        'kind': kind,
        'uploader_id': uploader ?? 1,
        'uploader': 'u$uploader',
        'taken_w': t ?? 1000.0 + id * 100,
        'likes': likes,
        'comments': 0,
        'persons': persons,
      };
    }

    test('连拍抑制：同上传者 90 秒内只选一张', () {
      final pool = [
        photo(1, uploader: 7, t: 1000, likes: 5),
        photo(2, uploader: 7, t: 1030, likes: 4), // 同组连拍
        photo(3, uploader: 7, t: 1300, likes: 1),
      ];
      final picked = selectTeamPhotos(pool, memberIds: {});
      expect(picked, isNot(contains(2)));
      expect(picked, containsAll([1, 3]));
    });

    test('不足时自然减少：3 张就选 3 张，不硬凑', () {
      final pool = [
        photo(1, uploader: 1, t: 1000),
        photo(2, uploader: 2, t: 100000),
        photo(3, uploader: 3, t: 200000),
      ];
      expect(selectTeamPhotos(pool, memberIds: {}).length, 3);
      expect(selectTeamPhotos([], memberIds: {}), isEmpty);
    });

    test('视频不进选图（只计团队视频数）', () {
      final pool = [
        photo(1),
        photo(2, kind: 'video'),
      ];
      final picked = selectTeamPhotos(pool, memberIds: {});
      expect(picked, [1]);
    });

    test('多样性：互动低但换了上传者/时间段的照片能进来', () {
      final pool = [
        for (var i = 0; i < 8; i++)
          photo(i + 1, uploader: 1, t: 1000.0 + i * 10, likes: 9 - i),
        photo(50, uploader: 2, t: 100000.0, likes: 0),
      ];
      final picked = selectTeamPhotos(pool, memberIds: {});
      expect(picked, contains(50), reason: '同上传者连拍被抑制后，唯一的别的照片自然入选');
    });

    test('换一版：seed 变化可改变选图，但快照数字不变', () {
      final pool = [
        for (var i = 0; i < 12; i++)
          photo(i + 1, uploader: i % 3, t: 1000.0 + i * 400, likes: 3),
      ];
      final a = selectTeamPhotos(pool, memberIds: {}, seed: 0);
      final b = selectTeamPhotos(pool, memberIds: {}, seed: 7);
      final allSeeds = <Set<int>>{
        for (var s = 0; s < 8; s++)
          selectTeamPhotos(pool, memberIds: {}, seed: s).toSet()
      };
      expect(allSeeds.length, greaterThan(1), reason: '多 seed 至少能出现两版选图');
      expect(a.length, b.length, reason: '张数规则一致');
      expect(a.toSet().length, a.length, reason: '不重复选同一张');
    });
  });

  group('crownWinners 并列', () {
    test('唯一冠军 / 并列 / 不足阈值', () {
      expect(crownWinners([(name: 'a', n: 5), (name: 'b', n: 3)], 3), ['a']);
      expect(
          crownWinners([(name: 'a', n: 5), (name: 'b', n: 5)], 3), ['a', 'b']);
      expect(crownWinners([(name: 'a', n: 5)], 6), isEmpty, reason: '低于阈值隐藏称号');
    });
  });

  group('TeamCardModel 模块与彩蛋', () {
    Map<String, dynamic> snapJson({
      int photos = 30,
      int videos = 2,
      int likes = 10,
      int comments = 4,
      List<Map> members = const [],
      List<Map> pairs = const [],
      List<Map> uploaders = const [],
      List<Map> pool = const [],
    }) {
      return {
        'counts': {'photos': photos, 'videos': videos},
        'likes': likes,
        'comments': comments,
        'members': members,
        'pairs': pairs,
        'uploaders': uploaders,
        'pool': pool,
        'time_note': false,
      };
    }

    test('出镜王并列显示两个名字；数据不足隐藏', () {
      var snap = ReportSnapshot.parse(snapJson(members: [
        {'person_id': 1, 'name': '甲', 'photos': 4, 'user_id': 10, 'avatar': 0},
        {
          'person_id': 2,
          'name': '乙',
          'photos': 4,
          'user_id': null,
          'avatar': null
        },
      ]));
      var model = TeamCardModel(snap);
      var top = model.modules.where((m) => m.type == 'topFace').toList();
      expect(top, hasLength(1));
      expect(top.first.extra, unorderedEquals(['甲', '乙']), reason: '并列不假装唯一冠军');

      snap = ReportSnapshot.parse(snapJson(members: [
        {
          'person_id': 1,
          'name': '甲',
          'photos': 2,
          'user_id': null,
          'avatar': null
        },
      ]));
      model = TeamCardModel(snap);
      expect(model.modules.where((m) => m.type == 'topFace'), isEmpty,
          reason: '低于阈值隐藏');
    });

    test('热门瞬间互动不足隐藏；彩蛋按优先级选一条', () {
      final snap = ReportSnapshot.parse(snapJson(
        photos: 20,
        members: [
          {
            'person_id': 1,
            'name': '甲',
            'photos': 6,
            'user_id': null,
            'avatar': null
          },
          {
            'person_id': 2,
            'name': '乙',
            'photos': 6,
            'user_id': null,
            'avatar': null
          },
        ],
        pairs: [
          {'a': 1, 'b': 2, 'n': 7},
        ],
        pool: [
          {
            'id': 9,
            'kind': 'image',
            'uploader_id': 3,
            'uploader': '丙',
            'likes': 1,
            'comments': 0,
            'persons': [],
          },
        ],
      ));
      final model = TeamCardModel(snap);
      expect(model.modules.where((m) => m.type == 'hotMoment'), isEmpty,
          reason: '互动 1 < 阈值 2');
      expect(model.egg!.text, contains('同框了 7 次'), reason: '同框彩蛋优先于影像瞬间彩蛋');
      expect(model.modules.length, lessThanOrEqualTo(2));
    });

    test('模块最多 2 个，不堆满', () {
      final snap = ReportSnapshot.parse(snapJson(
        members: [
          {
            'person_id': 1,
            'name': '甲',
            'photos': 9,
            'user_id': null,
            'avatar': null
          },
          {
            'person_id': 2,
            'name': '乙',
            'photos': 8,
            'user_id': null,
            'avatar': null
          },
        ],
        pairs: [
          {'a': 1, 'b': 2, 'n': 5},
        ],
        uploaders: [
          {'user_id': 3, 'name': '丙', 'photos': 10, 'videos': 1},
        ],
        pool: [
          {
            'id': 9,
            'kind': 'image',
            'uploader_id': 3,
            'uploader': '丙',
            'likes': 5,
            'comments': 2,
            'persons': []
          },
        ],
      ));
      expect(TeamCardModel(snap).modules.length, 2);
    });
  });

  group('PersonalCardModel', () {
    ReportSnapshot snap({
      required int personId,
      int? userId,
      List<Map> pool = const [],
      List<Map> pairs = const [],
      List<Map> members = const [],
      List<Map> photographers = const [],
      List<Map> uploaders = const [],
      List<Map> partners = const [],
      int? othersPhotos,
    }) {
      return ReportSnapshot.parse({
        'counts': {'photos': 10, 'videos': 0},
        'likes': 0,
        'comments': 0,
        'members': members,
        'pairs': pairs,
        'uploaders': uploaders,
        'pool': pool,
        'time_note': false,
        'person': {
          'person_id': personId,
          'name': '主角',
          'user_id': userId,
          'photos': 6,
          'others_photos': othersPhotos,
          'photographers': photographers,
          'partners': partners,
        },
      });
    }

    test('别人镜头里的你使用完整范围聚合，不受候选池截断', () {
      final s = snap(
        personId: 1,
        userId: 10,
        othersPhotos: 80,
        pool: [
          {
            'id': 1,
            'kind': 'image',
            'uploader_id': 10,
            'persons': [1],
            'likes': 0,
            'comments': 0
          },
          {
            'id': 2,
            'kind': 'image',
            'uploader_id': 20,
            'persons': [1],
            'likes': 0,
            'comments': 0
          },
          {
            'id': 3,
            'kind': 'image',
            'uploader_id': 20,
            'persons': [1, 2],
            'likes': 0,
            'comments': 0
          },
          {
            'id': 4,
            'kind': 'image',
            'uploader_id': 20,
            'persons': [2],
            'likes': 0,
            'comments': 0
          },
        ],
      );
      final m = PersonalCardModel(s, 1);
      expect(m.photosByOthers, 80);
      expect(m.appearPhotos, 6, reason: '总量来自服务端聚合，不受池截断影响');
    });

    test('今日摄影师排除本人；不足 2 张隐藏', () {
      final s = snap(
        personId: 1,
        userId: 10,
        photographers: [
          {'user_id': 10, 'photos': 9},
          {'user_id': 20, 'name': '乙', 'photos': 3},
        ],
        uploaders: [],
      );
      final m = PersonalCardModel(s, 1);
      expect(m.topPhotographer!.userId, 20);
      expect(m.topPhotographer!.photos, 3, reason: '显示含主角的照片数，不得串用该上传者的全团上传数');

      final s2 = snap(
        personId: 1,
        userId: 10,
        photographers: [
          {'user_id': 20, 'photos': 1},
        ],
      );
      expect(PersonalCardModel(s2, 1).topPhotographer, isNull);
    });

    test('未认领（无账号）不展示账号相关指标，彩蛋换合影', () {
      final s = snap(
        personId: 1,
        userId: null,
        members: [
          {
            'person_id': 2,
            'name': '乙',
            'photos': 3,
            'user_id': null,
            'avatar': null
          },
          {
            'person_id': 3,
            'name': '丙',
            'photos': 2,
            'user_id': null,
            'avatar': null
          },
        ],
        partners: [
          {'person_id': 2, 'photos': 4},
          {'person_id': 3, 'photos': 2},
        ],
      );
      final m = PersonalCardModel(s, 1);
      expect(m.selfUserId, isNull);
      expect(m.topPhotographer, isNull, reason: '未认领人物不知道哪个上传者是本人，隐藏账号关系指标');
      expect(m.bestPartner!.bId == 2 || m.bestPartner!.aId == 2, isTrue);
      expect(m.egg!.text, contains('2 位团员'));
    });

    test('百分比彩蛋：出镜够分母且有别人照片才出', () {
      final s = snap(
        personId: 1,
        userId: 10,
        othersPhotos: 4,
        pool: [
          {
            'id': 2,
            'kind': 'image',
            'uploader_id': 20,
            'persons': [1],
            'likes': 0,
            'comments': 0
          },
        ],
      );
      final m = PersonalCardModel(s, 1);
      expect(m.egg!.text, contains('% 的出镜照片来自别人的镜头'));
    });
  });
}
