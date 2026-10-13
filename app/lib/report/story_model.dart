import 'report_policy.dart';
import 'report_snapshot.dart';
import 'story_day.dart';

int storyInt(dynamic value) => reportIntOrNull(value) ?? 0;

class StoryPerson {
  const StoryPerson(
    this.name,
    this.count, {
    this.cover,
    this.personId,
    this.photoIds = const [],
  });
  final String name;
  final int count;
  final String? cover;
  final int? personId;
  final List<int> photoIds;
}

class StoryLink {
  const StoryLink(this.a, this.b, this.count);
  final int a;
  final int b;
  final int count;
}

enum StoryChapterKind {
  opening,
  moments,
  connections,
  contributors,
  responses,
  closing,
}

class StoryChapter {
  const StoryChapter(
    this.kind,
    this.eyebrow,
    this.title,
    this.body, {
    this.number,
    this.unit = '',
    this.people = const [],
    this.links = const [],
    this.photoIds = const [],
    this.metrics = const [],
  });
  final StoryChapterKind kind;
  final String eyebrow, title, body, unit;
  final int? number;
  final List<StoryPerson> people;
  final List<StoryLink> links;
  final List<int> photoIds;
  final List<({String label, int value})> metrics;
}

Iterable<Map> _rows(Object? list) =>
    list is List ? list.whereType<Map>() : const <Map>[];

/// Copy is derived exclusively from full-range server counts, never the pool.
/// Uploading is not evidence of authorship, and co-occurrence is not intimacy.
class StoryModel {
  /// [requested] 是列表里点开的日期：盒子回显的 day 缺失或不合法时用它兜底。
  StoryModel(Map<String, dynamic> raw, {StoryDay? requested})
    : snapshot = ReportSnapshot.parse(raw),
      day =
          StoryDay.tryParse(raw['day'], storyInt(raw['offset'])) ??
          requested ??
          (throw const FormatException('story day missing')),
      facts = raw['facts'] is Map
          ? Map<String, dynamic>.from(raw['facts'] as Map)
          : <String, dynamic>{},
      identity = raw['identity'] is Map
          ? Map<String, dynamic>.from(raw['identity'] as Map)
          : <String, dynamic>{};

  final ReportSnapshot snapshot;
  final StoryDay day;
  final Map<String, dynamic> facts, identity;
  int get personId => storyInt(identity['person_id']);
  String get name => (identity['name'] ?? '我').toString();
  int get appearances => storyInt(snapshot.personBlock?['photos']);
  int get pending => storyInt(facts['pending']);
  int get fallback => storyInt(facts['time_fallback']);
  int get myUploads => storyInt(facts['my_uploads']);
  int get moments => snapshot.photos + snapshot.videos;

  int? get groupHeroPhotoId {
    Map<String, dynamic>? best;
    var bestFaces = 1;
    var bestReactions = -1;
    for (final photo in snapshot.pool) {
      if (photo['kind'] != 'image') continue;
      final faces = <int>{
        for (final value in _list(photo['persons']))
          if (value is num) value.toInt(),
      }.length;
      final reactions = storyInt(photo['likes']) + storyInt(photo['comments']);
      if (faces > bestFaces ||
          (faces == bestFaces && reactions > bestReactions)) {
        best = photo;
        bestFaces = faces;
        bestReactions = reactions;
      }
    }
    final id = storyInt(best?['id']);
    return id > 0 ? id : null;
  }

  StoryPerson get selfPerson {
    for (final member in snapshot.members) {
      if (member.personId == personId) {
        return StoryPerson(
          member.name,
          appearances,
          cover: member.avatarPath,
          personId: member.personId,
        );
      }
    }
    return StoryPerson(name, appearances, personId: personId);
  }

  List<int> _poolPhotos(
    bool Function(Map<String, dynamic>) include, {
    int limit = 12,
  }) {
    final ids = <int>[];
    final seen = <int>{};
    for (final photo in snapshot.pool) {
      if (photo['kind'] != 'image' || !include(photo)) continue;
      final id = storyInt(photo['id']);
      if (id > 0 && seen.add(id)) ids.add(id);
      if (ids.length >= limit) break;
    }
    return ids;
  }

  List<int> get otherUploadedPhotos {
    final selfUserId = storyInt(snapshot.personBlock?['user_id']);
    if (selfUserId <= 0) return const [];
    return _poolPhotos((photo) {
      final people = _list(photo['persons']);
      return people.contains(personId) &&
          storyInt(photo['uploader_id']) != selfUserId;
    });
  }

  List<int> photosWith(int otherPersonId) => _poolPhotos((photo) {
    final people = _list(photo['persons']);
    return people.contains(personId) && people.contains(otherPersonId);
  }, limit: 6);

  List<int> photosOf(int targetPersonId) => _poolPhotos(
    (photo) =>
        (_list(photo['persons'])).contains(targetPersonId),
    limit: 4,
  );

  List<int> photos(bool personal) {
    if (personal && appearances == 0) {
      return [
        for (final photo in snapshot.pool)
          if (photo['kind'] == 'image' &&
              photo['uploader_id'] == snapshot.personBlock?['user_id'])
            storyInt(photo['id']),
      ].take(4).toList();
    }
    return personal
        ? selectPersonalPhotos(
            snapshot.pool,
            personId: personId,
            selfUserId: storyInt(snapshot.personBlock?['user_id']),
            want: 4,
          )
        : selectTeamPhotos(
            snapshot.pool,
            memberIds: snapshot.members.map((m) => m.personId).toSet(),
            want: 4,
          );
  }

