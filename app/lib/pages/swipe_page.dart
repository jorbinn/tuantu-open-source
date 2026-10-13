/// 选片页：抖音式上下滑照片/视频流。右栏头像/赞/评/下载；左右滑切顶部 tab。
/// 每个 tab 记住浏览位置，直到退出 App 或刷新该列表。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../like_sync.dart';
import '../main.dart';
import '../widgets/feed_gestures.dart';
import '../widgets/feed_media.dart';
import '../widgets/save_progress.dart';
import '../widgets/zoomable.dart';
import 'me_page.dart';

enum FeedLoadReason {
  initial,
  scopeChange,
  passiveResume,
  userRefresh,
  recommendationRefresh,
  pagination,
}

typedef _FeedItemStamp = ({
  int id,
  String thumb,
  String kind,
  String ext,
  String origName,
  String uploader,
  int? uploaderId,
  String? avatar,
  bool hasThumb,
  bool mine,
  bool hasLive,
  bool liked,
  int likes,
  int comments,
  int width,
  int height,
  double? duration,
  int? takenAt,
  double? createdAt,
});

class SwipePage extends StatefulWidget {
  const SwipePage({super.key, this.active = true, this.onCleanChanged});
  final bool active;
  final ValueChanged<bool>? onCleanChanged;

  @override
  State<SwipePage> createState() => SwipePageState();
}

class _FeedTabSnap {
  const _FeedTabSnap({
    required this.items,
    required this.page,
    required this.cursor,
    required this.cursorId,
    required this.end,
  });

  final List<CardItem> items;
  final int page;
  final double? cursor;
  final int? cursorId;
  final bool end;
}

class SwipePageState extends State<SwipePage> {
  static const feedTabs = [
    ('最近更新', 'all'),
    ('推荐', 'recommended'),
    ('有我的', 'mine'),
    ('热门', 'hot'),
  ];

  String view = 'all';
  String _loadedView = '';
  List<CardItem> items = [];
  double? cursor;
  int? cursorId;
  bool end = false;

  /// 请求代际号：慢网下快速切筛选时，旧请求的响应不允许写进新筛选的页面
  int _loadSeq = 0;
  bool loading = false;
  int page = 0;
  bool zoomed = false;
  bool clean = false;
  double speed = 1.0;
  final Set<int> _saving = {};
  final Set<int> _seen = {};
  final List<int> _recommendedRecent = [];
  List<dynamic> personsCache = [];
  PageController _pc = PageController();
  final _pageLock = ValueNotifier(false);
  final _pageDrag = PagingDragMemory();
  final _session = FeedGestureSession();
  int _pagerGen = 0;
  final ValueNotifier<double> _tabDrag = ValueNotifier(0);
  bool _mineUnseenOnly = false;
  final _likes = LikeCoordinator();

  /// 每个信息流 Tab 各自记住列表和浏览位置，退出 App 或刷新该列表后丢弃。
  final Map<String, _FeedTabSnap> _tabCache = {};

  @override
  void initState() {
    super.initState();
    _session.stopPageDrag = _stopPageDrag;
    load(reason: FeedLoadReason.initial);
  }

  void _stopPageDrag() {
    if (!_pc.hasClients) return;
    try {
      _pc.position.hold(() {});
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant SwipePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active && oldWidget.active) {
      _session.cancelRound?.call();
      setState(() {});
    }
  }

  @override
  void dispose() {
    if (_session.stopPageDrag == _stopPageDrag) {
      _session.stopPageDrag = null;
    }
    _session.cancelRound?.call();
    _pc.dispose();
    _pageLock.dispose();
    _tabDrag.dispose();
    super.dispose();
  }

  String get _viewKey =>
      view == 'mine' && _mineUnseenOnly ? 'mine_unseen' : view;

