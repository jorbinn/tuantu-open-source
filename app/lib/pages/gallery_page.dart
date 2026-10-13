/// 相册：五大入口 + 按上传人；点进去才是按天网格。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../gallery_refresh.dart';
import '../main.dart';
import '../widgets/save_progress.dart';
import '../widgets/box_image.dart';
import '../widgets/live_photo_badge.dart';
import '../widgets/feed_action_rail.dart';
import 'feed_viewer_page.dart';
import 'me_page.dart';

class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key, this.initialView = 'all', this.active = true});
  final String initialView;
  final bool active;
  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  Map<String, dynamic>? home;
  bool loading = false;

  /// IndexedStack 让这页常驻，刷新被在途请求吞掉就会一直旧下去，
  /// 所以在途时收到的新刷新诉求记在这里，跑完立刻补一次。
  bool _pending = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    galleryChanged.addListener(_onGalleryChanged);
    Api.endpointChanges.addListener(_onGalleryChanged);
    load();
    if (widget.initialView.startsWith('person:')) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final pid = int.tryParse(widget.initialView.split(':').last);
        if (pid == null) return;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => GalleryAlbumPage(
            title: '人物相册',
            view: widget.initialView,
          ),
        ));
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    galleryChanged.removeListener(_onGalleryChanged);
    Api.endpointChanges.removeListener(_onGalleryChanged);
    super.dispose();
  }

  void _onGalleryChanged() {
    if (!mounted || !widget.active) return;
    load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.active) load();
  }

  @override
  void didUpdateWidget(covariant GalleryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) load();
  }

  Future<void> load() async {
    if (loading) {
      _pending = true;
      return;
    }
    setState(() => loading = true);
    try {
      home = await Api.I.galleryHome();
      BoxImageRevival.bump();
    } catch (e) {
      if (mounted) toast(context, friendlyNet(e, '加载'));
    }
    if (mounted) setState(() => loading = false);
    if (_pending) {
      _pending = false;
      unawaited(load());
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final h = home;
    final uploaders = (h?['uploaders'] as List?) ?? const [];
    return RefreshIndicator(
      color: const Color(0xFFFF5E7A),
      onRefresh: load,
      child: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 14,
                crossAxisSpacing: 12,
                childAspectRatio: 0.86,
              ),
              delegate: SliverChildListDelegate([
                _sysAlbum(
                  title: '最近项目',
                  pack: h?['recent'],
                  onTap: () => _openAlbum('最近项目', 'all'),
                ),
                _sysAlbum(
                  title: '我喜欢的',
                  pack: h?['liked'],
                  onTap: () => _openAlbum('我喜欢的', 'liked'),
                ),
                _sysAlbum(
                  title: '所有图片',
                  pack: h?['images'],
                  onTap: () => _openAlbum('所有图片', 'images'),
                ),
                _sysAlbum(
                  title: '所有视频',
                  pack: h?['videos'],
                  onTap: () => _openAlbum('所有视频', 'videos'),
                ),
                _sysAlbum(
                  title: '合照',
                  pack: h?['group'],
                  onTap: () => _openAlbum('合照', 'group'),
                ),
              ]),
            ),
          ),
          if (uploaders.isNotEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 22, 16, 10),
                child: Text('小伙伴们',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: Colors.white70)),
              ),
            ),
          if (uploaders.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 28),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.86,
                ),
                delegate: SliverChildBuilderDelegate(
                  (_, i) => _personAlbum(uploaders[i]),
                  childCount: uploaders.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _openAlbum(String title, String view, {String sort = 'time'}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GalleryAlbumPage(title: title, view: view, sort: sort),
    ));
  }

  Widget _sysAlbum({
    required String title,
    required dynamic pack,
    required VoidCallback onTap,
  }) {
    final n = (pack is Map ? pack['count'] : 0) ?? 0;
    final cover = pack is Map ? pack['cover']?.toString() : null;
    return _albumCard(
      title: title,
      count: n is num ? n.toInt() : 0,
      cover: cover,
      onTap: onTap,
    );
  }

  Widget _personAlbum(dynamic raw) {
    final p = raw is Map ? raw : <String, dynamic>{};
    final name = (p['name'] ?? '未命名').toString();
    final id = (p['id'] as num?)?.toInt();
    final n = (p['count'] as num?)?.toInt() ?? 0;
    final cover = p['cover']?.toString();
    final avatar = p['avatar']?.toString();
    return _albumCard(
      title: name,
      count: n,
      cover: cover,
      avatar: avatar,
      avatarName: name,
      onTap: () {
        if (id == null) return;
        MePage.open(context, userId: id, userName: name);
      },
    );
  }

  Widget _albumCard({
    required String title,
    required int count,
    String? cover,
    String? avatar,
    String? avatarName,
    required VoidCallback onTap,
  }) {
    final url =
        (cover != null && cover.isNotEmpty) ? '${Api.I.base}$cover' : null;
    final av =
        (avatar != null && avatar.isNotEmpty) ? '${Api.I.base}$avatar' : null;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: url == null
                        ? const ColoredBox(color: Color(0xFF222933))
                        : BoxImage(url, fit: BoxFit.cover, cacheWidth: 512),
                  ),
                ),
                if (avatarName != null)
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x99000000),
                            blurRadius: 8,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                      child: UserAvatar(name: avatarName, url: av, radius: 22),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          Text('$count 项',
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }
}