  List<StoryPerson> get partners {
    final members = {for (final m in snapshot.members) m.personId: m};
    return [
      for (final row in _rows(snapshot.personBlock?['partners']))
        if (members[storyInt(row['person_id'])] case final member?)
          StoryPerson(
            member.name,
            storyInt(row['photos']),
            cover: member.avatarPath,
            personId: member.personId,
            photoIds: photosWith(member.personId),
          ),
    ];
  }

  List<StoryChapter> chapters(bool personal) {
    final chosen = photos(personal);
    final others = storyInt(snapshot.personBlock?['others_photos']);
    final likes = personal ? storyInt(facts['my_likes']) : snapshot.likes;
    final comments = personal
        ? storyInt(facts['my_comments'])
        : snapshot.comments;
    final people = personal
        ? partners
        : [
            for (final member
                in ([...snapshot.members]..sort((a, b) {
                  final order = b.photos.compareTo(a.photos);
                  return order == 0 ? a.personId.compareTo(b.personId) : order;
                })))
              if (member.photos > 0)
                StoryPerson(
                  member.name,
                  member.photos,
                  cover: member.avatarPath,
                  personId: member.personId,
                  photoIds: photosOf(member.personId),
                ),
          ];
    final contributors = personal
        ? [
            for (final row in _rows(snapshot.personBlock?['photographers']))
              StoryPerson(
                (row['name'] ?? '团友').toString(),
                storyInt(row['photos']),
                cover:
                    storyInt(row['avatar']) > 0 && storyInt(row['user_id']) > 0
                    ? '/api/user/${storyInt(row['user_id'])}/avatar?v=${storyInt(row['avatar'])}'
                    : null,
              ),
          ]
        : [
            for (final u
                in ([...snapshot.uploaders]..sort(
                  (a, b) =>
                      (b.photos + b.videos).compareTo(a.photos + a.videos),
                )))
              if (u.photos + u.videos > 0)
                StoryPerson(u.name, u.photos + u.videos),
          ];
    final othersWall = otherUploadedPhotos;
    final hero = groupHeroPhotoId ?? chosen.firstOrNull;
    final links = personal
        ? [
            for (final person in people)
              if (person.personId != null)
                StoryLink(personId, person.personId!, person.count),
          ]
        : [
            for (final pair in snapshot.pairs)
              StoryLink(pair.aId, pair.bId, pair.n),
          ];
    return [
      StoryChapter(
        StoryChapterKind.opening,
        '团图 · 每日旅行故事',
        personal ? '$name的\n这一天' : '我们的\n这一天',
        personal && appearances == 0 && chosen.isNotEmpty
            ? '你也在这一天里'
            : moments == 1
            ? '就这一张'
            : '这一天，重新发生',
        photoIds: [if (hero != null) hero],
      ),
      StoryChapter(
        StoryChapterKind.moments,
        personal ? '01 / 镜头里的你' : '01 / 一起留下的',
        personal
            ? appearances == 0
                  ? '你不必出现在\n每一张照片里'
                  : othersWall.isNotEmpty
                  ? '别人镜头里的\n你'
                  : '这些瞬间里，\n都有你'
            : snapshot.photos == 1
            ? '故事从\n一张照片开始'
            : '把这一天，\n留在相册里',
        '',
        number: personal ? appearances : snapshot.photos,
        unit: personal ? '张照片里有你' : '张照片',
        metrics: personal
            ? [
                (label: '别人拍到你', value: others),
                (label: '你分享', value: myUploads),
                (label: '视频', value: storyInt(facts['my_videos'])),
              ]
            : [
                (label: '段视频', value: snapshot.videos),
                (label: '位上传者', value: contributors.length),
              ],
        photoIds: personal && othersWall.isNotEmpty
            ? othersWall
            : chosen.skip(1).take(6).toList(),
      ),
      StoryChapter(
        StoryChapterKind.connections,
        '02 / 相遇的形状',
        personal
            ? people.isEmpty
                  ? '同框的故事，\n还在等待'
                  : '和他们\n撞进同一张照片'
            : people.isEmpty
            ? '风景也可以\n成为主角'
            : '这一页，\n是我们',
        '',
        people: people,
        links: links,
      ),
      if (contributors.isNotEmpty)
        StoryChapter(
          StoryChapterKind.contributors,
          '03 / 照片的来处',
          personal ? '谁把你\n留在了相册里' : '谢谢每一个\n分享瞬间的人',
          '',
          people: contributors,
        ),
      if (likes + comments > 0)
        StoryChapter(
          StoryChapterKind.responses,
          '04 / 留下的回应',
          personal ? '这一刻\n有人回应' : '我们留给\n彼此的回应',
          '',
          number: likes,
          unit: '个赞',
          metrics: [(label: '条评论', value: comments)],
        ),
      StoryChapter(
        StoryChapterKind.closing,
        '收藏这一天',
        '还会有新的照片，\n也会有新的故事',
        '',
        photoIds: chosen,
        metrics: personal
            ? [
                (label: '张出镜照', value: appearances),
                (label: '位同框团员', value: partners.length),
              ]
            : [
                (label: '张照片', value: snapshot.photos),
                (label: '段视频', value: snapshot.videos),
              ],
      ),
    ];
  }

  String get methodology =>
      '按拍摄日期归档 · 同一照片重复人脸只计一次。'
      '${fallback > 0 ? '$fallback 份影像缺少拍摄时间，按上传日期归入（${day.zone}）。' : ''}'
      '${snapshot.timeNote || storyInt(facts['legacy_time']) > 0 ? '部分旧照片的时间可能近似。' : ''}'
      '${pending > 0 ? '人脸识别尚未完成。' : ''}';
}

List<Object?> _list(Object? v) => v is List ? v : const [];
