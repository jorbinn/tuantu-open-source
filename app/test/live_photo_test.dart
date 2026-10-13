import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/live_photo.dart';
import 'package:tuantu_app/saver.dart';

Uint8List _ftyp(int n) {
  final out = Uint8List(n);
  final data = ByteData.sublistView(out);
  void box(int offset, int size, String type) {
    data.setUint32(offset, size);
    out.setRange(offset + 4, offset + 8, ascii.encode(type));
  }

  box(0, 16, 'ftyp');
  out.setRange(8, 12, ascii.encode('isom'));
  box(16, 12, 'moov');
  if (n >= 36) box(28, n - 28, 'mdat');
  return out;
}

Uint8List _be32(int n) => Uint8List(4)..buffer.asByteData().setUint32(0, n);

Uint8List _isoBox(String type, List<int> payload) => Uint8List.fromList([
      ..._be32(8 + payload.length),
      ...ascii.encode(type),
      ...payload,
    ]);

Uint8List _mp4WithChunkTable({
  required bool moovFirst,
  bool wide = false,
  int payloadBytes = 1800,
}) {
  Uint8List moovFor(int chunkOffset) {
    final table = wide
        ? _isoBox('co64', [
            0,
            0,
            0,
            0,
            ..._be32(1),
            ..._be32(0),
            ..._be32(chunkOffset),
          ])
        : _isoBox('stco', [
            0,
            0,
            0,
            0,
            ..._be32(1),
            ..._be32(chunkOffset),
          ]);
    return _isoBox(
      'moov',
      _isoBox('trak', _isoBox('mdia', _isoBox('minf', _isoBox('stbl', table)))),
    );
  }

  final ftyp = _isoBox('ftyp', [...ascii.encode('isom'), ..._be32(0)]);
  final moovSize = wide ? 64 : 60;
  final mdat = _isoBox('mdat', List<int>.filled(payloadBytes, 0xAB));
  if (moovFirst) {
    final moov = moovFor(ftyp.length + moovSize + 8);
    expect(moov.length, moovSize);
    return Uint8List.fromList([...ftyp, ...moov, ...mdat]);
  }
  final moov = moovFor(ftyp.length + 8);
  expect(moov.length, moovSize);
  return Uint8List.fromList([...ftyp, ...mdat, ...moov]);
}

