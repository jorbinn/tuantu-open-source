import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../api.dart';
import '../main.dart';
import '../report/report_card.dart';
import '../report/story_chapter.dart';
import '../report/story_day.dart';
import '../report/story_model.dart';
import '../saver.dart';
import 'report_card_page.dart' show encodeReportJpegOffload;

class ReportStoryPage extends StatefulWidget {
  const ReportStoryPage({super.key, required this.day});
  final StoryDay day;
  @override
  State<ReportStoryPage> createState() => _ReportStoryPageState();
}

class _ReportStoryPageState extends State<ReportStoryPage> {
  final scroll = ScrollController();
  final boundaryKey = GlobalKey();
  final chapterKeys = <GlobalKey>[];
  final revealed = <int>{0};
  final assets = ReportCardAssets(photos: {}, avatars: {});
  StoryModel? model;
  List<StoryChapter> chapters = [];
  bool personal = true, loading = true, saving = false;
  bool _imagesLoading = true;
  int missingImages = 0;
  String? error;
  CancelToken? _cancel;
  int _generation = 0;
  double progress = 0;

  @override
  void initState() {
    super.initState();
    scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _cancel?.cancel();
    scroll.dispose();
    _disposeImages();
    super.dispose();
  }

  void _disposeImages() {
    for (final image in assets.photos.values) {
      image.dispose();
    }
    for (final image in assets.avatars.values) {
      image.dispose();
    }
    assets.photos.clear();
    assets.avatars.clear();
  }

  void _onScroll() {
    if (!mounted || !scroll.hasClients || saving) return;
    final height = MediaQuery.sizeOf(context).height;
    setState(() {
      progress = scroll.position.maxScrollExtent <= 0
          ? 0
          : (scroll.offset / scroll.position.maxScrollExtent).clamp(0, 1);
      for (var i = 0; i < chapterKeys.length; i++) {
        final box = chapterKeys[i].currentContext?.findRenderObject();
        if (box is RenderBox &&
            box.hasSize &&
            box.localToGlobal(Offset.zero).dy < height * .92) {
          revealed.add(i);
        }
      }
    });
  }

  void _setChapters() {
    chapters = model!.chapters(personal);
    chapterKeys.clear();
    chapterKeys.addAll(List.generate(chapters.length, (_) => GlobalKey()));
    revealed
      ..clear()
      ..add(0);
    progress = 0;
  }

