/// 纪念卡生成/预览/保存页。
///
/// 流程：盒子聚合（一次快照）→ 客户端选图与排版 → 预览 → 导出 1080×1350 JPEG。
/// 底景、版式、选图各自独立；同一快照的数字不变；
/// 「重新生成」重新请求盒子，补传/删除/互动变化会反映到数字。
library;

import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as im;

import '../api.dart';
import '../main.dart';
import '../report/report_card.dart';
import '../report/report_policy.dart';
import '../report/report_snapshot.dart';
import '../report/report_template.dart';
import '../saver.dart';

class ReportCardPage extends StatefulWidget {
  const ReportCardPage({super.key, required this.config});
  final ReportConfig config;

  /// UI 测试注入假解码：instantiateImageCodec 走真实 IO，
  /// 在 testWidgets 的 fake async 里永远不会完成（真机无此问题）。
  static Future<ui.Image> Function(List<int> bytes, int target)?
  decodeOverrideForTest;

  @override
  State<ReportCardPage> createState() => _ReportCardPageState();
}

enum _Stage { loading, error, empty, ready }

class _ReportCardPageState extends State<ReportCardPage> {
  _Stage stage = _Stage.loading;
  String? error;
  ReportSnapshot? snap;
  int photoSeed = 0;
  int layoutIndex = 0;
  int sceneIndex = 0;
  final photos = <int, ui.Image>{};
  final avatars = <String, ui.Image>{};
  final _boundaryKey = GlobalKey();
  bool saving = false;
  bool regenerating = false;
  CancelToken? _cancelToken;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    final configured = reportScenes.indexWhere(
      (scene) => scene.id == widget.config.sceneId,
    );
    sceneIndex = configured < 0 ? 0 : configured;
    _generate();
  }

  @override
  void dispose() {
    _generation++;
    _cancelToken?.cancel('报告页面已关闭');
    for (final i in photos.values) {
      i.dispose();
    }
    for (final i in avatars.values) {
      i.dispose();
    }
    super.dispose();
  }

  Future<void> _generate() async {
    final generation = ++_generation;
    _cancelToken?.cancel('开始新的报告任务');
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    setState(() {
      stage = _Stage.loading;
      error = null;
    });
    try {
      final r = widget.config.range;
      final data = await Api.I.reportData(
        fromW: r.fromW,
        toW: r.toW,
        fromT: r.fromT,
        toT: r.toT,
        person: widget.config.personal ? widget.config.personId : null,
        cancelToken: cancelToken,
      );
      if (!mounted || generation != _generation) return;
      final s = ReportSnapshot.parse(data);
      if (widget.config.personal) {
        final appear = reportCount(s.personBlock?['photos']);
        if (appear == 0) {
          setState(() {
            snap = s;
            stage = _Stage.empty;
          });
          return;
        }
      } else if (!s.hasMedia) {
        setState(() {
          snap = s;
          stage = _Stage.empty;
        });
        return;
      }
      // 先落快照再加载图片：选图列表要从快照算。
      snap = s;
      final ok = await _loadAssets(cancelToken, generation);
      if (!mounted || generation != _generation) return;
      if (!ok) {
        setState(() {
          stage = _Stage.error;
          error = '图片加载失败，请检查和盒子的连接后重试';
        });
        return;
      }
      setState(() => stage = _Stage.ready);
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) return;
      if (!mounted) return;
      setState(() {
        stage = _Stage.error;
        error = friendlyNet(e, '生成');
      });
    }
  }

  /// 当前 seed 对应的模型（ready 阶段才有）。
  TeamCardModel? get _teamModel =>
      snap == null ? null : TeamCardModel(snap!, seed: photoSeed);

  PersonalCardModel? get _personalModel {
    if (snap == null || snap!.personBlock == null) return null;
    return PersonalCardModel(snap!, widget.config.personId!, seed: photoSeed);
  }

  /// 加载当前版本需要的图片。部分照片失效时用已成功的照片和占位图降级。
  Future<bool> _loadAssets(
    CancelToken cancelToken,
    int generation, {
    bool complete = false,
  }) async {
    final s = snap;
    if (s == null) return false;
    final photoIds = <int>[];
    final avatarPaths = <String>[];
    if (widget.config.personal) {
      final m = PersonalCardModel(
        s,
        widget.config.personId ?? -1,
        seed: photoSeed,
      );
      photoIds.addAll(m.photoIds);
      avatarPaths.add(m.member.avatarPath ?? '');
    } else {
      final m = TeamCardModel(s, seed: photoSeed);
      photoIds.addAll(m.photoIds);
      for (final mod in m.modules) {
        if (mod.photoId != null) photoIds.add(mod.photoId!);
      }
      var n = 0;
      for (final mem in m.appearingMembers.where((x) => x.photos > 0)) {
        if (n++ >= ReportThresholds.avatarMax) break;
        final a = mem.avatarPath;
        if (a != null && a.isNotEmpty) avatarPaths.add(a);
      }
    }
    final jobs = <Future<void>>[];
    // 并发限制：热点上 3 路并发足够，不挤占刷图和视频。
    Future<void> run(Future<void> f) async {
      jobs.add(f);
      if (jobs.length >= 3) {
        await Future.wait(jobs);
        jobs.clear();
      }
    }

    for (final id in photoIds) {
      if (photos.containsKey(id)) continue;
      await run(_loadPhoto(id, cancelToken, generation));
    }
    for (final path in avatarPaths) {
      if (path.isEmpty || avatars.containsKey(path)) continue;
      await run(_loadAvatar(path, cancelToken, generation));
    }
    if (jobs.isNotEmpty) await Future.wait(jobs);
    // 有一张照片成功就可以降级排版；视频-only/无照片报告也允许占位图。
    return photoIds.isEmpty ||
        (complete
            ? photoIds.every((id) => photos.containsKey(id))
            : photoIds.any((id) => photos.containsKey(id)));
  }

  Future<void> _loadPhoto(
    int id,
    CancelToken cancelToken,
    int generation,
  ) async {
    try {
      final bytes = await Api.I.reportPreviewBytes(id, cancelToken);
      // report-preview 已在盒子侧限制长边 1600；这里按原尺寸解码，避免
      // 竖图仅指定 targetWidth 后被反向放大到超过 1600。
      final img = await _decode(_asUint8List(bytes), 0);
      if (mounted && snap != null && generation == _generation) {
        photos[id]?.dispose();
        photos[id] = img;
      } else {
        img.dispose();
      }
    } catch (_) {}
  }

  Future<void> _loadAvatar(
    String path,
    CancelToken cancelToken,
    int generation,
  ) async {
    try {
      final r = await Api.I.dio.get<List<int>>(
        path,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
      final img = await _decode(_asUint8List(r.data), 256);
      if (mounted && generation == _generation) {
        avatars[path]?.dispose();
        avatars[path] = img;
      } else {
        img.dispose();
      }
    } catch (_) {}
  }

  static Uint8List _asUint8List(List<int>? bytes) =>
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes ?? const []);

  Future<ui.Image> _decode(List<int> bytes, int target) async {
    final inject = ReportCardPage.decodeOverrideForTest;
    if (inject != null) return inject(bytes, target);
    final codec = await ui.instantiateImageCodec(
      _asUint8List(bytes),
      targetWidth: target > 0 ? target : null,
    );
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }

  Future<void> _shuffle() async {
    if (stage != _Stage.ready || saving || regenerating) return;
    setState(() => stage = _Stage.loading);
    photoSeed++;
    final generation = ++_generation;
    _cancelToken?.cancel('切换报告版本');
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    final ok = await _loadAssets(cancelToken, generation);
    if (!mounted || generation != _generation) return;
    setState(() {
      stage = ok || photos.isNotEmpty ? _Stage.ready : _Stage.error;
      if (!ok && photos.isEmpty) error = '图片加载失败，请检查和盒子的连接后重试';
    });
  }

  Future<void> _save() async {
    if (saving || stage != _Stage.ready) return;
    setState(() => saving = true);
    try {
      final generation = _generation;
      final ok = await _loadAssets(
        _cancelToken ??= CancelToken(),
        generation,
        complete: true,
      );
      if (!mounted || generation != _generation) return;
      if (!ok) throw '部分照片尚未加载完整，请等信号恢复后再保存';
      setState(() {});
      final ctx = _boundaryKey.currentContext;
      if (ctx == null || !ctx.mounted) throw '还没渲染好，再试一次';
      final boundary = ctx.findRenderObject() as RenderRepaintBoundary;
      // 等一帧，确保换一版后的最新布局已经画完。
      await WidgetsBinding.instance.endOfFrame;
      final image = await boundary.toImage(pixelRatio: 1.0);
      try {
        final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (rgba == null) throw '导出失败';
        // ui.Image 带原生资源，不能被 Isolate.run 的闭包捕获。
        final width = image.width;
        final height = image.height;
        final jpeg = await encodeReportJpegOffload(rgba, width, height);
        final tag = widget.config.range.start;
        final name =
            'tuantu_report_${tag.year}${tag.month.toString().padLeft(2, '0')}${tag.day.toString().padLeft(2, '0')}.jpg';
        final msg = await Saver.saveReportImage(jpeg, title: name);
        if (mounted) toast(context, msg);
      } finally {
        image.dispose();
      }
    } catch (e) {
      if (mounted) toast(context, e is String ? e : '保存失败：$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.config.personal ? '${widget.config.personName} 的纪念卡' : '团队纪念卡',
        ),
      ),
      body: switch (stage) {
        _Stage.loading => _loadingView(),
        _Stage.error => _errorView(),
        _Stage.empty => _emptyView(),
        _Stage.ready => _readyView(),
      },
    );
  }

  Widget _loadingView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(strokeWidth: 2),
          const SizedBox(height: 14),
          Text(
            regenerating ? '正在重新统计…' : '正在整理这段旅行…',
            style: const TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 22),
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('取消', style: TextStyle(color: Colors.white38)),
          ),
        ],
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              error ?? '生成失败',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, height: 1.6),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: _generate, child: const Text('重试')),
          ],
        ),
      ),
    );
  }

  Widget _emptyView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🧭', style: TextStyle(fontSize: 44)),
            const SizedBox(height: 14),
            Text(
              widget.config.personal
                  ? '这段时间没有${widget.config.personName}的出镜照片。\n可以调整时间范围，或先确认照片已识别完成。'
                  : '这段时间相册里还没有照片。\n调整一下时间范围试试。',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, height: 1.8),
            ),
            const SizedBox(height: 22),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('返回调整时间'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _readyView() {
    final config = widget.config;
    final s = snap!;
    final assets = ReportCardAssets(photos: photos, avatars: avatars);
    final Widget card = config.personal
        ? PersonalReportCard(
            model: _personalModel!,
            assets: assets,
            title: config.title,
            rangeLabel: config.range.shareLabel,
            location: config.location,
            multiDay: config.range.multiDay,
            sceneId: reportScenes[sceneIndex].id,
            layoutIndex: layoutIndex,
          )
        : TeamReportCard(
            model: _teamModel!,
            assets: assets,
            title: config.title,
            rangeLabel: config.range.shareLabel,
            location: config.location,
            sceneId: reportScenes[sceneIndex].id,
            layoutIndex: layoutIndex,
          );
    return Column(
      children: [
        Expanded(
          child: Center(
            child: FittedBox(
              fit: BoxFit.contain,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: kCardWidth,
                height: kCardHeight,
                child: RepaintBoundary(key: _boundaryKey, child: card),
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            8,
            20,
            8 + MediaQuery.paddingOf(context).bottom,
          ),
          child: Column(
            children: [
              if (s.timeNote)
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text(
                    '部分老照片的时间来自上传记录，可能近似 · 人物数据基于已识别照片',
                    style: TextStyle(color: Colors.white30, fontSize: 11),
                  ),
                ),
              if (!s.timeNote)
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text(
                    '人物数据基于已识别照片',
                    style: TextStyle(color: Colors.white30, fontSize: 11),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: saving ? null : _nextScene,
                      icon: const Icon(Icons.landscape_outlined, size: 17),
                      label: const Text('换底景'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: saving ? null : _nextLayout,
                      icon: const Icon(Icons.view_quilt_outlined, size: 17),
                      label: const Text('换版式'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: saving || regenerating ? null : _shuffle,
                      icon: const Icon(Icons.collections_outlined, size: 17),
                      label: const Text('换照片'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: regenerating || saving ? null : _regenerate,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重新统计'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: saving ? null : _save,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFF5E7A),
                      ),
                      icon: saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download, size: 18),
                      label: Text(saving ? '保存中…' : '保存到相册'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _regenerate() async {
    if (regenerating) return;
    setState(() => regenerating = true);
    try {
      await _generate();
    } finally {
      if (mounted) setState(() => regenerating = false);
    }
  }

  void _nextLayout() {
    if (stage != _Stage.ready || saving) return;
    setState(() => layoutIndex = (layoutIndex + 1) % reportLayouts.length);
  }

  void _nextScene() {
    if (stage != _Stage.ready || saving) return;
    setState(() => sceneIndex = (sceneIndex + 1) % reportScenes.length);
  }
}

/// RGBA → JPEG（在 isolate 里跑，不卡 UI）。
List<int> encodeRgbaAsJpeg(ByteData rgba, int w, int h) {
  final img = im.Image.fromBytes(
    width: w,
    height: h,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    numChannels: 4,
  );
  return im.encodeJpg(img, quality: 88);
}

/// 只把可发送的像素数据和尺寸交给后台 isolate，避免捕获 ui.Image。
Future<List<int>> encodeReportJpegOffload(ByteData rgba, int w, int h) =>
    Isolate.run(() => encodeRgbaAsJpeg(rgba, w, h));
