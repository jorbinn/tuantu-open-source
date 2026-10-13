/// 相册导出准备：取消后不再回退到 originFile/file，也不清掉下一轮的令牌。
library;

import 'dart:async';
import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

/// 相册查询条件：按拍摄时间倒序，**不加任何时间窗口**。
///
/// photo_manager 的默认 createTimeCond 是 `[1970-01-01, DateTime.now()]`，
/// 而 now 在构造时就固定了。以前选图页把它存成 `static final`，App 不被
/// 杀掉就一直用第一次打开选图页的时刻当上限：之后拍的/导入的照片
/// （包括用读卡器导入「照片」的相机原片）全部查不到。相机时钟比手机快、
/// 时区设成国内、或默认 1970 年前的日期，也会落在窗口外。
/// 每次调用都新建，不要缓存成静态字段。
FilterOptionGroup albumFilterOption() => FilterOptionGroup(
      orders: const [OrderOption(type: OrderOptionType.createDate, asc: false)],
      createTimeCond: DateTimeCond.def().copyWith(ignore: true),
      updateTimeCond: DateTimeCond.def().copyWith(ignore: true),
    );

class AlbumPrepSession {
  AlbumPrepSession(this.gen);
  final int gen;
  bool cancelled = false;
  final createdFiles = <String>[];

  final _cancelled = Completer<void>();
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    cancelled = true;
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  bool get isCancelled => cancelled;

  void rememberCreated(String path) {
    if (path.isNotEmpty) createdFiles.add(path);
  }

  /// 只删本轮自己写出的预览，不动相册原片和其他任务正在用的文件。
  Future<void> cleanupCreated() async {
    for (final path in createdFiles) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    createdFiles.clear();
  }
}

/// iOS 热点通常没外网。原片不在本机时 [AssetEntity.loadFile]（isOrigin）
/// 会一直等 iCloud，进度停在「正在准备 0 / N」。本机没有原片就不要开始导出。
const kAlbumLocalCheckTimeout = Duration(seconds: 5);
const kAlbumFileTimeout = Duration(seconds: 25);
const kAlbumVideoTimeout = Duration(seconds: 90);
const kAlbumPreviewTimeout = Duration(seconds: 15);

enum AlbumPrepSkip { none, icloud, failed, cancelled }

/// 原片明确不在本机 → 当 iCloud 跳过，不要调用会等网络的 loadFile。
bool shouldSkipIcloudOrigin({required bool? originLocal}) =>
    originLocal == false;

/// loadFile 失败后要不要继续 originFile / file。
/// 取消或超时后继续会把用户卡住，或把压缩件冒充原件。
bool shouldFallbackAfterLoad({
  required bool cancelled,
  required bool timedOut,
}) =>
    !cancelled && !timedOut;

Future<T?> withTimeoutOrNull<T>(
  Future<T?> future, {
  required Duration timeout,
}) async {
  try {
    return await future.timeout(timeout);
  } on TimeoutException {
    return null;
  }
}

Duration albumExportTimeout({required bool isVideo}) =>
    isVideo ? kAlbumVideoTimeout : kAlbumFileTimeout;

class LiveExportPair {
  const LiveExportPair(this.still, this.video);
  final File still;
  final File video;
}

/// 实况静图和动态必须来自同一版本：先试用户看到的编辑版，再退回原片。
Future<LiveExportPair?> resolveLiveExportPair({
  required bool Function() cancelled,
  required Future<File?> Function({required bool isOrigin}) loadStill,
  required Future<File?> Function({required bool isOrigin}) loadVideo,
}) async {
  for (final origin in const [false, true]) {
    if (cancelled()) return null;
    File? still;
    try {
      still = await loadStill(isOrigin: origin);
    } catch (_) {
      still = null;
    }
    if (cancelled() || still == null) continue;
    File? video;
    try {
      video = await loadVideo(isOrigin: origin);
    } catch (_) {
      video = null;
    }
    if (cancelled()) return null;
    if (video != null && video.path != still.path) {
      return LiveExportPair(still, video);
    }
  }
  return null;
}

/// loadFile 失败或取消后，要不要继续 originFile / file。
Future<File?> resolveAlbumFile({
  required bool Function() cancelled,
  required Future<File?> Function() loadFile,
  required Future<File?> Function() originFile,
  required Future<File?> Function() file,
  Duration? stepTimeout,
  bool allowCompressedFallback = true,
}) async {
  if (cancelled()) return null;

  Future<(File? file, bool timedOut)> step(Future<File?> Function() run) async {
    if (cancelled()) return (null, false);
    try {
      final future = run();
      final out = stepTimeout == null
          ? await future
          : await future.timeout(stepTimeout);
      return (out, false);
    } on TimeoutException {
      return (null, true);
    } catch (_) {
      return (null, false);
    }
  }

  var (out, timedOut) = await step(loadFile);
  if (cancelled()) return null;
  if (out != null) return out;
  if (!shouldFallbackAfterLoad(cancelled: cancelled(), timedOut: timedOut)) {
    return null;
  }
  (out, timedOut) = await step(originFile);
  if (cancelled()) return null;
  if (out != null) return out;
  if (!allowCompressedFallback) return null;
  if (!shouldFallbackAfterLoad(cancelled: cancelled(), timedOut: timedOut)) {
    return null;
  }
  (out, _) = await step(file);
  if (cancelled()) return null;
  return out;
}

/// 旧一轮的 finally 不能清掉新一轮的 token / 遮罩状态。
bool shouldClearPrepSession({
  required int finishedGen,
  required int currentGen,
}) =>
    finishedGen == currentGen;

/// 单项导出的等待预算。原片在本机就给足导出时间（大视频要几十秒）；
/// 原片在 iCloud 且设备能出外网就等下载；出不了外网（盒子热点）就别等
/// 系统超时，直接按 iCloud 处理。返回 null 表示「这一项别等了」。
Duration? prepLoadBudget({
  required bool locallyAvailable,
  required bool online,
}) {
  if (locallyAvailable) return const Duration(seconds: 120);
  if (online) return const Duration(seconds: 90);
  return null;
}

/// 给一次 photo_manager 调用设上限：超时 / 出错都按「没拿到」处理。
/// 准备进度必须永远往前走，不允许任何一项无限等待。
/// 注意参数是非空 Future<T>：若声明成 Future<T>?，传 Future<File?> 时
/// T 会被推断成 File 而不是 File?，返回类型就错位了。
Future<T?> withPrepBudget<T>(Future<T> future, Duration? budget) async {
  if (budget == null) return null;
  try {
    return await future.timeout(budget);
  } catch (_) {
    return null;
  }
}

/// 轻量探测当前网络能不能出外网。客户端必须在 finally 里关闭（连接回归规则）。
/// 用 Apple 的 captive portal 地址：不依赖第三方，HTTP 明文不走 ATS。
Future<bool> probeInternetOnline({
  HttpClient Function()? newClient,
  Uri? probeUrl,
  Duration timeout = const Duration(seconds: 4),
}) async {
  final client = (newClient ?? HttpClient.new)();
  try {
    final url =
        probeUrl ?? Uri.parse('http://captive.apple.com/hotspot-detect.html');
    final req = await client.headUrl(url).timeout(timeout);
    final res = await req.close().timeout(timeout);
    await res.drain<void>().timeout(timeout);
    return res.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}
