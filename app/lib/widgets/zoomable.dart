/// 双指放大；放大后单指拖细节。缩回 1 倍后单指交还给信息流。
/// 捏合在 Listener 里做，不走 InteractiveViewer 的手势竞技场。
/// 允许先按住再落下第二指，不要求两指同时碰到屏幕。
///
/// 信息流里由外层 FeedPointerLayer 采集触点，再调用本文件的 pointer API，
/// 此时 [listenPointers] 为 false，避免内外两层重复计算缩放。
library;

import 'package:flutter/material.dart';

/// 本轮拖动起点与已选定的吸附目标。必须放在独立对象里：
/// Scrollable 会 `applyTo` 出新的 Physics 实例，写在 Physics 字段上会丢。
class PagingDragMemory {
  double? startPixels;
  double? committedTarget;

  void beginIfNeeded(double pixels) {
    committedTarget = null;
    startPixels ??= pixels;
  }

  void clearStart() {
    startPixels = null;
  }

  void reset() {
    startPixels = null;
    committedTarget = null;
  }
}

/// PageView 翻页锁。用 ValueNotifier 同步改值，不必等 setState。
/// 短行程即可翻页：划过约 5% 屏高就吸附。
///
/// 注意：PageView 会把框架的 PageScrollPhysics 包在我们外层
/// （page_view.dart: `_kPagePhysics.applyTo(physics)`），松手落位轮不到我们
/// 决定。两处 PageView 都必须配 `pageSnapping: false`，本物理层才会真正
/// 接管松手吸附。
class PagingLockPhysics extends PageScrollPhysics {
  PagingLockPhysics({
    required this.lock,
    PagingDragMemory? memory,
    super.parent,
  }) : memory = memory ?? PagingDragMemory();

  final ValueNotifier<bool> lock;
  final PagingDragMemory memory;

  static const snapFraction = 0.05;

  @override
  PagingLockPhysics applyTo(ScrollPhysics? ancestor) {
    return PagingLockPhysics(
      lock: lock,
      memory: memory,
      parent: buildParent(ancestor),
    );
  }

  @override
  double get minFlingVelocity => super.minFlingVelocity * 0.5;

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) {
    if (lock.value) return false;
    return super.shouldAcceptUserOffset(position);
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    if (lock.value) return 0;
    memory.beginIfNeeded(position.pixels);
    return super.applyPhysicsToUserOffset(position, offset);
  }

  /// 松手后应落到哪一页（像素）。前后方向对称：
  /// 快甩按速度方向翻页；慢松手按本轮净位移，划过 5% 行程就算翻页。
  /// 没有起点时（单元测试快照）退回按当前页内比例判断。
  double targetPixelsFor(
    ScrollMetrics position,
    double velocity, {
    double? dragStartPixels,
  }) {
    final dim = position.viewportDimension;
    if (dim <= 0) return position.pixels;
    final page = position.pixels / dim;
    final lower = page.floorToDouble();
    final frac = page - lower;
    final fling = minFlingVelocity;
    final maxPage = position.maxScrollExtent / dim;
    double dest;
    if (velocity >= fling) {
      dest = lower + 1;
    } else if (velocity <= -fling) {
      dest = lower;
    } else if (dragStartPixels != null) {
      final startPage = (dragStartPixels / dim).roundToDouble();
      final net = page - startPage;
      if (net >= snapFraction) {
        dest = startPage + 1;
      } else if (net <= -snapFraction) {
        dest = startPage - 1;
      } else {
        dest = startPage;
      }
    } else {
      dest = frac >= snapFraction ? lower + 1 : lower;
    }
    dest = dest.clamp(0.0, maxPage);
    return dest * dim;
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (lock.value) {
      memory.reset();
      return null;
    }
    final start = memory.startPixels;
    memory.clearStart();
    final target = memory.committedTarget ??
        targetPixelsFor(position, velocity, dragStartPixels: start);
    memory.committedTarget = target;
    if ((target - position.pixels).abs() < 0.5) {
      memory.reset();
      return null;
    }
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: toleranceFor(position),
    );
  }
}

