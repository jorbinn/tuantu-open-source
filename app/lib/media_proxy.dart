/// 视频播放地址：明文 HTTP 直连盒子（Range 边下边播）；HTTPS 自签才走本机中转。
library;

import 'dart:io';

import 'api.dart';

class MediaProxy {
  MediaProxy._();
  static final MediaProxy I = MediaProxy._();

  HttpServer? _server;
  int? port;

  Future<void> ensure() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = _server!.port;
    _server!.listen(_handle);
  }

  String rawUrl(int assetId) => 'http://127.0.0.1:$port/raw/$assetId';

  static String playUrl(int assetId) {
    final b = Api.I.base;
    if (b.startsWith('http://')) return '$b/api/asset/$assetId/raw';
    return I.rawUrl(assetId);
  }

  static String livePlayUrl(int assetId) {
    final b = Api.I.base;
    if (b.startsWith('http://')) return '$b/api/asset/$assetId/live';
    return I.rawUrl(assetId);
  }

  static Map<String, String> playHeaders() => {
        if (Api.I.token != null && Api.I.token!.isNotEmpty) 'X-Token': Api.I.token!,
      };

  Future<void> _handle(HttpRequest req) async {
    HttpClient? client;
    try {
      final segs = req.uri.pathSegments;
      if (segs.length != 2 || segs[0] != 'raw') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final id = int.parse(segs[1]);
      final range = req.headers.value(HttpHeaders.rangeHeader);
      client = HttpClient()
        ..idleTimeout = const Duration(seconds: 60)
        ..connectionTimeout = const Duration(seconds: 8)
        ..badCertificateCallback = (cert, host, port) => true;
      final up = await client.getUrl(Uri.parse('${Api.I.base}/api/asset/$id/raw'));
      if (Api.I.token != null) up.headers.set('X-Token', Api.I.token!);
      if (range != null) up.headers.set(HttpHeaders.rangeHeader, range);
      final down = await up.close();
      req.response.statusCode = down.statusCode;
      down.headers.forEach((name, values) {
        if (name.toLowerCase() == 'transfer-encoding') return;
        req.response.headers.set(name, values);
      });
      req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      await req.response.addStream(down);
      await req.response.close();
    } catch (_) {
      try {
        req.response.statusCode = 502;
        await req.response.close();
      } catch (_) {}
    } finally {
      client?.close(force: true);
    }
  }
}
