import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/pages/me_page.dart';
import 'package:tuantu_app/widgets/box_image.dart';

/// 盒子：自己的 [n] 张作品，全部有缩略图，按 offset 分页。
class _Box implements HttpClientAdapter {
  _Box(int n) : ids = [for (var i = n; i >= 1; i--) i];
  final List<int> ids;
  int listLoads = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
      RequestOptions o, Stream<Uint8List>? s, Future<void>? c) async {
    Object data;
    if (o.path == '/api/me') {
      data = {'id': 1, 'name': '我', 'uploaded': ids.length};
    } else if (o.path == '/api/me/assets') {
      listLoads++;
      final off = int.parse('${o.queryParameters['offset']}');
      final page = ids.skip(off).take(90).toList();
      data = {
        'items': [
          for (final id in page)
            {
              'id': id,
              'thumb': '/api/asset/$id/thumb',
              'has_thumb': 1,
              'kind': 'image',
              'ext': 'jpg',
              'taken_at': 1770000000 - id * 60,
              'uploader': '我',
              'mine': true,
              'width': 100,
              'height': 100,
            }
        ],
        'offset': off + page.length,
        'end': off + page.length >= ids.length,
      };
    } else {
      data = {};
    }
    return ResponseBody.fromString(jsonEncode(data), 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }
}

