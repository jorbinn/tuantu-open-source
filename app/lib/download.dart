/// 后台下载队列：下载原片并保存到系统相册，不阻塞当前浏览页面。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'saver.dart';

class DownloadJob {
  DownloadJob({
    required this.id,
    required this.assetId,
    required this.name,
    required this.kind,
    required this.ext,
    required this.createdAt,
    required this.targetBase,
    required this.boxId,
    this.hasLive = false,
    this.livePts,
    this.takenAt,
    this.mediaCreatedAt,
    this.allowDuplicate = true,
    this.state = 'queued',
    this.status = '排队中',
    this.err,
    this.progress = 0,
    int? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  final String id;
  final int assetId;
  final String name, kind, ext;
  final bool hasLive, allowDuplicate;
  final int? livePts, takenAt;
  final double? mediaCreatedAt;
  final String targetBase;
  final String? boxId;
  final int createdAt;
  int updatedAt;
  String state; // queued / downloading / done / failed / cancelled
  String status;
  String? err;
  double progress;
  bool cancelRequested = false;

  bool get active => state == 'queued' || state == 'downloading';
  bool get failed => state == 'failed';

  CardItem toCardItem() => CardItem({
        'id': assetId,
        'thumb': '/api/asset/$assetId/thumb',
        'kind': kind,
        'ext': ext,
        'orig_name': name,
        'has_thumb': 1,
        'uploader': '',
        'liked': false,
        'mine': false,
        'width': 0,
        'height': 0,
        'likes': 0,
        'comments': 0,
        'has_live': hasLive ? 1 : 0,
        'live_ready': hasLive ? 1 : 0,
        if (livePts != null) 'live_pts': livePts,
        if (takenAt != null) 'taken_at': takenAt,
        if (mediaCreatedAt != null) 'created_at': mediaCreatedAt,
      });

  Map<String, dynamic> toJson() => {
        'id': id,
        'assetId': assetId,
        'name': name,
        'kind': kind,
        'ext': ext,
        'hasLive': hasLive,
        'livePts': livePts,
        'takenAt': takenAt,
        'mediaCreatedAt': mediaCreatedAt,
        'allowDuplicate': allowDuplicate,
        'targetBase': targetBase,
        'boxId': boxId,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'state': state,
        'status': status,
        'err': err,
        'progress': progress,
      };

  factory DownloadJob.fromJson(Map<String, dynamic> j) => DownloadJob(
        id: (j['id'] ?? '').toString(),
        assetId: (j['assetId'] as num?)?.toInt() ?? 0,
        name: (j['name'] ?? '').toString(),
        kind: (j['kind'] ?? 'image').toString(),
        ext: (j['ext'] ?? '').toString(),
        hasLive: j['hasLive'] == true,
        livePts: (j['livePts'] as num?)?.toInt(),
        takenAt: (j['takenAt'] as num?)?.toInt(),
        mediaCreatedAt: (j['mediaCreatedAt'] as num?)?.toDouble(),
        allowDuplicate: j['allowDuplicate'] != false,
        targetBase: (j['targetBase'] ?? '').toString(),
        boxId: j['boxId']?.toString(),
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (j['updatedAt'] as num?)?.toInt(),
        state: (j['state'] ?? 'failed').toString(),
        status: (j['status'] ?? '').toString(),
        err: j['err']?.toString(),
        progress: (j['progress'] as num?)?.toDouble() ?? 0,
      );
}

String? downloadDestinationError(DownloadJob job) {
  if (Api.I.base.isEmpty ||
      (Api.I.base != job.targetBase &&
          !(Api.iosRecoveryEnabled &&
              job.boxId?.isNotEmpty == true &&
              Api.I.boxId == job.boxId))) {
    return '当前连接的不是原来的盒子';
  }
  final expected = job.boxId?.trim() ?? '';
  final current = Api.I.boxId?.trim() ?? '';
  if (expected.isNotEmpty && current != expected) {
    return '目标盒子已更换';
  }
  return null;
}

class DownloadStore extends ChangeNotifier {
  DownloadStore._();
  static final DownloadStore I = DownloadStore._();

  final List<DownloadJob> jobs = [];
  bool running = false;
  bool _loaded = false;
  Timer? _progressTick;
  Future<void>? _persistChain;
  int _persistEpoch = 0;

  @visibleForTesting
  bool pauseWorkers = false;

  @visibleForTesting
  Future<String> Function(
    DownloadJob job,
    void Function(double progress) onProgress,
    bool Function() isCancelled,
  )? saveOverride;

  int get activeCount => jobs.where((j) => j.active).length;

  List<DownloadJob> get newestFirst {
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
      jobs
        ..clear()
        ..addAll([
          for (final e in raw)
            if (e is Map) DownloadJob.fromJson(Map<String, dynamic>.from(e)),
        ]);
      for (final j in jobs) {
        if (j.state == 'downloading') {
          j.state = 'failed';
          j.status = '❌ 下载中断';
          j.err = '上次退出时未下载完';
        }
      }
      notifyListeners();
    } catch (_) {}
  }

  ({DownloadJob job, bool added}) add(
    CardItem c, {
    bool allowDuplicate = true,
    bool flush = true,
  }) {
    final base = Api.I.base;
    for (final existing in jobs) {
      if (existing.active &&
          existing.assetId == c.id &&
          existing.targetBase == base) {
        return (job: existing, added: false);
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final name = c.origName.isNotEmpty ? c.origName : 'tuantu_${c.id}.${c.ext}';
    final job = DownloadJob(
      id: '$now-${c.id}-${jobs.length}',
      assetId: c.id,
      name: name,
      kind: c.kind,
      ext: c.ext,
      hasLive: c.hasLive,
      livePts: c.livePts,
      takenAt: c.takenAt,
      mediaCreatedAt: c.createdAt,
      allowDuplicate: allowDuplicate,
      targetBase: base,
      boxId: Api.I.boxId,
      createdAt: now,
    );
    jobs.add(job);
    if (flush) {
      trimHistory();
      notifyListeners();
      _persist();
    }
    return (job: job, added: true);
  }

  int addAll(Iterable<CardItem> items, {bool allowDuplicate = true}) {
    var added = 0;
    for (final item in items) {
      if (add(item, allowDuplicate: allowDuplicate, flush: false).added) {
        added++;
      }
    }
    if (added > 0) {
      trimHistory();
      notifyListeners();
      _persist();
    }
    return added;
  }

  Future<void> retry(DownloadJob job) async {
    job
      ..cancelRequested = false
      ..err = null
      ..state = 'queued'
      ..status = '排队中'
      ..progress = 0
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
    await _persist();
    unawaited(run());
  }

  void cancel(DownloadJob job) {
    job.cancelRequested = true;
    if (job.state == 'downloading') {
      job.status = '正在取消…';
      notifyListeners();
    }
    if (job.state == 'queued') {
      job
        ..state = 'cancelled'
        ..status = '已取消'
        ..updatedAt = DateTime.now().millisecondsSinceEpoch;
      notifyListeners();
      _persist();
    }
  }

  Future<void> run() async {
    if (pauseWorkers || running || !jobs.any((j) => j.state == 'queued')) {
      return;
    }
    running = true;
    notifyListeners();
    try {
      while (true) {
        DownloadJob? job;
        for (final candidate in jobs) {
          if (candidate.state == 'queued') {
            job = candidate;
            break;
          }
        }
        if (job == null) break;
        job
          ..state = 'downloading'
          ..status = '下载中…'
          ..updatedAt = DateTime.now().millisecondsSinceEpoch;
        notifyListeners();
        await _downloadOne(job);
        notifyListeners();
        await _persist();
      }
    } finally {
      running = false;
      notifyListeners();
      await _persist();
    }
  }

  Future<void> _downloadOne(DownloadJob job) async {
    try {
      final destinationError = downloadDestinationError(job);
      if (destinationError != null) throw destinationError;
      final override = saveOverride;
      final message = override != null
          ? await override(
              job,
              (p) => _progress(job, p),
              () => job.cancelRequested,
            )
          : await Saver.save(
              Api.I,
              job.toCardItem(),
              allowDuplicate: job.allowDuplicate,
              onProgress: (p) => _progress(job, p),
              isCancelled: () => job.cancelRequested,
            );
      if (job.cancelRequested) throw '已取消';
      job
        ..state = 'done'
        ..status = message.contains('已经') ? '已有，无需重复保存' : '✅ 已存入相册'
        ..err = null
        ..progress = 1
        ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    } catch (e) {
      final message =
          e.toString().replaceFirst('Exception: ', '').split('\n').first;
      if (job.cancelRequested || message.contains('取消')) {
        job
          ..state = 'cancelled'
          ..status = '已取消'
          ..err = null;
      } else {
        job
          ..state = 'failed'
          ..status = '❌ 下载失败'
          ..err = message;
      }
      job.updatedAt = DateTime.now().millisecondsSinceEpoch;
    }
  }

  void _progress(DownloadJob job, double value) {
    if (job.cancelRequested) return;
    job.progress = value.clamp(0, 1).toDouble();
    job.status = '下载中 ${(job.progress * 100).toStringAsFixed(0)}%';
    if (_progressTick != null) return;
    _progressTick = Timer(const Duration(milliseconds: 200), () {
      _progressTick = null;
      notifyListeners();
    });
  }

  void trimHistory() {
    if (jobs.length <= 300) return;
    final finished = jobs.where((j) => !j.active).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    var excess = jobs.length - 300;
    final doomed = <String>{};
    for (final j in finished) {
      if (excess <= 0) break;
      doomed.add(j.id);
      excess--;
    }
    jobs.removeWhere((j) => doomed.contains(j.id));
  }

  Future<void> _persist() {
    final epoch = ++_persistEpoch;
    Future<void> next() async {
      if (epoch != _persistEpoch) return;
      try {
        final file = await _file();
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(
          jsonEncode([for (final job in jobs) job.toJson()]),
          flush: true,
        );
        await temp.rename(file.path);
      } catch (_) {}
    }

    _persistChain = _persistChain == null
        ? next()
        : _persistChain!.then((_) => next(), onError: (_) => next());
    return _persistChain!;
  }

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/downloads.json');
  }

  @visibleForTesting
  void resetForTest() {
    jobs.clear();
    running = false;
    pauseWorkers = false;
    saveOverride = null;
  }
}
