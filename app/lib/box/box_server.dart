/// 本机盒子：在 App 进程里起 HTTP 服务，给自己和热点里的队友用。
library;

import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../device_identity.dart';
import 'box_db.dart';
import 'box_faces.dart';
import 'box_host.dart';
import 'box_http.dart';
import 'box_start_lock.dart';
import 'ios_box_storage.dart';

class BoxServer extends ChangeNotifier {
  BoxServer._();
  static final BoxServer I = BoxServer._();

  HttpServer? _http;
  BoxDb? _db;
  BonsoirBroadcast? _mdns;
  RawDatagramSocket? _beacon;
  Timer? _beaconTick;
  Timer? _ipTick;
  BoxHttp? httpApi;
  bool running = false;
  int port = 8000;
  String? lastError;
  List<String> lanIps = const [];
  final _startLock = BoxStartLock();
  Future<bool>? _resumeFlight;

  static const prefEnabled = 'box_enabled';

  bool get isLocal {
    final b = Api.I.base;
    return b.contains('127.0.0.1') || b.contains('localhost');
  }

  Future<String?> start({String? hostName}) {
    return _startLock.run(
      alreadyRunning: running,
      body: (epoch) => _startBody(epoch, hostName: hostName),
    );
  }

  Future<String?> _startBody(int epoch, {String? hostName}) async {
    lastError = null;
    BoxDb? db;
    HttpServer? bound;
    BoxHttp? api;
    var committed = false;
    Future<void> disposeLocal() async {
      try {
        await bound?.close(force: true);
      } catch (_) {}
      bound = null;
      try {
        await db?.close();
      } catch (_) {}
      db = null;
      api = null;
    }

    try {
      if (!_startLock.isCurrent(epoch)) return '已停止';
      final Directory root;
      if (Platform.isIOS) {
        // Fail closed before opening SQLite or accepting a single upload.
        root = await prepareIosBoxStorage();
      } else {
        final extDir = await getExternalStorageDirectory();
        final docs = await getApplicationDocumentsDirectory();
        root = Directory('${(extDir ?? docs).path}/box');
        await root.create(recursive: true);
      }
      if (!_startLock.isCurrent(epoch)) return '已停止';
      final opened = await BoxDb.openIn(root, databaseInRoot: Platform.isIOS);
      db = opened;
      if (!_startLock.isCurrent(epoch)) {
        await disposeLocal();
        return '已停止';
      }
      final boxId = await opened.ensureBoxId();
      final serving = BoxHttp(opened, root, boxId: boxId);
      api = serving;
      // 开盒清扫：历史删除失败留下的孤儿文件、上次中断上传的 _tmp_
      // 不能 await：清扫是后台兜底，不能挡住 HTTP 端口开放。
      unawaited(serving.sweepOrphanFiles());
      try {
        bound = await HttpServer.bind(InternetAddress.anyIPv4, 8000);
      } on SocketException {
        await disposeLocal();
        return Platform.isIOS
            ? '8000 端口暂不可用，请稍后重新打开盒子。'
            : '8000 端口被占用。请先关掉 Termux 里的旧盒子服务，再打开开关。';
      }
      if (!_startLock.isCurrent(epoch)) {
        await disposeLocal();
        return '已停止';
      }
      port = 8000;
      bound!.autoCompress = false;
      bound!.idleTimeout = const Duration(seconds: 30);
      bound!.listen((req) {
        serving.handle(req);
      }, onError: (e) {
        debugPrint('[box] listen error: $e');
      });
      if (!await Api.probe('http://127.0.0.1:$port')) {
        throw StateError('盒子端口已打开，但健康检查没有响应');
      }
      if (!_startLock.isCurrent(epoch)) {
        await disposeLocal();
        return '已停止';
      }
      final prefs = await SharedPreferences.getInstance();
      final deviceId = await DeviceIdentity.ensureId();
      var name = hostName ?? prefs.getString('name') ?? '';
      String token;
      if (name.isNotEmpty) {
        token = await opened.ensureDeviceUser(deviceId, name);
      } else {
        final mine = await opened.userByDevice(deviceId);
        if (mine != null) {
          name = (mine['name'] ?? '团长').toString();
          token = mine['token'] as String;
        } else {
          final users =
              await opened.q('SELECT * FROM users ORDER BY id LIMIT 1');
          name =
              users.isEmpty ? '团长' : (users.first['name'] ?? '团长').toString();
          token = await opened.ensureDeviceUser(deviceId, name);
        }
      }
      if (!_startLock.isCurrent(epoch)) {
        await disposeLocal();
        return '已停止';
      }
      Api.I.configure('http://127.0.0.1:$port', token);
      Api.I.boxId = boxId;
      Api.I.name = name;
      try {
        final me = await Api.I.me();
        Api.I.userId = (me['id'] as num?)?.toInt();
      } catch (_) {}
      await prefs.setString('base', Api.I.base);
      await prefs.setString('name', name);
      await prefs.setString('token', token);
      await prefs.setBool(prefEnabled, true);
      if (!_startLock.isCurrent(epoch)) {
        await disposeLocal();
        return '已停止';
      }
      _db = db;
      _http = bound;
      httpApi = api;
      running = true;
      committed = true;
      notifyListeners();
      try {
        await BoxHost.start().timeout(const Duration(seconds: 3));
      } catch (e) {
        if (Platform.isIOS) rethrow;
        debugPrint('[box] 前台服务启动失败（服务仍可用）: $e');
      }
      unawaited(httpApi!.refreshStatusCache());
      // IP 枚举、mDNS、UDP 都是辅助发现通道，失败或卡住不能阻塞 HTTP 盒子启动。
      unawaited(
          _refreshIps().timeout(const Duration(seconds: 2), onTimeout: () {}));
      unawaited(
          _advertise().timeout(const Duration(seconds: 3), onTimeout: () {}));
      if (!Platform.isIOS) {
        unawaited(_listenBeacon()
            .timeout(const Duration(seconds: 2), onTimeout: () {}));
      }
      _ipTick?.cancel();
      _ipTick = Timer.periodic(const Duration(seconds: 4), (_) async {
        await _refreshIps();
        notifyListeners();
      });
      unawaited(FaceEngine.I.start(_db!, root));
      // 抽帧必须让开 HTTP。启动后先保证局域网 /api/status 能通，再慢慢补封面。
      unawaited(Future<void>.delayed(const Duration(seconds: 15), () async {
        if (!running) return;
        await httpApi?.backfillVideoThumbs();
      }));
      return null;
    } catch (e, st) {
      debugPrint('[box] start failed: $e\n$st');
      lastError = e.toString();
      if (committed) {
        await stop();
      } else {
        await disposeLocal();
      }
      return '开盒子失败：$e';
    }
  }

