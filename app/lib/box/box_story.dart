import '../report/story_day.dart';
import 'box_db.dart';
import 'box_report.dart';

// Same mutually exclusive domains as reportRangeSql. Each asset has one day.
String storyWallTimeSql(int offset) => '''CASE
WHEN a.time_source IN ('exif','meta') THEN a.taken_at
WHEN a.time_source='upload' THEN a.created_at + ${offset * 60}
WHEN a.time_source IS NULL AND a.taken_at IS NOT NULL
  AND ABS(a.taken_at-a.created_at)>=1 THEN a.taken_at
WHEN a.time_source IS NULL THEN a.created_at + ${offset * 60}
ELSE NULL END''';

Future<Map<String, Object?>?> storyIdentity(BoxDb db, Map user) => db.qOne('''
SELECT p.id person_id, COALESCE(NULLIF(p.name, ''), u.name) name,
       p.cover_face_id
FROM person_claims c JOIN persons p ON p.id=c.person_id
JOIN users u ON u.id=c.user_id
WHERE c.user_id=? AND p.member_status=1
''', [user['id']]);

/// One read transaction for identity and every count. Never starts recognition.
Future<Map<String, dynamic>?> buildStoryDays({
  required BoxDb db,
  required Map user,
  required int offset,
  StoryDay? before,
}) async {
  final identity = await storyIdentity(db, user);
  if (identity == null) return null;
  final wall = storyWallTimeSql(offset);
  final rows = await db.q('''
SELECT strftime('%Y-%m-%d', $wall, 'unixepoch') day,
       SUM(CASE WHEN a.kind='image' THEN 1 ELSE 0 END) photos,
       SUM(CASE WHEN a.kind='video' THEN 1 ELSE 0 END) videos,
       MAX(CASE WHEN a.kind='image' THEN a.id END) cover_id,
       SUM(CASE WHEN a.kind='image' AND EXISTS (
         SELECT 1 FROM faces f WHERE f.asset_id=a.id AND f.person_id=?
       ) THEN 1 ELSE 0 END) mine
FROM published_assets a
WHERE a.kind IN ('image','video') ${before == null ? '' : 'AND ($wall) < ?'}
GROUP BY day HAVING day IS NOT NULL ORDER BY day DESC LIMIT 31
''', [identity['person_id'], if (before != null) before.fromW]);
  return {
    'identity': identity,
    'offset': offset,
    'basis': 'capture',
    'days': rows.take(30).toList(),
    'next': rows.length > 30 ? rows[29]['day'] : null,
  };
}

Future<Map<String, dynamic>?> buildStoryData({
  required BoxDb db,
  required Map user,
  required StoryDay day,
  required Future<List<Map<String, dynamic>>> Function(List<Map>, Map) cards,
}) async {
  final identity = await storyIdentity(db, user);
  if (identity == null) return null;
  final pid = identity['person_id'] as int;
  final data = await buildReportData(
    db: db,
    user: user,
    cards: cards,
    personId: pid,
    visualOnly: true,
    fromW: day.fromW.toDouble(),
    toW: day.toW.toDouble(),
    fromT: day.from.toDouble(),
    toT: day.to.toDouble(),
  );
  if (data == null) return null;
  final range = reportRangeSql('a');
  final args = reportRangeArgs(day.fromW.toDouble(), day.toW.toDouble(),
      day.from.toDouble(), day.to.toDouble());
  final facts = await db.qOne('''
SELECT SUM(CASE WHEN kind='image' AND analyzed=0 THEN 1 ELSE 0 END) pending,
       SUM(CASE WHEN uploader_id=? AND kind='image' THEN 1 ELSE 0 END) my_uploads,
       SUM(CASE WHEN uploader_id=? AND kind='video' THEN 1 ELSE 0 END) my_videos,
       SUM(CASE WHEN time_source='upload' OR (time_source IS NULL AND
         (taken_at IS NULL OR ABS(taken_at-created_at)<1)) THEN 1 ELSE 0 END) time_fallback,
       SUM(CASE WHEN time_source IS NULL THEN 1 ELSE 0 END) legacy_time
FROM published_assets a WHERE $range AND a.kind IN ('image','video')
''', [user['id'], user['id'], ...args]);
  final personalLikes = firstIntValue(await db.q('''
SELECT COUNT(*) FROM likes l JOIN published_assets a ON a.id=l.asset_id
WHERE a.kind='image' AND $range
AND EXISTS(SELECT 1 FROM faces f WHERE f.asset_id=a.id AND f.person_id=?)
''', [...args, pid]));
  final personalComments = firstIntValue(await db.q('''
SELECT COUNT(*) FROM comments c JOIN published_assets a ON a.id=c.asset_id
WHERE a.kind='image' AND $range
AND EXISTS(SELECT 1 FROM faces f WHERE f.asset_id=a.id AND f.person_id=?)
''', [...args, pid]));
  return {
    ...data,
    'day': day.key,
    'offset': day.offsetMinutes,
    'basis': 'capture',
    'identity': identity,
    'facts': {
      ...?facts,
      'my_likes': personalLikes,
      'my_comments': personalComments
    },
  };
}
