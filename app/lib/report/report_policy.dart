/// 旅行报告 V1 的客户端策略：时间口径、阈值与文案格式。
///
/// 时间口径（和盒子 box_report.dart 一致，改动必须双端同步）：
/// - 拍摄时间沿用相册墙钟口径（taken_at = 相机墙钟按 UTC 编码的秒）；
/// - 上传时间回退按报告生成手机的本地时间解释；
/// - 起止分钟均包含，内部使用 [开始分钟, 结束分钟 + 1 分钟)。
library;

import 'dart:math' as math;

import '../upload_prep.dart';
import 'report_snapshot.dart' show reportIntOrNull;

class ReportRange {
  ReportRange({required this.start, required this.end});

  /// 本地墙钟分钟（秒恒为 0）。
  final DateTime start;
  final DateTime end;

  static ReportRange defaultRange() {
    final now = DateTime.now();
    return ReportRange.fromDates(now, now);
  }

  /// 只选日期：开始当天 00:00，结束当天 23:59（秒恒为 0，+1 分钟后覆盖到 23:59:59）。
  static ReportRange fromDates(DateTime startDate, DateTime endDate) {
    final start = DateTime(startDate.year, startDate.month, startDate.day);
    final end = DateTime(endDate.year, endDate.month, endDate.day, 23, 59);
    return ReportRange(start: start, end: end);
  }

  /// start 分钟必须 <= end 分钟（相等表示选了单独一分钟）。
  bool get isValid =>
      !start.isAfter(end) && end.difference(start).inDays <= 400;

  /// 墙钟域 [fromW, toW)：拍摄时间比较用。
  int get fromW => wallClockUtcSeconds(start);
  int get toW => wallClockUtcSeconds(end) + 60;

  /// 真实纪元域 [fromT, toT)：上传时间回退比较用（本机本地时区）。
  int get fromT => start.millisecondsSinceEpoch ~/ 1000;
  int get toT => end.millisecondsSinceEpoch ~/ 1000 + 60;

  String get label {
    String p(int n) => n.toString().padLeft(2, '0');
    String hm(DateTime d) => '${p(d.hour)}:${p(d.minute)}';
    String md(DateTime d) => '${d.month}月${d.day}日';
    if (start.year == end.year &&
        start.month == end.month &&
        start.day == end.day) {
      return '${md(start)} ${hm(start)} – ${hm(end)}';
    }
    return '${md(start)} ${hm(start)} – ${md(end)} ${hm(end)}';
  }

  /// 分享图上的精简日期。完整分钟范围仍由 [label] 用于页面说明。
  String get shareLabel {
    String p(int n) => n.toString().padLeft(2, '0');
    String ymd(DateTime d) => '${d.year}.${p(d.month)}.${p(d.day)}';
    if (!multiDay) return ymd(start);
    return '${ymd(start)} — ${ymd(end)}';
  }

  bool get multiDay {
    final s = DateTime(start.year, start.month, start.day);
    final e = DateTime(end.year, end.month, end.day);
    return e.difference(s).inDays >= 1;
  }
}

/// 一次报告生成的全部配置。
class ReportConfig {
  ReportConfig({
    required this.personal,
    this.personId,
    this.personName = '',
    required this.title,
    this.location,
    this.sceneId = 'vienna-stephansdom',
    required this.range,
  });

  final bool personal;
  final int? personId;
  final String personName;
  final String title;
  final String? location;
  final String sceneId;
  final ReportRange range;
}

/// 阈值集中配置：数据不够就隐藏，不为填满页面硬造趣味。
class ReportThresholds {
  /// 团队卡主视觉照片张数区间。
  static const teamPhotosMin = 4, teamPhotosMax = 6;

  /// 个人卡照片张数区间。
  static const personalPhotosMin = 3, personalPhotosMax = 5;

  /// 出镜王/摄影师称号的最少数量；低于它隐藏模块。
  static const crownMinCount = 3;

  /// 最强组合的最少同框照数。
  static const pairMinCount = 3;

