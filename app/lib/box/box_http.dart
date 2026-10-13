/// 本机盒子 HTTP API，路径与 Python 盒子对齐。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as im;
import 'package:path/path.dart' as p;

import '../live_photo.dart';
import '../report/story_day.dart';
import 'box_db.dart';
import 'box_face_cluster.dart' show memberStatusPriority;
import 'box_faces.dart';
import 'box_report.dart';
import 'box_story.dart';
import 'box_upload.dart';

const _imageExts = {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
  'bmp',
  'tif',
  'tiff',
  'heic',
  'heif',
  'avif',
  'cr2',
  'cr3',
  'nef',
  'arw',
  'dng',
  'orf',
  'rw2',
  'raf',
  'pef',
  'srw',
  'x3f',
  '3fr',
  'iiq',
};
const _videoExts = {
  'mp4',
  'mov',
  'm4v',
  'mkv',
  'avi',
  '3gp',
  'webm',
  'ts',
  'mpg',
  'mpeg',
};
const _audioExts = {'wav', 'mp3', 'm4a', 'aac', 'flac', 'ogg', 'amr'};
const _preview = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'};

/// 合照：至少两位团员人物出镜的照片或视频。同一人物多张脸只算一次。
const _groupShotFilter = '''
 AND a.kind IN ('image','video')
 AND (
   SELECT COUNT(DISTINCT f.person_id)
   FROM faces f
   JOIN persons p ON p.id=f.person_id
   WHERE f.asset_id=a.id AND p.member_status=1
 ) >= 2
''';

/// 封面 URL 带脸 id，换封面后客户端不会继续用旧缓存。
String personCoverUrl(int pid, {int? coverFaceId}) =>
    '/api/person/$pid/cover?c=${coverFaceId ?? 0}';

const _mime = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'mov': 'video/quicktime',
  'webm': 'video/webm',
  'mp3': 'audio/mpeg',
};

typedef PersonCoverWriter = Future<bool> Function(Map<String, dynamic> payload);

Future<bool> writePersonCoverOffload(Map<String, dynamic> payload) =>
    compute(writePersonCover, payload, debugLabel: 'tuantu-person-cover');

/// 给 CPU/内存重任务用的有界执行池。排队任务不占执行名额，失败也一定释放。
@visibleForTesting
class BoundedTaskPool {
  BoundedTaskPool(this.limit, {this.maxQueued, this.queueTimeout})
    : assert(limit > 0),
      assert(maxQueued == null || maxQueued >= 0);

  final int limit;
  final int? maxQueued;
  final Duration? queueTimeout;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  final Queue<Completer<void>> _priorityWaiters = Queue<Completer<void>>();
  int _priorityStreak = 0;
  int _running = 0;

  int get running => _running;
  int get queued => _waiters.length + _priorityWaiters.length;

  Future<T> run<T>(Future<T> Function() task, {bool priority = false}) async {
    await _acquire(priority);
    try {
      return await task();
    } finally {
      _release();
    }
  }

  Future<void> _acquire(bool priority) {
    if (_running < limit) {
      _running++;
      return Future<void>.value();
    }
    if (maxQueued != null && queued >= maxQueued!) {
      return Future<void>.error(const TaskPoolBusy());
    }
    final waiter = Completer<void>();
    final queue = priority ? _priorityWaiters : _waiters;
    queue.addLast(waiter);
    final timeout = queueTimeout;
    final timer = timeout == null
        ? null
        : Timer(timeout, () {
            if (queue.remove(waiter)) {
              waiter.completeError(const TaskPoolBusy());
            }
          });
    return waiter.future.whenComplete(() => timer?.cancel());
  }

  void _release() {
    // Foreground covers jump bulk uploads, but every fourth grant gives a
    // waiting upload a turn, so continuous browsing cannot starve uploads.
    if (_priorityWaiters.isNotEmpty &&
        (_waiters.isEmpty || _priorityStreak < 3)) {
      _priorityStreak++;
      _priorityWaiters.removeFirst().complete();
      return;
    }
    if (_waiters.isNotEmpty) {
      _priorityStreak = 0;
      // 名额直接交给队首，running 不先减，避免新任务插队造成超限。
      _waiters.removeFirst().complete();
      return;
    }
    _running--;
    _priorityStreak = 0;
  }
}

class TaskPoolBusy implements Exception {
  const TaskPoolBusy();
}

class BoxHttp {
  BoxHttp(
    this.db,
    this.root, {
    this.boxId = '',
    PersonCoverWriter? personCoverWriter,
    int personCoverConcurrency = 2,
    int personCoverMaxQueued = 32,
    Duration personCoverQueueTimeout = const Duration(seconds: 5),
  }) : _personCoverWriter = personCoverWriter ?? writePersonCoverOffload,
       _personCoverPool = BoundedTaskPool(
         personCoverConcurrency,
         maxQueued: personCoverMaxQueued,
         queueTimeout: personCoverQueueTimeout,
       );
  final BoxDb db;
  final Directory root;

  /// 内存中的盒子身份，/api/status 只读这个字段，不查库。
  String boxId;
  final PersonCoverWriter _personCoverWriter;
  final BoundedTaskPool _personCoverPool;
  // Acquire before reading originals: seven uploaders must not decode seven
  // full-resolution photos at once. Accepted uploads wait rather than drop work.
  final _imageWorkPool = BoundedTaskPool(2);
  final _reportPool = BoundedTaskPool(
    1,
    maxQueued: 32,
    queueTimeout: const Duration(seconds: 20),
  );
  final _coverJobs = <String, Future<File?>>{};
  final _personCoverGenerations = <int, int>{};
  final LinkedHashSet<int> _coverFailureLogged = LinkedHashSet<int>();
  final _reportPreviewJobs = <int, Future<File?>>{};
  final _userCache = <int, Map?>{};
  int _cachedTotal = 0;
  int _cachedPersons = 0;
  bool _refreshingStatus = false;
  final _statusRefreshClock = Stopwatch()..start();
  int _nextStatusRefreshMs = 0;
  int _requestSeq = 0;
  final _inflightByCategory = <String, int>{};

  /// 正在写的 orig/thumbs/_tmp_ 路径。清扫时必须跳过。
  final liveUploadFiles = <String>{};

  /// 测试钩子：快照资产名单之后、开始删文件之前。
  Future<void> Function()? debugAfterOrphanSnapshot;

  @visibleForTesting
  Future<void> Function()? debugBeforeUploadPreparation;

  void markLiveFile(String path) => liveUploadFiles.add(p.normalize(path));
  void unmarkLiveFile(String path) => liveUploadFiles.remove(p.normalize(path));

  bool _isLivePath(String path) => liveUploadFiles.contains(p.normalize(path));

  Directory get orig => Directory(p.join(root.path, 'orig'));
  Directory get thumbs => Directory(p.join(root.path, 'thumbs'));
  Directory get avatars => Directory(p.join(root.path, 'avatars'));

  Future<void> handle(HttpRequest req) async {
    final requestId = (++_requestSeq).toRadixString(36);
    final category = _requestCategory(req.method, req.uri.path);
    final watch = Stopwatch()..start();
    _inflightByCategory[category] = (_inflightByCategory[category] ?? 0) + 1;
    Object? requestError;
    try {
      req.response.headers.set('X-Tuantu-Request-Id', requestId);
      final path = req.uri.path;
      final m = req.method;
      if (m == 'GET' && path == '/api/status') {
        await _status(req);
        return;
      }
      if (m == 'POST' && path == '/api/join') {
        await _join(req);
        return;
      }
      // These exact GET routes were already public. Do not queue a token lookup
      // in SQLite for every avatar/thumbnail, especially during face writes.
      if (m == 'GET' && _isPublicMedia(path)) {
        if (path.startsWith('/api/asset/')) {
          await _assetRoutes(req, const {}, path, m);
        } else if (path.startsWith('/api/person/')) {
          await _personCoverRoute(req, path);
        } else {
          await _userRoutes(req, const {}, path, m);
        }
        return;
      }
      final user = await _auth(req);
      if (user == null) {
        await _err(req, 401, '请先加入');
        return;
      }
      if (m == 'GET' && path == '/api/me') {
        await _me(req, user);
        return;
      }
      if (m == 'GET' && path == '/api/users') {
        await _users(req);
        return;
      }
      if (m == 'POST' && path == '/api/me/profile') {
        await _profile(req, user);
        return;
      }
      if (m == 'POST' && path == '/api/me/avatar') {
        await _avatar(req, user);
        return;
      }
      if (m == 'GET' && path == '/api/me/upload_index') {
        await _uploadIndex(req, user);
        return;
      }
      if (m == 'GET' && path == '/api/me/assets') {
        await _ownAssets(req, user, user);
        return;
      }
      if (m == 'POST' && path == '/api/upload') {
        await _upload(req, user);
        return;
      }
      if (m == 'GET' && path == '/api/gallery/home') {
        await _galleryHome(req, user);
        return;
      }
      if (m == 'GET' && path == '/api/gallery') {
        await _gallery(req, user);
        return;
      }
      if (m == 'POST' && path == '/api/like') {
        await _like(req, user);
        return;
      }
      if (m == 'POST' && path == '/api/seen') {
        await _seen(req, user);
        return;
      }
      if (m == 'GET' && path == '/api/persons') {
        await _persons(req, user);
        return;
      }
      if (m == 'GET' && path.startsWith('/api/person/')) {
        await _personCoverRoute(req, path);
        return;
      }
      if (m == 'GET' && path.startsWith('/api/user/')) {
        await _userRoutes(req, user, path, m);
        return;
      }
      if (path.startsWith('/api/asset/')) {
        await _assetRoutes(req, user, path, m);
        return;
      }
      if (m == 'POST' && path == '/api/persons/merge') {
        await _mergePersons(req, user);
        return;
      }
      if (m == 'POST' && path == '/api/persons/members') {
        await _markPersonsMembers(req, user);
        return;
      }
      if (m == 'GET' && path == '/api/report/data') {
        await _reportData(req, user);
        return;
      }
      if (m == 'GET' &&
          (path == '/api/report/days' || path == '/api/report/story')) {
        await _story(req, user, index: path.endsWith('/days'));
        return;
      }
      if (m == 'POST' && path.startsWith('/api/persons/')) {
        await _personAction(req, user, path);
        return;
      }
      if (m == 'GET' && path == '/api/deal') {
        await _json(req, {
          'batch_no': 1,
          'cards': [],
          'view': 'all',
          'remaining': 0,
        });
        return;
      }
      await _err(req, 404, 'Not Found');
    } catch (e) {
      requestError = e;
      try {
        await _err(req, 500, e.toString());
      } catch (_) {}
    } finally {
      watch.stop();
      final left = (_inflightByCategory[category] ?? 1) - 1;
      if (left <= 0) {
        _inflightByCategory.remove(category);
      } else {
        _inflightByCategory[category] = left;
      }
      var status = 0;
      try {
        status = req.response.statusCode;
      } catch (_) {}
      final slowLimitMs = category == 'status'
          ? 250
          : category == 'person_cover'
          ? 500
          : 3000;
      if (requestError != null ||
          status >= 500 ||
          watch.elapsedMilliseconds >= slowLimitMs) {
        final inflight = _inflightByCategory.values.fold<int>(
          0,
          (a, b) => a + b,
        );
        debugPrint(
          '[http] id=$requestId category=$category stage=complete '
          'ms=${watch.elapsedMilliseconds} status=$status '
          'error=${requestError?.runtimeType ?? '-'} inflight=$inflight '
          'coverRunning=${_personCoverPool.running} '
          'coverQueued=${_personCoverPool.queued}',
        );
      }
    }
  }

  String _requestCategory(String method, String path) {
    if (path == '/api/status') return 'status';
    if (path == '/api/upload') return 'upload';
    if (path.startsWith('/api/person/') && path.endsWith('/cover')) {
      return 'person_cover';
    }
    if (path.contains('/thumb')) return 'thumb';
    if (path.contains('/raw')) return 'raw';
    if (path.contains('/live')) return 'live';
    if (path.startsWith('/api/gallery')) return 'gallery';
    if (path == '/api/persons') return 'persons';
    return method == 'GET' ? 'other_get' : 'other_write';
  }

  Future<void> _userRoutes(
    HttpRequest req,
    Map user,
    String path,
    String m,
  ) async {
    final segs = path.split('/');
    // /api/user/{uid} or /assets or /avatar
    if (segs.length < 4) return _err(req, 404, 'Not Found');
    final uid = int.tryParse(segs[3]);
    if (uid == null) return _err(req, 404, 'Not Found');
    if (segs.length == 4 && m == 'GET') return _userProfile(req, uid);
    if (segs.length == 5 && segs[4] == 'assets' && m == 'GET') {
      final owner = await db.userById(uid);
      if (owner == null) return _err(req, 404, '没有这个人');
      return _ownAssets(req, owner, user);
    }
    if (segs.length == 5 && segs[4] == 'avatar' && m == 'GET') {
      return _sendAvatar(req, uid);
    }
    return _err(req, 404, 'Not Found');
  }

  Future<void> _assetRoutes(
    HttpRequest req,
    Map user,
    String path,
    String m,
  ) async {
    final segs = path.split('/');
    if (segs.length < 4) return _err(req, 404, 'Not Found');
    final id = int.tryParse(segs[3]);
    if (id == null) return _err(req, 404, 'Not Found');
    if (m == 'DELETE' && segs.length == 4) return _delete(req, user, id);
    if (segs.length < 5) return _err(req, 404, 'Not Found');
    final tail = segs[4];
    if (m == 'GET' && tail == 'thumb') return _thumb(req, id);
    if (m == 'GET' && tail == 'report-preview') {
      return _reportPreview(req, id);
    }
    if (m == 'GET' && tail == 'face' && segs.length >= 6) {
      final fid = int.tryParse(segs[5]);
      if (fid == null) return _err(req, 404, 'Not Found');
      return _faceCrop(req, id, fid);
    }
    if (m == 'GET' && tail == 'raw') return _raw(req, id);
    if (m == 'GET' && tail == 'live') return _live(req, id);
    if (m == 'GET' && tail == 'detail') return _detail(req, user, id);
    if (m == 'GET' && tail == 'comments') return _listComments(req, user, id);
    if (m == 'POST' && tail == 'comments') return _addComment(req, user, id);
    if (m == 'DELETE' && segs.length == 4) return _delete(req, user, id);
    if (m == 'DELETE' && segs.length == 5 && tail.isEmpty) {
      return _delete(req, user, id);
    }
    if (m == 'DELETE') return _delete(req, user, id);
    return _err(req, 404, 'Not Found');
  }

