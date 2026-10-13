/// 团图 — 离线旅行共享相册（安卓盒子 / iOS 前台盒子与客人）
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'box/box_host.dart';
import 'box/box_server.dart';
import 'widgets/ios_box_banner.dart';
import 'card_reader.dart';
import 'device_identity.dart';
import 'hotspot_access.dart';
import 'download.dart';
import 'pages/album_picker_page.dart';
import 'pages/card_import_page.dart';
import 'pages/connect_page.dart';
import 'pages/gallery_page.dart';
import 'pages/me_page.dart';
import 'pages/persons_page.dart';
import 'pages/report_list_page.dart';
import 'pages/swipe_page.dart';
import 'pages/transfers_page.dart';
import 'pages/upload_page.dart';
import 'proxy.dart';
import 'widgets/app_toast.dart';
import 'transfer.dart';
import 'widgets/plus_tab_button.dart';
import 'widgets/soft_error.dart';

/// 盒子用自签证书：全局信任（API 和 Image.network 都走这里）
class TrustBoxHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final c = super.createHttpClient(context);
    c.badCertificateCallback = (cert, host, port) => true;
    c.idleTimeout = const Duration(seconds: 25);
    c.maxConnectionsPerHost = 8;
    return c;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installSoftErrorWidget();
  HttpOverrides.global = TrustBoxHttpOverrides();
  await TransferStore.I.load();
  await DownloadStore.I.load();
  final prefs = await SharedPreferences.getInstance();
  // iOS restores a foreground-only box with verified local, no-backup storage.
  if (BoxHost.hostingSupported &&
      prefs.getBool(BoxServer.prefEnabled) == true) {
    await BoxServer.I.restore();
  }
  final base = prefs.getString('base');
  final token = prefs.getString('token');
  final name = prefs.getString('name') ?? '';
  var loggedIn = false;
  if (BoxServer.I.running) {
    loggedIn = true;
  } else if (base != null &&
      token != null &&
      !base.contains('127.0.0.1') &&
      !base.contains('localhost')) {
    // 无外网热点上安卓可能把请求改走 4G。任何探测之前先把流量绑回 Wi-Fi。
    final wifi = await HotspotAccess.I.state();
    if (wifi.canDiscover(HotspotProfile.bundled)) {
      await BoxHost.bindWifi();
      // 服务在线 ≠ 会话有效：还要拿旧 token 问一次 /api/me，
      // 防止盒子重建库/换了盒子后顶着失效 token 进首页白屏。
      if (Platform.isIOS) {
        Api.I.configure(base, token);
        Api.I.boxId = prefs.getString('box_id');
      }
      if (await Api.sessionValid(base, token) ||
          (Platform.isIOS && await Api.I.recoverConnection())) {
        if (!Platform.isIOS) Api.I.configure(base, token);
        Api.I.name = name;
        try {
          await Api.I.me();
        } catch (_) {}
        await Api.I.refreshBoxIdentity();
        if (Platform.isIOS &&
            Uri.tryParse(Api.I.base)?.host.contains('.local') == true) {
          await Api.I.recoverConnection();
        }
        loggedIn = true;
      }
    }
  }
  // 提前生成一次永久设备身份。首次真正加入时才会要求显示名称。
  unawaited(DeviceIdentity.ensureId());
  Api.I.onAuthFailed = () {
    final ctx = TuantuApp.navKey.currentContext;
    if (ctx == null) return;
    toast(ctx, '登录已失效，请重新加入');
    Navigator.of(ctx).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const ConnectPage()),
      (_) => false,
    );
  };
  runApp(TuantuApp(loggedIn: loggedIn));
}

class TuantuApp extends StatefulWidget {
  const TuantuApp({super.key, required this.loggedIn});
  final bool loggedIn;

  /// 全局导航 key：Api 层发现 401 时从这里跳连接页
  static final navKey = GlobalKey<NavigatorState>();

  /// 信息流据此判断有没有被其它页面盖住，避免底下视频继续播。
  static final routeObserver = RouteObserver<ModalRoute<void>>();

  @override
  State<TuantuApp> createState() => _TuantuAppState();
}

class _TuantuAppState extends State<TuantuApp> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: TuantuApp.navKey,
      navigatorObservers: [TuantuApp.routeObserver],
      title: '团图',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F1216),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF5E7A),
          secondary: Color(0xFF38BDF8),
          surface: Color(0xFF1A1F26),
        ),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF0F1216)),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF222933),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF2C343F)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF2C343F)),
          ),
        ),
      ),
      // 记住会话就直接进；否则自动寻找盒子（mDNS/网关探测），全程只问名字
      home: widget.loggedIn ? const HomePage() : const ConnectPage(),
    );
  }
}

void toast(BuildContext context, String msg) {
  showAppToast(context, msg);
}