/// Thumbnail server: 503 (or [failStatus]) while unhealthy.
class _ImageClient implements HttpClient {
  bool healthy = false;
  int failStatus = 503;
  final Set<String> alwaysFail = {};
  final requests = <String>[];

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests.add(url.toString());
    final ok = healthy && !alwaysFail.contains(url.toString());
    return _Req(ok ? 200 : failStatus);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Req implements HttpClientRequest {
  _Req(this.status);
  final int status;
  @override
  HttpHeaders get headers => _H();
  @override
  Future<HttpClientResponse> close() async => _Resp(status);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _H implements HttpHeaders {
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

final _png = im.encodePng(im.Image(width: 4, height: 4));

class _Resp extends Stream<List<int>> implements HttpClientResponse {
  _Resp(this.statusCode);
  @override
  final int statusCode;
  bool get _ok => statusCode == 200;
  @override
  int get contentLength => _ok ? _png.length : 0;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? d,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      (_ok ? Stream.value(_png) : const Stream<List<int>>.empty()).listen(d,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late _ImageClient client;

  setUp(() {
    Api.listAttempts = 1;
    Api.I.configure('http://box.test:8000', 'token');
    BoxImageRevival.debugReset();
    client = _ImageClient();
    debugNetworkImageHttpClientProvider = () => client;
  });

  tearDown(() {
    debugNetworkImageHttpClientProvider = null;
    PaintingBinding.instance.imageCache.clear();
    BoxImageRevival.debugReset();
  });

  /// Real IO (image decode) interleaved with fake-time frames.
  Future<void> io(WidgetTester t) async {
    for (var i = 0; i < 4; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
  }

  /// Advance fake time in small steps, letting image IO run in between.
  Future<void> advance(WidgetTester t, Duration d) async {
    const step = Duration(milliseconds: 250);
    for (var e = Duration.zero; e < d; e += step) {
      await t.pump(step);
      await io(t);
    }
  }

  int loadedTiles(WidgetTester t) => t
      .widgetList<RawImage>(find.byType(RawImage).hitTestable())
      .where((r) => r.image != null)
      .length;

  int visibleTiles(WidgetTester t) =>
      find.byType(BoxImage).hitTestable().evaluate().length;

  Future<void> done(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(minutes: 1));
    debugNetworkImageHttpClientProvider = null;
  }

  testWidgets('503 outage then recovery: gray tiles fill in within ~2 s, '
      'without leaving the page', (tester) async {
    Api.I.dio.httpClientAdapter = _Box(120);
    await tester.pumpWidget(const MaterialApp(home: MePage()));
    await advance(tester, const Duration(seconds: 1));
    final visible = visibleTiles(tester);
    expect(visible, greaterThan(5));
    // Box overloaded for 40 s: every thumbnail 503s.
    await advance(tester, const Duration(seconds: 40));
    expect(loadedTiles(tester), 0);

    client.healthy = true;
    await advance(tester, const Duration(seconds: 2));
    expect(loadedTiles(tester), visible,
        reason: 'all visible tiles must recover within ~2 s of the box');
    await done(tester);
  });

  testWidgets('grid tiles back off at most ~5 s while the box is down',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: BoxImage('http://box.test:8000/api/asset/1/thumb',
          maxRetryDelay: BoxImage.gridRetryDelay),
    ));
    await advance(tester, const Duration(seconds: 30));
    final before = client.requests.length;
    await advance(tester, const Duration(seconds: 30));
    final perMinuteHalf = client.requests.length - before;
    // 30 s at a 5–5.7 s cadence: 5–6 attempts (the old cap allowed 1).
    expect(perMinuteHalf, inInclusiveRange(5, 7));
    await done(tester);
  });

  testWidgets('pull-to-refresh (successful list load) retries gray tiles now',
      (tester) async {
    final box = _Box(60);
    Api.I.dio.httpClientAdapter = box;
    await tester.pumpWidget(const MaterialApp(home: MePage()));
    await advance(tester, const Duration(seconds: 20));
    final visible = visibleTiles(tester);
    expect(loadedTiles(tester), 0);
    client.healthy = true;
    // Refresh right after recovery, before any backoff timer can fire.
    final state = tester.state<MePageState>(find.byType(MePage));
    final loads = box.listLoads;
    final refresh = state.load();
    await advance(tester, const Duration(milliseconds: 500));
    await refresh;
    expect(box.listLoads, loads + 1);
    expect(loadedTiles(tester), visible);
    await done(tester);
  });

  testWidgets('tap a gray tile retries it immediately; long-press still '
      'reaches the cell', (tester) async {
    var longPresses = 0;
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 120,
          height: 120,
          child: GestureDetector(
            onTap: () => taps++,
            onLongPress: () => longPresses++,
            child: const BoxImage('http://box.test:8000/api/asset/7/thumb',
                maxRetryDelay: BoxImage.gridRetryDelay, retryOnTap: true),
          ),
        ),
      ),
    ));
    await io(tester);
    expect(client.requests, hasLength(1));
    expect(find.byIcon(Icons.refresh), findsOneWidget);

    client.healthy = true;
    await tester.tap(find.byType(BoxImage));
    await io(tester);
    expect(client.requests, hasLength(2), reason: 'tap = immediate retry');
    expect(taps, 0, reason: 'tap on a failed tile must not open the viewer');
    expect(loadedTiles(tester), 1);

    // Loaded tile: taps go to the cell again.
    await tester.tap(find.byType(BoxImage));
    await tester.pump(const Duration(milliseconds: 500));
    expect(taps, 1);

    // Failed tile: long-press still reaches the cell (delete / multi-select).
    PaintingBinding.instance.imageCache.clear();
    client.healthy = false;
    await tester.pumpWidget(MaterialApp(
      home: GestureDetector(
        onTap: () => taps++,
        onLongPress: () => longPresses++,
        child: const BoxImage('http://box.test:8000/api/asset/8/thumb',
            retryOnTap: true),
      ),
    ));
    await io(tester);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    await tester.longPress(find.byType(BoxImage));
    await tester.pump(const Duration(milliseconds: 500));
    expect(longPresses, 1);
    expect(taps, 1);
    await done(tester);
  });

  testWidgets('revival waves are rate-limited and never loop on tiles that '
      'keep failing', (tester) async {
    final urls = [
      for (var i = 1; i <= 12; i++) 'http://box.test:8000/api/asset/$i/thumb'
    ];
    await tester.pumpWidget(MaterialApp(
      home: GridView.count(crossAxisCount: 4, children: [
        for (final u in urls)
          BoxImage(u, maxRetryDelay: BoxImage.gridRetryDelay),
      ]),
    ));
    await advance(tester, const Duration(seconds: 30));
    expect(BoxImageRevival.failedTiles, 12);

    // Box comes back for all but two tiles, which keep failing (e.g. broken).
    client.healthy = true;
    client.alwaysFail.addAll(urls.take(2));
    final wave0 = BoxImageRevival.wave.value;
    // A burst of success signals collapses into one wave now + at most one
    // trailing wave per cooldown.
    for (var i = 0; i < 20; i++) {
      BoxImageRevival.bump();
    }
    expect(BoxImageRevival.wave.value, wave0 + 1);
    await advance(tester, const Duration(seconds: 2));
    expect(loadedTiles(tester), 10);
    expect(BoxImageRevival.wave.value - wave0, lessThanOrEqualTo(3));

    // Nothing succeeds any more: no further waves, the two broken tiles are
    // back on their normal (≤5 s) backoff, not hammering the box.
    final waves = BoxImageRevival.wave.value;
    final before = client.requests.length;
    await advance(tester, const Duration(seconds: 20));
    expect(BoxImageRevival.wave.value, waves);
    expect(client.requests.length - before, lessThanOrEqualTo(2 * 6));
    expect(BoxImageRevival.failedTiles, 2);
    await done(tester);
    expect(BoxImageRevival.failedTiles, 0);
  });

  testWidgets('404 (thumbnail not generated yet) is not revived by waves',
      (tester) async {
    client.failStatus = 404;
    await tester.pumpWidget(const MaterialApp(
      home: BoxImage('http://box.test:8000/api/asset/9/thumb',
          maxRetryDelay: BoxImage.gridRetryDelay),
    ));
    await io(tester);
    final before = client.requests.length;
    BoxImageRevival.bump();
    await advance(tester, const Duration(milliseconds: 400));
    expect(client.requests.length, before);
    await done(tester);
  });
}
