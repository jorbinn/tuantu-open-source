/// 设置：代理模式等。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../box/box_host.dart';
import '../box/box_server.dart';
import '../main.dart';
import '../proxy.dart';
import 'card_import_page.dart';
import 'connect_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool proxyOn = false;
  bool proxyRunning = false;
  bool proxyBusy = false;
  bool boxBusy = false;
  StreamSubscription<bool>? _proxySub;

  @override
  void initState() {
    super.initState();
    BoxServer.I.addListener(_onBox);
    BoxServer.I.refreshIps();
    _loadProxy();
    if (ProxyMode.supported) {
      _proxySub = ProxyMode.runningStream().listen((v) {
        if (mounted) setState(() => proxyRunning = v);
      });
    }
  }

  @override
  void dispose() {
    BoxServer.I.removeListener(_onBox);
    _proxySub?.cancel();
    super.dispose();
  }

  void _onBox() {
    if (mounted) setState(() {});
  }

  Future<void> _loadProxy() async {
    if (!ProxyMode.supported) return;
    final on = await ProxyMode.enabledPref();
    final run = await ProxyMode.isRunning();
    if (mounted) {
      setState(() {
        proxyOn = on;
        proxyRunning = run;
      });
    }
  }

  Future<void> _toggleProxy(bool v) async {
    if (proxyBusy) return;
    setState(() => proxyBusy = true);
    try {
      if (v) {
        final err = await ProxyMode.start();
        if (err != null) {
          if (mounted) toast(context, err);
          setState(() {
            proxyOn = false;
            proxyBusy = false;
          });
          return;
        }
        await ProxyMode.setEnabledPref(true);
        await ProxyMode.markAsked();
        if (mounted) setState(() => proxyOn = true);
      } else {
        await ProxyMode.stop();
        await ProxyMode.setEnabledPref(false);
        if (mounted) setState(() => proxyOn = false);
      }
    } finally {
      if (mounted) setState(() => proxyBusy = false);
    }
  }

  Future<void> _toggleBox(bool v) async {
    if (boxBusy) return;
    setState(() => boxBusy = true);
    try {
      if (v) {
        final err = await BoxServer.I.start(hostName: null);
        if (err != null) {
          if (mounted) toast(context, err);
          return;
        }
        if (!mounted) return;
        toast(
            context,
            Platform.isIOS
                ? '盒子已打开，请保持团图在前台，让队友连接同一 Wi-Fi 或你的热点。'
                : '盒子已打开。请先开个人热点，让队友连上来。');
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const HomePage()),
          (_) => false,
        );
      } else {
        await BoxServer.I.stop();
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const ConnectPage()),
          (_) => false,
        );
      }
    } finally {
      if (mounted) setState(() => boxBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final boxOn = BoxServer.I.running;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.wifi_find),
            title: const Text('连接盒子',
                style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(
              BoxServer.I.running
                  ? '本机就是盒子 ${BoxServer.I.lanIps.isEmpty ? ':${BoxServer.I.port}' : BoxServer.I.lanIps.map((e) => 'http://$e:${BoxServer.I.port}').join('  ')}'
                  : (Api.I.base.isEmpty
                      ? '未连接。点这里扫描局域网 / 手动填地址'
                      : '当前 ${Api.I.base}'),
              style: const TextStyle(
                  color: Colors.white54, fontSize: 12, height: 1.4),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const ConnectPage(fromSettings: true),
              ));
            },
          ),
          if (BoxServer.I.running && BoxServer.I.lanIps.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  final t = BoxServer.I.lanIps
                      .map((e) => 'http://$e:${BoxServer.I.port}')
                      .join('\n');
                  await Clipboard.setData(ClipboardData(text: t));
                  if (context.mounted) toast(context, '盒子地址已复制');
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制盒子地址给队友'),
              ),
            ),
          const Divider(color: Color(0xFF2C343F)),
          if (BoxHost.hostingSupported)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(Platform.isIOS ? '作为盒子（保持前台）' : '作为盒子（团长）',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(
                Platform.isIOS
                    ? '保持团图在前台时，队友可通过同一 Wi-Fi 或个人热点上传、浏览。锁屏或切换应用可能中断，返回后自动恢复。'
                    : boxOn
                        ? (BoxServer.I.lanIps.isEmpty
                            ? '已开启：队友连你的热点。端口 ${BoxServer.I.port}'
                            : '已开启。让队友填：${BoxServer.I.lanIps.map((e) => 'http://$e:${BoxServer.I.port}').join('  或  ')}')
                        : '打开后这台手机就是盒子，不用再开 Termux。请先在系统里打开个人热点。',
                style: const TextStyle(
                    color: Colors.white54, fontSize: 12, height: 1.4),
              ),
              value: boxOn,
              onChanged: boxBusy ? null : _toggleBox,
            ),
          if (Platform.isIOS)
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.phone_iphone),
              title: Text('盒子数据仅存本机'),
              subtitle: Text(
                  '原片、缩略图、人物数据和数据库不参与 iCloud 备份。卸载团图会删除这些数据，请保留原片。手动保存到系统相册的副本遵循系统的 iCloud 照片设置。'),
            ),
          if (Platform.isAndroid)
            const Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: BoxHost.openWifiSettings,
                child: Text('去打开 / 连接 Wi-Fi 热点'),
              ),
            ),
          if (Platform.isAndroid && boxOn)
            Card(
              margin: const EdgeInsets.only(top: 8),
              child: ListTile(
                leading: const Icon(Icons.sd_card_outlined),
                title: const Text('识别相机存储卡',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('主动选择读卡器目录，按日期选片并分配给团员'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const CardImportPage(),
                )),
              ),
            ),
          const SizedBox(height: 12),
          if (ProxyMode.supported)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('代理模式',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(
                proxyRunning
                    ? '已开启：微信等走自己的 4G，传照片仍走热点'
                    : proxyOn
                        ? '开关开着但代理没起来，再拨一次。先确认移动数据开着'
                        : '连盒子热点时，让微信、地图仍走自己的流量',
                style: const TextStyle(
                    color: Colors.white54, fontSize: 12, height: 1.4),
              ),
              value: proxyOn,
              onChanged: proxyBusy ? null : _toggleProxy,
            )
          else
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('代理模式'),
              subtitle: Text('仅安卓可用', style: TextStyle(color: Colors.white54)),
            ),
          const SizedBox(height: 24),
          const Text('💡 使用小贴士', style: TextStyle(fontWeight: FontWeight.w700)),
          const Text(
            '· 首页上下滑刷照片/视频，右侧点赞、评论、下载\n'
            '· 左滑一下保存到相册，仍停在当前这张\n'
            '· 双指放大、拖拽查看细节；中间「+」上传\n'
            '· 先到「人物」页认领自己的脸，之后就能只刷有你的照片\n'
            '· 代理模式是手机本地分流，不是翻墙；系统会显示 VPN 字样\n'
            '· 所有数据都在团长开了服务的那部手机上',
            style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.9),
          ),
        ],
      ),
    );
  }
}
