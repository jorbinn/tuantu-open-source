/// 信息流原图：可取消的 HTTP 下载 + 在途上限，避免滑走后继续占带宽。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// 同时只允许一张原图在下。预加载页和快速滑过的页根本不该进这里。
class RawImageGate {
  RawImageGate._();

  static int maxInFlight = 1;
  static const maxCache = 2;
  static const maxCachedBytes = 4 * 1024 * 1024;

  static final _inflight = <String>{};
  // ignore: prefer_collection_literals
  static final cache = LinkedHashMap<String, Uint8List>();

  static int get inFlightCount => _inflight.length;

  static Uint8List? cached(String url) => cache[url];

  static void remember(String url, Uint8List bytes) {
    if (bytes.lengthInBytes > maxCachedBytes) return;
    cache.remove(url);
    cache[url] = bytes;
    while (cache.length > maxCache) {
      cache.remove(cache.keys.first);
    }
  }

  static bool tryAcquire(String url) {
    if (_inflight.contains(url)) return true;
    if (_inflight.length >= maxInFlight) return false;
    _inflight.add(url);
    return true;
  }

  static void release(String url) => _inflight.remove(url);

  @visibleForTesting
  static void reset() {
    _inflight.clear();
    cache.clear();
  }
}

/// 可中止的 GET。dispose / 换 URL / 滑走时 close(force) 掉在途请求。
class CancellableHttpGet {
  CancellableHttpGet({HttpClient Function()? clientFactory})
      : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;
  HttpClient? _client;
  int gen = 0;

  Future<Uint8List?> get(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    final ticket = ++gen;
    _closeClient();
    if (!RawImageGate.tryAcquire(url)) return null;
    final client = _clientFactory();
    _client = client;
    try {
      final req = await client.getUrl(Uri.parse(url));
      if (ticket != gen) return null;
      headers.forEach(req.headers.set);
      final resp = await req.close();
      if (ticket != gen) return null;
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('HTTP ${resp.statusCode}', uri: Uri.parse(url));
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp) {
        if (ticket != gen) return null;
        builder.add(chunk);
      }
      if (ticket != gen) return null;
      final bytes = Uint8List.fromList(builder.takeBytes());
      RawImageGate.remember(url, bytes);
      return bytes;
    } catch (_) {
      if (ticket != gen) return null;
      rethrow;
    } finally {
      RawImageGate.release(url);
      if (identical(_client, client)) _closeClient();
    }
  }

  void cancel() {
    gen++;
    _closeClient();
  }

  void _closeClient() {
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = null;
  }
}
