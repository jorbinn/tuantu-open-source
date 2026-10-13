import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/live_photo.dart';

Uint8List compose(List<int> still, List<int> clip,
        {List<int>? gain, int pts = 500000}) =>
    buildMotionPhotoJpeg(still, clip,
        gainMap: gain,
        presentationTimestampUs: pts,
        profile: AndroidMotionPhotoProfile.oplus,
        trimVendor: false);

void checkMpf(Uint8List photo, {List<int>? gain}) {
  final signature = latin1.decode(photo).indexOf('MPF\x00');
  expect(signature, greaterThan(0));
  final tiff = signature + 4;
  final data = ByteData.sublistView(photo);
  expect(data.getUint16(tiff), 0x4d4d);
  final ifd = tiff + data.getUint32(tiff + 4);
  expect(data.getUint16(ifd), 3);
  final count = data.getUint32(ifd + 22);
  expect(count, gain == null ? 1 : 2);
  final entries = tiff + data.getUint32(ifd + 34);
  final primaryLength = data.getUint32(entries + 4);
  expect(photo.sublist(primaryLength - 2, primaryLength), [0xff, 0xd9]);
  expect(data.getUint32(entries + 8), 0);
  final info = parseMotionPhoto(photo)!;
  expect(primaryLength + (gain?.length ?? 0), info.videoOffset);
  if (gain != null) {
    final start = tiff + data.getUint32(entries + 24);
    final size = data.getUint32(entries + 20);
    expect(size, gain.length);
    expect(start, primaryLength);
    expect(photo.sublist(start, start + size), gain);
  }
}

void main() {
  final clip = File('test/fixtures/live/sample.mp4').readAsBytesSync();
  final still = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);

  test('ColorOS 单图 MPF 指向最终 JPEG，重复封装不累积旧索引', () {
    final first = compose(still, clip);
    checkMpf(first);
    final second = compose(first, clip, pts: 12345678);
    checkMpf(second);
    expect('MPF\x00'.allMatches(latin1.decode(second)).length, 1);
    expect(second.sublist(parseMotionPhoto(second)!.videoOffset), clip);
  });

  test('ColorOS HDR MPF 在 XMP 长度变化后仍正确定位两张 JPEG', () {
    final gain =
        Uint8List.fromList([0xff, 0xd8, ...List.filled(64, 7), 0xff, 0xd9]);
    final first = compose(still, clip, gain: gain);
    final second = compose(first, clip, gain: gain, pts: 12345678);
    checkMpf(first, gain: gain);
    checkMpf(second, gain: gain);
    expect(extractMotionGainMap(second), gain);
    expect(second.sublist(parseMotionPhoto(second)!.videoOffset), clip);
  });

  test('ColorOS 单视频保留 UUID 并把完整长度写入两个字段', () {
    final uuid = Uint8List(32);
    ByteData.sublistView(uuid).setUint32(0, uuid.length);
    uuid.setRange(4, 8, ascii.encode('uuid'));
    final video = Uint8List.fromList([...clip, ...uuid]);
    final photo = compose(still, video);
    final text = latin1.decode(photo);
    expect(text, contains('OpCamera:VideoLength="${video.length}"'));
    expect(text, contains('Item:Length="${video.length}"'));
    expect(text, contains('OpCamera:MotionPhotoVideoStart="0"'));
    expect(text, contains('OpCamera:MotionPhotoVideoEnd="0"'));
    expect(photo.sublist(parseMotionPhoto(photo)!.videoOffset), video);
    expect(text, isNot(contains('live.subVideo')));
    checkMpf(photo);
  });

  // Optional local references stay outside Git. Outputs are consumed by the
  // Android GalleryParserProbe and manual system-Gallery playback checks.
  final referenceDir = Platform.environment['TUANTU_LIVE_REFERENCES'];
  test('本地微信成功样本：真实视频不变，生成产品封装与单变量对照', () {
    final dir = Directory(referenceDir!);
    for (final entry in {
      'vivo_recent_1333.jpg': '03_new_from_vivo.jpg',
      'realme_wx_1334.jpg': '04_wechat_rewrapped.jpg',
      '../live_real_assets/201.jpg': '05_new_native_vivo.jpg',
    }.entries) {
      final source = File('${dir.path}/${entry.key}').readAsBytesSync();
      final info = parseMotionPhoto(source)!;
      final video =
          source.sublist(info.videoOffset, info.videoOffset + info.videoLength);
      final gain = extractMotionGainMap(source);
      final output = compose(source, video,
          gain: gain, pts: info.presentationTimestampUs ?? 500000);
      checkMpf(output, gain: gain);
      expect(output.sublist(parseMotionPhoto(output)!.videoOffset), video);
      File('${dir.path}/${entry.value}').writeAsBytesSync(output);
      if (entry.value == '03_new_from_vivo.jpg') {
        final text = latin1.decode(output);
        final withoutTimes = text.replaceAllMapped(
            RegExp(r'OpCamera:MotionPhotoVideo(?:Start|End)="0"'),
            (match) => ' ' * match[0]!.length);
        File('${dir.path}/06_control_without_times.jpg')
            .writeAsBytesSync(latin1.encode(withoutTimes));
        final withoutMpf = Uint8List.fromList(output);
        withoutMpf[text.indexOf('MPF\x00') - 3] = 0xfe; // APP2 -> JPEG comment.
        File('${dir.path}/07_control_without_mpf.jpg')
            .writeAsBytesSync(withoutMpf);
      }
    }
  },
      skip: referenceDir == null
          ? 'Local private references not supplied'
          : false);
}
