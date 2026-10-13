/// 旅行报告 V1 的盒子端聚合。
///
/// 时间口径（必须和客户端 report_policy.dart 一致）：
/// - taken_at 是「相机墙钟按 UTC 编码」的秒，在墙钟域比较；
/// - created_at 是真实 Unix 秒，在真实域比较；
/// - time_source 记录来源：exif/meta 用墙钟域，upload 用真实域；
/// - NULL（旧数据）中，taken_at 与 created_at 相同的是旧版上传回填，走真实域；
///   两者不同的按旧版拍摄时间处理，走墙钟域。每个资产只归属一个时间域。
///
/// 聚合全部走 SQL + 索引，不触碰人脸管线、不触发重聚类、不解码图片。
/// 返回 null 表示 personId 无效或不是团员。
library;

import 'box_db.dart';

/// 报告候选池上限：互动热门 + 时间分散，选图在客户端做（换一版不重新请求）。
const kReportPoolLimit = 40;

/// 时间范围 SQL 片段（参数顺序见 [reportRangeArgs]）。
String reportRangeSql(String a) => '''
(
  (a.time_source = 'exif' OR a.time_source = 'meta')
    AND a.taken_at IS NOT NULL AND a.taken_at >= ? AND a.taken_at < ?
  OR a.time_source = 'upload'
    AND a.created_at >= ? AND a.created_at < ?
  OR a.time_source IS NULL AND a.taken_at IS NOT NULL
    AND ABS(a.taken_at - a.created_at) >= 1
    AND a.taken_at >= ? AND a.taken_at < ?
  OR a.time_source IS NULL
    AND (a.taken_at IS NULL OR ABS(a.taken_at - a.created_at) < 1)
    AND a.created_at >= ? AND a.created_at < ?
)''';

List<Object?> reportRangeArgs(
  double fromW,
  double toW,
  double fromT,
  double toT,
) => [fromW, toW, fromT, toT, fromW, toW, fromT, toT];