/// 过 slop 后判定轴向。水平分量不低于竖直即视为横滑（约 45°），
/// 避免必须“标准横滑”才能切 Tab。
enum FeedSwipeAxis { undecided, horizontal, vertical }

/// 横滑切 Tab 的行程阈值。有内容和空列表共用。
const feedTabSwitchPx = 45.0;

/// 单击 / 双击共用窗口。第二次按下落在窗口内则暂缓单击。
const feedTapWindow = Duration(milliseconds: 320);

/// 长按菜单 / 倍速的唯一计时。
const feedLongPressDelay = Duration(milliseconds: 500);

FeedSwipeAxis feedDecideAxis(double dx, double dy, {double slop = 8}) {
  if (dx.abs() < slop && dy.abs() < slop) return FeedSwipeAxis.undecided;
  return dx.abs() >= dy.abs()
      ? FeedSwipeAxis.horizontal
      : FeedSwipeAxis.vertical;
}

class Zoomable extends StatefulWidget {
  const Zoomable({
    super.key,
    required this.child,
    this.onZoomed,
    this.enabled = true,
    this.maxScale = 4,
    this.listenPointers = true,
    this.contentAspectRatio,
  });

  final Widget child;
  final ValueChanged<bool>? onZoomed;
  final bool enabled;
  final double maxScale;

  /// false 时不自己挂 Listener，只接受外层 pointer API。
  final bool listenPointers;

  /// 按 contain 后的实际画面比例夹紧平移，减少拖出大块空白。
  final double? contentAspectRatio;

  @override
  State<Zoomable> createState() => ZoomableState();
}

class ZoomableState extends State<Zoomable> {
  final TransformationController controller = TransformationController();
  bool zoomed = false;
  final Map<int, Offset> _points = {};
  Size _view = Size.zero;
  double _pinchDist = 0;
  Offset? _lastFocal;

  void reset() {
    _points.clear();
    _pinchDist = 0;
    _lastFocal = null;
    controller.value = Matrix4.identity();
    _setZoomed(false);
  }

  int get _pointers => _points.length;

  bool get _scaled => controller.value.getMaxScaleOnAxis() > 1.05;

  /// 只有双指或已经放大才锁翻页。单指按下不锁，否则上下滑会滑不动。
  bool get _lock => _scaled || _pointers >= 2;

  void _setZoomed(bool v) {
    if (zoomed == v) return;
    setState(() => zoomed = v);
    widget.onZoomed?.call(v);
  }

  void _emit() => _setZoomed(_lock);

  List<Offset> _pairPoints() {
    final ids = _points.keys.toList()..sort();
    return [_points[ids[0]]!, _points[ids[1]]!];
  }

  double _pairDistance() {
    if (_pointers < 2) return 0;
    final pts = _pairPoints();
    return (pts[0] - pts[1]).distance;
  }

  Offset _pairFocal() {
    final pts = _pairPoints();
    return (pts[0] + pts[1]) / 2;
  }

  void _rebuildPinchBaseline() {
    if (_pointers >= 2) {
      _pinchDist = _pairDistance();
      _lastFocal = _pairFocal();
    } else {
      _pinchDist = 0;
      _lastFocal = null;
    }
  }

  /// 外层或内部 Listener 共用：按下。
  void pointerDown(int pointer, Offset local) {
    if (!widget.enabled) return;
    _points[pointer] = local;
    _rebuildPinchBaseline();
    _emit();
  }

  /// 外层或内部 Listener 共用：移动。双指 = 距离缩放 + 中心点平移。
  void pointerMove(int pointer, Offset local) {
    if (!widget.enabled) return;
    final prev = _points[pointer];
    if (prev == null) return;
    _points[pointer] = local;
    if (_pointers >= 2) {
      final dist = _pairDistance();
      final focal = _pairFocal();
      if (_pinchDist > 1 && dist > 1) {
        _pinch(_lastFocal ?? focal, focal, dist / _pinchDist);
      }
      _pinchDist = dist;
      _lastFocal = focal;
      _emit();
      return;
    }
    _pinchDist = 0;
    _lastFocal = null;
    if (!_scaled) return;
    final delta = local - prev;
    final next = Matrix4.copy(controller.value);
    next.leftTranslateByDouble(delta.dx, delta.dy, 0, 1);
    controller.value = next;
    _clamp();
  }

