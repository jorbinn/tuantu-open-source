import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/upload_prep.dart';

void main() {
  test('iOS 资源 ID 含斜杠时预览文件名仍是单层安全名', () {
    const id = 'A1B2C3D4-E5F6-7890/L0/001';
    final name = compatiblePreviewFileName(id, nowMs: 1700000000000);
    expect(name.contains('/'), isFalse);
    expect(name.contains('\\'), isFalse);
    expect(name, startsWith('tuantu_preview_'));
    expect(name, endsWith('_1700000000000.jpg'));
    expect(name, isNot(contains('L0')));
  });

  test('不同资源 ID 同一时刻也不会撞名', () {
    final a = compatiblePreviewFileName('foo/L0/001', nowMs: 1);
    final b = compatiblePreviewFileName('foo_L0_001', nowMs: 1);
    expect(a, isNot(b));
  });

  test('Motion Photo 临时视频名安全且同一资源保持稳定', () {
    const id = 'A1B2C3D4-E5F6-7890/L0/001';
    final a = motionPreviewFileName(id);
    final b = motionPreviewFileName(id);
    expect(a, b);
    expect(a.contains('/'), isFalse);
    expect(a.contains('\\'), isFalse);
    expect(a, startsWith('tuantu_motion_preview_'));
    expect(a, endsWith('.mp4'));
  });
}