  bool _isPublicMedia(String path) {
    return RegExp(r'^/api/asset/\d+/(thumb|report-preview|raw|live|face/\d+)$')
            .hasMatch(path) ||
        RegExp(r'^/api/person/\d+/cover$').hasMatch(path) ||
        RegExp(r'^/api/user/\d+/avatar$').hasMatch(path);
  }

  Future<Map?> _auth(HttpRequest req) async {
    var token = req.headers.value('x-token') ?? '';
    if (token.isEmpty) {
      final c = req.headers.value('cookie') ?? '';
      final m = RegExp(r'tt_token=([^;]+)').firstMatch(c);
      token = m?.group(1) ?? '';
    }
    if (token.isEmpty) return null;
    return db.userByToken(token);
  }

  Future<void> _status(HttpRequest req) async {
    await _json(req, {
      'service': 'tuantu',
      'protocol': 1,
      'live_pair': 1,
      if (boxId.isNotEmpty) 'box_id': boxId,
      // 能力标记：旧客户端可据此提示升级盒子。
      'report': 1,
      'report_story': 1,
      'report_preview': 1,
      'recommend': 1,
      'total': _cachedTotal,
      'pending': FaceEngine.I.pending,
      'persons': _cachedPersons,
      'faces_ready': FaceEngine.I.ready,
      // 全部来自内存，用于故障现场判断请求卡在 HTTP 还是封面队列。
      'diagnostics': {
        'inflight': Map<String, int>.from(_inflightByCategory),
        'cover_running': _personCoverPool.running,
        'cover_queued': _personCoverPool.queued,
        'cover_jobs': _coverJobs.length,
        'image_running': _imageWorkPool.running,
        'image_queued': _imageWorkPool.queued,
        'report_queued': _reportPool.queued,
        'story_running': _storyPool.running,
        'story_queued': _storyPool.queued,
      },
    });
    // 发现接口绝不能等数据库。先响应，再在后台刷新展示用计数。
    if (_statusRefreshClock.elapsedMilliseconds >= _nextStatusRefreshMs) {
      _nextStatusRefreshMs = _statusRefreshClock.elapsedMilliseconds + 5000;
      unawaited(refreshStatusCache());
    }
  }

  Future<void> refreshStatusCache() async {
    if (_refreshingStatus) return;
    _refreshingStatus = true;
    try {
      _cachedTotal = firstInt(await db.q('SELECT COUNT(*) c FROM assets')) ?? 0;
      _cachedPersons =
          firstInt(await db.q('SELECT COUNT(*) c FROM persons')) ?? 0;
    } catch (_) {
      // 数据库繁忙时保留旧值，不能影响连接探测。
    } finally {
      _refreshingStatus = false;
    }
  }

  Future<void> _join(HttpRequest req) async {
    final body = await _readJson(req);
    final name = ((body['name'] ?? '') as String).trim();
    if (name.isEmpty) return _err(req, 400, '先给自己起个名字');
    final n = name.length > 20 ? name.substring(0, 20) : name;
    final deviceId = (body['device_id'] ?? '').toString().trim();
    final safeDeviceId = deviceId.length > 200
        ? deviceId.substring(0, 200)
        : deviceId;
    final token = deviceId.isEmpty
        ? await db.txn((tx) => tx.ensureUser(n))
        : await db.txn((tx) => tx.ensureDeviceUser(safeDeviceId, n));
    final user = await db.userByToken(token);
    await _json(req, {
      'ok': true,
      'name': (user?['name'] ?? n).toString(),
      'token': token,
      if (boxId.isNotEmpty) 'box_id': boxId,
    });
  }

  Future<void> _me(HttpRequest req, Map user) async {
    final uid = user['id'] as int;
    final uploaded =
        firstInt(
          await db.q('SELECT COUNT(*) c FROM assets WHERE uploader_id=?', [
            uid,
          ]),
        ) ??
        0;
    final last = await db.qOne(
      'SELECT MAX(created_at) t FROM assets WHERE uploader_id=?',
      [uid],
    );
    final claimed = [
      for (final r in await db.q(
        'SELECT person_id FROM person_claims WHERE user_id=?',
        [uid],
      ))
        r['person_id'],
    ];
    await _json(req, {
      'id': uid,
      'name': user['name'],
      'uploaded': uploaded,
      'kept': 0,
      'claimed': claimed,
      'faces_ready': FaceEngine.I.ready,
      'last_upload': last?['t'],
      'avatar': _avatarUrl(user),
    });
  }

  Future<void> _users(HttpRequest req) async {
    final rows = await db.q(
      'SELECT id, name FROM users ORDER BY created_at, id',
    );
    await _json(req, {
      'items': [
        for (final row in rows) {'id': row['id'], 'name': row['name']},
      ],
    });
  }

  Future<void> _profile(HttpRequest req, Map user) async {
    final body = await _readJson(req);
    final name = ((body['name'] ?? '') as String).trim();
    if (name.isEmpty) return _err(req, 400, '名字不能为空');
    if (name != user['name']) {
      await db.run('UPDATE users SET name=? WHERE id=?', [name, user['id']]);
    }
    await _json(req, {'ok': true, 'name': name, 'id': user['id']});
  }

  Future<void> _avatar(HttpRequest req, Map user) async {
    final parts = await _multipart(req);
    final f = parts.cast<_Part?>().firstWhere(
      (p) => p!.name == 'file' && p.bytes != null,
      orElse: () => null,
    );
    if (f == null || f.bytes == null || f.bytes!.isEmpty) {
      return _err(req, 400, '空文件');
    }
    final jpeg = await _imageWorkPool.run(
      () => encodeAvatarJpegOffload(f.bytes!),
      priority: true,
    );
    if (jpeg == null) return _err(req, 400, '不支持的图片，请换一张 JPG / PNG');
    final uid = user['id'] as int;
    await avatars.create(recursive: true);
    await File(p.join(avatars.path, '$uid.jpg')).writeAsBytes(jpeg);
    final stamp = BoxDb.now().round();
    _userCache.remove(uid);
    await db.run('UPDATE users SET avatar=? WHERE id=?', [stamp, uid]);
    await _json(req, {'ok': true, 'avatar': '/api/user/$uid/avatar?v=$stamp'});
  }

  Future<void> _uploadIndex(HttpRequest req, Map user) async {
    final rows = await db.q(
      'SELECT orig_name, taken_at, created_at FROM assets WHERE uploader_id=?',
      [user['id']],
    );
    final items = <Map>[];
    for (final r in rows) {
      final day = _epochDay(r['taken_at'] ?? r['created_at']);
      if (day == null) continue;
      items.add({'name': r['orig_name'], 'day': day});
    }
    await _json(req, {'items': items});
  }

  Future<void> _ownAssets(HttpRequest req, Map owner, Map viewer) async {
    final sort = req.uri.queryParameters['sort'] ?? 'time';
    final offset = int.tryParse(req.uri.queryParameters['offset'] ?? '0') ?? 0;
    final limit = (int.tryParse(req.uri.queryParameters['limit'] ?? '90') ?? 90)
        .clamp(1, 200);
    String order = 'a.created_at DESC, a.id DESC';
    if (sort == 'likes') {
      order = '(SELECT COUNT(*) FROM likes l WHERE l.asset_id=a.id) DESC, a.id DESC';
    } else if (sort == 'comments') {
      order = '(SELECT COUNT(*) FROM comments c WHERE c.asset_id=a.id) DESC, a.id DESC';
    }
    final rows = await db.q(
      'SELECT a.* FROM published_assets a WHERE a.uploader_id=? ORDER BY $order LIMIT ? OFFSET ?',
      [owner['id'], limit, offset],
    );
    final items = await _cards(rows, viewer);
    await _json(req, {
      'items': items,
      'offset': offset + items.length,
      'end': items.length < limit,
    });
  }

  Future<void> _gallery(HttpRequest req, Map user) async {
    final view = req.uri.queryParameters['view'] ?? 'all';
    if (view == 'uploaded') return _ownAssets(req, user, user);
    final limit = int.tryParse(req.uri.queryParameters['limit'] ?? '60') ?? 60;
    if (view == 'recommended') {
      final seed =
          int.tryParse(req.uri.queryParameters['seed'] ?? '') ??
          DateTime.now().microsecondsSinceEpoch;
      final exclude = <int>[];
      for (final part in (req.uri.queryParameters['exclude'] ?? '').split(
        ',',
      )) {
        final id = int.tryParse(part);
        if (id != null && id > 0 && !exclude.contains(id)) exclude.add(id);
        if (exclude.length >= 60) break;
      }
      final rows = await _recommendedRows(
        userId: user['id'] as int,
        limit: limit.clamp(1, 60).toInt(),
        seed: seed,
        exclude: exclude,
      );
      final items = await _cards(rows, user);
      await _json(req, {'items': items, 'cursor': null, 'cursor_id': null});
      return;
    }
    final cursor = double.tryParse(req.uri.queryParameters['cursor'] ?? '');
    final sort = req.uri.queryParameters['sort'] ?? 'time';
    var sql = 'SELECT a.* FROM published_assets a WHERE 1=1';
    final args = <Object?>[];
    if (view == 'liked') {
      sql += ' AND EXISTS(SELECT 1 FROM likes l WHERE l.asset_id=a.id AND l.user_id=?)';
      args.add(user['id']);
    } else if (view == 'images') {
      sql += " AND a.kind='image'";
    } else if (view == 'videos') {
      sql += " AND a.kind='video'";
    } else if (view == 'group') {
      sql += _groupShotFilter;
    } else if (view == 'mine' || view == 'mine_unseen') {
      sql += ''' AND EXISTS(SELECT 1 FROM faces f JOIN person_claims c
                            ON c.person_id=f.person_id
                            WHERE f.asset_id=a.id AND c.user_id=?)''';
      args.add(user['id']);
      if (view == 'mine_unseen') {
        sql += ' AND NOT EXISTS(SELECT 1 FROM views v WHERE v.asset_id=a.id AND v.user_id=?)';
        args.add(user['id']);
      }
    } else if (view == 'unseen') {
      sql += ' AND NOT EXISTS(SELECT 1 FROM views v WHERE v.asset_id=a.id AND v.user_id=?)';
      args.add(user['id']);
    } else if (view == 'hot') {
      sql += ''' AND (
        (SELECT COUNT(*) FROM likes l WHERE l.asset_id=a.id) >= 1
        OR (SELECT COUNT(*) FROM comments c WHERE c.asset_id=a.id) >= 1
      )''';
    } else if (view.startsWith('person:')) {
      final pid = int.tryParse(view.split(':').last) ?? -1;
      sql += ' AND EXISTS(SELECT 1 FROM faces f WHERE f.asset_id=a.id AND f.person_id=?)';
      args.add(pid);
    }
    if (view == 'hot') {
      final offset =
          int.tryParse(req.uri.queryParameters['offset'] ?? '0') ?? 0;
      sql += ''' ORDER BY (
        (SELECT COUNT(*) FROM likes l WHERE l.asset_id=a.id) +
        (SELECT COUNT(*) FROM comments c WHERE c.asset_id=a.id)
      ) DESC, a.id DESC LIMIT ? OFFSET ?''';
      args.add(limit);
      args.add(offset);
    } else {
      final byUpload = sort == 'upload';
      // 复合游标（时间, id）：连拍/导入的一批照片拍摄时间相同，
      // 只按「时间小于」翻页会跳掉同秒剩余的照片。新客户端带 cursor_id。
      final cursorId = int.tryParse(req.uri.queryParameters['cursor_id'] ?? '');
      if (cursor != null) {
        if (cursorId != null) {
          sql += byUpload
              ? ' AND (a.created_at < ? OR (a.created_at = ? AND a.id < ?))'
              : ' AND (COALESCE(a.taken_at, a.created_at) < ? '
                    'OR (COALESCE(a.taken_at, a.created_at) = ? AND a.id < ?))';
          args.addAll([cursor, cursor, cursorId]);
        } else {
          // 旧客户端：只有时间游标，行为保持原样
          sql += byUpload
              ? ' AND a.created_at < ?'
              : ' AND COALESCE(a.taken_at, a.created_at) < ?';
          args.add(cursor);
        }
      }
      sql += byUpload ? ' ORDER BY a.created_at DESC, a.id DESC LIMIT ?' : ' ORDER BY COALESCE(a.taken_at, a.created_at) DESC, a.id DESC LIMIT ?';
      args.add(limit);
    }
    final rows = await db.q(sql, args);
    final items = await _cards(rows, user);
    await _json(req, {
      'items': items,
      'cursor': rows.isEmpty
          ? null
          : (sort == 'upload'
                ? rows.last['created_at']
                : (rows.last['taken_at'] ?? rows.last['created_at'])),
      'cursor_id': rows.isEmpty ? null : rows.last['id'],
    });
  }

