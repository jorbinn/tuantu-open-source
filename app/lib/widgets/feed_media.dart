/// 抖音式单条信息流：照片/视频 + 右栏操作。首页左右滑切顶部 tab。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../api.dart';
import '../feed_player_load.dart';
import '../like_sync.dart';
import '../main.dart';
import '../media_proxy.dart';
import '../widgets/box_image.dart';
import '../widgets/feed_action_rail.dart';
import '../widgets/feed_gestures.dart';
import '../widgets/zoomable.dart';

const _scrubBottomPad = 10.0;
const _scrubHitHeight = 56.0;
const _scrubBarHeight = 2.0;
const _metaGap = 10.0;

double _scrubBarTop(BuildContext context) {
  final vp = MediaQuery.viewPaddingOf(context).bottom;
  return vp +
      _scrubBottomPad +
      (_scrubHitHeight - _scrubBarHeight) / 2 +
      _scrubBarHeight;
}

class FeedItem extends StatefulWidget {
  const FeedItem({
    super.key,
    required this.item,
    required this.active,
    required this.saving,
    required this.onZoomed,
    required this.onLike,
    this.onEnsureLike,
    required this.onComment,
    required this.onDownload,
    this.onProfile,
    this.onHorizontal,
    this.onHorizontalProgress,
    this.chrome = true,
    this.speed = 1.0,
    this.preload = false,
    this.onEnterClean,
    this.onSpeed,
    this.onDelete,
    this.session,
  });

  final CardItem item;
  final bool active;
  final bool preload;
  final bool saving;
  final ValueChanged<bool> onZoomed;
  final VoidCallback onLike;

  /// 双击只要赞，不走按钮的切换。
  final VoidCallback? onEnsureLike;
  final VoidCallback onComment;
  final VoidCallback onDownload;
  final VoidCallback? onProfile;

  /// 左滑 +1，右滑 -1。首页用来切顶部 tab。
  final ValueChanged<int>? onHorizontal;

  /// 首页横向拖动切 Tab 时，传出 -1...1 的实时页偏移供顶部指示线跟手。
  final ValueChanged<double>? onHorizontalProgress;
  final bool chrome;
  final double speed;
  final VoidCallback? onEnterClean;
  final ValueChanged<double>? onSpeed;
  final Future<void> Function()? onDelete;

  /// 首页/相册把触点采集放在 PageView 外层时传入；单测未传则自己包一层。
  final FeedGestureSession? session;

  @override
  State<FeedItem> createState() => _FeedItemState();
}

