import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/box/box_face_source.dart';

void main() {
  test('HEIC 原件解不开时改用 JPEG 预览，坐标仍按原图口径传 ow/oh', () {
    final cands = faceSourceCandidates(
      kind: 'image',
      origPath: '/box/orig/1.heic',
      origExists: true,
      thumbPath: '/box/thumbs/1.jpg',
      thumbExists: true,
      webpPath: '/box/thumbs/1.webp',
      webpExists: false,
    );
    expect(cands.map((e) => e.role).toList(), ['orig', 'thumb']);
    expect(nextFaceSource(cands, {'/box/orig/1.heic'})?.path,
        '/box/thumbs/1.jpg');
  });

  test('视频封面还没生成时不算没有人脸', () {
    final cands = faceSourceCandidates(
      kind: 'video',
      origPath: '/box/orig/2.mp4',
      origExists: true,
      thumbPath: '/box/thumbs/2.jpg',
      thumbExists: false,
      webpPath: '/box/thumbs/2.webp',
      webpExists: false,
    );
    expect(cands, isEmpty);
    expect(
      faceMaterialNotReady(kind: 'video', origExists: true, hasPreview: false),
      isTrue,
    );
    expect(decideFaceRetry(reason: 'not_ready', tries: 1), FaceAnalyzeRetry.wait);
    expect(
      decideFaceRetry(reason: 'not_ready', tries: kFaceNotReadyMaxTries),
      FaceAnalyzeRetry.giveUp,
    );
  });

  test('封面延迟出现后会继续用预览识别', () {
    expect(
      nextFaceSource(
        faceSourceCandidates(
          kind: 'video',
          origPath: '/box/orig/2.mp4',
          origExists: true,
          thumbPath: '/box/thumbs/2.jpg',
          thumbExists: true,
          webpPath: '/box/thumbs/2.webp',
          webpExists: false,
        ),
        {},
      )?.role,
      'thumb',
    );
  });

  test('解码失败会再等预览，不会第一次就永久放弃', () {
    expect(isFaceDecodeFailed('decode_failed'), isTrue);
    expect(isFaceDecodeFailed('Exception: boom'), isFalse);
    expect(
      decideFaceRetry(reason: 'decode_failed', tries: 1),
      FaceAnalyzeRetry.wait,
    );
    expect(
      decideFaceRetry(reason: 'decode_failed', tries: kFaceDecodeMaxTries),
      FaceAnalyzeRetry.giveUp,
    );
  });

  test('真正识别失败不会无限循环', () {
    expect(decideFaceRetry(reason: 'error', tries: 1), FaceAnalyzeRetry.giveUp);
    expect(
      decideFaceRetry(reason: 'timeout', tries: kFaceTimeoutMaxTries),
      FaceAnalyzeRetry.giveUp,
    );
  });
}
