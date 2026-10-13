/// 全屏图片/视频流查看器（相册、个人主页点进去）。
/// 上下滑切换当前集合里的作品，双指放大，缩回后才能翻页。
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

/// 返回来源网格时：同一张且还在列表里就不要滚动，避免无故跳动。
bool shouldRevealSource({
  required int openedId,
  required int? viewedId,
  required bool openedStillExists,
}) {
  final id = viewedId ?? openedId;
  if (id == openedId && openedStillExists) return false;
  return true;
}

class FeedViewerPage extends StatefulWidget {
  const FeedViewerPage({
    super.key,
    required this.items,
    this.initialIndex = 0,
    this.onLoadMore,
    this.onProfile,
    this.onViewedId,
  });

  final List<CardItem> items;
  final int initialIndex;
  final Future<void> Function()? onLoadMore;
  final ValueChanged<CardItem>? onProfile;
  final ValueChanged<int>? onViewedId;

  /// 打开全屏查看器。关闭后返回最后浏览的那张媒体 id，方便列表定位。
  static Future<int?> open(
    BuildContext context, {
    required List<CardItem> items,
    required int initialIndex,
    Future<void> Function()? onLoadMore,
    ValueChanged<CardItem>? onProfile,
  }) async {
    if (items.isEmpty) return null;
    final i = initialIndex.clamp(0, items.length - 1);
    var viewedId = items[i].id;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FeedViewerPage(
        items: items,
        initialIndex: i,
        onLoadMore: onLoadMore,
        onProfile: onProfile,
        onViewedId: (id) => viewedId = id,
      ),
    ));
    return viewedId;
  }

  @override
  State<FeedViewerPage> createState() => _FeedViewerPageState();
}

class _FeedViewerPageState extends State<FeedViewerPage> {
  late int page = widget.initialIndex;
  late int _viewedId = widget.items.isEmpty
      ? 0
      : widget.items[widget.initialIndex.clamp(0, widget.items.length - 1)].id;
  bool zoomed = false;
  bool clean = false;
  double speed = 1.0;
  bool loadingMore = false;
  final Set<int> _saving = {};
  late final PageController _pc;
  final _pageLock = ValueNotifier(false);
  final _pageDrag = PagingDragMemory();
  final _session = FeedGestureSession();
  double _tailOverscroll = 0;
  DateTime? _endHintAt;
  final _likes = LikeCoordinator();

  /// 锁翻页时立刻吸回整页，避免半页偏移导致单向滑不动。
  void _snapPage() {
    if (!_pc.hasClients || widget.items.isEmpty) return;
    final p = _pc.page;
    if (p == null) return;
    final t = p.round().clamp(0, widget.items.length - 1);
    if ((p - t).abs() > 0.001) _pc.jumpToPage(t);
  }

  void _onZoomed(bool z) {
    // 状态没变化（尤其普通单指松手的 false→false）完全不动滚动；
    // 只在真正进入锁定时对齐整页，解锁只放锁。jumpToPage 会终止当前
    // 拖动，松手路径上跳页会把每次翻页都打回原页。
    if (_pageLock.value == z) return;
    _pageLock.value = z;
    if (zoomed != z) setState(() => zoomed = z);
    if (z) _snapPage();
  }

  int? _idAt(int i) {
    if (widget.items.isEmpty) return null;
    return widget.items[i.clamp(0, widget.items.length - 1)].id;
  }

  void _emitViewed() {
    final id = _idAt(page);
    if (id == null) return;
    _viewedId = id;
    widget.onViewedId?.call(id);
  }

  /// 列表被追加/删除后按作品 ID 回位，不跟被替换的 index。
  void _syncPageToId({bool jump = true}) {
    if (widget.items.isEmpty) {
      page = 0;
      return;
    }
    var i = widget.items.indexWhere((e) => e.id == _viewedId);
    if (i < 0) {
      i = page.clamp(0, widget.items.length - 1);
    }
    page = i;
    _viewedId = widget.items[i].id;
    if (jump && _pc.hasClients) {
      final cur = _pc.page?.round();
      if (cur != i) _pc.jumpToPage(i);
    }
  }