class _FeedItemState extends State<FeedItem>
    with RouteAware, WidgetsBindingObserver
    implements FeedGestureTarget {
  @override
  bool zoomed = false;
  bool _scrubLock = false;
  bool _tabDragLock = false;
  // 最近一次发给父页面的锁状态。普通单指松手（false→false）不得当成
  // 一次“解锁”通知出去：父页面会据此对齐整页，打断正常翻页。
  bool _emittedLock = false;
  final _zoomKey = GlobalKey<ZoomableState>();
  final _railKey = GlobalKey();
  final _scrubKey = GlobalKey();
  bool _holdBoost = false;
  bool _lockReady = false;
  double _holdTarget = 2.0;
  Size _area = Size.zero;
  int _burstUntil = 0;
  int _heartSeq = 0;
  final _hearts = <_HeartBurst>[];
  final _playNudge = ValueNotifier(0);
  final _scrubInterrupt = ValueNotifier(0);
  bool _routeCurrent = true;
  bool _foreground = true;
  bool _ending = false;
  FeedGestureSession? _ownedSession;

  bool get _playable => feedPlayable(
        active: widget.active,
        routeCurrent: _routeCurrent,
        foreground: _foreground,
      );

  bool get _canPreload => widget.preload && _routeCurrent && _foreground;

  FeedGestureSession get _session => widget.session ?? _ownedSession!;

  double? get _mediaAspect {
    if (widget.item.width > 0 && widget.item.height > 0) {
      return widget.item.width / widget.item.height;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Api.endpointChanges.addListener(_endpointChanged);
    if (widget.session == null) {
      _ownedSession = FeedGestureSession();
    }
    if (widget.active) _registerSession();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      TuantuApp.routeObserver.subscribe(this, route);
    }
  }

  void _registerSession() {
    _session.activeItem = this;
  }

  void _unregisterSession() {
    if (_session.activeItem == this) _session.activeItem = null;
  }

  @override
  void didPushNext() {
    if (_routeCurrent) setState(() => _routeCurrent = false);
    _endRound();
  }

  @override
  void didPopNext() {
    if (!_routeCurrent) setState(() => _routeCurrent = true);
  }

  @override
  void didUpdateWidget(covariant FeedItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _unregisterSession();
      if (widget.session == null && _ownedSession == null) {
        _ownedSession = FeedGestureSession();
      }
      if (widget.active) _registerSession();
    }
    if (oldWidget.item.id != widget.item.id ||
        (oldWidget.active && !widget.active)) {
      _endRound();
      _zoomKey.currentState?.reset();
      zoomed = false;
      _scrubLock = false;
      _tabDragLock = false;
      _emitPagingLock();
      if (!widget.active) _unregisterSession();
    }
    if (widget.active && !oldWidget.active) _registerSession();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final fg = state == AppLifecycleState.resumed;
    if (fg != _foreground && mounted) setState(() => _foreground = fg);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _endRound();
    }
  }

  @override
  void dispose() {
    Api.endpointChanges.removeListener(_endpointChanged);
    _unregisterSession();
    _playNudge.dispose();
    _scrubInterrupt.dispose();
    TuantuApp.routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _endpointChanged() {
    if (mounted) setState(() {});
  }

  void _endRound() {
    if (_ending) return;
    _ending = true;
    _session.cancelRound?.call();
    _clearLocalGesture();
    _ending = false;
  }

  void _clearLocalGesture() {
    if (_holdBoost && mounted) {
      setState(() {
        _holdBoost = false;
        _lockReady = false;
      });
    } else {
      _holdBoost = false;
      _lockReady = false;
    }
    _scrubLock = false;
    _tabDragLock = false;
    _emitPagingLock();
  }

  void _emitPagingLock() {
    final z = zoomed || _scrubLock || _tabDragLock || _holdBoost;
    if (z == _emittedLock) return;
    _emittedLock = z;
    widget.onZoomed(z);
  }

  void _onZoomed(bool z) {
    zoomed = z;
    if (z) widget.onHorizontalProgress?.call(0);
    _emitPagingLock();
  }

  Offset _toLocal(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return global;
    return box.globalToLocal(global);
  }

  // ---- FeedGestureTarget ----

  @override
  bool get gestureReady => widget.active && _routeCurrent;

  @override
  int get mediaId => widget.item.id;

  @override
  Size get mediaSize => _area;

  @override
  bool isOverRail(Offset global) =>
      widget.chrome && hitTestGlobal(_railKey, global);

  @override
  bool isOverScrub(Offset global) => hitTestGlobal(_scrubKey, global);

  @override
  bool isBoostSpot(Offset global) {
    if (zoomed || widget.item.kind != 'video') return false;
    if (isOverScrub(global)) return false;
    return _isBoostZone(_toLocal(global), _area);
  }

  @override
  bool get inBurstWindow => DateTime.now().millisecondsSinceEpoch < _burstUntil;

  @override
  void tapMedia(Offset global) {
    if (!mounted || zoomed || _holdBoost) return;
    _playNudge.value++;
  }

  @override
  void doubleTapMedia(Offset global) {
    if (!mounted || zoomed || _holdBoost) return;
    _burstUntil = DateTime.now().millisecondsSinceEpoch + 420;
    _spawnHeart(_toLocal(global));
    _ensureLike();
  }

  @override
  void openMenu() {
    if (zoomed) return;
    _menu();
  }

  @override
  void boostStart() {
    HapticFeedback.mediumImpact();
    setState(() {
      _holdTarget = widget.speed >= 1.99 ? 1.0 : 2.0;
      _holdBoost = true;
      _lockReady = false;
    });
    _emitPagingLock();
  }

  @override
  void boostMove(Offset global) {
    if (!_holdBoost) return;
    final local = _toLocal(global);
    final over = local.dy > _area.height - 100;
    if (over == _lockReady) return;
    if (over) HapticFeedback.selectionClick();
    setState(() => _lockReady = over);
  }

  @override
  void boostEnd(bool confirm) {
    if (!_holdBoost) return;
    final lock = confirm && _lockReady;
    setState(() {
      _holdBoost = false;
      _lockReady = false;
    });
    _emitPagingLock();
    if (lock) widget.onSpeed?.call(_holdTarget);
  }

  @override
  void setTabDrag(bool active) {
    if (_tabDragLock == active) return;
    _tabDragLock = active;
    _emitPagingLock();
  }

  @override
  ZoomableState? mediaZoom() => _zoomKey.currentState;

  @override
  void cancelGestures() {
    interruptScrub();
    if (_ending) {
      _clearLocalGesture();
      return;
    }
    _clearLocalGesture();
  }

  @override
  void interruptScrub() {
    _scrubInterrupt.value++;
    if (_scrubLock) {
      _scrubLock = false;
      _emitPagingLock();
    }
  }

  void _ensureLike() {
    if (widget.onEnsureLike != null) {
      widget.onEnsureLike!();
      return;
    }
    if (!widget.item.liked) widget.onLike();
  }

  void _spawnHeart(Offset pos) {
    HapticFeedback.lightImpact();
    final id = ++_heartSeq;
    setState(() {
      _hearts.add(_HeartBurst(
        id: id,
        pos: pos,
        drift: ((id % 5) - 2) * 18.0,
        tilt: ((id % 7) - 3) * 0.14,
      ));
    });
    Future<void>.delayed(const Duration(milliseconds: 780), () {
      if (!mounted) return;
      setState(() => _hearts.removeWhere((e) => e.id == id));
    });
  }

  void _menu() {
    HapticFeedback.mediumImpact();
    final c = widget.item;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1F26),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.crop_free),
              title: Text(widget.chrome ? '清屏播放' : '退出清屏'),
              onTap: () {
                Navigator.pop(ctx);
                widget.onEnterClean?.call();
              },
            ),
            if (c.kind == 'video')
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    for (final s in const [1.0, 1.5, 2.0]) ...[
                      if (s != 1.0) const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            backgroundColor: widget.speed == s
                                ? const Color(0xFFFF5E7A)
                                : const Color(0xFF222933),
                            foregroundColor: Colors.white,
                            side: BorderSide.none,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: () {
                            Navigator.pop(ctx);
                            widget.onSpeed?.call(s);
                          },
                          child: Text('${s == 1 ? '1' : s}x',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            if (widget.onDelete != null)
              ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: Color(0xFFFF6B6B)),
                title: const Text('删除',
                    style: TextStyle(color: Color(0xFFFF6B6B))),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDelete();
                },
              ),
            ListTile(
              title: const Text('取消', textAlign: TextAlign.center),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }

  bool _isBoostZone(Offset p, Size size) {
    if (size.width <= 0 || size.height <= 0) return false;
    final edge = size.width * 0.22;
    final bottom = size.height * 0.28;
    return p.dx < edge ||
        p.dx > size.width - edge ||
        p.dy > size.height - bottom;
  }

  Future<void> _confirmDelete() async {
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这张？'),
        content: const Text('删除后所有人都看不见，无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFFF6B6B))),
          ),
        ],
      ),
    );
    if (ok == true) await widget.onDelete?.call();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.item;
    Widget body = Stack(
      fit: StackFit.expand,
      children: [
        LayoutBuilder(builder: (context, box) {
          _area = Size(box.maxWidth, box.maxHeight);
          return _media(c);
        }),
        if (_holdBoost)
          Positioned(
            left: 28,
            right: 28,
            bottom: widget.chrome ? 96 : 36,
            child: IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: _lockReady
                      ? const Color(0xFFFF5E7A)
                      : const Color(0xCC1A1F26),
                  borderRadius: BorderRadius.circular(22),
                ),
                alignment: Alignment.center,
                child: Text(
                  _lockReady
                      ? '松手锁定 ${_holdTarget == 1 ? '1' : '2'}x'
                      : '下滑松手锁定${_holdTarget == 1 ? '1' : '2'}倍速',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        if (widget.chrome)
          Positioned(
            right: 10,
            top: MediaQuery.sizeOf(context).height * 0.5,
            child: FeedActionRail(
              key: _railKey,
              item: c,
              onLike: widget.onLike,
              onComment: widget.onComment,
              onDownload: widget.onDownload,
              onProfile: widget.onProfile,
            ),
          ),
        if (widget.chrome)
          Positioned(
            left: 16,
            right: 88,
            bottom: c.kind == 'video' ? _scrubBarTop(context) + _metaGap : 28,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: widget.onProfile,
                  child: Text('@${c.uploader}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 16)),
                ),
                SizedBox(height: c.kind == 'video' ? _metaGap : 4),
                Text(
                  [
                    if (fmtTime(c.takenAt).isNotEmpty) fmtTime(c.takenAt),
                    if (c.kind == 'video') '视频',
                    if (c.isRaw) 'RAW',
                  ].join(' · '),
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
        for (final h in _hearts)
          _FlyingHeart(
            key: ValueKey(h.id),
            origin: h.pos,
            drift: h.drift,
            tilt: h.tilt,
          ),
      ],
    );
    if (_ownedSession == null) return body;
    return FeedPointerLayer(
      session: _ownedSession!,
      onTabSwitch: widget.onHorizontal,
      onTabProgress: widget.onHorizontalProgress,
      child: body,
    );
  }

  Widget _media(CardItem c) {
    if (c.kind == 'video') {
      return _FeedVideo(
        key: ValueKey('${c.id}-${Api.I.base}-${Api.endpointChanges.value}'),
        item: c,
        active: _playable,
        preload: _canPreload,
        speed: _holdBoost ? _holdTarget : widget.speed,
        playNudge: _playNudge,
        zoomKey: _zoomKey,
        onZoomed: _onZoomed,
        aspectRatio: _mediaAspect,
        scrubKey: _scrubKey,
        scrubInterrupt: _scrubInterrupt,
        onScrubActive: (v) {
          _scrubLock = v;
          _emitPagingLock();
        },
      );
    }
    final child = c.hasLive
        ? _LiveStill(
            key: ValueKey('${c.id}-${Api.I.base}-${Api.endpointChanges.value}'),
            item: c,
            active: _playable,
            playNudge: _playNudge,
          )
        : _photo(c);
    return Zoomable(
      key: _zoomKey,
      listenPointers: false,
      onZoomed: _onZoomed,
      contentAspectRatio: _mediaAspect,
      child: child,
    );
  }

  Widget _photo(CardItem c) {
    return _ProgressivePhoto(
        key: ValueKey('${c.id}-${Api.I.base}-${Api.endpointChanges.value}'),
        item: c,
        active: _playable);
  }
}

/// 信息流先显示小图保证滑动流畅；当前照片稳定停留半秒后，用原文件替换。
/// 解码尺寸覆盖最多 4 倍放大，避免超高像素照片整张解码造成内存峰值。
/// 网络请求仍然读取盒子的 /raw 原文件。
class _ProgressivePhoto extends StatefulWidget {
  const _ProgressivePhoto(
      {super.key, required this.item, required this.active});

  final CardItem item;
  final bool active;

  @override
  State<_ProgressivePhoto> createState() => _ProgressivePhotoState();
}

class _ProgressivePhotoState extends State<_ProgressivePhoto> {
  static const originalDelay = Duration(milliseconds: 500);
  static const _rawPreviewExts = {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
    'avif',
    'heic',
    'heif',
  };

  Timer? _timer;
  bool _showOriginal = false;

  bool get _canShowOriginal =>
      widget.item.kind == 'image' &&
      _rawPreviewExts.contains(widget.item.ext.toLowerCase());

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _ProgressivePhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.active != widget.active) {
      _sync(fromUpdate: true);
    }
  }

  void _sync({bool fromUpdate = false}) {
    _timer?.cancel();
    // 没封面、预加载页、快速滑走：一律不拉 /raw。只有当前静止页且已有缩略图才等半秒换原片。
    final allow = widget.active && _canShowOriginal && widget.item.wantThumb;
    if (!allow) {
      if (_showOriginal) {
        if (fromUpdate && mounted) {
          setState(() => _showOriginal = false);
        } else {
          _showOriginal = false;
        }
      }
      return;
    }
    if (_showOriginal) {
      if (fromUpdate && mounted) {
        setState(() => _showOriginal = false);
      } else {
        _showOriginal = false;
      }
    }
    _timer = Timer(originalDelay, () {
      if (mounted && widget.active) setState(() => _showOriginal = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final thumbUrl = item.wantThumb ? '${Api.I.base}${item.thumb}' : null;
    final rawUrl = '${Api.I.base}/api/asset/${item.id}/raw';
    if (thumbUrl == null) {
      return const ColoredBox(color: Color(0xFF111111));
    }
    final thumb = BoxImage(thumbUrl, fit: BoxFit.contain, cacheWidth: 1080);
    if (!_showOriginal || !_canShowOriginal) return thumb;
    final screen = MediaQuery.sizeOf(context).width;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final decodeWidth = (screen * ratio * 4).ceil().clamp(1080, 4096);
    return RawBoxImage(
      rawUrl,
      fit: BoxFit.contain,
      cacheWidth: decodeWidth,
      placeholder: thumb,
    );
  }
}

class _HeartBurst {
  _HeartBurst({
    required this.id,
    required this.pos,
    required this.drift,
    required this.tilt,
  });
  final int id;
  final Offset pos;
  final double drift;
  final double tilt;
}

class _FlyingHeart extends StatefulWidget {
  const _FlyingHeart({
    super.key,
    required this.origin,
    required this.drift,
    required this.tilt,
  });
  final Offset origin;
  final double drift;
  final double tilt;

  @override
  State<_FlyingHeart> createState() => _FlyingHeartState();
}

class _FlyingHeartState extends State<_FlyingHeart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 760),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value;
        final up = Curves.easeOut.transform(t);
        final fade = t < 0.18 ? t / 0.18 : (1 - (t - 0.18) / 0.82);
        final scale = t < 0.22 ? 0.45 + t * 2.6 : 1.02 - (t - 0.22) * 0.2;
        return Positioned(
          left: widget.origin.dx - 40 + widget.drift * up,
          top: widget.origin.dy - 48 - 150 * up,
          child: IgnorePointer(
            child: Opacity(
              opacity: fade.clamp(0.0, 1.0),
              child: Transform.rotate(
                angle: widget.tilt,
                child: Transform.scale(
                  scale: scale.clamp(0.4, 1.2),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
      child: const Icon(
        Icons.favorite,
        color: Color(0xFFFE2C55),
        size: 80,
        shadows: [Shadow(blurRadius: 12, color: Color(0x66FE2C55))],
      ),
    );
  }
}

class _LiveStill extends StatefulWidget {
  const _LiveStill({
    super.key,
    required this.item,
    required this.active,
    this.playNudge,
  });
  final CardItem item;
  final bool active;
  final ValueNotifier<int>? playNudge;

  @override
  State<_LiveStill> createState() => _LiveStillState();
}

class _LiveStillState extends State<_LiveStill> {
  VideoPlayerController? _c;
  bool _playing = false;
  bool _ready = false;
  bool _failed = false;
  final _loadLock = FeedPlayerLoadLock();
  bool _userPaused = false;

  @override
  void initState() {
    super.initState();
    widget.playNudge?.addListener(_nudge);
    if (widget.active) _prepare();
  }

  @override
  void didUpdateWidget(covariant _LiveStill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playNudge != widget.playNudge) {
      oldWidget.playNudge?.removeListener(_nudge);
      widget.playNudge?.addListener(_nudge);
    }
    if (widget.item.id != oldWidget.item.id) {
      _userPaused = false;
      _loadLock.invalidate();
      final stale = _c;
      _c = null;
      _ready = false;
      _playing = false;
      stale?.removeListener(_onLiveTick);
      unawaited(_disposeLive(stale));
      _prepare(force: true);
      return;
    }
    if (widget.active && !oldWidget.active && !_userPaused) {
      if (_c == null) {
        _prepare();
      } else {
        _playOnce();
      }
    }
    if (!widget.active && oldWidget.active) _stop();
  }

  void _nudge() {
    if (!widget.active) return;
    if (_playing) {
      _userPaused = true;
      _stop();
      return;
    }
    _userPaused = false;
    if (_c == null) {
      _prepare(force: true);
    } else {
      _playOnce();
    }
  }

  Future<void> _prepare({bool force = false}) async {
    final ticket = _loadLock.begin(force: force);
    if (ticket == null) return;
    if (mounted) setState(() => _failed = false);
    VideoPlayerController? ctrl;
    try {
      ctrl = VideoPlayerController.networkUrl(
        Uri.parse(MediaProxy.livePlayUrl(widget.item.id)),
        httpHeaders: MediaProxy.playHeaders(),
      );
      await ctrl.initialize().timeout(const Duration(seconds: 12));
      await ctrl.setLooping(false);
      final kept = await adoptLoaded(
        ctrl,
        ticket: ticket,
        currentGen: () => _loadLock.gen,
        dispose: (c) => c.dispose(),
      );
      if (kept == null) return;
      ctrl = null;
      _c = kept;
      kept.addListener(_onLiveTick);
      if (mounted && _loadLock.belongs(ticket)) setState(() => _ready = true);
      if (widget.active && !_userPaused) _playOnce();
    } catch (_) {
      if (mounted && _loadLock.belongs(ticket)) setState(() => _failed = true);
      unawaited(Api.I.recoverConnection().catchError((_) => false));
      try {
        await ctrl?.dispose();
      } catch (_) {}
    } finally {
      _loadLock.finish(ticket);
    }
  }

  Future<void> _playOnce() async {
    final v = _c;
    if (v == null || !v.value.isInitialized) return;
    try {
      await v.seekTo(Duration.zero);
      if (!mounted || !identical(_c, v) || !widget.active || _userPaused) {
        return;
      }
      setState(() => _playing = true);
      await v.play();
    } catch (_) {
      _failLive(v);
    }
  }

  void _onLiveTick() {
    final v = _c;
    if (v == null) return;
    if (v.value.hasError) {
      _failLive(v);
      return;
    }
    if (_playing &&
        v.value.duration > Duration.zero &&
        v.value.position >=
            v.value.duration - const Duration(milliseconds: 80)) {
      _stop();
    }
  }

  void _failLive(VideoPlayerController failed) {
    if (!mounted || !identical(_c, failed)) return;
    _loadLock.invalidate();
    failed.removeListener(_onLiveTick);
    setState(() {
      _c = null;
      _ready = false;
      _playing = false;
      _failed = true;
    });
    unawaited(_disposeLive(failed));
    unawaited(Api.I.recoverConnection().catchError((_) => false));
  }

  Future<void> _disposeLive(VideoPlayerController? controller) async {
    try {
      await controller?.dispose();
    } catch (_) {}
  }

  Future<void> _pauseLive(VideoPlayerController controller) async {
    try {
      await controller.pause();
    } catch (_) {
      _failLive(controller);
    }
  }

  void _stop() {
    final v = _c;
    if (v != null) unawaited(_pauseLive(v));
    if (mounted && _playing) setState(() => _playing = false);
  }

  @override
  void dispose() {
    _loadLock.invalidate();
    widget.playNudge?.removeListener(_nudge);
    _c?.removeListener(_onLiveTick);
    unawaited(_disposeLive(_c));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = _ProgressivePhoto(
      key: ValueKey(Api.I.base),
      item: widget.item,
      active: widget.active && !_playing,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        still,
        if (_failed && widget.active)
          Positioned(
            left: 24,
            right: 24,
            bottom: 110,
            child: Center(
                child: FilledButton.tonal(
              onPressed: () => _prepare(force: true),
              child: const Text('实况暂时无法播放，点击重试'),
            )),
          ),
        if (_playing && _ready && _c != null)
          FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: _c!.value.size.width,
              height: _c!.value.size.height,
              child: VideoPlayer(_c!),
            ),
          ),
      ],
    );
  }
}

