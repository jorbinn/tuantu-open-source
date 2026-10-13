import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tuantu_app/pages/album_picker_page.dart';
import 'package:tuantu_app/upload_prep.dart';
import 'package:tuantu_app/album_live_probe.dart';
import 'package:tuantu_app/live_photo.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.fluttercandies/photo_manager');
  final pixel = Uint8List.fromList(
    img.encodePng(img.Image(width: 2, height: 2)),
  );
  late Directory directory;
  late File source;
  var failExport = false;
  late VideoPlayerPlatform oldVideo;
  late _PreviewVideoFake video;
  late PathProviderPlatform oldPaths;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('picker-preview-test-');
    source = File('${directory.path}/test.jpg')..writeAsBytesSync(pixel);
    failExport = false;
    AlbumLiveProbe.shared.clearCache();
    AlbumLiveProbe.shared.probeOverride = null;
    oldVideo = VideoPlayerPlatform.instance;
    video = _PreviewVideoFake();
    VideoPlayerPlatform.instance = video;
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _PreviewPaths(directory.path);
    AlbumPickerPage.previewSourceOverride = (asset, token) async => source;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => directory.path,
    );
    AlbumPickerPage.prepareMediaOverride = (asset) async => failExport
        ? null
        : PickedMedia(
            path: source.path,
            name: asset.title!,
            day: '2023-11-14',
            isVideo: false,
            size: pixel.length,
          );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getPermissionState':
        case 'requestPermissionExtend':
          return 3;
        case 'getAssetPathList':
          return {
            'data': [
              {'id': 'all', 'name': 'All', 'isAll': true, 'assetCount': 2},
            ],
          };
        case 'getAssetListPaged':
          return {
            'data': [
              for (final id in ['a', 'b'])
                {
                  'id': id,
                  'type': 1,
                  'width': 100,
                  'height': 100,
                  'title': '$id.jpg',
                  'createDt': 1700000000,
                },
            ],
          };
        case 'getThumb':
          return pixel;
        case 'getFullFile':
          return failExport ? null : source.path;
        case 'isLocallyAvailable':
          return true;
        default:
          return null;
      }
    });
  });
  tearDown(() {
    AlbumPickerPage.prepareMediaOverride = null;
    AlbumLiveProbe.shared.probeOverride = null;
    AlbumLiveProbe.shared.clearCache();
    VideoPlayerPlatform.instance = oldVideo;
    PathProviderPlatform.instance = oldPaths;
    AlbumPickerPage.previewSourceOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    directory.deleteSync(recursive: true);
  });

  Future<void> openPicker(
    WidgetTester tester, {
    int? maxCount,
    required void Function(List<PickedMedia>?) onResult,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                onResult(
                  await AlbumPickerPage.open(context, maxCount: maxCount),
                );
              },
              child: const Text('选图'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选图'));
    await tester.pumpAndSettle();
  }

  Future<void> finishExport(WidgetTester tester) async {
    // File access/compute use real asynchronous work; let it finish between frames.
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('正在准备 0 / 1 项…').evaluate().isEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle();
  }

  testWidgets('大图勾选后可直接完成，结果返回调用页而不是只关闭预览', (tester) async {
    List<PickedMedia>? result;
    await openPicker(tester, onResult: (value) => result = value);
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '完成'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('preview-select')));
    await tester.pump();
    expect(find.text('完成 (1)'), findsOneWidget);
    final finish = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '完成 (1)'))
        .onPressed!;
    await tester.tap(find.text('完成 (1)'));
    finish(); // A second tap during the closing frame must not pop the picker again.
    await tester.pump();
    await finishExport(tester);
    expect(result, hasLength(1));
    expect(result!.single.name, 'a.jpg');
    expect(find.text('选图'), findsOneWidget);
    expect(find.byType(AlbumPickerPage), findsNothing);
  });

  testWidgets(
    'Live badge is bottom-left; only opened Live creates muted looping video',
    (tester) async {
      AlbumLiveProbe.shared.probeOverride = (asset) async => asset.id == 'a';
      source.writeAsBytesSync(
        buildMotionPhotoJpeg(
          img.encodeJpg(img.Image(width: 32, height: 32)),
          File('test/fixtures/live/sample.mp4').readAsBytesSync(),
        ),
      );
      await openPicker(tester, onResult: (_) {});
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      final badge = find.byKey(const ValueKey('album-live-a'));
      expect(badge, findsOneWidget);
      expect(find.byKey(const ValueKey('album-live-b')), findsNothing);
      final position = tester.widget<Positioned>(
        find.ancestor(of: badge, matching: find.byType(Positioned)).first,
      );
      expect(position.left, 6);
      expect(position.bottom, 6);
      expect(
        video.sources,
        isEmpty,
        reason: 'grid must never extract/play Live videos',
      );
      await tester.tap(find.byType(Image).first);
      await tester.pump();
      for (var i = 0; i < 80 && video.played.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(video.sources, hasLength(1));
      expect(video.sources.single.sourceType, DataSourceType.file);
      expect(video.looping, true);
      expect(video.volume, 0);
      expect(video.played, isNotEmpty);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('album-preview-close')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        if (!directory.listSync().any((f) => f.path.endsWith('.mp4'))) break;
      }
      expect(video.disposed, contains(1));
      expect(
        directory.listSync().whereType<File>().where(
              (f) => f.path.endsWith('.mp4'),
            ),
        isEmpty,
      );
    },
  );

  testWidgets('closing Live preview during source loading never starts a stale player', (tester) async {
    AlbumLiveProbe.shared.probeOverride = (asset) async => asset.id == 'a';
    final pending = Completer<File?>();
    var exports = 0;
    AlbumPickerPage.previewSourceOverride = (asset, token) {
      exports++;
      return pending.future;
    };
    await openPicker(tester, onResult: (_) {});
    await tester.tap(find.byType(Image).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(exports, 1);
    await tester.tap(find.byKey(const ValueKey('album-preview-close')));
    await tester.pumpAndSettle();
    pending.complete(source);
    await tester.pumpAndSettle();
    expect(video.sources, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('单选预览可以换图，关闭大图保留选择但不提交', (tester) async {
    var submitted = false;
    await openPicker(tester, maxCount: 1, onResult: (_) => submitted = true);
    await tester.tap(find.byKey(const ValueKey('album-select-a')));
    await tester.tap(find.byType(Image).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('preview-select')));
    await tester.pump();
    expect(find.text('完成 (1)'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(submitted, isFalse);
    expect(find.text('完成 (1)'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('album-select-b')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('多选完成数量随大图勾选更新，提交保留其他已选项目', (tester) async {
    List<PickedMedia>? result;
    await openPicker(tester, onResult: (value) => result = value);
    await tester.tap(find.byKey(const ValueKey('album-select-a')));
    await tester.tap(find.byKey(const ValueKey('album-select-b')));
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.text('完成 (2)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('preview-select')));
    await tester.pump();
    expect(find.text('完成 (1)'), findsOneWidget);
    await tester.tap(find.text('完成 (1)'));
    await tester.pump();
    await finishExport(tester);
    expect(result!.map((m) => m.name), ['b.jpg']);
  });

  testWidgets('预览直接完成遇到导出失败仍显示错误并留在选图页', (tester) async {
    failExport = true;
    var submitted = false;
    await openPicker(tester, onResult: (_) => submitted = true);
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('preview-select')));
    await tester.pump();
    await tester.tap(find.text('完成 (1)'));
    await tester.pump();
    await finishExport(tester);
    expect(find.text('没能准备好所选项目'), findsOneWidget);
    expect(submitted, isFalse);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.byType(AlbumPickerPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

class _PreviewVideoFake extends VideoPlayerPlatform {
  final sources = <DataSource>[];
  final played = <int>[];
  final disposed = <int>[];
  bool looping = false;
  double volume = 1;
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    sources.add(options.dataSource);
    return sources.length;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream.value(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 2),
          size: const Size(32, 32),
        ),
      );
  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
  }

  @override
  Future<void> setLooping(int playerId, bool value) async {
    looping = value;
  }

  @override
  Future<void> setVolume(int playerId, double value) async {
    volume = value;
  }

  @override
  Future<void> play(int playerId) async {
    played.add(playerId);
  }

  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setMixWithOthers(bool value) async {}
  @override
  Future<void> setAllowBackgroundPlayback(bool value) async {}
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();
}

class _PreviewPaths extends PathProviderPlatform {
  _PreviewPaths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
}