  /// Resume the local listener without closing the DB beneath unfinished work.
  /// Never rediscover/join a different box when this phone is the host.
  Future<bool> resumeForeground() {
    if (!Platform.isIOS || !running) return Future.value(running);
    return _resumeFlight ??= _resumeForegroundBody().whenComplete(() {
      _resumeFlight = null;
    });
  }

  Future<bool> _resumeForegroundBody() async {
    final epoch = _startLock.epoch;
    final api = httpApi;
    bool current() =>
        running && _startLock.isCurrent(epoch) && identical(api, httpApi);
    if (api == null) return false;
    try {
      await BoxHost.start();
      if (!current()) return false;
      if (!await Api.probe('http://127.0.0.1:$port')) {
        if (!current()) return false;
        final old = _http;
        _http = null;
        await old?.close(force: true);
        if (!current()) return false;
        final fresh = await HttpServer.bind(InternetAddress.anyIPv4, port);
        if (!current()) {
          await fresh.close(force: true);
          return false;
        }
        fresh.autoCompress = false;
        fresh.idleTimeout = const Duration(seconds: 30);
        fresh.listen(api.handle,
            onError: (Object e) => debugPrint('[box] resume: $e'));
        _http = fresh;
        if (!await Api.probe('http://127.0.0.1:$port')) {
          throw StateError('盒子恢复后没有响应，请在设置中重新开启');
        }
      }
      if (!current()) return false;
      lastError = null;
      unawaited(refreshIps());
      final oldBroadcast = _mdns;
      _mdns = null;
      try {
        await oldBroadcast?.stop();
      } catch (_) {}
      if (!current()) return false;
      unawaited(_advertise());
      notifyListeners();
      return true;
    } catch (e) {
      if (current()) {
        lastError = '盒子恢复失败，请在设置中重新开启：$e';
        notifyListeners();
      }
      return false;
    }
  }

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(prefEnabled) != true) return;
    await start(hostName: prefs.getString('name'));
  }

  Future<void> stop() async {
    _startLock.cancel();
    running = false;
    try {
      await _mdns?.stop();
    } catch (_) {}
    _mdns = null;
    _ipTick?.cancel();
    _ipTick = null;
    _beaconTick?.cancel();
    _beaconTick = null;
    try {
      _beacon?.close();
    } catch (_) {}
    _beacon = null;
    try {
      await _http?.close(force: true);
    } catch (_) {}
    _http = null;
    try {
      await FaceEngine.I.stop();
    } catch (_) {}
    try {
      await _db?.close();
    } catch (_) {}
    _db = null;
    httpApi = null;
    try {
      await BoxHost.stop();
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefEnabled, false);
    notifyListeners();
  }

  Future<void> refreshIps() async {
    await _refreshIps();
    notifyListeners();
  }

  Future<void> _refreshIps() async {
    final fromOs = await BoxHost.lanIps();
    final fromDart = <String>[];
    try {
      for (final itf in await NetworkInterface.list(
          includeLoopback: false, type: InternetAddressType.IPv4)) {
        for (final a in itf.addresses) {
          if (!a.address.startsWith('127.')) fromDart.add(a.address);
        }
      }
    } catch (_) {}
    lanIps = {...fromOs, ...fromDart}.toList();
  }

  Future<void> _listenBeacon() async {
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 18000,
          reuseAddress: true);
      s.broadcastEnabled = true;
      s.listen((e) {
        if (e != RawSocketEvent.read) return;
        final dg = s.receive();
        if (dg == null) return;
        final msg = String.fromCharCodes(dg.data);
        if (!msg.startsWith('TUANTU?')) return;
        s.send(_beaconPayload().codeUnits, dg.address, dg.port);
      });
      _beacon = s;
      _beaconTick?.cancel();
      _beaconTick = Timer.periodic(const Duration(seconds: 2), (_) {
        _shout(s);
      });
      _shout(s);
    } catch (_) {}
  }

  String _beaconPayload() {
    final ips = lanIps.where((e) => !e.startsWith('127.')).join(' ');
    return ips.isEmpty ? 'TUANTU $port' : 'TUANTU $port $ips';
  }

  void _shout(RawDatagramSocket s) {
    final payload = _beaconPayload().codeUnits;
    final dests = <InternetAddress>{InternetAddress('255.255.255.255')};
    for (final ip in lanIps) {
      final o = ip.split('.');
      if (o.length != 4) continue;
      dests.add(InternetAddress('${o[0]}.${o[1]}.${o[2]}.255'));
    }
    for (final d in dests) {
      try {
        s.send(payload, d, 18000);
      } catch (_) {}
    }
  }

  Future<void> _advertise() async {
    final epoch = _startLock.epoch;
    if (!running) return;
    try {
      final svc = BonsoirService(
        name: '团图盒子',
        type: '_tuantu._tcp',
        port: port,
        attributes: {'scheme': 'http', 'path': '/'},
      );
      final b = BonsoirBroadcast(service: svc);
      _mdns = b;
      await b.ready;
      if (!running || !_startLock.isCurrent(epoch) || !identical(_mdns, b)) {
        await b.stop();
        return;
      }
      await b.start();
      if (!running || !_startLock.isCurrent(epoch) || !identical(_mdns, b)) {
        await b.stop();
      }
    } catch (_) {}
  }
}