  /// 热门瞬间的最少互动（赞+评）。
  static const hotMinInteractions = 2;

  /// 「A 和 B 同框 N 次」彩蛋的最少次数。
  static const eggPairMinCount = 5;

  /// 「留下了 N 个影像瞬间」彩蛋的最少总量。
  static const eggMomentsMinCount = 12;

  /// 「M% 出镜来自别人镜头」彩蛋需要的最少出镜照数（分母太小百分比没意义）。
  static const eggPercentMinPhotos = 5;

  /// 连拍抑制：同上传者且时间差小于该秒数的照片算同组，尽量只选一张。
  static const burstSeconds = 90;

  /// 头像最多展示个数，多的收进「+N」。
  static const avatarMax = 5;
}

/// 时间桶：选图时用来打散不同时间段（一天一桶）。
int _dayBucket(num? wallSeconds) {
  if (wallSeconds == null || wallSeconds == 0 || !wallSeconds.isFinite) {
    return 0;
  }
  return (wallSeconds / 86400).floor();
}

/// 团队选图：兼顾互动、团员共现、不同上传者/时间段/人物组合。
/// [seed] 变化（换一版）时选图变化，但同一快照的数字不变。
List<int> selectTeamPhotos(
  List<Map<String, dynamic>> pool, {
  required Set<int> memberIds,
  int seed = 0,
  int want = ReportThresholds.teamPhotosMax,
}) {
  final photos = [
    for (final p in pool)
      if (p['kind'] == 'image') p,
  ];
  if (photos.isEmpty) return const [];
  // 互动 + 团员出镜基础分；seed 打乱同分顺序，换一版换图。
  final scored = [
    for (var i = 0; i < photos.length; i++)
      (
        p: photos[i],
        score: (((poolLikes(photos[i])) + (poolComments(photos[i]))) +
            1.5 * _memberCount(photos[i], memberIds)),
        jitter: ((i * 2654435761 + seed * 40503) % 97) / 97.0,
      )
  ]..sort((a, b) {
      final d = b.score + b.jitter * 0.5 - (a.score + a.jitter * 0.5);
      if (d.abs() > 0.001) return d > 0 ? 1 : -1;
      return _id(a.p).compareTo(_id(b.p));
    });

  final picked = <Map<String, dynamic>>[];
  final uploaderUsed = <int?, int>{};
  final bucketUsed = <int, int>{};
  final sigUsed = <String, int>{};
  final lastTimeByUploader = <int?, num>{};
  for (final s in scored) {
    if (picked.length >= want) break;
    final p = s.p;
    final uid = reportIntOrNull(p['uploader_id']);
    final t = _time(p);
    final bucket = _dayBucket(t);
    final sig = _personSig(p, memberIds);
    // 连拍抑制：同一上传者 90 秒内已有更优照片时跳过。
    final lastT = lastTimeByUploader[uid];
    if (lastT != null && (t - lastT).abs() < ReportThresholds.burstSeconds) {
      continue;
    }
    final penalty = 2.0 * (uploaderUsed[uid] ?? 0) +
        2.0 * (bucketUsed[bucket] ?? 0) +
        3.0 * (sigUsed[sig] ?? 0);
    if (picked.isNotEmpty &&
        s.score - penalty <= 0 &&
        picked.length >= ReportThresholds.teamPhotosMin) {
      continue; // 多样性惩罚到负分的不再硬塞
    }
    picked.add(p);
    uploaderUsed[uid] = (uploaderUsed[uid] ?? 0) + 1;
    bucketUsed[bucket] = (bucketUsed[bucket] ?? 0) + 1;
    sigUsed[sig] = (sigUsed[sig] ?? 0) + 1;
    lastTimeByUploader[uid] = t;
  }
  // 照片不足时放宽多样性（上面的惩罚只在够数时生效），自然减少即可。
  return [for (final p in picked) _id(p)];
}

