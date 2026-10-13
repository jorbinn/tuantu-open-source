/// 信息流播放器同一代只能有一个初始化任务，避免连点重试和快速切页造出多个播放器。
library;

class FeedPlayerLoadLock {
  int gen = 0;
  bool loading = false;

  /// 开始一轮加载。同一代已经在加载时默认拒绝，避免重试按钮连点。
  /// 切媒体 / 强制重试时 [force] 让旧代作废。
  int? begin({bool force = false}) {
    if (loading && !force) return null;
    loading = true;
    return ++gen;
  }

  bool belongs(int ticket) => ticket == gen;

  void finish(int ticket) {
    if (ticket == gen) loading = false;
  }

  /// 滑走、销毁、换媒体：作废在途初始化。
  int invalidate() {
    loading = false;
    return ++gen;
  }
}

/// 初始化完成或失败后，过期结果不能占用新控制器。
Future<T?> adoptLoaded<T>(
  T loaded, {
  required int ticket,
  required int Function() currentGen,
  required Future<void> Function(T value) dispose,
}) async {
  if (ticket != currentGen()) {
    await dispose(loaded);
    return null;
  }
  return loaded;
}