  Future<List<Map<String, Object?>>> _recommendedRows({
    required int userId,
    required int limit,
    required int seed,
    required List<int> exclude,
  }) async {
    final safeSeed = seed & 0x7fffffff;
    final factor = 1009 + (safeSeed % 997) * 2;
    final salt = safeSeed % 2147483647;
    final now = BoxDb.now();
    final candidateLimit = (limit * 6).clamp(60, 360).toInt();

    Future<List<Map<String, Object?>>> query(List<int> blocked) async {
      final placeholders = List.filled(blocked.length, '?').join(',');
      final exclusion = blocked.isEmpty
          ? ''
          : 'AND a.id NOT IN ($placeholders)';
      return db.q(
        '''
WITH signals AS (
  SELECT a.*,
    CASE WHEN NOT EXISTS(
      SELECT 1 FROM views v WHERE v.user_id=? AND v.asset_id=a.id
    ) THEN 40 ELSE 0 END AS unseen_bonus,
    CASE
      WHEN a.created_at >= ? THEN 18
      WHEN a.created_at >= ? THEN 10
      ELSE 0
    END AS recent_bonus,
    MIN((SELECT COUNT(*) FROM likes l WHERE l.asset_id=a.id) * 3, 18)
      AS like_bonus,
    MIN((SELECT COUNT(*) FROM comments c WHERE c.asset_id=a.id) * 5, 20)
      AS comment_bonus,
    CASE WHEN a.kind='image' THEN (
      SELECT COUNT(DISTINCT f.person_id)
      FROM faces f
      JOIN persons p ON p.id=f.person_id
      WHERE f.asset_id=a.id AND p.member_status=1
    ) ELSE 0 END AS member_count
  FROM published_assets a
  WHERE 1=1 $exclusion
), scored AS (
  SELECT signals.*,
    unseen_bonus + recent_bonus + like_bonus + comment_bonus +
    CASE
      WHEN member_count >= 4 THEN 72
      WHEN member_count = 3 THEN 48
      WHEN member_count = 2 THEN 24
      WHEN member_count = 1 THEN 8
      ELSE 0
    END + ABS((id * ? + ?) % 2147483647) % 25 AS recommend_score
  FROM signals
)
SELECT * FROM scored
ORDER BY recommend_score DESC, created_at DESC, id DESC
LIMIT ?
''',
        [
          userId,
          now - 86400,
          now - 7 * 86400,
          ...blocked,
          factor,
          salt,
          candidateLimit,
        ],
      );
    }

    final candidates = <Map<String, Object?>>[...await query(exclude)];
    var chosen = _diversifyRecommended(candidates, limit);
    if (chosen.length < limit && exclude.isNotEmpty) {
      final known = {for (final row in candidates) row['id']};
      for (final row in await query(const [])) {
        if (known.add(row['id'])) candidates.add(row);
      }
      chosen = _diversifyRecommended(candidates, limit);
    }
    return chosen;
  }

  List<Map<String, Object?>> _diversifyRecommended(
    List<Map<String, Object?>> candidates,
    int limit,
  ) {
    final remaining = [...candidates];
    final result = <Map<String, Object?>>[];
    final uploaderCounts = <int, int>{};
    final uploaderCap = (limit / 4).ceil().clamp(2, 6).toInt();
    int? lastUploader;
    while (remaining.isNotEmpty && result.length < limit) {
      var index = remaining.indexWhere((row) {
        final uid = (row['uploader_id'] as num).toInt();
        return (uploaderCounts[uid] ?? 0) < uploaderCap && uid != lastUploader;
      });
      index = index >= 0
          ? index
          : remaining.indexWhere((row) {
              final uid = (row['uploader_id'] as num).toInt();
              return (uploaderCounts[uid] ?? 0) < uploaderCap;
            });
      if (index < 0) index = 0;
      final row = remaining.removeAt(index);
      final uid = (row['uploader_id'] as num).toInt();
      result.add(row);
      uploaderCounts[uid] = (uploaderCounts[uid] ?? 0) + 1;
      lastUploader = uid;
    }
    return result;
  }

  Future<void> _galleryHome(HttpRequest req, Map user) async {
    Future<Map<String, Object?>> pack(String extra, List<Object?> args) async {
      final n =
          firstInt(
            await db.q(
              'SELECT COUNT(*) c FROM published_assets a WHERE 1=1 $extra',
              args,
            ),
          ) ??
          0;
      final last = await db.qOne(
        'SELECT a.id, a.kind FROM published_assets a WHERE 1=1 $extra ORDER BY COALESCE(a.taken_at, a.created_at) DESC, a.id DESC LIMIT 1',
        args,
      );
      return {
        'count': n,
        'cover': last == null ? null : '/api/asset/${last['id']}/thumb',
        'kind': last?['kind'],
      };
    }

    final recent = await pack('', const []);
    final liked = await pack(
      'AND EXISTS(SELECT 1 FROM likes l WHERE l.asset_id=a.id AND l.user_id=?)',
      [user['id']],
    );
    final images = await pack("AND a.kind='image'", const []);
    final videos = await pack("AND a.kind='video'", const []);
    final group = await pack(_groupShotFilter, const []);
    final people = await db.q('''
SELECT u.id, u.name, u.avatar, cnt.n, last.id cover_id
FROM users u
JOIN (
  SELECT uploader_id, COUNT(*) n, MAX(created_at) t
  FROM published_assets GROUP BY uploader_id
) cnt ON cnt.uploader_id = u.id
LEFT JOIN published_assets last ON last.id = (
  SELECT a2.id FROM published_assets a2
  WHERE a2.uploader_id = u.id
  ORDER BY a2.created_at DESC, a2.id DESC LIMIT 1
)
WHERE cnt.n > 0
ORDER BY cnt.t DESC''');
    final uploaders = [
      for (final r in people)
        {
          'id': r['id'],
          'name': r['name'],
          'count': r['n'],
          'avatar': _avatarUrl(r),
          'cover': r['cover_id'] == null
              ? null
              : '/api/asset/${r['cover_id']}/thumb',
        },
    ];
    await _json(req, {
      'recent': recent,
      'liked': liked,
      'images': images,
      'videos': videos,
      'group': group,
      'uploaders': uploaders,
    });
  }

  bool _isUploadExt(String ext) =>
      _imageExts.contains(ext) ||
      _videoExts.contains(ext) ||
      _audioExts.contains(ext);

  String _uploadKind(String ext) => _videoExts.contains(ext)
      ? 'video'
      : _audioExts.contains(ext)
      ? 'audio'
      : 'image';

  /// 并发上传同内容时的「查重 + 插入」原子段锁，按 sha 分 key。
  final _shaMutex = KeyedMutex();

  Future<void> _upload(HttpRequest req, Map user) async {
    final boundary = req.headers.contentType?.parameters['boundary'];
    if (boundary == null) {
      await _json(req, {
        'accepted': <Map>[],
        'duplicates': <Map>[],
        'rejected': <String>[],
      });
      return;
    }
    var uploader = user;
    final importUserRaw = req.headers.value('x-tuantu-import-user');
    if (importUserRaw != null && importUserRaw.isNotEmpty) {
      final local = req.connectionInfo?.remoteAddress.isLoopback == true;
      if (!local) return _err(req, 403, '只有盒子本机可以替团员导入作品');
      final importUserId = int.tryParse(importUserRaw);
      final found = importUserId == null
          ? null
          : await db.userById(importUserId);
      if (found == null) return _err(req, 400, '所选团员已经不存在');
      uploader = found;
    }
    // 流式写盘：边收 chunk 边解析 multipart，单文件内存 O(chunk) 而不是 O(文件大小)。
    // 两阶段：整个请求体（含 preview/meta/live 附件）收完才查重入库，
    // 断在半路时库和盘上都不会留半成品，客户端整包重发即可补齐。
    final pendingIds = <int>[];
    try {
      final ingested = await ingestUploadMultipart(
        body: req,
        boundary: boundary,
        orig: orig,
        userId: uploader['id'] as int,
        isAllowed: _isUploadExt,
        kindOf: _uploadKind,
        // 去重只能在当前作者内生效。不同团员上传同一原文件是
        // 两件独立作品，也不应被同一把锁互相阻塞。
        dedupeLock: <T>(String key, Future<T> Function() fn) =>
            _shaMutex.run<T>('${uploader['id']}:$key', fn),
        trackFile: markLiveFile,
        untrackFile: unmarkLiveFile,
        findDup: (file, takenAt) async {
          final dayStart =
              (takenAt / Duration.secondsPerDay).floor() *
              Duration.secondsPerDay;
          final row = await db.qOne(
            'SELECT id, uploader_id FROM assets '
            'WHERE uploader_id=? AND orig_name=? '
            'AND COALESCE(taken_at, created_at)>=? '
            'AND COALESCE(taken_at, created_at)<? LIMIT 1',
            [
              uploader['id'],
              file.filename,
              dayStart,
              dayStart + Duration.secondsPerDay,
            ],
          );
          if (row == null) return null;
          return DupRecord(
            id: (row['id'] as num).toInt(),
            uploaderId: (row['uploader_id'] as num?)?.toInt(),
          );
        },
        insertAsset: (f) async {
          final stamp = BoxDb.now();
          return db.txn((tx) async {
            final id = await tx.exec(
              'INSERT INTO assets(uploader_id, sha256, orig_name, ext, kind, size, taken_at, created_at, analyzed, time_source) '
              "VALUES(?,?,?,?,?,?,?,?,0,'upload')",
              [
                uploader['id'],
                f.sha256,
                f.filename,
                f.ext,
                f.kind,
                f.size,
                f.takenAt ?? stamp,
                stamp,
              ],
            );
            await tx.run('INSERT INTO pending_uploads(asset_id) VALUES(?)', [
              id,
            ]);
            pendingIds.add(id);
            return id;
          });
        },
        deleteAsset: (id) async {
          await db.run('DELETE FROM assets WHERE id=?', [id]);
        },
      );

      await debugBeforeUploadPreparation?.call();
      for (final a in ingested.accepted) {
        if (_preview.contains(a.ext)) {
          try {
            final thumb = await _imageWorkPool.run(() => _uploadThumb(a.file));
            if (thumb != null) {
              await thumbs.create(recursive: true);
              final thumbFile = File(p.join(thumbs.path, '${a.id}.jpg'));
              markLiveFile(thumbFile.path);
              try {
                await thumbFile.writeAsBytes(thumb['jpeg'] as Uint8List);
              } finally {
                unmarkLiveFile(thumbFile.path);
              }
              final taken = (thumb['taken'] as num?)?.toDouble();
              await db.run(
                "UPDATE assets SET taken_at=COALESCE(?, taken_at, created_at), has_thumb=1, "
                "width=?, height=?, time_source=CASE WHEN ? IS NULL "
                "THEN 'upload' ELSE 'exif' END WHERE id=?",
                [taken, thumb['width'], thumb['height'], taken, a.id],
              );
            }
            await _recoverLiveSidecar(a.id, a.ext);
          } catch (_) {}
        } else if (a.kind == 'video') {
          try {
            unawaited(_ensureVideoCover(a.id, a.ext));
          } catch (_) {}
        }
      }

      // 客户端附带的兼容预览（iOS HEIC / 视频首帧）：盒子解不了原片时，
      // 用预览生成缩略图。原件原样保留，预览用完即删。
      final previewTmp = ingested.previewFile;
      var previewUsed = false;
      if (previewTmp != null) {
        var bytes = Uint8List(0);
        try {
          bytes = await previewTmp.readAsBytes();
        } catch (_) {}
        if (bytes.isNotEmpty) {
          // 新收的 accepted：第一个解不了原片的格式用预览出图
          for (final a in ingested.accepted) {
            if (_preview.contains(a.ext)) continue; // 已有自己的 EXIF 管线
            if (previewUsed) break; // 单文件上传对应单预览，只给第一个匹配的
            previewUsed = await _applyPreviewThumb(a.id, bytes) || previewUsed;
          }
        }
      }

      // 客户端提供的拍摄时间只补没有 EXIF 的文件；相机卡上的 JPEG 若没有
      // 拍摄时间，也可用文件墙钟时间兜底，避免全部错归到导入日。
      for (final a in ingested.accepted) {
        final m = ingested.meta[a.filename];
        if (m is! Map) continue;
        final pts = (m['live_pts'] as num?)?.toInt();
        if (pts != null && pts >= 0) {
          try {
            await db.run('UPDATE assets SET live_pts=? WHERE id=?', [
              pts,
              a.id,
            ]);
          } catch (_) {}
        }
        final t = (m['taken_at'] as num?)?.toDouble();
        if (t == null || t <= 0) continue;
        try {
          await db.run(
            "UPDATE assets SET taken_at=?, time_source='meta' "
            "WHERE id=? AND (time_source='upload' OR taken_at IS NULL)",
            [t, a.id],
          );
        } catch (_) {}
      }

      // 同作者重复上传的补全：上次断在附件前，这次把缺的预览/拍摄时间/实况补上。
      // 只动自己的旧作品，且只补缺失项，绝不覆盖已有数据和别人的作品。
      final repairedOut = <Map<String, Object?>>[];
      int? liveTargetOverride;
      for (final r in ingested.repaired) {
        final row = await db.qOne(
          'SELECT id, uploader_id, ext, has_thumb, has_live, analyzed, '
          'taken_at, created_at FROM assets WHERE id=?',
          [r.id],
        );
        if (row == null || row['uploader_id'] != uploader['id']) continue;
        var applied = false;
        final hasThumb = (row['has_thumb'] as num?)?.toInt() == 1;
        if (!hasThumb &&
            previewTmp != null &&
            !previewUsed &&
            !_preview.contains(row['ext'] ?? '')) {
          var bytes = Uint8List(0);
          try {
            bytes = await previewTmp.readAsBytes();
          } catch (_) {}
          if (bytes.isNotEmpty) {
            final ok = await _applyPreviewThumb(r.id, bytes);
            previewUsed = previewUsed || ok;
            applied = applied || ok;
          }
        }
        final m = ingested.meta[r.filename];
        if (m is Map) {
          final t = (m['taken_at'] as num?)?.toDouble();
          if (t != null && t > 0) {
            try {
              final n = await db.run(
                "UPDATE assets SET taken_at=?, time_source='meta' "
                'WHERE id=? AND (taken_at IS NULL OR taken_at=created_at)',
                [t, r.id],
              );
              applied = applied || n > 0;
            } catch (_) {}
          }
        }
        if (!liveVideoFileReady(File(p.join(orig.path, '${r.id}.live.mp4'))) &&
            ingested.liveFile != null &&
            liveVideoFileReady(ingested.liveFile!)) {
          liveTargetOverride = r.id; // 标记待补，文件统一在下面搬运
          applied = true;
        }
        if (applied) {
          if ((row['analyzed'] as num?)?.toInt() == 0 &&
              (r.kind == 'image' || r.kind == 'video')) {
            FaceEngine.I.enqueue(r.id);
          }
          repairedOut.add({'id': r.id, 'name': r.filename});
        }
      }

      final liveTmp = ingested.liveFile;
      if (liveTmp != null) {
        final id = ingested.accepted.isNotEmpty
            ? ingested.accepted.last.id
            : liveTargetOverride;
        if (id != null && liveVideoFileReady(liveTmp)) {
          final dest = File(p.join(orig.path, '$id.live.mp4'));
          markLiveFile(dest.path);
          try {
            await liveTmp.rename(dest.path);
          } on FileSystemException {
            await liveTmp.copy(dest.path);
            try {
              await liveTmp.delete();
            } catch (_) {}
          } finally {
            unmarkLiveFile(dest.path);
            unmarkLiveFile(liveTmp.path);
          }
          await db.run('UPDATE assets SET has_live=1 WHERE id=?', [id]);
        } else {
          try {
            await liveTmp.delete();
          } catch (_) {}
          unmarkLiveFile(liveTmp.path);
        }
      }
      if (previewTmp != null) {
        try {
          await previewTmp.delete();
        } catch (_) {}
        unmarkLiveFile(previewTmp.path);
      }

      await _publishUploads(pendingIds);
      for (final a in ingested.accepted) {
        if (a.kind == 'image' || a.kind == 'video') FaceEngine.I.enqueue(a.id);
      }
      await _json(req, {
        'accepted': [
          for (final a in ingested.accepted)
            {
              'id': a.id,
              'name': a.filename,
              'live_ready': liveVideoFileReady(
                File(p.join(orig.path, '${a.id}.live.mp4')),
              ),
            },
        ],
        // 同作者的重复上传且补全了缺失附件（旧客户端会忽略这个新字段）
        'repaired': [
          for (final r in repairedOut)
            {
              ...r,
              'live_ready': liveVideoFileReady(
                File(p.join(orig.path, '${r['id']}.live.mp4')),
              ),
            },
        ],
        'duplicates': [
          ...ingested.duplicates,
          for (final r in ingested.repaired)
            if (!repairedOut.any((e) => e['id'] == r.id))
              {'name': r.filename, 'from': 'same'},
        ],
        'rejected': ingested.rejected,
      });
      for (final a in ingested.accepted) {
        if (a.kind != 'image') continue;
        if (liveVideoFileReady(File(p.join(orig.path, '${a.id}.live.mp4')))) {
          continue;
        }
        unawaited(_recoverLiveSidecar(a.id, a.ext));
      }
    } finally {
      // A failed attachment must not leave a successfully received original
      // permanently invisible. Ingest itself rolls back missing originals.
      await _publishUploads(pendingIds);
    }
  }

