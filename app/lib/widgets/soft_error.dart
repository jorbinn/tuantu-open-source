import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Release 下单个 widget build 失败时，Flutter 默认画一整块灰色 ErrorWidget，
/// 在列表里会盖住整页。换成一个几乎透明的小图标：出错的只有那一小块，
/// 其余内容照常显示。Debug/测试下保留默认的红屏，方便发现问题。
void installSoftErrorWidget({bool? release}) {
  if (!(release ?? kReleaseMode)) return;
  ErrorWidget.builder = (details) => const SoftErrorBox();
}

class SoftErrorBox extends StatelessWidget {
  const SoftErrorBox({super.key});

  @override
  Widget build(BuildContext context) => const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(8),
            child: SizedBox(
              width: 20,
              height: 20,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0x22FFFFFF),
                ),
              ),
            ),
          ),
        ),
      );
}
