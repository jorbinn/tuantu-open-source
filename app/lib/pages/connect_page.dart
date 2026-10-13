/// 连接页：自动发现盒子（记住的地址 → mDNS → 热点网关探测），
/// 校验旅行热点后自动进入；名字只问一次。
library;

import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../ios_box_endpoint.dart';
import '../box/box_host.dart';
import '../box/box_server.dart';
import '../device_identity.dart';
import '../hotspot_access.dart';
import '../main.dart';
import '../widgets/ios_wifi_help.dart';

class ConnectPage extends StatefulWidget {
  const ConnectPage(
      {super.key,
      this.fromSettings = false,
      this.hotspotProfile = HotspotProfile.bundled,
      this.hotspotAccess,
      this.probeOverride});
  final bool fromSettings;
  final HotspotProfile hotspotProfile;
  final HotspotAccess? hotspotAccess;
  @visibleForTesting
  final Future<bool> Function(String)? probeOverride;
  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> with WidgetsBindingObserver {
  HotspotProfile get _hotspot => widget.hotspotProfile;
  HotspotAccess get _wifi => widget.hotspotAccess ?? HotspotAccess.I;
  Future<bool> _probe(String base) => (widget.probeOverride ?? Api.probe)(base);
  bool _autoBusy = false;
  bool _hotspotAttempted = false;
  bool _waitingForWifi = false;
  bool _foreground = true;
  bool _checkingWifi = false;
  bool _targetApproved = false;
  bool _manualConnection = false;
  Timer? _retryTimer;
  String status = '正在寻找盒子…';
  bool searching = true;
  String? foundBase;
  final name = TextEditingController();
  String? _savedName;
  String? _deviceId;

  /// 搜索代际号：新开一轮搜索或退出页面都会 +1，旧搜索链路检测到就自行退出。
  int _gen = 0;
  String? _previousBoxId;

  @override
  void initState() {
    super.initState();
    _previousBoxId = Api.I.boxId;
    WidgetsBinding.instance.addObserver(this);
    // Show the page before requesting system Wi-Fi approval. Album permissions
    // are unrelated to joining and must not overlap the Wi-Fi consent dialog.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _auto();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _retryTimer?.cancel();
      return;
    }
    if (!mounted || _autoBusy || foundBase != null) return;
    if (_waitingForWifi) {
      _checkWifiAgain();
    } else {
      _auto(allowJoin: false);
    }
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    if (!mounted || !_foreground || foundBase != null) return;
    _retryTimer = Timer(Duration(seconds: _waitingForWifi ? 2 : 8), () {
      if (_waitingForWifi) {
        _checkWifiAgain();
      } else {
        _auto(allowJoin: false);
      }
    });
  }

  Future<void> _checkWifiAgain() async {
    if (_checkingWifi || _autoBusy || !_foreground || !mounted) return;
    _checkingWifi = true;
    final g = _gen;
    try {
      final wifi = await _wifi.state();
      if (!mounted || g != _gen || !_foreground || !_waitingForWifi) return;
      if (wifi.known &&
          (!wifi.connected ||
              (wifi.networkName != null &&
                  wifi.networkName != _hotspot.ssid))) {
        _targetApproved = false;
      }
      if (wifi.canDiscover(_hotspot, targetApproved: _targetApproved) ||
          (wifi.enabled && !_hotspotAttempted && _hotspot.available)) {
        await _auto(allowJoin: !_hotspotAttempted);
      }
    } finally {
      _checkingWifi = false;
      if (mounted && g == _gen && _waitingForWifi) _scheduleRetry();
    }
  }

  void _wifiHelp(String message) {
    if (!mounted) return;
    setState(() {
      searching = false;
      _waitingForWifi = true;
      foundBase = null;
      status = message;
    });
    _scheduleRetry();
  }

