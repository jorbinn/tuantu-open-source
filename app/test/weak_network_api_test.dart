import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/api.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final ResponseBody Function(RequestOptions, int) respond;
  final paths = <String>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    return respond(options, paths.length);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object data, int status) => ResponseBody.fromString(
  jsonEncode(data),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

void main() {
  test('报告429会等待重试，成功后返回数据', () async {
    final adapter = _Adapter(
      (o, n) => n == 1
          ? _json({'detail': 'busy'}, 429)
          : _json({
              'days': [],
              'identity': {'person_id': 1},
            }, 200),
    );
    Api.I.configure('http://story.test', 'token');
    Api.I.dio.httpClientAdapter = adapter;
    final response = await Api.I.storyDays(offset: 480);
    expect(response['identity']['person_id'], 1);
    expect(adapter.paths, hasLength(2));
  });
  test('报告预览503恢复后取得高清内容，不请求thumb', () async {
    final adapter = _Adapter(
      (o, n) => n == 1
          ? _json({'detail': 'busy'}, 503)
          : ResponseBody.fromBytes([1, 2, 3], 200),
    );
    Api.I.configure('http://story.test', 'token');
    Api.I.dio.httpClientAdapter = adapter;
    expect(await Api.I.reportPreviewBytes(1, CancelToken()), [1, 2, 3]);
    expect(adapter.paths, [
      '/api/asset/1/report-preview',
      '/api/asset/1/report-preview',
    ]);
  });
  test('报告忙碌等待时退出，立即取消且不补发', () async {
    final adapter = _Adapter((o, n) => _json({'detail': 'busy'}, 429));
    Api.I.configure('http://story.test', 'token');
    Api.I.dio.httpClientAdapter = adapter;
    final cancel = CancelToken();
    final request = Api.I.storyDays(offset: 480, cancelToken: cancel);
    Timer(const Duration(milliseconds: 80), cancel.cancel);
    await expectLater(request, throwsA(isA<DioException>()));
    expect(adapter.paths, hasLength(1));
  });
  test('已有会话容忍1.8秒响应延迟，鉴权失败不重试', () async {
    final override = HttpOverrides.current;
    HttpOverrides.global = null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var statusHits = 0;
    var meHits = 0;
    var authorized = true;
    server.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path == '/api/status') {
        statusHits++;
        await Future<void>.delayed(const Duration(milliseconds: 1800));
        req.response.write(jsonEncode({'service': 'tuantu', 'protocol': 1}));
      } else {
        meHits++;
        req.response.statusCode = authorized ? 200 : 401;
        req.response.write(
          jsonEncode(authorized ? {'id': 1} : {'detail': 'unauthorized'}),
        );
      }
      await req.response.close();
    });
    try {
      final base = 'http://127.0.0.1:${server.port}';
      expect(await Api.sessionValid(base, 'token'), isTrue);
      authorized = false;
      expect(await Api.sessionValid(base, 'token'), isFalse);
      expect(statusHits, 2);
      expect(meHits, 2);
    } finally {
      await server.close(force: true);
      HttpOverrides.global = override;
    }
  });
}
