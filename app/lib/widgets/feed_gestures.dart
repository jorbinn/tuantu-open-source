/// 信息流手势统一归属：触点在 PageView 外层采集，一整轮只有一个状态机。
///
/// 为什么在外层：第一指触发页面拖动后，滚动内容可能收不到新触点，
/// 内部 Zoomable 会漏掉第二指。外层按 pointer ID 持续记录，第二指落下
/// 时停止页面拖动，并把完整触点交给当前媒体缩放。
///
/// 结束条件：本轮曾出现多指，则必须等全部手指离开才结束；一指抬起
/// 只删除对应 pointer。出现过双指后，本轮禁止切 Tab / 点击 / 长按。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'zoomable.dart';

/// 活动媒体与外层触点层之间的会话。页面创建一份，
/// 活动的 FeedItem 注册自己，触点层据此路由手势。
class FeedGestureSession {
  FeedGestureTarget? activeItem;

  /// 第二指落下或横滑成立时停止页面拖动。
  VoidCallback? stopPageDrag;

  /// 统一取消入口：取消、切页、后台时由页面/媒体调用。
  VoidCallback? cancelRound;
}

/// FeedItem 提供给触点层的动作接口。坐标一律是全局坐标。
abstract class FeedGestureTarget {
  bool get gestureReady;

  int get mediaId;

  /// 落点是否在右栏按钮上（这些控件自己处理点击）。
  bool isOverRail(Offset global);

  /// 落点是否在**可用**进度条的真实渲染区域上。
  bool isOverScrub(Offset global);

  /// 落点是否可长按倍速（视频倍速区）。
  bool isBoostSpot(Offset global);

  /// 已放大时单指只用来拖细节，不弹菜单、不点暂停。
  bool get zoomed;

  Size get mediaSize;

  void tapMedia(Offset global);

  void doubleTapMedia(Offset global);

  bool get inBurstWindow;

  void openMenu();

  void boostStart();

  void boostMove(Offset global);

  /// [confirm] 仅在正常松手且命中锁定区时由目标自己决定；
  /// 取消路径必须传 false。
  void boostEnd(bool confirm);

  /// 横滑切 Tab 期间锁翻页；结束传入 false 释放。
  void setTabDrag(bool active);

  ZoomableState? mediaZoom();

  /// 收尾本轮手势遗留状态（临时倍速、进度预览等），不得回叫 cancelRound。
  void cancelGestures();

  /// 第二指加入时丢掉进度条占用，且不得异步恢复旧视频。
  void interruptScrub();
}

class FeedPointerLayer extends StatefulWidget {
  const FeedPointerLayer({
    super.key,
    required this.session,
    required this.child,
    this.onTabSwitch,
    this.onTabProgress,
  });

  final FeedGestureSession session;
  final Widget child;

  /// 左滑 +1，右滑 -1。首页用来切顶部 Tab。
  final ValueChanged<int>? onTabSwitch;

  /// 横向拖动时传出 -1...1 的实时页偏移供指示线跟手。
  final ValueChanged<double>? onTabProgress;

  @override
  State<FeedPointerLayer> createState() => FeedPointerLayerState();
}

class FeedPointerLayerState extends State<FeedPointerLayer> {
  final Map<int, Offset> _points = {};
  final Map<int, Offset> _origins = {};
  int? _primary;
  bool _multiSeen = false;
  bool _axisLocked = false;
  bool _horizontal = false;
  bool _controls = false;
  bool _scrubCandidate = false;
  bool _longPressFired = false;
  bool _boosting = false;
  bool _doubleCandidate = false;
  bool _dragStopped = false;
  bool _clearing = false;
  Timer? _pressTimer;
  Timer? _singleTapTimer;
  Offset _pendingTapPos = Offset.zero;
  int _lastTapAt = 0;
  Offset _lastTapPos = Offset.zero;

  FeedGestureSession get _session => widget.session;

  ZoomableState? get _zoom => _session.activeItem?.mediaZoom();

  bool get _mediaZoomed =>
      (_session.activeItem?.zoomed ?? false) || (_zoom?.zoomed ?? false);

  @override
  void initState() {
    super.initState();
    _session.cancelRound = cancelRound;
  }