  Future<void> _publishUploads(List<int> ids) async {
    if (ids.isEmpty) return;
    await db.run(
      'DELETE FROM pending_uploads WHERE asset_id IN '
      '(${ids.map((_) => '?').join(',')})',
      ids,
    );
    ids.clear();
  }

  Future<Map<String, dynamic>?> _uploadThumb(File file) async {
    // The fast metadata reader is JPEG-specific. Preserve the existing EXIF
    // handling for PNG/WebP and other formats through the isolate fallback.
    final ext = p.extension(file.path).toLowerCase();
    if (Platform.isAndroid && (ext == '.jpg' || ext == '.jpeg')) {
      try {
        final result = await const MethodChannel('dev.tuantu/box')
            .invokeMapMethod<String, dynamic>('imageThumb', {'src': file.path});
        if (result != null &&
            result['jpeg'] is Uint8List &&
            (result['jpeg'] as Uint8List).isNotEmpty &&
            (result['width'] as num? ?? 0) > 0 &&
            (result['height'] as num? ?? 0) > 0) {
          result['taken'] = await readUploadTakenAt(file.path);
          return result;
        }
      } catch (_) {
        // Old platform bridge and unsupported formats keep the proven fallback.
      }
    }
    return encodeThumbJpegOffload(await file.readAsBytes());
  }