  void _rebindPager(int initial) {
    final old = _pc;
    _pagerGen++;
    _pc = PageController(initialPage: initial);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      old.dispose();
    });
  }

  void _stashCurrent() {
    if (_loadedView.isEmpty) return;
    final p = items.isEmpty ? 0 : page.clamp(0, items.length - 1);
    _tabCache[_loadedView] = _FeedTabSnap(
      items: List<CardItem>.from(items),
      page: p,
      cursor: cursor,
      cursorId: cursorId,
      end: end,
    );
  }

  bool _restoreView(String key) {
    final snap = _tabCache[key];
    if (snap == null) return false;
    _loadSeq++;
    final t =
        snap.items.isEmpty ? 0 : snap.page.clamp(0, snap.items.length - 1);
    _rebindPager(t);
    setState(() {
      items = List<CardItem>.from(snap.items);
      page = t;
      cursor = snap.cursor;
      cursorId = snap.cursorId;
      end = snap.end;
      _loadedView = key;
      loading = false;
      zoomed = false;
      _pageLock.value = false;
    });
    if (items.isNotEmpty) _markSeen(items[page]);
    return true;
  }

  void _goView(String next) {
    if (view == next) {
      if (next == 'recommended') {
        load(reason: FeedLoadReason.recommendationRefresh);
      }
      return;
    }
    _stashCurrent();
    view = next;
    HapticFeedback.selectionClick();
    if (_restoreView(_viewKey)) return;
    load(reason: FeedLoadReason.scopeChange);
  }

  double _hdx = 0;
  double _leadOverscroll = 0;
  double _tailOverscroll = 0;
  DateTime? _endHintAt;

  void _snapPage() {
    if (!_pc.hasClients || items.isEmpty) return;
    final p = _pc.page;
    if (p == null) return;
    final t = p.round().clamp(0, items.length - 1);
    if ((p - t).abs() > 0.001) _pc.jumpToPage(t);
  }

  /// 双指落下或放大时立刻锁翻页并吸回整页，避免半页偏移导致单向滑不动。
  void _onZoomed(bool z) {
    // 状态没变化（尤其普通单指松手的 false→false）完全不动滚动；
    // 只在真正进入锁定时对齐整页，解锁只放锁。jumpToPage 会终止当前
    // 拖动，松手路径上跳页会把每次翻页都打回原页。
    if (_pageLock.value == z) return;
    _pageLock.value = z;
    if (zoomed != z) setState(() => zoomed = z);
    if (z) _snapPage();
  }

  void _hintNoMore() {
    final now = DateTime.now();
    if (_endHintAt != null &&
        now.difference(_endHintAt!) < const Duration(seconds: 2)) {
      return;
    }
    _endHintAt = now;
    toast(context, '没有更多啦');
  }

  /// 第一条上往下过滚才刷新，不劫持 PageView 物理滚动。
  bool _onFeedScroll(ScrollNotification n) {
    if (_pageLock.value || zoomed || clean) {
      _leadOverscroll = 0;
      _tailOverscroll = 0;
      return false;
    }
    if (page != 0) _leadOverscroll = 0;
    if (n is ScrollUpdateNotification && n.metrics.pixels > 0) {
      _leadOverscroll = 0;
    } else if (page == 0 &&
        n is OverscrollNotification &&
        n.dragDetails != null &&
        n.metrics.pixels <= n.metrics.minScrollExtent) {
      _leadOverscroll += n.overscroll.abs();
      if (_leadOverscroll > 96 && !loading) {
        _leadOverscroll = 0;
        load(reason: FeedLoadReason.userRefresh);
      }
    } else if (n is ScrollEndNotification) {
      _leadOverscroll = 0;
    }

    final last = items.isNotEmpty && page >= items.length - 1;
    if (end && last) {
      if (n is OverscrollNotification &&
          n.dragDetails != null &&
          n.metrics.pixels >= n.metrics.maxScrollExtent) {
        _tailOverscroll += n.overscroll.abs();
        if (_tailOverscroll > 56) {
          _tailOverscroll = 0;
          _hintNoMore();
        }
      } else if (n is ScrollEndNotification) {
        _tailOverscroll = 0;
      }
    } else {
      _tailOverscroll = 0;
    }
    return false;
  }

  _FeedItemStamp _stamp(CardItem item) => (
        id: item.id,
        thumb: item.thumb,
        kind: item.kind,
        ext: item.ext,
        origName: item.origName,
        uploader: item.uploader,
        uploaderId: item.uploaderId,
        avatar: item.avatar,
        hasThumb: item.hasThumb,
        mine: item.mine,
        hasLive: item.hasLive,
        liked: item.liked,
        likes: item.likes,
        comments: item.commentCount,
        width: item.width,
        height: item.height,
        duration: item.duration,
        takenAt: item.takenAt,
        createdAt: item.createdAt,
      );

  bool _samePage(List<_FeedItemStamp> before, List<CardItem> after) {
    if (before.length != after.length) return false;
    for (var i = 0; i < before.length; i++) {
      if (before[i] != _stamp(after[i])) return false;
    }
    return true;
  }

  bool _sameItemIds(List<_FeedItemStamp> before, List<CardItem> after) {
    if (before.length != after.length) return false;
    for (var i = 0; i < before.length; i++) {
      if (before[i].id != after[i].id) return false;
    }
    return true;
  }

  bool _containsNewUpload(
    List<CardItem> next, {
    required bool hasBaseline,
    required Set<int> knownIds,
    required double? previousCreatedAt,
    required int? previousId,
  }) {
    if (!hasBaseline || next.isEmpty) return false;
    if (previousId == null) return true;
    if (previousCreatedAt == null) return false;
    return next.any((item) {
      if (knownIds.contains(item.id)) return false;
      final createdAt = item.createdAt;
      if (createdAt == null) return false;
      return createdAt > previousCreatedAt ||
          (createdAt == previousCreatedAt && item.id > previousId);
    });
  }

  bool _canShowNotice({required int seq, required String requestView}) {
    if (!mounted || seq != _loadSeq || requestView != _viewKey) return false;
    if (!widget.active) return false;
    return ModalRoute.of(context)?.isCurrent ?? true;
  }

  Future<void> load({
    FeedLoadReason reason = FeedLoadReason.initial,
    bool resetPosition = false,
  }) async {
    final more = reason == FeedLoadReason.pagination;
    // 只挡「加载更多」的并发；切筛选/下拉刷新要能超越在途请求（旧响应按代际丢弃）
    if (more && (loading || end)) return;
    final seq = ++_loadSeq;
    final v = view == 'mine' && _mineUnseenOnly ? 'mine_unseen' : view;
    final recommended = v == 'recommended';
    final requestBase = Api.I.base;
    final requestToken = Api.I.token;
    final hasBaseline = _loadedView == v;
    final previousPage = items.take(20).map(_stamp).toList(growable: false);
    final previousCreatedAt = items.isEmpty ? null : items.first.createdAt;
    final previousId = items.isEmpty ? null : items.first.id;
    final oldIds = {for (final e in items) e.id};
    // 只有同一个普通列表内刷新才保留浏览位置；推荐每次刷新都换一批并回到首条。
    // 必须回到顶部，两边内容有重叠也不能停在同一条上。
    final keepPosition = !resetPosition && !recommended && _loadedView == v;
    final currentId = keepPosition && items.isNotEmpty && page < items.length
        ? items[page].id
        : null;
    final reqCursor = more ? cursor : null;
    final reqCursorId = more ? cursorId : null;
    final hotOffset = items.length;
    setState(() => loading = true);
    try {
      final d = await Api.I.gallery(
        v,
        cursor: v == 'hot' || recommended ? null : reqCursor,
        cursorId: v == 'hot' || recommended ? null : reqCursorId,
        offset: v == 'hot' && more ? hotOffset : 0,
        limit: 20,
        sort: v == 'hot' || recommended ? null : 'upload',
        seed: recommended
            ? (DateTime.now().microsecondsSinceEpoch ^ (seq * 2654435761)) &
                0x7fffffff
            : null,
        excludeIds: recommended ? _recommendedRecent : null,
      );
      // 过期响应：请求期间筛选、刷新或盒子会话已切换，这份作废。
      if (!mounted || seq != _loadSeq) return;
      if (v != _viewKey ||
          Api.I.base != requestBase ||
          Api.I.token != requestToken) {
        return;
      }
      var list = ((d['items'] as List?) ?? []).map((e) => CardItem(e)).toList();
      if (recommended && more) {
        list = list.where((e) => !oldIds.contains(e.id)).toList();
      }
      if (recommended) {
        for (final item in list) {
          _recommendedRecent.remove(item.id);
          _recommendedRecent.add(item.id);
        }
        if (_recommendedRecent.length > 60) {
          _recommendedRecent.removeRange(0, _recommendedRecent.length - 60);
        }
      }
      setState(() {
        if (more) {
          items.addAll(list);
        } else {
          items = list;
          page = 0;
          if (currentId != null) {
            final idx = list.indexWhere((e) => e.id == currentId);
            if (idx >= 0) page = idx;
          }
          _loadedView = v;
          zoomed = false;
          _pageLock.value = false;
          _tabCache.remove(v);
          if (_pc.hasClients) _pc.jumpToPage(page);
        }
        cursor = (d['cursor'] as num?)?.toDouble();
        cursorId = (d['cursor_id'] as num?)?.toInt();
        end = list.length < 20;
      });
      if (!more && items.isNotEmpty) {
        final i = page.clamp(0, items.length - 1);
        _markSeen(items[i]);
      }
      if (_canShowNotice(seq: seq, requestView: v)) {
        if (reason == FeedLoadReason.recommendationRefresh) {
          toast(
            context,
            _sameItemIds(previousPage, list) ? '内容不多，暂时还是这些' : '已换一批',
          );
        } else if (reason == FeedLoadReason.userRefresh) {
          final same = hasBaseline && _samePage(previousPage, list);
          final hasNewUpload = v == 'all' &&
              _containsNewUpload(
                list,
                hasBaseline: hasBaseline,
                knownIds: oldIds,
                previousCreatedAt: previousCreatedAt,
                previousId: previousId,
              );
          toast(context, hasNewUpload ? '发现新内容' : (same ? '暂无更新' : '刷新完成'));
        }
      }
    } catch (e) {
      final silent = reason == FeedLoadReason.passiveResume;
      if (!silent && _canShowNotice(seq: seq, requestView: v)) {
        toast(context, friendlyNet(e, '加载'));
      }
    } finally {
      if (mounted && seq == _loadSeq) setState(() => loading = false);
    }
  }

  Future<void> _like(CardItem c, {bool ensureLiked = false}) async {
    final t = LikeTarget(liked: c.liked, likes: c.likes);
    await _likes.apply(
      id: c.id,
      item: t,
      ensureLiked: ensureLiked,
      send: (id, {liked}) => Api.I.like(id, liked: liked),
      onChanged: () {
        c.liked = t.liked;
        c.likes = t.likes;
        if (mounted) setState(() {});
      },
      onError: (e) {
        if (mounted) toast(context, friendlyNet(e, '点赞'));
      },
    );
  }

  void _cycleTab(int dir) {
    const ids = ['all', 'recommended', 'mine', 'hot'];
    var i = ids.indexOf(view);
    if (i < 0) i = 0;
    final next = i + dir;
    if (next < 0 || next >= ids.length) return;
    _goView(ids[next]);
  }

  void _selectTab(String next) => _goView(next);

  Future<void> _showMineMenu(LongPressStartDetails details) async {
    HapticFeedback.mediumImpact();
    final size = MediaQuery.sizeOf(context);
    final maxLeft = size.width > 180 ? size.width - 172 : 8.0;
    final left =
        (details.globalPosition.dx - 82).clamp(8.0, maxLeft).toDouble();
    final choice = await showMenu<bool>(
      context: context,
      color: const Color(0xFF1A1F26),
      position: RelativeRect.fromLTRB(
        left,
        details.globalPosition.dy + 12,
        size.width - left - 164,
        0,
      ),
      items: [
        CheckedPopupMenuItem<bool>(
          value: false,
          checked: !_mineUnseenOnly,
          child: const Text('查看全部'),
        ),
        CheckedPopupMenuItem<bool>(
          value: true,
          checked: _mineUnseenOnly,
          child: const Text('只看未看过'),
        ),
      ],
    );
    if (choice == null || !mounted) return;
    if (view == 'mine' && _mineUnseenOnly == choice) return;
    _stashCurrent();
    _mineUnseenOnly = choice;
    view = 'mine';
    if (_restoreView(_viewKey)) return;
    load(reason: FeedLoadReason.scopeChange);
  }

  void _markSeen(CardItem c) {
    if (_seen.contains(c.id)) return;
    _seen.add(c.id);
    Api.I.markSeen(c.id);
  }

  bool consumeBack() {
    if (!clean) return false;
    setState(() => clean = false);
    widget.onCleanChanged?.call(false);
    return true;
  }

  void _toggleClean() {
    setState(() => clean = !clean);
    widget.onCleanChanged?.call(clean);
  }

  Future<void> _delete(CardItem c) async {
    try {
      await Api.I.deleteAsset(c.id);
      if (!mounted) return;
      setState(() {
        items.removeWhere((e) => e.id == c.id);
        if (page >= items.length) page = (items.length - 1).clamp(0, 1 << 30);
      });
      toast(context, '已删除');
    } catch (e) {
      if (mounted) toast(context, friendlyNet(e, '删除'));
    }
  }

  Future<void> _save(CardItem c) async {
    if (_saving.contains(c.id)) return;
    setState(() => _saving.add(c.id));
    HapticFeedback.mediumImpact();
    try {
      final msg = await queueDownload(context, c);
      if (mounted) toast(context, msg);
    } catch (e) {
      if (mounted) toast(context, friendlyNet(e, '保存'));
    }
    if (mounted) setState(() => _saving.remove(c.id));
  }

  void _comments(CardItem c) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1F26),
      builder: (_) => CommentSheet(
        item: c,
        onChanged: () {
          if (mounted) setState(() {});
        },
      ),
    );
  }

  Future<void> pickPerson() async {
    try {
      personsCache = await Api.I.persons();
    } catch (_) {
      personsCache = [];
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1F26),
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text(
                '按人物刷',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (final p in personsCache)
              ListTile(
                leading: p['cover'] != null
                    ? CircleAvatar(
                        backgroundImage: NetworkImage(
                          '${Api.I.base}${p['cover']}',
                        ),
                      )
                    : const CircleAvatar(child: Icon(Icons.face)),
                title: Text((p['name'] ?? '未命名') as String),
                subtitle: Text('${p['count']} 张'),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => view = 'person:${p['id']}');
                  load(reason: FeedLoadReason.scopeChange);
                },
              ),
            if (personsCache.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(
                  child: Text(
                    '还没识别出人物',
                    style: TextStyle(color: Colors.white38),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        children: [
          if (items.isEmpty)
            RefreshIndicator(
              color: const Color(0xFFFF5E7A),
              onRefresh: () => load(reason: FeedLoadReason.userRefresh),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (d) {
                      _hdx += d.delta.dx;
                      final w = MediaQuery.sizeOf(context).width;
                      if (w > 0) {
                        _tabDrag.value =
                            (-_hdx / w).clamp(-1.0, 1.0).toDouble();
                      }
                    },
                    onHorizontalDragCancel: () {
                      _hdx = 0;
                      _tabDrag.value = 0;
                    },
                    onHorizontalDragEnd: (_) {
                      final dx = _hdx;
                      _hdx = 0;
                      _tabDrag.value = 0;
                      if (dx < -feedTabSwitchPx) _cycleTab(1);
                      if (dx > feedTabSwitchPx) _cycleTab(-1);
                    },
                    child: SizedBox(
                      height: MediaQuery.sizeOf(context).height - 160,
                      child: const Center(
                        child: Text(
                          '还没有照片',
                          style: TextStyle(color: Colors.white38),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            // 不要用 RefreshIndicator 包垂直 PageView：下拉刷新会把下滑翻页
            // 卡在过滚位置，表现为「下滑失灵，上划一下又好了」。
            NotificationListener<ScrollNotification>(
              onNotification: _onFeedScroll,
              child: FeedPointerLayer(
                session: _session,
                onTabSwitch: clean ? null : _cycleTab,
                onTabProgress:
                    clean ? null : (value) => _tabDrag.value = value,
                child: PageView.builder(
                key: ValueKey('feed-pager-$_loadedView-$_pagerGen'),
                controller: _pc,
                scrollDirection: Axis.vertical,
                // pageSnapping:false 让 PagingLockPhysics 真正接管松手吸附；
                // 否则框架 PageScrollPhysics 包在外层，拖不到半屏就弹回本页。
                pageSnapping: false,
                physics: PagingLockPhysics(lock: _pageLock, memory: _pageDrag),
                itemCount: items.length,
                onPageChanged: (i) {
                  _session.cancelRound?.call();
                  _leadOverscroll = 0;
                  setState(() {
                    page = i;
                    zoomed = false;
                    _pageLock.value = false;
                  });
                  if (i < items.length) _markSeen(items[i]);
                  if (!end && i >= items.length - 3) {
                    load(reason: FeedLoadReason.pagination);
                  }
                },
                itemBuilder: (_, i) {
                  final c = items[i];
                  return FeedItem(
                    key: ValueKey('feed-${c.id}'),
                    item: c,
                    active: widget.active && i == page,
                    preload: widget.active && (i == page + 1),
                    saving: _saving.contains(c.id),
                    onZoomed: _onZoomed,
                    onLike: () => _like(c),
                    onEnsureLike: () => _like(c, ensureLiked: true),
                    onComment: () => _comments(c),
                    onDownload: () => _save(c),
                    onProfile: () => MePage.open(
                      context,
                      userId: c.uploaderId,
                      userName: c.uploader,
                    ),
                    session: _session,
                    chrome: !clean,
                    speed: speed,
                    onEnterClean: _toggleClean,
                    onSpeed: (s) => setState(() => speed = s),
                    onDelete: c.mine ? () => _delete(c) : null,
                  );
                },
              ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: clean ? const SizedBox.shrink() : _topBar(),
          ),
        ],
      ),
    );
  }

  Widget _topBar() {
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: 50,
        child: ValueListenableBuilder<double>(
          valueListenable: _tabDrag,
          builder: (context, drag, _) => LayoutBuilder(
            builder: (context, box) {
              final selected = feedTabs.indexWhere((t) => t.$2 == view);
              final index = selected < 0 ? 0 : selected;
              final position =
                  (index + drag).clamp(0.0, feedTabs.length - 1.0).toDouble();
              final tabWidth = box.maxWidth / feedTabs.length;
              const lineWidth = 26.0;
              return Stack(
                children: [
                  Row(
                    children: [
                      for (var i = 0; i < feedTabs.length; i++)
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _selectTab(feedTabs[i].$2),
                            onLongPressStart:
                                feedTabs[i].$2 == 'mine' ? _showMineMenu : null,
                            child: Center(
                              child: Text(
                                feedTabs[i].$1,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: Color.lerp(
                                    Colors.white54,
                                    Colors.white,
                                    (1 - (position - i).abs())
                                        .clamp(0.0, 1.0)
                                        .toDouble(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  AnimatedPositioned(
                    key: const ValueKey('feed-tab-indicator'),
                    duration: drag.abs() > 0.001
                        ? Duration.zero
                        : const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    left: tabWidth * position + (tabWidth - lineWidth) / 2,
                    bottom: 3,
                    width: lineWidth,
                    height: 3,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF5E7A),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
