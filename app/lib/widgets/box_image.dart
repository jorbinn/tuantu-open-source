/// 盒子图片：弱网自动重试，避免缩略图直接变灰。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api.dart';
import 'raw_image.dart';

class BoxImage extends StatefulWidget {
  const BoxImage(
    this.url, {
    super.key,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.cacheWidth = 512,
    this.placeholder,
    this.retryEpoch = 0,
    this.maxRetryDelay = const Duration(seconds: 30),
    this.retryOnTap = false,
  });

  /// Grid thumbnails use a short cap (~5 s) so a gray tile never waits long.
  static const gridRetryDelay = Duration(seconds: 5);

  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final int? cacheWidth;
  final Widget? placeholder;
  /// A successful parent refresh can revive failed images without evicting
  /// already loaded avatars or changing their cache URLs.
  final int retryEpoch;

  /// Upper bound of the automatic retry backoff.
  final Duration maxRetryDelay;

  /// A failed (gray) tile retries immediately when tapped. Long-press is not
  /// intercepted. Off by default: avatars etc. keep their own tap action.
  final bool retryOnTap;

  @override
  State<BoxImage> createState() => _BoxImageState();
}

/// 信息流原图：缩略图先显示，下载可取消，解码完成前不拿掉封面。
class RawBoxImage extends StatefulWidget {
  const RawBoxImage(
    this.url, {
    super.key,
    required this.placeholder,
    this.fit = BoxFit.contain,
    this.cacheWidth,
  });

  final String url;
  final Widget placeholder;
  final BoxFit fit;
  final int? cacheWidth;

  @override
  State<RawBoxImage> createState() => _RawBoxImageState();
}

class _RawBoxImageState extends State<RawBoxImage> {
  final _get = CancellableHttpGet();
  Uint8List? _bytes;
  String? _url;
  int _loadGen = 0;

