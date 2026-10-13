/// Daily stories keep V1's capture wall-clock / upload fallback policy.
/// The offset only applies to true upload timestamps, never EXIF wall clocks.
class StoryDay {
  StoryDay(this.date, this.offsetMinutes);
  final DateTime date;
  final int offsetMinutes;

  /// 盒子返回的 day 可能是 null、非字符串，或 SQLite 对远古时间给出的
  /// `0000-01-01` / `-001-11-30`（EXIF `0000:00:00`）；这些都返回 null。
  static StoryDay? tryParse(Object? value, int offsetMinutes) =>
      value is String ? parse(value, offsetMinutes) : null;

  static StoryDay? parse(String value, int offsetMinutes) {
    if (offsetMinutes < -720 ||
        offsetMinutes > 840 ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      return null;
    }
    final date = DateTime.tryParse('${value}T00:00:00Z');
    if (date == null || date.year < 1970 || date.year > 9998) return null;
    final result = StoryDay(date, offsetMinutes);
    return result.key == value ? result : null;
  }

  String get key => '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
  int get fromW => date.millisecondsSinceEpoch ~/ 1000;
  int get toW => fromW + 86400;
  int get from => fromW - offsetMinutes * 60;
  int get to => from + 86400;
  String get label => '${date.year}年${date.month}月${date.day}日';
  String get zone {
    final value = offsetMinutes.abs();
    return 'UTC${offsetMinutes < 0 ? '-' : '+'}'
        '${(value ~/ 60).toString().padLeft(2, '0')}:'
        '${(value % 60).toString().padLeft(2, '0')}';
  }
}

/// 每日故事列表的一行（已校验日期）。
class StoryDayRow {
  StoryDayRow(this.day, this.row);
  final StoryDay day;
  final Map<String, dynamic> row;
}

/// 拍摄日期不可信（缺失、0000 年、1970 年前、9999 年等）的影像汇总。
/// 这些日期无法打开当天故事（盒子也会拒绝），只在列表末尾单独展示。
class StoryUnknownDays {
  int photos = 0, videos = 0, mine = 0, days = 0;
  int get moments => photos + videos;
}

int _count(Object? v) {
  final n = v is num
      ? (v.isFinite ? v.toInt() : 0)
      : v is String
          ? (num.tryParse(v.trim())?.toInt() ?? 0)
          : 0;
  return n < 0 ? 0 : n;
}

/// 把盒子的日列表拆成「可打开的日期」和「时间未知」汇总，永不抛异常。
({List<StoryDayRow> dated, StoryUnknownDays? unknown}) splitStoryDays(
  Iterable<Map<String, dynamic>> rows,
  int offsetMinutes,
) {
  final dated = <StoryDayRow>[];
  StoryUnknownDays? unknown;
  for (final row in rows) {
    final day = StoryDay.tryParse(row['day'], offsetMinutes);
    if (day != null) {
      dated.add(StoryDayRow(day, row));
      continue;
    }
    final u = unknown ??= StoryUnknownDays();
    u.days++;
    u.photos += _count(row['photos']);
    u.videos += _count(row['videos']);
    u.mine += _count(row['mine']);
  }
  if (unknown != null && unknown.moments == 0) unknown = null;
  return (dated: dated, unknown: unknown);
}