  void pointerUp(int pointer) => _pointerGone(pointer);

  void pointerCancel(int pointer) => _pointerGone(pointer);

  void _pointerGone(int pointer) {
    if (!widget.enabled) return;
    _points.remove(pointer);
    _rebuildPinchBaseline();
    if (_pointers < 2 && !_scaled) {
      reset();
      return;
    }
    _clamp();
    _emit();
  }

  /// 双指捏合：先跟中心点平移，再绕新中心缩放。接近 1 倍时比例和偏移一起归位。
  void _pinch(Offset oldFocal, Offset newFocal, double factor) {
    final current = controller.value.getMaxScaleOnAxis();
    if (current <= 0) return;
    final target = (current * factor).clamp(1.0, widget.maxScale);
    final used = target / current;
    final m = Matrix4.copy(controller.value);
    if (target <= 1.0) {
      m.setIdentity();
      controller.value = m;
      return;
    }
    if ((used - 1.0).abs() < 0.0008 && (newFocal - oldFocal).distance < 0.4) {
      return;
    }
    final tx = m.storage[12] + (newFocal.dx - oldFocal.dx);
    final ty = m.storage[13] + (newFocal.dy - oldFocal.dy);
    final s = current * used;
    m.setIdentity();
    m.storage[0] = s;
    m.storage[5] = s;
    m.storage[10] = 1;
    m.storage[12] = newFocal.dx * (1 - used) + used * tx;
    m.storage[13] = newFocal.dy * (1 - used) + used * ty;
    controller.value = m;
    _clamp();
  }

  Rect _contentRect() {
    final aspect = widget.contentAspectRatio;
    if (aspect == null || aspect <= 0 || _view == Size.zero) {
      return Offset.zero & _view;
    }
    final viewAspect = _view.width / _view.height;
    if (aspect >= viewAspect) {
      final h = _view.width / aspect;
      return Rect.fromLTWH(0, (_view.height - h) / 2, _view.width, h);
    }
    final w = _view.height * aspect;
    return Rect.fromLTWH((_view.width - w) / 2, 0, w, _view.height);
  }

  void _clamp() {
    if (_view == Size.zero) return;
    final m = controller.value;
    final s = m.getMaxScaleOnAxis();
    if (s <= 1.05) return;
    final c = _contentRect();
    var minTx = _view.width - c.right * s;
    var maxTx = -c.left * s;
    var minTy = _view.height - c.bottom * s;
    var maxTy = -c.top * s;
    var tx = m.storage[12];
    var ty = m.storage[13];
    if (minTx > maxTx) {
      tx = (minTx + maxTx) / 2;
    } else {
      tx = tx.clamp(minTx, maxTx);
    }
    if (minTy > maxTy) {
      ty = (minTy + maxTy) / 2;
    } else {
      ty = ty.clamp(minTy, maxTy);
    }
    if (tx != m.storage[12] || ty != m.storage[13]) {
      m.storage[12] = tx;
      m.storage[13] = ty;
      controller.value = m;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return LayoutBuilder(builder: (context, box) {
      _view = Size(box.maxWidth, box.maxHeight);
      Widget child = ClipRect(
        child: AnimatedBuilder(
          animation: controller,
          builder: (_, child) => Transform(
            transform: controller.value,
            alignment: Alignment.topLeft,
            filterQuality: FilterQuality.low,
            child: child,
          ),
          child: widget.child,
        ),
      );
      if (!widget.listenPointers) return child;
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => pointerDown(e.pointer, e.localPosition),
        onPointerMove: (e) => pointerMove(e.pointer, e.localPosition),
        onPointerUp: (e) => pointerUp(e.pointer),
        onPointerCancel: (e) => pointerCancel(e.pointer),
        child: child,
      );
    });
  }
}
