import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/resumable_download.dart';
import 'package:tuantu_app/network_recovery.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions, int) respond;
  final calls = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    calls.add(options);
    return respond(options, calls.length);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _body(
  List<int> data, {
  int status = 200,
  String? tag = '"v1"',
  int? length,
  String? range,
  bool broken = false,
}) {
  Stream<Uint8List> chunks() async* {
    yield Uint8List.fromList(data);
    if (broken) throw const SocketException('Connection reset by peer');
  }

  return ResponseBody(
    chunks(),
    status,
    headers: {
      if (tag != null) 'etag': [tag],
      'content-length': ['${length ?? data.length}'],
      if (range != null) 'content-range': [range],
    },
  );
}

void main() {
  late Directory dir;
  late Dio dio;
  late String path;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('tuantu_resume_');
    path = '${dir.path}/download.bin';
    dio = Dio(BaseOptions(baseUrl: 'http://download.test'));
  });
  tearDown(() {
    dio.close(force: true);
    dir.deleteSync(recursive: true);
  });
  Future<int> download({bool Function()? cancel, int attempts = 3}) =>
      resumableDownload(
        dio,
        '/raw',
        path,
        isCancelled: cancel,
        attempts: attempts,
        retryDelay: (_) => Duration.zero,
      );

  test('流中途断开使用 Range+If-Range，只接着下载剩余字节', () async {
    final adapter = _Adapter(
      (o, n) async => n == 1
          ? _body([1, 2, 3], length: 6, broken: true)
          : _body([4, 5, 6], status: 206, range: 'bytes 3-5/6'),
    );
    dio.httpClientAdapter = adapter;
    expect(await download(), 6);
    expect(File(path).readAsBytesSync(), [1, 2, 3, 4, 5, 6]);
    expect(adapter.calls[1].headers['Range'], 'bytes=3-');
    expect(adapter.calls[1].headers['If-Range'], '"v1"');
  });
  test('正常结束但长度不足也必须续传，不能保存残缺文件', () async {
    final adapter = _Adapter(
      (o, n) async => n == 1
          ? _body([1, 2], length: 4)
          : _body([3, 4], status: 206, range: 'bytes 2-3/4'),
    );
    dio.httpClientAdapter = adapter;
    expect(await download(), 4);
    expect(File(path).readAsBytesSync(), [1, 2, 3, 4]);
  });
  test('旧盒子没有 ETag 时重传全部，不盲目拼接', () async {
    final adapter = _Adapter(
      (o, n) async => n == 1
          ? _body([1, 2], length: 4, broken: true, tag: null)
          : _body([1, 2, 3, 4], tag: null),
    );
    dio.httpClientAdapter = adapter;
    expect(await download(), 4);
    expect(adapter.calls[1].headers.containsKey('Range'), isFalse);
    expect(File(path).readAsBytesSync(), [1, 2, 3, 4]);
  });
  test('文件变化或服务端忽略 Range 返回200时清空旧前缀', () async {
    dio.httpClientAdapter = _Adapter(
      (o, n) async => n == 1
          ? _body([1, 2], length: 4, broken: true)
          : _body([8, 7, 6, 5], tag: '"v2"'),
    );
    expect(await download(), 4);
    expect(File(path).readAsBytesSync(), [8, 7, 6, 5]);
  });
  for (final mismatch in ['range', 'etag', 'total']) {
    test('错误206的 $mismatch 不得拼接到磁盘', () async {
      final adapter = _Adapter((o, n) async {
        if (n == 1) return _body([1, 2], length: 4, broken: true);
        if (n == 2) {
          return _body(
            [9, 9],
            status: 206,
            tag: mismatch == 'etag' ? '"v2"' : '"v1"',
            range: mismatch == 'range'
                ? 'bytes 1-2/4'
                : mismatch == 'total'
                    ? 'bytes 2-3/5'
                    : 'bytes 2-3/4',
          );
        }
        return _body([1, 2, 3, 4]);
      });
      dio.httpClientAdapter = adapter;
      expect(await download(), 4);
      expect(adapter.calls.last.headers.containsKey('Range'), isFalse);
      expect(File(path).readAsBytesSync(), [1, 2, 3, 4]);
    });
  }
  test('服务端416会重新取整文件，不能保留无效偏移', () async {
    dio.httpClientAdapter = _Adapter(
      (o, n) async => n == 1
          ? _body([1, 2], length: 4, broken: true)
          : n == 2
              ? _body([], status: 416)
              : _body([7, 8]),
    );
    expect(await download(), 2);
    expect(File(path).readAsBytesSync(), [7, 8]);
  });
  test('HTTP404立即失败，不自动重试，并清理半成品', () async {
    final adapter = _Adapter((o, n) async => _body([], status: 404));
    dio.httpClientAdapter = adapter;
    await expectLater(download(), throwsA(isA<DioException>()));
    expect(adapter.calls, hasLength(1));
    expect(File(path).existsSync(), isFalse);
  });
  test('多次断开超过上限后删除半成品', () async {
    final adapter = _Adapter(
      (o, n) async => _body([1], length: 4, tag: null, broken: true),
    );
    dio.httpClientAdapter = adapter;
    await expectLater(download(), throwsA(anything));
    expect(adapter.calls, hasLength(3));
    expect(File(path).existsSync(), isFalse);
  });
  test('没有新字节的停滞会超时重试并续传', () async {
    final adapter = _Adapter((o, n) async {
      if (n > 1) return _body([3, 4], status: 206, range: 'bytes 2-3/4');
      Stream<Uint8List> stalled() async* {
        yield Uint8List.fromList([1, 2]);
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }

      return ResponseBody(
        stalled(),
        200,
        headers: {
          'content-length': ['4'],
          'etag': ['"v1"'],
        },
      );
    });
    dio.httpClientAdapter = adapter;
    expect(
      await resumableDownload(
        dio,
        '/raw',
        path,
        stallTimeout: const Duration(milliseconds: 30),
        retryDelay: (_) => Duration.zero,
      ),
      4,
    );
    expect(adapter.calls, hasLength(2));
  });
  test('退避期间可取消，取消不重试且删除半成品', () async {
    var cancel = false;
    final adapter = _Adapter(
      (o, n) async => _body([1], length: 4, broken: true),
    );
    dio.httpClientAdapter = adapter;
    final timer = Timer(const Duration(milliseconds: 80), () => cancel = true);
    await expectLater(
      resumableDownload(
        dio,
        '/raw',
        path,
        isCancelled: () => cancel,
        retryDelay: (_) => const Duration(seconds: 10),
      ),
      throwsA(anything),
    );
    timer.cancel();
    expect(adapter.calls, hasLength(1));
    expect(File(path).existsSync(), isFalse);
  });
  test('等待响应头时取消，不等大文件超时且不继续重试', () async {
    var cancel = false;
    final pending = Completer<ResponseBody>();
    final adapter = _Adapter((o, n) => pending.future);
    dio.httpClientAdapter = adapter;
    final started = Stopwatch()..start();
    final future = download(cancel: () => cancel);
    Timer(const Duration(milliseconds: 30), () => cancel = true);
    await expectLater(future.timeout(const Duration(seconds: 2)),
        throwsA(isNot(isA<TimeoutException>())));
    pending.complete(_body([]));
    expect(adapter.calls, hasLength(1));
    expect(started.elapsed, lessThan(const Duration(seconds: 2)));
    expect(File(path).existsSync(), isFalse);
  });
  test('响应流无新字节时取消，及时清理半成品', () async {
    var cancel = false;
    final stream = StreamController<Uint8List>();
    dio.httpClientAdapter =
        _Adapter((o, n) async => ResponseBody(stream.stream, 200));
    final future = download(cancel: () => cancel);
    Timer(const Duration(milliseconds: 30), () => cancel = true);
    await expectLater(future.timeout(const Duration(seconds: 2)),
        throwsA(isNot(isA<TimeoutException>())));
    await stream.close();
    expect(File(path).existsSync(), isFalse);
  });
  test('退避有上限且错峰，HTTP取消/权限错误不会被判为网络故障', () {
    for (var i = 0; i < 8; i++) {
      expect(networkRetryDelay(i).inMilliseconds, lessThanOrEqualTo(12700));
    }
    expect({
      for (var i = 0; i < 20; i++) networkRetryDelay(0),
    }, hasLength(greaterThan(1)));
    final request = RequestOptions(path: '/raw');
    expect(
      transientNet(
        DioException(requestOptions: request, type: DioExceptionType.cancel),
      ),
      isFalse,
    );
    expect(
      transientNet(
        DioException(
          requestOptions: request,
          type: DioExceptionType.badResponse,
          response: Response(requestOptions: request, statusCode: 401),
        ),
      ),
      isFalse,
    );
  });
}