void main() {
  test('Live 后台任务只通过可发送参数运行', () async {
    final dir = Directory.systemTemp.createTempSync('tuantu_live_isolate_');
    try {
      final jpeg = File('${dir.path}/still.jpg')
        ..writeAsBytesSync([0xff, 0xd8, 0xff, 0xd9]);
      final video = File('${dir.path}/paired.mp4')
        ..writeAsBytesSync(
          File('test/fixtures/live/sample.mp4').readAsBytesSync(),
        );
      final source = File('${dir.path}/source_MP.jpg')
        ..writeAsBytesSync(
          buildMotionPhotoJpeg(
            jpeg.readAsBytesSync(),
            video.readAsBytesSync(),
            presentationTimestampUs: 321000,
          ),
        );
      expect(await compute(motionPhotoFileComplete, source.path), isTrue);

      final recovered = File('${dir.path}/recovered.mp4');
      expect(
        await compute(recoverLiveSidecarFromPaths, [
          source.path,
          recovered.path,
        ]),
        321000,
      );
      expect(recovered.readAsBytesSync(), video.readAsBytesSync());

      final preview = File('${dir.path}/preview.mp4');
      expect(
        await compute(extractMotionVideoFile, [source.path, preview.path]),
        isTrue,
      );
      expect(preview.readAsBytesSync(), video.readAsBytesSync());

      final output = File('${dir.path}/rebuilt_MP.jpg');
      expect(
        await compute(buildMotionPhotoFile, <String, Object?>{
          'jpeg': jpeg.path,
          'still': jpeg.path,
          'video': video.path,
          'output': output.path,
          'fallback': 123000,
        }),
        isTrue,
      );
      expect(await compute(motionPhotoFileComplete, output.path), isTrue);
      expect(
        await compute(motionPhotoFilesMatch, [output.path, output.path]),
        isTrue,
      );
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('标准 Motion Photo 不冒充手机厂商，按目标品牌写对应标记', () {
    final clip = File('test/fixtures/live/sample.mp4').readAsBytesSync();
    expect(isStructurallyCompleteLiveVideo(clip), isTrue);
    final photo = buildMotionPhotoJpeg([0xff, 0xd8, 0xff, 0xd9], clip);
    final xmp = latin1.decode(photo);
    expect(xmp, isNot(contains('OpCamera:')));
    expect(xmp, contains('GCamera:MotionPhotoVersion="1"'));
    expect(
      xmp,
      isNot(contains('GCamera:MicroVideoVersion')),
      reason: 'ColorOS 16 rejects Motion Photo XMP containing the legacy flag',
    );
    expect(extractMotionVideo(photo), clip);

    final oplus = buildMotionPhotoJpeg(
      [0xff, 0xd8, 0xff, 0xd9],
      clip,
      profile: AndroidMotionPhotoProfile.oplus,
    );
    final oplusXmp = latin1.decode(oplus);
    expect(oplusXmp, contains('OpCamera:OLivePhotoVersion="2"'));
    expect(oplusXmp, contains('OpCamera:MotionPhotoOwner="oplus"'));
    expect(oplusXmp, contains('OpCamera:MotionPhotoVideoStart="0"'));
    expect(oplusXmp, contains('OpCamera:MotionPhotoVideoEnd="0"'));
    expect(oplusXmp, contains('x:xmptk="Adobe XMP Core 5.1.0-jc003"'));
    expect(oplusXmp, isNot(contains('<?xpacket')));
    expect(oplusXmp, isNot(contains('VCamera:')));
    expect(extractMotionVideo(oplus), clip);

    final vivo = buildMotionPhotoJpeg(
      [0xff, 0xd8, 0xff, 0xd9],
      clip,
      profile: AndroidMotionPhotoProfile.vivo,
    );
    final vivoXmp = latin1.decode(vivo);
    expect(
      vivoXmp,
      contains(
        'xmlns:VCamera="http://ns.vivo.com/photos/1.0/camera/"',
      ),
    );
    expect(vivoXmp, contains('VCamera:VMotionPhotoVersion="1"'));
    expect(vivoXmp, contains('VCamera:VMotionPhotoSource="1"'));
    expect(vivoXmp, contains('VCamera:VMediaKitVersion="1.0.0.9"'));
    expect(vivoXmp, isNot(contains('OpCamera:')));
    expect(extractMotionVideo(vivo), clip);
  });

  test('安卓保存 profile 按目标手机选择，不按来源文件选择', () {
    expect(
      androidMotionPhotoProfileForDevice(
        manufacturer: 'OPPO',
        brand: 'realme',
      ),
      AndroidMotionPhotoProfile.oplus,
    );
    expect(
      androidMotionPhotoProfileForDevice(
        manufacturer: 'vivo',
        brand: 'iQOO',
      ),
      AndroidMotionPhotoProfile.vivo,
    );
    expect(
      androidMotionPhotoProfileForDevice(
        manufacturer: 'Google',
        brand: 'Pixel',
      ),
      AndroidMotionPhotoProfile.google,
    );
    expect(
      androidMotionPhotoProfileFromWire('unknown'),
      AndroidMotionPhotoProfile.google,
    );
  });

  test('跨品牌重封装会移除来源厂商标记并保留动态视频', () {
    final clip = File('test/fixtures/live/sample.mp4').readAsBytesSync();
    final fromOplus = buildMotionPhotoJpeg(
      [0xff, 0xd8, 0xff, 0xd9],
      clip,
      profile: AndroidMotionPhotoProfile.oplus,
    );
    expect(latin1.decode(fromOplus), contains('OpCamera:'));

    final forVivo = buildMotionPhotoJpeg(
      jpegStillBytes(fromOplus),
      extractMotionVideo(fromOplus)!,
      profile: AndroidMotionPhotoProfile.vivo,
    );
    final vivoXmp = latin1.decode(forVivo);
    expect(vivoXmp, contains('GCamera:MotionPhoto="1"'));
    expect(vivoXmp, contains('VCamera:VMotionPhotoVersion="1"'));
    expect(vivoXmp, isNot(contains('OpCamera:')));
    expect(extractMotionVideo(forVivo), clip);
  });

  test('大段手机元数据之后的 Motion Photo XMP 仍能被完整校验', () {
    final jpeg = BytesBuilder(copy: false)..add([0xff, 0xd8]);
    for (var index = 0; index < 7; index++) {
      const payloadLength = 60000;
      const segmentLength = payloadLength + 2;
      jpeg.add([
        0xff,
        0xe2,
        (segmentLength >> 8) & 0xff,
        segmentLength & 0xff,
      ]);
      jpeg.add(Uint8List(payloadLength));
    }
    jpeg.add([0xff, 0xd9]);

    final clip = File('test/fixtures/live/sample.mp4').readAsBytesSync();
    final photo = buildMotionPhotoJpeg(
      jpeg.toBytes(),
      clip,
      profile: AndroidMotionPhotoProfile.vivo,
    );
    expect(isCompleteMotionPhoto(photo), isTrue);
    expect(parseMotionPhoto(photo)!.hasXmpFlag, isTrue);
    expect(extractMotionVideo(photo), clip);
  });

  test('reject truncated boxes and ftyp-only payloads even with stale XMP', () {
    final jpeg = [0xff, 0xd8, 0xff, 0xd9];
    final movie = _ftyp(2048);
    expect(isStructurallyCompleteLiveVideo(movie), isTrue);
    expect(isStructurallyCompleteLiveVideo(movie.sublist(0, 1800)), isFalse);
    final muxed = buildMotionPhotoJpeg(jpeg, movie);
    expect(parseMotionPhoto(muxed.sublist(0, muxed.length - 64)), isNull);
    final headOnly = Uint8List(2048)..setRange(0, 16, movie);
    expect(() => buildMotionPhotoJpeg(jpeg, headOnly), throwsArgumentError);
  });

  test('QuickTime MIME, disabled flags and unmarked appended movie', () {
    final jpeg = [0xff, 0xd8, 0xff, 0xd9];
    final movie = _ftyp(2048)..setRange(8, 12, ascii.encode('qt  '));
    final muxed = buildMotionPhotoJpeg(jpeg, movie);
    expect(latin1.decode(muxed), contains('Item:Mime="video/quicktime"'));
    final disabled = Uint8List.fromList(
      latin1.encode(
        latin1
            .decode(muxed)
            .replaceAll('Camera:MotionPhoto="1"', 'Camera:MotionPhoto="0"'),
      ),
    );
    expect(isCompleteMotionPhoto(disabled), isFalse);
    expect(extractMotionVideo(disabled), movie);
    expect(isCompleteMotionPhoto([...jpeg, ...movie]), isFalse);
  });

  test('只读文件头即可区分 QuickTime 与 MP4', () async {
    final dir = Directory.systemTemp.createTempSync('tuantu_live_brand_');
    try {
      final quickTime = File('${dir.path}/apple.mov')
        ..writeAsBytesSync(_ftyp(2048)..setRange(8, 12, ascii.encode('qt  ')));
      final mp4 = File('${dir.path}/android.mp4')
        ..writeAsBytesSync(_ftyp(2048));
      expect(
        await compute(liveVideoFileMime, quickTime.path),
        'video/quicktime',
      );
      expect(await compute(liveVideoFileMime, mp4.path), 'video/mp4');
      expect(await compute(liveVideoPathReady, quickTime.path), isTrue);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('ftyp 头才算视频容器，改后缀或随机字节都不算', () {
    expect(looksLikeVideoContainer(_ftyp(64)), isTrue);
    expect(looksLikeVideoContainer(Uint8List(64)), isFalse);
    expect(
      looksLikeVideoContainer(Uint8List.fromList([0xFF, 0xD8, 0, 0])),
      isFalse,
    );
  });

  test('上传分类：苹果实况缺动态不能当静图，安卓内嵌动态算成套', () {
    expect(
      classifyLiveUpload(
        isLivePhoto: true,
        stillHasEmbeddedLive: false,
        pairedVideoReady: true,
        siblingReady: false,
      ),
      LiveUploadKind.applePair,
    );
    expect(
      classifyLiveUpload(
        isLivePhoto: true,
        stillHasEmbeddedLive: false,
        pairedVideoReady: false,
        siblingReady: false,
      ),
      isNull,
      reason: '实况缺动态部分不得降级成静图上传',
    );
    expect(
      classifyLiveUpload(
        isLivePhoto: false,
        stillHasEmbeddedLive: true,
        pairedVideoReady: false,
        siblingReady: false,
      ),
      LiveUploadKind.embeddedMotion,
    );
    expect(
      classifyLiveUpload(
        isLivePhoto: false,
        stillHasEmbeddedLive: false,
        pairedVideoReady: false,
        siblingReady: true,
      ),
      LiveUploadKind.siblingVideo,
    );
    expect(
      classifyLiveUpload(
        isLivePhoto: false,
        stillHasEmbeddedLive: false,
        pairedVideoReady: false,
        siblingReady: false,
      ),
      LiveUploadKind.stillOnly,
    );
  });

  test('素材分类：完整配对 / 需核验 / 缺失', () {
    expect(
      classifyLiveResource(
        hasLiveFlag: true,
        stillBytes: 2000,
        liveBytes: 4000,
        liveLooksLikeVideo: true,
      ),
      LiveResourceStatus.complete,
    );
    expect(
      classifyLiveResource(
        hasLiveFlag: true,
        stillBytes: 2000,
        liveBytes: 4000,
        liveLooksLikeVideo: false,
      ),
      LiveResourceStatus.needsVerify,
    );
    expect(
      classifyLiveResource(
        hasLiveFlag: true,
        stillBytes: 2000,
        liveBytes: 0,
        liveLooksLikeVideo: false,
      ),
      LiveResourceStatus.needsVerify,
    );
    expect(
      classifyLiveResource(
        hasLiveFlag: false,
        stillBytes: 2000,
        liveBytes: 0,
        liveLooksLikeVideo: false,
      ),
      LiveResourceStatus.missing,
    );
    expect(
      classifyLiveResource(
        hasLiveFlag: true,
        stillBytes: 0,
        liveBytes: 4000,
        liveLooksLikeVideo: true,
      ),
      LiveResourceStatus.missing,
    );
  });

  test('live 文件存在且带 ftyp 才算 ready', () {
    final dir = Directory.systemTemp.createTempSync('tuantu_live_');
    try {
      final ok = File('${dir.path}/ok.mp4');
      ok.writeAsBytesSync(_ftyp(2000));
      expect(liveVideoFileReady(ok), isTrue);
      final bad = File('${dir.path}/bad.mp4');
      bad.writeAsBytesSync(List.filled(2000, 3));
      expect(liveVideoFileReady(bad), isFalse);
      final tiny = File('${dir.path}/tiny.mp4');
      tiny.writeAsBytesSync(_ftyp(32));
      expect(liveVideoFileReady(tiny), isFalse);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('旧静态保存记录不能挡住完整 Live 再存', () {
    const key = 'http://box.test:8000|42';
    expect(Saver.parseSavedEntry('$key|abc', key)?.liveMarked, isFalse);
    expect(Saver.parseSavedEntry('$key|abc|live', key)?.liveMarked, isFalse);
    expect(Saver.parseSavedEntry('$key|abc|live-v2', key)?.liveMarked, isFalse);
    expect(Saver.parseSavedEntry('$key|abc|live-v3', key)?.liveMarked, isFalse);
    expect(Saver.parseSavedEntry('$key|abc|live-v4', key)?.liveMarked, isFalse);
    expect(Saver.parseSavedEntry('$key|abc|live-v5', key)?.liveMarked, isFalse);
    expect(Saver.parseSavedEntry('$key|abc|live-v6', key)?.liveMarked, isFalse);
    expect(Saver.parseSavedEntry('$key|abc|live-v7', key)?.liveMarked, isFalse);
    expect(Saver.parseSavedEntry('$key|abc|live-v8', key)?.liveMarked, isFalse);
    expect(Saver.parseSavedEntry('$key|abc|live-v9', key)?.liveMarked, isFalse);
    expect(Saver.parseSavedEntry('$key|abc|live-v10', key)?.liveMarked, isFalse);
    expect(Saver.parseSavedEntry('$key|abc|live-v11', key)?.liveMarked, isTrue);
    expect(Saver.parseSavedEntry('$key|', key)?.localId, '');
    expect(Saver.parseSavedEntry('other|abc', key), isNull);
  });

  test('Motion Photo 封装后能按 XMP 偏移取出原视频', () {
    final jpeg = Uint8List.fromList([
      0xFF,
      0xD8,
      0xFF,
      0xE0,
      0x00,
      0x10,
      0x4A,
      0x46,
      0x49,
      0x46,
      0x00,
      0x01,
      0x01,
      0x00,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x00,
      0xFF,
      0xD9,
    ]);
    final video = _ftyp(2048);
    final muxed = buildMotionPhotoJpeg(jpeg, video);
    expect(isCompleteMotionPhoto(muxed), isTrue);
    final info = parseMotionPhoto(muxed)!;
    expect(info.hasXmpFlag, isTrue);
    expect(info.videoLength, 2048);
    expect(extractMotionVideo(muxed), video);
    final still = jpegStillBytes(muxed);
    expect(still.sublist(still.length - 2), [0xFF, 0xD9]);
    expect(parseMotionPhoto(still), isNull);
  });

  test('没有 XMP 时仍能靠 ftyp 扫出旧 Motion Photo 视频', () {
    final jpeg = Uint8List.fromList([
      0xFF,
      0xD8,
      0xFF,
      0xE0,
      0x00,
      0x10,
      0x4A,
      0x46,
      0x49,
      0x46,
      0x00,
      0x01,
      0x01,
      0x00,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x00,
      0xFF,
      0xD9,
    ]);
    final video = _ftyp(1500);
    final raw = Uint8List.fromList([...jpeg, ...video]);
    expect(motionVideoOffset(raw), jpeg.length);
    expect(extractMotionVideo(raw), video);
    expect(isCompleteMotionPhoto(raw), isFalse);
  });

  test('关键照片时间点写入 XMP，并能从静图抽出 sidecar', () {
    final jpeg = Uint8List.fromList([
      0xFF,
      0xD8,
      0xFF,
      0xE0,
      0x00,
      0x10,
      0x4A,
      0x46,
      0x49,
      0x46,
      0x00,
      0x01,
      0x01,
      0x00,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x00,
      0xFF,
      0xD9,
    ]);
    final video = _ftyp(1800);
    final muxed = buildMotionPhotoJpeg(
      jpeg,
      video,
      presentationTimestampUs: 1500000,
    );
    expect(parseMotionPhoto(muxed)!.presentationTimestampUs, 1500000);
    expect(livePresentationUs(muxed, fallback: 9), 1500000);
    expect(livePresentationUs(jpeg, fallback: 9), 9);
    expect(livePresentationUs(jpeg), -1);

    final dir = Directory.systemTemp.createTempSync('tuantu_live_fix_');
    try {
      final dest = File('${dir.path}/7.live.mp4');
      expect(writeLiveSidecarFromStill(muxed, dest), isTrue);
      expect(dest.readAsBytesSync(), video);
      expect(writeLiveSidecarFromStill(jpeg, dest), isFalse);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('旧盒子没有 live_ready 时沿用 has_live', () {
    Map<String, dynamic> card({int? liveReady, int hasLive = 1}) => {
          'id': 1,
          'thumb': '',
          'kind': 'image',
          'ext': 'heic',
          'has_thumb': 1,
          'orig_name': 'a.HEIC',
          'uploader': '甲',
          'liked': false,
          'mine': true,
          'width': 0,
          'height': 0,
          'likes': 0,
          'comments': 0,
          'has_live': hasLive,
          if (liveReady != null) 'live_ready': liveReady,
        };
    expect(CardItem(card()).liveReady, isTrue);
    expect(CardItem(card(liveReady: 0)).liveReady, isFalse);
    expect(CardItem(card(hasLive: 0)).liveReady, isFalse);
    expect(CardItem({...card(), 'live_pts': 1200}).livePts, 1200);
    expect(CardItem(card()).livePts, isNull);
  });

  test('原件内嵌视频即使旧记录漏标也要走 Live 保存', () {
    expect(
      shouldAdaptAndroidLive(hasLiveFlag: false, stillHasEmbeddedLive: true),
      isTrue,
    );
    expect(
      shouldAdaptAndroidLive(hasLiveFlag: true, stillHasEmbeddedLive: false),
      isTrue,
    );
    expect(
      shouldAdaptAndroidLive(hasLiveFlag: false, stillHasEmbeddedLive: false),
      isFalse,
    );
  });

  test('vivo uuid 尾巴在 keepUuidTails 时保留进 Item:Length', () {
    final clip = _ftyp(1500);
    final uuid = Uint8List.fromList([
      0, 0, 0, 24, 0x75, 0x75, 0x69, 0x64, // size 24 + uuid
      ...ascii.encode('vivoMediaExtInfo').take(16),
    ]);
    // 24-byte box: 8 header + 16 name
    final withUuid = Uint8List.fromList([...clip, ...uuid]);
    expect(isoMediaUsableLength(withUuid), 1500);
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
    final muxed = buildMotionPhotoJpeg(jpeg, withUuid, trimVendor: false);
    expect(parseMotionPhoto(muxed)!.videoLength, withUuid.length);
  });

  test('ColorOS 重排 moov 时必须改写 stco，并保持样本字节', () {
    final src = _mp4WithChunkTable(moovFirst: true);
    expect(isoMediaTopLevelTypes(src).indexOf('moov'),
        lessThan(isoMediaTopLevelTypes(src).indexOf('mdat')));
    final oldOffsets = isoMediaChunkOffsets(src);
    expect(oldOffsets, isNotEmpty);
    final ordered = isoMediaMoovAtEnd(src);
    expect(isStructurallyCompleteLiveVideo(ordered), isTrue);
    final types = isoMediaTopLevelTypes(ordered);
    expect(types.first, 'ftyp');
    expect(types.indexOf('mdat'), lessThan(types.indexOf('moov')));
    final newOffsets = isoMediaChunkOffsets(ordered);
    expect(newOffsets.length, oldOffsets.length);
    expect(newOffsets.first, isNot(oldOffsets.first));
    expect(
      ordered.sublist(newOffsets.first, newOffsets.first + 64),
      src.sublist(oldOffsets.first, oldOffsets.first + 64),
    );
    expect(isoMediaMoovAtEnd(ordered), ordered);
  });

  test('真实 MP4 重排后 chunk 仍指向原来的媒体数据', () {
    final src = File('test/fixtures/live/sample.mp4').readAsBytesSync();
    final oldOff = isoMediaChunkOffsets(src).first;
    final ordered = isoMediaMoovAtEnd(src);
    expect(isoMediaTopLevelTypes(ordered).indexOf('mdat'),
        lessThan(isoMediaTopLevelTypes(ordered).indexOf('moov')));
    final newOff = isoMediaChunkOffsets(ordered).first;
    expect(
      ordered.sublist(newOff, newOff + 64),
      src.sublist(oldOff, oldOff + 64),
    );
  });

  test('co64 重排同样更新 64 位偏移', () {
    final src = _mp4WithChunkTable(moovFirst: true, wide: true);
    final oldOff = isoMediaChunkOffsets(src).first;
    final ordered = isoMediaMoovAtEnd(src);
    final newOff = isoMediaChunkOffsets(ordered).first;
    expect(newOff, isNot(oldOff));
    expect(
      ordered.sublist(newOff, newOff + 32),
      src.sublist(oldOff, oldOff + 32),
    );
  });

  test('无法安全重排的 MP4 不能输出看起来合法的文件', () {
    expect(() => isoMediaMoovAtEnd(_ftyp(2048)), throwsArgumentError);
    final twoMdat = Uint8List.fromList([
      ..._mp4WithChunkTable(moovFirst: true),
      ..._isoBox('mdat', List<int>.filled(128, 0x11)),
    ]);
    expect(() => isoMediaMoovAtEnd(twoMdat), throwsArgumentError);
    final dir = Directory.systemTemp.createTempSync('tuantu_moov_');
    try {
      final src = File('${dir.path}/bad.mp4')..writeAsBytesSync(_ftyp(2048));
      final dest = File('${dir.path}/out.mp4');
      expect(isoMediaMoovAtEndFile([src.path, dest.path]), isFalse);
      expect(dest.existsSync(), isFalse);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('截断在 moov 之后的厂商尾巴不会当成视频长度', () {
    final clip = _ftyp(2048);
    final dirty = Uint8List.fromList([...clip, ...List<int>.filled(800, 0x99)]);
    expect(isoMediaUsableLength(dirty), 2048);
    expect(trimLiveVideoToIsoMedia(dirty), clip);
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
    final muxed = buildMotionPhotoJpeg(jpeg, dirty);
    expect(extractMotionVideo(muxed), clip);
    expect(parseMotionPhoto(muxed)!.videoLength, 2048);
  });

  test('封装时保留 Gain Map 条目，视频长度取 MotionPhoto 而不是 GainMap', () {
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
    final gain = Uint8List.fromList(
        [0xFF, 0xD8, ...List<int>.filled(64, 1), 0xFF, 0xD9]);
    final clip = _ftyp(1500);
    final muxed = buildMotionPhotoJpeg(jpeg, clip, gainMap: gain);
    final info = parseMotionPhoto(muxed)!;
    expect(info.videoLength, 1500);
    expect(info.gainMapLength, gain.length);
    expect(extractMotionGainMap(muxed), gain);
    expect(extractMotionVideo(muxed), clip);
    final xmp = latin1.decode(muxed);
    expect(xmp, contains('Item:Semantic="GainMap"'));
    expect(xmp, contains('hdrgm:Version="1.0"'));
  });

  test('XMP 插在 EXIF 之后、MPF 之前，避免挪动 MPF 偏移', () {
    final exif = [
      0xff,
      0xe1,
      0x00,
      0x10,
      ...ascii.encode('Exif'),
      0,
      0,
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
    ];
    final mpf = [
      0xff,
      0xe2,
      0x00,
      0x0c,
      ...ascii.encode('MPF\x00'),
      1,
      2,
      3,
      4,
    ];
    final jpeg = Uint8List.fromList([0xff, 0xd8, ...exif, ...mpf, 0xff, 0xd9]);
    final clip = _mp4WithChunkTable(moovFirst: false);
    final muxed = buildMotionPhotoJpeg(jpeg, clip);
    final xmpAt = latin1.decode(muxed).indexOf('GCamera:MotionPhoto');
    final asText = latin1.decode(muxed);
    final mpfAt = asText.indexOf('MPF\x00');
    final exifAt = asText.indexOf('Exif');
    expect(exifAt, greaterThan(0));
    expect(xmpAt, greaterThan(exifAt));
    expect(mpfAt, greaterThan(xmpAt));
  });

  test('ColorOS 保留 moov 后的非 uuid 尾巴，Item:Length 含尾巴', () {
    final clip = _mp4WithChunkTable(moovFirst: true);
    final trailer = _isoBox('GT7P', ascii.encode('realme'));
    final withTail = Uint8List.fromList([...clip, ...trailer]);
    final ordered = isoMediaMoovAtEnd(withTail);
    expect(ordered.sublist(ordered.length - trailer.length), trailer);
    expect(isoMediaUsableLength(ordered), ordered.length - trailer.length);
    final jpeg = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);
    final muxed = buildMotionPhotoJpeg(
      jpeg,
      withTail,
      profile: AndroidMotionPhotoProfile.oplus,
      trimVendor: false,
    );
    final xmp = latin1.decode(muxed);
    expect(xmp, contains('OpCamera:VideoLength="${withTail.length}"'));
    expect(xmp, contains('Item:Length="${withTail.length}"'));
  });

  test('重排时丢掉 vivo uuid，但留下 ColorOS 私有尾巴', () {
    final clip = _mp4WithChunkTable(moovFirst: true);
    final uuid = _isoBox('uuid', [...ascii.encode('vivoMediaExtInfoxx')]);
    final trailer = _isoBox('GT7P', ascii.encode('tail'));
    final mixed = Uint8List.fromList([...clip, ...uuid, ...trailer]);
    final ordered = isoMediaMoovAtEnd(mixed);
    expect(ordered.sublist(ordered.length - trailer.length), trailer);
    expect(ordered.length, isNot(mixed.length));
  });

  test('带 ColorOS 尾巴的原片静图应识别为可原样保存', () {
    final dir = Directory.systemTemp.createTempSync('tuantu_still_');
    try {
      final clip = _mp4WithChunkTable(moovFirst: true);
      final trailer = _isoBox('GT7P', ascii.encode('realme'));
      final video = Uint8List.fromList([...clip, ...trailer]);
      final jpeg = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);
      final muxed = buildMotionPhotoJpeg(
        jpeg,
        video,
        profile: AndroidMotionPhotoProfile.oplus,
        trimVendor: false,
      );
      final f = File('${dir.path}/still.jpg')..writeAsBytesSync(muxed);
      expect(stillHasColorOsLiveTrailer(f.path), isTrue);
      final uuid = Uint8List.fromList([
        ...clip,
        ..._isoBox('uuid', ascii.encode('vivoMediaExtInfoxx')),
      ]);
      final vivo = buildMotionPhotoJpeg(
        jpeg,
        uuid,
        profile: AndroidMotionPhotoProfile.oplus,
        trimVendor: false,
      );
      File('${dir.path}/vivo.jpg').writeAsBytesSync(vivo);
      expect(stillHasColorOsLiveTrailer('${dir.path}/vivo.jpg'), isFalse);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('ColorOS 视频保留允许 moov 在前和 vivo UUID，照片仍按目标重封装', () {
    final dir = Directory.systemTemp.createTempSync('tuantu_oplus_');
    try {
      final clip = _mp4WithChunkTable(moovFirst: true);
      final native = File('${dir.path}/native.mp4')
        ..writeAsBytesSync(
          Uint8List.fromList(
              [...clip, ..._isoBox('GT7P', ascii.encode('realme'))]),
        );
      final vivo = File('${dir.path}/vivo.mp4')
        ..writeAsBytesSync(
          Uint8List.fromList([
            ...clip,
            ..._isoBox('uuid', ascii.encode('vivoMediaExtInfoxx')),
          ]),
        );
      expect(liveVideoCanPreserveOplusContainer(native.path), isTrue);
      expect(liveVideoCanPreserveOplusContainer(vivo.path), isTrue);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('motionPhotoFilesMatch 要求字节一致，不只比长度', () {
    final dir = Directory.systemTemp.createTempSync('tuantu_match_');
    try {
      final clip = File('test/fixtures/live/sample.mp4').readAsBytesSync();
      final bytes = buildMotionPhotoJpeg([0xff, 0xd8, 0xff, 0xd9], clip);
      final a = File('${dir.path}/a.jpg')..writeAsBytesSync(bytes);
      final b = File('${dir.path}/b.jpg')..writeAsBytesSync(bytes);
      expect(motionPhotoFilesMatch([a.path, b.path]), isTrue);
      final mutated = Uint8List.fromList(bytes);
      mutated[mutated.length - 1] ^= 0x01;
      File('${dir.path}/c.jpg').writeAsBytesSync(mutated);
      expect(motionPhotoFilesMatch([a.path, '${dir.path}/c.jpg']), isFalse);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('普通静图不会被分类成 Live', () {
    expect(
      classifyLiveUpload(
        isLivePhoto: false,
        stillHasEmbeddedLive: false,
        pairedVideoReady: false,
        siblingReady: false,
      ),
      LiveUploadKind.stillOnly,
    );
  });
}