  Future<bool> _joinHotspot(int g, bool allowJoin) async {
    if (!_hotspot.available || !allowJoin || _hotspotAttempted) {
      _wifiHelp(
          _hotspot.available ? '请连接 Wi-Fi：${_hotspot.ssid}' : '请连接团长的 Wi-Fi');
      return false;
    }
    _hotspotAttempted = true;
    _setStat('正在连接 ${_hotspot.ssid}…');
    final code = await _wifi.join(_hotspot);
    if (!mounted || g != _gen) return false;
    if (code != 'connected') {
      final message = switch (code) {
        'permission_denied' => '请在系统 Wi-Fi 中连接 ${_hotspot.ssid}',
        'location_off' => '请在系统 Wi-Fi 中连接 ${_hotspot.ssid}',
        _ => '请连接 Wi-Fi：${_hotspot.ssid}',
      };
      _wifiHelp(message);
      return false;
    }
    _targetApproved = true;
    // iOS approval completion is not proof that DHCP has finished.
    for (var i = 0; i < 8; i++) {
      final wifi = await _wifi.state();
      if (!mounted || g != _gen) return false;
      if (wifi.canDiscover(_hotspot, targetApproved: true)) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    _wifiHelp('正在等待 Wi-Fi：${_hotspot.ssid}');
    return false;
  }

  Future<void> _openWifiSettings() async {
    // This is the sole explicit user action; retries after it may request consent.
    _hotspotAttempted = false;
    await _wifi.openSettings();
    if (mounted && _foreground && _waitingForWifi) _scheduleRetry();
  }

  Future<void> _retryHotspotJoin() async {
    if (_autoBusy || !_foreground || !mounted) return;
    _hotspotAttempted = false;
    await _auto();
  }

  Future<String?> _saved(String key) async {
    final p = await SharedPreferences.getInstance();
    return p.getString(key);
  }

  void _setStat(String s) {
    if (mounted) setState(() => status = s);
  }

  Future<void> _auto({bool allowJoin = true}) async {
    if (_autoBusy || !mounted || _manualConnection) return;
    _autoBusy = true;
    try {
      await _discover(allowJoin: allowJoin);
    } finally {
      _autoBusy = false;
      if (mounted && !searching && foundBase == null) _scheduleRetry();
    }
  }

  Future<void> _discover({required bool allowJoin}) async {
    final g = ++_gen;
    _retryTimer?.cancel();
    _waitingForWifi = false;
    foundBase = null;
    _deviceId = await DeviceIdentity.ensureId();
    _savedName = await DeviceIdentity.savedName();
    if (g != _gen) return;
    if (mounted) setState(() => searching = true);
    if (BoxServer.I.running) {
      final p = await SharedPreferences.getInstance();
      await _enter(Api.I.base, p.getString('name'));
      return;
    }
    _setStat('正在检查 Wi-Fi…');
    final wifi = await _wifi.state();
    if (!mounted || g != _gen) return;
    if (wifi.known &&
        (!wifi.connected ||
            (wifi.networkName != null && wifi.networkName != _hotspot.ssid))) {
      _targetApproved = false;
    }
    if (wifi.known && !wifi.enabled) {
      _wifiHelp(
          _hotspot.available ? '请连接 Wi-Fi：${_hotspot.ssid}' : '请连接团长的 Wi-Fi');
      return;
    }
    // A known wrong SSID must not probe or reuse a box on another network.
    if (!wifi.canDiscover(_hotspot, targetApproved: _targetApproved)) {
      if (!await _joinHotspot(g, allowJoin)) return;
    }
    await BoxHost.bindWifi();
    if (g != _gen) return;
    await _primeLocalNetworkDialog();
    if (g != _gen) return;

    // 0) 系统网关 / DHCP（OPPO/真我热点经常不是 .1，而是 .34 这种）
    _setStat('正在连接团长的盒子…');
    try {
      for (final ip in await BoxHost.boxHints()) {
        if (g != _gen || foundBase != null) break;
        if (!RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(ip)) continue;
        if (ip.startsWith('127.')) continue;
        if (await _probe('http://$ip:8000')) {
          _found('http://$ip:8000', g);
          break;
        }
      }
    } catch (_) {}

    // 1) 上次连过的地址最优先（本机 127.0.0.1 不算，那是团长自己）
    final savedBase = await _saved('base');
    final savedName = _savedName;
    if (g != _gen) return;
    if (foundBase != null) {
      await _enter(foundBase!, savedName);
      return;
    }
    if (savedBase != null &&
        savedBase.isNotEmpty &&
        !savedBase.contains('127.0.0.1') &&
        !savedBase.contains('localhost')) {
      _setStat('正在连接上次用的盒子…');
      final ok = await _probe(savedBase);
      if (g != _gen) return;
      if (ok) {
        await _enter(savedBase, savedName);
        return;
      }
    }

    _setStat('正在连接团长的盒子…');

    // 2) UDP 信标（热点上比 mDNS 稳）。
    // iOS 收发广播要 multicast entitlement，没批文发不出也收不到，直接跳过；
    // 等 申请到 com.apple.developer.networking.multicast 再恢复。
    if (!Platform.isIOS) await _udpDiscovery(g);
    if (g != _gen) return;

    // 3) mDNS 广播发现（iOS 上的主力通道）
    if (foundBase == null) await _mdnsDiscovery(g);
    if (g != _gen) return;

    // 4) 常见热点网关 + 本网段 .1
    if (foundBase == null) await _probeGateways(g);
    if (g != _gen) return;

    // 5) 全子网扫描
    if (foundBase == null) {
      await _scanSubnet(g);
    }
    if (g != _gen) return;
    if (foundBase == null) {
      await _scanSubnet(g);
    }
    if (g != _gen) return;

    if (foundBase != null) {
      await _enter(foundBase!, savedName);
      return;
    }

    if (mounted) {
      setState(() {
        searching = false;
        status = Platform.isIOS ? '等待团长打开盒子，请允许团图访问本地网络' : '等待团长打开盒子…';
      });
    }
  }

  BonsoirDiscovery? _d;

  /// iOS 首次连本地地址时系统会挂起「本地网络」授权弹窗，期间所有连接
  /// 全部超时。先串行探测一个本地地址把弹窗顶出来，再走批量发现。
  Future<void> _primeLocalNetworkDialog() async {
    if (!Platform.isIOS) return;
    try {
      final itfs = await NetworkInterface.list(
          includeLoopback: false, type: InternetAddressType.IPv4);
      final first =
          itfs.isNotEmpty ? itfs.first.addresses : const <InternetAddress>[];
      var host = first.isNotEmpty ? first.first.address : '192.168.0.1';
      final o = host.split('.');
      if (o.length == 4) host = '${o[0]}.${o[1]}.${o[2]}.1';
      await _probe('http://$host:8000');
    } catch (_) {}
  }

  Future<void> _udpDiscovery(int g) async {
    RawDatagramSocket? s;
    try {
      s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 18000,
          reuseAddress: true);
      s.broadcastEnabled = true;
      s.listen((e) async {
        if (e != RawSocketEvent.read || foundBase != null) return;
        final dg = s?.receive();
        if (dg == null) return;
        final msg = String.fromCharCodes(dg.data);
        if (!msg.startsWith('TUANTU')) return;
        final ips = <String>{dg.address.address};
        for (final p in msg.split(RegExp(r'\s+'))) {
          if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(p)) ips.add(p);
        }
        for (final ip in ips) {
          if (foundBase != null) return;
          if (ip.startsWith('127.')) continue;
          final base = 'http://$ip:8000';
          if (await _probe(base)) {
            _found(base, g);
            return;
          }
        }
      });
      final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
      try {
        for (final itf in await NetworkInterface.list(
            includeLoopback: false, type: InternetAddressType.IPv4)) {
          for (final a in itf.addresses) {
            final o = a.address.split('.');
            if (o.length != 4) continue;
            targets.add(InternetAddress('${o[0]}.${o[1]}.${o[2]}.1'));
            targets.add(InternetAddress('${o[0]}.${o[1]}.${o[2]}.255'));
          }
        }
      } catch (_) {}
      for (var i = 0; i < 3 && foundBase == null && g == _gen; i++) {
        for (final t in targets) {
          try {
            s.send('TUANTU?'.codeUnits, t, 18000);
          } catch (_) {}
        }
        await Future.delayed(const Duration(milliseconds: 400));
      }
      await Future.delayed(const Duration(milliseconds: 600));
    } catch (_) {
    } finally {
      try {
        s?.close();
      } catch (_) {}
    }
  }

  Future<void> _mdnsDiscovery(int g) async {
    if (Platform.isIOS) {
      try {
        for (final endpoint in await IosBoxEndpoint.I.discover()) {
          if (!mounted || g != _gen || foundBase != null) return;
          if (await _probe(endpoint.base)) {
            _found(endpoint.base, g);
            return;
          }
        }
      } catch (_) {}
      return; // Existing gateway/subnet fallback still follows this step.
    }
    BonsoirDiscovery? d;
    StreamSubscription? sub;
    try {
      final inst = BonsoirDiscovery(type: '_tuantu._tcp');
      d = inst;
      await inst.ready;
      if (g != _gen) {
        try {
          await inst.stop();
        } catch (_) {}
        return;
      }
      _d = inst;
      sub = inst.eventStream?.listen((event) async {
        if (g != _gen || foundBase != null) return;
        // 发现只是看到了名字，必须再 resolve 才有 host/port 可连。
        if (event.type == BonsoirDiscoveryEventType.discoveryServiceFound) {
          final svc0 = event.service;
          if (svc0 != null) {
            try {
              await svc0.resolve(inst.serviceResolver);
            } catch (_) {}
          }
          return;
        }
        if (event.type != BonsoirDiscoveryEventType.discoveryServiceResolved) {
          return;
        }
        final svc = event.service is ResolvedBonsoirService
            ? event.service as ResolvedBonsoirService
            : null;
        final host = svc?.host ?? '';
        if (host.isEmpty) return;
        final port = svc?.port ?? 8000;
        for (final h in [host, host.replaceAll(RegExp(r'\.$'), '')]) {
          if (h.isEmpty || g != _gen) continue;
          final base = 'http://$h:$port';
          if (await _probe(base)) {
            _found(base, g);
            await sub?.cancel();
            try {
              await inst.stop();
            } catch (_) {}
            return;
          }
        }
      });
      await inst.start();
      await Future.delayed(const Duration(seconds: 4));
    } catch (_) {
      // mDNS 不可用，交给网关探测
    } finally {
      await sub?.cancel();
      try {
        await d?.stop();
      } catch (_) {}
      if (d != null && identical(_d, d)) _d = null;
    }
  }

  Future<void> _probeGateways(int g) async {
    final candidates = <String>{
      '192.168.43.1',
      '192.168.137.1',
      '172.20.10.1',
      '192.168.42.1',
      '192.168.49.1',
      '192.168.182.1',
      '192.168.12.1',
      '192.168.0.1',
      '192.168.1.1',
      '192.168.50.1',
    };
    try {
      for (final itf in await NetworkInterface.list(
          includeLoopback: false, type: InternetAddressType.IPv4)) {
        for (final a in itf.addresses) {
          final o = a.address.split('.');
          if (o.length != 4) continue;
          candidates.add('${o[0]}.${o[1]}.${o[2]}.1');
        }
      }
    } catch (_) {}
    for (final c in candidates) {
      if (g != _gen || foundBase != null) return;
      final base = 'http://$c:8000';
      if (await _probe(base)) {
        _found(base, g);
        return;
      }
    }
  }

  /// 全子网扫描：并行探测所在网段的全部地址（不依赖 mDNS 和网关假设，
  /// 无论盒子是热点方还是客户端都能找到）。
  Future<void> _scanSubnet(int g) async {
    final bases = <String>[];
    try {
      final interfaces = await NetworkInterface.list(includeLoopback: false);
      for (final itf in interfaces) {
        for (final a in itf.addresses) {
          if (a.type != InternetAddressType.IPv4) continue;
          final o = a.address.split('.');
          if (o.length != 4) continue;
          for (var last = 1; last <= 254; last++) {
            bases.add('http://${o[0]}.${o[1]}.${o[2]}.$last:8000');
          }
        }
      }
    } catch (_) {}
    final unique = bases.toSet().toList();
    var i = 0;
    Future<void> worker() async {
      while (i < unique.length && g == _gen && foundBase == null) {
        final idx = i++;
        final base = unique[idx];
        if (await _probe(base)) {
          if (g == _gen && foundBase == null) _found(base, g);
          return;
        }
      }
    }

    await Future.wait([for (var k = 0; k < 8; k++) worker()]);
  }

  void _found(String base, int g) {
    if (g != _gen || foundBase != null) return;
    foundBase = base;
    try {
      _d?.stop();
    } catch (_) {}
  }

  Future<void> _goHome() async {
    if (!mounted) return;
    if (Platform.isIOS &&
        widget.fromSettings &&
        _previousBoxId != null &&
        _previousBoxId == Api.I.boxId &&
        Navigator.of(context).canPop()) {
      Api.endpointChanges.value++;
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomePage()),
      (_) => false,
    );
  }

  Future<void> _enter(String base, String? savedName) async {
    final g = _gen;
    base = await Api.addressForJoin(base);
    if (!mounted || g != _gen) return;
    if (savedName != null && savedName.isNotEmpty) {
      _setStat('正在进入相册…');
      final deviceId = _deviceId ?? await DeviceIdentity.ensureId();
      final err = await Api.I.join(base, savedName, '', deviceId: deviceId);
      if (!mounted || g != _gen) return;
      if (err != null) {
        setState(() {
          searching = false;
          foundBase = base;
          status = err;
        });
        return;
      }
      final p = await SharedPreferences.getInstance();
      await p.setString('base', base);
      if (Api.I.boxId != null) await p.setString('box_id', Api.I.boxId!);
      await DeviceIdentity.saveName(Api.I.name);
      _savedName = Api.I.name;
      if (Api.I.token != null) await p.setString('token', Api.I.token!);
      if (!mounted || g != _gen) return;
      await _goHome();
      return;
    }
    if (mounted) {
      setState(() {
        foundBase = base;
        searching = false;
        status = '已找到团长的盒子';
      });
    }
  }

  Future<void> _connectManually() async {
    final dialogGeneration = ++_gen;
    _manualConnection = true;
    _retryTimer?.cancel();
    _waitingForWifi = false;
    unawaited(_wifi.cancelPending());
    final address = TextEditingController();
    String? error;
    final dialog = DialogRoute<String>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, update) {
        void submit() {
          final value = Api.normalizeBase(address.text);
          final host = value == null ? null : Uri.tryParse(value)?.host;
          if (value == null ||
              host == 'localhost' ||
              host == '::1' ||
              host == '0.0.0.0' ||
              (host?.startsWith('127.') ?? false)) {
            update(() => error = '请填写团长设置中显示的局域网地址');
            return;
          }
          Navigator.pop(context, value);
        }

        return AlertDialog(
          title: const Text('输入盒子地址'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('先连接盒子所在的 Wi-Fi 或热点，再填写团长设置里的地址。'),
            TextField(
              controller: address,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                  hintText: 'http://192.168.50.42:8000', errorText: error),
              onSubmitted: (_) => submit(),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(onPressed: submit, child: const Text('连接')),
          ],
        );
      }),
    );
    final base = await Navigator.of(context).push(dialog);
    await dialog.completed;
    address.dispose();
    if (!mounted || dialogGeneration != _gen) return;
    if (base == null) {
      _manualConnection = false;
      unawaited(_auto(allowJoin: false));
      return;
    }
    final g = ++_gen;
    _manualConnection = true;
    _retryTimer?.cancel();
    _waitingForWifi = false;
    await _wifi.cancelPending();
    if (!mounted || g != _gen) return;
    setState(() {
      searching = true;
      foundBase = base;
      status = '正在连接这个盒子…';
    });
    await BoxHost.bindWifi();
    if (!mounted || g != _gen) return;
    final ok = await _probe(base);
    if (!mounted || g != _gen) return;
    if (!ok) {
      setState(() {
        searching = false;
        status = '未连上这个地址。请确认同一 Wi-Fi、团图盒子保持前台，以及本地网络权限已允许。';
      });
      return;
    }
    await _enter(base, _savedName);
  }

  Future<void> _becomeBox() async {
    _gen++;
    _manualConnection = true;
    _retryTimer?.cancel();
    _waitingForWifi = false;
    await _wifi.cancelPending();
    var n = name.text.trim();
    if (n.isEmpty) {
      n = (await _saved('name')) ?? '';
    }
    if (n.isEmpty) {
      if (mounted) {
        setState(() {
          searching = false;
          foundBase = 'local-box';
          status = '先给自己起个名字，再开盒子';
        });
      }
      return;
    }
    _setStat(Platform.isIOS ? '正在准备本机存储并关闭盒子数据备份…' : '正在打开本机盒子…');
    if (mounted) setState(() => searching = true);
    final err = await BoxServer.I.start(hostName: n);
    if (err != null) {
      if (mounted) {
        setState(() {
          searching = false;
          status = err;
        });
      }
      return;
    }
    final p = await SharedPreferences.getInstance();
    await p.setString('name', n);
    if (!mounted) return;
    await _goHome();
  }

  Future<void> _submitName() async {
    if (searching) return;
    final g = ++_gen;
    if (foundBase == 'local-box') {
      await _becomeBox();
      return;
    }
    final found = foundBase;
    if (found == null) return;
    final base = await Api.addressForJoin(found);
    if (!mounted || g != _gen) return;
    final who = _savedName ?? name.text.trim();
    if (who.isEmpty) {
      if (mounted) setState(() => status = '先填你的名字');
      return;
    }
    if (mounted) {
      setState(() {
        searching = true;
        status = '正在进入…';
      });
    }
    final deviceId = _deviceId ?? await DeviceIdentity.ensureId();
    final e = await Api.I.join(base, who, '', deviceId: deviceId);
    if (!mounted || g != _gen) return;
    if (e != null) {
      setState(() {
        searching = false;
        status = e;
      });
      return;
    }
    final p = await SharedPreferences.getInstance();
    await p.setString('base', base);
    if (Api.I.boxId != null) await p.setString('box_id', Api.I.boxId!);
    await DeviceIdentity.saveName(Api.I.name);
    _savedName = Api.I.name;
    await p.setString('token', Api.I.token!);
    if (!mounted || g != _gen) return;
    await _goHome();
  }

  @override
  Widget build(BuildContext context) {
    final askName =
        foundBase != null && (_savedName == null || foundBase == 'local-box');
    final showSubmit = foundBase != null && !searching;
    return Scaffold(
      appBar: widget.fromSettings ? AppBar(title: const Text('连接盒子')) : null,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('🏕️', style: TextStyle(fontSize: 52)),
                          const Text('团 图',
                              style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 4)),
                          const SizedBox(height: 32),
                          if (searching) ...[
                            const CircularProgressIndicator(
                                color: Color(0xFFFF5E7A)),
                            const SizedBox(height: 20),
                          ],
                          Text(status,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 14),
                              textAlign: TextAlign.center),
                          if (_waitingForWifi ||
                              (!searching && !showSubmit)) ...[
                            const SizedBox(height: 24),
                            if (Platform.isIOS)
                              IosWifiHelp(
                                ssid: _hotspot.available ? _hotspot.ssid : null,
                                onRetry: _retryHotspotJoin,
                              )
                            else
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton(
                                  onPressed: _openWifiSettings,
                                  style: FilledButton.styleFrom(
                                      backgroundColor: const Color(0xFFFF5E7A),
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 16)),
                                  child: const Text('打开 Wi-Fi'),
                                ),
                              ),
                          ],
                          if (showSubmit) ...[
                            if (askName) ...[
                              const SizedBox(height: 24),
                              TextField(
                                controller: name,
                                autofocus: true,
                                decoration: const InputDecoration(
                                    hintText: '你的名字（如：小明）'),
                                onSubmitted: (_) => _submitName(),
                              ),
                            ],
                            const SizedBox(height: 20),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: _submitName,
                                style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFFFF5E7A),
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 16)),
                                child: Text(
                                    foundBase == 'local-box' ? '打开盒子' : '进入相册'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (BoxHost.hostingSupported && foundBase != 'local-box')
                TextButton(
                  onPressed: _becomeBox,
                  child: Text(Platform.isIOS ? '我来当盒子（保持前台）' : '我来当盒子'),
                ),
              if (!BoxServer.I.running && foundBase != 'local-box')
                TextButton(
                    onPressed: _connectManually, child: const Text('输入盒子地址')),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _gen++; // 让还在跑的搜索链路全部停下，不再 setState
    _retryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_wifi.cancelPending());
    name.dispose();
    try {
      _d?.stop();
    } catch (_) {}
    super.dispose();
  }
}
