/// 旅行报告快照模型 + 纪念卡内容计算。
///
/// 同一次生成的数字全部来自同一份快照（盒子聚合一次的 JSON）；
/// 「换一版」只变 [seed]（选图/称号候选/彩蛋排列），数字不变。
library;

import 'report_policy.dart';

class ReportMember {
  ReportMember({
    required this.personId,
    required this.name,
    this.userId,
    this.avatarTs,
    this.cover,
    this.photos = 0,
  });

  final int personId;
  final String name;
  final int? userId;
  final int? avatarTs;
  final String? cover;
  int photos;

  /// 头像优先账号头像，其次人物封面，最后占位图。
  String? get avatarPath {
    if (userId != null && avatarTs != null && avatarTs! > 0) {
      return '/api/user/$userId/avatar?v=$avatarTs';
    }
    final c = cover;
    return (c == null || c.isEmpty) ? null : c;
  }
}

class ReportPair {
  ReportPair(this.aId, this.bId, this.n);
  final int aId, bId, n;
}

class ReportUploader {
  ReportUploader(this.userId, this.name, this.photos, this.videos);
  final int? userId;
  final String name;
  final int photos, videos;
}

/// 盒子 JSON 的数字字段可能是 int、double、数字字符串、null 甚至 NaN；
/// 解析不了一律当作缺失，绝不在 build 期间抛异常。
int? reportIntOrNull(Object? v) {
  if (v is int) return v;
  if (v is num) return v.isFinite ? v.toInt() : null;
  if (v is String) {
    final n = num.tryParse(v.trim());
    return n != null && n.isFinite ? n.toInt() : null;
  }
  return null;
}

/// 计数字段：缺失/非法/负数都按 0。
int reportCount(Object? v) {
  final n = reportIntOrNull(v) ?? 0;
  return n < 0 ? 0 : n;
}

Iterable<Map> _maps(Object? list) =>
    list is List ? list.whereType<Map>() : const <Map>[];

class ReportSnapshot {
  ReportSnapshot._(this.raw);

  final Map<String, dynamic> raw;
  late final Map _counts = raw['counts'] is Map ? raw['counts'] as Map : {};
  late final int photos = reportCount(_counts['photos']);
  late final int videos = reportCount(_counts['videos']);
  late final int likes = reportCount(raw['likes']);
  late final int comments = reportCount(raw['comments']);
  late final bool timeNote = raw['time_note'] == true;

  late final List<ReportMember> members = [
    for (final m in _maps(raw['members']))
      if (reportIntOrNull(m['person_id']) case final id?)
        ReportMember(
          personId: id,
          name: _name(m['name'], '团员'),
          userId: reportIntOrNull(m['user_id']),
          avatarTs: reportIntOrNull(m['avatar']),
          cover: m['cover']?.toString(),
          photos: reportCount(m['photos']),
        )
  ];

  late final List<ReportPair> pairs = [
    for (final e in _maps(raw['pairs']))
      if ((reportIntOrNull(e['a']), reportIntOrNull(e['b']))
          case (final a?, final b?))
        ReportPair(a, b, reportCount(e['n']))
  ];

  late final List<ReportUploader> uploaders = [
    for (final e in _maps(raw['uploaders']))
      ReportUploader(
        reportIntOrNull(e['user_id']),
        _name(e['name'], '?'),
        reportCount(e['photos']),
        reportCount(e['videos']),
      )
  ];

  /// 候选照片池；没有合法 id 的条目直接丢弃（选图/排序都依赖 id）。
  late final List<Map<String, dynamic>> pool = [
    for (final e in _maps(raw['pool']))
      if (reportIntOrNull(e['id']) != null) Map<String, dynamic>.from(e)
  ];

  /// 个人报告数据（仅个人模式非空）。
  late final Map<String, dynamic>? personBlock = (raw['person'] is Map)
      ? Map<String, dynamic>.from(raw['person'] as Map)
      : null;

  Map<String, dynamic>? poolById(int id) {
    for (final p in pool) {
      if (reportIntOrNull(p['id']) == id) return p;
    }
    return null;
  }

