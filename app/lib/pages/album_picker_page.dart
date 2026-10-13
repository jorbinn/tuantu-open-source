/// 微信 / 抖音式相册选择：按日期聚合，可全选当天，不走「所有文件」页。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show compute, debugPrint, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';

import '../album_prep.dart';
import '../ios_live_export.dart';
import '../album_live_probe.dart';
import '../widgets/live_photo_badge.dart';
import '../live_photo.dart';
import '../saver.dart';
import '../upload_prep.dart';

class AlbumPickerPage extends StatefulWidget {
  const AlbumPickerPage({super.key, this.maxCount, this.imageOnly = false});

  final int? maxCount;
  final bool imageOnly;

  /// Allows navigation tests to substitute platform-only photo export.
  @visibleForTesting
  static Future<PickedMedia?> Function(AssetEntity)? prepareMediaOverride;

  @visibleForTesting
  static Future<File?> Function(AssetEntity, PMCancelToken)?
      previewSourceOverride;

  static Future<List<PickedMedia>?> open(
    BuildContext context, {
    int? maxCount,
    bool imageOnly = false,
  }) {
    return Navigator.of(context).push<List<PickedMedia>>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            AlbumPickerPage(maxCount: maxCount, imageOnly: imageOnly),
      ),
    );
  }

  @override
  State<AlbumPickerPage> createState() => _AlbumPickerPageState();
}

