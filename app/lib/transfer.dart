/// 本机传输记录：当前上传队列 + 历史，最新在前。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'card_reader.dart';
import 'gallery_refresh.dart';
import 'live_photo.dart';
import 'upload_prep.dart';
import 'upload_staging.dart';

class TransferJob {
  TransferJob({
    required this.id,
    required this.path,
    required this.name,
    required this.createdAt,
    this.status = '排队中',
    this.state = 'queued',
    this.err,
    this.assetId,
    this.progress = 0,
    this.day,
    this.livePath,
    this.liveRequired = false,
    this.previewPath,
    this.takenAt,
    this.sourceUri,
    this.stageId,
    this.uploaderId,
    this.uploaderName,
    this.boxId,
    this.targetBase,
    this.targetToken,
    this.sessionUserId,
    int? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  final String id;
  final String path;
  final String name;
  final String? day;
  final String? livePath;
  final bool liveRequired;
  final String? previewPath;
  final int? takenAt;
  final String? sourceUri;
  final String? stageId;
  final int? uploaderId;
  final String? uploaderName;
  final String? boxId;
  final String? targetBase;
  final String? targetToken;
  final int? sessionUserId;
  String status;
  String state; // queued / uploading / done / duplicate / rejected / failed
  String? err;
  int? assetId;
  double progress;
  final int createdAt;
  int updatedAt;

  bool get active => state == 'queued' || state == 'uploading';
  bool get failed => state == 'failed' || state == 'rejected';

  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'name': name,
        'status': status,
        'state': state,
        'err': err,
        'assetId': assetId,
        'progress': progress,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'day': day,
        // livePath/previewPath/takenAt 必须持久化：杀进程重启后重试才不会丢附件
        'livePath': livePath,
        'liveRequired': liveRequired,
        'previewPath': previewPath,
        'takenAt': takenAt,
        'sourceUri': sourceUri,
        'stageId': stageId,
        'uploaderId': uploaderId,
        'uploaderName': uploaderName,
        'boxId': boxId,
        'targetBase': targetBase,
        'targetToken': targetToken,
        'sessionUserId': sessionUserId,
      };

  factory TransferJob.fromJson(Map<String, dynamic> j) => TransferJob(
        id: (j['id'] ?? '').toString(),
        path: (j['path'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        status: (j['status'] ?? '').toString(),
        state: (j['state'] ?? 'done').toString(),
        err: j['err']?.toString(),
        assetId: (j['assetId'] as num?)?.toInt(),
        progress: (j['progress'] as num?)?.toDouble() ?? 0,
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (j['updatedAt'] as num?)?.toInt(),
        day: j['day']?.toString(),
        livePath: j['livePath']?.toString(),
        liveRequired: j['liveRequired'] == true ||
            ((j['livePath'] ?? '').toString().isNotEmpty),
        previewPath: j['previewPath']?.toString(),
        takenAt: (j['takenAt'] as num?)?.toInt(),
        sourceUri: j['sourceUri']?.toString(),
        stageId: j['stageId']?.toString(),
        uploaderId: (j['uploaderId'] as num?)?.toInt(),
        uploaderName: j['uploaderName']?.toString(),
        boxId: j['boxId']?.toString(),
        targetBase: j['targetBase']?.toString(),
        targetToken: j['targetToken']?.toString(),
        sessionUserId: (j['sessionUserId'] as num?)?.toInt(),
      );
}

/// 选图拿到的原始文件名优先；没有才回退到路径尾段。
/// 不覆盖实际文件路径：iOS 缓存名带资源 ID，只能当本地路径用。
String transferJobName({String? name, required String path}) {
  final n = name?.trim() ?? '';
  if (n.isNotEmpty) return n;
  if (path.isEmpty) return '';
  return path.split(RegExp(r'[\\/]')).last;
}

/// 任务能不能发到 [remoteBoxId] 这个盒子。地址相同不算同一个盒子。
/// 旧任务缺目标信息时拒绝发送，不能猜成当前盒子。
String? transferDestinationError({
  required TransferJob job,
  required String? remoteBoxId,
}) {
  final base = job.targetBase?.trim() ?? '';
  final token = job.targetToken?.trim() ?? '';
  if (base.isEmpty || token.isEmpty) {
    return '旧任务没有目标盒子信息，请重新加入后再选照片上传';
  }
  final jobBox = job.boxId?.trim() ?? '';
  final remote = remoteBoxId?.trim() ?? '';
  if (jobBox.isNotEmpty) {
    if (remote.isEmpty || remote != jobBox) {
      return '目标盒子已更换，未上传以免传错';
    }
  } else if (remote.isNotEmpty) {
    return '目标盒子已更换，未上传以免传错';
  }
  return null;
}

class TransferStore extends ChangeNotifier {
  TransferStore._();
  static final TransferStore I = TransferStore._();

  final List<TransferJob> jobs = [];
  bool running = false;
  bool _loaded = false;

  /// 测试可替换：查看目标盒子当前身份。
  Future<String?> Function(String base) peekBoxId = Api.peekBoxId;

  /// 测试可替换：真正发文件。默认发到任务绑定的盒子，不跟随 [Api.I]。
  Future<Map<String, dynamic>> Function(
    TransferJob job,
    String uploadPath, {
    String? live,
    String? preview,
    Map<String, dynamic> extra,
    int? asUserId,
  })? sendUpload;

  /// 同一批上传中的盒子身份结果短暂复用。超时或上传断线后重新探测，
  /// 既不每张照片新建连接，也不会长时间盲信旧 IP 上的盒子。
  static const _boxIdentityTtl = Duration(seconds: 10);
  final _boxIdentityCache = <String, ({String? id, DateTime checkedAt})>{};
  final _boxIdentityInflight = <String, Future<String?>>{};

  int get activeCount => jobs.where((j) => j.active).length;

  Set<String> get uploadedKeys => {
        for (final j in jobs)
          if ((j.state == 'done' || j.state == 'duplicate') &&
              j.day != null &&
              j.day!.isNotEmpty)
            uploadKey(j.name, j.day!),
      };

  List<TransferJob> get newestFirst {
    final copy = [...jobs];
    copy.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return copy;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! List) return;
      if (Platform.isIOS) {
        final storage = await _uploadStorage();
        for (final e in raw) {
          if (e is! Map || e['stageId'] is! String) continue;
          final id = e['stageId'] as String;
          if (!UploadStaging.validId(id)) continue;
          for (final key in ['path', 'livePath', 'previewPath']) {
            if (e[key] is String && (e[key] as String).isNotEmpty) {
              e[key] = storage.resolve(id, e[key]);
            }
          }
        }
      }
      jobs
        ..clear()
        ..addAll([
          for (final e in raw)
            if (e is Map) TransferJob.fromJson(Map<String, dynamic>.from(e)),
        ]);
      for (final j in jobs) {
        if (j.active || j.state == 'staging') {
          j.state = 'failed';
          j.status = '❌ 中断';
          j.err = '上次退出时未传完';
        }
      }
      notifyListeners();
    } catch (_) {}
  }

  TransferJob add(
    String path, {
    String? name,
    String? day,
    String? livePath,
    bool liveRequired = false,
    String? previewPath,
    int? takenAt,
    bool flush = true,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final resolved = transferJobName(name: name, path: path);
    final job = TransferJob(
      id: '$now-$resolved-${jobs.length}',
      path: path,
      name: resolved,
      createdAt: now,
      day: day,
      livePath: livePath,
      liveRequired: liveRequired,
      previewPath: previewPath,
      takenAt: takenAt,
      boxId: Api.I.boxId,
      targetBase: Api.I.base.isEmpty ? null : Api.I.base,
      targetToken: Api.I.token,
      sessionUserId: Api.I.userId,
    );
    jobs.add(job);
    if (flush) {
      trimHistory();
      notifyListeners();
      _persist();
    }
    return job;
  }

  /// 批量入队只通知和落盘一次，避免 300 张逐条重建整份历史。
  List<TransferJob> addAll(
    Iterable<
            ({
              String path,
              String? name,
              String? day,
              String? livePath,
              bool liveRequired,
              String? previewPath,
              int? takenAt,
            })>
        items,
  ) {
    final out = <TransferJob>[
      for (final m in items)
        add(
          m.path,
          name: m.name,
          day: m.day,
          livePath: m.livePath,
          liveRequired: m.liveRequired,
          previewPath: m.previewPath,
          takenAt: m.takenAt,
          flush: false,
        ),
    ];
    if (out.isEmpty) return out;
    trimHistory();
    notifyListeners();
    _persist();
    return out;
  }

  Future<UploadStaging> _uploadStorage() async {
    final support = await getApplicationSupportDirectory();
    return UploadStaging(Directory('${support.path}/UploadJobs'));
  }

  /// Capture destination before any file IO, and persist a complete owned copy
  /// before making jobs visible to the worker. iOS only; Android keeps addAll.
  Future<List<TransferJob>> addPersistent(List<PickedMedia> items) async {
    final now = DateTime.now().microsecondsSinceEpoch;
    final captured = [
      for (var i = 0; i < items.length; i++)
        TransferJob(
          id: '$now-$i',
          path: items[i].path,
          name: items[i].name,
          createdAt: now ~/ 1000,
          day: items[i].day,
          livePath: items[i].livePath,
          liveRequired: items[i].liveRequired,
          previewPath: items[i].previewPath,
          takenAt: items[i].takenAt,
          boxId: Api.I.boxId,
          targetBase: Api.I.base,
          targetToken: Api.I.token,
          sessionUserId: Api.I.userId,
        )
    ];
    final storage = await _uploadStorage();
    await const MethodChannel('dev.tuantu/live_photo')
        .invokeMethod<void>('excludeUploadBackup');
    final ready = <TransferJob>[];
    try {
      for (final j in captured) {
        ready.add(TransferJob.fromJson(await storage.copy(j.toJson())));
      }
      // "staging" prevents another worker from sending before durable enqueue.
      for (final j in ready) {
        j.state = 'staging';
      }
      jobs.addAll(ready);
      await _persist(strict: true);
      for (final j in ready) {
        j.state = 'queued';
      }
      trimHistory();
      unawaited(_persist());
      notifyListeners();
      return ready;
    } catch (_) {
      jobs.removeWhere(ready.contains);
      await _persist();
      for (final j in ready) {
        await storage.remove(j.stageId!);
      }
      rethrow;
    }
  }

  TransferJob addCard({
    required String uri,
    required String name,
    required String day,
    required int uploaderId,
    required String uploaderName,
    int? takenAt,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final job = TransferJob(
      id: '$now-card-${jobs.length}',
      path: '',
      name: name,
      createdAt: now,
      day: day,
      takenAt: takenAt,
      sourceUri: uri,
      uploaderId: uploaderId,
      uploaderName: uploaderName,
      status: '等待读取存储卡',
      boxId: Api.I.boxId,
      targetBase: Api.I.base.isEmpty ? null : Api.I.base,
      targetToken: Api.I.token,
      sessionUserId: Api.I.userId,
    );
    jobs.add(job);
    trimHistory();
    notifyListeners();
    _persist();
    return job;
  }

  Future<void> enqueue(List<String> paths) async {
    if (paths.isEmpty) return;
    for (final p in paths) {
      add(p);
    }
    await run();
  }

  Future<void> retryFailed() async {
    for (final j in jobs.where((j) => j.failed)) {
      j.err = null;
      j.state = 'queued';
      j.status = '排队中';
      j.progress = 0;
      j.updatedAt = DateTime.now().millisecondsSinceEpoch;
    }
    notifyListeners();
    await run();
  }

  Future<void> retry(TransferJob j) async {
    j.err = null;
    j.state = 'queued';
    j.status = '排队中';
    j.progress = 0;
    j.updatedAt = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
    await run();
  }

  Future<void> run() async {
    if (running) return;
    if (!jobs.any((j) => j.state == 'queued')) return;
    running = true;
    _boxIdentityCache.clear();
    _boxIdentityInflight.clear();
    notifyListeners();
    final uploadClients = <String, Dio>{};
    TransferJob? claim() {
      for (final j in jobs) {
        if (j.state == 'queued') {
          j.state = 'uploading';
          j.status = '上传中…';
          j.updatedAt = DateTime.now().millisecondsSinceEpoch;
          return j;
        }
      }
      return null;
    }

    Dio uploadClient(String base) =>
        uploadClients.putIfAbsent(base, () => Api.createUploadClient(base));

    Future<void> worker() async {
      while (true) {
        final j = claim();
        if (j == null) return;
        notifyListeners();
        await _uploadOne(
          j,
          uploadClient: sendUpload == null ? uploadClient : null,
        );
        notifyListeners();
        await _persist();
        if (Platform.isIOS &&
            j.stageId != null &&
            (j.state == 'done' || j.state == 'duplicate')) {
          // Keep source copies if history could not be persisted.
          try {
            await _persist(strict: true);
            await (await _uploadStorage()).remove(j.stageId!);
          } catch (_) {}
        }
      }
    }

    try {
      await Future.wait([for (var k = 0; k < 2; k++) worker()]);
    } finally {
      for (final client in uploadClients.values) {
        client.close(force: true);
      }
      _boxIdentityCache.clear();
      _boxIdentityInflight.clear();
      running = false;
      notifyListeners();
      await _persist();
    }
  }

  Future<void> _uploadOne(
    TransferJob j, {
    Dio Function(String base)? uploadClient,
  }) async {
    String uploadPath = j.path;
    File? staged;
    String? cardPreview;
    if (j.sourceUri != null) {
      try {
        j.status = '从存储卡读取…';
        notifyListeners();
        uploadPath = await CardReader.I.copyToCache(j.sourceUri!, j.name);
        staged = File(uploadPath);
        final ext = j.name.split('.').last.toLowerCase();
        if (!previewExts.contains(ext) && !isVideoName(j.name)) {
          cardPreview = await CardReader.I.thumbnail(j.sourceUri!);
        }
      } catch (e) {
        j.err = '读卡失败：${e.toString().split('\n').first}';
        j.state = 'failed';
        j.status = '❌ 请重新插卡';
        j.updatedAt = DateTime.now().millisecondsSinceEpoch;
        return;
      }
    }
    try {
      await _uploadPrepared(
        j,
        uploadPath,
        cardPreview: cardPreview,
        uploadClient: uploadClient,
      );
    } finally {
      try {
        if (staged != null && staged.existsSync()) staged.deleteSync();
      } catch (_) {}
    }
  }

  Future<void> _uploadPrepared(
    TransferJob j,
    String uploadPath, {
    String? cardPreview,
    Dio Function(String base)? uploadClient,
  }) async {
    if (Platform.isIOS &&
        (!await File(uploadPath).exists() ||
            await File(uploadPath).length() == 0)) {
      j.err = '原片已不可用，请回到上传页重新选择照片或视频';
      j.state = 'failed';
      j.status = '❌ 请重新选择';
      j.updatedAt = DateTime.now().millisecondsSinceEpoch;
      return;
    }
    // 恢复/重试前校验文件还在不在（缓存可能被系统清掉）
    String? live;
    if (j.livePath != null && j.livePath!.isNotEmpty) {
      final liveFile = File(j.livePath!);
      if (!liveVideoFileReady(liveFile)) {
        j.err = '动态部分丢失，请重新选择这张实况照片';
        j.state = 'failed';
        j.status = '❌ 实况不完整';
        j.updatedAt = DateTime.now().millisecondsSinceEpoch;
        return;
      }
      live = j.livePath;
    }
    if (j.liveRequired && live == null) {
      j.err = '动态部分丢失，请重新选择这张实况照片';
      j.state = 'failed';
      j.status = '❌ 实况不完整';
      j.updatedAt = DateTime.now().millisecondsSinceEpoch;
      return;
    }
    String? preview;
    if (j.previewPath != null && File(j.previewPath!).existsSync()) {
      preview = j.previewPath;
    }
    if (preview == null &&
        cardPreview != null &&
        File(cardPreview).existsSync()) {
      preview = cardPreview;
    }
    final extra = <String, dynamic>{};
    if (j.takenAt != null || live != null || j.liveRequired) {
      extra['meta'] = jsonEncode({
        j.name: {
          if (j.takenAt != null) 'taken_at': j.takenAt,
          if (live != null || j.liveRequired) 'live_required': true,
        },
      });
    }
    var boundBase = j.targetBase?.trim() ?? '';
    final boundToken = j.targetToken?.trim() ?? '';
    if (boundBase.isEmpty || boundToken.isEmpty) {
      j.err = '旧任务没有目标盒子信息，请重新加入后再选照片上传';
      j.state = 'failed';
      j.status = '❌ 目标不明';
      j.updatedAt = DateTime.now().millisecondsSinceEpoch;
      return;
    }
    Object? last;
    for (var i = 0; i < transferNetworkAttempts; i++) {
      try {
        if (Api.iosRecoveryEnabled && j.boxId != null) {
          // Keep the task's original identity/token across address changes.
          if (Api.I.boxId == j.boxId && Api.I.base.isNotEmpty) {
            boundBase = Api.I.base;
          }
          final host = Uri.tryParse(boundBase)?.host ?? '';
          if (i > 0 || host.endsWith('.local.') || host.endsWith('.local')) {
            boundBase =
                await Api.endpointResolver.resolve(boundBase, boxId: j.boxId) ??
                    boundBase;
          }
        }
        final remoteId = await _peekBoxIdentity(boundBase, force: i > 0);
        final destErr = transferDestinationError(job: j, remoteBoxId: remoteId);
        if (destErr != null) {
          j.err = destErr;
          j.state = 'failed';
          j.status = '❌ 目标盒子不匹配';
          j.updatedAt = DateTime.now().millisecondsSinceEpoch;
          return;
        }
        final send = sendUpload;
        final res = send != null
            ? await send(
                j,
                uploadPath,
                live: live,
                preview: preview,
                extra: extra,
                asUserId: j.uploaderId,
              )
            : await Api.uploadFilesTo(
                boundBase,
                boundToken,
                [uploadPath],
                (p) {
                  j.progress = p;
                  j.status = '上传中 ${(p * 100).toStringAsFixed(0)}%';
                  _notifyProgress();
                },
                livePath: live,
                previewPath: preview,
                extraFields: extra,
                asUserId: j.uploaderId,
                filename: j.name,
                client: uploadClient?.call(boundBase),
                attempts: 1, // 仅由任务层重试，避免 3 × 3 次整文件重传。
              );
        if ((res['accepted'] as List?)?.isNotEmpty == true) {
          final first = res['accepted'][0];
          if (live != null && first is Map && first['live_ready'] == false) {
            throw StateError('盒子未能保存动态部分，请重试');
          }
          if (first is Map) j.assetId = (first['id'] as num?)?.toInt();
          j.state = 'done';
          j.status = '✅ 已入库';
          j.err = null;
          j.progress = 1;
          j.updatedAt = DateTime.now().millisecondsSinceEpoch;
          notifyGalleryChanged();
          return;
        }
        if ((res['repaired'] as List?)?.isNotEmpty == true) {
          final first = res['repaired'][0];
          if (live != null && first is Map && first['live_ready'] == false) {
            throw StateError('盒子未能补全动态部分，请重试');
          }
          if (first is Map) j.assetId = (first['id'] as num?)?.toInt();
          j.state = 'done';
          j.status = '✅ 已补全';
          j.err = null;
          j.progress = 1;
          j.updatedAt = DateTime.now().millisecondsSinceEpoch;
          notifyGalleryChanged();
          return;
        }
        if ((res['duplicates'] as List?)?.isNotEmpty == true) {
          j.state = 'duplicate';
          j.status = '⏭️ 重复跳过';
          j.err = null;
          j.progress = 1;
          j.updatedAt = DateTime.now().millisecondsSinceEpoch;
          return;
        }
        final rejList = (res['rejected'] as List?) ?? const [];
        j.state = 'rejected';
        j.status =
            '🚫 ${rejList.isNotEmpty ? rejList.join('、') : '盒子没有接受这个文件'}';
        j.err = rejList.join('、');
        j.updatedAt = DateTime.now().millisecondsSinceEpoch;
        return;
      } catch (e) {
        last = e;
        if (!transientNet(e) || i == transferNetworkAttempts - 1) break;
        _boxIdentityCache.remove(boundBase);
        j.status = '信号不稳，等待重连 ${i + 1}/${transferNetworkAttempts - 1}…';
        notifyListeners();
        await waitForNetworkRetry(networkRetryDelay(i));
      }
    }
    j.err = last.toString().split('\n').first;
    j.state = 'failed';
    j.status = '❌ 失败';
    j.updatedAt = DateTime.now().millisecondsSinceEpoch;
  }

  Future<String?> _peekBoxIdentity(String base, {bool force = false}) {
    final now = DateTime.now();
    final cached = _boxIdentityCache[base];
    if (!force &&
        cached != null &&
        now.difference(cached.checkedAt) < _boxIdentityTtl) {
      return Future<String?>.value(cached.id);
    }
    final active = _boxIdentityInflight[base];
    if (active != null) return active;
    late final Future<String?> request;
    request = peekBoxId(base).then((id) {
      _boxIdentityCache[base] = (id: id, checkedAt: DateTime.now());
      return id;
    }).whenComplete(() {
      if (identical(_boxIdentityInflight[base], request)) {
        _boxIdentityInflight.remove(base);
      }
    });
    _boxIdentityInflight[base] = request;
    return request;
  }

  /// 历史裁剪：只裁已结束的任务。排队中/上传中的永远保留，
  /// 否则一次选 300+ 张会把还没传的任务直接裁掉丢失。
  void trimHistory() {
    if (jobs.length <= 300) return;
    final finished = jobs
        .where((j) =>
            !j.active &&
            j.state != 'staging' &&
            (j.stageId == null || j.state == 'done' || j.state == 'duplicate'))
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    var excess = jobs.length - 300;
    final doomed = <String>{};
    for (final j in finished) {
      if (excess <= 0) break;
      doomed.add(j.id);
      excess--;
    }
    if (doomed.isEmpty) return;
    jobs.removeWhere((j) => doomed.contains(j.id));
  }

  Future<void>? _persistChain;
  int _persistEpoch = 0;
  Timer? _progressTick;

  void _notifyProgress() {
    if (_progressTick != null) return;
    _progressTick = Timer(const Duration(milliseconds: 200), () {
      _progressTick = null;
      notifyListeners();
    });
  }

  @override
  void notifyListeners() {
    _progressTick?.cancel();
    _progressTick = null;
    super.notifyListeners();
  }

  /// 串行 + 原子写：并发上传频繁触发时合并为最后一次状态落盘，
  /// 写一半断电也不会留下半截 JSON。
  Future<void> _persist({bool strict = false}) {
    final epoch = ++_persistEpoch;
    Future<void> next() async {
      if (!strict && epoch != _persistEpoch) return;
      await _persistNow(strict: strict);
    }

    _persistChain = _persistChain == null
        ? next()
        : _persistChain!.then((_) => next(), onError: (_) => next());
    return _persistChain!;
  }

  Future<void> _persistNow({bool strict = false}) async {
    try {
      final f = await _file();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
        jsonEncode([for (final j in jobs) j.toJson()]),
        flush: true,
      );
      await tmp.rename(f.path);
    } catch (_) {
      if (strict) rethrow;
    }
  }

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/transfers.json');
  }
}
