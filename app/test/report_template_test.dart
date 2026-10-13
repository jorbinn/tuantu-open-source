import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/report/report_template.dart';

void main() {
  test('景点库包含 20 个独立底景，文件均随应用提供', () {
    expect(reportScenes, hasLength(20));
    expect(reportScenes.map((scene) => scene.id).toSet(), hasLength(20));
    for (final scene in reportScenes) {
      expect(File(scene.asset).existsSync(), isTrue, reason: scene.name);
    }
  });

  test('七类四图版式具备稳定槽位且不侵入数据区', () {
    expect(reportLayouts, hasLength(7));
    for (final layout in reportLayouts) {
      expect(layout.slots, hasLength(4), reason: layout.name);
      for (final slot in layout.slots) {
        expect(slot.rect.left, greaterThanOrEqualTo(0));
        expect(slot.rect.right, lessThanOrEqualTo(1080));
        expect(slot.rect.top, greaterThanOrEqualTo(0));
        expect(slot.rect.bottom, lessThanOrEqualTo(835));
      }
    }
  });
}
