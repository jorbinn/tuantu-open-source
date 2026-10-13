/// 上传页：打开微信/抖音式相册多选，写入本机传输列表并并发上传。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../box/box_server.dart';
import '../main.dart';
import '../transfer.dart';
import '../upload_prep.dart';
import 'album_picker_page.dart';
import 'card_import_page.dart';
import 'transfers_page.dart';

class UploadPage extends StatefulWidget {
  const UploadPage({super.key, this.active = true});
  final bool active;
  @override
  State<UploadPage> createState() => UploadPageState();
}

class UploadPageState extends State<UploadPage> {
  final Set<String> session = {};
  bool _preparing = false;

  bool get uploading => TransferStore.I.running;

  @override
  void initState() {
    super.initState();
    TransferStore.I.addListener(_onTx);
  }

  @override
  void didUpdateWidget(covariant UploadPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active && mounted) setState(() {});
  }

  @override
  void dispose() {
    TransferStore.I.removeListener(_onTx);
    super.dispose();
  }

  void _onTx() {
    if (!mounted || !widget.active) return;
    setState(() {});
  }

  Future<void> pick() async {
    if (uploading || _preparing) return;
    final items = await AlbumPickerPage.open(context);
    if (!mounted || items == null || items.isEmpty) return;
    await enqueue(items);
  }

  Future<void> enqueue(List<PickedMedia> items) async {
    if (items.isEmpty || _preparing) return;
    _preparing = true;
    try {
      await _enqueue(items);
    } finally {
      _preparing = false;
      if (Platform.isIOS) {
        for (final item in items) {
          await item.releaseOwnedFiles();
        }
      }
    }
  }

  Future<void> _enqueue(List<PickedMedia> items) async {
    final box = Api.I.boxId;
    final token = Api.I.token;
    final kept = await _prepare(items);
    if (!mounted || kept.isEmpty) return;
    if (Platform.isIOS && (Api.I.boxId != box || Api.I.token != token)) {
      toast(context, '连接已切换，请在当前盒子重新选择上传');
      return;
    }
    late List<TransferJob> added;
    try {
      added = Platform.isIOS
          ? await TransferStore.I.addPersistent(kept)
          : TransferStore.I.addAll([
              for (final m in kept)
                (
                  path: m.path,
                  name: m.name,
                  day: m.day,
                  livePath: m.livePath,
                  liveRequired: m.liveRequired,
                  previewPath: m.previewPath,
                  takenAt: m.takenAt,
                ),
            ]);
    } catch (_) {
      if (mounted) toast(context, '无法保存待上传文件，请检查剩余空间后重新选择');
      return;
    }
    for (final j in added) {
      session.add(j.id);
    }
    await TransferStore.I.run();
    if (!mounted) return;
    // 不能一律报「上传完成」：按终态汇报
    final mine =
        TransferStore.I.jobs.where((j) => session.contains(j.id)).toList();
    final ok = mine.where((j) => j.state == 'done').length;
    final dup = mine.where((j) => j.state == 'duplicate').length;
    final bad = mine.where((j) => j.failed).length;
    final active = mine.where((j) => j.active).length;
    if (active > 0) {
      toast(context, '还有 $active 个在上传，可在传输列表查看');
    } else if (bad > 0) {
      toast(context, '完成：成功 $ok · 重复 $dup · 失败 $bad（可重试）');
    } else if (dup > 0) {
      toast(context, '完成：成功 $ok · 重复跳过 $dup');
    } else {
      toast(context, '上传完成！盒子正在后台分析');
    }
  }

  Future<List<PickedMedia>> _prepare(List<PickedMedia> items) async {
    // 只对照当前作者还在库里的作品（文件名+日期）。已删除的不算，可以再传。
    final keys = await Api.I.uploadKeys();
    final kept = excludeUploaded(items, keys);
    final skipped = items.length - kept.length;
    if (skipped > 0 && mounted) {
      toast(context, '已跳过 $skipped 个你作品里已有的文件');
    }
    if (kept.isEmpty) {
      if (mounted) toast(context, '所选文件在你的作品里都已有了');
      return const [];
    }
    final videos = kept.where((m) => m.isVideo).toList();
    final bytes = videos.fold<int>(0, (a, b) => a + b.size);
    if (!shouldWarnVideos(videoCount: videos.length, videoBytes: bytes)) {
      return kept;
    }
    if (!mounted) return const [];
    final onlyVideo = videos.length == kept.length;
    final mb = (bytes / (1024 * 1024)).toStringAsFixed(1);
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选中视频内存较大，确认上传？'),
        content: Text('${videos.length} 个视频 · $mb MB'),
        actions: [
          if (onlyVideo)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('取消上传'),
            )
          else
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'photos'),
              child: const Text('仅上传图片'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'all'),
            child: const Text('确定上传'),
          ),
        ],
      ),
    );
    if (action == 'all') return kept;
    if (action == 'photos') {
      final photos = kept.where((m) => !m.isVideo).toList();
      if (photos.isEmpty && mounted) toast(context, '没有可上传的图片');
      return photos;
    }
    return const [];
  }

  /// RAW / 音频等相册里不一定有的文件，才走系统文件页。
  Future<void> pickFromFiles() async {
    if (uploading) return;
    final r = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
      withData: false,
    );
    final files = r?.files.where((f) => f.path != null).toList() ?? [];
    if (files.isEmpty) return;
    final items = <PickedMedia>[];
    for (final f in files) {
      final path = f.path!;
      var day = mediaDay(DateTime.now());
      try {
        day = mediaDay(File(path).lastModifiedSync());
      } catch (_) {}
      items.add(PickedMedia(
        path: path,
        name: f.name,
        day: day,
        isVideo: isVideoName(f.name),
        size: f.size,
      ));
    }
    await enqueue(items);
  }

  Future<void> retryFailed() async {
    final failed = _sessionJobs.where((j) => j.failed).toList();
    for (final j in failed) {
      j.err = null;
      j.state = 'queued';
      j.status = '排队中';
      j.progress = 0;
    }
    await TransferStore.I.run();
  }

  List<TransferJob> get _sessionJobs {
    final map = {for (final j in TransferStore.I.jobs) j.id: j};
    return [
      for (final id in session)
        if (map[id] != null) map[id]!,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final queue = _sessionJobs;
    final failed = queue.where((u) => u.failed).toList();
    final done = queue.where((u) => !u.active).length;
    final progress = queue.isEmpty ? 0.0 : done / queue.length;
    final ok = queue.where((u) => u.state == 'done').length;
    final dup = queue.where((u) => u.state == 'duplicate').length;
    final bad = failed.length;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              const Text('上传照片 / 视频',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const Text(
                  '支持 JPG / HEIC / RAW / MP4 / MOV 等。按日期全选当天即可，已传过的会自动跳过。',
                  style: TextStyle(
                      color: Colors.white38, fontSize: 12, height: 1.6)),
              const SizedBox(height: 14),
              InkWell(
                onTap: uploading ? null : pick,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 34),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: const Color(0xFF2C343F),
                        width: 1.5,
                        style: BorderStyle.solid),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Column(children: [
                    Text('📤', style: TextStyle(fontSize: 34)),
                    SizedBox(height: 6),
                    Text('点这里打开相册（可按日期全选）',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54)),
                  ]),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: uploading ? null : pickFromFiles,
                  child: const Text('从文件选择 RAW / 音频',
                      style: TextStyle(color: Colors.white38, fontSize: 12)),
                ),
              ),
              if (Platform.isAndroid &&
                  BoxServer.I.running &&
                  BoxServer.I.isLocal)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: OutlinedButton.icon(
                    onPressed: uploading
                        ? null
                        : () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => const CardImportPage(),
                            )),
                    icon: const Icon(Icons.sd_card_outlined),
                    label: const Text('从相机存储卡导入并分配给团员'),
                  ),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => TransferButton.open(context),
                  child: const Text('查看传输列表',
                      style: TextStyle(color: Colors.white54, fontSize: 12)),
                ),
              ),
              if (queue.isNotEmpty) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: uploading || progress < 1 ? progress : 1,
                  minHeight: 4,
                  backgroundColor: const Color(0xFF222933),
                  color: const Color(0xFF38BDF8),
                ),
                const SizedBox(height: 8),
              ],
            ]),
          ),
        ),
        if (queue.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) {
                  final q = queue[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Expanded(
                        child: Text(q.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13)),
                      ),
                      Text(q.status,
                          style: TextStyle(
                              fontSize: 12,
                              color: q.failed
                                  ? const Color(0xFFFF6B6B)
                                  : Colors.white54)),
                    ]),
                  );
                },
                childCount: queue.length,
              ),
            ),
          ),
        if (queue.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                if (failed.isNotEmpty && !uploading)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: OutlinedButton(
                      onPressed: retryFailed,
                      child: Text('🔁 重试失败的 ${failed.length} 个'),
                    ),
                  ),
                if (!uploading)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('✅ 成功 $ok · ⏭️ 重复 $dup · ⚠️ 失败/不支持 $bad',
                        style: const TextStyle(color: Colors.white54)),
                  ),
              ]),
            ),
          ),
      ],
    );
  }
}