class _AlbumPickerPageState extends State<AlbumPickerPage>
    with WidgetsBindingObserver {
  static const _pageSize = 80;

  List<AssetPathEntity> albums = [];
  AssetPathEntity? current;
  final List<AssetEntity> assets = [];
  final List<AssetEntity> selected = [];
  bool loading = true;
  bool loadingMore = false;
  bool resolving = false;
  bool hasMore = true;
  int page = 0;
  String? permError;
  bool limited = false;
  String? loadingDay;
  Future<void>? _inflight;
  bool get _allowDaySelect => widget.maxCount != 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  /// 选图页开着时去「照片」导入读卡器里的照片、或在设置里改了权限，
  /// 回到 App 要重新查一次，否则新照片要关掉选图页才看得到。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshOnResume());
  }

  bool _refreshing = false;
  int _listGen = 0;

  /// 上次加载时当前相册的资源数；回到前台没变化就不重置列表（保留滚动位置）。
  int? _knownCount;

  Future<int?> _count(AssetPathEntity? path) async {
    if (path == null) return null;
    try {
      return await path.assetCountAsync;
    } catch (_) {
      return null;
    }
  }

  Future<void> _refreshOnResume() async {
    if (_refreshing || loading || resolving || loadingDay != null) return;
    _refreshing = true;
    try {
      await _inflight;
      if (!mounted || resolving || loadingDay != null) return;
      if (permError != null || current == null) {
        setState(() {
          permError = null;
          loading = true;
        });
        await _boot();
        return;
      }
      final state = await PhotoManager.getPermissionState(
        requestOption: Saver.permissionOption,
      );
      final paths = await PhotoManager.getAssetPathList(
        type: widget.imageOnly ? RequestType.image : RequestType.common,
        filterOption: albumFilterOption(),
      );
      await _inflight;
      if (!mounted || resolving || loadingDay != null) return;
      final keep = current?.id;
      final target = paths.where((p) => p.id == keep).firstOrNull ??
          (paths.isEmpty ? null : paths.first);
      final count = await _count(target);
      await _inflight;
      if (!mounted || resolving || loadingDay != null) return;
      if (count != null &&
          count == _knownCount &&
          target?.id == keep &&
          state.isLimited == limited) {
        return; // 相册没变化
      }
      _knownCount = count;
      setState(() {
        _listGen++;
        albums = paths;
        current = target;
        limited = state.isLimited;
        // 已选的保留（按资源 ID）；列表从头重新分页。
        assets.clear();
        page = 0;
        hasMore = true;
      });
      await _loadMore();
    } catch (_) {
      // 刷新失败不影响当前列表。
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stallTimer?.cancel();
    _prepSession?.cancel();
    try {
      _prepToken?.cancelRequest();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _boot() async {
    final err = await Saver.ensurePermission();
    if (!mounted) return;
    if (err != null) {
      setState(() {
        permError = err;
        loading = false;
      });
      return;
    }
    final state = await PhotoManager.getPermissionState(
      requestOption: Saver.permissionOption,
    );
    final paths = await PhotoManager.getAssetPathList(
      type: widget.imageOnly ? RequestType.image : RequestType.common,
      filterOption: albumFilterOption(),
    );
    if (!mounted) return;
    setState(() {
      albums = paths;
      current = paths.isEmpty ? null : paths.first;
      limited = state.isLimited;
      loading = false;
    });
    _knownCount = await _count(current);
    if (!mounted) return;
    await _loadMore();
  }

  Future<void> _loadMore() {
    if (_inflight != null) return _inflight!;
    _inflight = _loadMoreBody().whenComplete(() => _inflight = null);
    return _inflight!;
  }

  Future<void> _loadMoreBody() async {
    final album = current;
    if (album == null || !hasMore) return;
    final gen = _listGen;
    setState(() => loadingMore = true);
    final batch = await album.getAssetListPaged(page: page, size: _pageSize);
    if (!mounted) return;
    if (gen != _listGen) {
      // 列表在请求期间被重置（切相册 / 回到前台刷新），丢弃旧页。
      setState(() => loadingMore = false);
      return;
    }
    setState(() {
      assets.addAll(batch);
      page += 1;
      hasMore = batch.length >= _pageSize;
      loadingMore = false;
    });
  }

  Future<void> _switchAlbum(AssetPathEntity album) async {
    if (album.id == current?.id) return;
    await _inflight;
    if (!mounted) return;
    setState(() {
      _listGen++;
      current = album;
      assets.clear();
      selected.clear();
      page = 0;
      hasMore = true;
    });
    _knownCount = await _count(album);
    if (!mounted) return;
    await _loadMore();
  }

  Future<void> _openSettings() async {
    await PhotoManager.openSetting();
  }

  Future<void> _manageLimited() async {
    await PhotoManager.presentLimited(
      type: widget.imageOnly ? RequestType.image : RequestType.common,
    );
    if (!mounted) return;
    setState(() {
      _listGen++;
      assets.clear();
      selected.clear();
      albums = [];
      current = null;
      page = 0;
      hasMore = true;
      loading = true;
      permError = null;
    });
    await _boot();
  }

  List<(String, List<AssetEntity>)> get _groups {
    final map = <String, List<AssetEntity>>{};
    final order = <String>[];
    for (final a in assets) {
      final k = mediaDay(a.createDateTime);
      if (!map.containsKey(k)) {
        map[k] = [];
        order.add(k);
      }
      map[k]!.add(a);
    }
    return [for (final k in order) (k, map[k]!)];
  }

  bool _dayComplete(String day) {
    if (!hasMore) return true;
    if (assets.isEmpty) return false;
    final last = mediaDay(assets.last.createDateTime);
    if (last == day) return false;
    return last.compareTo(day) < 0;
  }

  Future<void> _ensureDayLoaded(String day) async {
    while (mounted && hasMore && !_dayComplete(day)) {
      await _loadMore();
    }
  }

  void _toggle(AssetEntity asset) {
    setState(() {
      final i = selected.indexWhere((a) => a.id == asset.id);
      if (i >= 0) {
        selected.removeAt(i);
        return;
      }
      final max = widget.maxCount;
      if (max == 1) {
        selected
          ..clear()
          ..add(asset);
        return;
      }
      if (max != null && selected.length >= max) return;
      selected.add(asset);
    });
  }

  Future<void> _openPreview(AssetEntity asset) async {
    final i = assets.indexWhere((a) => a.id == asset.id);
    if (i < 0) return;
    final confirm = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _PreviewPage(
          assets: assets,
          initialIndex: i,
          selected: selected,
          maxCount: widget.maxCount,
          onToggle: _toggle,
          onNeedMore: _loadMore,
        ),
      ),
    );
    // Close only the preview first; preparation and the final result still
    // belong to the picker route (including cancellation and export errors).
    if (confirm == true && mounted) await _confirm();
  }

  Future<void> _toggleDay(String day) async {
    if (!_allowDaySelect || loadingDay != null) return;
    setState(() => loadingDay = day);
    await _ensureDayLoaded(day);
    if (!mounted) return;
    final items = [
      for (final a in assets)
        if (mediaDay(a.createDateTime) == day) a,
    ];
    final allOn = items.isNotEmpty &&
        items.every((a) => selected.any((s) => s.id == a.id));
    setState(() {
      if (allOn) {
        selected.removeWhere((s) => mediaDay(s.createDateTime) == day);
      } else {
        for (final a in items) {
          if (selected.indexWhere((s) => s.id == a.id) < 0) {
            selected.add(a);
          }
        }
      }
      loadingDay = null;
    });
  }

  PMCancelToken? _prepToken;
  AlbumPrepSession? _prepSession;
  int _prepGen = 0;
  int _prepped = 0;
  int _prepTotal = 0;
  bool? _prepOnline;
  Timer? _stallTimer;
  DateTime _lastProgress = DateTime.now();
  int _stallSec = 0;

  void _cancelPrep() {
    _prepSession?.cancel();
    try {
      unawaited(_prepToken?.cancelRequest());
    } catch (_) {}
  }

  /// 准备并返回选中的媒体。iCloud 没原片的、导出失败的都会被明确报告，
  /// 不允许「转圈到底」或把没准备好的算进成功。
  Future<void> _confirm() async {
    if (selected.isEmpty || resolving) return;
    final token = PMCancelToken();
    final session = AlbumPrepSession(++_prepGen);
    setState(() {
      resolving = true;
      _prepToken = token;
      _prepSession = session;
      _prepped = 0;
      _prepTotal = selected.length;
      _prepOnline = null;
      _lastProgress = DateTime.now();
      _stallSec = 0;
    });
    _stallTimer?.cancel();
    _stallTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || !resolving) {
        t.cancel();
        return;
      }
      setState(
        () => _stallSec = DateTime.now().difference(_lastProgress).inSeconds,
      );
    });
    final out = <PickedMedia>[];
    var icloud = 0;
    var failed = 0;
    try {
      for (final a in selected) {
        if (!mounted || session.cancelled) {
          await session.cleanupCreated();
          return;
        }
        final r = await _prepOne(a, token, session);
        if (!mounted || session.cancelled) {
          await session.cleanupCreated();
          return;
        }
        setState(() {
          _prepped++;
          _lastProgress = DateTime.now();
        });
        if (r != null) {
          out.add(r);
        } else if (session.cancelled) {
          await session.cleanupCreated();
          return;
        } else {
          // 区分：iCloud 上没有原片 vs 本地导出失败
          var local = true;
          try {
            local = await a.isLocallyAvailable(isOrigin: true);
          } catch (_) {}
          if (!local) {
            icloud++;
          } else {
            failed++;
          }
        }
      }
    } finally {
      _stallTimer?.cancel();
      if (shouldClearPrepSession(
        finishedGen: session.gen,
        currentGen: _prepGen,
      )) {
        _prepToken = null;
        _prepSession = null;
        if (mounted) setState(() => resolving = false);
      }
    }
    if (!mounted || session.cancelled) return;
    if (out.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('没能准备好所选项目'),
          content: Text(
            icloud > 0
                ? '有 $icloud 个项目的原片在 iCloud 上、本机没有。'
                    '请先在系统相册里连一次网（点开这些照片）让原片下载到手机，再来上传。'
                : '导出所选项目失败了，请重试。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    if (icloud > 0 || failed > 0) {
      final parts = [
        if (icloud > 0) '$icloud 个原片在 iCloud（没下载到本机）',
        if (failed > 0) '$failed 个导出失败',
      ];
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('部分项目没准备好'),
          content: Text('${parts.join('，')}。先上传剩下的 ${out.length} 个？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('传 ${out.length} 个'),
            ),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    Navigator.pop(context, out);
  }

  /// 导出单个 asset：优先原片；iOS 上给 HEIC/HEIF/AVIF/TIFF 和视频生成 JPEG
  /// 预览，让安卓盒子也能出缩略图。返回 null 表示这一项没准备好。
  Future<PickedMedia?> _prepOne(
    AssetEntity a,
    PMCancelToken token,
    AlbumPrepSession session,
  ) async {
    final override = AlbumPickerPage.prepareMediaOverride;
    if (override != null) return override(a);
    File? file;
    String? live;
    String? pairedPreview;
    String? pairedName;
    final owned = <String>[];
    if (Platform.isIOS && a.type != AssetType.video && a.isLivePhoto) {
      try {
        final pair = await exportIosLive(a.id, session: session);
        if (pair == null) return null;
        for (final key in ['still', 'video', 'preview']) {
          final path = pair[key];
          if (path != null) {
            session.rememberCreated(path);
            owned.add(path);
          }
        }
        if (session.cancelled || !mounted) return null;
        final stillPath = pair['still'];
        final videoPath = pair['video'];
        if (stillPath == null ||
            videoPath == null ||
            !liveVideoFileReady(File(videoPath))) {
          return null;
        }
        file = File(stillPath);
        live = videoPath;
        pairedPreview = pair['preview'];
        pairedName = pair['name'];
      } catch (_) {
        return null;
      }
    } else if (a.type != AssetType.video && a.isLivePhoto) {
      final pair = await resolveLiveExportPair(
        cancelled: () => session.cancelled || !mounted,
        loadStill: ({required isOrigin}) =>
            a.loadFile(isOrigin: isOrigin, cancelToken: token),
        loadVideo: ({required isOrigin}) => a.loadFile(
          isOrigin: isOrigin,
          withSubtype: true,
          cancelToken: token,
        ),
      );
      if (pair == null || !liveVideoFileReady(pair.video)) return null;
      file = pair.still;
      live = pair.video.path;
    } else {
      // 教训：原片在 iCloud 时 loadFile 会一直等系统下载；盒子热点没外网就
      // 永远等不到，进度条冻在「正在准备 x/y」。iOS 先查本地可用性和外网，
      // 给整条导出链设预算，超时按「没拿到」处理；安卓保持原行为不动。
      final ios = Platform.isIOS;
      var loadBudget = const Duration(seconds: 120);
      var locallyAvailable = true;
      if (ios) {
        locallyAvailable = await withPrepBudget<bool>(
              a.isLocallyAvailable(isOrigin: true),
              const Duration(seconds: 5),
            ) ??
            true;
        if (!locallyAvailable) {
          final online = _prepOnline ??= await probeInternetOnline(
            newClient: HttpClient.new,
          );
          final icloudBudget = prepLoadBudget(
            locallyAvailable: false,
            online: online,
          );
          if (icloudBudget == null) {
            // ignore: avoid_print
            print('[prep] ${a.id} 原片在 iCloud 且当前无外网，跳过等待');
            return null;
          }
          loadBudget = icloudBudget;
        }
      }
      final loadStart = DateTime.now();
      Future<File?> bounded(Future<File?> f) {
        if (!ios) return f;
        final r = loadBudget - DateTime.now().difference(loadStart);
        return withPrepBudget<File?>(f, r.isNegative ? Duration.zero : r);
      }

      final sw = Stopwatch()..start();
      file = await resolveAlbumFile(
        cancelled: () => session.cancelled || !mounted,
        loadFile: () => bounded(a.loadFile(isOrigin: true, cancelToken: token)),
        originFile: () => bounded(a.originFile),
        // iOS 压缩件不能冒充原件；安卓 a.file 就是相册文件。
        allowCompressedFallback: !ios,
        file: () async {
          try {
            return await bounded(a.file);
          } catch (_) {
            return null;
          }
        },
      );
      // ignore: avoid_print
      print(
        '[prep] ${a.id} load=${sw.elapsed.inMilliseconds}ms '
        'local=$locallyAvailable got=${file != null}',
      );
    }
    if (file == null || session.cancelled || !mounted) return null;
    var size = 0;
    try {
      size = await file.length();
    } catch (_) {}
    // 系统相册里的真实文件名（IMG_1234.HEIC），iOS 缓存导出名带 assetID
    // 和修改时间，直接用会导致「同一张照片每次名字都不一样」。
    final String name;
    if (Platform.isIOS) {
      // iOS 27：实况/编辑过的照片 originalFilename 常是通用的
      // FullSizeRender.*，同一天多张撞名被误判「重复」。优先取未编辑原片
      // 资源名（titleAsync），再按相册 ID 追加稳定哈希保证唯一。
      String? original;
      try {
        original = await withPrepBudget<String>(
          a.titleAsync,
          const Duration(seconds: 3),
        );
      } catch (_) {}
      name = iosUploadName(
        assetId: a.id,
        filePath: file.path,
        preferredName: (original != null && original.trim().isNotEmpty)
            ? original
            : (pairedName ?? a.title),
      );
    } else {
      name = pairedName ??
          ((a.title != null && a.title!.isNotEmpty)
              ? a.title!
              : (file.uri.pathSegments.isEmpty
                  ? file.path
                  : file.uri.pathSegments.last));
    }
    final ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    var liveRequired = live != null;
    if (a.type != AssetType.video && live == null) {
      var stillHasEmbeddedLive = false;
      try {
        stillHasEmbeddedLive = await compute(
          motionPhotoFileHasEmbedded,
          file.path,
        );
      } catch (_) {}
      final sibling = siblingLiveVideo(file.path);
      final kind = classifyLiveUpload(
        isLivePhoto: a.isLivePhoto,
        stillHasEmbeddedLive: stillHasEmbeddedLive,
        pairedVideoReady: false,
        siblingReady: sibling != null,
      );
      if (kind == null) return null;
      if (kind == LiveUploadKind.embeddedMotion) {
        final dir = await getTemporaryDirectory();
        final dest =
            '${dir.path}/tuantu_live_${a.id}_${DateTime.now().millisecondsSinceEpoch}.mp4';
        final ok = await compute(extractMotionVideoFile, [file.path, dest]);
        if (!ok || !liveVideoFileReady(File(dest))) return null;
        live = dest;
        liveRequired = true;
        session.rememberCreated(dest);
      } else if (kind == LiveUploadKind.siblingVideo && sibling != null) {
        live = sibling;
        liveRequired = true;
      }
    }
    if (session.cancelled) return null;
    // 兼容预览：HEIC / AVIF / TIFF 静图和视频（首帧），安卓盒子解不了这些，
    // 但解码一张 JPEG 没问题。原件照传，预览只是附加字段。
    String? preview = pairedPreview;
    if (preview == null &&
        Platform.isIOS &&
        (a.type == AssetType.video ||
            (ext.isNotEmpty && !previewExts.contains(ext)))) {
      preview = await _exportPreview(a, token);
      if (preview != null) session.rememberCreated(preview);
    }
    if (session.cancelled) return null;
    return PickedMedia(
      path: file.path,
      name: name,
      day: mediaDay(a.createDateTime),
      isVideo: a.type == AssetType.video,
      size: size,
      livePath: live,
      previewPath: preview,
      takenAt: wallClockUtcSeconds(a.createDateTime),
      liveRequired: liveRequired,
      ownedFiles: owned,
    );
  }

  Future<String?> _exportPreview(AssetEntity a, PMCancelToken token) async {
    try {
      final data = await withPrepBudget<Uint8List?>(
        a.thumbnailDataWithOption(
          ThumbnailOption.ios(
            size: const ThumbnailSize(2048, 2048),
            quality: 88,
            // highQualityFormat 会等 iCloud 高质量版；热点没网就白等。
            // opportunistic 立刻用本机已有的版本出预览。
            deliveryMode: DeliveryMode.opportunistic,
          ),
          cancelToken: token,
        ),
        const Duration(seconds: 30),
      );
      if (data == null || data.length < 512) return null;
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/${compatiblePreviewFileName(a.id)}');
      await f.writeAsBytes(data, flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  String get _albumTitle {
    final a = current;
    if (a == null) return '相册';
    if (a.isAll) return '最近项目';
    return a.name;
  }

  String _dayLabel(String k) {
    final d = DateTime.tryParse('${k}T00:00:00');
    // 本机相册里也可能有 0000 年 / 1970 年前的照片：不显示奇怪的 key。
    if (d == null || d.year < 1900 || d.year > 9999) return '时间未知';
    const wd = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final today = mediaDay(DateTime.now());
    final yest = mediaDay(DateTime.now().subtract(const Duration(days: 1)));
    final base = '${d.month}月${d.day}日 ${wd[d.weekday - 1]}';
    if (k == today) return '今天 $base';
    if (k == yest) return '昨天 $base';
    if (d.year != DateTime.now().year) return '${d.year}年$base';
    return base;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        title: albums.length <= 1
            ? Text(_albumTitle, style: const TextStyle(fontSize: 17))
            : InkWell(
                onTap: _showAlbums,
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        _albumTitle,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 17),
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down, size: 22),
                  ],
                ),
              ),
        actions: [
          if (limited)
            TextButton(onPressed: _manageLimited, child: const Text('管理')),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              if (limited)
                Material(
                  color: const Color(0xFF1A1F26),
                  child: ListTile(
                    dense: true,
                    title: const Text(
                      '仅可访问部分照片',
                      style: TextStyle(fontSize: 13),
                    ),
                    trailing: const Text(
                      '管理',
                      style: TextStyle(color: Color(0xFF38BDF8)),
                    ),
                    onTap: _manageLimited,
                  ),
                ),
              Expanded(child: _body()),
              _bottomBar(),
            ],
          ),
          if (resolving)
            ColoredBox(
              color: const Color(0x88000000),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 14),
                    Text(
                      '正在准备 $_prepped / $_prepTotal 项…',
                      style: const TextStyle(fontSize: 14),
                    ),
                    if (_stallSec >= 6) ...[
                      const SizedBox(height: 6),
                      Text(
                        '第 ${_prepped + 1} 项耗时较久：'
                        '可能在等 iCloud 原片或导出大视频',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    TextButton(onPressed: _cancelPrep, child: const Text('取消')),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body() {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (permError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('📷', style: TextStyle(fontSize: 42)),
              const SizedBox(height: 12),
              Text(
                permError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, height: 1.5),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _openSettings,
                child: const Text('去系统设置开启'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () async {
                  setState(() {
                    loading = true;
                    permError = null;
                  });
                  await _boot();
                },
                child: const Text('我已开启，再试一次'),
              ),
            ],
          ),
        ),
      );
    }
    if (assets.isEmpty) {
      return const Center(
        child: Text('相册是空的', style: TextStyle(color: Colors.white54)),
      );
    }
    final groups = _groups;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels > n.metrics.maxScrollExtent - 900) {
          _loadMore();
        }
        return false;
      },
      child: CustomScrollView(
        slivers: [
          for (final g in groups) ...[
            SliverToBoxAdapter(child: _dayHeader(g.$1, g.$2)),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 2,
                  crossAxisSpacing: 2,
                ),
                delegate: SliverChildBuilderDelegate(
                  (_, i) => _cell(g.$2[i]),
                  childCount: g.$2.length,
                ),
              ),
            ),
          ],
          if (loadingMore)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _dayHeader(String day, List<AssetEntity> items) {
    final allOn = items.isNotEmpty &&
        items.every((a) => selected.any((s) => s.id == a.id));
    final busy = loadingDay == day;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _dayLabel(day),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
          ),
          if (_allowDaySelect)
            TextButton(
              onPressed: busy ? null : () => _toggleDay(day),
              child: busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      allOn ? '取消全选' : '全选',
                      style: const TextStyle(fontSize: 13),
                    ),
            ),
        ],
      ),
    );
  }

  Widget _cell(AssetEntity asset) {
    final idx = selected.indexWhere((a) => a.id == asset.id);
    final on = idx >= 0;
    return GestureDetector(
      onTap: () => _openPreview(asset),
      behavior: HitTestBehavior.opaque,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _AssetThumb(asset: asset),
          if (on) const ColoredBox(color: Color(0x66000000)),
          if (asset.type == AssetType.image)
            Positioned(left: 6, bottom: 6, child: _LiveBadge(asset: asset)),
          // 点格子主体是放大预览，勾选收进右上角的圆圈按钮。
          Positioned(
            top: 0,
            right: 0,
            child: GestureDetector(
              onTap: () => _toggle(asset),
              key: ValueKey('album-select-${asset.id}'),
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: 40,
                height: 40,
                child: Center(
                  child: Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: on ? const Color(0xFFFF5E7A) : Colors.transparent,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: on
                        ? Text(
                            '${idx + 1}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          )
                        : null,
                  ),
                ),
              ),
            ),
          ),
          if (asset.type == AssetType.video)
            Positioned(
              left: 6,
              bottom: 6,
              child: Text(
                _fmtDur(asset.videoDuration),
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.white,
                  shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    final n = selected.length;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.maxCount == 1
                    ? (widget.imageOnly ? '选一张照片' : '选一项')
                    : '按日期全选当天，已传过的会自动跳过',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            FilledButton(
              onPressed: n == 0 || resolving ? null : _confirm,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFF5E7A),
                disabledBackgroundColor: const Color(0xFF2C343F),
              ),
              child: Text(n == 0 ? '完成' : '完成 ($n)'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAlbums() async {
    final counts = <String, int>{};
    await Future.wait(
      albums.map((a) async {
        counts[a.id] = await a.assetCountAsync;
      }),
    );
    if (!mounted) return;
    final picked = await showModalBottomSheet<AssetPathEntity>(
      context: context,
      backgroundColor: const Color(0xFF1A1F26),
      builder: (ctx) => ListView(
        children: [
          for (final a in albums)
            ListTile(
              title: Text(a.isAll ? '最近项目' : a.name),
              subtitle: Text(
                '${counts[a.id] ?? 0} 项',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
              selected: a.id == current?.id,
              onTap: () => Navigator.pop(ctx, a),
            ),
        ],
      ),
    );
    if (picked != null) await _switchAlbum(picked);
  }

  static String _fmtDur(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

final Map<String, Uint8List> _thumbCache = {};

class _LiveBadge extends StatefulWidget {
  const _LiveBadge({required this.asset});
  final AssetEntity asset;
  @override
  State<_LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<_LiveBadge> {
  bool live = false;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _probe();
  }

  @override
  void didUpdateWidget(_LiveBadge old) {
    super.didUpdateWidget(old);
    if (AlbumLiveProbe.shared.key(old.asset) !=
        AlbumLiveProbe.shared.key(widget.asset)) {
      _probe();
    }
  }

  void _probe() {
    _timer?.cancel();
    live = AlbumLiveProbe.shared.cached(widget.asset) ?? false;
    final asset = widget.asset;
    // Fast-scrolled cells disappear before touching their original file.
    _timer = Timer(const Duration(milliseconds: 180), () async {
      final found = await AlbumLiveProbe.shared.detect(asset);
      if (mounted &&
          AlbumLiveProbe.shared.key(widget.asset) ==
              AlbumLiveProbe.shared.key(asset)) {
        setState(() => live = found);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !live
      ? const SizedBox.shrink()
      : LivePhotoBadge(key: ValueKey('album-live-${widget.asset.id}'));
}

class _AssetThumb extends StatefulWidget {
  const _AssetThumb({required this.asset});
  final AssetEntity asset;

  @override
  State<_AssetThumb> createState() => _AssetThumbState();
}

class _AssetThumbState extends State<_AssetThumb> {
  Uint8List? bytes;

  @override
  void initState() {
    super.initState();
    bytes = _thumbCache[widget.asset.id];
    if (bytes == null) _load();
  }

  @override
  void didUpdateWidget(_AssetThumb old) {
    super.didUpdateWidget(old);
    if (old.asset.id != widget.asset.id) {
      bytes = _thumbCache[widget.asset.id];
      setState(() {});
      if (bytes == null) _load();
    }
  }

  Future<void> _load() async {
    final id = widget.asset.id;
    final data = await widget.asset.thumbnailDataWithSize(
      const ThumbnailSize.square(300),
    );
    if (data != null) {
      if (_thumbCache.length > 400) _thumbCache.clear();
      _thumbCache[id] = data;
    }
    if (!mounted || widget.asset.id != id) return;
    setState(() => bytes = data);
  }

  @override
  Widget build(BuildContext context) {
    if (bytes == null) return const ColoredBox(color: Color(0xFF222933));
    return Image.memory(
      bytes!,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
    );
  }
}

/// 预览大图缓存（2048px），容量小：一次浏览看不了几张。
final Map<String, Uint8List> _previewCache = {};

void _previewCachePut(String id, Uint8List data) {
  while (_previewCache.length >= 20) {
    _previewCache.remove(_previewCache.keys.first);
  }
  _previewCache[id] = data;
}

/// 选照片页的全屏预览：左右滑动连续看，捏合/双击放大，右上角勾选。
/// [selected] 与选择页共享同一个列表对象，勾选立即同步到网格。
class _PreviewPage extends StatefulWidget {
  const _PreviewPage({
    required this.assets,
    required this.initialIndex,
    required this.selected,
    required this.maxCount,
    required this.onToggle,
    required this.onNeedMore,
  });

  final List<AssetEntity> assets;
  final int initialIndex;
  final List<AssetEntity> selected;
  final int? maxCount;
  final void Function(AssetEntity) onToggle;
  final Future<void> Function() onNeedMore;

  @override
  State<_PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<_PreviewPage> {
  late int _index;
  late final PageController _ctrl;
  bool _submitted = false;

  /// 当前页处于放大状态时禁掉 PageView 横滑，让单指拖动归平移。
  bool _zooming = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.assets.length - 1);
    // PageView 的真实初始页必须和顶部状态一致，否则点第 N 张时画面仍是第 1 张。
    _ctrl = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  AssetEntity get _current => widget.assets[_index];

  int _selIndex(AssetEntity a) =>
      widget.selected.indexWhere((s) => s.id == a.id);

  void _toggleCurrent() {
    widget.onToggle(_current);
    setState(() {});
  }

  void _confirmSelection() {
    if (_submitted || widget.selected.isEmpty) return;
    setState(() => _submitted = true);
    Navigator.pop(context, true);
  }

  Future<void> _onPageChanged(int i) async {
    setState(() {
      _index = i;
      _zooming = false;
    });
    if (i >= widget.assets.length - 3) {
      await widget.onNeedMore();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.assets.length;
    return Scaffold(
      backgroundColor: Colors.black,
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.selected.isEmpty
                      ? '勾选要提交的项目'
                      : '已选择 ${widget.selected.length} 项',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              FilledButton(
                onPressed: widget.selected.isEmpty || _submitted
                    ? null
                    : _confirmSelection,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFF5E7A),
                  disabledBackgroundColor: const Color(0xFF2C343F),
                ),
                child: Text(
                  widget.selected.isEmpty
                      ? '完成'
                      : '完成 (${widget.selected.length})',
                ),
              ),
            ],
          ),
        ),
      ),
      body: Stack(
        children: [
          PageView.builder(
            controller: _ctrl,
            itemCount: n,
            physics: _zooming
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            onPageChanged: _onPageChanged,
            itemBuilder: (_, i) => _PreviewMedia(
              key: ValueKey(widget.assets[i].id),
              asset: widget.assets[i],
              active: i == _index,
              onZoomChanged: (z) {
                if (_zooming != z) setState(() => _zooming = z);
              },
            ),
          ),
          _topBar(n),
        ],
      ),
    );
  }

  Widget _topBar(int n) {
    final sel = _selIndex(_current);
    final on = sel >= 0;
    // 多选选满才禁用；maxCount == 1 是替换语义，随时可以改选。
    final max = widget.maxCount;
    final full = max != null && max > 1 && widget.selected.length >= max && !on;
    return SafeArea(
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('album-preview-close'),
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
          Expanded(
            child: Text(
              '${_index + 1} / $n',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: GestureDetector(
              onTap: full ? null : _toggleCurrent,
              key: const ValueKey('preview-select'),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: on ? const Color(0xFFFF5E7A) : Colors.transparent,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: on
                        ? const Color(0xFFFF5E7A)
                        : (full ? Colors.white24 : Colors.white),
                    width: 1.5,
                  ),
                ),
                child: on
                    ? Text(
                        '${sel + 1}',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      )
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewMedia extends StatefulWidget {
  const _PreviewMedia({
    super.key,
    required this.asset,
    required this.active,
    required this.onZoomChanged,
  });

  final AssetEntity asset;
  final bool active;
  final void Function(bool zooming) onZoomChanged;

  @override
  State<_PreviewMedia> createState() => _PreviewMediaState();
}

class _PreviewMediaState extends State<_PreviewMedia> {
  final _transform = TransformationController();

  /// 先用网格缩略图垫底秒开，大图到了再替换。
  Uint8List? bytes;
  VideoPlayerController? _video;
  PMCancelToken? _videoToken;
  bool _videoLoading = false;
  String? _videoError;
  bool _detectedLive = false;
  int _videoGeneration = 0;
  File? _previewVideoFile;

  bool get _isVideo => widget.asset.type == AssetType.video;
  bool get _isLive => widget.asset.isLivePhoto || _detectedLive;
  bool get _isPlayable => _isVideo || _isLive;

  @override
  void initState() {
    super.initState();
    bytes = _previewCache[widget.asset.id];
    if (bytes == null) {
      bytes = _thumbCache[widget.asset.id];
      _load();
    }
    if (widget.active) unawaited(_activate());
  }

  @override
  void didUpdateWidget(_PreviewMedia oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id) {
      _videoGeneration++;
      _videoLoading = false;
      _detectedLive = false;
      try {
        _videoToken?.cancelRequest();
      } catch (_) {}
      _videoToken = null;
      unawaited(_disposeVideo());
      bytes = _previewCache[widget.asset.id] ?? _thumbCache[widget.asset.id];
      _videoError = null;
      _load();
    }
    if (widget.active &&
        (!oldWidget.active || oldWidget.asset.id != widget.asset.id)) {
      unawaited(_activate());
    }
    if (!oldWidget.active && widget.active && _isPlayable) {
      if (_video == null) {
        unawaited(_initVideo());
      } else if (_isLive) {
        unawaited(_video!.play());
      }
    } else if (oldWidget.active && !widget.active) {
      _videoGeneration++;
      _videoLoading = false;
      try {
        _videoToken?.cancelRequest();
      } catch (_) {}
      final video = _video;
      if (video != null) {
        unawaited(_pauseAndRewind(video));
      }
    }
  }

  @override
  void dispose() {
    _videoGeneration++;
    try {
      _videoToken?.cancelRequest();
    } catch (_) {}
    unawaited(_disposeVideo());
    _transform.dispose();
    super.dispose();
  }

  Future<void> _disposeVideo() async {
    final old = _video;
    _video = null;
    final file = _previewVideoFile;
    _previewVideoFile = null;
    if (old != null) await old.dispose();
    try {
      if (file != null && await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _activate() async {
    final asset = widget.asset;
    if (!_isVideo && !_isLive) {
      final live = await AlbumLiveProbe.shared.detect(asset);
      if (!mounted || widget.asset.id != asset.id || !widget.active) return;
      setState(() => _detectedLive = live);
    }
    if (mounted && widget.active && _isPlayable) {
      if (_video == null) {
        await _initVideo();
      } else if (_isLive) {
        await _video!.play();
      }
    }
  }

  Future<void> _pauseAndRewind(VideoPlayerController video) async {
    await video.pause();
    await video.seekTo(Duration.zero);
  }

  Future<void> _load() async {
    final id = widget.asset.id;
    try {
      final data = await widget.asset.thumbnailDataWithOption(
        const ThumbnailOption(size: ThumbnailSize(2048, 2048)),
      );
      if (data == null || widget.asset.id != id) return;
      _previewCachePut(id, data);
      if (!mounted) return;
      setState(() => bytes = data);
    } catch (_) {}
  }

  Future<void> _initVideo() async {
    if (_videoLoading || _video != null || !_isPlayable || !widget.active) {
      return;
    }
    final id = widget.asset.id;
    final generation = ++_videoGeneration;
    bool current() =>
        mounted &&
        widget.active &&
        widget.asset.id == id &&
        generation == _videoGeneration;
    setState(() {
      _videoLoading = true;
      _videoError = null;
    });
    VideoPlayerController? controller;
    File? extracted;
    final token = PMCancelToken();
    _videoToken = token;
    try {
      if (_isVideo || (Platform.isIOS && _isLive)) {
        // photo_manager 会把普通视频解析为系统媒体 URL；iOS Live Photo
        // 则解析为同一 PHAsset 的 pairedVideo，方向元数据交给 AVPlayer。
        final url = await widget.asset.getMediaUrl(cancelToken: token).timeout(
          const Duration(seconds: 45),
          onTimeout: () {
            token.cancelRequest();
            throw TimeoutException('media url timeout');
          },
        );
        if (!current()) return;
        if (url == null || url.isEmpty) throw StateError('media url missing');
        controller = VideoPlayerController.networkUrl(
          Uri.parse(url),
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
        );
      } else {
        // 安卓动态照片是 JPEG + MP4 的单文件。仅向临时目录提取 MP4，
        // 原片不做任何修改，且大文件解析放到 isolate。
        final source = await (AlbumPickerPage.previewSourceOverride
                    ?.call(widget.asset, token) ??
                widget.asset.loadFile(isOrigin: true, cancelToken: token))
            .timeout(
          const Duration(seconds: 45),
          onTimeout: () {
            token.cancelRequest();
            throw TimeoutException('motion photo timeout');
          },
        );
        if (!current()) return;
        if (source == null) throw StateError('motion photo missing');
        final dir = await getTemporaryDirectory();
        final output = File(
          '${dir.path}${Platform.pathSeparator}'
          '${DateTime.now().microsecondsSinceEpoch}_${motionPreviewFileName(id)}',
        );
        extracted = output;
        if (!current()) return;
        final ok = await compute(extractMotionVideoFile, [
          source.path,
          output.path,
        ]);
        if (!current()) return;
        final sibling =
            ok ? null : await compute(siblingLiveVideo, source.path);
        if (!current()) return;
        if (!ok && sibling == null) throw StateError('motion video missing');
        controller = VideoPlayerController.file(
          ok ? output : File(sibling!),
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
        );
      }
      await controller.initialize().timeout(const Duration(seconds: 45));
      await controller.setLooping(_isLive);
      if (_isLive) await controller.setVolume(0);
      controller.addListener(_onVideoChanged);
      if (!current()) {
        await controller.dispose();
        return;
      }
      setState(() {
        _video = controller;
        _previewVideoFile = extracted;
        extracted = null;
        _videoLoading = false;
      });
      if (widget.active && _isLive) await controller.play();
    } catch (error) {
      debugPrint('[album-preview] video preparation failed: $error');
      await controller?.dispose();
      if (!current()) return;
      setState(() {
        if (identical(_video, controller)) _video = null;
        _videoLoading = false;
        _videoError = _isLive ? '无法读取这张实况照片的动态部分' : '视频暂时无法播放';
      });
    } finally {
      try {
        if (extracted != null && await extracted!.exists()) {
          await extracted!.delete();
        }
      } catch (_) {}
      if (identical(_videoToken, token)) _videoToken = null;
    }
  }

  void _onVideoChanged() {
    if (mounted) setState(() {});
  }

  void _togglePlayback() {
    final video = _video;
    if (video == null || !video.value.isInitialized) {
      if (!_videoLoading) unawaited(_initVideo());
      return;
    }
    if (video.value.isPlaying) {
      unawaited(video.pause());
    } else {
      if (video.value.position >= video.value.duration) {
        unawaited(video.seekTo(Duration.zero));
      }
      unawaited(video.play());
    }
  }

  void _doubleTap(TapDownDetails d) {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.05;
    if (zoomed) {
      _transform.value = Matrix4.identity();
      widget.onZoomChanged(false);
      return;
    }
    // 绕双击点放大 2.5 倍（与 zoomable.dart 一致，直接写 storage）。
    const s = 2.5;
    final m = Matrix4.identity();
    m.storage[0] = s;
    m.storage[5] = s;
    m.storage[12] = d.localPosition.dx * (1 - s);
    m.storage[13] = d.localPosition.dy * (1 - s);
    _transform.value = m;
    widget.onZoomChanged(true);
  }

  @override
  Widget build(BuildContext context) {
    if (_isPlayable) return _buildPlayable();
    return GestureDetector(
      onDoubleTapDown: _doubleTap,
      onDoubleTap: () {},
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 1,
        maxScale: 4,
        onInteractionStart: (_) => widget.onZoomChanged(true),
        onInteractionEnd: (_) =>
            widget.onZoomChanged(_transform.value.getMaxScaleOnAxis() > 1.01),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: bytes == null
                  ? const ColoredBox(
                      color: Colors.black,
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : Image.memory(
                      bytes!,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _poster() {
    if (bytes == null) {
      return const ColoredBox(color: Colors.black);
    }
    return Image.memory(
      bytes!,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      width: double.infinity,
      height: double.infinity,
    );
  }

  Widget _buildPlayable() {
    final video = _video;
    final ready = video?.value.isInitialized == true;
    final playing = ready && video!.value.isPlaying;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _togglePlayback,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(child: _poster()),
          if (ready)
            Center(
              child: AspectRatio(
                aspectRatio:
                    video!.value.aspectRatio > 0 ? video.value.aspectRatio : 1,
                child: VideoPlayer(video),
              ),
            ),
          if (_videoLoading)
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          if (!playing && !_videoLoading && _videoError == null)
            Center(
              child: Container(
                width: 58,
                height: 58,
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow,
                  color: Colors.white,
                  size: 38,
                ),
              ),
            ),
          if (_videoError != null)
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 40),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _videoError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 14,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (ready)
                  VideoProgressIndicator(
                    video!,
                    allowScrubbing: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    colors: const VideoProgressColors(
                      playedColor: Color(0xFFFF5E7A),
                      bufferedColor: Colors.white38,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                Row(
                  children: [
                    Icon(
                      _isLive ? Icons.motion_photos_on : Icons.videocam,
                      color: Colors.white70,
                      size: 17,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _isLive
                          ? '实况'
                          : _AlbumPickerPageState._fmtDur(
                              widget.asset.videoDuration,
                            ),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
