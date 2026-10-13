/// 团图 API 客户端：与手机盒子上的 FastAPI 服务通信。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ios_box_endpoint.dart';

import 'upload_prep.dart';
import 'network_recovery.dart';
import 'resumable_download.dart';
export 'network_recovery.dart';

class CardItem {
  final int id;
  final String thumb, kind, ext, origName, uploader;
  final String? avatar;
  final int? uploaderId;
  final bool hasThumb, mine, hasLive, liveReady;
  final int? livePts;
  bool liked;
  int likes;
  int commentCount;
  final int width, height;
  final double? duration;
  final int? takenAt;
  final double? createdAt;

  CardItem(Map<String, dynamic> j)
      : id = j['id'],
        thumb = j['thumb'],
        kind = j['kind'] ?? 'image',
        ext = (j['ext'] ?? '').toString(),
        origName = (j['orig_name'] ?? '').toString(),
        hasThumb = (j['has_thumb'] ?? 0) == 1,
        uploader = (j['uploader'] ?? '?').toString(),
        uploaderId = (j['uploader_id'] as num?)?.toInt(),
        avatar = j['avatar']?.toString(),
        liked = j['liked'] == true || j['liked'] == 1,
        mine = j['mine'] == true || j['mine'] == 1,
        width = (j['width'] ?? 0) as int,
        height = (j['height'] ?? 0) as int,
        likes = (j['likes'] ?? 0) as int,
        commentCount = (j['comments'] ?? 0) as int,
        duration = (j['duration'] as num?)?.toDouble(),
        takenAt = _looseInt(j['taken_at']) ?? _looseInt(j['created_at']),
        createdAt = _looseDouble(j['created_at']),
        hasLive = j['has_live'] == true || j['has_live'] == 1,
        liveReady = j.containsKey('live_ready')
            ? (j['live_ready'] == true || j['live_ready'] == 1)
            : (j['has_live'] == true || j['has_live'] == 1),
        livePts = (j['live_pts'] as num?)?.toInt();

  String? get avatarUrl {
    final a = avatar;
    if (a == null || a.isEmpty) return null;
    if (a.startsWith('http')) return a;
    return '${Api.I.base}$a';
  }

  bool get isOwn {
    if (mine) return true;
    final uid = Api.I.userId;
    return uid != null && uploaderId == uid;
  }

  bool get isRaw => const [
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
      ].contains(ext.toLowerCase());

  /// 视频即使库里还没标 has_thumb，也去拉封面（盒子会现抽一帧）。
  bool get wantThumb => hasThumb || kind == 'video';
}

class PersonItem {
  final int id, count;
  final String? name, cover;
  final bool claimedByMe;

  PersonItem(Map<String, dynamic> j)
      : id = j['id'],
        count = j['count'] ?? 0,
        name = j['name'],
        cover = j['cover'],
        claimedByMe = j['claimed_by_me'] == true;
}

class Api {
  Api._();
  static final Api I = Api._();

  static bool iosRecoveryEnabled = Platform.isIOS;
  static IosBoxEndpoint endpointResolver = IosBoxEndpoint.I;
  static final endpointChanges = ValueNotifier<int>(0);
  Future<bool>? _recovering;

  static Future<String> addressForJoin(String base) async {
    if (!iosRecoveryEnabled) return base;
    return await endpointResolver.resolve(base) ?? base;
  }

  /// Re-address only the same box and session. Never replay a write or join
  /// another identity. Concurrent failures share a single recovery request.
  Future<bool> recoverConnection() {
    final host = Uri.tryParse(base)?.host.toLowerCase();
    final local = host == 'localhost' ||
        host == '::1' ||
        (host != null && host.startsWith('127.'));
    if (!iosRecoveryEnabled || local || boxId == null || token == null) {
      return Future.value(false);
    }
    if (_recovering != null) return _recovering!;
    late Future<bool> request;
    request = _recoverConnection().whenComplete(() {
      if (identical(_recovering, request)) _recovering = null;
    });
    _recovering = request;
    return request;
  }

  Future<bool> _recoverConnection() async {
    final oldClient = _dio;
    final oldBase = base;
    final oldToken = token;
    final oldBox = boxId;
    final next = await endpointResolver.resolve(oldBase, boxId: oldBox);
    if (!identical(_dio, oldClient) ||
        base != oldBase ||
        token != oldToken ||
        boxId != oldBox) {
      return false;
    }
    if (next == null ||
        !await sessionValid(next, oldToken, expectedBoxId: oldBox)) {
      return false;
    }
    if (!identical(_dio, oldClient) ||
        base != oldBase ||
        token != oldToken ||
        boxId != oldBox) {
      return false;
    }
    // configure() would erase identity and cancel unrelated in-flight work.
    base = next;
    dio.options.baseUrl = next;
    final prefs = await SharedPreferences.getInstance();
    if (!identical(_dio, oldClient) || base != next || token != oldToken) {
      return false;
    }
    await prefs.setString('base', next);
    if (oldBox != null) await prefs.setString('box_id', oldBox);
    endpointChanges.value++;
    return true;
  }