  Map<String, String> get _headers => {
        if (Api.I.token != null && Api.I.token!.isNotEmpty)
          'X-Token': Api.I.token!,
      };

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant RawBoxImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _sync();
  }

  void _sync() {
    _get.cancel();
    final ticket = ++_loadGen;
    _url = widget.url;
    _bytes = RawImageGate.cached(widget.url);
    if (_bytes == null) {
      _load(ticket);
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> _load(int ticket) async {
    final url = widget.url;
    for (var i = 0; i < 20; i++) {
      if (!mounted || _loadGen != ticket || _url != url) return;
      final cached = RawImageGate.cached(url);
      if (cached != null) {
        setState(() => _bytes = cached);
        return;
      }
      try {
        final bytes = await _get.get(url, headers: _headers);
        if (!mounted || _loadGen != ticket || _url != url) return;
        if (bytes != null) {
          setState(() => _bytes = bytes);
          return;
        }
      } catch (_) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  @override
  void dispose() {
    _get.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return widget.placeholder;
    return Image.memory(
      bytes,
      fit: widget.fit,
      cacheWidth: widget.cacheWidth,
      gaplessPlayback: true,
      frameBuilder: (_, child, frame, sync) {
        if (sync || frame != null) return child;
        return widget.placeholder;
      },
      errorBuilder: (_, __, ___) => widget.placeholder,
    );
  }
}

/// 全局「盒子又能出图了」信号。任何格子的缩略图在别人失败期间加载成功、
/// 或者列表接口加载成功，都算盒子恢复：所有失败格子在 ~0.3 s 内错开重试，
/// 不用再退出页面重进。
///
/// 防风暴：一波复活之后至少冷却 [minGap] 才会有下一波（期间的信号合并成
/// 冷却结束时的一波）；只复活「最后一次失败早于这一波」的格子；信号只来自
/// 成功，所以一直失败的格子不会自己把自己叫醒。
class BoxImageRevival {
  BoxImageRevival._();

  /// 每一波复活 +1。
  static final ValueNotifier<int> wave = ValueNotifier<int>(0);

  static Duration minGap = const Duration(milliseconds: 1500);

  static Timer? _cooldown;
  static bool _queued = false;
  static int _failedTiles = 0;

  /// 当前处于失败状态的 [BoxImage] 数量。
  static int get failedTiles => _failedTiles;

  /// 请求一波复活。冷却期内合并；没有失败格子时忽略。
  static void bump() {
    // Nothing gray on screen: nothing to revive, no cooldown timer.
    if (_failedTiles == 0) return;
    if (_cooldown != null) {
      _queued = true;
      return;
    }
    _fire();
  }

  static void _fire() {
    _queued = false;
    wave.value++;
    _cooldown = Timer(minGap, () {
      _cooldown = null;
      if (_queued) _fire();
    });
  }

  @visibleForTesting
  static void debugReset() {
    _cooldown?.cancel();
    _cooldown = null;
    _queued = false;
    minGap = const Duration(milliseconds: 1500);
  }
}

class _BoxImageState extends State<BoxImage> with WidgetsBindingObserver {
  static final _rng = math.Random();

  /// Image key generation; bumps on every retry so a fresh stream is resolved.
  int gen = 0;

  /// Consecutive failures since the last success or revival; drives backoff.
  int _failures = 0;
  Timer? _retryTimer;
  bool _failed = false;
  bool _countedFailed = false;
  bool _permanentError = false;
  int _failedAtWave = 0;
  int _errorGen = -1;
  int _successGen = -1;
  bool _visible = true;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    BoxImageRevival.wave.addListener(_onRevivalWave);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    _scheduleRetry();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _scheduleRetry();
  }

  void _setFailedCount(bool failed) {
    if (failed == _countedFailed) return;
    _countedFailed = failed;
    BoxImageRevival._failedTiles += failed ? 1 : -1;
  }

  bool get _canRetryNow => mounted && _failed && _visible && _foreground;

  void _scheduleRetry() {
    if (!_failed || !_visible || !_foreground) {
      _retryTimer?.cancel();
      _retryTimer = null;
      return;
    }
    if (_retryTimer != null) return;
    // Exponential backoff with a cap. Random jitter spreads cards (and
    // clients) apart over time so retries are not synchronized bursts.
    // A 404 (thumbnail not generated yet) keeps the slow 30 s cadence.
    final cap = _permanentError
        ? math.max(widget.maxRetryDelay.inMilliseconds, 30000)
        : widget.maxRetryDelay.inMilliseconds;
    final base = _failures < 16 ? 500 * (1 << _failures) : cap;
    final backoff = math.min(base, cap);
    final jitter = _rng.nextInt(math.min(backoff ~/ 5, 700) + 1);
    _startRetryTimer(Duration(milliseconds: backoff + jitter));
  }

  void _startRetryTimer(Duration delay) {
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (_canRetryNow) {
        setState(() {
          gen++;
          _failures++;
        });
      }
    });
  }

  /// Retry right away with a fresh backoff (tap, parent refresh, revival).
  void _retryNow({Duration delay = Duration.zero}) {
    if (!_failed) return;
    _failures = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!_visible || !_foreground) {
      // Resumes with the short first backoff once visible again.
      return;
    }
    if (delay == Duration.zero) {
      setState(() => gen++);
    } else {
      _retryTimer = Timer(delay, () {
        _retryTimer = null;
        if (_canRetryNow) setState(() => gen++);
      });
    }
  }

  void _onRevivalWave() {
    final wave = BoxImageRevival.wave.value;
    // 404 = the box has no thumbnail yet (e.g. video cover queued); the
    // normal backoff covers that, a revival wave would only add load.
    if (!_failed || _permanentError || _failedAtWave >= wave) return;
    _retryNow(delay: Duration(milliseconds: 30 + _rng.nextInt(270)));
  }

  void _onLoaded(bool fromNetwork) {
    if (_successGen == gen) return;
    _successGen = gen;
    final wasFailed = _failed;
    _failed = false;
    _failures = 0;
    _permanentError = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _setFailedCount(false);
    // Fresh bytes while other tiles are failing = the box serves again.
    if (fromNetwork && (wasFailed || BoxImageRevival.failedTiles > 0)) {
      scheduleMicrotask(BoxImageRevival.bump);
    }
  }

  void _onError(Object error) {
    _failed = true;
    if (_errorGen != gen) {
      _errorGen = gen;
      _failedAtWave = BoxImageRevival.wave.value;
      _permanentError =
          error is NetworkImageLoadException && error.statusCode == 404;
      _setFailedCount(true);
    }
    _scheduleRetry();
  }

  @override
  void didUpdateWidget(covariant BoxImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _retryTimer?.cancel();
      _retryTimer = null;
      gen = 0;
      _failures = 0;
      _failed = false;
      _errorGen = -1;
      _successGen = -1;
      _setFailedCount(false);
    } else if (_failed && oldWidget.retryEpoch != widget.retryEpoch) {
      _failures = 0;
      _retryTimer?.cancel();
      _retryTimer = null;
      gen++;
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _setFailedCount(false);
    BoxImageRevival.wave.removeListener(_onRevivalWave);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Widget get _placeholder =>
      widget.placeholder ?? const ColoredBox(color: Color(0xFF222933));

  @override
  Widget build(BuildContext context) {
    return Image.network(
      widget.url,
      key: ValueKey('${widget.url}#$gen'),
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      cacheWidth: widget.cacheWidth,
      headers: {
        if (Api.I.token != null && Api.I.token!.isNotEmpty)
          'X-Token': Api.I.token!,
      },
      frameBuilder: (_, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) {
          _onLoaded(!wasSynchronouslyLoaded);
          return child;
        }
        return _placeholder;
      },
      errorBuilder: (_, error, __) {
        _onError(error);
        if (!widget.retryOnTap) return _placeholder;
        // 灰格子可以点一下立刻重试；长按不拦截，交给外层（删除/多选）。
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _retryNow(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _placeholder,
              const Center(
                child: Icon(Icons.refresh, size: 18, color: Colors.white24),
              ),
            ],
          ),
        );
      },
    );
  }
}
