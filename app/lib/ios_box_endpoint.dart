import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

/// Bonjour 的 hostname 不是可持久依赖的传输地址。直接取系统解析出的 IPv4，
/// 再用 HTTP 核对盒子身份；这里的探测不带任何登录凭据。
class BoxEndpoint {
  const BoxEndpoint(this.base, this.host);
  final String base;
  final String host;
}

class IosBoxEndpoint {
  static final I = IosBoxEndpoint();
  IosBoxEndpoint({
    Future<List<BoxEndpoint>> Function()? discover,
    Future<String?> Function(String)? identify,
    Future<List<String>> Function(String)? fallbackCandidates,
    this.cooldown = const Duration(seconds: 10),
    this.fallbackBudget = const Duration(seconds: 12),
    this.fallbackConcurrency = 8,
  })  : discover = discover ?? _discover,
        identify = identify ?? _identify,
        fallbackCandidates = fallbackCandidates ?? _wifiCandidates,
        _fallbackIdentify = identify ?? _identifyFast;

  final Future<List<BoxEndpoint>> Function() discover;
  final Future<String?> Function(String) identify;
  final Duration cooldown;
  final Duration fallbackBudget;
  final int fallbackConcurrency;
  final Future<List<String>> Function(String) fallbackCandidates;
  final Future<String?> Function(String) _fallbackIdentify;
  int _fallbackCursor = 0;
  final _resolved = <String, String>{};
  final _inflight = <String, Future<String?>>{};
  final _lastAttempt = <String, DateTime>{};

  static String _host(String value) =>
      value.toLowerCase().replaceFirst(RegExp(r'\.$'), '');

  /// 有 boxId 才能跨地址恢复已有身份；首次加入仅接受同一 Bonjour 主机。
  Future<String?> resolve(String base, {String? boxId}) {
    final key = '$base|${boxId ?? ''}';
    final active = _inflight[key];
    if (active != null) return active;
    final last = _lastAttempt[key];
    if (last != null && DateTime.now().difference(last) < cooldown) {
      return Future.value(_resolved[key]);
    }
    _lastAttempt[key] = DateTime.now();
    late Future<String?> request;
    request = _resolve(base, boxId).then((value) {
      if (value != null) {
        _resolved[key] = value;
      } else {
        _resolved.remove(key);
      }
      return value;
    }).whenComplete(() {
      _lastAttempt[key] = DateTime.now();
      if (identical(_inflight[key], request)) _inflight.remove(key);
    });
    _inflight[key] = request;
    return request;
  }

  Future<String?> _resolve(String base, String? boxId) async {
    final uri = Uri.tryParse(base);
    if (uri == null || uri.scheme != 'http') return null;
    final expected = boxId?.trim() ?? '';
    final host = _host(uri.host);
    // 没有盒子身份时，不能把失效的数字 IP 自动迁移到任意其它盒子。
    if (expected.isEmpty && !host.endsWith('.local')) return null;
    try {
      final candidates = await discover();
      for (final candidate in candidates) {
        if (candidate.base == base) continue;
        if (expected.isEmpty && _host(candidate.host) != host) continue;
        String? id;
        try {
          id = await identify(candidate.base);
        } catch (_) {
          continue;
        }
        if (id == null || id.isEmpty) continue;
        if (expected.isNotEmpty && id != expected) continue;
        return candidate.base;
      }
    } catch (_) {
      // Discovery failure must leave the old session intact.
    }
    // Only an already identified box may be recovered by address probing.
    // No tokens are sent to candidates; Api validates the session afterwards.
    if (expected.isNotEmpty) return _fallback(base, expected);
    return null;
  }

  Future<String?> _fallback(String base, String expected) async {
    final watch = Stopwatch()..start();
    List<String> candidates;
    try {
      candidates =
          (await fallbackCandidates(base).timeout(const Duration(seconds: 2)))
              .toSet()
              .toList();
    } catch (_) {
      return null;
    }
    if (candidates.isEmpty) return null;
    // Rotate the remainder between bounded rounds, so hosts late in a /24 are
    // not permanently starved when the hotspot drops packets silently.
    final start = _fallbackCursor % candidates.length;
    var scheduled = 0;
    String? found;
    Future<void> worker() async {
      while (found == null &&
          scheduled < candidates.length &&
          watch.elapsed < fallbackBudget) {
        final candidate = candidates[(start + scheduled++) % candidates.length];
        try {
          final remaining = fallbackBudget - watch.elapsed;
          if (remaining <= Duration.zero) return;
          final id = await _fallbackIdentify(candidate).timeout(
              remaining < const Duration(milliseconds: 900)
                  ? remaining
                  : const Duration(milliseconds: 900));
          if (id == expected) found ??= candidate;
        } catch (_) {/* Continue within this round's budget. */}
      }
    }

    await Future.wait([
      for (var i = 0; i < fallbackConcurrency.clamp(1, 8); i++) worker(),
    ]);
    _fallbackCursor = (start + scheduled) % candidates.length;
    return found;
  }

  static Future<List<String>> _wifiCandidates(String previous) async {
    if (!Platform.isIOS) return [];
    final interfaces = await NetworkInterface.list(
        includeLoopback: false, type: InternetAddressType.IPv4);
    final hosts = <String>{};
    final old = Uri.tryParse(previous);
    for (final itf in interfaces.where((itf) => itf.name == 'en0')) {
      for (final address in itf.addresses) {
        final parts = address.address.split('.');
        if (parts.length != 4 || address.isLoopback || address.isLinkLocal) {
          continue;
        }
        final prefix = parts.take(3).join('.');
        if (old != null && old.host.startsWith('$prefix.')) hosts.add(old.host);
        hosts.add('$prefix.1');
        for (var last = 1; last <= 254; last++) {
          final host = '$prefix.$last';
          if (host != address.address) hosts.add(host);
        }
      }
    }
    final port = old?.port ?? 8000;
    return [for (final host in hosts) 'http://$host:$port'];
  }

  static Future<List<BoxEndpoint>> _discover() async {
    if (!Platform.isIOS) return const [];
    const channel = MethodChannel('dev.tuantu/hotspot');
    final values = await channel
        .invokeListMethod<dynamic>('boxCandidates')
        .timeout(const Duration(seconds: 6));
    return [
      for (final value in values ?? const [])
        if (value is Map &&
            value['ip'] is String &&
            value['host'] is String &&
            InternetAddress.tryParse(value['ip'])?.type ==
                InternetAddressType.IPv4 &&
            !value['ip'].toString().startsWith('127.') &&
            value['port'] is int &&
            value['port'] > 0 &&
            value['port'] <= 65535)
          BoxEndpoint('http://${value['ip']}:${value['port']}', value['host']),
    ];
  }

  static Future<String?> _identifyFast(String base) =>
      _identify(base, fast: true);

  static Future<String?> _identify(String base, {bool fast = false}) async {
    final client = Dio(BaseOptions(
      connectTimeout:
          fast ? const Duration(milliseconds: 350) : const Duration(seconds: 1),
      receiveTimeout:
          fast ? const Duration(milliseconds: 650) : const Duration(seconds: 2),
      followRedirects: false,
    ));
    final cancel = CancelToken();
    final deadline = Timer(
        fast ? const Duration(milliseconds: 800) : const Duration(seconds: 3),
        () => cancel.cancel('identity probe deadline'));
    try {
      final r = await client.get('$base/api/status', cancelToken: cancel);
      final data = r.data;
      if (r.statusCode != 200 || data is! Map || data['service'] != 'tuantu') {
        return null;
      }
      return data['box_id']?.toString();
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }
}
