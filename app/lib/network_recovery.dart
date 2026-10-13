import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

final _networkRandom = Random();
// 快速拒绝连接时也给约 50 秒的恢复窗口，而不是几秒内耗尽重试。
const transferNetworkAttempts = 8;

/// 有上限的指数退避，并让同一热点上的手机错峰重试。
Duration networkRetryDelay(int attempt) => Duration(
  milliseconds:
      min(12000, 800 * (1 << min(attempt, 4))) + _networkRandom.nextInt(701),
);

bool transientNet(Object e) {
  if (e is DioException) {
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError => true,
      DioExceptionType.unknown => e.error != null && transientNet(e.error!),
      _ => false,
    };
  }
  if (e is SocketException || e is HttpException || e is TimeoutException) {
    return true;
  }
  // 兼容平台通道/旧保存接口抛出的字符串，不把 HTTP 4xx 当网络故障重发。
  final s = e.toString().toLowerCase();
  return s.contains('connection reset') ||
      s.contains('broken pipe') ||
      s.contains('connection closed') ||
      s.contains('connection refused') ||
      s.contains('timed out') ||
      s.contains('timeout');
}

String friendlyNet(Object e, String action) {
  if (transientNet(e)) return '$action失败：和盒子的连接断了，请再试一次';
  return '$action失败：$e';
}

/// 即使正在退避，也能及时响应页面退出或下载取消。
Future<void> waitForNetworkRetry(
  Duration delay, {
  CancelToken? cancelToken,
  bool Function()? isCancelled,
}) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < delay) {
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    if (isCancelled?.call() == true) throw '已取消';
    final left = delay - clock.elapsed;
    await Future<void>.delayed(
      left < const Duration(milliseconds: 200)
          ? left
          : const Duration(milliseconds: 200),
    );
  }
  if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
  if (isCancelled?.call() == true) throw '已取消';
}

Future<T> retryNet<T>(
  Future<T> Function() fn, {
  int attempts = 3,
  CancelToken? cancelToken,
}) async {
  final n = max(1, attempts);
  for (var i = 0; ; i++) {
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    try {
      return await fn();
    } catch (e) {
      if (!transientNet(e) || i >= n - 1) rethrow;
      await waitForNetworkRetry(networkRetryDelay(i), cancelToken: cancelToken);
    }
  }
}
