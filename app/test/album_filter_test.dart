import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photo_manager/photo_manager.dart';
import 'package:tuantu_app/album_live_probe.dart';
import 'package:tuantu_app/album_prep.dart';
import 'package:tuantu_app/pages/album_picker_page.dart';

/// 在任意嵌套的 method-channel 参数里找 createDate / updateDate 条件。
List<Map> _dateConds(Object? v, String key) {
  final out = <Map>[];
  void walk(Object? x) {
    if (x is Map) {
      if (x[key] is Map) out.add(x[key] as Map);
      x.values.forEach(walk);
    } else if (x is List) {
      x.forEach(walk);
    }
  }

  walk(v);
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.fluttercandies/photo_manager');
  final pixel = Uint8List.fromList(
    img.encodePng(img.Image(width: 2, height: 2)),
  );

  test('album filter has no creation/update time window', () {
    final group = albumFilterOption();
    expect(group.createTimeCond.ignore, isTrue);
    expect(group.updateTimeCond.ignore, isTrue);
    final m = group.toMap();
    expect(_dateConds(m, 'createDate').single['ignore'], isTrue);
    expect(_dateConds(m, 'updateDate').single['ignore'], isTrue);
    expect(group.orders.single.type, OrderOptionType.createDate);
    expect(group.orders.single.asc, isFalse);
    // 每次新建，不能是被缓存的同一个对象（旧 bug：static final 冻结 now）。
    expect(identical(albumFilterOption(), albumFilterOption()), isFalse);
  });

  group('picker', () {
    final calls = <MethodCall>[];
    late List<Map<String, Object?>> library;

    Map<String, Object?> asset(String id, int createDt) => {
          'id': id,
          'type': 1,
          'width': 100,
          'height': 100,
          'title': '$id.JPG',
          'createDt': createDt,
        };

    setUp(() {
      calls.clear();
      AlbumLiveProbe.shared.clearCache();
      AlbumLiveProbe.shared.probeOverride = (_) async => false;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      library = [
        // 相机时钟比手机快（时区设成 UTC+8）：拍摄时间在「未来」。
        asset('camera_future', now + 6 * 3600),
        asset('iphone_now', now),
        // 相机没设时钟：1970 年之前。
        asset('camera_old', -86400 * 400),
      ];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'getPermissionState':
          case 'requestPermissionExtend':
            return 3;
          case 'getAssetPathList':
            return {
              'data': [
                {
                  'id': 'all',
                  'name': 'Recents',
                  'isAll': true,
                  'assetCount': library.length,
                },
              ],
            };
          case 'getAssetListPaged':
            return {'data': library};
          case 'getAssetCountFromPath':
            return library.length;
          case 'getThumb':
            return pixel;
          default:
            return null;
        }
      });
    });

    tearDown(() {
      AlbumLiveProbe.shared.probeOverride = null;
      AlbumLiveProbe.shared.clearCache();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    testWidgets(
        'queries without a date window; future/old camera dates are listed; '
        'returning to the app picks up newly imported photos', (tester) async {
      // 三个日期组（now+6h 可能跨天）都要在视口内，避免按时刻变化的偶发失败。
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: AlbumPickerPage()));
      await tester.pumpAndSettle();
      for (final id in ['camera_future', 'iphone_now', 'camera_old']) {
        expect(find.byKey(ValueKey('album-select-$id')), findsOneWidget,
            reason: id);
      }
      for (final m in ['getAssetPathList', 'getAssetListPaged']) {
        final call = calls.firstWhere((c) => c.method == m);
        final create = _dateConds(call.arguments, 'createDate');
        expect(create, isNotEmpty, reason: m);
        expect(create.every((c) => c['ignore'] == true), isTrue, reason: m);
      }
      expect(find.textContaining('1968年'), findsOneWidget); // 1970 年前的日期头

      await tester.tap(find.byKey(const ValueKey('album-select-iphone_now')));
      await tester.pump();
      expect(find.text('完成 (1)'), findsOneWidget);

      // 相册没变化时回到前台不重置列表。
      final paged = calls.where((c) => c.method == 'getAssetListPaged').length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'getAssetListPaged').length, paged);

      // 选图页开着时去「照片」用读卡器导入了新照片，再回到 App。
      library = [
        asset('card_import', DateTime.now().millisecondsSinceEpoch ~/ 1000),
        ...library,
      ];
      final before = calls.where((c) => c.method == 'getAssetPathList').length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'getAssetPathList').length,
          before + 1);
      expect(find.byKey(const ValueKey('album-select-card_import')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('album-select-iphone_now')),
          findsOneWidget);
      // 已选项保留。
      expect(find.text('完成 (1)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
