import 'package:flutter/material.dart';

import '../box/box_server.dart';

class IosBoxBanner extends StatelessWidget {
  const IosBoxBanner({super.key});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: BoxServer.I,
        builder: (context, _) {
          if (!BoxServer.I.running) return const SizedBox.shrink();
          return Material(
            color: const Color(0xFF243D37),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                const Icon(Icons.phone_iphone, size: 18, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(
                  BoxServer.I.lastError ??
                      '盒子已开启 · 请保持团图在前台\n盒子数据仅存本机，不参与 iCloud 备份',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                )),
              ]),
            ),
          );
        },
      );
}