class _FeedVideo extends StatefulWidget {
  const _FeedVideo({
    super.key,
    required this.item,
    required this.active,
    this.preload = false,
    this.speed = 1.0,
    this.playNudge,
    required this.zoomKey,
    required this.onZoomed,
    this.aspectRatio,
    required this.scrubKey,
    this.scrubInterrupt,
    this.onScrubActive,
  });
  final CardItem item;
  final bool active;
  final bool preload;
  final double speed;
  final ValueNotifier<int>? playNudge;
  final GlobalKey<ZoomableState> zoomKey;
  final ValueChanged<bool> onZoomed;
  final double? aspectRatio;
  final Key scrubKey;
  final ValueNotifier<int>? scrubInterrupt;

  /// 进度条横拖/长按拖动真正接管手势时置 true，结束或取消置 false。
  /// 未加载完成前不会触发。
  final ValueChanged<bool>? onScrubActive;

  @override
  State<_FeedVideo> createState() => _FeedVideoState();
}

class _FeedVideoState extends State<_FeedVideo> {
  VideoPlayerController? _c;
  bool ready = false;
  String? err;
  final _loadLock = FeedPlayerLoadLock();
  bool _userPaused = false;
  bool _seeking = false;
  Duration _seekTo = Duration.zero;
  bool _wasPlaying = false;
  Duration _lastUi = Duration.zero;