  Future<void> _load() async {
    if (saving) return;
    final generation = ++_generation;
    _cancel?.cancel();
    final token = _cancel = CancelToken();
    setState(() {
      loading = true;
      _imagesLoading = true;
      error = null;
    });
    try {
      final data = await Api.I.storyData(
        day: widget.day.key,
        offset: widget.day.offsetMinutes,
        cancelToken: token,
      );
      if (!mounted || generation != _generation) return;
      _disposeImages();
      model = StoryModel(data, requested: widget.day);
      if (model!.moments == 0) {
        setState(() {
          loading = false;
          error = '这一天的影像已移除，返回列表看看其他日子。';
        });
        return;
      }
      _setChapters();
      final allChapters = [...model!.chapters(true), ...model!.chapters(false)];
      final photoIds = <int>{};
      final avatarPaths = <String>{};
      if (model!.selfPerson.cover case final path?) avatarPaths.add(path);
      for (final chapter in allChapters) {
        photoIds.addAll(chapter.photoIds);
        for (final person in chapter.people.take(8)) {
          photoIds.addAll(person.photoIds);
          if (person.cover case final path?) avatarPaths.add(path);
        }
      }
      var missed = 0;
      final jobs = <Future<void> Function()>[
        for (final id in photoIds)
          () async {
            final image = await _image(
              '/api/asset/$id/report-preview',
              token,
              photoId: id,
            );
            if (!mounted || generation != _generation) {
              image?.dispose();
              return;
            }
            if (image == null) {
              missed++;
            } else {
              assets.photos[id] = image;
            }
          },
        for (final path in avatarPaths)
          () async {
            final image = await _image(path, token, target: 160);
            if (!mounted || generation != _generation) {
              image?.dispose();
              return;
            }
            if (image != null) assets.avatars[path] = image;
          },
      ];
      // Bound image work to three requests, including when the hotspot is slow.
      for (var i = 0; i < jobs.length; i += 3) {
        if (!mounted || generation != _generation) return;
        await Future.wait(jobs.skip(i).take(3).map((job) => job()));
        if (!mounted || generation != _generation) return;
        setState(() {
          loading = false;
          missingImages = missed;
        });
        if (i == 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
        }
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        missingImages = missed;
        loading = false;
        _imagesLoading = false;
      });
      if (jobs.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
      }
    } catch (e) {
      if (!mounted ||
          generation != _generation ||
          (e is DioException && CancelToken.isCancel(e))) {
        return;
      }
      final body = e is DioException ? e.response?.data : null;
      setState(() {
        loading = false;
        _imagesLoading = false;
        error = body is Map && body['code'] == 'claim_required'
            ? '你的认领已变化，请返回列表重新确认「这是我」。'
            : e is DioException && e.response?.statusCode == 429
            ? '另一份报告正在生成，稍后重试就好。'
            : '故事暂时没有加载成功，连上盒子后再试一次。';
      });
    }
  }

  Future<ui.Image?> _image(
    String path,
    CancelToken token, {
    int? photoId,
    int target = 900,
  }) async {
    try {
      List<int> bytes;
      if (photoId != null) {
        bytes = await Api.I.reportPreviewBytes(photoId, token);
      } else {
        final response = await retryNet(
          () => Api.I.dio.get<List<int>>(
            path,
            cancelToken: token,
            options: Options(
              responseType: ResponseType.bytes,
              validateStatus: (status) => status == 200,
              receiveTimeout: const Duration(seconds: 15),
            ),
          ),
          attempts: 2,
          cancelToken: token,
        );
        bytes = response.data!;
      }
      if (token.isCancelled) return null;
      final buffer = await ui.ImmutableBuffer.fromUint8List(
        Uint8List.fromList(bytes),
      );
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          final scale = math.min(
            1.0,
            target / math.max(descriptor.width, descriptor.height),
          );
          final codec = await descriptor.instantiateCodec(
            targetWidth: math.max(1, (descriptor.width * scale).round()),
            targetHeight: math.max(1, (descriptor.height * scale).round()),
          );
          try {
            return (await codec.getNextFrame()).image;
          } finally {
            codec.dispose();
          }
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  void _switch(bool value) {
    if (saving || personal == value) return;
    setState(() {
      personal = value;
      _setChapters();
    });
    if (scroll.hasClients) scroll.jumpTo(0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
  }

  Future<void> _save() async {
    if (saving || loading || _imagesLoading || model == null) return;
    if (missingImages > 0) {
      toast(context, '部分照片尚未加载完整，请点重试后再保存');
      return;
    }
    setState(() => saving = true);
    try {
      // Force every chapter and number visible; scrolling position must never
      // affect the exported story. The entire Column is built, not a lazy list.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final boundary =
          boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final ratio = math.min(
        1080 / boundary.size.width,
        12000 / boundary.size.height,
      );
      final image = await boundary.toImage(pixelRatio: ratio);
      late List<int> jpeg;
      try {
        final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (rgba == null) throw StateError('No pixels');
        jpeg = await encodeReportJpegOffload(rgba, image.width, image.height);
      } finally {
        image.dispose();
      }
      if (!mounted) return;
      await Saver.saveReportImage(
        jpeg,
        title: 'tuantu_story_${widget.day.key}_${personal ? 'me' : 'us'}.jpg',
      );
      if (mounted) toast(context, '整段故事已保存为长图');
    } catch (_) {
      if (mounted) toast(context, '长图保存失败，请确认相册权限和剩余空间后重试');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: storyAccent,
        brightness: Brightness.dark,
        surface: storySurface,
      ),
      scaffoldBackgroundColor: storyPaper,
      appBarTheme: const AppBarTheme(
        backgroundColor: storyPaper,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
    ),
    child: PopScope(
      canPop: !saving,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: storyPaper,
          title: Text(widget.day.label, style: const TextStyle(fontSize: 16)),
          actions: [
            IconButton(
              tooltip: '更新这一天的故事',
              onPressed: saving || loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: loading
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 20),
                    Text('正在收好这一天的故事…'),
                  ],
                ),
              )
            : error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(error!, textAlign: TextAlign.center),
                      const SizedBox(height: 20),
                      FilledButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                ),
              )
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 2, 24, 12),
                    child: SegmentedButton<bool>(
                      style: ButtonStyle(
                        foregroundColor: WidgetStateProperty.resolveWith(
                          (states) => states.contains(WidgetState.selected)
                              ? Colors.white
                              : Colors.white60,
                        ),
                        backgroundColor: WidgetStateProperty.resolveWith(
                          (states) => states.contains(WidgetState.selected)
                              ? storyAccent
                              : storySurface,
                        ),
                      ),
                      segments: const [
                        ButtonSegment(value: true, label: Text('我的这一天')),
                        ButtonSegment(value: false, label: Text('我们的这一天')),
                      ],
                      selected: {personal},
                      onSelectionChanged: saving
                          ? null
                          : (v) => _switch(v.first),
                    ),
                  ),
                  LinearProgressIndicator(
                    value: progress,
                    minHeight: 2,
                    color: storyAccent,
                    backgroundColor: storyAccent.withValues(alpha: .1),
                  ),
                  Expanded(
                    child: Stack(
                      children: [
                        SingleChildScrollView(
                          controller: scroll,
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 480),
                              child: RepaintBoundary(
                                key: boundaryKey,
                                child: Column(
                                  children: [
                                    for (var i = 0; i < chapters.length; i++)
                                      KeyedSubtree(
                                        key: chapterKeys[i],
                                        child: _reveal(
                                          i,
                                          StoryChapterView(
                                            chapter: chapters[i],
                                            model: model!,
                                            assets: assets,
                                            personal: personal,
                                            index: i,
                                            revealed: revealed.contains(i),
                                            exporting: saving,
                                            minHeight:
                                                (MediaQuery.sizeOf(context)
                                                            .height *
                                                        .75)
                                                    .clamp(480, 620),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (saving)
                          const Positioned.fill(
                            child: ColoredBox(
                              color: Color(0xEE080A0D),
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircularProgressIndicator(),
                                    SizedBox(height: 20),
                                    Text('正在把整段故事装进长图…'),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (missingImages > 0)
                    TextButton(
                      onPressed: saving ? null : _load,
                      child: Text(
                        '$missingImages 张照片暂未加载，点此重试',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: storyAccent,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: saving || _imagesLoading ? null : _save,
                          icon: const Icon(Icons.download_outlined),
                          label: Text(
                            saving
                                ? '正在保存…'
                                : _imagesLoading
                                ? '正在加载报告图片…'
                                : '保存完整故事长图',
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    ),
  );

  Widget _reveal(int index, Widget child) {
    if (saving || MediaQuery.disableAnimationsOf(context)) return child;
    final show = revealed.contains(index);
    return AnimatedOpacity(
      opacity: show ? 1 : 0,
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOut,
      child: AnimatedScale(
        scale: show ? 1 : .965,
        duration: const Duration(milliseconds: 680),
        curve: Curves.easeOutBack,
        child: AnimatedSlide(
          offset: show ? Offset.zero : const Offset(0, .055),
          duration: const Duration(milliseconds: 620),
          curve: Curves.easeOutCubic,
          child: child,
        ),
      ),
    );
  }
}
