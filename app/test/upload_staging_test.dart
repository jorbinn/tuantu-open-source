import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/upload_staging.dart';

void main() {
  late Directory temp;
  late Directory cache;
  late UploadStaging storage;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tuantu-stage-test-');
    cache = await Directory('${temp.path}/cache').create();
    storage = UploadStaging(Directory('${temp.path}/support/UploadJobs'));
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  test('缓存清理后原片、Live 视频、封面仍完整；沙盒换路径可恢复', () async {
    final paths = <String, String>{};
    for (final key in ['path', 'livePath', 'previewPath']) {
      paths[key] =
          (await File('${cache.path}/$key.mov').writeAsString('$key-data'))
              .path;
    }
    final staged = await storage.copy({...paths, 'liveRequired': true});
    await cache.delete(recursive: true);
    for (final key in paths.keys) {
      expect(await File(staged[key]).readAsString(), '$key-data');
    }
    final relocatedRoot = '${temp.path}/new-sandbox/UploadJobs';
    await Directory('${temp.path}/new-sandbox').create();
    await storage.root.rename(relocatedRoot);
    final relocated = UploadStaging(Directory(relocatedRoot));
    for (final key in paths.keys) {
      expect(
          await File(relocated.resolve(staged['stageId'], staged[key]))
              .readAsString(),
          '$key-data');
    }
    await relocated.remove(staged['stageId']);
    expect(await Directory('$relocatedRoot/${staged['stageId']}').exists(),
        isFalse);
  });
  test('附件缺失时整项回滚，不删相册原片', () async {
    final still =
        await File('${cache.path}/still.heic').writeAsString('original');
    await expectLater(
        storage.copy({
          'path': still.path,
          'livePath': '${cache.path}/missing.mov',
          'liveRequired': true
        }),
        throwsA(isA<FileSystemException>()));
    expect(await still.readAsString(), 'original');
    expect(await storage.root.list().toList(), isEmpty);
  });
  test('无效 stage ID 不允许删除或读取其它目录', () async {
    final original = await File('${cache.path}/original').writeAsString('keep');
    await storage.remove('../../cache');
    expect(() => storage.resolve('../../cache', 'original'),
        throwsFormatException);
    expect(await original.exists(), isTrue);
  });
}