  @override
  void initState() {
    super.initState();
    widget.playNudge?.addListener(_nudgePlay);
    widget.scrubInterrupt?.addListener(_onScrubInterrupt);
    if (widget.active || widget.preload) _load();
  }

  void _onScrubInterrupt() {
    if (_seeking) _endScrub(confirm: false);
  }

  void _nudgePlay() {
    final v = _c;
    if (v == null || !widget.active) return;
    if (v.value.isPlaying) {
      _userPaused = true;
      setState(() => v.pause());
      return;
    }
    _userPaused = false;
    setState(() => v.play());
  }

  @override
  void didUpdateWidget(covariant _FeedVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playNudge != widget.playNudge) {
      oldWidget.playNudge?.removeListener(_nudgePlay);
      widget.playNudge?.addListener(_nudgePlay);
    }
    if (oldWidget.scrubInterrupt != widget.scrubInterrupt) {
      oldWidget.scrubInterrupt?.removeListener(_onScrubInterrupt);
      widget.scrubInterrupt?.addListener(_onScrubInterrupt);
    }
    // 列表刷新把同位置的媒体换成了另一条：旧播放器必须重建，否则错播
    if (widget.item.id != oldWidget.item.id) {
      if (_seeking) {
        _seeking = false;
        widget.onScrubActive?.call(false);
      }
      _userPaused = false;
      _loadLock.invalidate();
      final stale = _c;
      _c = null;
      ready = false;
      err = null;
      stale?.removeListener(_onTick);
      stale?.dispose();
      if (widget.active || widget.preload) _load(force: true);
      return;
    }
    if (widget.speed != oldWidget.speed) {
      _c?.setPlaybackSpeed(widget.speed);
    }
    if ((widget.active || widget.preload) && _c == null) _load();
    if (widget.active && !oldWidget.active) {
      if (_c == null) {
        _load();
      } else if (_c!.value.isInitialized && !_userPaused) {
        _c!.play();
      }
    } else if (!widget.active && oldWidget.active) {
      if (_seeking) {
        _seeking = false;
        widget.onScrubActive?.call(false);
      }
      _c?.pause();
    }
  }

  /// 初始化后发生的播放错误（网络断了、盒子重启）：给重试入口，不黑屏到底
  void _onControllerError() {
    if (!mounted) return;
    _loadLock.invalidate();
    setState(() {
      err = '播放出错';
      final stale = _c;
      _c = null;
      ready = false;
      stale?.removeListener(_onTick);
      stale?.dispose();
    });
  }

  Future<void> _load({bool force = false}) async {
    final ticket = _loadLock.begin(force: force);
    if (ticket == null) return;
    VideoPlayerController? ctrl;
    try {
      if (!Api.I.base.startsWith('http://')) {
        await MediaProxy.I.ensure();
      }
      ctrl = VideoPlayerController.networkUrl(
        Uri.parse(MediaProxy.playUrl(widget.item.id)),
        httpHeaders: MediaProxy.playHeaders(),
      );
      await ctrl.initialize().timeout(const Duration(seconds: 12));
      await ctrl.setLooping(true);
      await ctrl.setPlaybackSpeed(widget.speed);
      final kept = await adoptLoaded(
        ctrl,
        ticket: ticket,
        currentGen: () => _loadLock.gen,
        dispose: (c) => c.dispose(),
      );
      if (kept == null) return;
      ctrl = null;
      _c = kept;
      kept.addListener(_onTick);
      kept.addListener(() {
        if (kept.value.hasError) _onControllerError();
      });
      if (widget.active && !_userPaused) {
        await kept.play();
      } else {
        await kept.pause();
      }
      if (mounted && _loadLock.belongs(ticket)) {
        setState(() {
          ready = true;
          err = null;
        });
      }
    } catch (e) {
      try {
        await ctrl?.dispose();
      } catch (_) {}
      if (mounted && _loadLock.belongs(ticket)) {
        setState(() => err = e.toString());
      }
    } finally {
      _loadLock.finish(ticket);
    }
  }

  void _onTick() {
    if (!mounted || _seeking || _c == null) return;
    final p = _c!.value.position;
    if ((p - _lastUi).inMilliseconds.abs() < 200) return;
    _lastUi = p;
    setState(() {});
  }

  String _fmt(Duration d) {
    final s = d.inSeconds.clamp(0, 24 * 3600);
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final r = s % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
    }
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  void _seekAt(double dx, double width) {
    final v = _c;
    if (v == null || width <= 0) return;
    final total = v.value.duration;
    if (total <= Duration.zero) return;
    final t = (dx / width).clamp(0.0, 1.0);
    _seekTo = Duration(milliseconds: (total.inMilliseconds * t).round());
    setState(() {});
  }

  @override
  void dispose() {
    if (_seeking) widget.onScrubActive?.call(false);
    _loadLock.invalidate();
    widget.playNudge?.removeListener(_nudgePlay);
    widget.scrubInterrupt?.removeListener(_onScrubInterrupt);
    _c?.removeListener(_onTick);
    _c?.dispose();
    super.dispose();
  }

  Future<void> _endScrub({required bool confirm}) async {
    if (!_seeking) return;
    final v = _c;
    final itemId = widget.item.id;
    final playing = _wasPlaying;
    _seeking = false;
    widget.onScrubActive?.call(false);
    if (mounted) setState(() {});
    if (v == null) return;
    if (confirm) {
      await v.seekTo(_seekTo);
    }
    if (!mounted || _c != v || widget.item.id != itemId || !widget.active) {
      return;
    }
    if (playing) await v.play();
  }

  Widget _zoomChild(Widget child) {
    return Zoomable(
      key: widget.zoomKey,
      listenPointers: false,
      onZoomed: widget.onZoomed,
      contentAspectRatio: widget.aspectRatio,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.item;
    if (ready && _c != null) {
      final v = _c!;
      final total = v.value.duration;
      final pos = _seeking ? _seekTo : v.value.position;
      final p = total.inMilliseconds <= 0
          ? 0.0
          : (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
      return Stack(
        fit: StackFit.expand,
        children: [
          _zoomChild(
            FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: v.value.size.width,
                height: v.value.size.height,
                child: VideoPlayer(v),
              ),
            ),
          ),
          if (_seeking)
            IgnorePointer(
              child: Center(
                child: Text(
                  '${_fmt(pos)} / ${_fmt(total)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(blurRadius: 10, color: Colors.black54)],
                  ),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewPaddingOf(context).bottom + _scrubBottomPad,
            height: _scrubHitHeight,
            child: KeyedSubtree(
              key: widget.scrubKey,
              child: LayoutBuilder(builder: (context, box) {
                void start(Offset local) {
                  widget.onScrubActive?.call(true);
                  _wasPlaying = v.value.isPlaying;
                  v.pause();
                  _seeking = true;
                  _seekAt(local.dx, box.maxWidth);
                }

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPressStart: (d) => start(d.localPosition),
                  onLongPressMoveUpdate: (d) =>
                      _seekAt(d.localPosition.dx, box.maxWidth),
                  onLongPressEnd: (_) => _endScrub(confirm: true),
                  onLongPressCancel: () => _endScrub(confirm: false),
                  onHorizontalDragStart: (d) => start(d.localPosition),
                  onHorizontalDragUpdate: (d) =>
                      _seekAt(d.localPosition.dx, box.maxWidth),
                  onHorizontalDragEnd: (_) => _endScrub(confirm: true),
                  onHorizontalDragCancel: () => _endScrub(confirm: false),
                  child: Align(
                    alignment: Alignment.center,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: SizedBox(
                          height: _seeking ? 4 : 2,
                          child: LinearProgressIndicator(
                            value: p,
                            backgroundColor: Colors.white24,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      );
    }
    return _zoomChild(
      Stack(
        fit: StackFit.expand,
        children: [
          if (c.wantThumb)
            BoxImage('${Api.I.base}${c.thumb}', fit: BoxFit.contain)
          else
            const ColoredBox(color: Color(0xFF111111)),
          Center(
            child: err != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.videocam_off_outlined,
                          color: Colors.white38, size: 48),
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: _loadLock.loading ? null : _load,
                        child: const Text('播放失败，点我重试'),
                      ),
                    ],
                  )
                : const CircularProgressIndicator(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

String? commentAvatarUrl(Object? raw) {
  final a = raw?.toString() ?? '';
  if (a.isEmpty) return null;
  if (a.startsWith('http')) return a;
  final base = Api.I.base;
  if (base.isEmpty) return a;
  return '$base$a';
}

class CommentSheet extends StatefulWidget {
  const CommentSheet({super.key, required this.item, required this.onChanged});
  final CardItem item;
  final VoidCallback onChanged;

  @override
  State<CommentSheet> createState() => _CommentSheetState();
}

class _CommentSheetState extends State<CommentSheet> {
  final text = TextEditingController();
  List<Map<String, dynamic>> comments = [];
  bool loading = true;
  bool sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      comments = await Api.I.comments(widget.item.id);
    } catch (e) {
      if (mounted) toast(context, '评论加载失败：$e');
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _send() async {
    final body = text.text.trim();
    if (body.isEmpty || sending) return;
    setState(() => sending = true);
    try {
      final r = await Api.I.addComment(widget.item.id, body);
      text.clear();
      setState(() {
        comments.add(r);
        widget.item.commentCount += 1;
      });
      widget.onChanged();
    } catch (e) {
      if (mounted) toast(context, '发送失败：$e');
    }
    if (mounted) setState(() => sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.55,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('评论',
                      style:
                          TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                ),
              ),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : comments.isEmpty
                        ? const Center(
                            child: Text('还没有评论',
                                style: TextStyle(color: Colors.white38)))
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: comments.length,
                            itemBuilder: (_, i) {
                              final c = comments[i];
                              final name = (c['name'] ?? '?').toString();
                              return ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: UserAvatar(
                                  name: name,
                                  url: commentAvatarUrl(c['avatar']),
                                  radius: 18,
                                ),
                                title: Text(name,
                                    style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700)),
                                subtitle: Text((c['body'] ?? '').toString(),
                                    style:
                                        const TextStyle(color: Colors.white70)),
                              );
                            },
                          ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: text,
                        maxLength: 500,
                        decoration: const InputDecoration(
                          hintText: '说点什么…',
                          counterText: '',
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: sending ? null : _send,
                      style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFFF5E7A)),
                      child: Text(sending ? '…' : '发送'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
