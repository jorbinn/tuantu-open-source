import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tuantu_app/box/box_db.dart';
import 'package:tuantu_app/box/ios_box_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  const channel = MethodChannel('dev.tuantu/box');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tuantu_local_box_');
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  test(
      'native privacy failure does not open a database or create fallback files',
      () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
          code: 'box_storage', message: 'backup flag failed');
    });
    await expectLater(
        prepareIosBoxStorage(), throwsA(isA<PlatformException>()));
    expect(await root.list().toList(), isEmpty);
  });

  test('missing privacy confirmation or unsafe path fails closed', () async {
    for (final value in [
      null,
      {'path': root.path},
      {'path': root.path, 'backupExcluded': false},
      {'path': '/', 'backupExcluded': true},
      {'path': 'relative', 'backupExcluded': true},
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => value);
      await expectLater(prepareIosBoxStorage(), throwsStateError);
    }
  });

  test(
      'verified existing native directory is used without a second storage lookup',
      () async {
    messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
              'path': root.path,
              'backupExcluded': true,
            });
    // iOS uses POSIX absolute paths; this suite runs on the macOS validator.
    if (!Platform.isWindows) {
      expect((await prepareIosBoxStorage()).path, root.path);
    }
  });

  test('co-located SQLite and sidecars persist box identity across reopen',
      () async {
    final db = await BoxDb.openIn(root, databaseInRoot: true);
    final id = await db.ensureBoxId();
    final token = await db.ensureDeviceUser('ios-host', '团长');
    expect(await File('${root.path}/tuantu.db').exists(), true);
    final files = await root.list().toList();
    expect(files.every((file) => file.parent.path == root.path), true);
    await db.close();
    final reopened = await BoxDb.openIn(root, databaseInRoot: true);
    try {
      expect(await reopened.ensureBoxId(), id);
      expect(await reopened.ensureDeviceUser('ios-host', '改名'), token);
    } finally {
      await reopened.close();
    }
  });
}
