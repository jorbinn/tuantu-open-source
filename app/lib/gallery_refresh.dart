/// 相册内容变化广播：有新作品入库时递增，相册相关页面监听后重拉。
/// 值本身没有意义，只看有没有变化。纯客户端信号，不感知别人手机的上传。
library;

import 'package:flutter/foundation.dart';

final ValueNotifier<int> galleryChanged = ValueNotifier<int>(0);

void notifyGalleryChanged() => galleryChanged.value++;
