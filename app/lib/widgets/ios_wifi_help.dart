import 'package:flutter/material.dart';

/// iOS has no public shortcut to the Wi-Fi settings page.
class IosWifiHelp extends StatelessWidget {
  const IosWifiHelp({super.key, this.ssid, required this.onRetry});

  final String? ssid;
  final VoidCallback onRetry;

  void _showSteps(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('连接团长的 Wi-Fi'),
        content: Text('回到 iPhone 主屏幕，打开「设置」→「Wi-Fi」，'
            '选择${ssid == null ? '团长的热点' : '「$ssid」'}并输入密码。\n\n'
            '连接后返回团图，会自动继续。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      FilledButton(
        onPressed: ssid == null ? () => _showSteps(context) : onRetry,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFFFF5E7A),
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
        child: Text(ssid == null ? '如何连接 Wi-Fi' : '连接 $ssid'),
      ),
      if (ssid != null)
        TextButton(
          onPressed: () => _showSteps(context),
          child: const Text('如何手动连接 Wi-Fi'),
        ),
    ],
  );
}
