/// 底部中间「+」上传按钮：白底圆角框。
library;

import 'package:flutter/material.dart';

class DouyinPlusButton extends StatelessWidget {
  const DouyinPlusButton({super.key, this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 52,
        height: 56,
        child: Center(
          child: Semantics(
            button: true,
            label: '上传',
            child: Container(
              width: 38,
              height: 32,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.add, color: Colors.black, size: 24),
            ),
          ),
        ),
      ),
    );
  }
}
