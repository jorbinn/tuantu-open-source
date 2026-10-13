import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:path/path.dart' as p;
import 'package:tuantu_app/box/box_http.dart';
import 'package:tuantu_app/box/box_upload.dart';

void main() {
  late Directory orig;

  setUp(() {
    orig = Directory.systemTemp.createTempSync('tuantu_box_upload_');
  });

  tearDown(() {
    try {
      orig.deleteSync(recursive: true);
    } catch (_) {}
  });

  test(
    'invalid, missing or ambiguously paired Live upload never inserts a still',
    () async {
      const boundary = '----LiveIntegrity';
      final photo = _jpeg(12, 10, 200, 40, 40);
      for (final scenario in ['invalid', 'missing', 'multiple']) {
        var inserted = 0;
        final body = _multipartFull(
          boundary,
          [
            (name: 'files', filename: 'a.jpg', data: photo),
            if (scenario == 'multiple')
              (name: 'files', filename: 'b.jpg', data: photo),
            if (scenario != 'missing')
              (
                name: 'live',
                filename: 'a.mp4',
                data: scenario == 'invalid'
                    ? List<int>.filled(3000, 3)
                    : File('test/fixtures/live/sample.mp4').readAsBytesSync(),
              ),
          ],
          fields: {'meta': '{"a.jpg":{"live_required":true}}'},
        );
        await expectLater(
          ingestUploadMultipart(
            body: _chunked(body, 13),
            boundary: boundary,
            orig: orig,
            isAllowed: (_) => true,
            kindOf: (_) => 'image',
            findDup: (_, __) async => null,
            insertAsset: (_) async => ++inserted,
          ),
          throwsFormatException,
          reason: scenario,
        );
        expect(inserted, 0, reason: scenario);
        expect(orig.listSync(), isEmpty, reason: scenario);
      }
    },
  );

  test('流式 multipart：跨 chunk 边界、多文件、拒绝扩展名、sha 去重', () async {
    final photoA = _jpeg(12, 10, 200, 40, 40);
    final photoB = _jpeg(14, 11, 40, 180, 40);
    final exeBytes = utf8.encode('not-an-image');

    const boundary = '----TuantuTestBoundaryXYZ';
    final body = _multipart(boundary, [
      (name: 'files', filename: 'a.jpg', data: photoA),
      (name: 'files', filename: 'b.png', data: photoB),
      (name: 'files', filename: 'notes.exe', data: exeBytes),
      (name: 'files', filename: 'a-again.jpg', data: photoA),
    ]);

    // 刻意用小于边界串的块，强迫 `--boundary` 横跨两个 chunk。
    const chunkSize = 5;
    expect(utf8.encode('--$boundary').length, greaterThan(chunkSize));

    final knownSha = <String, int>{};
    var nextId = 1;
    final result = await ingestUploadMultipart(
      body: _chunked(body, chunkSize),
      boundary: boundary,
      orig: orig,
      isAllowed: (ext) => const {'jpg', 'jpeg', 'png', 'mp4'}.contains(ext),
      kindOf: (ext) => ext == 'mp4' ? 'video' : 'image',
      findDup: (file, _) async {
        final id = knownSha[file.sha256];
        return id == null ? null : DupRecord(id: id, uploaderId: null);
      },
      insertAsset: (f) async {
        final id = nextId++;
        knownSha[f.sha256] = id;
        return id;
      },
    );

    final json = {
      'accepted': [
        for (final a in result.accepted) {'id': a.id, 'name': a.filename},
      ],
      'duplicates': result.duplicates,
      'rejected': result.rejected,
    };
    expect(json, {
      'accepted': [
        {'id': 1, 'name': 'a.jpg'},
        {'id': 2, 'name': 'b.png'},
      ],
      'duplicates': [
        {'name': 'a-again.jpg', 'from': '?'},
      ],
      'rejected': ['notes.exe（.exe 不支持）'],
    });

    expect(File(p.join(orig.path, '1.jpg')).readAsBytesSync(), photoA);
    expect(File(p.join(orig.path, '2.png')).readAsBytesSync(), photoB);
    expect(result.accepted[0].sha256, sha256.convert(photoA).toString());
    expect(orig.listSync().map((e) => p.basename(e.path)).toList()..sort(), [
      '1.jpg',
      '2.png',
    ]);
  });

  test('流式 multipart：空文件按落盘长度拒绝，多文件均正确落盘', () async {
    final photoA = _jpeg(8, 8, 10, 10, 200);
    final photoB = _jpeg(9, 8, 200, 10, 10);
    const boundary = '----EmptyAndTwo';
    final body = _multipart(boundary, [
      (name: 'files', filename: 'empty.jpg', data: Uint8List(0)),
      (name: 'files', filename: 'one.jpg', data: photoA),
      (name: 'files', filename: 'two.jpg', data: photoB),
    ]);

    var nextId = 10;
    final result = await ingestUploadMultipart(
      body: _chunked(body, 7),
      boundary: boundary,
      orig: orig,
      isAllowed: (ext) => ext == 'jpg',
      kindOf: (_) => 'image',
      findDup: (_, __) async => null,
      insertAsset: (f) async => nextId++,
    );

    expect(result.rejected, ['empty.jpg']);
    expect(
      result.accepted.map((a) => {'id': a.id, 'name': a.filename}).toList(),
      [
        {'id': 10, 'name': 'one.jpg'},
        {'id': 11, 'name': 'two.jpg'},
      ],
    );
    expect(File(p.join(orig.path, '10.jpg')).readAsBytesSync(), photoA);
    expect(File(p.join(orig.path, '11.jpg')).readAsBytesSync(), photoB);
    expect(result.accepted[0].size, photoA.length);
    expect(result.accepted[1].sha256, sha256.convert(photoB).toString());
  });

  test('缩略图在 isolate 中运行期间主 isolate 能继续响应异步任务', () async {
    final img = im.Image(width: 1400, height: 1000);
    for (var y = 0; y < img.height; y += 3) {
      for (var x = 0; x < img.width; x += 3) {
        img.setPixelRgb(x, y, x % 256, y % 256, (x + y) % 256);
      }
    }
    final bytes = Uint8List.fromList(im.encodeJpg(img, quality: 88));

    var ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 2), (_) {
      ticks++;
    });
    final result = await encodeThumbJpegOffload(bytes);
    timer.cancel();

    expect(result, isNotNull);
    expect((result!['jpeg'] as Uint8List).length, greaterThan(100));
    expect(result['width'], 1400);
    expect(result['height'], 1000);
    expect(ticks, greaterThan(0), reason: '若在主 isolate 同步解码，定时器在解码结束前不会触发');
  });

  test('报告预览图限制长边 1600，同时保留原始比例', () async {
    final source = im.Image(width: 2400, height: 1200);
    im.fill(source, color: im.ColorRgb8(90, 130, 160));
    final bytes = Uint8List.fromList(im.encodeJpg(source, quality: 88));
    final encoded = await encodeReportPreviewJpegOffload(bytes);
    expect(encoded, isNotNull);
    final decoded = im.decodeImage(encoded!);
    expect(decoded, isNotNull);
    expect(decoded!.width, 1600);
    expect(decoded.height, 800);
  });

  test('流式 multipart：preview / meta 附加 part 被解析，未知 part 安全忽略', () async {
    final heic = utf8.encode('fake-heic-bytes');
    final preview = _jpeg(20, 20, 90, 90, 90);
    const boundary = '----PreviewMeta';
    final body = _multipartFull(
      boundary,
      [
        (name: 'files', filename: 'IMG_1.HEIC', data: heic),
        (name: 'preview', filename: 'IMG_1.preview.jpg', data: preview),
        (name: 'unknown', filename: null, data: utf8.encode('x')),
      ],
      fields: {'meta': '{"IMG_1.HEIC": {"taken_at": 1770000000}}'},
    );

    final result = await ingestUploadMultipart(
      body: _chunked(body, 9),
      boundary: boundary,
      orig: orig,
      isAllowed: (ext) => const {'heic'}.contains(ext),
      kindOf: (_) => 'image',
      findDup: (_, __) async => null,
      insertAsset: (f) async => 5,
    );

    expect(result.accepted.single.filename, 'IMG_1.HEIC');
    expect(result.previewFile, isNotNull);
    expect(result.previewFile!.readAsBytesSync(), preview);
    expect(result.meta['IMG_1.HEIC'], {'taken_at': 1770000000});
    // 预览临时文件不在正式 orig 命名里（由调用方用完删除）
    expect(File(p.join(orig.path, '5.heic')).readAsBytesSync(), heic);
    await result.previewFile!.delete();
  });

  test('上传体中断：主文件收完也不入库，临时文件全清', () async {
    final photo = _jpeg(12, 10, 200, 40, 40);
    const boundary = '----BrokenUpload';
    final body = _multipartFull(
      boundary,
      [
        (name: 'files', filename: 'a.jpg', data: photo),
        (
          name: 'preview',
          filename: 'a.preview.jpg',
          data: List.filled(5000, 7),
        ),
      ],
      fields: {'meta': '{"a.jpg": {"taken_at": 1770000000}}'},
    );
    // 在 preview part 的数据中间截断：主文件已完整收到，附件没收完
    final cut = body.length - 1200;

    var inserted = 0;
    Stream<List<int>> broken() async* {
      yield body.sublist(0, cut);
      throw const SocketException('connection reset by peer');
    }

    await expectLater(
      ingestUploadMultipart(
        body: broken(),
        boundary: boundary,
        orig: orig,
        isAllowed: (ext) => ext == 'jpg',
        kindOf: (_) => 'image',
        findDup: (_, __) async => null,
        insertAsset: (f) async {
          inserted++;
          return inserted;
        },
      ),
      throwsA(isA<SocketException>()),
    );
    expect(inserted, 0, reason: '附件没收完就入库，重试会被 SHA 去重挡住，附件永远补不上');
    expect(orig.listSync(), isEmpty, reason: '中断后不应残留 _tmp_ 临时文件');
  });

  test('同作者重复上传携带附件：返回可补全项；跨作者仍算重复', () async {
    final heic = utf8.encode('fake-heic-bytes');
    final preview = _jpeg(20, 20, 90, 90, 90);
    const boundary = '----RetryRepair';
    final body = _multipartFull(
      boundary,
      [
        (name: 'files', filename: 'IMG_1.HEIC', data: heic),
        (name: 'preview', filename: 'p.jpg', data: preview),
        (
          name: 'live',
          filename: 'IMG_1.mp4',
          data: File('test/fixtures/live/sample.mp4').readAsBytesSync(),
        ),
      ],
      fields: {'meta': '{"IMG_1.HEIC": {"taken_at": 1770000000}}'},
    );

    Future<UploadIngestResult> run(int userId) => ingestUploadMultipart(
          body: _chunked(body, 13),
          boundary: boundary,
          orig: orig,
          userId: userId,
          isAllowed: (ext) => const {'heic'}.contains(ext),
          kindOf: (_) => 'image',
          findDup: (file, _) async =>
              file.sha256 == sha256.convert(heic).toString()
                  ? DupRecord(id: 7, uploaderId: 42)
                  : null,
          insertAsset: (_) async => throw StateError('不该再插入'),
        );

    final mine = await run(42);
    expect(
        mine.repaired.map((r) => r.id).toList(),
        [
          7,
        ],
        reason: '自己上次传了一半的作品，重试应能补附件');
    expect(mine.duplicates, isEmpty);
    expect(mine.accepted, isEmpty);
    // 自己的旧作品：附件临时文件交给调用方补附件用
    expect(mine.previewFile, isNotNull);
    expect(mine.liveFile, isNotNull);
    await mine.previewFile?.delete();
    await mine.liveFile?.delete();

    final other = await run(43);
    expect(other.repaired, isEmpty, reason: '不能给别人的作品补附件');
    expect(other.duplicates, [
      {'name': 'IMG_1.HEIC', 'from': '?'},
    ]);
    await other.previewFile?.delete();
    await other.liveFile?.delete();
    expect(orig.listSync().where((e) => e.path.contains('_tmp_')), isEmpty);
  });

  test('写盘 close 失败：不入库、清半成品、重传不被错误去重挡住', () async {
    final photo = _jpeg(12, 10, 200, 40, 40);
    const boundary = '----CloseFail';
    final body = _multipart(boundary, [
      (name: 'files', filename: 'a.jpg', data: photo),
    ]);
    final sha = sha256.convert(photo).toString();
    final known = <String, int>{};
    var inserted = 0;

    IOSink failingSink(File f) => _SinkThatFailsOnClose(f.openWrite());

    await expectLater(
      ingestUploadMultipart(
        body: _chunked(body, 8),
        boundary: boundary,
        orig: orig,
        isAllowed: (ext) => ext == 'jpg',
        kindOf: (_) => 'image',
        findDup: (file, _) async {
          final id = known[file.sha256];
          return id == null ? null : DupRecord(id: id);
        },
        insertAsset: (f) async {
          inserted++;
          known[f.sha256] = inserted;
          return inserted;
        },
        openSink: failingSink,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(inserted, 0, reason: '落盘失败不能入库');
    expect(orig.listSync(), isEmpty, reason: '半成品必须清掉');
    expect(known.containsKey(sha), isFalse, reason: '失败记录不能挡住重传');

    final ok = await ingestUploadMultipart(
      body: _chunked(body, 8),
      boundary: boundary,
      orig: orig,
      isAllowed: (ext) => ext == 'jpg',
      kindOf: (_) => 'image',
      findDup: (file, _) async {
        final id = known[file.sha256];
        return id == null ? null : DupRecord(id: id);
      },
      insertAsset: (f) async {
        inserted++;
        known[f.sha256] = inserted;
        return inserted;
      },
    );
    expect(ok.accepted, hasLength(1));
    expect(File(p.join(orig.path, '1.jpg')).readAsBytesSync(), photo);
  });

  test('KeyedMutex：同 key 串行、不同 key 并行', () async {
    final m = KeyedMutex();
    final log = <String>[];
    Future<void> section(String key, String tag, int ms) =>
        m.run(key, () async {
          log.add('$tag+');
          await Future<void>.delayed(Duration(milliseconds: ms));
          log.add('$tag-');
        });
    await Future.wait([
      section('sha-a', 'a1', 30),
      section('sha-a', 'a2', 5),
      section('sha-b', 'b1', 10),
    ]);
    expect(
      log.indexOf('a2+'),
      greaterThan(log.indexOf('a1-')),
      reason: '同 key 的临界区必须等前一个结束',
    );
    expect(
      log.indexOf('b1+'),
      lessThan(log.indexOf('a1-')),
      reason: '不同 key 不应互相阻塞',
    );
  });

  test(
      'bounded queue rejects overflow and expires waiters without releasing active work',
      () async {
    final pool = BoundedTaskPool(
      1,
      maxQueued: 1,
      queueTimeout: const Duration(milliseconds: 30),
    );
    final release = Completer<void>();
    final active = pool.run(() => release.future);
    var expiredTaskRan = false;
    final waiting = pool.run(() async {
      expiredTaskRan = true;
    });
    final expires = expectLater(waiting, throwsA(isA<TaskPoolBusy>()));
    await expectLater(pool.run(() async {}), throwsA(isA<TaskPoolBusy>()));
    expect(pool.running, 1);
    await expires;
    expect(pool.queued, 0);
    expect(
      pool.running,
      1,
      reason: 'timeout must not free a still-running worker',
    );
    release.complete();
    await active;
    expect(expiredTaskRan, false);
    expect(await pool.run(() async => 42), 42);
    expect(pool.running, 0);
  });

  test('BoundedTaskPool：并发有上限，任务失败后名额仍释放', () async {
    final pool = BoundedTaskPool(2);
    var running = 0;
    var maxRunning = 0;
    var completed = 0;

    Future<void> work(int id) => pool.run(() async {
          running++;
          maxRunning = max(maxRunning, running);
          try {
            await Future<void>.delayed(const Duration(milliseconds: 15));
            if (id == 1) throw StateError('expected');
            completed++;
          } finally {
            running--;
          }
        });

    final tasks = [for (var i = 0; i < 6; i++) work(i)];
    await expectLater(tasks[1], throwsStateError);
    await Future.wait([tasks[0], ...tasks.skip(2)]);

    expect(maxRunning, 2);
    expect(completed, 5);
    expect(pool.running, 0);
    expect(pool.queued, 0);
  });

  test(
    'foreground image priority is bounded and never starves uploads',
    () async {
      final pool = BoundedTaskPool(1);
      final gate = Completer<void>();
      final first = pool.run(() => gate.future);
      final order = <String>[];
      final upload = pool.run(() async {
        order.add('upload');
      });
      final covers = [
        for (var i = 0; i < 5; i++)
          pool.run(() async {
            order.add('cover$i');
          }, priority: true),
      ];
      gate.complete();
      await Future.wait([first, upload, ...covers]);
      expect(order, [
        'cover0',
        'cover1',
        'cover2',
        'upload',
        'cover3',
        'cover4',
      ]);
      expect(pool.running, 0);
      expect(pool.queued, 0);
    },
  );

  test('人物脸框较小时原片解码失败，仍用已解码缩略图生成封面', () {
    final thumb = File(p.join(orig.path, 'thumb.jpg'))
      ..writeAsBytesSync(_jpeg(40, 40, 80, 120, 160));
    final unsupportedOrig = File(p.join(orig.path, 'source.heic'))
      ..writeAsBytesSync(utf8.encode('not-a-decodable-image'));
    final out = File(p.join(orig.path, 'person.jpg'));

    final ok = writePersonCover({
      'thumb': thumb.path,
      'orig': unsupportedOrig.path,
      'out': out.path,
      'ow': 40,
      'oh': 40,
      'x': 10,
      'y': 10,
      'w': 4,
      'h': 4,
    });

    expect(ok, isTrue);
    expect(out.lengthSync(), greaterThan(40));
    expect(im.decodeJpg(out.readAsBytesSync()), isNotNull);
  });

  test('Range 解析：a-b / a- / -n / 越界 / 非法', () {
    const len = 100;
    expect(parseRangeHeader('bytes=0-9', len), const RangeResult(0, 9));
    expect(parseRangeHeader('bytes=90-', len), const RangeResult(90, 99));
    // AVPlayer 探测首两字节
    expect(parseRangeHeader('bytes=0-1', len), const RangeResult(0, 1));
    // 后缀：最后 10 字节
    expect(parseRangeHeader('bytes=-10', len), const RangeResult(90, 99));
    // 后缀超过文件长：从头给
    expect(parseRangeHeader('bytes=-500', len), const RangeResult(0, 99));
    // end 超界截到末尾
    expect(parseRangeHeader('bytes=50-999', len), const RangeResult(50, 99));
    // 越界起点 → 416
    expect(parseRangeHeader('bytes=100-', len), const RangeResult.invalid());
    expect(parseRangeHeader('bytes=105-110', len), const RangeResult.invalid());
    // 非法 / 多段 → 忽略按整文件
    expect(parseRangeHeader('bytes=abc', len), isNull);
    expect(parseRangeHeader('bytes=5-2', len), const RangeResult.invalid());
    expect(parseRangeHeader('bytes=0-9,20-29', len), const RangeResult(0, 9));
  });
}

Uint8List _jpeg(int w, int h, int r, int g, int b) {
  final img = im.Image(width: w, height: h);
  im.fill(img, color: im.ColorRgb8(r, g, b));
  return Uint8List.fromList(im.encodeJpg(img, quality: 90));
}

List<int> _multipart(
  String boundary,
  List<({String name, String filename, List<int> data})> parts,
) {
  final out = BytesBuilder();
  for (final part in parts) {
    out.add(utf8.encode('--$boundary\r\n'));
    out.add(
      utf8.encode(
        'Content-Disposition: form-data; name="${part.name}"; filename="${part.filename}"\r\n\r\n',
      ),
    );
    out.add(part.data);
    out.add(utf8.encode('\r\n'));
  }
  out.add(utf8.encode('--$boundary--\r\n'));
  return out.takeBytes();
}

Stream<List<int>> _chunked(List<int> data, int size) async* {
  for (var i = 0; i < data.length; i += size) {
    yield data.sublist(i, min(i + size, data.length));
  }
}

/// 带普通字段（无 filename）的 multipart 构造。
List<int> _multipartFull(
  String boundary,
  List<({String name, String? filename, List<int> data})> parts, {
  Map<String, String> fields = const {},
}) {
  final out = BytesBuilder();
  for (final part in parts) {
    out.add(utf8.encode('--$boundary\r\n'));
    final fn = part.filename == null ? '' : '; filename="${part.filename}"';
    out.add(
      utf8.encode(
        'Content-Disposition: form-data; name="${part.name}"$fn\r\n\r\n',
      ),
    );
    out.add(part.data);
    out.add(utf8.encode('\r\n'));
  }
  fields.forEach((k, v) {
    out.add(utf8.encode('--$boundary\r\n'));
    out.add(
      utf8.encode('Content-Disposition: form-data; name="$k"\r\n\r\n$v\r\n'),
    );
  });
  out.add(utf8.encode('--$boundary--\r\n'));
  return out.takeBytes();
}

class _SinkThatFailsOnClose implements IOSink {
  _SinkThatFailsOnClose(this._inner);
  final IOSink _inner;

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future addStream(Stream<List<int>> stream) => _inner.addStream(stream);

  @override
  Future flush() => _inner.flush();

  @override
  Future close() async {
    await _inner.close();
    throw const FileSystemException('simulated close failure');
  }

  @override
  Future get done => _inner.done;

  @override
  void write(Object? object) => _inner.write(object);

  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
}
