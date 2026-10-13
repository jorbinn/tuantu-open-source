/// 本机传输列表 + 图片识别进度。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../api.dart';
import 'album_picker_page.dart';
import 'upload_page.dart';
import '../box/box_faces.dart';
import '../download.dart';
import '../transfer.dart';
import '../upload_prep.dart';
import '../widgets/box_image.dart';

class TransferButton extends StatelessWidget {
  const TransferButton({super.key, this.color});
  final Color? color;

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TransfersPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        TransferStore.I,
        DownloadStore.I,
        FaceEngine.I,
      ]),
      builder: (_, __) {
        final n = TransferStore.I.activeCount +
            DownloadStore.I.activeCount +
            FaceEngine.I.pending;
        return IconButton(
          tooltip: '传输列表',
          onPressed: () => open(context),
          icon: Badge(
            isLabelVisible: n > 0,
            label: Text('$n', style: const TextStyle(fontSize: 10)),
            child: Icon(Icons.swap_vert, color: color),
          ),
        );
      },
    );
  }
}

class TransfersPage extends StatelessWidget {
  const TransfersPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('传输列表'),
          bottom: const TabBar(
            indicatorColor: Color(0xFFFF5E7A),
            tabs: [
              Tab(text: '上传'),
              Tab(text: '下载'),
              Tab(text: '图片识别'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _TransferTab(),
            _DownloadTab(),
            _FaceTab(),
          ],
        ),
      ),
    );
  }
}

class _TransferTab extends StatelessWidget {
  const _TransferTab();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: TransferStore.I,
      builder: (_, __) {
        final jobs = TransferStore.I.newestFirst;
        if (jobs.isEmpty) {
          return const Center(
            child: Text('还没有传输记录', style: TextStyle(color: Colors.white38)),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          itemCount: jobs.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, color: Color(0xFF2C343F)),
          itemBuilder: (context, i) => _txRow(context, jobs[i]),
        );
      },
    );
  }

  Widget _txRow(BuildContext context, TransferJob j) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(width: 56, height: 56, child: _thumb(j)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(j.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  '${j.uploaderName == null ? '' : '归属 ${j.uploaderName} · '}${j.status} · ${_when(j.createdAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: _statusColor(j)),
                ),
                if (Platform.isIOS && j.failed && j.err != null)
                  Text(j.err!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, color: Colors.orangeAccent)),
                if (Platform.isIOS &&
                    j.failed &&
                    (j.err?.contains('重新选择') ?? false) &&
                    j.boxId == Api.I.boxId &&
                    j.sessionUserId == Api.I.userId)
                  TextButton(
                      onPressed: () async {
                        final items = await AlbumPickerPage.open(context);
                        if (!context.mounted ||
                            items == null ||
                            items.isEmpty) {
                          return;
                        }
                        if (j.boxId != Api.I.boxId ||
                            j.sessionUserId != Api.I.userId) {
                          for (final item in items) {
                            await item.releaseOwnedFiles();
                          }
                          return;
                        }
                        if (!context.mounted) return;
                        await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => _ReselectUpload(items: items)));
                      },
                      child: const Text('重新选择上传')),
                if (j.active)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: LinearProgressIndicator(
                      value:
                          j.progress > 0 && j.progress < 1 ? j.progress : null,
                      minHeight: 3,
                      backgroundColor: const Color(0xFF222933),
                      color: const Color(0xFF38BDF8),
                    ),
                  ),
              ],
            ),
          ),
          if (j.failed)
            IconButton(
              tooltip: '重试',
              onPressed: () => TransferStore.I.retry(j),
              icon: const Icon(Icons.refresh, color: Colors.white54),
            ),
        ],
      ),
    );
  }

  Widget _thumb(TransferJob j) {
    if (j.assetId != null && Api.I.base.isNotEmpty) {
      return BoxImage(
        '${Api.I.base}/api/asset/${j.assetId}/thumb',
        fit: BoxFit.cover,
        width: 56,
        height: 56,
        cacheWidth: 160,
      );
    }
    final ext = j.name.split('.').last.toLowerCase();
    const imgs = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'};
    try {
      final f = File(j.path);
      if (imgs.contains(ext) && f.existsSync()) {
        return Image.file(f, fit: BoxFit.cover, width: 56, height: 56);
      }
    } catch (_) {}
    return ColoredBox(
      color: const Color(0xFF222933),
      child: Center(
        child: Icon(
          ext == 'mp4' || ext == 'mov' || ext == 'm4v'
              ? Icons.videocam_outlined
              : Icons.insert_photo_outlined,
          color: Colors.white38,
        ),
      ),
    );
  }

  Color _statusColor(TransferJob j) {
    if (j.failed) return const Color(0xFFFF6B6B);
    if (j.state == 'done') return const Color(0xFF34D399);
    if (j.active) return const Color(0xFF38BDF8);
    return Colors.white54;
  }

  String _when(int ms) {
    if (ms <= 0 || plausibleWallClock(ms / 1000) == null) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String p(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }
}

