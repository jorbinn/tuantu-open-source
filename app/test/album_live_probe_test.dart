import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:photo_manager/photo_manager.dart';
import 'package:tuantu_app/album_live_probe.dart';
import 'package:tuantu_app/box/box_faces.dart';
import 'package:tuantu_app/live_photo.dart';

void main() {
  test('system Live flag does not request an original or an iCloud export', () async {
    final probe = AlbumLiveProbe();
    var calls = 0;
    probe.probeOverride = (_) async { calls++; return false; };
    final live = AssetEntity(id: 'ios-live', typeInt: 1,
        width: 100, height: 100, subtype: 8);
    expect(live.isLivePhoto, true);
    expect(await probe.detect(live), true);
    expect(calls, 0);
  });
  test('metadata probe finds motion, rejects static and truncated data', () {
    final dir = Directory.systemTemp.createTempSync('live-probe-');
    try {
      final file = File('${dir.path}/test.jpg');
      final jpg = im.encodeJpg(im.Image(width: 32, height: 32));
      file.writeAsBytesSync(jpg);
      expect(probeLocalLivePhoto(file.path), false);
      final clip = File('test/fixtures/live/sample.mp4').readAsBytesSync();
      final live = buildMotionPhotoJpeg(jpg, clip);
      file.writeAsBytesSync(live);
      expect(probeLocalLivePhoto(file.path), true);
      expect(readJpegMetadata(file.path).length, lessThan(live.length ~/ 2));
      file.writeAsBytesSync(live.sublist(0, live.length - 40));
      expect(probeLocalLivePhoto(file.path), false);
      file.writeAsBytesSync(jpg);
      File('${dir.path}/test.mov').writeAsBytesSync(clip);
      expect(probeLocalLivePhoto(file.path), true);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test(
    'grid and preview coalesce detection; at most two files at once',
    () async {
      final probe = AlbumLiveProbe();
      var running = 0;
      var peak = 0;
      var calls = 0;
      final release = Completer<void>();
      probe.probeOverride = (a) async {
        calls++;
        running++;
        if (running > peak) peak = running;
        await release.future;
        running--;
        return a.id == '0';
      };
      final assets = [
        for (var i = 0; i < 20; i++)
          AssetEntity(
            id: '$i',
            typeInt: 1,
            width: 100,
            height: 100,
            modifiedDateSecond: 1,
          ),
      ];
      final grid = [for (final a in assets) probe.detect(a)];
      final preview = probe.detect(assets.first);
      release.complete();
      final results = await Future.wait(grid);
      expect(await preview, true);
      expect(results.where((v) => v), hasLength(1));
      expect(peak, 2);
      expect(calls, 20);
      expect(await probe.detect(assets.first), true);
      expect(calls, 20);
      await probe.detect(
        AssetEntity(
          id: '0',
          typeInt: 1,
          width: 100,
          height: 100,
          modifiedDateSecond: 2,
        ),
      );
      expect(calls, 21);
    },
  );

  test(
      'unchanged automatic cover is stable, changed or removed source invalidates',
      () {
    final areas = <int, num>{1: 25, 2: 100, 3: 100, 4: 150};
    expect(effectivePersonCover([3, 2, 1], null, areas), 2);
    expect(effectivePersonCover([1, 2, 3], null, areas), 2);
    expect(effectivePersonCover([1, 3], null, areas), 3);
    expect(effectivePersonCover([1, 2, 4], null, areas), 4);
    expect(effectivePersonCover([1, 2, 4], 1, areas), 1);
    expect(effectivePersonCover([2, 4], 1, areas), 4);
  });
}