/// 主框架：底部五 Tab，正中间是抖音式「+」上传。
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int tab = 0;
  final _upload = GlobalKey<UploadPageState>();
  final _me = GlobalKey<MePageState>();
  final _swipe = GlobalKey<SwipePageState>();
  final _persons = GlobalKey<PersonsPageState>();
  DateTime? _exitAt;
  DateTime? _resumeProbeAt;
  int _resumeProbeGeneration = 0;
  Timer? _connectionWatch;
  bool _connectionProbeRunning = false;
  bool _manualReconnectQueued = false;
  int _connectionMisses = 0;
  DateTime? _cardPromptAt;
  bool _feedClean = false;

  @override
  void initState() {
    super.initState();
    Api.endpointChanges.addListener(_connectionRestored);
    unawaited(DownloadStore.I.run());
    WidgetsBinding.instance.addObserver(this);
    _connectionWatch = Timer.periodic(const Duration(seconds: 8), (_) {
      final base = Api.I.base;
      if (!mounted ||
          base.isEmpty ||
          base.contains('127.0.0.1') ||
          base.contains('localhost') ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
          (!Platform.isIOS && ModalRoute.of(context)?.isCurrent != true)) {
        return;
      }
      // 用户一直停留在首页也能发现断开；正常连通时不刷新列表、不抢滚动位置。
      unawaited(_probeAfterResume(passive: true));
    });
    CardReader.I.onStorageMounted = _storageMounted;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (await CardReader.I.consumeMountIntent() && mounted) {
        _storageMounted();
        return;
      }
      // Browsing/connecting does not need album access on either platform.
      // AlbumPickerPage and Saver request it when the user uploads or saves.
      if (!mounted) return;
      final err = HotspotProfile.bundled.available && !BoxServer.I.running
          ? await ProxyMode.autostart()
          : await ProxyMode.askIfNeeded(context);
      if (err != null && mounted) toast(context, err);
    });
  }

  @override
  void dispose() {
    Api.endpointChanges.removeListener(_connectionRestored);
    _connectionWatch?.cancel();
    CardReader.I.onStorageMounted = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _connectionRestored() {
    if (!mounted) return;
    _connectionMisses = 0;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
  }

  void _storageMounted() {
    if (!mounted ||
        !Platform.isAndroid ||
        !BoxServer.I.running ||
        !BoxServer.I.isLocal) {
      return;
    }
    final now = DateTime.now();
    if (_cardPromptAt != null &&
        now.difference(_cardPromptAt!) < const Duration(seconds: 12)) {
      return;
    }
    _cardPromptAt = now;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const CardImportPage()));
    });
  }

  /// 回前台：安卓客人可能被改走 4G，iOS 锁屏几秒后 socket 会被挂起。
  /// 先把流量绑回 Wi-Fi，再探测盒子；通了刷 feed，不通给「重新连接」。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final now = DateTime.now();
    if (_resumeProbeAt != null &&
        now.difference(_resumeProbeAt!) < const Duration(seconds: 3)) {
      return;
    }
    _resumeProbeAt = now;
    _probeAfterResume();
  }

  Future<void> _probeAfterResume(
      {bool passive = false, bool manual = false}) async {
    if (_connectionProbeRunning) {
      if (manual) _manualReconnectQueued = true;
      return;
    }
    if (manual && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('正在重新连接，当前页面会保留'), duration: Duration(seconds: 20)));
    }
    _connectionProbeRunning = true;
    try {
      final generation = ++_resumeProbeGeneration;
      final base = Api.I.base;
      final token = Api.I.token;
      if (base.isEmpty) return;
      final local = base.contains('127.0.0.1') || base.contains('localhost');
      if (Platform.isAndroid && !local) {
        await BoxHost.bindWifi();
      }
      if (Platform.isIOS && local && BoxServer.I.running) {
        await BoxServer.I.resumeForeground();
      }
      var ok = await Api.sessionValid(base, token);
      var recoveredAddress = false;
      if (!ok && Platform.isIOS && !local) {
        recoveredAddress = await Api.I.recoverConnection();
        ok = recoveredAddress;
      }
      if (!mounted ||
          generation != _resumeProbeGeneration ||
          (!recoveredAddress && Api.I.base != base) ||
          Api.I.token != token ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      if (ok) {
        final recovered = _connectionMisses > 0 || recoveredAddress;
        if (recovered || manual) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
        }
        _connectionMisses = 0;
        if (Platform.isIOS && (manual || recovered) && !recoveredAddress) {
          Api.endpointChanges.value++;
        }
        if (!passive || recovered) {
          _swipe.currentState?.load(reason: FeedLoadReason.passiveResume);
        }
        return;
      }
      _connectionMisses++;
      if (passive && _connectionMisses < 2) return;
      if (!Platform.isIOS &&
          !local &&
          HotspotProfile.bundled.available &&
          (ModalRoute.of(context)?.isCurrent ?? false)) {
        // A remembered guest should not have to find and tap a short-lived toast.
        // Do not interrupt an open picker, editor, permission dialog or subpage.
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const ConnectPage(fromSettings: true),
          ),
        );
        return;
      }
      if (passive && _connectionMisses > 2) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text('和盒子的连接断了'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 6),
            action: SnackBarAction(
              label: '重新连接',
              onPressed: () {
                if (Platform.isIOS) {
                  // Keep the entire route stack, selected tab and scroll/media
                  // position. Recovery broadcasts refresh only after success.
                  _probeAfterResume(manual: true);
                  return;
                }
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ConnectPage(fromSettings: true),
                  ),
                );
              },
            ),
          ),
        );
    } finally {
      _connectionProbeRunning = false;
      if (_manualReconnectQueued && mounted) {
        _manualReconnectQueued = false;
        unawaited(_probeAfterResume(manual: true));
      }
    }
  }

  static const _labels = ['首页', '相册', '', '人物', '我的'];
  static const _icons = [
    Icons.home_outlined,
    Icons.photo_library_outlined,
    Icons.add,
    Icons.face_outlined,
    Icons.person_outline,
  ];
  static const _iconsOn = [
    Icons.home,
    Icons.photo_library,
    Icons.add,
    Icons.face,
    Icons.person,
  ];

  @override
  Widget build(BuildContext context) {
    final pages = [
      SwipePage(
        key: _swipe,
        active: tab == 0,
        onCleanChanged: (v) {
          if (_feedClean != v) setState(() => _feedClean = v);
        },
      ),
      GalleryPage(active: tab == 1),
      UploadPage(key: _upload, active: tab == 2),
      PersonsPage(key: _persons, active: tab == 3, onBrowse: _browsePerson),
      MePage(key: _me),
    ];
    final feed = tab == 0;
    final me = tab == 4;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_swipe.currentState?.consumeBack() == true) return;
        if (_persons.currentState?.consumeBack() == true) return;

        final now = DateTime.now();
        if (_exitAt != null &&
            now.difference(_exitAt!) < const Duration(seconds: 2)) {
          SystemNavigator.pop();
          return;
        }
        _exitAt = now;
        toast(context, '再次返回退出APP');
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: feed ? Colors.black : const Color(0xFF0F1216),
          appBar: (feed || me)
              ? null
              : AppBar(
                  title: const Text(
                    '🏕️ 团图',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    ),
                  ),
                  actions: [
                    IconButton(
                      tooltip: '旅行报告',
                      icon: const Icon(Icons.auto_stories_outlined),
                      onPressed: _openReport,
                    ),
                    const TransferButton(),
                    const SizedBox(width: 4),
                  ],
                ),
          body: IndexedStack(
            index: tab,
            children: [
              for (var i = 0; i < pages.length; i++)
                TickerMode(enabled: i == tab, child: pages[i]),
            ],
          ),
          bottomNavigationBar: Platform.isIOS
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  const IosBoxBanner(),
                  if (!_feedClean) _tabBar(feed),
                ])
              : _feedClean
                  ? null
                  : _tabBar(feed),
        ),
      ),
    );
  }

  Widget _tabBar(bool feed) {
    return ColoredBox(
      color: feed ? Colors.black : const Color(0xFF1A1F26),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              for (var i = 0; i < 5; i++)
                Expanded(
                  child: i == 2
                      ? DouyinPlusButton(onPressed: _onPlus)
                      : _tabItem(i),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabItem(int i) {
    final on = tab == i;
    return InkWell(
      onTap: () {
        if (i == 0 && tab == 0) {
          _swipe.currentState?.load(
            reason: FeedLoadReason.userRefresh,
            resetPosition: true,
          );
          return;
        }
        setState(() => tab = i);
        if (i == 4) _me.currentState?.load();
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            on ? _iconsOn[i] : _icons[i],
            color: on ? Colors.white : Colors.white54,
            size: 24,
          ),
          const SizedBox(height: 2),
          Text(
            _labels[i],
            style: TextStyle(
              fontSize: 11,
              fontWeight: on ? FontWeight.w700 : FontWeight.w400,
              color: on ? Colors.white : Colors.white54,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onPlus() async {
    if (_upload.currentState?.uploading == true) {
      setState(() => tab = 2);
      return;
    }
    final items = await AlbumPickerPage.open(context);
    if (!mounted || items == null || items.isEmpty) return;
    setState(() => tab = 2);
    await _upload.currentState?.enqueue(items);
  }

  void _browsePerson(int pid, String label) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GalleryAlbumPage(title: label, view: 'person:$pid'),
      ),
    );
  }

  /// 相册/人物 Tab 右上角的统一报告入口。旧盒子不支持时提示升级，
  /// 不用不完整的客户端分页数据算假总量。
  Future<void> _openReport() async {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ReportListPage()));
  }
}
