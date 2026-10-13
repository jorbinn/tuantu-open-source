import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:tuantu_app/widgets/box_image.dart';

void main() {
  Widget page({bool active = true, int epoch = 0}) => MaterialApp(
    home: TickerMode(
      enabled: active,
      child: BoxImage('http://box/api/person/1/cover', retryEpoch: epoch),
    ),
  );

  Image picture(WidgetTester tester) =>
      tester.widget<Image>(find.byType(Image));
  void failImage(WidgetTester tester) {
    picture(tester).errorBuilder!(
      tester.element(find.byType(Image)),
      StateError('hotspot temporarily busy'),
      StackTrace.current,
    );
  }

  testWidgets(
    'failed avatars keep retrying beyond the old three-attempt limit',
    (tester) async {
      await tester.pumpWidget(page());
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        failImage(tester);
        final previous = picture(tester).key;
        await tester.pump(const Duration(seconds: 31));
        expect(picture(tester).key, isNot(previous));
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hidden pages and background apps pause retries; returning resumes',
    (tester) async {
      await tester.pumpWidget(page());
      await tester.pump();
      failImage(tester);
      await tester.pumpWidget(page(active: false));
      final hidden = picture(tester).key;
      await tester.pump(const Duration(minutes: 2));
      expect(picture(tester).key, hidden);
      await tester.pumpWidget(page());
      await tester.pump(const Duration(seconds: 31));
      expect(picture(tester).key, isNot(hidden));
      failImage(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final paused = picture(tester).key;
      await tester.pump(const Duration(minutes: 2));
      expect(picture(tester).key, paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 31));
      expect(picture(tester).key, isNot(paused));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'refresh retries failures, while success cancels timers and keeps cache key',
    (tester) async {
      final client = _ImageClient();
      debugNetworkImageHttpClientProvider = () => client;
      addTearDown(() {
        debugNetworkImageHttpClientProvider = null;
        PaintingBinding.instance.imageCache.clear();
      });
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      final failed = picture(tester).key;
      client.healthy = true;
      await tester.pumpWidget(page(epoch: 1));
      expect(picture(tester).key, isNot(failed));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      final loaded = picture(tester).key;
      final requests = client.requests;
      await tester.pumpWidget(page(epoch: 2));
      await tester.pump(const Duration(minutes: 2));
      expect(picture(tester).key, loaded);
      expect(
        client.requests,
        requests,
        reason: 'successful image must stop retrying',
      );
      await tester.pumpWidget(const SizedBox());
      debugNetworkImageHttpClientProvider = null;
    },
  );
}

class _ImageClient implements HttpClient {
  bool healthy = false;
  int requests = 0;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests++;
    return _ImageRequest(healthy);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageRequest implements HttpClientRequest {
  _ImageRequest(this.healthy);
  final bool healthy;
  @override
  HttpHeaders get headers => _Headers();
  @override
  Future<HttpClientResponse> close() async => _ImageResponse(healthy);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageResponse extends Stream<List<int>> implements HttpClientResponse {
  _ImageResponse(this.healthy);
  final bool healthy;
  final bytes = im.encodePng(im.Image(width: 4, height: 4));
  @override
  int get statusCode => healthy ? 200 : 503;
  @override
  int get contentLength => healthy ? bytes.length : 0;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      (healthy ? Stream.value(bytes) : const Stream<List<int>>.empty()).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