  @override
  void didUpdateWidget(covariant FeedPointerLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      if (oldWidget.session.cancelRound == cancelRound) {
        oldWidget.session.cancelRound = null;
      }
      _session.cancelRound = cancelRound;
    }
  }

  @override
  void dispose() {
    if (_session.cancelRound == cancelRound) {
      _session.cancelRound = null;
    }
    _pressTimer?.cancel();
    _singleTapTimer?.cancel();
    super.dispose();
  }

  Offset _toZoomLocal(ZoomableState zoom, Offset global) {
    final box = zoom.context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return global;
    return box.globalToLocal(global);
  }

  void _forwardDown(int pointer, Offset global) {
    final zoom = _zoom;
    if (zoom == null) return;
    zoom.pointerDown(pointer, _toZoomLocal(zoom, global));
  }

  void _forwardMove(int pointer, Offset global) {
    final zoom = _zoom;
    if (zoom == null) return;
    zoom.pointerMove(pointer, _toZoomLocal(zoom, global));
  }

  void _forwardUp(int pointer) => _zoom?.pointerUp(pointer);

  void _forwardCancel(int pointer) => _zoom?.pointerCancel(pointer);

  void _stopDrag() {
    if (_dragStopped) return;
    _dragStopped = true;
    _session.stopPageDrag?.call();
  }

  void _resetFlags() {
    _primary = null;
    _multiSeen = false;
    _axisLocked = false;
    _horizontal = false;
    _controls = false;
    _scrubCandidate = false;
    _longPressFired = false;
    _boosting = false;
    _doubleCandidate = false;
    _dragStopped = false;
  }

  /// 统一取消入口：PointerCancel、切页、覆盖页面、后台都走这里。
  /// 只清理状态，绝不触发切 Tab、倍速确认或单击。
  void cancelRound() {
    if (_clearing) return;
    _clearing = true;
    try {
      _pressTimer?.cancel();
      _pressTimer = null;
      _singleTapTimer?.cancel();
      _singleTapTimer = null;
      _lastTapAt = 0;
      _doubleCandidate = false;
      if (_boosting) {
        _boosting = false;
        _session.activeItem?.boostEnd(false);
      }
      if (_horizontal) {
        _session.activeItem?.setTabDrag(false);
        widget.onTabProgress?.call(0);
      }
      for (final id in _points.keys.toList()) {
        _forwardCancel(id);
      }
      _points.clear();
      _origins.clear();
      _resetFlags();
      _session.activeItem?.cancelGestures();
    } finally {
      _clearing = false;
    }
  }

  void _pointerDown(PointerDownEvent e) {
    _points[e.pointer] = e.position;
    _origins[e.pointer] = e.position;
    _forwardDown(e.pointer, e.position);

    if (_points.length == 1) {
      _beginRound(e);
      return;
    }
    _onAddedFinger();
  }

  void _beginRound(PointerDownEvent e) {
    _primary = e.pointer;
    _multiSeen = false;
    _axisLocked = false;
    _horizontal = false;
    _longPressFired = false;
    _boosting = false;
    _dragStopped = false;
    _scrubCandidate = false;
    _controls = false;
    _doubleCandidate = false;

    final item = _session.activeItem;
    if (item == null || !item.gestureReady) {
      _controls = true;
      return;
    }
    if (item.isOverRail(e.position)) {
      _controls = true;
      return;
    }
    if (item.isOverScrub(e.position)) {
      _scrubCandidate = true;
      return;
    }
    if (_mediaZoomed) {
      // 放大后单指只拖细节，不进入长按菜单/倍速。
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_singleTapTimer != null &&
        _lastTapAt > 0 &&
        now - _lastTapAt < feedTapWindow.inMilliseconds &&
        (e.position - _lastTapPos).distance < 64) {
      _singleTapTimer?.cancel();
      _singleTapTimer = null;
      _doubleCandidate = true;
      return;
    }

    _pressTimer?.cancel();
    _pressTimer = Timer(feedLongPressDelay, _fireLongPress);
  }

  void _onAddedFinger() {
    _multiSeen = true;
    _doubleCandidate = false;
    _pressTimer?.cancel();
    _pressTimer = null;
    _singleTapTimer?.cancel();
    _singleTapTimer = null;
    _lastTapAt = 0;
    if (_boosting) {
      _boosting = false;
      _session.activeItem?.boostEnd(false);
    }
    if (_horizontal) {
      _horizontal = false;
      _session.activeItem?.setTabDrag(false);
      widget.onTabProgress?.call(0);
    }
    _session.activeItem?.interruptScrub();
    _stopDrag();
  }

  void _fireLongPress() {
    _pressTimer = null;
    final item = _session.activeItem;
    if (item == null ||
        _multiSeen ||
        _points.length != 1 ||
        _controls ||
        _scrubCandidate ||
        _horizontal ||
        _mediaZoomed) {
      return;
    }
    final pos = _points[_primary];
    if (pos == null) return;
    _longPressFired = true;
    _singleTapTimer?.cancel();
    _singleTapTimer = null;
    _lastTapAt = 0;
    _doubleCandidate = false;
    // 长按成立后必须停掉 PageView，否则继续下划会翻到下一条。
    _stopDrag();
    if (item.isBoostSpot(pos)) {
      _boosting = true;
      item.boostStart();
    } else {
      item.openMenu();
    }
  }

  void _pointerMove(PointerMoveEvent e) {
    if (!_points.containsKey(e.pointer)) return;
    _points[e.pointer] = e.position;
    _forwardMove(e.pointer, e.position);

    final zoomed = _mediaZoomed;
    if (zoomed) {
      _pressTimer?.cancel();
      _pressTimer = null;
    }
    if (_points.length >= 2 || zoomed || _multiSeen) return;
    if (e.pointer != _primary) return;
    if (_controls) return;
    if (_boosting) {
      _session.activeItem?.boostMove(e.position);
      return;
    }
    if (_longPressFired) return;

    final origin = _origins[_primary];
    if (origin == null) return;
    final dx = e.position.dx - origin.dx;
    final dy = e.position.dy - origin.dy;
    if (_pressTimer != null && (dx.abs() > 18 || dy.abs() > 18)) {
      _pressTimer?.cancel();
      _pressTimer = null;
    }
    if (!_axisLocked) {
      final axis = feedDecideAxis(dx, dy);
      if (axis == FeedSwipeAxis.undecided) return;
      _axisLocked = true;
      _singleTapTimer?.cancel();
      _singleTapTimer = null;
      _lastTapAt = 0;
      _doubleCandidate = false;
      if (axis == FeedSwipeAxis.horizontal &&
          !_scrubCandidate &&
          widget.onTabSwitch != null) {
        _pressTimer?.cancel();
        _pressTimer = null;
        _horizontal = true;
        _stopDrag();
        _session.activeItem?.setTabDrag(true);
      }
      return;
    }
    if (_horizontal && widget.onTabProgress != null) {
      final width = _session.activeItem?.mediaSize.width ?? 0;
      widget.onTabProgress!(
        width > 0 ? (-dx / width).clamp(-1.0, 1.0).toDouble() : 0,
      );
    }
  }

  void _pointerUp(PointerUpEvent e) =>
      _pointerGone(e.pointer, e.position, cancelled: false);

  void _pointerCancel(PointerCancelEvent e) =>
      _pointerGone(e.pointer, e.position, cancelled: true);

  void _pointerGone(int pointer, Offset pos, {required bool cancelled}) {
    final origin = _primary != null ? _origins[_primary] : null;
    final last = _primary != null ? _points[_primary] : null;
    _points.remove(pointer);
    _origins.remove(pointer);
    if (cancelled) {
      _forwardCancel(pointer);
    } else {
      _forwardUp(pointer);
    }

    if (_points.isNotEmpty) {
      if (pointer == _primary) {
        _primary = _points.keys.first;
      }
      return;
    }

    _pressTimer?.cancel();
    _pressTimer = null;

    final item = _session.activeItem;
    final wasHorizontal = _horizontal;
    final wasBoosting = _boosting;
    final wasMulti = _multiSeen;
    final wasControls = _controls;
    final wasScrub = _scrubCandidate;
    final wasLongPress = _longPressFired;
    final wasAxis = _axisLocked;
    final wasDouble = _doubleCandidate;

    if (wasHorizontal) {
      item?.setTabDrag(false);
      widget.onTabProgress?.call(0);
    }
    if (wasBoosting) {
      _boosting = false;
      item?.boostEnd(!cancelled);
    }

    if (!cancelled && item != null && item.gestureReady && !wasMulti) {
      if (wasHorizontal) {
        if (origin != null && last != null && widget.onTabSwitch != null) {
          final netDx = last.dx - origin.dx;
          if (netDx < -feedTabSwitchPx) widget.onTabSwitch!(1);
          if (netDx > feedTabSwitchPx) widget.onTabSwitch!(-1);
        }
      } else if (!wasAxis &&
          !wasLongPress &&
          !wasControls &&
          !wasScrub &&
          !item.zoomed) {
        _settleTap(item, pos, forceDouble: wasDouble);
      }
    }

    _resetFlags();
  }

  void _settleTap(
    FeedGestureTarget item,
    Offset pos, {
    required bool forceDouble,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (forceDouble ||
        item.inBurstWindow ||
        (_lastTapAt > 0 &&
            now - _lastTapAt < feedTapWindow.inMilliseconds &&
            (pos - _lastTapPos).distance < 64)) {
      _singleTapTimer?.cancel();
      _singleTapTimer = null;
      _lastTapAt = 0;
      item.doubleTapMedia(pos);
      return;
    }
    _lastTapAt = now;
    _lastTapPos = pos;
    _pendingTapPos = pos;
    _singleTapTimer?.cancel();
    _singleTapTimer = Timer(feedTapWindow, () {
      _singleTapTimer = null;
      _lastTapAt = 0;
      _session.activeItem?.tapMedia(_pendingTapPos);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _pointerDown,
      onPointerMove: _pointerMove,
      onPointerUp: _pointerUp,
      onPointerCancel: _pointerCancel,
      child: widget.child,
    );
  }
}

bool hitTestGlobal(GlobalKey key, Offset global) {
  final box = key.currentContext?.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return false;
  final local = box.globalToLocal(global);
  return local.dx >= 0 &&
      local.dy >= 0 &&
      local.dx <= box.size.width &&
      local.dy <= box.size.height;
}