  /// 团员名字；人物不在团员列表里（数据脏/刚被移除）时给占位名而不是抛异常。
  String memberName(int id, [String fallback = '团员']) {
    for (final m in members) {
      if (m.personId == id) return m.name;
    }
    return fallback;
  }

  bool get hasMedia => photos + videos > 0;

  static ReportSnapshot parse(Map<String, dynamic> json) =>
      ReportSnapshot._(json);
}

String _name(Object? v, String fallback) {
  final s = v?.toString().trim() ?? '';
  return s.isEmpty ? fallback : s;
}

/// 团队卡的一个趣味模块。
class TeamModule {
  TeamModule(this.type, this.title, this.value, {this.photoId, this.extra});
  final String type; // topFace | photographer | bestDuo | hotMoment
  final String title;
  final String value;
  final int? photoId; // hotMoment 用
  final List<String>? extra; // 并列名字
}

/// 一条彩蛋。
class ReportEgg {
  ReportEgg(this.text);
  final String text;
}

/// 团队纪念卡内容（同一快照 + seed 决定一版）。
class TeamCardModel {
  TeamCardModel(this.snap, {this.seed = 0});

  final ReportSnapshot snap;
  final int seed;

  late final List<int> photoIds = selectTeamPhotos(
    snap.pool,
    memberIds: memberIds,
    seed: seed,
  );

  Set<int> get memberIds => {for (final m in snap.members) m.personId};

  /// 本时段有照片出镜的团员（按出镜数排序），头像行展示。
  late final List<ReportMember> appearingMembers = [...snap.members]
    ..sort((a, b) => b.photos.compareTo(a.photos));

  /// 趣味模块（最多 2 个；并列展示并列，不假装唯一冠军）。
  late final List<TeamModule> modules = _modules();

  /// 彩蛋（最多 1 条）。
  late final ReportEgg? egg = _egg();

  List<TeamModule> _modules() {
    final out = <TeamModule>[];

    // 出镜王
    final facesRanked = [
      for (final m in appearingMembers) (name: m.name, n: m.photos),
    ]..sort((a, b) => b.n.compareTo(a.n));
    final faceWinners =
        crownWinners(facesRanked, ReportThresholds.crownMinCount);
    if (faceWinners.isNotEmpty && out.length < 2) {
      out.add(TeamModule(
          'topFace',
          '出镜王',
          faceWinners.length == 1
              ? '${faceWinners.first} · ${facesRanked.first.n} 张'
              : '并列',
          extra: faceWinners.length == 1 ? null : faceWinners));
    }

    // 摄影师（上传照片最多的账号）
    final upRanked = [
      for (final u in snap.uploaders) (name: u.name, n: u.photos),
    ]..sort((a, b) => b.n.compareTo(a.n));
    final upWinners = crownWinners(upRanked, ReportThresholds.crownMinCount);
    if (upWinners.isNotEmpty && out.length < 2) {
      out.add(TeamModule(
          'photographer',
          '摄影师',
          upWinners.length == 1
              ? '${upWinners.first} · ${upRanked.first.n} 张'
              : '并列',
          extra: upWinners.length == 1 ? null : upWinners));
    }

    // 最强组合（共同出镜最多的两位团员）
    if (snap.pairs.isNotEmpty &&
        snap.pairs.first.n >= ReportThresholds.pairMinCount &&
        out.length < 2) {
      final p = snap.pairs.first;
      final tie = [
        for (final e in snap.pairs)
          if (e.n == p.n) e
      ];
      String nameOf(int id) => snap.memberName(id);
      if (tie.length == 1) {
        out.add(TeamModule('bestDuo', '最强组合',
            '${nameOf(p.aId)} & ${nameOf(p.bId)} · ${p.n} 张同框'));
      } else {
        out.add(
            TeamModule('bestDuo', '最强组合', '${tie.length} 对组合并列 · ${p.n} 张同框'));
      }
    }

    // 热门瞬间（互动最高的照片；pool 已含互动 Top 20）
    if (out.length < 2) {
      Map<String, dynamic>? hot;
      var hotScore = 0;
      for (final p in snap.pool) {
        final s = poolLikes(p) + poolComments(p);
        if (s >= ReportThresholds.hotMinInteractions && s > hotScore) {
          hotScore = s;
          hot = p;
        }
      }
      if (hot != null) {
        out.add(TeamModule('hotMoment', '热门瞬间',
            '❤️ ${poolLikes(hot)} · 💬 ${poolComments(hot)}',
            photoId: reportIntOrNull(hot['id'])));
      }
    }
    return out;
  }