class _DownloadTab extends StatelessWidget {
  const _DownloadTab();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DownloadStore.I,
      builder: (_, __) {
        final jobs = DownloadStore.I.newestFirst;
        if (jobs.isEmpty) {
          return const Center(
            child: Text('还没有下载记录', style: TextStyle(color: Colors.white38)),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          itemCount: jobs.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, color: Color(0xFF2C343F)),
          itemBuilder: (_, i) => _downloadRow(jobs[i]),
        );
      },
    );
  }

  Widget _downloadRow(DownloadJob job) {
    final active = job.active;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 56,
              height: 56,
              child: job.targetBase.isEmpty
                  ? const ColoredBox(color: Color(0xFF222933))
                  : BoxImage(
                      '${job.targetBase}/api/asset/${job.assetId}/thumb',
                      fit: BoxFit.cover,
                      width: 56,
                      height: 56,
                      cacheWidth: 160,
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (job.hasLive) ...[
                      const Icon(Icons.motion_photos_on_outlined,
                          size: 15, color: Color(0xFF38BDF8)),
                      const SizedBox(width: 5),
                    ],
                    Expanded(
                      child: Text(
                        job.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  job.err == null ? job.status : '${job.status} · ${job.err}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 12, color: _downloadStatusColor(job)),
                ),
                if (active)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: LinearProgressIndicator(
                      value: job.progress > 0 && job.progress < 1
                          ? job.progress
                          : null,
                      minHeight: 3,
                      backgroundColor: const Color(0xFF222933),
                      color: const Color(0xFF38BDF8),
                    ),
                  ),
              ],
            ),
          ),
          if (active)
            IconButton(
              tooltip: '取消下载',
              onPressed: () => DownloadStore.I.cancel(job),
              icon: const Icon(Icons.close, color: Colors.white54),
            )
          else if (job.failed)
            IconButton(
              tooltip: '重试',
              onPressed: () => DownloadStore.I.retry(job),
              icon: const Icon(Icons.refresh, color: Colors.white54),
            ),
        ],
      ),
    );
  }

  Color _downloadStatusColor(DownloadJob job) {
    if (job.failed) return const Color(0xFFFF6B6B);
    if (job.state == 'done') return const Color(0xFF34D399);
    if (job.active) return const Color(0xFF38BDF8);
    return Colors.white54;
  }
}

class _FaceTab extends StatelessWidget {
  const _FaceTab();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: FaceEngine.I,
      builder: (_, __) {
        final eng = FaceEngine.I;
        final jobs = eng.newestFirst;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Icon(
                    eng.ready ? Icons.face : Icons.hourglass_empty,
                    size: 18,
                    color: eng.ready ? const Color(0xFF34D399) : Colors.white38,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      eng.lastError != null
                          ? '模型异常：${eng.lastError}'
                          : eng.ready
                              ? (eng.pending > 0
                                  ? '正在识别，队列里还有 ${eng.pending} 张'
                                  : '识别空闲')
                              : (eng.starting ? '正在加载识别模型…' : '识别还没启动'),
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                  if (eng.ready)
                    TextButton(
                      onPressed: eng.pending > 0
                          ? null
                          : () => FaceEngine.I.requeueUnfaced(),
                      child: const Text('补识别', style: TextStyle(fontSize: 13)),
                    ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFF2C343F)),
            Expanded(
              child: jobs.isEmpty
                  ? const Center(
                      child: Text('还没有识别记录。新上传的照片会自动排队。',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white38)),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                      itemCount: jobs.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, color: Color(0xFF2C343F)),
                      itemBuilder: (_, i) => _faceRow(jobs[i]),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _faceRow(FaceJob j) {
    final color = j.state == 'failed'
        ? const Color(0xFFFF6B6B)
        : j.state == 'done'
            ? const Color(0xFF34D399)
            : const Color(0xFF38BDF8);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 56,
              height: 56,
              child: Api.I.base.isEmpty
                  ? const ColoredBox(color: Color(0xFF222933))
                  : BoxImage(
                      '${Api.I.base}/api/asset/${j.id}/thumb',
                      fit: BoxFit.cover,
                      width: 56,
                      height: 56,
                      cacheWidth: 160,
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(j.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(j.status, style: TextStyle(fontSize: 12, color: color)),
                if (j.active)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: LinearProgressIndicator(
                      minHeight: 3,
                      backgroundColor: Color(0xFF222933),
                      color: Color(0xFFFF5E7A),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReselectUpload extends StatefulWidget {
  const _ReselectUpload({required this.items});
  final List<PickedMedia> items;
  @override
  State<_ReselectUpload> createState() => _ReselectUploadState();
}

class _ReselectUploadState extends State<_ReselectUpload> {
  final _key = GlobalKey<UploadPageState>();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _key.currentState?.enqueue(widget.items);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('重新选择上传')),
        body: UploadPage(key: _key),
      );
}
