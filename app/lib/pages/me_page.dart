/// 个人主页：抖音式资料 + 作品网格。主人可改名/头像；长按进入多选，批量删除前二次确认。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../main.dart';
import '../transfer.dart';
import '../widgets/box_image.dart';
import '../widgets/live_photo_badge.dart';
import '../widgets/feed_action_rail.dart';
import 'album_picker_page.dart';
import 'feed_viewer_page.dart';
import 'settings_page.dart';
import 'transfers_page.dart';

class MePage extends StatefulWidget {
  const MePage({super.key, this.userId, this.userName});

  /// null 表示当前登录用户（「我的」Tab）。
  final int? userId;
  final String? userName;

  static Future<void> open(
    BuildContext context, {
    int? userId,
    String? userName,
  }) {
    if (userId == null) {
      toast(context, '暂时打不开这个主页');
      return Future.value();
    }
    return Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MePage(userId: userId, userName: userName),
    ));
  }

  @override
  State<MePage> createState() => MePageState();
}

class MePageState extends State<MePage> with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? me;
  List<CardItem> items = [];
  String sort = 'time';
  bool showSortTabs = false;
  int offset = 0;
  double? cursor;
  int? cursorId;
  bool end = false;
  bool loading = false;
  bool legacyBox = false;
  bool avatarBusy = false;
  bool _wasUploading = false;
  bool _reloadQueued = false;
  bool _offsetPaging = false;
  bool _queuedFull = false;
  /// Bumped after every successful list load: failed (gray) thumbnails retry.
  int _thumbEpoch = 0;
  /// 主人长按进入多选；批量删除前二次确认。别人的主页没有多选。
  bool selecting = false;
  final selected = <int>{};
  bool deleting = false;
  final _listCtrl = ScrollController();
  final _cellKeys = <int, GlobalKey>{};

  static const _sorts = [
    ('time', '时间'),
    ('likes', '点赞'),
    ('comments', '评论量'),
  ];

  bool get _isOwner =>
      widget.userId == null || widget.userId == Api.I.userId;

  @override
  bool get wantKeepAlive => widget.userId == null;

  @override
  void initState() {
    super.initState();
    Api.endpointChanges.addListener(_endpointChanged);
    load();
    if (_isOwner) TransferStore.I.addListener(_onTx);
  }

  @override
  void dispose() {
    Api.endpointChanges.removeListener(_endpointChanged);
    if (_isOwner) TransferStore.I.removeListener(_onTx);
    _listCtrl.dispose();
    super.dispose();
  }

  GlobalKey _cellKey(int id) =>
      _cellKeys.putIfAbsent(id, () => GlobalKey(debugLabel: 'me-cell-$id'));

  void _onTx() {
    final run = TransferStore.I.running;
    if (_wasUploading && !run) {
      if (loading) {
        _reloadQueued = true;
        _queuedFull = true;
      } else {
        load();
      }
    }
    _wasUploading = run;
  }

  num? _asNum(dynamic v) {
    if (v is num) return v;
    if (v is String) return num.tryParse(v);
    return null;
  }

  num? _lastUploadTs() {
    num? best = _asNum(me?['last_upload']);
    for (final c in items) {
      final t = c.createdAt;
      if (t != null && t > 0 && (best == null || t > best)) best = t;
    }
    if (_isOwner) {
      for (final j in TransferStore.I.jobs) {
        if (j.state != 'done' || j.updatedAt <= 0) continue;
        final t = j.updatedAt / 1000;
        if (best == null || t > best) best = t;
      }
    }
    return best;
  }

  void _endpointChanged() {
    if (mounted) {
      setState(() {});
      if (!loading) load(preservePosition: true);
    }
  }

  Future<void> load({bool more = false, bool preservePosition = false}) async {
    if (loading) {
      if (!more) {
        _reloadQueued = true;
        if (!preservePosition) _queuedFull = true;
      }
      return;
    }
    setState(() => loading = true);
    try {
      if (!more) {
        if (_isOwner) {
          me = await Api.I.me();
        } else {
          me = await Api.I.userProfile(widget.userId!);
          if ((me?['name'] as String?)?.isEmpty == true &&
              widget.userName != null) {
            me = {...?me, 'name': widget.userName};
          }
        }
        // Retain existing contents until the refresh has succeeded.
      }
      final acc = <CardItem>[];
      var off = more ? offset : 0;
      var cur = more ? cursor : null;
      var curId = more ? cursorId : null;
      var localEnd = false;
      var legacy = false;
      for (var i = 0; i < 12; i++) {
        final d = _isOwner
            ? await Api.I.myAssets(
                sort: sort, offset: off, limit: 90, cursor: cur, cursorId: curId)
            : await Api.I.userAssets(widget.userId!,
                sort: sort, offset: off, limit: 90, cursor: cur, cursorId: curId);
        legacy = d['legacy'] == true;
        final raw = ((d['items'] as List?) ?? []).map((e) => CardItem(e)).toList();
        final keep = _isOwner ? raw.where((e) => e.isOwn).toList() : raw;
        acc.addAll(keep);
        off = (d['offset'] as num?)?.toInt() ?? off + raw.length;
        cur = (d['cursor'] as num?)?.toDouble();
        curId = (d['cursor_id'] as num?)?.toInt();
        localEnd = d['end'] == true || (!legacy && raw.length < 90);
        if (!legacy || localEnd || acc.length >= 90) break;
        if (cur == null && raw.isEmpty) break;
      }
      if (!mounted) return;
      setState(() {
        // 已加载的都在刷回来的第一页里：直接整体换成第一页，offset 与列表
        // 一致（只合并不换会漏掉删除后补进第一页末尾的那一张）。
        final coveredByFirstPage = items.length <= acc.length;
        if (preservePosition && items.isNotEmpty && !coveredByFirstPage) {
          final updated = {for (final item in acc) item.id: item};
          items = [for (final item in items) updated[item.id] ?? item];
        } else if (more) {
          // 格子用作品 id 做 GlobalKey，重复 id 会让整页构建失败。
          final known = {for (final item in items) item.id};
          items.addAll(acc.where((item) => known.add(item.id)));
        } else {
          items = acc;
        }
        if (!preservePosition || coveredByFirstPage) {
          offset = off;
          cursor = cur;
          cursorId = curId;
          end = localEnd;
        }
        legacyBox = legacy || me?['id'] == null;
        // 新盒子的 /api/me/assets、/api/user/{id}/assets 按 offset 翻页；
        // legacy 兜底走 /api/gallery 的游标，不看 offset。
        _offsetPaging = !legacy;
        _thumbEpoch++;
      });
      BoxImageRevival.bump();
    } catch (e) {
      if (mounted) toast(context, friendlyNet(e, '加载'));
    }
    if (mounted) setState(() => loading = false);
    if (_reloadQueued) {
      final full = _queuedFull;
      _reloadQueued = false;
      _queuedFull = false;
      await load(preservePosition: !full);
    }
  }

  String get _sortLabel => _sorts.firstWhere((s) => s.$1 == sort).$2;

  Future<void> _openUser(CardItem c) async {
    final id = c.uploaderId;
    if (id == null) {
      toast(context, '暂时打不开这个主页');
      return;
    }
    if (widget.userId == id) return;
    if (_isOwner && (id == Api.I.userId || c.isOwn) && widget.userId == null) {
      return;
    }
    await MePage.open(context, userId: id, userName: c.uploader);
  }

  Future<void> _editName() async {
    if (!_isOwner) return;
    final ctrl = TextEditingController(text: Api.I.name);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('改名字'),
        content: TextField(
          controller: ctrl,
          maxLength: 20,
          autofocus: true,
          decoration: const InputDecoration(hintText: '你的名字'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (next == null || next.isEmpty || next == Api.I.name) return;
    try {
      await Api.I.updateProfile(next);
      final p = await SharedPreferences.getInstance();
      await p.setString('name', Api.I.name);
      if (mounted) {
        setState(() {
          me = {...?me, 'name': Api.I.name};
        });
      }
      await load();
    } catch (e) {
      if (mounted) toast(context, friendlyNet(e, '改名'));
    }
  }

  Future<void> _editAvatar() async {
    if (!_isOwner || avatarBusy) return;
    final paths = await AlbumPickerPage.open(context, maxCount: 1, imageOnly: true);
    if (!mounted || paths == null || paths.isEmpty) return;
    setState(() => avatarBusy = true);
    try {
      // HEIC 头像走本机导出的 JPEG 预览；盒子解不了 HEIC
      final src = paths.first.previewPath ?? paths.first.path;
      final r = await Api.I.updateAvatar(src);
      if (mounted) {
        setState(() {
          me = {...?me, 'avatar': r['avatar']};
        });
      }
      await load();
    } catch (e) {
      if (mounted) toast(context, friendlyNet(e, '换头像'));
    }
    if (mounted) setState(() => avatarBusy = false);
  }

  Future<void> _openFeed(CardItem c) async {
    final openedId = c.id;
    final i = items.indexWhere((e) => e.id == openedId);
    final viewedId = await FeedViewerPage.open(
      context,
      items: items,
      initialIndex: i < 0 ? 0 : i,
      onLoadMore: end ? null : () => load(more: true),
      onProfile: _openUser,
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

  Future<void> _revealItem(int id) async {
    if (!mounted || !items.any((e) => e.id == id)) return;
    final idx = items.indexWhere((e) => e.id == id);
    if (_listCtrl.hasClients && idx >= 0) {
      final w = MediaQuery.sizeOf(context).width;
      final cols = (w / 160).floor().clamp(3, 6);
      final cell = (w - 2 - (cols - 1)) / cols;
      var y = 120.0 + (showSortTabs ? 44.0 : 0);
      y += (idx ~/ cols) * (cell + 1);
      final max = _listCtrl.position.maxScrollExtent;
      _listCtrl.jumpTo(y.clamp(0.0, max));
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

  void _exitSelect() {
    setState(() {
      selecting = false;
      selected.clear();
    });
  }

  void _enterSelect(CardItem c) {
    if (!_isOwner || deleting) return;
    setState(() {
      selecting = true;
      selected.add(c.id);
    });
  }

  void _toggleSelect(CardItem c) {
    setState(() {
      if (!selected.add(c.id)) selected.remove(c.id);
    });
  }

  /// 二次确认：取消不删；确认后才真正删除。空选禁用。
  @visibleForTesting
  Future<bool> confirmDeleteDialog(int n) async {
    if (n <= 0) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('确定删除这 $n 张照片？'),
        content: const Text('删除后无法恢复'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFF6B6B),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _confirmBatchDelete() async {
    if (!_isOwner || deleting || selected.isEmpty) return;
    final n = selected.length;
    if (!await confirmDeleteDialog(n) || !mounted) return;
    await deleteSelectedInPlace();
  }

  /// 批量原地删除：滚动位置与已加载分页不动；offset 翻页时每删一张起点前移一位；
  /// 某张失败则放回原位。取消确认不会走到这里。
  @visibleForTesting
  Future<void> deleteSelectedInPlace() async {
    if (!_isOwner || deleting) return;
    final ids = selected.toList();
    if (ids.isEmpty) return;
    final victims = <({int index, CardItem item})>[];
    for (var i = 0; i < items.length; i++) {
      if (ids.contains(items[i].id)) {
        victims.add((index: i, item: items[i]));
      }
    }
    if (victims.isEmpty) return;
    final uploadedBefore = me?['uploaded'];
    final shift =
        _offsetPaging ? (victims.length < offset ? victims.length : offset) : 0;
    setState(() {
      deleting = true;
      items.removeWhere((e) => ids.contains(e.id));
      selecting = false;
      selected.clear();
      if (uploadedBefore is num && uploadedBefore > 0) {
        final next = uploadedBefore - victims.length;
        me = {...?me, 'uploaded': next < 0 ? 0 : next};
      }
      if (shift > 0) offset -= shift;
    });
    final failed = <({int index, CardItem item})>[];
    Object? lastErr;
    for (final v in victims) {
      try {
        await Api.I.deleteAsset(v.item.id);
      } catch (e) {
        lastErr = e;
        failed.add(v);
      }
    }
    if (!mounted) return;
    if (failed.isNotEmpty) {
      setState(() {
        failed.sort((a, b) => a.index.compareTo(b.index));
        for (final v in failed) {
          if (!items.any((x) => x.id == v.item.id)) {
            items.insert(v.index.clamp(0, items.length), v.item);
          }
        }
        if (uploadedBefore != null) {
          final cur = me?['uploaded'];
          if (cur is num) {
            me = {...?me, 'uploaded': cur + failed.length};
          } else {
            me = {...?me, 'uploaded': uploadedBefore};
          }
        }
        if (_offsetPaging) offset += failed.length;
      });
      toast(
        context,
        failed.length == victims.length && lastErr != null
            ? friendlyNet(lastErr, '删除')
            : '有 ${failed.length} 张没删掉，已放回原位',
      );
    } else {
      toast(
        context,
        victims.length == 1 ? '已删除' : '已删除 ${victims.length} 张',
      );
    }
    setState(() => deleting = false);
    unawaited(load(preservePosition: true));
  }

  /// 原地删除单张（测试与兼容）：走同一套批量逻辑。
  @visibleForTesting
  Future<void> deleteInPlace(CardItem c) async {
    selected
      ..clear()
      ..add(c.id);
    selecting = true;
    await deleteSelectedInPlace();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final m = me;
    final name = (m?['name'] ?? widget.userName ?? Api.I.name).toString();
    final uploaded = _asNum(m?['uploaded'])?.toInt() ?? items.length;
    final last = fmtLastUpload(_lastUploadTs());
    String? avatar = m?['avatar']?.toString();
    if (avatar != null && avatar.isNotEmpty && !avatar.startsWith('http')) {
      avatar = '${Api.I.base}$avatar';
    }
    // Inspect this page's route, not a settings/viewer route above it. A
    // connection refresh can rebuild this page while that overlay is open.
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    final title = selecting
        ? '已选 ${selected.length}'
        : (_isOwner && !canPop ? '我的' : name);
    final w = MediaQuery.sizeOf(context).width;
    final cols = (w / 160).floor().clamp(3, 6);
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (did, _) {
        if (did) return;
        if (selecting) _exitSelect();
      },
      child: Scaffold(
      backgroundColor: const Color(0xFF0F1216),
      bottomNavigationBar: selecting
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton(
                  onPressed: selected.isEmpty || deleting
                      ? null
                      : _confirmBatchDelete,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFFF6B6B),
                    disabledBackgroundColor: const Color(0xFF3A2226),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(
                    deleting
                        ? '删除中…'
                        : '删除（${selected.length}）',
                  ),
                ),
              ),
            )
          : null,
      body: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: Column(
      children: [
        SafeArea(
          bottom: false,
          child: SizedBox(
            height: 46,
            child: Row(
              children: [
                if (selecting)
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: deleting ? null : _exitSelect,
                  )
                else if (canPop)
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.pop(context),
                  )
                else
                  const SizedBox(width: 12),
                Expanded(
                  child: Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w800, fontSize: 17)),
                ),
                if (selecting)
                  TextButton(
                    onPressed: deleting ? null : _exitSelect,
                    child: const Text('取消'),
                  )
                else if (_isOwner && !canPop) ...[
                  const TransferButton(),
                  IconButton(
                    tooltip: '设置',
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SettingsPage()),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            color: const Color(0xFFFF5E7A),
            onRefresh: () => load(),
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (!end && !loading &&
                    n.metrics.pixels > n.metrics.maxScrollExtent - 600) {
                  load(more: true);
                }
                return false;
              },
              child: CustomScrollView(
                controller: _listCtrl,
                // ignore: deprecated_member_use
                cacheExtent: 1600,
                slivers: [
                  SliverToBoxAdapter(child: _profile(name, avatar, uploaded, last)),
                  if (legacyBox && _isOwner)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(
                          '当前盒子还是旧版。作品已只显示你自己上传的；改名字和头像需要先更新盒子服务。',
                          style: TextStyle(color: Color(0xFFFBBF24), fontSize: 12, height: 1.4),
                        ),
                      ),
                    ),
                  SliverToBoxAdapter(child: _worksHeader()),
                  if (showSortTabs) SliverToBoxAdapter(child: _sortTabs()),
                  if (items.isEmpty && !loading)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Text('还没有作品', style: TextStyle(color: Colors.white38)),
                      ),
                    )
                  else ...[
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(1, 0, 1, 8),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          mainAxisSpacing: 1,
                          crossAxisSpacing: 1,
                          childAspectRatio: 1,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (_, i) => _cell(items[i]),
                          childCount: items.length,
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                        child: Center(
                          child: end
                              ? const Text('没有更多啦',
                                  style: TextStyle(color: Colors.white38, fontSize: 13))
                              : const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
        ),
      ),
    ),
    );
  }

  Widget _profile(String name, String? avatar, int uploaded, String last) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: _isOwner ? _editAvatar : null,
            child: Stack(
              children: [
                UserAvatar(name: name, url: avatar, radius: 40),
                if (avatarBusy)
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: Color(0x66000000), shape: BoxShape.circle),
                      child: Center(child: SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )),
                    ),
                  )
                else if (_isOwner)
                  const Positioned(
                    right: 0,
                    bottom: 0,
                    child: CircleAvatar(
                      radius: 11,
                      backgroundColor: Color(0xFFFF5E7A),
                      child: Icon(Icons.camera_alt, size: 12, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: _isOwner ? _editName : null,
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(name,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
                      ),
                      if (_isOwner) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.edit, size: 16, color: Colors.white38),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text('作品 $uploaded',
                    style: const TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 4),
                Text(
                  last.isEmpty ? '上次上传：还没有' : '上次上传：$last',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _worksHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        children: [
          const Icon(Icons.grid_on, size: 16, color: Colors.white70),
          const SizedBox(width: 6),
          const Text('作品', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          const Spacer(),
          TextButton.icon(
            onPressed: () => setState(() => showSortTabs = !showSortTabs),
            icon: const Icon(Icons.sort, size: 18, color: Colors.white70),
            label: Text(_sortLabel, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _sortTabs() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final s in _sorts)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(s.$2),
                selected: sort == s.$1,
                selectedColor: const Color(0xFFFF5E7A),
                backgroundColor: const Color(0xFF1A1F26),
                side: const BorderSide(color: Color(0xFF2C343F)),
                onSelected: (_) {
                  setState(() {
                    sort = s.$1;
                    showSortTabs = true;
                  });
                  load();
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _cell(CardItem c) {
    final on = selected.contains(c.id);
    return KeyedSubtree(
      key: ValueKey('me-cell-${c.id}'),
      child: GestureDetector(
      key: _cellKey(c.id),
      onTap: () {
        if (selecting) {
          _toggleSelect(c);
          return;
        }
        _openFeed(c);
      },
      onLongPress: _isOwner && !deleting ? () => _enterSelect(c) : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          c.wantThumb
              ? BoxImage(
                  '${Api.I.base}${c.thumb}',
                  fit: BoxFit.cover,
                  retryEpoch: _thumbEpoch,
                  maxRetryDelay: BoxImage.gridRetryDelay,
                  retryOnTap: !selecting,
                )
              : Container(
                  color: const Color(0xFF222933),
                  alignment: Alignment.center,
                  child: Text(
                    c.kind == 'video' ? '🎬' : c.kind == 'audio' ? '🎵' : 'RAW',
                    style: const TextStyle(color: Colors.white38),
                  ),
                ),
          if (c.hasLive)
            const Positioned(left: 6, bottom: 6, child: LivePhotoBadge()),
          if (c.kind == 'video')
            const Positioned(
              right: 6,
              top: 6,
              child: Icon(Icons.play_circle_fill, color: Colors.white, size: 18),
            ),
          if (c.likes > 0)
            Positioned(
              left: c.hasLive ? 36 : 6,
              bottom: 6,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    c.liked ? Icons.favorite : Icons.favorite_border,
                    color: c.liked
                        ? const Color(0xFFFE2C55)
                        : Colors.white,
                    size: 14,
                    shadows: const [Shadow(blurRadius: 4)],
                  ),
                  const SizedBox(width: 2),
                  Text('${c.likes}',
                      style: const TextStyle(
                          fontSize: 11,
                          shadows: [Shadow(blurRadius: 4)])),
                ],
              ),
            ),
          if (selecting)
            Positioned(
              right: 6,
              top: 6,
              child: Icon(
                on ? Icons.check_circle : Icons.circle_outlined,
                color: on ? const Color(0xFFFF5E7A) : Colors.white,
                size: 22,
                shadows: const [Shadow(blurRadius: 4)],
              ),
            ),
        ],
      ),
    ),
    );
  }
}