  Dio? _dio;
  Dio get dio => _dio ?? (throw StateError('Api.configure 尚未调用'));
  String base = '';
  String? token;
  String name = '';
  int? userId;

  /// 当前盒子身份。旧盒子没有 /api/status.box_id 时为 null。
  String? boxId;

  /// 加入/点赞/评论/认领等交互。测试可缩短，用来覆盖「已连上但不回包」。
  static Duration interactiveTimeout = const Duration(seconds: 8);

  /// 列表/资料 GET。重试次数另算，避免叠成几分钟。
  static Duration listTimeout = const Duration(seconds: 12);
  static int listAttempts = 2;

  /// 401（会话失效）时的全局回调，由 main.dart 注册跳转连接页。
  void Function()? onAuthFailed;
  bool _authFiring = false;

  /// 初始化：base 形如 http://192.168.50.42:8000
  void configure(String baseUrl, String? token_) {
    final previous = _dio;
    base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    token = token_;
    userId = null;
    boxId = null;
    _authFiring = false;
    final next = Dio(
      BaseOptions(
        baseUrl: base,
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(minutes: 10),
        sendTimeout: const Duration(minutes: 30),
        persistentConnection: true,
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    // 盒子用自签证书，局域网工具直接信任
    (next.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final c = HttpClient();
      c.badCertificateCallback = (cert, host, port) => true;
      c.idleTimeout = const Duration(seconds: 25);
      c.maxConnectionsPerHost = 8;
      return c;
    };
    next.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          if (token != null) o.headers['X-Token'] = token;
          h.next(o);
        },
        onError: (error, handler) async {
          if (iosRecoveryEnabled &&
              error.requestOptions.method == 'GET' &&
              transientNet(error) &&
              identical(_dio, next)) {
            try {
              await recoverConnection();
            } catch (_) {}
          }
          handler.next(error);
        },
      ),
    );
    _dio = next;
    // 切换盒子/会话时，旧连接池里的 keep-alive socket 和在途请求都已经
    // 属于旧身份。显式关闭，避免反复加入或重连后持续占用局域网连接资源。
    previous?.close(force: true);
  }

  /// 列表/资料类 GET：短超时 + 网络重试。全局 10 分钟接收超时只该留给
  /// 上传/下载大文件，列表卡 10 分钟会把页面刷新锁死。
  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, dynamic>? q,
    CancelToken? cancelToken,
  ]) async {
    final r = await retryNet(
      () => dio.get(
        path,
        queryParameters: q,
        cancelToken: cancelToken,
        options: Options(receiveTimeout: listTimeout, sendTimeout: listTimeout),
      ),
      attempts: listAttempts,
      cancelToken: cancelToken,
    );
    _throwIfBad(r);
    return Map<String, dynamic>.from(r.data as Map);
  }

  Future<Map<String, dynamic>> _post(String path, [Object? body]) async {
    final r = await dio.post(
      path,
      data: body,
      options: Options(
        receiveTimeout: interactiveTimeout,
        sendTimeout: interactiveTimeout,
      ),
    );
    _throwIfBad(r);
    return Map<String, dynamic>.from(r.data as Map);
  }

  void _throwIfBad(Response r) {
    if (r.statusCode == null || r.statusCode! < 400) return;
    final d = r.data;
    final detail =
        (d is Map && d['detail'] != null) ? d['detail'].toString() : null;
    if (r.statusCode == 401) {
      _fireAuthFailed();
      throw '登录已失效，请重新加入';
    }
    if (r.statusCode == 404 && (detail == null || detail == 'Not Found')) {
      throw '盒子还是旧版，请先更新盒子上的服务';
    }
    throw detail ?? '请求失败';
  }

  void _fireAuthFailed() {
    if (_authFiring) return;
    _authFiring = true;
    scheduleMicrotask(() {
      _authFiring = false;
      onAuthFailed?.call();
    });
  }

  /// 加入房间，返回错误信息或 null（成功）
  Future<String?> join(
    String base_,
    String name_,
    String code, {
    String? deviceId,
  }) async {
    configure(base_, null);
    try {
      final r = await dio.post(
        '/api/join',
        data: {
          'name': name_,
          'code': code,
          if (deviceId != null && deviceId.isNotEmpty) 'device_id': deviceId,
        },
        options: Options(
          validateStatus: (s) => s! < 500,
          receiveTimeout: interactiveTimeout,
          sendTimeout: interactiveTimeout,
        ),
      );
      if (r.statusCode == 200) {
        final d = Map<String, dynamic>.from(r.data as Map);
        token = d['token'] as String;
        name = (d['name']?.toString().trim().isNotEmpty ?? false)
            ? d['name'].toString()
            : name_;
        final joinBox = d['box_id']?.toString().trim();
        if (joinBox != null && joinBox.isNotEmpty) {
          boxId = joinBox;
        } else {
          await refreshBoxIdentity();
        }
        return null;
      }
      final d = r.data;
      if (d is Map && d['detail'] != null) return d['detail'].toString();
      return '加入失败 (${r.statusCode})';
    } catch (e) {
      return '连不上盒子：${e.toString().split('\n').first}';
    }
  }

  Future<Map<String, dynamic>> me() async {
    final d = await _get('/api/me');
    userId = (d['id'] as num?)?.toInt();
    final n = d['name']?.toString();
    if (n != null && n.isNotEmpty) name = n;
    return d;
  }

  Future<List<Map<String, dynamic>>> users() async {
    final d = await _get('/api/users');
    return [
      for (final e in (d['items'] as List? ?? const []))
        if (e is Map) Map<String, dynamic>.from(e),
    ];
  }

  Future<Map<String, dynamic>> status() => _get('/api/status');

  /// 从 /api/status 读取盒子身份。旧盒子没有该字段时保持 null。
  Future<void> refreshBoxIdentity() async {
    final client = _dio;
    try {
      final s = await status();
      if (!identical(client, _dio)) return;
      final id = s['box_id']?.toString().trim();
      boxId = (id == null || id.isEmpty) ? null : id;
      if (iosRecoveryEnabled && boxId != null) {
        final currentBase = base;
        final currentBox = boxId!;
        final prefs = await SharedPreferences.getInstance();
        if (base == currentBase && boxId == currentBox) {
          await prefs.setString('box_id', currentBox);
        }
      }
    } catch (_) {}
  }

  /// 探测目标地址当前的 box_id。旧盒子或非团图服务返回 null。
  static Future<String?> peekBoxId(String base) async {
    final d = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    (d.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final c = HttpClient();
      c.badCertificateCallback = (cert, host, port) => true;
      return c;
    };
    try {
      final r = await d.get('$base/api/status');
      if (r.statusCode != 200) return null;
      var data = r.data;
      if (data is String) {
        try {
          data = jsonDecode(data);
        } catch (_) {
          return null;
        }
      }
      if (data is! Map) return null;
      if (!_isBoxStatus(data)) return null;
      final id = data['box_id']?.toString().trim();
      if (id == null || id.isEmpty) return null;
      return id;
    } finally {
      d.close(force: true);
    }
  }

  /// 自己的作品。旧盒子没有该接口时，从全部相册里筛 mine=true。
  Future<Map<String, dynamic>> myAssets({
    String sort = 'time',
    int offset = 0,
    int limit = 90,
    double? cursor,
    int? cursorId,
  }) async {
    final r = await retryNet(
      () => dio.get(
        '/api/me/assets',
        queryParameters: {'sort': sort, 'offset': offset, 'limit': limit},
        options: Options(receiveTimeout: listTimeout, sendTimeout: listTimeout),
      ),
      attempts: listAttempts,
    );
    if (r.statusCode == 404) {
      final g = await gallery(
        'all',
        cursor: cursor,
        cursorId: cursorId,
        limit: limit,
      );
      final raw = (g['items'] as List?) ?? const [];
      final items = [
        for (final e in raw)
          if (e is Map && (e['mine'] == true || e['mine'] == 1)) e,
      ];
      return {
        'items': items,
        'cursor': g['cursor'],
        'cursor_id': g['cursor_id'],
        'end': raw.length < limit,
        'legacy': true,
      };
    }
    _throwIfBad(r);
    return Map<String, dynamic>.from(r.data as Map);
  }

  Future<Map<String, dynamic>> userProfile(int uid) async {
    final r = await retryNet(
      () => dio.get(
        '/api/user/$uid',
        options: Options(receiveTimeout: listTimeout, sendTimeout: listTimeout),
      ),
      attempts: listAttempts,
    );
    if (r.statusCode == 404) {
      final d = r.data;
      if (d is Map && d['detail'] == '没有这个人') _throwIfBad(r);
      return {
        'id': uid,
        'name': '',
        'uploaded': 0,
        'last_upload': null,
        'avatar': null,
        'legacy': true,
      };
    }
    _throwIfBad(r);
    return Map<String, dynamic>.from(r.data as Map);
  }

  Future<Map<String, dynamic>> userAssets(
    int uid, {
    String sort = 'time',
    int offset = 0,
    int limit = 90,
    double? cursor,
    int? cursorId,
  }) async {
    final r = await retryNet(
      () => dio.get(
        '/api/user/$uid/assets',
        queryParameters: {'sort': sort, 'offset': offset, 'limit': limit},
        options: Options(receiveTimeout: listTimeout, sendTimeout: listTimeout),
      ),
      attempts: listAttempts,
    );
    if (r.statusCode == 404) {
      final err = r.data;
      if (err is Map && err['detail'] == '没有这个人') _throwIfBad(r);
      final g = await gallery(
        'all',
        cursor: cursor,
        cursorId: cursorId,
        limit: limit,
      );
      final raw = (g['items'] as List?) ?? const [];
      final items = [
        for (final e in raw)
          if (e is Map && (e['uploader_id'] as num?)?.toInt() == uid) e,
      ];
      return {
        'items': items,
        'cursor': g['cursor'],
        'cursor_id': g['cursor_id'],
        'end': raw.length < limit,
        'legacy': true,
      };
    }
    _throwIfBad(r);
    return Map<String, dynamic>.from(r.data as Map);
  }

  /// 当前登录作者还在库里的作品「文件名|拍摄日」。已删除的不在其中。
  Future<Set<String>> uploadKeys() async {
    try {
      final d = await _get('/api/me/upload_index');
      final list = (d['items'] as List?) ?? const [];
      return {
        for (final e in list)
          if (e is Map)
            uploadKey(
              (e['name'] ?? '').toString(),
              (e['day'] ?? '').toString(),
            ),
      };
    } catch (_) {
      return {};
    }
  }

  Future<Map<String, dynamic>> updateProfile(String name_) async {
    final r = await dio.post(
      '/api/me/profile',
      data: {'name': name_},
      options: Options(
        contentType: Headers.jsonContentType,
        receiveTimeout: interactiveTimeout,
        sendTimeout: interactiveTimeout,
      ),
    );
    _throwIfBad(r);
    final d = Map<String, dynamic>.from(r.data as Map);
    name = (d['name'] ?? name_).toString();
    return d;
  }

  Future<Map<String, dynamic>> updateAvatar(String path) async {
    final fd = FormData.fromMap({
      'file': await MultipartFile.fromFile(
        path,
        filename: path.split(Platform.pathSeparator).last,
      ),
    });
    final r = await dio.post(
      '/api/me/avatar',
      data: fd,
      options: Options(
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(minutes: 2),
      ),
    );
    _throwIfBad(r);
    return Map<String, dynamic>.from(r.data as Map);
  }

  Future<void> deleteAsset(int id) async {
    final r = await dio.delete(
      '/api/asset/$id',
      options: Options(
        receiveTimeout: interactiveTimeout,
        sendTimeout: interactiveTimeout,
      ),
    );
    _throwIfBad(r);
  }

  Future<Map<String, dynamic>> deal(String view) async =>
      _get('/api/deal', {'view': view});

  Future<void> decide(int assetId, String action, int batchNo, String view) =>
      _post('/api/decide', {
        'asset_id': assetId,
        'action': action,
        'batch_no': batchNo,
        'view': view,
      });

  Future<Map<String, dynamic>> like(int assetId, {bool? liked}) async => _post(
        '/api/like',
        {'asset_id': assetId, if (liked != null) 'liked': liked},
      );

  Future<void> markSeen(int assetId) async {
    try {
      await dio.post(
        '/api/seen',
        data: {'asset_id': assetId},
        options: Options(
          receiveTimeout: interactiveTimeout,
          sendTimeout: interactiveTimeout,
        ),
      );
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> comments(int assetId) async {
    final r = await retryNet(
      () => dio.get(
        '/api/asset/$assetId/comments',
        options: Options(receiveTimeout: listTimeout, sendTimeout: listTimeout),
      ),
      attempts: listAttempts,
    );
    final list = (r.data as Map)['comments'] as List? ?? const [];
    return [for (final e in list) Map<String, dynamic>.from(e as Map)];
  }

  Future<Map<String, dynamic>> addComment(int assetId, String body) async {
    final r = await dio.post(
      '/api/asset/$assetId/comments',
      data: {'body': body},
      options: Options(
        receiveTimeout: interactiveTimeout,
        sendTimeout: interactiveTimeout,
      ),
    );
    if (r.statusCode != null && r.statusCode! >= 400) {
      final d = r.data;
      throw (d is Map && d['detail'] != null) ? d['detail'].toString() : '发送失败';
    }
    return Map<String, dynamic>.from(r.data as Map);
  }

  Future<Map<String, dynamic>> confirmBatch(int batchNo, String view) =>
      _post('/api/batch/$batchNo/confirm?view=$view');

  Future<Map<String, dynamic>> galleryHome() => _get('/api/gallery/home');

  Future<Map<String, dynamic>> gallery(
    String view, {
    double? cursor,
    int? cursorId,
    int limit = 90,
    String? sort,
    int? offset,
    int? seed,
    Iterable<int>? excludeIds,
  }) =>
      _get('/api/gallery', {
        'view': view,
        'limit': limit,
        if (cursor != null) 'cursor': cursor,
        if (cursorId != null) 'cursor_id': cursorId,
        if (sort != null) 'sort': sort,
        if (offset != null) 'offset': offset,
        if (seed != null) 'seed': seed,
        if (excludeIds != null && excludeIds.isNotEmpty)
          'exclude': excludeIds.join(','),
      });

  Future<Map<String, dynamic>> assetDetail(int id) =>
      _get('/api/asset/$id/detail');
  Future<List<dynamic>> persons() async {
    final r = await retryNet(
      () => dio.get(
        '/api/persons',
        options: Options(receiveTimeout: listTimeout, sendTimeout: listTimeout),
      ),
      attempts: listAttempts,
    );
    return (r.data as List).toList();
  }

  /// 一对一认领。返回 {'ok': true} 或 {'conflict': {...}}（服务端 409）。
  /// [confirm] 携带确认框展示过的 [expectMyPerson]/[expectPersonUser]
  /// （无认领用 -1），期间状态被别人改过时服务端再退回最新 conflict。
  Future<Map<String, dynamic>> claim(
    int pid, {
    bool confirm = false,
    int? expectMyPerson,
    int? expectPersonUser,
  }) async {
    final r = await dio.post(
      '/api/persons/$pid/claim',
      data: {
        if (confirm) 'confirm': true,
        if (confirm) 'expect_my_person': expectMyPerson ?? -1,
        if (confirm) 'expect_person_user': expectPersonUser ?? -1,
      },
      options: Options(
        receiveTimeout: interactiveTimeout,
        sendTimeout: interactiveTimeout,
      ),
    );
    final d = r.data is Map
        ? Map<String, dynamic>.from(r.data as Map)
        : <String, dynamic>{};
    if (r.statusCode == 409 && d['conflict'] != null) return d;
    _throwIfBad(r);
    return d;
  }

  Future<void> unclaim(int pid) => _post('/api/persons/$pid/unclaim');

  /// 团员标记：0=未标记 1=团员 2=非团员。
  Future<void> setPersonMember(int pid, int status) =>
      _post('/api/persons/$pid/member', {'status': status});

  /// 批量设置团员标记。旧盒子没有批量接口时逐个提交，保持新客户端可用。
  Future<void> setPersonsMember(Iterable<int> personIds, int status) async {
    final ids = personIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    if (ids.length == 1) return setPersonMember(ids.single, status);
    final r = await dio.post(
      '/api/persons/members',
      data: {'ids': ids, 'status': status},
      options: Options(
        receiveTimeout: interactiveTimeout,
        sendTimeout: interactiveTimeout,
      ),
    );
    final detail = r.data is Map ? (r.data as Map)['detail']?.toString() : null;
    if (r.statusCode == 404 && (detail == null || detail == 'Not Found')) {
      for (final id in ids) {
        await setPersonMember(id, status);
      }
      return;
    }
    _throwIfBad(r);
  }

  Future<void> renamePerson(int pid, String name) =>
      _post('/api/persons/$pid/rename', {'name': name});

  /// 从该人物的一张照片（或指定脸）裁封面。
  Future<Map<String, dynamic>> setPersonCover(
    int pid, {
    int? assetId,
    int? faceId,
  }) async {
    final r = await dio.post(
      '/api/persons/$pid/cover',
      data: {
        if (assetId != null) 'asset_id': assetId,
        if (faceId != null) 'face_id': faceId,
      },
      options: Options(
        receiveTimeout: interactiveTimeout,
        sendTimeout: interactiveTimeout,
      ),
    );
    _throwIfBad(r);
    final d = r.data;
    return d is Map
        ? Map<String, dynamic>.from(d)
        : <String, dynamic>{'ok': true};
  }

  /// 合并人物。不同账号的认领撞上时返回 409 conflict，由调用方选
  /// [keepClaimUser]（用户 id）或 'none'（全部取消）后重试。
  Future<Map<String, dynamic>> mergePersons(
    List<int> ids, {
    Object? keepClaimUser,
  }) async {
    final r = await dio.post(
      '/api/persons/merge',
      data: {
        'ids': ids,
        if (keepClaimUser != null) 'keep_claim_user': keepClaimUser,
      },
      options: Options(
        receiveTimeout: interactiveTimeout,
        sendTimeout: interactiveTimeout,
      ),
    );
    final d = r.data is Map
        ? Map<String, dynamic>.from(r.data as Map)
        : <String, dynamic>{};
    if (r.statusCode == 409 && d['conflict'] != null) return d;
    _throwIfBad(r);
    return d;
  }

  /// 旅行报告数据快照（盒子端聚合）。时间参数见 report_policy.dart。
  Future<Map<String, dynamic>> reportData({
    required int fromW,
    required int toW,
    required int fromT,
    required int toT,
    int? person,
    CancelToken? cancelToken,
  }) =>
      _get(
          '/api/report/data',
          {
            'from_w': fromW,
            'to_w': toW,
            'from_t': fromT,
            'to_t': toT,
            if (person != null) 'person': person,
          },
          cancelToken);

  /// 当前账号的每日故事列表；日期按拍摄时间和旧数据回退策略归档。
  Future<Map<String, dynamic>> storyDays({
    required int offset,
    String? before,
    CancelToken? cancelToken,
  }) =>
      _storyGet(
          '/api/report/days',
          {
            'offset': offset,
            if (before != null) 'before': before,
          },
          cancelToken);

  Future<Map<String, dynamic>> storyData({
    required String day,
    required int offset,
    CancelToken? cancelToken,
  }) =>
      _storyGet(
          '/api/report/story',
          {
            'day': day,
            'offset': offset,
          },
          cancelToken);

  // Preserve structured claim/version/busy responses for the story UI. The
  // legacy _get helper intentionally reduces most HTTP errors to plain text.
  Future<Map<String, dynamic>> _storyGet(
    String path,
    Map<String, dynamic> query,
    CancelToken? token,
  ) async {
    final client = dio;
    for (var attempt = 0;; attempt++) {
      final response = await retryNet(
        () => client.get(
          path,
          queryParameters: query,
          cancelToken: token,
          options: Options(
            receiveTimeout: const Duration(seconds: 30),
            sendTimeout: listTimeout,
          ),
        ),
        attempts: listAttempts,
        cancelToken: token,
      );
      if (response.statusCode == 429 && attempt < 3) {
        await waitForNetworkRetry(
          networkRetryDelay(attempt + 1),
          cancelToken: token,
        );
        continue;
      }
      if (response.statusCode == 401) _throwIfBad(response);
      if ((response.statusCode ?? 500) >= 400) {
        throw DioException(
          requestOptions: response.requestOptions,
          response: response,
          type: DioExceptionType.badResponse,
        );
      }
      return Map<String, dynamic>.from(response.data as Map);
    }
  }

  /// 高清预览忙碌时重试，不把暂时降级的缩略图缓存成最终导出图。
  Future<List<int>> reportPreviewBytes(int id, CancelToken token) async {
    final client = dio;
    for (var attempt = 0;; attempt++) {
      final response = await retryNet(
        () => client.get<List<int>>(
          '/api/asset/$id/report-preview',
          cancelToken: token,
          options: Options(
            responseType: ResponseType.bytes,
            receiveTimeout: const Duration(seconds: 30),
            validateStatus: (_) => true,
          ),
        ),
        attempts: 2,
        cancelToken: token,
      );
      if ((response.statusCode == 503 || response.statusCode == 429) &&
          attempt < 3) {
        await waitForNetworkRetry(
          networkRetryDelay(attempt + 1),
          cancelToken: token,
        );
        continue;
      }
      if (response.statusCode == 404) {
        // 兼容没有 report-preview 的旧盒子，不对忙碌/断网静默降级。
        final fallback = await client.get<List<int>>(
          '/api/asset/$id/thumb',
          cancelToken: token,
          options: Options(
            responseType: ResponseType.bytes,
            receiveTimeout: const Duration(seconds: 20),
            validateStatus: (s) => s == 200,
          ),
        );
        return fallback.data!;
      }
      if (response.statusCode != 200) {
        throw DioException(
          requestOptions: response.requestOptions,
          response: response,
          type: DioExceptionType.badResponse,
        );
      }
      return response.data!;
    }
  }

  /// 盒子是否支持旧版旅行纪念卡。
  Future<bool> boxSupportsReport() async {
    try {
      final s = await status();
      final v = (s['report'] as num?)?.toInt() ?? 0;
      return v >= 1;
    } catch (_) {
      return false;
    }
  }

  /// 探测某地址是不是团图盒子（1.2 秒超时）。
  /// 光看 200 不够：必须是团图 /api/status 的 JSON，避免把随便一个网页当盒子。
  static Future<bool> probe(String base) async {
    final d = Dio(
      BaseOptions(
        connectTimeout: const Duration(milliseconds: 1200),
        receiveTimeout: const Duration(milliseconds: 1500),
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    (d.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final c = HttpClient();
      c.badCertificateCallback = (cert, host, port) => true;
      return c;
    };
    try {
      final r = await d.get('$base/api/status');
      if (r.statusCode != 200) return false;
      final data = r.data;
      if (data is Map) return _isBoxStatus(data);
      if (data is String) {
        try {
          final decoded = jsonDecode(data);
          return decoded is Map && _isBoxStatus(decoded);
        } catch (_) {
          return false;
        }
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      d.close(force: true);
    }
  }

  static bool _isBoxStatus(Map data) {
    if (data['service'] == 'tuantu') return true;
    // 兼容升级前的盒子，但不能只凭一个 total 把普通网页误认成盒子。
    return data.containsKey('total') &&
        data.containsKey('pending') &&
        data.containsKey('persons');
  }

  /// 探测 + 校验 token：服务在线且会话有效才算登录态。
  static Future<bool> sessionValid(String base, String? token,
      {String? expectedBoxId}) async {
    if (token == null || token.isEmpty) return false;
    final d = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 4),
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    (d.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final c = HttpClient();
      c.badCertificateCallback = (cert, host, port) => true;
      return c;
    };
    try {
      // 恢复已有会话不能沿用子网扫描的 1.2 秒快速淘汰策略。
      // 网络抖动重试一次；身份失效/不是团图则立即返回，不自动重发写操作。
      return await retryNet(() async {
        final status = await d.get('$base/api/status');
        var statusData = status.data;
        if (statusData is String) {
          try {
            statusData = jsonDecode(statusData);
          } catch (_) {
            return false;
          }
        }
        if (status.statusCode != 200 ||
            statusData is! Map ||
            !_isBoxStatus(statusData)) {
          return false;
        }
        if (expectedBoxId != null && statusData['box_id'] != expectedBoxId) {
          return false;
        }
        final r = await d.get('$base/api/me',
            options: Options(headers: {'X-Token': token}));
        if (r.statusCode != 200) return false;
        var data = r.data;
        if (data is String) {
          try {
            data = jsonDecode(data);
          } catch (_) {
            return false;
          }
        }
        return data is Map && data.containsKey('id');
      }, attempts: 2);
    } catch (_) {
      return false;
    } finally {
      d.close(force: true);
    }
  }

  /// 手动填的地址规范化：补 scheme 和默认端口 8000。返回 null 表示格式不对。
  static String? normalizeBase(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'http://$s';
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    final u = Uri.tryParse(s);
    if (u == null || !u.hasScheme || u.host.isEmpty) return null;
    // Dart 的 URI 解析很宽松（空格会被编码塞进 host），手工拦掉
    if (u.host.contains('%') || u.host.contains(' ')) return null;
    if (u.hasPort) return '${u.scheme}://${u.host}:${u.port}';
    return '${u.scheme}://${u.host}:8000';
  }

  Future<List<int>?> fetchLive(int assetId) async {
    try {
      final r = await dio.get<List<int>>(
        '/api/asset/$assetId/live',
        options: Options(responseType: ResponseType.bytes),
      );
      return r.data;
    } catch (_) {
      return null;
    }
  }

  Future<int> downloadLiveToFile(
    int assetId,
    String destPath, {
    void Function(double p)? onProgress,
    bool Function()? isCancelled,
  }) {
    return _downloadToFile(
      '/api/asset/$assetId/live',
      destPath,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  /// 下载原图字节（保存到相册用）
  Future<List<int>> fetchRaw(int assetId) async {
    final r = await retryNet(
      () => dio.get<List<int>>(
        '/api/asset/$assetId/raw',
        options: Options(responseType: ResponseType.bytes),
      ),
    );
    return r.data!;
  }

  /// 流式下载原图到文件：大视频保存不再把整片驻留内存。
  /// 返回下载的字节数；[onProgress] 0~1（拿不到总长时为 -1 增量字节）。
  /// [isCancelled] 每块检查，置 true 即中止并删除半成品。
  Future<int> downloadRawToFile(
    int assetId,
    String destPath, {
    void Function(double p)? onProgress,
    bool Function()? isCancelled,
  }) {
    return _downloadToFile(
      '/api/asset/$assetId/raw',
      destPath,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  Future<int> _downloadToFile(
    String path,
    String destPath, {
    void Function(double p)? onProgress,
    bool Function()? isCancelled,
  }) async {
    return resumableDownload(
      dio,
      path,
      destPath,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  /// 多文件上传，onProgress 0~1。
  /// FormData 只能用一次：每次（重）发送都要新建，否则 Dio 报 already finalized。
  Future<Map<String, dynamic>> uploadFiles(
    List<String> paths,
    void Function(double) onProgress, {
    String? livePath,
    Map<String, dynamic> extraFields = const {},
    String? previewPath,
    int? asUserId,
    String? filename,
  }) {
    return uploadFilesTo(
      base,
      token ?? '',
      paths,
      onProgress,
      livePath: livePath,
      extraFields: extraFields,
      previewPath: previewPath,
      asUserId: asUserId,
      filename: filename,
      client: dio,
      fireAuthFailed: true,
    );
  }

  /// 发到指定盒子。默认新建短生命周期客户端，避免跟随 [Api.I] 会话切换。
  /// [fireAuthFailed] 仅当前会话上传为 true；绑定任务的重试不能把用户踢下当前盒子。
  static Future<Map<String, dynamic>> uploadFilesTo(
    String base,
    String token,
    List<String> paths,
    void Function(double) onProgress, {
    String? livePath,
    Map<String, dynamic> extraFields = const {},
    String? previewPath,
    int? asUserId,
    String? filename,
    Dio? client,
    bool fireAuthFailed = false,
    int attempts = 3,
  }) async {
    Future<FormData> build() async {
      final list = <MultipartFile>[];
      for (final p in paths) {
        list.add(
          await MultipartFile.fromFile(
            p,
            filename: filename ?? p.split(Platform.pathSeparator).last,
          ),
        );
      }
      final map = <String, dynamic>{'files': list};
      if (livePath != null && livePath.isNotEmpty) {
        map['live'] = await MultipartFile.fromFile(
          livePath,
          filename: livePath.split(Platform.pathSeparator).last,
        );
      }
      if (previewPath != null && previewPath.isNotEmpty) {
        map['preview'] = await MultipartFile.fromFile(
          previewPath,
          filename: previewPath.split(Platform.pathSeparator).last,
        );
      }
      map.addAll(extraFields);
      return FormData.fromMap(map);
    }

    final owned = client == null;
    final d = client ?? createUploadClient(base);
    try {
      final r = await retryNet(() async {
        final fd = await build();
        return d.post(
          owned ? '/api/upload' : '/api/upload',
          data: fd,
          options: Options(
            sendTimeout: const Duration(minutes: 60),
            headers: {
              if (token.isNotEmpty) 'X-Token': token,
              if (asUserId != null) 'X-Tuantu-Import-User': '$asUserId',
            },
          ),
          onSendProgress: (sent, total) => onProgress(sent / total),
        );
      }, attempts: attempts);
      if (r.statusCode != null && r.statusCode! >= 400) {
        final data = r.data;
        if (r.statusCode == 401) {
          if (fireAuthFailed) Api.I._fireAuthFailed();
          throw fireAuthFailed ? '登录已失效，请重新加入' : '目标盒子登录已失效，请重新加入后再传';
        }
        throw (data is Map && data['detail'] != null)
            ? data['detail'].toString()
            : '上传失败';
      }
      return Map<String, dynamic>.from(r.data as Map);
    } finally {
      if (owned) d.close(force: true);
    }
  }

  /// 批量上传复用的客户端。调用方在整批完成后统一 close，
  /// 避免每张照片都重新建立 TCP 连接。
  static Dio createUploadClient(String base) {
    final d = Dio(
      BaseOptions(
        baseUrl: base.endsWith('/') ? base.substring(0, base.length - 1) : base,
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(minutes: 10),
        sendTimeout: const Duration(minutes: 60),
        persistentConnection: true,
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    (d.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final c = HttpClient();
      c.badCertificateCallback = (cert, host, port) => true;
      c.idleTimeout = const Duration(seconds: 25);
      c.maxConnectionsPerHost = 8;
      return c;
    };
    return d;
  }
}

/// taken_at 存的是「相机本地时间按 UTC 解释」，用 UTC 系列方法还原墙钟时间
String fmtTime(int? t) {
  final d = plausibleWallClock(t);
  if (d == null) return '';
  String p(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
}

/// 拍摄日分组键 `yyyy-MM-dd`（UTC 墙钟）。
///
/// 教训：相机没设时钟时 EXIF 是 `0000:00:00 00:00:00`，盒子存成公元前的
/// 负秒数；年份不足 4 位时 `DateTime.parse` 解析失败，相册日期分组在
/// release 下变成一整块灰色 ErrorWidget（10 万像素高），盖住后面的照片。
/// 不合理的时间一律归到「时间未知」。
String dayKey(int? t) {
  final d = plausibleWallClock(t);
  if (d == null) return 'unknown';
  String p(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${p(d.month)}-${p(d.day)}';
}

/// 拍摄时间（秒，UTC 墙钟）→ DateTime；缺失、0、超出 DateTime 范围
/// （±8.64e12 秒，否则抛 RangeError）或年份不在 1900–9999 的都当作未知。
DateTime? plausibleWallClock(num? t) {
  if (t == null || t == 0 || !t.isFinite || t.abs() > 8640000000000) {
    return null;
  }
  final d =
      DateTime.fromMillisecondsSinceEpoch((t * 1000).round(), isUtc: true);
  if (d.year < 1900 || d.year > 9999) return null;
  return d;
}

/// 盒子字段可能是 num、数字字符串或空串；解析不了当作缺失。
int? _looseInt(Object? v) {
  if (v is num) return v.isFinite ? v.toInt() : null;
  if (v is String) {
    final n = num.tryParse(v.trim());
    return n != null && n.isFinite ? n.toInt() : null;
  }
  return null;
}

double? _looseDouble(Object? v) {
  if (v is num) return v.isFinite ? v.toDouble() : null;
  if (v is String) {
    final n = double.tryParse(v.trim());
    return n != null && n.isFinite ? n : null;
  }
  return null;
}

/// 上次上传：本地墙钟，精确到分钟。
String fmtLastUpload(num? t) {
  if (plausibleWallClock(t) == null) return '';
  final d = DateTime.fromMillisecondsSinceEpoch((t! * 1000).round());
  String p(int n) => n.toString().padLeft(2, '0');
  return '${d.year}年${d.month}月${d.day}日 ${p(d.hour)}:${p(d.minute)}';
}
