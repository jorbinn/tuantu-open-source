import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/ios_box_endpoint.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const old = 'http://Android_Box.local.:8000';
  const ip = 'http://192.168.254.154:8000';

  test('首次加入使用系统解析的数字 IP，允许主机名大小写和末尾点差异', () async {
    final resolver = IosBoxEndpoint(
      discover: () async => [const BoxEndpoint(ip, 'android_box.local')],
      identify: (_) async => 'box-a',
    );
    expect(await resolver.resolve(old), ip);
  });
  test('旧任务恢复只接受同一 box_id，不猜测相同名字或第一个服务', () async {
    final checked = <String>[];
    final resolver = IosBoxEndpoint(
      discover: () async => [
        const BoxEndpoint('http://192.168.254.2:8000', 'Android_Box.local.'),
        const BoxEndpoint(ip, 'renamed.local.'),
      ],
      identify: (base) async {
        checked.add(base);
        return base == ip ? 'box-a' : 'box-b';
      },
    );
    expect(await resolver.resolve(old, boxId: 'box-a'), ip);
    expect(checked, hasLength(2));
  });
  test('没有盒子身份时不把失效数字 IP 迁移到陌生盒子', () async {
    var searches = 0;
    final resolver = IosBoxEndpoint(discover: () async {
      searches++;
      return [];
    });
    expect(await resolver.resolve(ip), isNull);
    expect(searches, 0);
  });
  test('某个服务超时不阻止其他地址，并发故障只发现一次', () async {
    var searches = 0;
    final pending = Completer<List<BoxEndpoint>>();
    final resolver = IosBoxEndpoint(
      discover: () {
        searches++;
        return pending.future;
      },
      identify: (base) async {
        if (base != ip) throw const SocketException('unreachable');
        return 'box-a';
      },
    );
    final first = resolver.resolve(old, boxId: 'box-a');
    final second = resolver.resolve(old, boxId: 'box-a');
    pending.complete([
      const BoxEndpoint('http://192.168.254.2:8000', 'bad.local'),
      const BoxEndpoint(ip, 'android_box.local'),
    ]);
    expect(await first, ip);
    expect(await second, ip);
    expect(searches, 1);
    expect(await resolver.resolve(old, boxId: 'box-a'), ip);
    expect(searches, 1, reason: '故障重试受冷却限制，不制造发现风暴');
  });

  test('Bonjour 失效时扫描 Wi-Fi 候选，只接受原盒子身份', () async {
    final checked = <String>[];
    final resolver = IosBoxEndpoint(
      discover: () async => throw const SocketException('Bonjour unavailable'),
      fallbackCandidates: (_) async => ['http://wrong:8000', ip],
      identify: (base) async {
        checked.add(base);
        return base == ip ? 'box-a' : 'box-b';
      },
    );
    expect(await resolver.resolve(old, boxId: 'box-a'), ip);
    expect(checked.toSet(), {'http://wrong:8000', ip});
  });
  test('没有原盒子身份时不启用子网迁移', () async {
    var scans = 0;
    final resolver = IosBoxEndpoint(
      discover: () async => [],
      fallbackCandidates: (_) async {
        scans++;
        return [ip];
      },
    );
    expect(await resolver.resolve(old), isNull);
    expect(scans, 0);
  });
  test('扫描限制并发、总时长，后续轮次继续剩余地址', () async {
    var active = 0;
    var peak = 0;
    final checked = <String>[];
    final resolver = IosBoxEndpoint(
      discover: () async => [],
      cooldown: Duration.zero,
      fallbackBudget: const Duration(milliseconds: 50),
      fallbackConcurrency: 2,
      fallbackCandidates: (_) async =>
          List.generate(20, (i) => 'http://host$i:8000'),
      identify: (base) async {
        checked.add(base);
        active++;
        if (active > peak) peak = active;
        try {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return null;
        } finally {
          active--;
        }
      },
    );
    final watch = Stopwatch()..start();
    expect(await resolver.resolve(old, boxId: 'box-a'), isNull);
    expect(watch.elapsedMilliseconds, lessThan(500));
    expect(peak, lessThanOrEqualTo(2));
    final first = checked.toSet();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    checked.clear();
    expect(await resolver.resolve(old, boxId: 'box-a'), isNull);
    expect(checked.toSet().intersection(first), isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 40));
  });

  group('API recovery', () {
    late HttpServer server;
    HttpOverrides? previousHttpOverrides;
    late String actual;
    setUp(() async {
      previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
      Api.iosRecoveryEnabled = true;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      actual = 'http://127.0.0.1:${server.port}';
      server.listen((r) async {
        r.response.headers.contentType = ContentType.json;
        r.response.write(r.uri.path == '/api/status'
            ? '{"service":"tuantu","box_id":"box-a"}'
            : '{"id":7}');
        await r.response.close();
      });
      Api.I.configure(old, 'test-token');
      Api.I.boxId = 'box-a';
      Api.I.userId = 7;
      Api.I.name = 'test-name';
    });
    tearDown(() async {
      Api.iosRecoveryEnabled = Platform.isIOS;
      Api.endpointResolver = IosBoxEndpoint.I;
      Api.I.dio.close(force: true);
      await server.close(force: true);
      HttpOverrides.global = previousHttpOverrides;
    });
    test('地址更新保留 token、身份和客户端，持久化并通知当前页面', () async {
      Api.endpointResolver = IosBoxEndpoint(
        discover: () async => [BoxEndpoint(actual, 'android_box.local')],
        identify: (_) async => 'box-a',
      );
      final client = Api.I.dio;
      final revision = Api.endpointChanges.value;
      expect(await Api.I.recoverConnection(), isTrue);
      expect(Api.I.base, actual);
      expect(Api.I.dio, same(client));
      expect(Api.I.token, 'test-token');
      expect(Api.I.userId, 7);
      expect(Api.I.name, 'test-name');
      expect(Api.endpointChanges.value, revision + 1);
      expect((await SharedPreferences.getInstance()).getString('base'), actual);
    });
    test('本机盒子故障不搜索远程地址或改写自己的会话', () async {
      var discoveries = 0;
      Api.endpointResolver = IosBoxEndpoint(discover: () async {
        discoveries++;
        return [BoxEndpoint(actual, 'my-box.local')];
      });
      Api.I.configure('http://127.0.0.1:8000', 'host-token');
      Api.I.boxId = 'box-a';
      final revision = Api.endpointChanges.value;
      expect(await Api.I.recoverConnection(), isFalse);
      expect(discoveries, 0);
      expect(Api.I.base, 'http://127.0.0.1:8000');
      expect(Api.I.token, 'host-token');
      expect(Api.endpointChanges.value, revision);
    });
    test('发现期间切换账号/盒子，旧结果不覆盖新会话', () async {
      final pending = Completer<List<BoxEndpoint>>();
      Api.endpointResolver = IosBoxEndpoint(
        discover: () => pending.future,
        identify: (_) async => 'box-a',
      );
      final recovery = Api.I.recoverConnection();
      Api.I.configure('http://another.test', 'another-token');
      Api.I.boxId = 'box-b';
      pending.complete([BoxEndpoint(actual, 'android_box.local')]);
      expect(await recovery, isFalse);
      expect(Api.I.base, 'http://another.test');
      expect((await SharedPreferences.getInstance()).getString('base'), isNull);
    });
    test('其它盒子匹配失败，完全不发送会话认证请求', () async {
      Api.endpointResolver = IosBoxEndpoint(
        discover: () async => [BoxEndpoint(actual, 'android_box.local')],
        identify: (_) async => 'box-b',
      );
      expect(await Api.I.recoverConnection(), isFalse);
      expect(Api.I.base, old);
    });
  });
}
