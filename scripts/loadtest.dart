/// 模拟多台手机同时连盒子：刷信息流、下缩略图/原片、上传。
/// 用法：dart run scripts/loadtest.dart [http://127.0.0.1:8000] [clients=50] [seconds=25]
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

void main(List<String> args) async {
  final base = args.isNotEmpty ? args[0] : 'http://127.0.0.1:8000';
  final clients = args.length > 1 ? int.parse(args[1]) : 50;
  final seconds = args.length > 2 ? int.parse(args[2]) : 25;
  stdout.writeln('压测 $clients 路 × ${seconds}s  →  $base');

  final jpeg = _tinyJpeg();
  final stats = _Stats();
  final stopAt = DateTime.now().add(Duration(seconds: seconds));
  final workers = <Future<void>>[];
  for (var i = 0; i < clients; i++) {
    workers.add(_client('$base', '压测$i', jpeg, stopAt, stats, i));
  }
  await Future.wait(workers);
  stats.dump();
}

Future<void> _client(String base, String name, Uint8List jpeg,
    DateTime stopAt, _Stats stats, int seed) async {
  final rng = Random(seed);
  final http = HttpClient()
    ..idleTimeout = const Duration(seconds: 8)
    ..maxConnectionsPerHost = 8
    ..connectionTimeout = const Duration(seconds: 4);
  try {
    final token = await _join(http, base, name, stats);
    if (token == null) return;
    var ids = <int>[];
    while (DateTime.now().isBefore(stopAt)) {
      final roll = rng.nextInt(100);
      if (roll < 45) {
        ids = await _gallery(http, base, token, stats) ?? ids;
      } else if (roll < 75) {
        if (ids.isEmpty) {
          ids = await _gallery(http, base, token, stats) ?? ids;
        }
        if (ids.isNotEmpty) {
          await _get(http, '$base/api/asset/${ids[rng.nextInt(ids.length)]}/thumb',
              stats, 'thumb', token: token);
        }
      } else if (roll < 90) {
        if (ids.isEmpty) {
          ids = await _gallery(http, base, token, stats) ?? ids;
        }
        if (ids.isNotEmpty) {
          await _get(http, '$base/api/asset/${ids[rng.nextInt(ids.length)]}/raw',
              stats, 'raw', token: token);
        }
      } else {
        await _upload(http, base, token, jpeg, stats);
      }
    }
  } finally {
    http.close(force: true);
  }
}

Future<String?> _join(
    HttpClient http, String base, String name, _Stats stats) async {
  final t0 = DateTime.now();
  try {
    final req = await http.postUrl(Uri.parse('$base/api/join'));
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode({'name': name, 'code': ''})));
    final res = await req.close().timeout(const Duration(seconds: 6));
    final body = await utf8.decoder.bind(res).join();
    stats.hit('join', DateTime.now().difference(t0), res.statusCode);
    if (res.statusCode != 200) return null;
    final d = jsonDecode(body);
    return d is Map ? d['token']?.toString() : null;
  } catch (e) {
    stats.hit('join', DateTime.now().difference(t0), 0, err: true);
    return null;
  }
}

Future<List<int>?> _gallery(
    HttpClient http, String base, String token, _Stats stats) async {
  final t0 = DateTime.now();
  try {
    final req = await http.getUrl(Uri.parse('$base/api/gallery?view=all&limit=20&sort=upload'));
    req.headers.set('X-Token', token);
    final res = await req.close().timeout(const Duration(seconds: 8));
    final body = await utf8.decoder.bind(res).join();
    stats.hit('gallery', DateTime.now().difference(t0), res.statusCode);
    if (res.statusCode != 200) return null;
    final d = jsonDecode(body);
    final items = d is Map ? d['items'] as List? : null;
    return [
      for (final e in items ?? const [])
        if (e is Map && e['id'] is num) (e['id'] as num).toInt()
    ];
  } catch (_) {
    stats.hit('gallery', DateTime.now().difference(t0), 0, err: true);
    return null;
  }
}

Future<void> _get(HttpClient http, String url, _Stats stats, String op,
    {String? token}) async {
  final t0 = DateTime.now();
  try {
    final req = await http.getUrl(Uri.parse(url));
    if (token != null) req.headers.set('X-Token', token);
    final res = await req.close().timeout(const Duration(seconds: 12));
    await res.drain<void>();
    stats.hit(op, DateTime.now().difference(t0), res.statusCode,
        bytes: res.contentLength);
  } catch (_) {
    stats.hit(op, DateTime.now().difference(t0), 0, err: true);
  }
}

Future<void> _upload(HttpClient http, String base, String token,
    Uint8List jpeg, _Stats stats) async {
  final t0 = DateTime.now();
  try {
    final boundary = 'lt${DateTime.now().microsecondsSinceEpoch}';
    final req = await http.postUrl(Uri.parse('$base/api/upload'));
    req.headers.set('X-Token', token);
    req.headers.contentType =
        ContentType('multipart', 'form-data', parameters: {'boundary': boundary});
    final head =
        utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="files"; filename="lt.jpg"\r\nContent-Type: image/jpeg\r\n\r\n');
    final tail = utf8.encode('\r\n--$boundary--\r\n');
    req.add(head);
    req.add(jpeg);
    req.add(tail);
    final res = await req.close().timeout(const Duration(seconds: 15));
    await res.drain<void>();
    stats.hit('upload', DateTime.now().difference(t0), res.statusCode);
  } catch (_) {
    stats.hit('upload', DateTime.now().difference(t0), 0, err: true);
  }
}

class _Stats {
  final _ops = <String, List<int>>{};
  final _err = <String, int>{};
  final _ok = <String, int>{};
  int _n = 0;

  void hit(String op, Duration d, int status, {bool err = false, int bytes = 0}) {
    _n++;
    (_ops[op] ??= []).add(d.inMilliseconds);
    if (err || status >= 400 || status == 0) {
      _err[op] = (_err[op] ?? 0) + 1;
    } else {
      _ok[op] = (_ok[op] ?? 0) + 1;
    }
  }

  void dump() {
    stdout.writeln('\n===== 压测结果  总请求 $_n =====');
    stdout.writeln('操作'.padRight(10) +
        '成功'.padLeft(8) +
        '失败'.padLeft(8) +
        'p50ms'.padLeft(8) +
        'p95ms'.padLeft(8) +
        'max'.padLeft(8));
    for (final op in _ops.keys.toList()..sort()) {
      final ms = _ops[op]!..sort();
      int pct(int p) => ms[(ms.length * p / 100).floor().clamp(0, ms.length - 1)];
      stdout.writeln(op.padRight(10) +
          '${_ok[op] ?? 0}'.padLeft(8) +
          '${_err[op] ?? 0}'.padLeft(8) +
          '${pct(50)}'.padLeft(8) +
          '${pct(95)}'.padLeft(8) +
          '${ms.last}'.padLeft(8));
    }
  }
}

Uint8List _tinyJpeg() {
  // 最小合法 JPEG（1×1）
  return Uint8List.fromList([
    0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
    0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
    0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
    0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
    0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
    0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
    0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
    0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
    0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x14, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x09, 0xFF, 0xC4, 0x00, 0x14, 0x10, 0x01, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
    0x7F, 0xFF, 0xD9,
  ]);
}
