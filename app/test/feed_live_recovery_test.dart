import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/widgets/feed_media.dart';

class ProbePlayer extends VideoPlayerPlatform {
  final streams = <int, StreamController<VideoEvent>>{};
  final disposed = <int>[];
  int created = 0;
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = ++created;
    late StreamController<VideoEvent> stream;
    stream = StreamController(
        onCancel: () {},
        onListen: () => stream.add(VideoEvent(
            eventType: VideoEventType.initialized,
            duration: const Duration(seconds: 3),
            size: const Size(32, 32))));
    streams[id] = stream;
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int id) => streams[id]!.stream;
  @override
  Future<void> dispose(int id) async {
    disposed.add(id);
  }

  @override
  Future<void> setLooping(int id, bool value) async {}
  @override
  Future<void> setVolume(int id, double value) async {}
  @override
  Future<void> play(int id) async {}
  @override
  Future<void> pause(int id) async {}
  @override
  Future<void> seekTo(int id, Duration position) async {}
  @override
  Future<void> setPlaybackSpeed(int id, double speed) async {}
  @override
  Future<void> setMixWithOthers(bool value) async {}
  @override
  Future<void> setAllowBackgroundPlayback(bool value) async {}
  @override
  Future<Duration> getPosition(int id) async => Duration.zero;
  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();
}

Future<void> drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  late VideoPlayerPlatform old;
  late ProbePlayer player;
  setUp(() {
    old = VideoPlayerPlatform.instance;
    player = ProbePlayer();
    VideoPlayerPlatform.instance = player;
    Api.I.configure('http://box.test:8000', 'synthetic-test-token');
  });
  tearDown(() async {
    for (final s in player.streams.values) {
      await s.close();
    }
    VideoPlayerPlatform.instance = old;
    Api.I.dio.close(force: true);
  });
  testWidgets(
      'Live runtime error releases the player and can recover on resume',
      (tester) async {
    final card = CardItem({
      'id': 1,
      'thumb': '',
      'kind': 'image',
      'has_live': 1,
      'ext': 'jpg',
      'width': 32,
      'height': 32
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FeedItem(
                item: card,
                active: true,
                saving: false,
                chrome: false,
                onZoomed: (_) {},
                onLike: () {},
                onComment: () {},
                onDownload: () {}))));
    await drain(tester);
    expect(player.created, 1);
    expect(find.byType(VideoPlayer), findsOneWidget);
    player.streams[1]!.addError(PlatformException(
        code: 'VideoError', message: 'simulated AVPlayer stream failure'));
    await drain(tester);
    expect(find.byType(VideoPlayer), findsNothing);
    expect(find.byType(FilledButton), findsOneWidget);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(player.disposed, [1]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await drain(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await drain(tester);
    expect(player.created, 2);
    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await drain(tester);
  });
}