Future<Map<String, dynamic>?> buildReportData({
  required BoxDb db,
  required Map user,
  required Future<List<Map<String, dynamic>>> Function(List<Map> rows, Map user)
  cards,
  required double fromW,
  required double toW,
  required double fromT,
  required double toT,
  int? personId,
  bool visualOnly = false,
}) async {
  final range =
      '${reportRangeSql('a')}'
      '${visualOnly ? " AND a.kind IN ('image','video')" : ''}';
  final rargs = reportRangeArgs(fromW, toW, fromT, toT);

  // 团员人物（member_status=1）+ 各自的认领账号（可能没有）。
  final memberRows = await db.q('''
SELECT p.id, p.name, p.cover_face_id, c.user_id, u.name uname, u.avatar
FROM persons p
LEFT JOIN person_claims c ON c.person_id = p.id
LEFT JOIN users u ON u.id = c.user_id
WHERE p.member_status = 1
ORDER BY p.id''');
  final members = <Map<String, Object?>>[
    for (final r in memberRows)
      {
        'person_id': r['id'],
        'name': (r['name']?.toString().trim().isNotEmpty ?? false)
            ? r['name']
            : (r['uname'] ?? '团员'),
        'user_id': r['user_id'],
        'avatar': r['user_id'] == null ? null : r['avatar'],
        'cover':
            '/api/person/${r['id']}/cover?c=${(r['cover_face_id'] as num?)?.toInt() ?? 0}',
      },
  ];
  final memberIds = [for (final m in members) m['person_id'] as int];

  // 个人报告只支持团员人物。
  Map<String, Object?>? personRow;
  if (personId != null) {
    if (!memberIds.contains(personId)) return null;
    personRow = members.firstWhere((m) => m['person_id'] == personId);
  }

  // 团队媒体总量（仍然存在的全部作品；非团员的照片也计入媒体总量）。
  final counts = {'photos': 0, 'videos': 0, 'audio': 0};
  for (final r in await db.q(
    'SELECT a.kind k, COUNT(*) c FROM published_assets a WHERE $range GROUP BY a.kind',
    rargs,
  )) {
    final k = r['k']?.toString();
    if (k == 'image') {
      counts['photos'] = (r['c'] as num).toInt();
    } else if (k == 'video') {
      counts['videos'] = (r['c'] as num).toInt();
    } else {
      counts['audio'] = counts['audio']! + (r['c'] as num).toInt();
    }
  }
  // 点赞/评论：范围内媒体截至当前的总量，不按互动时间再筛。
  final likeTotal = firstIntValue(
    await db.q('''
SELECT COUNT(*) c FROM likes l
JOIN published_assets a ON a.id = l.asset_id WHERE $range''', rargs),
  );
  final commentTotal = firstIntValue(
    await db.q('''
SELECT COUNT(*) c FROM comments c
JOIN published_assets a ON a.id = c.asset_id WHERE $range''', rargs),
  );

  // 出镜（仅静态照片，按照片去重；同一照片多个框只算一次）。
  final appearRows = await db.q('''
SELECT f.person_id pid, COUNT(DISTINCT f.asset_id) n
FROM faces f JOIN published_assets a ON a.id = f.asset_id
WHERE a.kind = 'image' AND f.person_id IS NOT NULL AND $range
GROUP BY f.person_id''', rargs);
  final appearByPerson = <int, int>{
    for (final r in appearRows)
      (r['pid'] as num).toInt(): (r['n'] as num).toInt(),
  };

  // 同框搭子（团员 × 团员，按照片去重）。
  final pairs = <Map<String, Object?>>[];
  if (memberIds.isNotEmpty) {
    final mph = List.filled(memberIds.length, '?').join(',');
    final pairRows = await db.q(
      '''
SELECT f1.person_id p1, f2.person_id p2, COUNT(DISTINCT f1.asset_id) n
FROM faces f1
JOIN faces f2 ON f2.asset_id = f1.asset_id AND f2.person_id > f1.person_id
JOIN published_assets a ON a.id = f1.asset_id
WHERE a.kind = 'image' AND $range
  AND f1.person_id IN ($mph) AND f2.person_id IN ($mph)
GROUP BY p1, p2 ORDER BY n DESC LIMIT 12''',
      [...rargs, ...memberIds, ...memberIds],
    );
    pairs.addAll([
      for (final r in pairRows)
        {'a': r['p1'], 'b': r['p2'], 'n': (r['n'] as num).toInt()},
    ]);
  }

  // 上传者（账号维度，含视频；摄影师/「别人镜头里的你」都用它）。
  final uploaders = <Map<String, Object?>>[
    for (final r in await db.q('''
SELECT a.uploader_id, u.name, u.avatar,
  SUM(CASE WHEN a.kind='image' THEN 1 ELSE 0 END) photos,
  SUM(CASE WHEN a.kind='video' THEN 1 ELSE 0 END) videos
FROM published_assets a LEFT JOIN users u ON u.id = a.uploader_id
WHERE $range GROUP BY a.uploader_id''', rargs))
      {
        'user_id': r['uploader_id'],
        'name': r['name'] ?? '?',
        'avatar': r['avatar'],
        'photos': (r['photos'] as num?)?.toInt() ?? 0,
        'videos': (r['videos'] as num?)?.toInt() ?? 0,
      },
  ];

  // 候选池：互动热门 20 + 时间分散 20（去重后封顶），数字计算与选图分离。
  final poolIds = <int>[];
  final seen = <int>{};
  // 开场封面优先使用同框人数最多的照片，先把合照放进候选池。
  final groupShots = await db.q('''
SELECT a.id, COUNT(DISTINCT f.person_id) face_count
FROM published_assets a JOIN faces f ON f.asset_id=a.id AND f.person_id IS NOT NULL
WHERE a.kind='image' AND $range
GROUP BY a.id HAVING face_count >= 2
ORDER BY face_count DESC,
  ((SELECT COUNT(*) FROM likes l WHERE l.asset_id=a.id) +
   (SELECT COUNT(*) FROM comments c WHERE c.asset_id=a.id)) DESC,
  a.id DESC LIMIT 8''', rargs);
  for (final r in groupShots) {
    final id = (r['id'] as num).toInt();
    if (seen.add(id)) poolIds.add(id);
  }
  // 个人报告：把该人物范围内的照片（按互动）优先放进池子，
  // 否则人少照片少时会不巧被热门/分散名额挤掉。
  if (personId != null) {
    final mine = await db.q(
      '''
SELECT DISTINCT a.id FROM published_assets a
JOIN faces f ON f.asset_id = a.id AND f.person_id = ?
WHERE a.kind = 'image' AND $range
ORDER BY (
  (SELECT COUNT(*) FROM likes l WHERE l.asset_id = a.id) +
  (SELECT COUNT(*) FROM comments c WHERE c.asset_id = a.id)
) DESC, a.id DESC LIMIT 12''',
      [personId, ...rargs],
    );
    for (final r in mine) {
      final id = (r['id'] as num).toInt();
      if (seen.add(id)) poolIds.add(id);
    }
  }
  final hot = await db.q('''
SELECT a.id FROM published_assets a WHERE a.kind = 'image' AND $range
ORDER BY (
  (SELECT COUNT(*) FROM likes l WHERE l.asset_id = a.id) +
  (SELECT COUNT(*) FROM comments c WHERE c.asset_id = a.id)
) DESC, a.id DESC LIMIT 20''', rargs);
  for (final r in hot) {
    final id = (r['id'] as num).toInt();
    if (seen.add(id)) poolIds.add(id);
  }
  // 时间分散：读取范围内照片 id 后等距抽样，确保长旅程后半段也能入池。
  final timeRows = await db.q('''
SELECT a.id FROM published_assets a WHERE a.kind = 'image' AND $range
ORDER BY COALESCE(a.taken_at, a.created_at), a.id''', rargs);
  final timeIds = [for (final r in timeRows) (r['id'] as num).toInt()];
  final wantSpread = timeIds.length < 20 ? timeIds.length : 20;
  if (wantSpread > 0) {
    final step = timeIds.length / wantSpread;
    for (var i = 0; i < wantSpread; i++) {
      final id = timeIds[(i * step).floor()];
      if (seen.add(id)) poolIds.add(id);
    }
  }
  if (poolIds.length > kReportPoolLimit) {
    poolIds.removeRange(kReportPoolLimit, poolIds.length);
  }

  // 池内每张照片里出现的人物（全员，不只团员；客户端选图时再区分）。
  final facesByAsset = <int, List<int>>{};
  if (poolIds.isNotEmpty) {
    final ph = List.filled(poolIds.length, '?').join(',');
    for (final r in await db.q(
      'SELECT DISTINCT asset_id, person_id FROM faces WHERE asset_id IN ($ph) AND person_id IS NOT NULL',
      poolIds,
    )) {
      facesByAsset
          .putIfAbsent((r['asset_id'] as num).toInt(), () => [])
          .add((r['person_id'] as num).toInt());
    }
  }

  final poolRows = poolIds.isEmpty
      ? const <Map<String, Object?>>[]
      : await db.q(
          'SELECT * FROM published_assets WHERE id IN '
          '(${List.filled(poolIds.length, '?').join(',')})',
          poolIds,
        );
  final rowById = {for (final r in poolRows) (r['id'] as num).toInt(): r};
  // 注入卡片字段（上传者/赞/评论/缩略图）：选图和热门模块都要用。
  final poolCards = poolRows.isEmpty
      ? const <Map<String, dynamic>>[]
      : await cards(poolRows, user);
  final cardById = {for (final c in poolCards) c['id'] as int: c};
  final pool = <Map<String, Object?>>[
    for (final id in poolIds)
      if (rowById[id] != null)
        {
          ...?cardById[id],
          'taken_w': rowById[id]!['taken_at'] ?? rowById[id]!['created_at'],
          'persons': facesByAsset[id] ?? const <int>[],
        },
  ];

  // 旧数据时间来源不明（回填行 taken_at==created_at）：客户端提示时间可能近似。
  final legacyNote =
      firstIntValue(
        await db.q('''
SELECT COUNT(*) c FROM published_assets a
WHERE $range AND a.time_source IS NULL
  AND (a.taken_at IS NULL OR ABS(a.taken_at - a.created_at) < 1)''', rargs),
      ) >
      0;

  final out = <String, dynamic>{
    'generated_at': BoxDb.now(),
    'counts': counts,
    'likes': likeTotal,
    'comments': commentTotal,
    'members': [
      for (final m in members)
        {...m, 'photos': appearByPerson[m['person_id']] ?? 0},
    ],
    'pairs': pairs,
    'uploaders': uploaders,
    'pool': pool,
    'time_note': legacyNote,
  };

  if (personRow != null) {
    final pid = personRow['person_id'] as int;
    final claimUid = personRow['user_id'] as int?;
    // 含该人物的照片里各账号上传多少（今日摄影师；客户端排除本人）。
    final photographers = <Map<String, Object?>>[
      for (final r in await db.q(
        '''
SELECT a.uploader_id, u.name, u.avatar, COUNT(DISTINCT a.id) n
FROM published_assets a JOIN faces f ON f.asset_id = a.id AND f.person_id = ?
LEFT JOIN users u ON u.id = a.uploader_id
WHERE a.kind = 'image' AND $range
GROUP BY a.uploader_id ORDER BY n DESC''',
        [pid, ...rargs],
      ))
        {
          'user_id': r['uploader_id'],
          'name': r['name'] ?? '?',
          'avatar': r['avatar'],
          'photos': (r['n'] as num).toInt(),
        },
    ];
    final othersPhotos = claimUid == null
        ? null
        : photographers
              .where((p) => p['user_id'] != claimUid)
              .fold<int>(0, (n, p) => n + (p['photos'] as int));

    // 团队榜只返回前 12 对；个人报告需要该人物的完整搭子关系和总人数。
    final personalPairs = <Map<String, Object?>>[];
    if (memberIds.length > 1) {
      final mph = List.filled(memberIds.length, '?').join(',');
      for (final r in await db.q(
        '''
SELECT f2.person_id other, COUNT(DISTINCT f1.asset_id) n
FROM faces f1
JOIN faces f2 ON f2.asset_id = f1.asset_id AND f2.person_id != f1.person_id
JOIN published_assets a ON a.id = f1.asset_id
WHERE f1.person_id = ? AND a.kind = 'image' AND $range
  AND f2.person_id IN ($mph)
GROUP BY f2.person_id ORDER BY n DESC''',
        [pid, ...rargs, ...memberIds],
      )) {
        personalPairs.add({
          'person_id': r['other'],
          'photos': (r['n'] as num).toInt(),
        });
      }
    }
    out['person'] = {
      'person_id': pid,
      'name': personRow['name'],
      'user_id': claimUid,
      'photos': appearByPerson[pid] ?? 0,
      'others_photos': othersPhotos,
      'photographers': photographers,
      'partners': personalPairs,
    };
  }
  return out;
}

int firstIntValue(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) return 0;
  final v = rows.first.values.first;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return 0;
}
