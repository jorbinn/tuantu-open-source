import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/transfer.dart';
import 'package:tuantu_app/upload_prep.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const native = MethodChannel('dev.tuantu/live_photo');
  late Directory dir;
  bool badDocuments = false;
  Completer<void>? gate;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tuantu-enqueue-test-');
    badDocuments = false;
    gate = null;
    TransferStore.I.jobs.clear();
    Api.I.configure('http://synthetic-box-a.test', 'synthetic-a');
    Api.I.boxId = 'a';
    Api.I.userId = 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (call) async {
      if (call.method == 'getApplicationSupportDirectory') {
        return '${dir.path}/support';
      }
      return badDocuments ? '${dir.path}/not-a-directory/sub' : dir.path;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (call) async {
      await gate?.future;
      return null;
    });
  });
  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    TransferStore.I.jobs.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, null);
    await dir.delete(recursive: true);
  });
  Future<PickedMedia> item() async {
    final source =
        await File('${dir.path}/original.heic').writeAsString('original');
    return PickedMedia(
        path: source.path,
        name: 'synthetic.heic',
        day: '2026-09-22',
        isVideo: false,
        size: 8);
  }

  test('入队持久化保留原身份；复制期间换盒子不能重定向任务', () async {
    gate = Completer<void>();
    final media = await item();
    final add = TransferStore.I.addPersistent([media]);
    Api.I.configure('http://synthetic-box-b.test', 'synthetic-b');
    Api.I.boxId = 'b';
    Api.I.userId = 2;
    gate!.complete();
    final jobs = await add;
    expect(jobs.single.boxId, 'a');
    expect(jobs.single.sessionUserId, 1);
    expect(jobs.single.targetToken, 'synthetic-a');
    expect(jobs.single.stageId, isNotNull);
    final persisted =
        jsonDecode(await File('${dir.path}/transfers.json').readAsString())
            as List;
    expect(persisted.single['boxId'], 'a');
    await File(media.path).delete();
    expect(await File(jobs.single.path).readAsString(), 'original');
  });
  test('历史写入失败时不留下可发送任务，清理本次副本且不删原片', () async {
    final media = await item();
    await File('${dir.path}/not-a-directory').writeAsString('file');
    badDocuments = true;
    await expectLater(TransferStore.I.addPersistent([media]),
        throwsA(isA<FileSystemException>()));
    expect(TransferStore.I.jobs, isEmpty);
    expect(await File(media.path).exists(), isTrue);
    expect(await Directory('${dir.path}/support/UploadJobs').list().toList(),
        isEmpty);
  });
  test('历史裁剪保留有持久文件的失败任务和正在落盘的任务', () {
    for (var i = 0; i < 310; i++) {
      TransferStore.I.jobs.add(TransferJob(
          id: '$i',
          path: '/synthetic',
          name: '$i',
          createdAt: i,
          state: i == 0
              ? 'failed'
              : i == 1
                  ? 'staging'
                  : 'done',
          stageId: i == 0 ? 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' : null));
    }
    TransferStore.I.trimHistory();
    expect(TransferStore.I.jobs.length, 300);
    expect(TransferStore.I.jobs.any((j) => j.id == '0'), isTrue);
    expect(TransferStore.I.jobs.any((j) => j.id == '1'), isTrue);
  });
  test('清理只针对选择器明确拥有的导出文件', () async {
    final original = await item();
    final exported =
        await File('${dir.path}/owned.mov').writeAsString('export');
    final media = PickedMedia(
        path: original.path,
        name: original.name,
        day: original.day,
        isVideo: false,
        size: 8,
        ownedFiles: [exported.path]);
    await media.releaseOwnedFiles();
    expect(await File(original.path).exists(), isTrue);
    expect(await exported.exists(), isFalse);
  });
}