  @override
  void initState() {
    super.initState();
    _pc = PageController(initialPage: widget.initialIndex);
    _session.stopPageDrag = _stopPageDrag;
    _emitViewed();
  }

  void _stopPageDrag() {
    if (!_pc.hasClients) return;
    try {
      _pc.position.hold(() {});
    } catch (_) {}
  }

  @override
  void dispose() {
    if (_session.stopPageDrag == _stopPageDrag) {
      _session.stopPageDrag = null;
    }
    _session.cancelRound?.call();
    _pc.dispose();
    _pageLock.dispose();
    super.dispose();
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

  void _toggleClean() => setState(() => clean = !clean);

  Future<void> _delete(CardItem c) async {
    try {
      await Api.I.deleteAsset(c.id);
      if (!mounted) return;
      setState(() {
        widget.items.removeWhere((e) => e.id == c.id);
        _syncPageToId(jump: false);
      });
      if (_pc.hasClients && widget.items.isNotEmpty) {
        _pc.jumpToPage(page);
      }
      _emitViewed();
      toast(context, '已删除');
      if (widget.items.isEmpty && mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) toast(context, friendlyNet(e, '删除'));
    }
  }

  Future<void> _maybeMore(int i) async {
    if (loadingMore || widget.onLoadMore == null) return;
    if (i < widget.items.length - 3) return;
    loadingMore = true;
    try {
      await widget.onLoadMore!();
    } finally {
      loadingMore = false;
      if (mounted) {
        setState(() => _syncPageToId());
      }
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (_pageLock.value) {
      _tailOverscroll = 0;
      return false;
    }
    final last = widget.items.isNotEmpty && page >= widget.items.length - 1;
    final noMore = widget.onLoadMore == null;
    if (last && noMore) {
      if (n is OverscrollNotification &&
          n.dragDetails != null &&
          n.metrics.pixels >= n.metrics.maxScrollExtent) {
        _tailOverscroll += n.overscroll.abs();
        if (_tailOverscroll > 56) {
          _tailOverscroll = 0;
          final now = DateTime.now();
          if (_endHintAt == null ||
              now.difference(_endHintAt!) > const Duration(seconds: 2)) {
            _endHintAt = now;
            toast(context, '没有更多啦');
          }
        }
      } else if (n is ScrollEndNotification) {
        _tailOverscroll = 0;
      }
    } else {
      _tailOverscroll = 0;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    return PopScope(
      canPop: !clean,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (clean) setState(() => clean = false);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: items.isEmpty
            ? const Center(
                child: Text('还没有照片', style: TextStyle(color: Colors.white38)))
            : Stack(
                children: [
                  NotificationListener<ScrollNotification>(
                    onNotification: _onScroll,
                    child: FeedPointerLayer(
                      session: _session,
                      child: PageView.builder(
                      key: const ValueKey('feed-viewer-pager'),
                      controller: _pc,
                      scrollDirection: Axis.vertical,
                      // pageSnapping:false 让 PagingLockPhysics 真正接管松手
                      // 吸附；否则框架 PageScrollPhysics 包在外层，拖不到
                      // 半屏就弹回本页。
                      pageSnapping: false,
                      physics: PagingLockPhysics(lock: _pageLock, memory: _pageDrag),
                      itemCount: items.length,
                      onPageChanged: (i) {
                        _session.cancelRound?.call();
                        setState(() {
                          page = i;
                          zoomed = false;
                          _pageLock.value = false;
                        });
                        _emitViewed();
                        _maybeMore(i);
                      },
                      itemBuilder: (_, i) {
                        final c = items[i];
                        return FeedItem(
                          key: ValueKey('viewer-${c.id}'),
                          item: c,
                          active: i == page,
                          saving: _saving.contains(c.id),
                          onZoomed: _onZoomed,
                          onLike: () => _like(c),
                          onEnsureLike: () => _like(c, ensureLiked: true),
                          onComment: () => _comments(c),
                          onDownload: () => _save(c),
                          onProfile: widget.onProfile == null
                              ? null
                              : () => widget.onProfile!(c),
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
                  if (!clean)
                    Positioned(
                      top: 0,
                      left: 0,
                      child: SafeArea(
                        child: IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