/// 个人选图：本人出现 + 优先别人上传 + 时间/上传者打散。
List<int> selectPersonalPhotos(
  List<Map<String, dynamic>> pool, {
  required int personId,
  int? selfUserId,
  int seed = 0,
  int want = ReportThresholds.personalPhotosMax,
}) {
  final photos = [
    for (final p in pool)
      if (p['kind'] == 'image' &&
          _list(p['persons']).contains(personId))
        p,
  ];
  if (photos.isEmpty) return const [];
  final scored = [
    for (var i = 0; i < photos.length; i++)
      (
        p: photos[i],
        score: (poolLikes(photos[i]) + poolComments(photos[i])).toDouble() +
            // 别人镜头里的你优先（仅当本人账号明确时才加偏好）
            (selfUserId != null &&
                    reportIntOrNull(photos[i]['uploader_id']) != selfUserId
                ? 1.5
                : 0.0),
        jitter: ((i * 2654435761 + seed * 40503) % 97) / 97.0,
      )
  ]..sort((a, b) {
      final d = b.score + b.jitter - (a.score + a.jitter);
      if (d.abs() > 0.001) return d > 0 ? 1 : -1;
      return _id(a.p).compareTo(_id(b.p));
    });
  final picked = <Map<String, dynamic>>[];
  final uploaderUsed = <int?, int>{};
  final bucketUsed = <int, int>{};
  final lastTimeByUploader = <int?, num>{};
  for (final s in scored) {
    if (picked.length >= want) break;
    final p = s.p;
    final uid = reportIntOrNull(p['uploader_id']);
    final t = _time(p);
    final lastT = lastTimeByUploader[uid];
    if (lastT != null && (t - lastT).abs() < ReportThresholds.burstSeconds) {
      continue;
    }
    final penalty =
        2.0 * (uploaderUsed[uid] ?? 0) + 2.0 * (bucketUsed[_dayBucket(t)] ?? 0);
    if (picked.length >= ReportThresholds.personalPhotosMin &&
        s.score - penalty <= 0) {
      continue;
    }
    picked.add(p);
    uploaderUsed[uid] = (uploaderUsed[uid] ?? 0) + 1;
    bucketUsed[_dayBucket(t)] = (bucketUsed[_dayBucket(t)] ?? 0) + 1;
    lastTimeByUploader[uid] = t;
  }
  return [for (final p in picked) _id(p)];
}

int poolLikes(Map p) => math.max(0, reportIntOrNull(p['likes']) ?? 0);
int poolComments(Map p) => math.max(0, reportIntOrNull(p['comments']) ?? 0);

int _id(Map p) => reportIntOrNull(p['id']) ?? 0;

/// 选图用的时间（墙钟秒）；缺失/非法（含 0000 年等远古时间）都可以参与，
/// 只用于打散，不做日期格式化，所以不会抛异常。
double _time(Map p) {
  for (final k in const ['taken_w', 'taken_at']) {
    final v = p[k];
    final n = v is num ? v : (v is String ? num.tryParse(v.trim()) : null);
    if (n != null && n.isFinite) return n.toDouble();
  }
  return 0;
}

int _memberCount(Map p, Set<int> memberIds) {
  final persons = _list(p['persons']);
  var n = 0;
  for (final e in persons) {
    final id = reportIntOrNull(e);
    if (id != null && memberIds.contains(id)) n++;
  }
  return n;
}

String _personSig(Map p, Set<int> memberIds) {
  final persons = _list(p['persons']);
  final ids = <int>[];
  for (final e in persons) {
    final id = reportIntOrNull(e);
    if (id != null && memberIds.contains(id)) ids.add(id);
  }
  ids.sort();
  return ids.join(',');
}

/// 并列检测：返回并列第一的名字列表（长度 1 = 唯一冠军）。
List<String> crownWinners(List<({String name, int n})> ranked, int minCount) {
  final qualified = [
    for (final e in ranked)
      if (e.n >= minCount) e
  ];
  if (qualified.isEmpty) return const [];
  final top = qualified.first.n;
  return [
    for (final e in qualified)
      if (e.n == top) e.name
  ];
}

List<Object?> _list(Object? v) => v is List ? v : const [];
