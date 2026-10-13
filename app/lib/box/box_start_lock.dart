/// 盒子启动互斥：同一时刻只允许一个有效启动流程。
library;

import 'dart:async';

class BoxStartLock {
  int _epoch = 0;
  Future<String?>? _inFlight;

  int get epoch => _epoch;
  bool get isBusy => _inFlight != null;

  /// [alreadyRunning] 为 true 时直接返回 null（已在跑，视为成功）。
  /// 启动进行中再次调用会加入同一次结果，不会开第二条流程。
  Future<String?> run({
    required bool alreadyRunning,
    required Future<String?> Function(int epoch) body,
  }) {
    if (alreadyRunning) return Future<String?>.value(null);
    final existing = _inFlight;
    if (existing != null) return existing;
    final epoch = ++_epoch;
    final done = Completer<String?>();
    _inFlight = done.future;
    () async {
      try {
        done.complete(await body(epoch));
      } catch (e, st) {
        done.completeError(e, st);
      } finally {
        if (identical(_inFlight, done.future)) _inFlight = null;
      }
    }();
    return done.future;
  }

  bool isCurrent(int epoch) => epoch == _epoch;

  /// 作废进行中的启动，让它放弃提交。不负责关资源。
  void cancel() => _epoch++;
}
