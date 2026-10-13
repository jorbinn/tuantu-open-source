import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/upload_prep.dart';

void main() {
  group('iosUploadName', () {
    test('generic Live Photo names become unique per asset', () {
      final a = iosUploadName(
          assetId: 'AAA/L0/001',
          filePath: '/tmp/x/still.heic',
          preferredName: 'FullSizeRender.heic');
      final b = iosUploadName(
          assetId: 'BBB/L0/001',
          filePath: '/tmp/y/still.heic',
          preferredName: 'FullSizeRender.heic');
      expect(a, isNot(b));
      expect(a, startsWith('FullSizeRender_'));
      expect(a, endsWith('.heic'));
      final keys = {uploadKey(a, '2026-09-25')};
      final kept = excludeUploaded([
        PickedMedia(
            path: '/p', name: b, day: '2026-09-25', isVideo: false, size: 1),
      ], keys);
      expect(kept, hasLength(1));
    });

    test('same asset keeps the same name so real duplicates are skipped', () {
      String n() => iosUploadName(
          assetId: 'AAA/L0/001',
          filePath: '/tmp/${DateTime.now().microsecondsSinceEpoch}/still.HEIC',
          preferredName: 'IMG_1234.HEIC');
      expect(n(), n());
      expect(n(), matches(RegExp(r'^IMG_1234_[0-9a-f]{8}\.HEIC$')));
    });

    test('extension follows the actual uploaded file', () {
      final n = iosUploadName(
          assetId: 'A',
          filePath: '/tmp/still.jpg',
          preferredName: 'IMG_1.HEIC');
      expect(n, endsWith('.jpg'));
      expect(n, startsWith('IMG_1_'));
    });

    test('empty names fall back and stay unique', () {
      final a = iosUploadName(
          assetId: 'A', filePath: '/tmp/still.heic', preferredName: '');
      final b = iosUploadName(
          assetId: 'B', filePath: '/tmp/still.heic', preferredName: null);
      expect(a, startsWith('still_'));
      expect(a, isNot(b));
      final c = iosUploadName(
          assetId: 'C', filePath: '/tmp/.heic', preferredName: '');
      expect(c, startsWith('IMG_'));
    });

    test('idempotent', () {
      final a = iosUploadName(
          assetId: 'A', filePath: '/t/x.heic', preferredName: 'IMG_9.heic');
      expect(
          iosUploadName(assetId: 'A', filePath: '/t/x.heic', preferredName: a),
          a);
    });
  });
}