  /// 用客户端预览字节给 [id] 生成缩略图。返回是否真的写了。
  Future<bool> _applyPreviewThumb(int id, Uint8List bytes) async {
    final dest = File(p.join(thumbs.path, '$id.jpg'));
    markLiveFile(dest.path);
    try {
      final thumb = await _imageWorkPool.run(
        () => encodeThumbJpegOffload(bytes),
      );
      if (thumb == null) return false;
      await thumbs.create(recursive: true);
      await dest.writeAsBytes(thumb['jpeg'] as Uint8List);
      await db.run(
        'UPDATE assets SET has_thumb=1, width=?, height=? WHERE id=?',
        [thumb['width'], thumb['height'], id],
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      unmarkLiveFile(dest.path);
    }
  }

  Future<void> _seen(HttpRequest req, Map user) async {
    final body = await _readJson(req);
    final aid = body['asset_id'];
    if (aid == null) return _err(req, 400, '缺 asset_id');
    try {
      await db.exec(
        'INSERT OR IGNORE INTO views(user_id, asset_id, created_at) '
        'SELECT ?, id, ? FROM assets WHERE id=?',
        [user['id'], BoxDb.now(), aid],
      );
    } catch (_) {}
    await _json(req, {'ok': true});
  }

  Future<void> _like(HttpRequest req, Map user) async {
    final body = await _readJson(req);
    final aid = body['asset_id'];
    if (aid == null) return _err(req, 400, '缺 asset_id');
    final wanted = body['liked'];
    final result = await db.txn<Map<String, dynamic>?>((tx) async {
      final asset = await tx.qOne('SELECT 1 x FROM assets WHERE id=?', [aid]);
      if (asset == null) return null;
      final has = await tx.qOne(
        'SELECT 1 x FROM likes WHERE asset_id=? AND user_id=?',
        [aid, user['id']],
      );
      var liked = has != null;
      if (wanted == true || wanted == 1) {
        if (has == null) {
          await tx.exec(
            'INSERT OR IGNORE INTO likes(asset_id, user_id, created_at) VALUES(?,?,?)',
            [aid, user['id'], BoxDb.now()],
          );
        }
        liked = true;
      } else if (wanted == false || wanted == 0) {
        if (has != null) {
          await tx.run('DELETE FROM likes WHERE asset_id=? AND user_id=?', [
            aid,
            user['id'],
          ]);
        }
        liked = false;
      } else if (has != null) {
        await tx.run('DELETE FROM likes WHERE asset_id=? AND user_id=?', [
          aid,
          user['id'],
        ]);
        liked = false;
      } else {
        await tx.exec(
          'INSERT INTO likes(asset_id, user_id, created_at) VALUES(?,?,?)',
          [aid, user['id'], BoxDb.now()],
        );
        liked = true;
      }
      final n =
          firstInt(
            await tx.q('SELECT COUNT(*) c FROM likes WHERE asset_id=?', [aid]),
          ) ??
          0;
      return {'liked': liked, 'likes': n};
    });
    if (result == null) return _err(req, 404, '照片不存在');
    await _json(req, result);
  }

  Future<void> _listComments(HttpRequest req, Map user, int id) async {
    final rows = await db.q(
      '''SELECT c.id, c.body, c.created_at, c.user_id, u.name, u.avatar
         FROM comments c JOIN users u ON u.id=c.user_id
         WHERE c.asset_id=? ORDER BY c.created_at ASC, c.id ASC''',
      [id],
    );
    await _json(req, {
      'comments': [
        for (final r in rows)
          {
            'id': r['id'],
            'body': r['body'],
            'name': r['name'],
            'created_at': r['created_at'],
            'mine': r['user_id'] == user['id'],
            'avatar': _avatarUrl({'id': r['user_id'], 'avatar': r['avatar']}),
          },
      ],
    });
  }

  Future<void> _addComment(HttpRequest req, Map user, int id) async {
    final body = await _readJson(req);
    final text = ((body['body'] ?? '') as String).trim();
    if (text.isEmpty) return _err(req, 400, '写点什么再发');
    final now = BoxDb.now();
    final cid = await db.txn<int?>((tx) async {
      if (await tx.qOne('SELECT 1 x FROM assets WHERE id=?', [id]) == null) {
        return null;
      }
      return tx.exec(
        'INSERT INTO comments(asset_id, user_id, body, created_at) VALUES(?,?,?,?)',
        [id, user['id'], text, now],
      );
    });
    if (cid == null) return _err(req, 404, '照片不存在');
    await _json(req, {
      'id': cid,
      'body': text,
      'name': user['name'],
      'created_at': now,
      'mine': true,
      'avatar': _avatarUrl(user),
    });
  }

  Future<void> _detail(HttpRequest req, Map user, int id) async {
    final a = await db.qOne('SELECT * FROM assets WHERE id=?', [id]);
    if (a == null) return _err(req, 404, '照片不存在');
    final card = await _card(a, user);
    final likes = await db.q(
      'SELECT u.name FROM likes l JOIN users u ON u.id=l.user_id WHERE l.asset_id=? ORDER BY l.created_at',
      [id],
    );
    card['liked_by'] = [for (final r in likes) r['name']];
    card['size'] = a['size'];
    card['faces'] = [];
    await _json(req, card);
  }

  Future<void> _delete(HttpRequest req, Map user, int id) async {
    // 权限检查、关联快照和全部删除必须处于同一个写事务。
    // 否则点赞/评论可以在“清关联”与“删资产”之间插入幽灵记录。
    final outcome = await db.txn((tx) async {
      final asset = await tx.qOne('SELECT * FROM assets WHERE id=?', [id]);
      if (asset == null) {
        return (
          status: 404,
          asset: <String, Object?>{},
          faceIds: <int>[],
          personIds: <int>{},
        );
      }
      if (asset['uploader_id'] != user['id']) {
        return (
          status: 403,
          asset: asset,
          faceIds: <int>[],
          personIds: <int>{},
        );
      }
      final faceRows = await tx.q(
        'SELECT id, person_id FROM faces WHERE asset_id=?',
        [id],
      );
      final faceIds = [for (final f in faceRows) (f['id'] as num).toInt()];
      final personIds = <int>{
        for (final f in faceRows)
          if (f['person_id'] != null) (f['person_id'] as num).toInt(),
      };
      if (faceIds.isNotEmpty) {
        final ph = List.filled(faceIds.length, '?').join(',');
        await tx.run(
          'UPDATE persons SET cover_face_id=NULL WHERE cover_face_id IN ($ph)',
          faceIds,
        );
      }
      await tx.run('DELETE FROM likes WHERE asset_id=?', [id]);
      await tx.run('DELETE FROM comments WHERE asset_id=?', [id]);
      await tx.run('DELETE FROM views WHERE asset_id=?', [id]);
      await tx.run('DELETE FROM decisions WHERE asset_id=?', [id]);
      await tx.run('DELETE FROM faces WHERE asset_id=?', [id]);
      await tx.run('DELETE FROM assets WHERE id=?', [id]);
      return (
        status: 200,
        asset: asset,
        faceIds: faceIds,
        personIds: personIds,
      );
    });
    if (outcome.status == 404) return _err(req, 404, '照片不存在');
    if (outcome.status == 403) return _err(req, 403, '只能删除自己上传的');
    final a = outcome.asset;
    final faceIds = outcome.faceIds;
    final personIds = outcome.personIds;
    // 人物/认领关系不动：人物可能还有别的照片的脸。人物统计按 faces 实时算，
    // faces 删了统计自然正确。
    final ext = a['ext'];
    final doomed = <File>[
      File(p.join(orig.path, '$id.$ext')),
      File(p.join(orig.path, '$id.live.mp4')),
      File(p.join(thumbs.path, '$id.jpg')),
      File(p.join(thumbs.path, '$id.webp')),
      File(p.join(thumbs.path, 'report_$id.jpg')),
      for (final fid in faceIds) File(p.join(thumbs.path, 'face_$fid.jpg')),
    ];
    // 人物封面可能正是用这张图裁的：删缓存 + 清进行中的任务，下次按剩余脸重新生成
    _invalidatePersonCovers(personIds);
    // 人物封面必须在响应删除前同步失效。若放到后台重试，
    // 新请求刚重建的封面可能又被旧删除任务删掉。
    for (final pid in personIds) {
      try {
        final cover = _personCoverFile(pid);
        if (cover.existsSync()) cover.deleteSync();
      } catch (_) {}
    }
    _coverJobs.remove('video:$id');
    unawaited(_deleteFilesWithRetry(doomed));
    await _json(req, {'ok': true});
  }

  /// 文件删除带重试：可能正被并发的读请求占用，立即删会失败。
  /// 重试后仍失败的留给下次开盒子的孤儿清扫（sweepOrphanFiles）兜底，
  /// 不能只吞异常了事。
  Future<void> _deleteFilesWithRetry(List<File> files) async {
    var remaining = <File>[...files.where((f) => f.existsSync())];
    for (var attempt = 0; attempt < 4 && remaining.isNotEmpty; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
      final next = <File>[];
      for (final f in remaining) {
        try {
          await f.delete();
        } catch (_) {
          next.add(f);
        }
      }
      remaining = next;
    }
  }

  /// 开盒时清扫孤儿文件：数据库里已不存在的作品/脸/人物对应的
  /// orig、thumbs 文件，以及上次中断上传留下的 `_tmp_*`。
  /// 这是删除时文件清理失败的最终兜底。
  ///
  /// 不能用启动瞬间的资产名单直接删：清扫期间新上传的原片、缩略图、
  /// 正在写的 `_tmp_` 都不在那份快照里。删之前必须再确认无主且不在途。
  Future<int> sweepOrphanFiles() async {
    var removed = 0;
    try {
      final started = DateTime.now();
      var assetIds = {
        for (final r in await db.q('SELECT id FROM assets'))
          (r['id'] as num).toInt(),
      };
      var faceIds = {
        for (final r in await db.q('SELECT id FROM faces'))
          (r['id'] as num).toInt(),
      };
      var personIds = {
        for (final r in await db.q('SELECT id FROM persons'))
          (r['id'] as num).toInt(),
      };
      final pause = debugAfterOrphanSnapshot;
      if (pause != null) await pause();

      bool tooNew(File f) {
        try {
          return f.lastModifiedSync().isAfter(started);
        } catch (_) {
          return true;
        }
      }

      Future<bool> stillAsset(int id) async {
        if (assetIds.contains(id)) return true;
        final row = await db.qOne('SELECT id FROM assets WHERE id=?', [id]);
        if (row == null) return false;
        assetIds.add(id);
        return true;
      }

      Future<bool> stillFace(int id) async {
        if (faceIds.contains(id)) return true;
        final row = await db.qOne('SELECT id FROM faces WHERE id=?', [id]);
        if (row == null) return false;
        faceIds.add(id);
        return true;
      }

      Future<bool> stillPerson(int id) async {
        if (personIds.contains(id)) return true;
        final row = await db.qOne('SELECT id FROM persons WHERE id=?', [id]);
        if (row == null) return false;
        personIds.add(id);
        return true;
      }

      Future<void> deleteIfOrphan(
        File e, {
        required Future<bool> Function() owned,
      }) async {
        if (_isLivePath(e.path) || tooNew(e)) return;
        if (await owned()) return;
        if (_isLivePath(e.path) || tooNew(e)) return;
        try {
          await e.delete();
          removed++;
        } catch (_) {}
      }

      Future<void> sweep(Directory dir) async {
        if (!await dir.exists()) return;
        await for (final e in dir.list()) {
          if (e is! File) continue;
          final name = p.basename(e.path);
          if (name.startsWith('_tmp_')) {
            await deleteIfOrphan(e, owned: () async => false);
            continue;
          }
          final id = int.tryParse(
            RegExp(r'^(\d+)\.').firstMatch(name)?.group(1) ?? '',
          );
          if (id == null) continue;
          await deleteIfOrphan(e, owned: () => stillAsset(id));
        }
      }

      await sweep(orig);
      await sweep(thumbs);
      if (await thumbs.exists()) {
        await for (final e in thumbs.list()) {
          if (e is! File) continue;
          final name = p.basename(e.path);
          final fm = RegExp(r'^face_(\d+)\.jpg$').firstMatch(name);
          final pm = RegExp(r'^person_(\d+)\.jpg$').firstMatch(name);
          final rm = RegExp(r'^report_(\d+)\.jpg$').firstMatch(name);
          if (fm != null) {
            final id = int.parse(fm.group(1)!);
            await deleteIfOrphan(e, owned: () => stillFace(id));
          } else if (pm != null) {
            final id = int.parse(pm.group(1)!);
            await deleteIfOrphan(e, owned: () => stillPerson(id));
          } else if (rm != null) {
            final id = int.parse(rm.group(1)!);
            await deleteIfOrphan(e, owned: () => stillAsset(id));
          }
        }
      }
    } catch (_) {}
    return removed;
  }

  File? _firstFile(List<String> paths) {
    for (final path in paths) {
      final f = File(path);
      if (f.existsSync()) return f;
    }
    return null;
  }

  Future<void> _thumb(HttpRequest req, int id) async {
    // 先验库：作品删了即使缩略图文件还在（删除失败/延迟重试中）也不可读
    final a = await db.qOne('SELECT kind, ext FROM assets WHERE id=?', [id]);
    if (a == null) return _err(req, 404, 'Not Found');
    var f = _firstFile([
      p.join(thumbs.path, '$id.webp'),
      p.join(thumbs.path, '$id.jpg'),
    ]);
    if (f == null) {
      // 有文件立刻返回。抽帧走后台队列，绝不让 /api/thumb 等 20 秒。
      if (a['kind'] == 'video') {
        unawaited(_ensureVideoCover(id, (a['ext'] as String?) ?? 'mp4'));
      }
      return _err(req, 404, 'Not Found');
    }
    final mime = f.path.endsWith('.webp') ? 'image/webp' : 'image/jpeg';
    await _sendFile(req, f, mime);
  }

  Future<void> _reportPreview(HttpRequest req, int id) async {
    final a = await db.qOne('SELECT kind, ext FROM assets WHERE id=?', [id]);
    if (a == null || a['kind'] != 'image') {
      return _err(req, 404, 'Not Found');
    }
    final cached = File(p.join(thumbs.path, 'report_$id.jpg'));
    if (cached.existsSync() && cached.lengthSync() > 40) {
      return _sendFile(req, cached, 'image/jpeg');
    }
    File? made;
    try {
      made = await _reportPreviewJobs.putIfAbsent(id, () async {
        try {
          final source = File(p.join(orig.path, '$id.${a['ext']}'));
          if (!source.existsSync()) return null;
          final jpeg = await _reportPool.run(
            () => _imageWorkPool.run(
              () async =>
                  encodeReportPreviewJpegOffload(await source.readAsBytes()),
            ),
          );
          if (jpeg == null || jpeg.isEmpty) return null;
          await thumbs.create(recursive: true);
          await cached.writeAsBytes(jpeg, flush: true);
          return cached;
        } on TaskPoolBusy {
          rethrow;
        } catch (_) {
          return null;
        } finally {
          _reportPreviewJobs.remove(id);
        }
      });
    } on TaskPoolBusy {
      // 不用 HTTP 200 的缩略图冒充高清图，否则客户端会永久缓存降级结果。
      req.response.headers.set('Retry-After', '2');
      return _err(req, 503, '高清图片正在排队，请稍后重试');
    }
    if (made == null) return _thumb(req, id);
    await _sendFile(req, made, 'image/jpeg');
  }

  static const _thumbChannel = MethodChannel('dev.tuantu/box');

  Future<File?> _ensureVideoCover(int id, String ext) {
    return _coverJobs.putIfAbsent('video:$id', () async {
      try {
        final src = File(p.join(orig.path, '$id.$ext'));
        if (!src.existsSync()) return null;
        final out = File(p.join(thumbs.path, '$id.jpg'));
        if (out.existsSync() && out.lengthSync() > 40) return out;
        if (!Platform.isAndroid && !Platform.isIOS) return null;
        final r = await _thumbChannel
            .invokeMethod('videoThumb', {
              'src': src.path,
              'dest': out.path,
              'maxWidth': 480,
            })
            .timeout(const Duration(seconds: 20));
        if (r is Map && r['ok'] == true && out.existsSync()) {
          await db.run('UPDATE assets SET has_thumb=1 WHERE id=?', [id]);
          return out;
        }
        // 失败了别留 0 字节文件挡下次
        try {
          if (out.existsSync() && out.lengthSync() == 0) out.deleteSync();
        } catch (_) {}
        return null;
      } catch (_) {
        return null;
      } finally {
        _coverJobs.remove('video:$id');
      }
    });
  }

  /// 盒子启动后给旧视频补封面，不挡开盒子。
  Future<void> backfillVideoThumbs() async {
    List<Map<String, Object?>> rows;
    try {
      rows = await db.q(
        "SELECT id, ext FROM assets WHERE kind='video' AND IFNULL(has_thumb,0)=0 ORDER BY id DESC",
      );
    } catch (e) {
      debugPrint('[thumb] backfill query failed: $e');
      return;
    }
    for (final r in rows) {
      final id = (r['id'] as num?)?.toInt();
      if (id == null) continue;
      try {
        await _ensureVideoCover(id, (r['ext'] ?? 'mp4').toString());
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<void> _faceCrop(HttpRequest req, int id, int fid) async {
    final a = await db.qOne('SELECT id FROM assets WHERE id=?', [id]);
    if (a == null) return _err(req, 404, 'Not Found');
    final cached = File(p.join(thumbs.path, 'face_$fid.jpg'));
    if (cached.existsSync()) {
      await _sendFile(req, cached, 'image/jpeg');
      return;
    }
    // 封面/裁脸只用缩略图，绝不解码原片（原片解码会卡住 UI 线程）。
    final thumbF = _firstFile([
      p.join(thumbs.path, '$id.webp'),
      p.join(thumbs.path, '$id.jpg'),
    ]);
    if (thumbF == null) return _err(req, 404, 'Not Found');
    await _sendFile(
      req,
      thumbF,
      thumbF.path.endsWith('.webp') ? 'image/webp' : 'image/jpeg',
    );
  }

  Future<void> _personCoverRoute(HttpRequest req, String path) async {
    final segs = path.split('/');
    // /api/person/{pid}/cover
    if (segs.length < 5 || segs[4] != 'cover') {
      await _err(req, 404, 'Not Found');
      return;
    }
    final pid = int.tryParse(segs[3]);
    if (pid == null) {
      await _err(req, 404, 'Not Found');
      return;
    }
    File? f;
    try {
      f = await _ensurePersonCover(pid);
    } on TaskPoolBusy {
      req.response.headers.set('Retry-After', '2');
      req.response.headers.set('Cache-Control', 'no-store');
      return _err(req, 503, '封面正在生成，请稍后重试');
    }
    if (f == null) {
      await _err(req, 404, 'Not Found');
      return;
    }
    await _sendFile(req, f, 'image/jpeg');
  }

  File _personCoverFile(int pid) =>
      File(p.join(thumbs.path, 'person_$pid.jpg'));

  /// 删图、换封面、合并人物时让旧生成任务失效。
  /// 从 map 里移除 Future 并不能取消 isolate，所以写入前还必须校验代际。
  void _invalidatePersonCovers(Iterable<int> personIds) {
    final ids = personIds.toSet();
    if (ids.isEmpty) return;
    for (final pid in ids) {
      _personCoverGenerations[pid] = (_personCoverGenerations[pid] ?? 0) + 1;
      _coverJobs.remove('person:$pid');
    }
  }

  Future<Map<String, Object?>?> _faceForPersonCover(
    int pid, {
    int? faceId,
    int? assetId,
  }) async {
    if (faceId != null) {
      return db.qOne(
        'SELECT id, asset_id, x, y, w, h FROM faces WHERE id=? AND person_id=?',
        [faceId, pid],
      );
    }
    if (assetId != null) {
      return db.qOne(
        '''
SELECT id, asset_id, x, y, w, h FROM faces
WHERE person_id=? AND asset_id=?
ORDER BY (w*h) DESC LIMIT 1''',
        [pid, assetId],
      );
    }
    final person = await db.qOne(
      'SELECT cover_face_id FROM persons WHERE id=?',
      [pid],
    );
    if (person == null) return null;
    final chosen = (person['cover_face_id'] as num?)?.toInt();
    if (chosen != null) {
      final row = await db.qOne(
        'SELECT id, asset_id, x, y, w, h FROM faces WHERE id=? AND person_id=?',
        [chosen, pid],
      );
      if (row != null) return row;
    }
    return db.qOne(
      'SELECT id, asset_id, x, y, w, h FROM faces WHERE person_id=? ORDER BY (w*h) DESC, id ASC LIMIT 1',
      [pid],
    );
  }

  Future<File?> _ensurePersonCover(int pid, {bool force = false}) {
    final key = 'person:$pid';
    final active = _coverJobs[key];
    if (active != null) return active;

    late final Future<File?> job;
    final generation = _personCoverGenerations[pid] ?? 0;
    job = _buildPersonCover(pid, force: force, generation: generation)
        .whenComplete(() {
          // 只能清掉自己登记的任务。换封面等流程可能已为同一人物安排了新任务，
          // 旧任务结束时不能误删新任务。
          if (identical(_coverJobs[key], job)) _coverJobs.remove(key);
        });
    _coverJobs[key] = job;
    return job;
  }

  Future<File?> _buildPersonCover(
    int pid, {
    required bool force,
    required int generation,
  }) async {
    final watch = Stopwatch()..start();
    try {
      final out = _personCoverFile(pid);
      if (generation != (_personCoverGenerations[pid] ?? 0)) return null;
      if (!force && out.existsSync() && out.lengthSync() > 40) return out;
      return await _personCoverPool.run(() async {
        if (generation != (_personCoverGenerations[pid] ?? 0)) return null;
        final waitedMs = watch.elapsedMilliseconds;
        // 排队期间同一文件可能已由旧任务留下，进入重任务前再检查一次。
        if (!force && out.existsSync() && out.lengthSync() > 40) return out;
        final face = await _faceForPersonCover(pid);
        // 不存在的人物 ID 直接 404；不要为任意探测 ID 留日志去重状态。
        if (face == null) return null;
        final aid = face['asset_id'] as int;
        final a = await db.qOne(
          'SELECT ext, width, height FROM assets WHERE id=?',
          [aid],
        );
        final thumbF = _firstFile([
          p.join(thumbs.path, '$aid.webp'),
          p.join(thumbs.path, '$aid.jpg'),
        ]);
        final origF = File(p.join(orig.path, '$aid.${a?['ext'] ?? 'jpg'}'));
        if (thumbF == null && !origF.existsSync()) {
          _logCoverUnavailable(pid, 'source_missing');
          return null;
        }
        await thumbs.create(recursive: true);
        final temp = File(
          p.join(
            thumbs.path,
            '_tmp_person_${pid}_${DateTime.now().microsecondsSinceEpoch}.jpg',
          ),
        );
        markLiveFile(temp.path);
        final payload = <String, dynamic>{
          'thumb': thumbF?.path ?? '',
          'orig': origF.existsSync() ? origF.path : '',
          'out': temp.path,
          'ow': (a?['width'] as num?)?.toInt() ?? 0,
          'oh': (a?['height'] as num?)?.toInt() ?? 0,
          'x': (face['x'] as num?)?.toInt() ?? 0,
          'y': (face['y'] as num?)?.toInt() ?? 0,
          'w': (face['w'] as num?)?.toInt() ?? 1,
          'h': (face['h'] as num?)?.toInt() ?? 1,
        };
        try {
          final ok = await _imageWorkPool.run(
            () => _personCoverWriter(payload),
            priority: true,
          );
          if (ok != true || !temp.existsSync() || temp.lengthSync() <= 40) {
            _logCoverUnavailable(pid, 'decode_or_write_failed');
            return null;
          }
          final coverRevision = db.personsRev;
          final selectedNow = await _faceForPersonCover(pid);
          final faceStillExists =
              await db.qOne(
                '''
SELECT 1 x FROM faces f
JOIN persons p ON p.id=f.person_id
JOIN assets a ON a.id=f.asset_id
WHERE f.id=? AND f.person_id=? AND f.asset_id=?''',
                [face['id'], pid, aid],
              ) !=
              null;
          // DB 校验会 await，因此必须在它返回后再读一次代际。
          // 下面的最终替换不能再 await，保证失效操作不会插入。
          if (!faceStillExists ||
              selectedNow?['id'] != face['id'] ||
              coverRevision != db.personsRev ||
              generation != (_personCoverGenerations[pid] ?? 0)) {
            return null;
          }
          try {
            if (out.existsSync()) out.deleteSync();
            temp.renameSync(out.path);
          } on FileSystemException {
            temp.copySync(out.path);
            temp.deleteSync();
          }
        } finally {
          unmarkLiveFile(temp.path);
          try {
            if (temp.existsSync()) await temp.delete();
          } catch (_) {}
        }
        _coverFailureLogged.remove(pid);
        if (waitedMs >= 100 || watch.elapsedMilliseconds >= 500) {
          debugPrint(
            '[cover] person=$pid stage=generated waitMs=$waitedMs '
            'totalMs=${watch.elapsedMilliseconds} '
            'running=${_personCoverPool.running} queued=${_personCoverPool.queued}',
          );
        }
        return out;
      });
    } on TaskPoolBusy {
      rethrow;
    } catch (e, st) {
      debugPrint('[cover] person $pid failed: $e\n$st');
      return null;
    }
  }

  void _logCoverUnavailable(int pid, String reason) {
    if (!_coverFailureLogged.add(pid)) return;
    if (_coverFailureLogged.length > 128) {
      _coverFailureLogged.remove(_coverFailureLogged.first);
    }
    debugPrint(
      '[cover] person=$pid stage=unavailable reason=$reason '
      'running=${_personCoverPool.running} queued=${_personCoverPool.queued}',
    );
  }

  Future<void> _live(HttpRequest req, int id) async {
    final a = await db.qOne('SELECT id, ext FROM assets WHERE id=?', [id]);
    if (a == null) return _err(req, 404, 'Not Found');
    final f = File(p.join(orig.path, '$id.live.mp4'));
    if (!liveVideoFileReady(f)) {
      await _recoverLiveSidecar(id, (a['ext'] ?? '').toString());
    }
    if (!liveVideoFileReady(f)) return _err(req, 404, 'Not Found');
    final handle = await f.open();
    late final String mime;
    try {
      mime = liveVideoMime(await handle.read(12));
    } finally {
      await handle.close();
    }
    await _sendFile(req, f, mime);
  }

  /// 旧数据：静图里已经内嵌动态，但没有 sidecar。只在 /live 路径补齐，
  /// 绝不挂在 /api/status 上。内嵌都没有则无法凭静图发明动态。
  final _liveRecoveries = <int, Future<void>>{};

  Future<void> _recoverLiveSidecar(int id, String ext) =>
      _liveRecoveries.putIfAbsent(
        id,
        () => _recoverLiveSidecarOnce(id, ext).whenComplete(() {
          _liveRecoveries.remove(id);
        }),
      );

  Future<void> _recoverLiveSidecarOnce(int id, String ext) async {
    final still = File(p.join(orig.path, '$id.$ext'));
    if (!still.existsSync()) return;
    try {
      final dest = File(p.join(orig.path, '$id.live.mp4'));
      final tempPath = '${dest.path}.recover';
      markLiveFile(dest.path);
      markLiveFile(tempPath);
      int? pts;
      try {
        final recovered = await compute(recoverLiveSidecarFromPaths, [
          still.path,
          tempPath,
        ]);
        if (recovered == null) return;
        pts = recovered;
        await File(tempPath).rename(dest.path);
      } finally {
        unmarkLiveFile(dest.path);
        unmarkLiveFile(tempPath);
        if (File(tempPath).existsSync()) await File(tempPath).delete();
      }
      if (pts >= 0) {
        await db.run('UPDATE assets SET has_live=1, live_pts=? WHERE id=?', [
          pts,
          id,
        ]);
      } else {
        await db.run('UPDATE assets SET has_live=1 WHERE id=?', [id]);
      }
    } catch (e, st) {
      debugPrint('[live] recover id=$id failed: $e\n$st');
    }
  }

  Future<void> _raw(HttpRequest req, int id) async {
    final a = await db.qOne('SELECT orig_name, ext FROM assets WHERE id=?', [
      id,
    ]);
    if (a == null) return _err(req, 404, 'Not Found');
    final f = File(p.join(orig.path, '$id.${a['ext']}'));
    if (!f.existsSync()) return _err(req, 404, 'Not Found');
    final mime = _mime[a['ext']] ?? 'application/octet-stream';
    await _sendFile(req, f, mime);
  }

  Future<void> _userProfile(HttpRequest req, int uid) async {
    final u = await db.userById(uid);
    if (u == null) return _err(req, 404, '没有这个人');
    final uploaded =
        firstInt(
          await db.q('SELECT COUNT(*) c FROM assets WHERE uploader_id=?', [
            uid,
          ]),
        ) ??
        0;
    final last = await db.qOne(
      'SELECT MAX(created_at) t FROM assets WHERE uploader_id=?',
      [uid],
    );
    await _json(req, {
      'id': uid,
      'name': u['name'],
      'uploaded': uploaded,
      'last_upload': last?['t'],
      'avatar': _avatarUrl(u),
    });
  }

  Future<void> _sendAvatar(HttpRequest req, int uid) async {
    final f = _firstFile([
      p.join(avatars.path, '$uid.webp'),
      p.join(avatars.path, '$uid.jpg'),
    ]);
    if (f == null) return _err(req, 404, 'Not Found');
    final mime = f.path.endsWith('.webp') ? 'image/webp' : 'image/jpeg';
    await _sendFile(req, f, mime);
  }

  Future<void> _persons(HttpRequest req, Map user) async {
    final mine = {
      for (final r in await db.q(
        'SELECT person_id FROM person_claims WHERE user_id=?',
        [user['id']],
      ))
        r['person_id'],
    };
    // 历史冲突待确认的认领（迁移/重聚类转入），按人物聚合，前端标「待确认」。
    final pendingByPerson = <int, List<Map<String, Object?>>>{};
    for (final r in await db.q('''
SELECT cp.person_id, cp.user_id, u.name
FROM claim_pending cp
JOIN users u ON u.id = cp.user_id
WHERE cp.resolved_at IS NULL
  AND EXISTS(SELECT 1 FROM persons p WHERE p.id = cp.person_id)
''')) {
      final pid = (r['person_id'] as num).toInt();
      pendingByPerson.putIfAbsent(pid, () => []).add({
        'user_id': r['user_id'],
        'name': r['name'],
      });
    }
    final rows = await db.q('''
SELECT p.id, p.name, p.claimed_by, p.member_status, p.cover_face_id, cnt.n, f.asset_id
FROM persons p
JOIN (SELECT person_id, COUNT(*) n FROM faces GROUP BY person_id) cnt
  ON cnt.person_id = p.id
LEFT JOIN faces f ON f.id = (
  SELECT f2.id FROM faces f2
  WHERE f2.person_id = p.id
  ORDER BY (f2.w * f2.h) DESC LIMIT 1
)
WHERE cnt.n > 0
ORDER BY cnt.n DESC''');
    final out = [
      for (final r in rows)
        {
          'id': r['id'],
          'name': r['name'],
          'count': r['n'],
          'cover': personCoverUrl(
            (r['id'] as num).toInt(),
            coverFaceId: (r['cover_face_id'] as num?)?.toInt(),
          ),
          'cover_face_id': r['cover_face_id'],
          'claimed_by_me': mine.contains(r['id']),
          'claimed_by': r['claimed_by'],
          'member': (r['member_status'] as num?)?.toInt() ?? 0,
          'pending': pendingByPerson[r['id']] ?? const <Map>[],
        },
    ];
    await _json(req, out);
  }

  /// 认领状态快照：我现在认领的人物、目标人物现在的认领者。
  /// 409 响应和「确认期间关系已变」的再校验都用它。
  Future<Map<String, dynamic>> _claimState(BoxDb tx, int uid, int pid) async {
    final my = await tx.qOne(
      '''
SELECT p.id, p.name FROM person_claims c
JOIN persons p ON p.id = c.person_id WHERE c.user_id=?''',
      [uid],
    );
    final their = await tx.qOne(
      '''
SELECT u.id, u.name FROM person_claims c
JOIN users u ON u.id = c.user_id WHERE c.person_id=?''',
      [pid],
    );
    final p = await tx.qOne('SELECT member_status FROM persons WHERE id=?', [
      pid,
    ]);
    return {
      'my_person': my == null ? null : {'id': my['id'], 'name': my['name']},
      'person_user': their == null
          ? null
          : {'id': their['id'], 'name': their['name']},
      'person_member': (p?['member_status'] as num?)?.toInt() ?? 0,
    };
  }

  /// 原子应用一次认领：解除我的旧认领（若有）、解除目标上的他人认领（若有，
  /// 留迁移记录）、建立新认领、未标记/非团员恢复为团员、清掉该对的待确认。
  Future<void> _applyClaim(BoxDb tx, int uid, int pid) async {
    final now = BoxDb.now();
    final myOld = await tx.qOne(
      'SELECT person_id, created_at FROM person_claims WHERE user_id=?',
      [uid],
    );
    if (myOld != null && myOld['person_id'] != pid) {
      await tx.run(
        'DELETE FROM person_claims WHERE person_id=? AND user_id=?',
        [myOld['person_id'], uid],
      );
      await tx.run('UPDATE persons SET claimed_by=NULL WHERE id=?', [
        myOld['person_id'],
      ]);
    }
    final theirOld = await tx.qOne(
      'SELECT user_id, created_at FROM person_claims WHERE person_id=?',
      [pid],
    );
    if (theirOld != null && theirOld['user_id'] != uid) {
      await tx.run('DELETE FROM person_claims WHERE person_id=?', [pid]);
      // 接替记录：被解除的账号可在历史里查到，不参与待确认。
      await tx.exec(
        '''
INSERT OR REPLACE INTO claim_pending(person_id, user_id, created_at, pending_at, reason, resolved_at)
VALUES(?,?,?,?, 'takeover', ?)
''',
        [pid, theirOld['user_id'], theirOld['created_at'] ?? now, now, now],
      );
    }
    await tx.exec(
      'INSERT OR IGNORE INTO person_claims(person_id, user_id, created_at) VALUES(?,?,?)',
      [pid, uid, now],
    );
    // 新认领成功自动成为团员；已是团员的保留原标记人和时间。
    await tx.run(
      'UPDATE persons SET member_status=1, '
      'member_marked_by=CASE WHEN member_status=1 THEN member_marked_by ELSE ? END, '
      'member_marked_at=CASE WHEN member_status=1 THEN member_marked_at ELSE ? END '
      'WHERE id=? AND member_status != 1',
      [uid, now, pid],
    );
    await tx.run('UPDATE persons SET claimed_by=? WHERE id=?', [uid, pid]);
    await tx.run(
      'UPDATE claim_pending SET resolved_at=? WHERE person_id=? AND user_id=? AND resolved_at IS NULL',
      [now, pid, uid],
    );
  }

  Future<void> _personAction(HttpRequest req, Map user, String path) async {
    final segs = path.split('/');
    // /api/persons/{pid}/claim|unclaim|rename|member|cover
    if (segs.length < 5) return _err(req, 404, 'Not Found');
    final pid = int.tryParse(segs[3]);
    if (pid == null) return _err(req, 404, 'Not Found');
    final action = segs[4];
    final uid = user['id'] as int;

    if (action == 'claim') {
      final body = await _readJson(req);
      final confirm = body['confirm'] == true;
      // 客户端确认对话框展示过的状态快照（expect_*）：
      // 应用前再核对一遍，期间被别人动过就退回最新状态，绝不覆盖。
      final hasMy = body.containsKey('expect_my_person');
      final hasTheir = body.containsKey('expect_person_user');
      final out = await db.txn((tx) async {
        final person = await tx.qOne(
          'SELECT id, name FROM persons WHERE id=?',
          [pid],
        );
        if (person == null) return {'missing': true};
        final st = await _claimState(tx, uid, pid);
        final myId = (st['my_person'] as Map?)?['id'];
        final theirId = (st['person_user'] as Map?)?['id'];
        final conflictMy = myId != null && myId != pid;
        final conflictTheir = theirId != null && theirId != uid;
        // 非团员人物被认领：确认框要说明会恢复为团员。
        final restoreMember = (st['person_member'] as int? ?? 0) == 2;
        if (!conflictMy && !conflictTheir && !restoreMember) {
          if (myId == pid) return {'ok': true, 'already': true};
          await _applyClaim(tx, uid, pid);
          return {'ok': true};
        }
        if (!confirm) {
          return {'conflict': st};
        }
        // 确认路径：核对客户端看到的还是不是当前状态
        final expectMy = hasMy
            ? (body['expect_my_person'] as num?)?.toInt()
            : null;
        final expectTheir = hasTheir
            ? (body['expect_person_user'] as num?)?.toInt()
            : null;
        final myNow = myId == null ? -1 : (myId as num).toInt();
        final theirNow = theirId == null ? -1 : (theirId as num).toInt();
        if ((hasMy && expectMy != myNow) ||
            (hasTheir && expectTheir != theirNow)) {
          return {'conflict': st, 'stale': true};
        }
        await _applyClaim(tx, uid, pid);
        return {'ok': true};
      });
      if (out.containsKey('missing')) {
        return _err(req, 404, '人物不存在');
      }
      if (out.containsKey('conflict')) {
        return _json(req, out, status: 409);
      }
      if (out['ok'] == true && out['already'] != true) db.bumpPersonsRev();
      return _json(req, out);
    }

    if (action == 'unclaim') {
      // 只取消当前账号的认领；不动团员标记、不删人物、允许再次认领。
      await db.txn((tx) async {
        final n = await tx.run(
          'DELETE FROM person_claims WHERE person_id=? AND user_id=?',
          [pid, uid],
        );
        if (n > 0) {
          await tx.run('UPDATE persons SET claimed_by=NULL WHERE id=?', [pid]);
          // 我明确说「不是我」：该对的待确认也随之了结。
          await tx.run(
            'UPDATE claim_pending SET resolved_at=? WHERE person_id=? AND user_id=? AND resolved_at IS NULL',
            [BoxDb.now(), pid, uid],
          );
        }
      });
      db.bumpPersonsRev();
      return _json(req, {'ok': true});
    }

    if (action == 'cover') {
      final body = await _readJson(req);
      final faceId = (body['face_id'] as num?)?.toInt();
      final assetId = (body['asset_id'] as num?)?.toInt();
      if (faceId == null && assetId == null) {
        return _err(req, 400, '请选择一张这个人的照片');
      }
      final exists = await db.qOne('SELECT id FROM persons WHERE id=?', [pid]);
      if (exists == null) return _err(req, 404, '人物不存在');
      final face = await _faceForPersonCover(
        pid,
        faceId: faceId,
        assetId: assetId,
      );
      if (face == null) {
        return _err(req, 400, '这张照片里没有这个人的脸');
      }
      final fid = (face['id'] as num).toInt();
      await db.run('UPDATE persons SET cover_face_id=? WHERE id=?', [fid, pid]);
      db.bumpPersonsRev();
      _invalidatePersonCovers([pid]);
      try {
        final cached = _personCoverFile(pid);
        if (cached.existsSync()) cached.deleteSync();
      } catch (_) {}
      final file = await _ensurePersonCover(pid, force: true);
      if (file == null) return _err(req, 500, '裁封面失败');
      return _json(req, {
        'ok': true,
        'cover': personCoverUrl(pid, coverFaceId: fid),
        'cover_face_id': fid,
      });
    }

    if (action == 'member') {
      final body = await _readJson(req);
      final status = (body['status'] as num?)?.toInt();
      if (status == null || status < 0 || status > 2) {
        return _err(req, 400, 'status 必须是 0/1/2');
      }
      final exists = await db.qOne('SELECT id FROM persons WHERE id=?', [pid]);
      if (exists == null) return _err(req, 404, '人物不存在');
      final now = BoxDb.now();
      await db.run(
        'UPDATE persons SET member_status=?, member_marked_by=?, member_marked_at=? WHERE id=?',
        [status, uid, now, pid],
      );
      db.bumpPersonsRev();
      return _json(req, {'ok': true, 'status': status});
    }

    if (action == 'rename') {
      final body = await _readJson(req);
      final name = ((body['name'] ?? '') as String).trim();
      await db.run('UPDATE persons SET name=? WHERE id=?', [
        name.isEmpty ? null : (name.length > 20 ? name.substring(0, 20) : name),
        pid,
      ]);
      db.bumpPersonsRev();
      return _json(req, {'ok': true});
    }
    return _err(req, 404, 'Not Found');
  }

  /// 批量设置团员标记。先核对整批人物都存在，再在同一事务中更新，
  /// 避免请求中断时出现只改成功一部分的状态。
  Future<void> _markPersonsMembers(HttpRequest req, Map user) async {
    final body = await _readJson(req);
    final status = (body['status'] as num?)?.toInt();
    if (status == null || status < 0 || status > 2) {
      return _err(req, 400, 'status 必须是 0/1/2');
    }
    final rawIds = body['ids'];
    if (rawIds is! List) return _err(req, 400, 'ids 必须是人物编号列表');
    final ids = <int>{};
    for (final value in rawIds) {
      final id = (value as num?)?.toInt();
      if (id == null || id <= 0) return _err(req, 400, '人物编号无效');
      ids.add(id);
    }
    if (ids.isEmpty || ids.length > 500) {
      return _err(req, 400, '每次请选择 1–500 个人物');
    }

    final list = ids.toList(growable: false);
    final placeholders = List.filled(list.length, '?').join(',');
    final uid = user['id'] as int;
    final now = BoxDb.now();
    final updated = await db.txn((tx) async {
      final found = await tx.q(
        'SELECT id FROM persons WHERE id IN ($placeholders)',
        list,
      );
      if (found.length != list.length) return -1;
      return tx.run(
        'UPDATE persons SET member_status=?, member_marked_by=?, member_marked_at=? '
        'WHERE id IN ($placeholders)',
        [status, uid, now, ...list],
      );
    });
    if (updated < 0) return _err(req, 404, '部分人物不存在，请刷新后重试');
    db.bumpPersonsRev();
    return _json(req, {'ok': true, 'status': status, 'count': updated});
  }

  Future<void> _mergePersons(HttpRequest req, Map user) async {
    final body = await _readJson(req);
    final raw = body['ids'];
    if (raw is! List || raw.length < 2) {
      return _err(req, 400, '至少选两个人物才能合并');
    }
    final ids = [
      for (final e in raw)
        if (e is num) e.toInt() else int.tryParse('$e'),
    ].whereType<int>().toSet().toList();
    if (ids.length < 2) return _err(req, 400, '至少选两个人物才能合并');
    final ph = List.filled(ids.length, '?').join(',');
    // keep_claim_user：保留哪个账号的认领；'none' = 全部取消。
    // 只有关联到不同账号时才必须由操作者显式选择。
    final keepClaim = body['keep_claim_user'];

    final persons = await db.q(
      'SELECT id, name, member_status, member_marked_by, member_marked_at '
      'FROM persons WHERE id IN ($ph)',
      ids,
    );
    if (persons.length != ids.length) return _err(req, 404, '有人物不存在');
    final claims = await db.q(
      'SELECT person_id, user_id, created_at FROM person_claims WHERE person_id IN ($ph)',
      ids,
    );
    final distinctUsers = {
      for (final c in claims) (c['user_id'] as num).toInt(),
    };
    if (distinctUsers.length > 1 && keepClaim == null) {
      // 不同账号的认领撞在一起：让操作者选保留谁的，不能靠顺序默认。
      final names = {
        for (final u in await db.q(
          'SELECT id, name FROM users WHERE id IN (${List.filled(distinctUsers.length, '?').join(',')})',
          distinctUsers.toList(),
        ))
          (u['id'] as num).toInt(): u['name'].toString(),
      };
      final byId = {for (final p in persons) (p['id'] as num).toInt(): p};
      return _json(req, {
        'conflict': {
          'type': 'merge_claims',
          'claims': [
            for (final c in claims)
              {
                'person_id': c['person_id'],
                'person_name': byId[(c['person_id'] as num).toInt()]?['name'],
                'user_id': c['user_id'],
                'user_name': names[(c['user_id'] as num).toInt()] ?? '?',
              },
          ],
        },
      }, status: 409);
    }
    int? keepUser;
    if (keepClaim == 'none') {
      keepUser = null;
    } else if (keepClaim != null) {
      keepUser = (keepClaim as num?)?.toInt();
      if (keepUser == null || !distinctUsers.contains(keepUser)) {
        return _err(req, 400, 'keep_claim_user 不是这些人物的认领者');
      }
    } else if (distinctUsers.length == 1) {
      keepUser = distinctUsers.first; // 只有一个账号，合并后自然一对一
    }

    var keep = ids.first;
    var best = -1;
    for (final id in ids) {
      final n =
          firstInt(
            await db.q('SELECT COUNT(*) c FROM faces WHERE person_id=?', [id]),
          ) ??
          0;
      if (n > best) {
        best = n;
        keep = id;
      }
    }
    // 团员状态：团员 > 非团员 > 未标记，绝不静默丢掉人工标记；
    // 同优先级时保留 keep 人物自己的标记人和时间。
    var memberStatus = 0;
    int? memberMarkedBy;
    double? memberMarkedAt;
    for (final p in persons) {
      final s = (p['member_status'] as num?)?.toInt() ?? 0;
      if (s == 0) continue;
      final isKeep = (p['id'] as num).toInt() == keep;
      final winner =
          memberStatusPriority(s) > memberStatusPriority(memberStatus) ||
          (isKeep &&
              memberStatusPriority(s) == memberStatusPriority(memberStatus));
      if (winner) {
        memberStatus = s;
        memberMarkedBy = (p['member_marked_by'] as num?)?.toInt();
        memberMarkedAt = (p['member_marked_at'] as num?)?.toDouble();
      }
    }
    // 保留人物没名字时收养第一个有名字的，别把名字合没了。
    final keepName = persons
        .firstWhere((p) => (p['id'] as num).toInt() == keep)['name']
        ?.toString();
    final adoptName = keepName?.trim().isNotEmpty == true
        ? null
        : persons
              .map((p) => p['name']?.toString())
              .firstWhere(
                (n) => n?.trim().isNotEmpty == true,
                orElse: () => null,
              );
    final now = BoxDb.now();
    final doomedCovers = <int>[];
    await db.txn((tx) async {
      for (final id in ids) {
        if (id == keep) continue;
        // 被并掉的人物上的认领：除保留者外，全部转为已了结的合并记录。
        await tx.exec(
          '''
INSERT OR REPLACE INTO claim_pending(person_id, user_id, created_at, pending_at, reason, resolved_at)
SELECT ?, user_id, created_at, ?, 'merge', ? FROM person_claims WHERE person_id=?
''',
          [id, now, now, id],
        );
        await tx.run('DELETE FROM person_claims WHERE person_id=?', [id]);
        await tx.run('UPDATE faces SET person_id=? WHERE person_id=?', [
          keep,
          id,
        ]);
        // 待确认记录跟着人物走（同一用户重复的丢弃无妨）。
        await tx.run(
          'UPDATE OR IGNORE claim_pending SET person_id=? WHERE person_id=?',
          [keep, id],
        );
        await tx.run('DELETE FROM persons WHERE id=?', [id]);
        doomedCovers.add(id);
      }
      await tx.run('DELETE FROM person_claims WHERE person_id=?', [keep]);
      if (keepUser != null) {
        await tx.exec(
          'INSERT INTO person_claims(person_id, user_id, created_at) VALUES(?,?,?)',
          [keep, keepUser, now],
        );
      }
      if (adoptName != null) {
        await tx.run('UPDATE persons SET name=? WHERE id=?', [adoptName, keep]);
      }
      await tx.run(
        'UPDATE persons SET claimed_by=?, member_status=?, member_marked_by=?, member_marked_at=? WHERE id=?',
        [keepUser, memberStatus, memberMarkedBy, memberMarkedAt, keep],
      );
    });
    db.bumpPersonsRev();
    _invalidatePersonCovers({...doomedCovers, keep});
    for (final id in doomedCovers) {
      try {
        File(p.join(thumbs.path, 'person_$id.jpg')).deleteSync();
      } catch (_) {}
    }
    try {
      File(p.join(thumbs.path, 'person_$keep.jpg')).deleteSync();
    } catch (_) {}
    await _json(req, {'ok': true, 'id': keep});
  }

  final _storyPool = BoundedTaskPool(
    1,
    maxQueued: 32,
    queueTimeout: const Duration(seconds: 20),
  );
  final _storyJobs = <String, Future<Map<String, dynamic>?>>{};
  @visibleForTesting
  Future<void> Function()? debugBeforeStoryBuild;

  Future<void> _story(HttpRequest req, Map user, {required bool index}) async {
    final q = req.uri.queryParameters;
    final offset = int.tryParse(q['offset'] ?? '');
    if (offset == null || offset < -720 || offset > 840) {
      return _err(req, 400, '时区不合法');
    }
    final value = q[index ? 'before' : 'day'];
    final day = value == null ? null : StoryDay.parse(value, offset);
    if ((!index || value != null) && day == null) {
      return _err(req, 400, '日期不合法');
    }
    // 同账号同日期只聚合一次；不同账号绝不共用个人内容。
    // 排队只涵盖计算，不能把慢客户端发送响应的时间也算作「忙碌」。
    final key = '${user['id']}|$index|$offset|$value';
    try {
      final data = await _storyJobs.putIfAbsent(key, () async {
        try {
          return await _storyPool.run(() async {
            await debugBeforeStoryBuild?.call();
            return db.txn(
              (tx) => index
                  ? buildStoryDays(
                      db: tx,
                      user: user,
                      offset: offset,
                      before: day,
                    )
                  : buildStoryData(
                      db: tx,
                      user: user,
                      day: day!,
                      cards: (rows, currentUser) =>
                          _cards(rows, currentUser, queryDb: tx),
                    ),
            );
          });
        } finally {
          _storyJobs.remove(key);
        }
      });
      if (data == null) {
        await _json(req, {
          'code': 'claim_required',
          'detail': '请先在人物页认领「这是我」',
        }, status: 409);
        return;
      }
      await _json(req, data);
    } on TaskPoolBusy {
      req.response.headers.set('Retry-After', '2');
      await _err(req, 429, '报告正在排队，请稍后重试');
    }
  }

  Future<void> _reportData(HttpRequest req, Map user) async {
    final q = req.uri.queryParameters;
    final fromW = double.tryParse(q['from_w'] ?? '');
    final toW = double.tryParse(q['to_w'] ?? '');
    final fromT = double.tryParse(q['from_t'] ?? '');
    final toT = double.tryParse(q['to_t'] ?? '');
    if (fromW == null ||
        toW == null ||
        fromT == null ||
        toT == null ||
        fromW >= toW ||
        fromT >= toT) {
      return _err(req, 400, '时间范围不合法');
    }
    // 防呆：超过 400 天的报告不聚（全表扫太久），客户端本来也不会给这么长。
    if (toW - fromW > 400 * 86400 || toT - fromT > 400 * 86400 + 86400) {
      return _err(req, 400, '时间范围太长');
    }
    int? personId;
    final rawPerson = q['person'];
    if (rawPerson != null && rawPerson.isNotEmpty) {
      personId = int.tryParse(rawPerson);
      if (personId == null) return _err(req, 400, 'person 不合法');
    }
    // 多条统计查询必须看到同一份数据库快照；卡片字段也使用同一个事务，
    // 避免生成期间恰逢删除/点赞时出现总数与候选图互相矛盾。
    final data = await db.txn(
      (tx) => buildReportData(
        db: tx,
        user: user,
        cards: (rows, currentUser) => _cards(rows, currentUser, queryDb: tx),
        fromW: fromW,
        toW: toW,
        fromT: fromT,
        toT: toT,
        personId: personId,
      ),
    );
    if (data == null) return _err(req, 404, '人物不存在或不是团员');
    await _json(req, data);
  }

  Future<Map<String, dynamic>> _card(Map a, Map user) async {
    final list = await _cards([a], user);
    return list.first;
  }

  /// 报告聚合复用的卡片构建（带点赞/评论/上传者信息）。
  Future<List<Map<String, dynamic>>> cards(List<Map> rows, Map user) =>
      _cards(rows, user);

  Future<List<Map<String, dynamic>>> _cards(
    List<Map> rows,
    Map user, {
    BoxDb? queryDb,
  }) async {
    if (rows.isEmpty) return const [];
    final source = queryDb ?? db;
    final ids = [for (final a in rows) a['id'] as int];
    final ph = List.filled(ids.length, '?').join(',');
    final likeMap = <int, int>{};
    for (final r in await source.q(
      'SELECT asset_id, COUNT(*) c FROM likes WHERE asset_id IN ($ph) GROUP BY asset_id',
      ids,
    )) {
      likeMap[(r['asset_id'] as num).toInt()] = (r['c'] as num).toInt();
    }
    final myLikes = {
      for (final r in await source.q(
        'SELECT asset_id FROM likes WHERE user_id=? AND asset_id IN ($ph)',
        [user['id'], ...ids],
      ))
        (r['asset_id'] as num).toInt(),
    };
    final commentMap = <int, int>{};
    for (final r in await source.q(
      'SELECT asset_id, COUNT(*) c FROM comments WHERE asset_id IN ($ph) GROUP BY asset_id',
      ids,
    )) {
      commentMap[(r['asset_id'] as num).toInt()] = (r['c'] as num).toInt();
    }
    final uids = {for (final a in rows) (a['uploader_id'] as num).toInt()};
    final users = <int, Map?>{};
    for (final uid in uids) {
      if (queryDb != null) {
        users[uid] = await source.userById(uid);
      } else {
        if (!_userCache.containsKey(uid)) {
          _userCache[uid] = await source.userById(uid);
        }
        users[uid] = _userCache[uid];
      }
    }
    final out = <Map<String, dynamic>>[];
    for (final a in rows) {
      final id = a['id'] as int;
      final uid = (a['uploader_id'] as num).toInt();
      final uploader = users[uid];
      // has_live 只在 sidecar 完整落盘后才入库。列表返回直接信任该标志，
      // 避免每个客户端每页对外部存储做最多 90 次同步 stat。
      final hasLive = (a['has_live'] as num?)?.toInt() ?? 0;
      out.add({
        'id': id,
        'thumb': '/api/asset/$id/thumb',
        'kind': a['kind'],
        'ext': a['ext'],
        'has_thumb': a['has_thumb'],
        'orig_name': a['orig_name'],
        'width': a['width'] ?? 0,
        'height': a['height'] ?? 0,
        'duration': a['duration'],
        'taken_at': a['taken_at'] ?? a['created_at'],
        'created_at': a['created_at'],
        'uploader': uploader?['name'] ?? '?',
        'uploader_id': uid,
        'avatar': _avatarUrl(uploader),
        'mine': uid == user['id'],
        'likes': likeMap[id] ?? 0,
        'liked': myLikes.contains(id),
        'comments': commentMap[id] ?? 0,
        'has_live': hasLive,
        'live_ready': hasLive,
        'live_pts': (a['live_pts'] as num?)?.toInt(),
      });
    }
    return out;
  }

  String? _avatarUrl(Map? u) {
    if (u == null) return null;
    final v = (u['avatar'] as num?)?.toInt() ?? 0;
    if (v == 0) return null;
    return '/api/user/${u['id']}/avatar?v=$v';
  }

  String? _epochDay(Object? ts) {
    if (ts is! num) return null;
    final n = ts.toDouble();
    // 0000 年 / 超出 DateTime 范围的脏时间当作没有日期（否则 RangeError）。
    if (n == 0 || !n.isFinite || n.abs() > 8640000000000) return null;
    final d = DateTime.fromMillisecondsSinceEpoch(
      (n * 1000).round(),
      isUtc: true,
    );
    if (d.year < 1900 || d.year > 9999) return null;
    String p2(int x) => x.toString().padLeft(2, '0');
    return '${d.year}-${p2(d.month)}-${p2(d.day)}';
  }

  Future<void> _sendFile(HttpRequest req, File f, String mime) async {
    final stat = await f.stat();
    final len = stat.size;
    final etag = '"$len-${stat.modified.microsecondsSinceEpoch}"';
    req.response.headers.set('ETag', etag);
    final ifRange = req.headers.value('if-range');
    final range = ifRange == null || ifRange == etag
        ? req.headers.value('range')
        : null;
    req.response.headers.set('Accept-Ranges', 'bytes');
    req.response.headers.contentType = ContentType.parse(mime);
    if (mime.startsWith('image/') || mime.startsWith('video/')) {
      req.response.headers.set('Cache-Control', 'public, max-age=86400');
    }
    if (range != null && range.toLowerCase().startsWith('bytes=')) {
      // 单 Range：a-b / a- / -n（后缀）。多段 Range 忽略，按整文件返回。
      final r = parseRangeHeader(range, len);
      if (r == const RangeResult.invalid()) {
        req.response.statusCode = 416;
        req.response.headers.set('Content-Range', 'bytes */$len');
        await req.response.close();
        return;
      }
      if (r != null) {
        req.response.statusCode = 206;
        req.response.headers.set(
          'Content-Range',
          'bytes ${r.start}-${r.end}/$len',
        );
        req.response.contentLength = r.end - r.start + 1;
        await req.response.addStream(f.openRead(r.start, r.end + 1));
        await req.response.close();
        return;
      }
      // 非法 Range 头：忽略，按整文件 200 返回
    }
    req.response.contentLength = len;
    await req.response.addStream(f.openRead());
    await req.response.close();
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final s = await utf8.decoder.bind(req).join();
    if (s.isEmpty) return {};
    final v = jsonDecode(s);
    return v is Map ? Map<String, dynamic>.from(v) : {};
  }

  Future<void> _json(HttpRequest req, Object data, {int status = 200}) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(data));
    await req.response.close();
  }

  Future<void> _err(HttpRequest req, int status, String detail) =>
      _json(req, {'detail': detail}, status: status);

  Future<List<_Part>> _multipart(HttpRequest req) async {
    final ctype = req.headers.contentType;
    final boundary = ctype?.parameters['boundary'];
    if (boundary == null) return [];
    final builder = BytesBuilder(copy: false);
    await for (final c in req) {
      builder.add(c);
    }
    return _parseMultipart(builder.takeBytes(), boundary);
  }
}

/// 在后台 isolate 里裁一张脸封面。参数全是路径/整数，避免 Isolate 传 Uint8List 失败。
bool writePersonCover(Map<String, dynamic> a) {
  try {
    final thumb = (a['thumb'] ?? '').toString();
    final orig = (a['orig'] ?? '').toString();
    final out = (a['out'] ?? '').toString();
    if (out.isEmpty) return false;
    im.Image? img;
    var sx = 1.0;
    var sy = 1.0;
    final ow = (a['ow'] as num?)?.toInt() ?? 0;
    final oh = (a['oh'] as num?)?.toInt() ?? 0;
    if (thumb.isNotEmpty) {
      img = im.decodeImage(File(thumb).readAsBytesSync());
      if (img != null && ow > 0 && oh > 0) {
        sx = img.width / ow;
        sy = img.height / oh;
      }
    }
    var x = (((a['x'] as num?)?.toDouble() ?? 0) * sx).round();
    var y = (((a['y'] as num?)?.toDouble() ?? 0) * sy).round();
    var w = ((((a['w'] as num?)?.toDouble() ?? 1) * sx).round());
    var h = ((((a['h'] as num?)?.toDouble() ?? 1) * sy).round());
    final needOrig =
        img == null || w < 16 || x >= (img.width) || y >= (img.height);
    if (needOrig && orig.isNotEmpty) {
      final origImg = im.decodeImage(File(orig).readAsBytesSync());
      // HEIC/RAW 等原片可能无法由 image 包解码。增强失败时必须保留已经
      // 成功解码的缩略图，不能把可用 img 覆盖成 null 后永久返回灰图。
      if (origImg != null) {
        img = origImg;
        sx = 1;
        sy = 1;
        x = (a['x'] as num?)?.toInt() ?? 0;
        y = (a['y'] as num?)?.toInt() ?? 0;
        w = (a['w'] as num?)?.toInt() ?? 1;
        h = (a['h'] as num?)?.toInt() ?? 1;
      }
    }
    if (img == null) return false;
    w = w.clamp(1, img.width);
    h = h.clamp(1, img.height);
    final mrg = (w > h ? w : h) * 35 ~/ 100;
    final left = (x - mrg).clamp(0, img.width - 1);
    final top = (y - mrg).clamp(0, img.height - 1);
    final right = (x + w + mrg).clamp(left + 1, img.width);
    final bottom = (y + h + mrg).clamp(top + 1, img.height);
    var crop = im.copyCrop(
      img,
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
    crop = im.copyResize(crop, width: 240, height: 240);
    File(out).writeAsBytesSync(im.encodeJpg(crop, quality: 82));
    return File(out).lengthSync() > 40;
  } catch (_) {
    return false;
  }
}

int? firstInt(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) return null;
  final v = rows.first.values.first;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return null;
}

/// 解析 Range 的结果：null = 头不合法/多段，按整文件 200；
/// invalid = 越界/空后缀，应回 416；否则 start/end 已按文件长度截好。
class RangeResult {
  const RangeResult(this.start, this.end);
  const RangeResult.invalid() : start = -1, end = -1;
  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is RangeResult && other.start == start && other.end == end;

  @override
  int get hashCode => start * 31 + end;
}

RangeResult? parseRangeHeader(String header, int len) {
  final spec = header.substring(6).split(',')[0].trim();
  final m = RegExp(r'^(\d*)-(\d*)$').firstMatch(spec);
  if (m == null || (m[1]!.isEmpty && m[2]!.isEmpty)) return null;
  int start;
  int end;
  if (m[1]!.isEmpty) {
    final n = int.tryParse(m[2]!) ?? 0;
    if (n <= 0 || len == 0) return const RangeResult.invalid();
    start = len > n ? len - n : 0;
    end = len - 1;
  } else {
    start = int.tryParse(m[1]!) ?? -1;
    if (start < 0) return null;
    end = m[2]!.isNotEmpty ? (int.tryParse(m[2]!) ?? len - 1) : len - 1;
    if (end >= len) end = len - 1; // 超界按规范截到末尾
  }
  if (start > end || start >= len) return const RangeResult.invalid();
  return RangeResult(start, end);
}

class _Part {
  _Part({this.name, this.filename, this.bytes});
  final String? name;
  final String? filename;
  final Uint8List? bytes;
}

List<_Part> _parseMultipart(Uint8List data, String boundary) {
  final sep = utf8.encode('--$boundary');
  final out = <_Part>[];
  var i = 0;
  while (true) {
    final start = _indexOf(data, sep, i);
    if (start < 0) break;
    var from = start + sep.length;
    if (from + 1 < data.length && data[from] == 13) from += 2; // \r\n
    if (from < data.length && data[from] == 45) break; // --
    final next = _indexOf(data, sep, from);
    if (next < 0) break;
    var chunk = data.sublist(from, next);
    if (chunk.length >= 2 && chunk[chunk.length - 2] == 13) {
      chunk = chunk.sublist(0, chunk.length - 2);
    }
    final split = _indexOf(chunk, utf8.encode('\r\n\r\n'), 0);
    if (split >= 0) {
      final head = utf8.decode(chunk.sublist(0, split), allowMalformed: true);
      final body = chunk.sublist(split + 4);
      final name = RegExp(r'name="([^"]+)"').firstMatch(head)?.group(1);
      final filename = RegExp(r'filename="([^"]*)"').firstMatch(head)?.group(1);
      out.add(
        _Part(name: name, filename: filename, bytes: Uint8List.fromList(body)),
      );
    }
    i = next;
  }
  return out;
}

int _indexOf(Uint8List data, List<int> pat, int from) {
  if (pat.isEmpty) return from;
  outer:
  for (var i = from; i <= data.length - pat.length; i++) {
    for (var j = 0; j < pat.length; j++) {
      if (data[i + j] != pat[j]) continue outer;
    }
    return i;
  }
  return -1;
}