class GalleryAlbumPage extends StatefulWidget {
  const GalleryAlbumPage({
    super.key,
    required this.title,
    required this.view,
    this.sort = 'time',
  });
  final String title;
  final String view;
  final String sort;

  @override
  State<GalleryAlbumPage> createState() => _GalleryAlbumPageState();
}

class _GalleryAlbumPageState extends State<GalleryAlbumPage> {
  List<CardItem> items = [];
  double? cursor;
  int? cursorId;
  bool end = false, loading = false;
  String? _loadError;
  bool selecting = false;
  /// Bumped after every successful page load: failed (gray) thumbnails retry.
  int _thumbEpoch = 0;
  bool pickingCover = false;
  final selected = <int>{};
  bool saving = false;
  final _listCtrl = ScrollController();
  final _cellKeys = <int, GlobalKey>{};
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    galleryChanged.addListener(_onGalleryChanged);
    Api.endpointChanges.addListener(_endpointChanged);
    load();
  }

  @override
  void dispose() {
    galleryChanged.removeListener(_onGalleryChanged);
    Api.endpointChanges.removeListener(_endpointChanged);
    _listCtrl.dispose();
    super.dispose();
  }

  /// 本页开着时有人上传入库：只把「比当前列表第一项更新」的新项合并到
  /// 头部，不清空已加载内容，浏览位置不被打断；更老的照片下拉刷新再看。
  Future<void> _onGalleryChanged() async {
    if (!mounted || loading) return;
    final gen = ++_loadGen;
    try {
      final d = await Api.I.gallery(widget.view, limit: 90, sort: widget.sort);
      if (!mounted || gen != _loadGen) return;
      final list =
          ((d['items'] as List?) ?? []).map((e) => CardItem(e)).toList();
      final known = {for (final c in items) c.id};
      list.retainWhere((c) => known.add(c.id));
      final cutoff = items.isEmpty ? null : _rank(items.first);
      final fresh = [
        for (final c in list)
          if (cutoff == null || _rank(c) >= cutoff) c,
      ];
      if (fresh.isEmpty) return;
      setState(() => items = [...fresh, ...items]);
    } catch (_) {}
  }

  double _rank(CardItem c) {
    if (widget.sort == 'upload') {
      return (c.createdAt?.round() ?? c.takenAt ?? 0).toDouble();
    }
    return (c.takenAt ?? c.createdAt?.round() ?? 0).toDouble();
  }

  GlobalKey _cellKey(int id) =>
      _cellKeys.putIfAbsent(id, () => GlobalKey(debugLabel: 'album-cell-$id'));

  void _endpointChanged() {
    if (!mounted || loading) return;
    if (items.isEmpty) {
      load();
    } else {
      // Retain the loaded pages and scroll offset when the address recovers.
      setState(() => _loadError = null);
      _onGalleryChanged();
    }
  }

  Future<void> load({bool more = false}) async {
    if (loading) return;
    if (more && end) return;
    setState(() {
      loading = true;
      _loadError = null;
    });
    try {
      final d = await Api.I.gallery(
        widget.view,
        cursor: more ? cursor : null,
        cursorId: more ? cursorId : null,
        limit: 90,
        sort: widget.sort,
      );
      if (!mounted) return;
      final list =
          ((d['items'] as List?) ?? []).map((e) => CardItem(e)).toList();
      setState(() {
        // 每个格子用资源 id 做 GlobalKey；同一 id 出现两次会让整组构建失败。
        if (more) {
          final known = {for (final c in items) c.id};
          items.addAll(list.where((c) => known.add(c.id)));
        } else {
          final known = <int>{};
          items = [
            for (final c in list)
              if (known.add(c.id)) c
          ];
        }
        cursor = (d['cursor'] as num?)?.toDouble();
        cursorId = (d['cursor_id'] as num?)?.toInt();
        end = list.length < 90;
        _thumbEpoch++;
      });
      BoxImageRevival.bump();
    } catch (e) {
      if (mounted) setState(() => _loadError = friendlyNet(e, '加载'));
    }
    if (mounted) setState(() => loading = false);
  }

  int? get _personId {
    if (!widget.view.startsWith('person:')) return null;
    return int.tryParse(widget.view.split(':').last);
  }

  String _dayOf(CardItem c) {
    if (widget.sort == 'upload') {
      return dayKey(c.createdAt?.round() ?? c.takenAt);
    }
    return dayKey(c.takenAt ?? c.createdAt?.round());
  }

  @override
  Widget build(BuildContext context) {
    final days = <String, List<CardItem>>{};
    final order = <String>[];
    for (final c in items) {
      final k = _dayOf(c);
      if (!days.containsKey(k)) {
        days[k] = [];
        order.add(k);
      }
      days[k]!.add(c);
    }
    // 没有可信拍摄日期的照片统一放到最后的「时间未知」组。
    if (order.remove('unknown')) order.add('unknown');
    return PopScope(
      canPop: !selecting && !pickingCover,
      onPopInvokedWithResult: (did, _) {
        if (did) return;
        if (selecting) {
          setState(() {
            selecting = false;
            selected.clear();
          });
          return;
        }
        if (pickingCover) {
          setState(() => pickingCover = false);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(pickingCover
              ? '选择一张照片作为封面'
              : (selecting ? '已选 ${selected.length}' : widget.title)),
          actions: [
            if (selecting)
              TextButton(
                onPressed: () => setState(() {
                  selecting = false;
                  selected.clear();
                }),
                child: const Text('取消'),
              )
            else if (pickingCover)
              TextButton(
                onPressed: () => setState(() => pickingCover = false),
                child: const Text('取消'),
              )
            else if (_personId != null)
              TextButton(
                onPressed: items.isEmpty
                    ? null
                    : () => setState(() => pickingCover = true),
                child: const Text('更换封面'),
              ),
          ],
        ),
        bottomNavigationBar: selecting
            ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: FilledButton(
                    onPressed:
                        selected.isEmpty || saving ? null : _saveSelected,
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFF5E7A),
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                    child: Text(saving ? '保存中…' : '保存到相册（${selected.length}）'),
                  ),
                ),
              )
            : null,
        body: items.isEmpty && !loading
            ? RefreshIndicator(
                onRefresh: () => load(),
                child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 80),
                      Center(
                          child: Text(_loadError ?? '还没有照片',
                              textAlign: TextAlign.center)),
                      if (_loadError != null)
                        Center(
                            child: TextButton(
                                onPressed: () => load(),
                                child: const Text('重新加载'))),
                    ]),
              )
            : RefreshIndicator(
                color: const Color(0xFFFF5E7A),
                onRefresh: () => load(),
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (!end &&
                        !loading &&
                        n.metrics.pixels > n.metrics.maxScrollExtent - 600) {
                      load(more: true);
                    }
                    return false;
                  },
                  child: ListView.builder(
                    controller: _listCtrl,
                    // ignore: deprecated_member_use
                    cacheExtent: 1600,
                    padding: const EdgeInsets.only(bottom: 20),
                    itemCount: order.length + 1,
                    itemBuilder: (_, i) {
                      if (i >= order.length) {
                        if (_loadError != null) {
                          return Column(children: [
                            Text(_loadError!, textAlign: TextAlign.center),
                            TextButton(
                                onPressed: () => load(more: true),
                                child: const Text('重新加载')),
                          ]);
                        }
                        if (!end) {
                          return const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          );
                        }
                        return const Padding(
                          padding: EdgeInsets.fromLTRB(16, 18, 16, 28),
                          child: Center(
                            child: Text('没有更多啦',
                                style: TextStyle(
                                    color: Colors.white38, fontSize: 13)),
                          ),
                        );
                      }
                      final k = order[i];
                      String label = '时间未知';
                      final d = k == 'unknown'
                          ? null
                          : DateTime.tryParse('${k}T00:00:00Z');
                      if (d != null) {
                        const wd = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
                        label = '${d.month}月${d.day}日 ${wd[d.weekday - 1]}';
                      }
                      final dayItems = days[k]!;
                      final allOn =
                          dayItems.every((c) => selected.contains(c.id));
                      return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 12, 16, 6),
                              child: Row(
                                children: [
                                  if (selecting)
                                    Checkbox(
                                      value: allOn,
                                      activeColor: const Color(0xFFFF5E7A),
                                      onChanged: (_) => _toggleDay(dayItems),
                                    ),
                                  Expanded(
                                    child: GestureDetector(
                                      onLongPress: () {
                                        setState(() {
                                          selecting = true;
                                          selected.addAll(
                                              dayItems.map((e) => e.id));
                                        });
                                      },
                                      onTap: selecting
                                          ? () => _toggleDay(dayItems)
                                          : null,
                                      child: Text(label,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              color: Colors.white60)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            GridView.count(
                              crossAxisCount: 3,
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              mainAxisSpacing: 4,
                              crossAxisSpacing: 4,
                              childAspectRatio: 1,
                              children: [for (final c in dayItems) _cell(c)],
                            ),
                          ]);
                    },
                  ),
                ),
              ),
      ),
    );
  }

  void _toggleDay(List<CardItem> day) {
    setState(() {
      selecting = true;
      final ids = [for (final c in day) c.id];
      final allOn = ids.every(selected.contains);
      if (allOn) {
        selected.removeAll(ids);
        if (selected.isEmpty) selecting = false;
      } else {
        selected.addAll(ids);
      }
    });
  }

  Future<void> _setCover(CardItem c) async {
    final pid = _personId;
    if (pid == null || saving) return;
    setState(() => saving = true);
    try {
      await Api.I.setPersonCover(pid, assetId: c.id);
      if (!mounted) return;
      setState(() {
        saving = false;
        pickingCover = false;
      });
      toast(context, '封面已更换');
    } catch (e) {
      if (!mounted) return;
      setState(() => saving = false);
      toast(context, friendlyNet(e, '更换封面'));
    }
  }

  Future<void> _saveSelected() async {
    if (saving || selected.isEmpty) return;
    setState(() => saving = true);
    try {
      final chosen = [
        for (final item in items)
          if (selected.contains(item.id)) item,
      ];
      final added = await queueDownloads(chosen);
      if (!mounted) return;
      toast(context, added > 0 ? '已加入下载列表 $added 项' : '所选内容已在下载列表中');
    } catch (e) {
      if (mounted) toast(context, friendlyNet(e, '加入下载列表'));
    }
    if (!mounted) return;
    setState(() {
      saving = false;
      selecting = false;
      selected.clear();
    });
  }

  Widget _cell(CardItem c) => KeyedSubtree(
        key: ValueKey('album-cell-${c.id}'),
        child: GestureDetector(
          key: _cellKey(c.id),
          onTap: () {
            if (pickingCover) {
              _setCover(c);
              return;
            }
            if (selecting) {
              setState(() {
                if (selected.contains(c.id)) {
                  selected.remove(c.id);
                  if (selected.isEmpty) selecting = false;
                } else {
                  selected.add(c.id);
                }
              });
              return;
            }
            _openFeed(c);
          },
          onLongPress: pickingCover
              ? null
              : () {
                  setState(() {
                    selecting = true;
                    selected.add(c.id);
                  });
                },
          child: Stack(fit: StackFit.expand, children: [
            c.wantThumb
                ? BoxImage(
                    '${Api.I.base}${c.thumb}',
                    fit: BoxFit.cover,
                    retryEpoch: _thumbEpoch,
                    maxRetryDelay: BoxImage.gridRetryDelay,
                    // 多选/挑封面时点击有别的意思，不拦截。
                    retryOnTap: !selecting && !pickingCover,
                  )
                : Container(
                    color: const Color(0xFF222933),
                    alignment: Alignment.center,
                    child: Text(
                        c.kind == 'video'
                            ? '🎬'
                            : c.kind == 'audio'
                                ? '🎵'
                                : 'RAW',
                        style: const TextStyle(color: Colors.white38)),
                  ),
            if (c.hasLive)
              const Positioned(left: 6, bottom: 6, child: LivePhotoBadge()),
            if (c.kind == 'video')
              const Positioned(
                  right: 4,
                  top: 4,
                  child: Text('🎬', style: TextStyle(fontSize: 11))),
            if (c.likes > 0)
              Positioned(
                  left: 4,
                  top: 4,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        c.liked ? Icons.favorite : Icons.favorite_border,
                        color: c.liked ? const Color(0xFFFE2C55) : Colors.white,
                        size: 13,
                        shadows: const [Shadow(blurRadius: 4)],
                      ),
                      const SizedBox(width: 2),
                      Text('${c.likes}',
                          style: const TextStyle(
                              fontSize: 10, shadows: [Shadow(blurRadius: 4)])),
                    ],
                  )),
            if (pickingCover)
              const Positioned(
                right: 4,
                bottom: 4,
                child: Icon(Icons.face,
                    color: Colors.white,
                    size: 18,
                    shadows: [Shadow(blurRadius: 4)]),
              ),
            if (selecting)
              Positioned(
                right: 4,
                bottom: 4,
                child: Icon(
                  selected.contains(c.id)
                      ? Icons.check_circle
                      : Icons.circle_outlined,
                  color: selected.contains(c.id)
                      ? const Color(0xFFFF5E7A)
                      : Colors.white70,
                  size: 22,
                ),
              ),
          ]),
        ),
      );

  Future<void> _openFeed(CardItem c) async {
    final openedId = c.id;
    final i = items.indexWhere((e) => e.id == openedId);
    final viewedId = await FeedViewerPage.open(
      context,
      items: items,
      initialIndex: i < 0 ? 0 : i,
      onLoadMore: end ? null : () => load(more: true),
      onProfile: (u) => MePage.open(
        context,
        userId: u.uploaderId,
        userName: u.uploader,
      ),
    );
    if (!mounted) return;
    setState(() {});
    final id = viewedId ?? openedId;
    if (!shouldRevealSource(
      openedId: openedId,
      viewedId: viewedId,
      openedStillExists: items.any((e) => e.id == openedId),
    )) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealItem(id);
    });
  }

  double _estimateOffset(int id) {
    final width = MediaQuery.sizeOf(context).width;
    final cell = (width - 8) / 3;
    const header = 38.0;
    var y = 0.0;
    final days = <String, List<CardItem>>{};
    final order = <String>[];
    for (final c in items) {
      final k = _dayOf(c);
      if (!days.containsKey(k)) {
        days[k] = [];
        order.add(k);
      }
      days[k]!.add(c);
    }
    if (order.remove('unknown')) order.add('unknown');
    for (final k in order) {
      final dayItems = days[k]!;
      y += header;
      final idx = dayItems.indexWhere((e) => e.id == id);
      if (idx >= 0) {
        y += (idx ~/ 3) * (cell + 4);
        return y;
      }
      final rows = (dayItems.length / 3).ceil();
      if (rows > 0) {
        y += rows * cell + (rows - 1) * 4;
      }
    }
    return y;
  }

  Future<void> _revealItem(int id) async {
    if (!mounted || !items.any((e) => e.id == id)) return;
    if (_listCtrl.hasClients) {
      final max = _listCtrl.position.maxScrollExtent;
      _listCtrl.jumpTo(_estimateOffset(id).clamp(0.0, max));
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final ctx = _cellKeys[id]?.currentContext;
    if (ctx == null || !ctx.mounted) return;
    await Scrollable.ensureVisible(
      ctx,
      alignment: 0.3,
      duration: Duration.zero,
      alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
    );
  }
}
