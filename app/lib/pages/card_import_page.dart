/// Camera-card import for the Android box phone.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../api.dart';
import '../box/box_server.dart';
import '../card_reader.dart';
import '../main.dart';
import '../transfer.dart';
import 'transfers_page.dart';

class CardImportPage extends StatefulWidget {
  const CardImportPage({super.key, this.autoChoose = false});
  final bool autoChoose;

  @override
  State<CardImportPage> createState() => _CardImportPageState();
}

class _CardImportPageState extends State<CardImportPage> {
  String sourceName = '存储卡';
  String? treeUri;
  List<CardMedia> media = const [];
  final selected = <String>{};
  bool loading = true;
  String? error;
  String filter = 'all';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    if (!Platform.isAndroid || !BoxServer.I.running || !BoxServer.I.isLocal) {
      setState(() {
        loading = false;
        error = '请先在这台安卓手机上打开「我来当盒子」，再插入读卡器。';
      });
      return;
    }
    final saved = await CardReader.I.savedTree();
    if (!mounted) return;
    if (saved == null || widget.autoChoose) {
      await _chooseSource();
    } else {
      treeUri = saved.uri;
      sourceName = saved.name;
      await _scan();
    }
  }

  Future<void> _chooseSource() async {
    final picked = await CardReader.I.chooseTree();
    if (!mounted) return;
    if (picked == null) {
      setState(() => loading = false);
      return;
    }
    treeUri = picked.uri;
    sourceName = picked.name;
    await _scan();
  }

  Future<void> _scan() async {
    final uri = treeUri;
    if (uri == null) return;
    setState(() {
      loading = true;
      error = null;
      selected.clear();
    });
    try {
      final found = await CardReader.I.scan(uri);
      if (!mounted) return;
      setState(() {
        media = found;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = '无法读取这个目录，可能存储卡已拔出或授权失效。\n$e';
      });
    }
  }

  List<CardMedia> get visible => switch (filter) {
        'photo' => media.where((e) => !e.isVideo).toList(),
        'video' => media.where((e) => e.isVideo).toList(),
        'raw' => media.where((e) => e.isRaw).toList(),
        _ => media,
      };

  Map<String, List<CardMedia>> get groups {
    final out = <String, List<CardMedia>>{};
    for (final item in visible) {
      (out[item.day] ??= []).add(item);
    }
    return out;
  }

  void _toggleDay(List<CardMedia> items) {
    final all = items.every((e) => selected.contains(e.uri));
    setState(() {
      for (final item in items) {
        if (all) {
          selected.remove(item.uri);
        } else {
          selected.add(item.uri);
        }
      }
    });
  }

  Future<void> _assignAndImport() async {
    final chosen = media.where((e) => selected.contains(e.uri)).toList();
    if (chosen.isEmpty) return;
    final bytes = chosen.fold<int>(0, (n, e) => n + e.size);
    final largest = chosen.fold<int>(0, (n, e) => e.size > n ? e.size : n);
    final space = await CardReader.I.space();
    if (!mounted) return;
    if (space != null && space.boxFree > 0 && bytes > space.boxFree * 0.92) {
      toast(context, '盒子空间不足：所选 ${_size(bytes)}，可用约 ${_size(space.boxFree)}');
      return;
    }
    if (space != null &&
        space.cacheFree > 0 &&
        largest > space.cacheFree * 0.92) {
      toast(context, '临时空间不足以读取最大的文件，请减少选择或释放手机空间');
      return;
    }
    List<Map<String, dynamic>> users;
    try {
      users = await Api.I.users();
    } catch (e) {
      if (mounted) toast(context, '读取团员失败：$e');
      return;
    }
    if (!mounted || users.isEmpty) return;
    final byDay = <String, List<CardMedia>>{};
    for (final item in chosen) {
      (byDay[item.day] ??= []).add(item);
    }
    var split = false;
    var allUser = Api.I.userId ?? (users.first['id'] as num).toInt();
    final dayUsers = <String, int>{
      for (final day in byDay.keys) day: allUser,
    };
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1F26),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        Widget picker(int value, ValueChanged<int?> changed) =>
            DropdownButtonFormField<int>(
              initialValue: value,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: [
                for (final u in users)
                  DropdownMenuItem(
                    value: (u['id'] as num).toInt(),
                    child: Text((u['name'] ?? '未命名').toString()),
                  )
              ],
              onChanged: changed,
            );
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                20, 18, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('这些作品归谁？',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text('${chosen.length} 项 · 作品会显示在所选团员名下',
                    style: const TextStyle(color: Colors.white54)),
                const SizedBox(height: 18),
                if (!split)
                  picker(allUser, (v) {
                    if (v == null) return;
                    setSheet(() {
                      allUser = v;
                      for (final day in dayUsers.keys) {
                        dayUsers[day] = v;
                      }
                    });
                  }),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('不同日期分配给不同团员'),
                  value: split,
                  onChanged: (v) => setSheet(() => split = v),
                ),
                if (split)
                  for (final e in byDay.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(children: [
                        SizedBox(
                            width: 110,
                            child: Text('${e.key}\n${e.value.length} 项')),
                        Expanded(
                          child: picker(dayUsers[e.key]!,
                              (v) => setSheet(() => dayUsers[e.key] = v!)),
                        ),
                      ]),
                    ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('确认归属并开始导入'),
                  ),
                ),
              ]),
            ),
          ),
        );
      }),
    );
    if (ok != true || !mounted) return;
    final names = {
      for (final u in users)
        (u['id'] as num).toInt(): (u['name'] ?? '未命名').toString()
    };
    for (final item in chosen) {
      final uid = dayUsers[item.day] ?? allUser;
      TransferStore.I.addCard(
        uri: item.uri,
        name: item.name,
        day: item.day,
        takenAt: item.takenAt > 0 ? item.takenAt : null,
        uploaderId: uid,
        uploaderName: names[uid] ?? '团员',
      );
    }
    unawaited(TransferStore.I.run());
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const TransfersPage()));
  }

  @override
  Widget build(BuildContext context) {
    final selectedItems = media.where((e) => selected.contains(e.uri));
    final bytes = selectedItems.fold<int>(0, (n, e) => n + e.size);
    return Scaffold(
      appBar: AppBar(
        title: Text(sourceName),
        actions: [
          IconButton(
              tooltip: '重新扫描',
              onPressed: loading ? null : _scan,
              icon: const Icon(Icons.refresh)),
          TextButton(
              onPressed: loading ? null : _chooseSource,
              child: const Text('换目录')),
        ],
      ),
      body: error != null
          ? _ErrorView(message: error!, retry: _chooseSource)
          : loading
              ? const Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 14),
                  Text('正在读取拍摄日期和文件信息…'),
                ]))
              : media.isEmpty
                  ? _ErrorView(
                      message: '这个目录里没有找到可导入的照片或视频。', retry: _chooseSource)
                  : Column(children: [
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                        child: Row(children: [
                          for (final f in const [
                            ('all', '全部'),
                            ('photo', '照片'),
                            ('video', '视频'),
                            ('raw', 'RAW'),
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(f.$2),
                                selected: filter == f.$1,
                                onSelected: (_) =>
                                    setState(() => filter = f.$1),
                              ),
                            ),
                        ]),
                      ),
                      Expanded(
                        child: CustomScrollView(
                          slivers: [
                            for (final e in groups.entries) ...[
                              SliverPadding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                                sliver: SliverToBoxAdapter(
                                    child: _dayHeader(e.key, e.value)),
                              ),
                              SliverPadding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                                sliver: SliverGrid(
                                  gridDelegate:
                                      const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 4,
                                    crossAxisSpacing: 4,
                                    mainAxisSpacing: 4,
                                  ),
                                  delegate: SliverChildBuilderDelegate(
                                    (_, i) => _mediaTile(e.value[i]),
                                    childCount: e.value.length,
                                  ),
                                ),
                              ),
                              const SliverToBoxAdapter(
                                  child: SizedBox(height: 8)),
                            ],
                            const SliverToBoxAdapter(
                                child: SizedBox(height: 110)),
                          ],
                        ),
                      ),
                    ]),
      bottomNavigationBar: selected.isEmpty
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                decoration: const BoxDecoration(color: Color(0xFF1A1F26)),
                child: Row(children: [
                  Expanded(
                    child: Text('已选 ${selected.length} 项 · ${_size(bytes)}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  FilledButton(
                      onPressed: _assignAndImport, child: const Text('选择归属')),
                ]),
              ),
            ),
    );
  }

  Widget _dayHeader(String day, List<CardMedia> items) {
    final n = items.where((e) => selected.contains(e.uri)).length;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(day, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text('${items.length} 项${n > 0 ? ' · 已选 $n' : ''}'),
      trailing: TextButton(
        onPressed: () => _toggleDay(items),
        child: Text(n == items.length ? '取消全选' : '全选当天'),
      ),
    );
  }

  Widget _mediaTile(CardMedia item) {
    final on = selected.contains(item.uri);
    return GestureDetector(
      onTap: () => setState(() {
        if (!selected.add(item.uri)) selected.remove(item.uri);
      }),
      child: Stack(fit: StackFit.expand, children: [
        _CardThumb(item: item),
        if (on) Container(color: const Color(0x6638BDF8)),
        Positioned(
          top: 4,
          right: 4,
          child: Icon(on ? Icons.check_circle : Icons.circle_outlined,
              color: on ? const Color(0xFF38BDF8) : Colors.white, size: 22),
        ),
        if (item.isRaw)
          const Positioned(
            left: 4,
            bottom: 4,
            child: Text('RAW',
                style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900)),
          ),
        if (item.isVideo)
          const Positioned(
            left: 4,
            top: 4,
            child: Icon(Icons.videocam, size: 18),
          ),
      ]),
    );
  }

  static String _size(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}

class _CardThumb extends StatefulWidget {
  const _CardThumb({required this.item});
  final CardMedia item;

  @override
  State<_CardThumb> createState() => _CardThumbState();
}

class _CardThumbState extends State<_CardThumb> {
  late final Future<String?> path = CardReader.I.thumbnail(widget.item.uri);

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
        future: path,
        builder: (_, snap) {
          final p = snap.data;
          if (p != null) {
            return Image.file(File(p),
                fit: BoxFit.cover, errorBuilder: (_, __, ___) => _fallback());
          }
          return _fallback();
        },
      );

  Widget _fallback() => ColoredBox(
        color: const Color(0xFF252C35),
        child: Center(
          child: Icon(
              widget.item.isVideo ? Icons.movie_outlined : Icons.image_outlined,
              color: Colors.white38),
        ),
      );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.retry});
  final String message;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.sd_card_outlined, size: 52, color: Colors.white38),
            const SizedBox(height: 14),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 18),
            FilledButton(onPressed: retry, child: const Text('选择存储卡目录')),
          ]),
        ),
      );
}
