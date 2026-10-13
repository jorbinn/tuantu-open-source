import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import 'network_recovery.dart';

/// 在同一次保存任务中续传。旧盒子不带 ETag 时安全地重新下载；
/// 不跨进程复用半成品，不会把旧盒子或旧文件的内容拼入新文件。
Future<int> resumableDownload(
  Dio client,
  String path,
  String destPath, {
  void Function(double)? onProgress,
  bool Function()? isCancelled,
  int attempts = transferNetworkAttempts,
  Duration stallTimeout = const Duration(seconds: 20),
  Duration Function(int) retryDelay = networkRetryDelay,
}) async {
  final file = File(destPath);
  var received = 0;
  int? expectedTotal;
  String? validator;
  var succeeded = false;
  final cancel = CancelToken();
  final cancelPoll = Timer.periodic(const Duration(milliseconds: 200), (_) {
    if (isCancelled?.call() == true) cancel.cancel('已取消');
  });
  try {
    for (var attempt = 0; attempt < attempts; attempt++) {
      IOSink? sink;
      StreamIterator<List<int>>? chunks;
      try {
        if (isCancelled?.call() == true) throw '已取消';
        final offset = validator == null ? 0 : received;
        final response = await client.get<ResponseBody>(
          path,
          cancelToken: cancel,
          options: Options(
            responseType: ResponseType.stream,
            receiveTimeout: stallTimeout,
            headers: {
              'Accept-Encoding': 'identity',
              if (offset > 0) 'Range': 'bytes=$offset-',
              if (offset > 0) 'If-Range': validator,
            },
            validateStatus: (_) => true,
          ),
        );
        final stream = response.data?.stream;
        if (stream == null) throw const HttpException('没有收到文件内容');
        final status = response.statusCode;
        final etag = response.headers.value('etag');
        final length = int.tryParse(
          response.headers.value('content-length') ?? '',
        );
        if (status == 206) {
          final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
              .firstMatch(response.headers.value('content-range') ?? '');
          final start = range == null ? -1 : int.parse(range[1]!);
          final end = range == null ? -1 : int.parse(range[2]!);
          final total = range == null ? -1 : int.parse(range[3]!);
          if (offset == 0 ||
              start != offset ||
              end < start ||
              total <= end ||
              (length != null && length != end - start + 1) ||
              etag != validator ||
              expectedTotal != total) {
            await stream.listen((_) {}).cancel();
            validator = null;
            received = 0;
            expectedTotal = null;
            throw const HttpException('续传校验不一致，重新下载');
          }
        } else if (status == 200) {
          received = 0;
          expectedTotal = length;
          validator = etag != null && etag.startsWith('"') ? etag : null;
        } else if (status == 416 && offset > 0) {
          await stream.listen((_) {}).cancel();
          validator = null;
          received = 0;
          expectedTotal = null;
          throw const HttpException('续传范围已变化，重新下载');
        } else {
          await stream.listen((_) {}).cancel();
          throw DioException(
            requestOptions: response.requestOptions,
            response: response,
            type: DioExceptionType.badResponse,
          );
        }
        sink = file.openWrite(
          mode: received > 0 ? FileMode.append : FileMode.write,
        );
        chunks = StreamIterator(stream.timeout(stallTimeout));
        while (await Future.any<bool>([
          chunks.moveNext(),
          cancel.whenCancel.then<bool>((error) => throw error),
        ])) {
          final chunk = chunks.current;
          if (isCancelled?.call() == true) throw '已取消';
          // Await disk backpressure; do not buffer a whole video in IOSink.
          sink.add(chunk);
          await sink.flush();
          received += chunk.length;
          if (expectedTotal != null && received > expectedTotal) {
            validator = null;
            received = 0;
            throw const HttpException('下载长度不一致');
          }
          onProgress?.call(
            expectedTotal != null && expectedTotal > 0
                ? received / expectedTotal
                : -1,
          );
        }
        unawaited(chunks.cancel());
        chunks = null;
        await sink.close();
        sink = null;
        if (expectedTotal != null && received != expectedTotal) {
          throw const HttpException('文件未收完整，继续下载');
        }
        if (isCancelled?.call() == true) throw '已取消';
        succeeded = true;
        onProgress?.call(1);
        return received;
      } catch (e) {
        if (chunks != null) unawaited(chunks.cancel());
        if (sink != null) {
          try {
            await sink.close();
          } catch (_) {}
        }
        if (cancel.isCancelled || isCancelled?.call() == true) throw '已取消';
        if (!transientNet(e) || attempt == attempts - 1) rethrow;
        await waitForNetworkRetry(
          retryDelay(attempt),
          cancelToken: cancel,
          isCancelled: isCancelled,
        );
      }
    }
    throw const HttpException('下载未完成');
  } finally {
    cancelPoll.cancel();
    cancel.cancel();
    if (!succeeded && await file.exists()) await file.delete();
  }
}
