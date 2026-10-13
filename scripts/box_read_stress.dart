/// Read-only production smoke test: no joins, uploads, deletions or raw files.
/// dart scripts/box_read_stress.dart BASE CLIENTS SECONDS PERSON_IDS_CSV
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length != 4) {
    stderr.writeln('Usage: BASE CLIENTS SECONDS PERSON_IDS_CSV');
    exitCode = 64;
    return;
  }
  final base = Uri.parse(args[0]);
  final clients = int.parse(args[1]);
  final seconds = int.parse(args[2]);
  final ids = args[3].split(',').map(int.parse).toList();
  if (clients < 1 ||
      clients > 50 ||
      seconds < 1 ||
      seconds > 300 ||
      ids.isEmpty) {
    throw ArgumentError('Use 1..50 clients and 1..300 seconds');
  }
  final timings = <String, List<int>>{'status': [], 'cover': []};
  final errors = <String, int>{};
  final elapsed = Stopwatch()..start();
  await Future.wait([
    for (var n = 0; n < clients; n++)
      () async {
        final http = HttpClient()
          ..connectionTimeout = const Duration(seconds: 3);
        var turn = n;
        try {
          while (elapsed.elapsed.inSeconds < seconds) {
            final kind = turn % 4 == 0 ? 'status' : 'cover';
            final path = kind == 'status'
                ? '/api/status'
                : '/api/person/${ids[turn % ids.length]}/cover';
            final watch = Stopwatch()..start();
            try {
              final req = await http
                  .getUrl(base.resolve(path))
                  .timeout(const Duration(seconds: 3));
              final response = await req.close().timeout(
                const Duration(seconds: 3),
              );
              final bytes = await response
                  .fold<List<int>>([], (out, chunk) => out..addAll(chunk))
                  .timeout(const Duration(seconds: 3));
              if (response.statusCode != 200)
                throw HttpException('HTTP ${response.statusCode}');
              if (kind == 'status') {
                if ((jsonDecode(utf8.decode(bytes)) as Map)['service'] !=
                    'tuantu') {
                  throw const FormatException('not a tuantu status');
                }
              } else if (bytes.length < 40 ||
                  bytes[0] != 0xff ||
                  bytes[1] != 0xd8) {
                throw const FormatException('not a JPEG cover');
              }
              timings[kind]!.add(watch.elapsedMilliseconds);
            } catch (e) {
              final key = '$kind: $e';
              errors[key] = (errors[key] ?? 0) + 1;
            }
            turn++;
            // Bounded test traffic, still substantially more than seven people tapping.
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
        } finally {
          http.close(force: true);
        }
      }(),
  ]);
  final output = <String, Object>{
    'clients': clients,
    'elapsed_ms': elapsed.elapsedMilliseconds,
    'errors': errors,
  };
  for (final entry in timings.entries) {
    final values = entry.value..sort();
    output[entry.key] = {
      'ok': values.length,
      if (values.isNotEmpty) ...{
        'p50_ms':
            values[(values.length * .50).floor().clamp(0, values.length - 1)],
        'p95_ms':
            values[(values.length * .95).floor().clamp(0, values.length - 1)],
        'max_ms': values.last,
      },
    };
  }
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(output));
  if (errors.isNotEmpty) exitCode = 1;
}
