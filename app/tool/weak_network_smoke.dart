// Explicit opt-in device test. Uses existing, named test identities only.
// dart run tool/weak_network_smoke.dart BASE STATE_JSON FIXTURE_JPEG OUTPUT_DIR
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:image/image.dart' as im;
import 'package:tuantu_app/resumable_download.dart';

Future<void> main(List<String> args) async {
  if (args.length != 4) {
    throw ArgumentError('BASE STATE_JSON FIXTURE_JPEG OUTPUT_DIR');
  }
  final target = Uri.parse(args[0]);
  if (target.host != '127.0.0.1') {
    throw ArgumentError('Use the explicitly established device relay');
  }
  final state = jsonDecode(await File(args[1]).readAsString()) as Map;
  final users = List<Map>.from(state['users'] as List).take(30).toList();
  if (users.length != 30) {
    throw StateError('Expected 30 existing test identities');
  }
  final output = Directory(args[3]);
  await output.create(recursive: true);
  if (await File('${output.path}/ledger.json').exists()) {
    throw StateError('Use a fresh output directory; preserve any earlier cleanup ledger');
  }
  final fixture = await File(args[2]).readAsBytes();
  final clients = [
    for (final u in users)
      Dio(
        BaseOptions(
          baseUrl: target.toString(),
          headers: {'X-Token': u['token']},
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 40),
        ),
      ),
  ];
  final ledger = <Map<String, dynamic>>[];
  final results = <String, dynamic>{};
  Future<void> ledgerWrites = Future<void>.value();
  Future<void> persistLedger() => ledgerWrites = ledgerWrites.then(
    (_) =>
        File('${output.path}/ledger.json')
            .writeAsString(jsonEncode(ledger))
            .then((_) {}),
  );
  final failures = <String>[];
  int? testPerson;
  bool claimedTestPerson = false;
  final run = DateTime.now().millisecondsSinceEpoch;
  Future<Set<int>> inventory() async {
    final ids = <int>{};
    final query = <String, dynamic>{
      'view': 'all',
      'sort': 'upload',
      'limit': 90,
    };
    for (var page = 0; page < 10000; page++) {
      final r = await clients.first.get('/api/gallery', queryParameters: query);
      final items = r.data['items'] as List;
      for (final item in items) {
        if (!ids.add(item['id'] as int)) {
          throw StateError('Inventory pagination repeated an asset');
        }
      }
      if (items.isEmpty || r.data['cursor'] == null) return ids;
      query['cursor'] = r.data['cursor'];
      query['cursor_id'] = r.data['cursor_id'];
    }
    throw StateError('Inventory exceeded page bound');
  }

  final before = await inventory();
  results['baseline_count'] = before.length;
  print('Inventory complete: ${before.length} original assets');
  // A mistyped credentials file must not mutate a real user's account.
  for (final c in clients) {
    final me = (await c.get('/api/me')).data as Map;
    if (!me['name'].toString().startsWith('压力测试0922-') ||
        ((me['claimed'] as List?) ?? []).isNotEmpty) {
      throw StateError('Not an unclaimed test identity');
    }
  }
  print('30 test identities validated');
  try {
    final uploadClock = Stopwatch()..start();
    await Future.wait([
      for (var i = 0; i < 30; i++)
        () async {
          final name = 'weak_${run}_$i.jpg';
          final r = await clients[i].post(
            '/api/upload',
            data: FormData.fromMap({
              'files': MultipartFile.fromBytes(fixture, filename: name),
              'meta': jsonEncode({
                name: {'taken_at': 1790035200},
              }),
            }),
          );
          final accepted = r.data['accepted'] as List;
          if (accepted.length != 1) throw StateError('Test upload rejected');
          ledger.add({'id': accepted.single['id'], 'user': i, 'name': name});
          await persistLedger();
        }(),
    ]);
    results['upload_30'] = {
      'accepted': ledger.length,
      'elapsed_ms': uploadClock.elapsedMilliseconds,
    };
    print('30 test uploads complete');
    final owned = ledger.map((e) => e['id'] as int).toSet();
    final coldClock = Stopwatch()..start();
    var fullSize = 0;
    final sizes = <List<int>>[];
    await Future.wait([
      for (final item in ledger)
        () async {
          final r = await clients[item['user'] as int].get<List<int>>(
            '/api/asset/${item['id']}/report-preview',
            options: Options(responseType: ResponseType.bytes),
          );
          final decoded = im.decodeImage(Uint8List.fromList(r.data!));
          if (decoded == null) throw StateError('Not a preview image');
          sizes.add([decoded.width, decoded.height]);
          if (max(decoded.width, decoded.height) >= 1000) fullSize++;
        }(),
    ]);
    results['cold_preview_30'] = {
      'full_size': fullSize,
      'sizes': sizes,
      'elapsed_ms': coldClock.elapsedMilliseconds,
    };
    print('30 cold report previews complete: $fullSize full-sized');

    // Only claim a newly recognized person whose entire gallery is test-owned.
    final recognizeClock = Stopwatch()..start();
    while (testPerson == null &&
        recognizeClock.elapsed < const Duration(seconds: 90)) {
      final persons = (await clients.first.get('/api/persons')).data as List;
      for (final p in persons) {
        if (p['claimed_by'] != null) continue;
        final r = await clients.first.get(
          '/api/gallery',
          queryParameters: {'view': 'person:${p['id']}', 'limit': 200},
        );
        final items = r.data['items'] as List;
        if (items.isNotEmpty &&
            items.length < 200 &&
            items.every((a) => owned.contains(a['id']))) {
          testPerson = p['id'] as int;
          break;
        }
      }
      if (testPerson == null) {
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
    if (testPerson != null) {
      final r = await clients.first.post(
        '/api/persons/$testPerson/claim',
        data: {},
      );
      if (r.data['ok'] != true) {
        throw StateError('Test claim conflicted; do not override');
      }
      claimedTestPerson = true;
      var ok = 0;
      final codes = <int, int>{};
      final times = <int>[];
      for (var wave = 0; wave < 10; wave++) {
        await Future.wait([
          for (var i = 0; i < 30; i++)
            () async {
              final clock = Stopwatch()..start();
              final c = Dio(
                BaseOptions(
                  baseUrl: target.toString(),
                  headers: {'X-Token': users.first['token']},
                  receiveTimeout: const Duration(seconds: 35),
                  validateStatus: (_) => true,
                ),
              );
              try {
                final r = await c.get(
                  '/api/report/story',
                  queryParameters: {'day': '2026-09-22', 'offset': 480},
                );
                codes[r.statusCode!] = (codes[r.statusCode] ?? 0) + 1;
                if (r.statusCode == 200) ok++;
                times.add(clock.elapsedMilliseconds);
              } finally {
                c.close(force: true);
              }
            }(),
        ]);
      }
      times.sort();
      results['story_300_same_test_identity'] = {
        'success': ok,
        'codes': {for (final e in codes.entries) '${e.key}': e.value},
        'p95_ms': times[(times.length * .95).floor()],
        'max_ms': times.last,
      };
      print('Story burst complete: $ok / 300');
    } else {
      results['story_300_same_test_identity'] =
          'SKIPPED: no isolated test person recognized';
      print('Story burst skipped: no isolated test person; real claims untouched');
    }

    // Client-side bandwidth/delay/drop injection, routed through vivo Wi-Fi.
    final aid = ledger.first['id'] as int;
    final hash = sha256.convert(fixture).toString();
    for (final outageSeconds in [5, 30]) {
      final proxy = await _WeakProxy.start(target, outageSeconds);
      final clock = Stopwatch()..start();
      var success = 0;
      final times = <int>[];
      final healthTimes = <int>[];
      var healthStopped = false;
      final health = () async {
        while (!healthStopped) {
          final w = Stopwatch()..start();
          try {
            final r = await clients.first.get('/api/status');
            if (r.data['service'] != 'tuantu') throw StateError('not tuantu');
            healthTimes.add(w.elapsedMilliseconds);
          } catch (e) {
            failures.add('health: ${e.runtimeType}');
          }
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }();
      try {
        await Future.wait([
          for (var i = 0; i < 10; i++)
            () async {
              final c = Dio(
                BaseOptions(
                  baseUrl: proxy.base,
                  connectTimeout: const Duration(seconds: 8),
                ),
              );
              final path = '${output.path}/download_${outageSeconds}_$i.jpg';
              final watch = Stopwatch()..start();
              try {
                await resumableDownload(
                  c,
                  '/api/asset/$aid/raw?weak_client=$i',
                  path,
                );
                final actual = sha256
                    .convert(await File(path).readAsBytes())
                    .toString();
                if (actual != hash) throw StateError('HASH_MISMATCH');
                success++;
                times.add(watch.elapsedMilliseconds);
              } catch (e) {
                failures.add(
                  'outage${outageSeconds}_client$i:${e.runtimeType}',
                );
              } finally {
                c.close(force: true);
              }
            }(),
        ]);
      } finally {
        healthStopped = true;
        await health;
        await proxy.close();
      }
      times.sort();
      results['weak_${outageSeconds}s'] = {
        'clients': 10,
        'success': success,
        'limit_bytes_per_sec_per_client': 131072,
        'header_delay_ms': '300..750',
        'injected_cuts': proxy.cuts,
        'reconnect_refusals': proxy.refusals,
        'range_requests': proxy.ranges,
        'elapsed_ms': clock.elapsedMilliseconds,
        'max_client_ms': times.isEmpty ? null : times.last,
        'status_max_ms': healthTimes.isEmpty ? null : healthTimes.reduce(max),
      };
      print('Weak network ${outageSeconds}s blackout complete: $success / 10');
    }
  } catch (e) {
    failures.add('test: ${e.runtimeType}: $e');
    rethrow;
  } finally {
    if (claimedTestPerson) {
      try {
        await clients.first.post('/api/persons/$testPerson/unclaim');
        await clients.first.post(
          '/api/persons/$testPerson/member',
          data: {'status': 0},
        );
      } catch (e) {
        failures.add('claim cleanup:${e.runtimeType}');
      }
    }
    await ledgerWrites;
    for (final item in ledger) {
      try {
        await clients[item['user'] as int].delete('/api/asset/${item['id']}');
      } catch (e) {
        failures.add('asset cleanup ${item['id']}:${e.runtimeType}');
      }
    }
    final after = await inventory();
    results['cleanup'] = {
      'before': before.length,
      'after': after.length,
      'missing_original_ids': before.difference(after).toList(),
      'remaining_test_ids': ledger
          .map((e) => e['id'])
          .where(after.contains)
          .toList(),
    };
    results['failures'] = failures;
    await File('${output.path}/results.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(results));
    for (final c in clients) {
      c.close(force: true);
    }
    print(jsonEncode(results));
  }
}

class _WeakProxy {
  _WeakProxy(this.target, this.outageSeconds, this.server);
  final Uri target;
  final int outageSeconds;
  final HttpServer server;
  final upstream = HttpClient()..maxConnectionsPerHost = 40;
  final until = <String, DateTime>{};
  int cuts = 0, refusals = 0, ranges = 0;
  String get base => 'http://127.0.0.1:${server.port}';
  static Future<_WeakProxy> start(Uri target, int outage) async {
    final proxy = _WeakProxy(
      target,
      outage,
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    proxy.server.listen(proxy.handle);
    return proxy;
  }

  Future<void> handle(HttpRequest request) async {
    try {
      final id = request.uri.queryParameters['weak_client'] ?? '0';
      final blackout = until[id];
      if (blackout != null && DateTime.now().isBefore(blackout)) {
        refusals++;
        (await request.response.detachSocket(writeHeaders: false)).destroy();
        return;
      }
      await Future<void>.delayed(
        Duration(milliseconds: 300 + (int.parse(id) % 4) * 150),
      );
      final sent = await upstream.getUrl(target.resolveUri(request.uri));
      for (final name in ['range', 'if-range', 'accept-encoding']) {
        final value = request.headers.value(name);
        if (value != null) sent.headers.set(name, value);
      }
      if (request.headers.value('range') != null) ranges++;
      final response = await sent.close();
      request.response.statusCode = response.statusCode;
      for (final name in [
        'content-length',
        'content-range',
        'content-type',
        'etag',
      ]) {
        final value = response.headers.value(name);
        if (value != null) request.response.headers.set(name, value);
      }
      var bytes = 0;
      await for (final chunk in response) {
        for (var at = 0; at < chunk.length; at += 16384) {
          final end = min(at + 16384, chunk.length);
          request.response.add(chunk.sublist(at, end));
          await request.response.flush();
          bytes += end - at;
          if (blackout == null && bytes >= 65536) {
            until[id] = DateTime.now().add(Duration(seconds: outageSeconds));
            cuts++;
            (await request.response.detachSocket(writeHeaders: false))
                .destroy();
            return;
          }
          await Future<void>.delayed(
            Duration(microseconds: (end - at) * 1000000 ~/ 131072),
          );
        }
      }
      await request.response.close();
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    await server.close(force: true);
    upstream.close(force: true);
  }
}