  ReportEgg? _egg() {
    // A 和 B 同框 N 次
    if (snap.pairs.isNotEmpty &&
        snap.pairs.first.n >= ReportThresholds.eggPairMinCount) {
      final p = snap.pairs.first;
      String nameOf(int id) => snap.memberName(id);
      return ReportEgg('${nameOf(p.aId)} 和 ${nameOf(p.bId)} 同框了 ${p.n} 次');
    }
    // 留下了 N 个影像瞬间
    final moments = snap.photos + snap.videos;
    if (moments >= ReportThresholds.eggMomentsMinCount) {
      return ReportEgg('这趟旅行留下了 $moments 个影像瞬间');
    }
    return null;
  }
}

/// 个人纪念卡内容。
class PersonalCardModel {
  PersonalCardModel(this.snap, this.personId, {this.seed = 0});

  final ReportSnapshot snap;
  final int personId;
  final int seed;

  Map<String, dynamic> get _block => snap.personBlock ?? const {};

  ReportMember get member {
    for (final m in snap.members) {
      if (m.personId == personId) return m;
    }
    return ReportMember(personId: personId, name: '我');
  }

  int? get selfUserId => reportIntOrNull(_block['user_id']);

  late final int appearPhotos = reportCount(_block['photos']);

  /// 别人镜头里的你（服务端对完整范围聚合，不使用有限候选池）。
  int get photosByOthers => reportCount(_block['others_photos']);

  List<Map<String, dynamic>> get partnerRows => [
        for (final e in _maps(_block['partners']))
          if (reportIntOrNull(e['person_id']) != null)
            Map<String, dynamic>.from(e),
      ];

  late final List<int> photoIds = selectPersonalPhotos(
    snap.pool,
    personId: personId,
    selfUserId: selfUserId,
    seed: seed,
  );

  /// 同框搭子：共同出镜最多的另一位团员。
  ReportPair? get bestPartner {
    if (partnerRows.isEmpty) return null;
    final bestN = reportCount(partnerRows.first['photos']);
    if (bestN < 2 ||
        partnerRows.where((p) => reportCount(p['photos']) == bestN).length >
            1) {
      return null;
    }
    final other = reportIntOrNull(partnerRows.first['person_id'])!;
    return ReportPair(personId, other, bestN);
  }

  /// 旅途摄影师：上传含该人物照片最多的其他账号（排除本人）。
  ReportUploader? get topPhotographer {
    final uid = selfUserId;
    if (uid == null) return null;
    final ranked = <Map>[
      for (final e in _maps(_block['photographers']))
        if (reportIntOrNull(e['user_id']) != uid) e,
    ];
    if (ranked.isEmpty) return null;
    final bestN = reportCount(ranked.first['photos']);
    if (bestN < 2 ||
        ranked.where((e) => reportCount(e['photos']) == bestN).length > 1) {
      return null;
    }
    final best = ranked.first;
    return ReportUploader(
        reportIntOrNull(best['user_id']), _name(best['name'], '?'), bestN, 0);
  }

  /// 彩蛋（最多 1 条）。
  ReportEgg? get egg {
    final partners = {
      for (final p in partnerRows) reportIntOrNull(p['person_id'])!,
    };
    if (partners.length >= 2) {
      return ReportEgg('你和 ${partners.length} 位团员都有合影');
    }
    final uid = selfUserId;
    if (uid != null &&
        appearPhotos >= ReportThresholds.eggPercentMinPhotos &&
        photosByOthers > 0) {
      // 脏数据下 others 可能大于总数；百分比夹在 0–100。
      final pct = (photosByOthers * 100 / appearPhotos).round().clamp(0, 100);
      return ReportEgg('$pct% 的出镜照片来自别人的镜头');
    }
    return null;
  }
}
