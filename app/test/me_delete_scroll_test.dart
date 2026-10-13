import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/pages/me_page.dart';

/// 盒子上 300 张自己的作品，按 offset 分页，每页 90。
class _Box implements HttpClientAdapter {
  final ids = [for (var i = 300; i >= 1; i--) i];
  bool failDelete = false;
  final deletes = <int>[];
  final assetOffsets = <int>[];

  Map<String, Object?> _item(int id) => {
        'id': id,
        'thumb': '/thumb/$id',
        'has_thumb': 0,
        'kind': 'image',
        'ext': 'jpg',
        'taken_at': 1770000000 - id * 60,
        'uploader': '我',
        'mine': true,
        'width': 100,
        'height': 100,
      };

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
      RequestOptions o, Stream<Uint8List>? s, Future<void>? cancel) async {
    Object data;
    var code = 200;
    if (o.method == 'DELETE') {
      final id = int.parse(o.path.split('/').last);
      deletes.add(id);
      if (failDelete) {
        code = 409;
        data = {'detail': '盒子忙'};
      } else {
        ids.remove(id);
        data = {'ok': true};
      }
    } else if (o.path == '/api/me') {
      data = {'id': 1, 'name': '我', 'uploaded': ids.length};
    } else if (o.path == '/api/me/assets') {
      final off = int.parse('${o.queryParameters['offset']}');
      assetOffsets.add(off);
      final page = ids.skip(off).take(90).toList();
      data = {
        'items': [for (final id in page) _item(id)],
        'offset': off + page.length,
        'end': off + page.length >= ids.length,
      };
    } else {
      data = {};
    }
    return ResponseBody.fromString(jsonEncode(data), code, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }
}

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Finder _visibleCells() => find
    .byWidgetPredicate((w) =>
        w is KeyedSubtree &&
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('me-cell-'))
    .hitTestable();

int _idOf(Finder f) =>
    int.parse(((f.evaluate().first.widget.key as ValueKey<String>).value)
        .split('-')
        .last);

void main() {
  late _Box box;
  setUp(() {
    Api.listAttempts = 1;
    Api.I.configure('http://box.test:8000', 'token');
    box = _Box();
    Api.I.dio.httpClientAdapter = box;
  });

  Future<ScrollPosition> openDeep(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: MePage()));
    await _drain(tester);
    final scrollable = find.byType(Scrollable).first;
    // 往下滑到第二、三页（超过第一页的 90 张）。
    for (var i = 0; i < 12; i++) {
      await tester.drag(scrollable, const Offset(0, -700));
      await _drain(tester);
    }
    final state = tester.state<MePageState>(find.byType(MePage));
    expect(state.items.length, greaterThan(90));
    return tester.state<ScrollableState>(scrollable).position;
  }

  Future<void> longPressDelete(WidgetTester tester, Finder cell) async {
    await tester.longPress(cell);
    await _drain(tester);
    // 长按进入多选 → 底部「删除（N）」→ 二次确认。
    await tester.tap(find.textContaining('删除（'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    await _drain(tester);
  }

  testWidgets('long-press delete keeps scroll offset and loaded pages',
      (tester) async {
    final pos = await openDeep(tester);
    final before = pos.pixels;
    expect(before, greaterThan(3000));
    final state = tester.state<MePageState>(find.byType(MePage));
    final loaded = state.items.length;
    final cell = _visibleCells().at(5);
    final id = _idOf(cell);

    await longPressDelete(tester, cell);
    await tester.pump(const Duration(seconds: 3)); // toast
    await _drain(tester);

    expect(box.deletes, [id]);
    expect(pos.pixels, before, reason: 'scroll offset must not jump');
    expect(state.items.any((c) => c.id == id), isFalse);
    expect(state.items.length, loaded - 1,
        reason: 'loaded pages must not be truncated to the first page');
    expect(find.text('作品 299'), findsNothing); // 头部在屏幕外，只检查状态
    expect(state.me?['uploaded'], 299);

    // 继续往下翻：下一页从正确的 offset 开始，没有重复也没有漏项。
    for (var i = 0; i < 30 && !state.end; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
      await _drain(tester);
    }
    final got = [for (final c in state.items) c.id];
    expect(got.toSet().length, got.length);
    expect(got, box.ids);
  });

  testWidgets('failed delete restores the item in place without jumping',
      (tester) async {
    final pos = await openDeep(tester);
    final before = pos.pixels;
    final state = tester.state<MePageState>(find.byType(MePage));
    final order = [for (final c in state.items) c.id];
    box.failDelete = true;
    final cell = _visibleCells().at(3);
    final id = _idOf(cell);

    await longPressDelete(tester, cell);
    expect(find.textContaining('盒子忙'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await _drain(tester);

    expect(box.deletes, [id]);
    expect(pos.pixels, before);
    expect([for (final c in state.items) c.id], order);
  });

  testWidgets('deleting the last item of the list clamps without errors',
      (tester) async {
    box.ids
      ..clear()
      ..addAll([3, 2, 1]);
    await tester.pumpWidget(const MaterialApp(home: MePage()));
    await _drain(tester);
    final state = tester.state<MePageState>(find.byType(MePage));
    for (final c in [...state.items]) {
      final done = state.deleteInPlace(c);
      await _drain(tester);
      await done;
    }
    await tester.pump(const Duration(seconds: 3));
    await _drain(tester);
    expect(tester.takeException(), isNull);
    expect(state.items, isEmpty);
    expect(find.text('还没有作品'), findsOneWidget);
  });

  /// 600 张，只加载前 [pages] 页就删除。
  Future<MePageState> openFirstPage(WidgetTester tester, {int pages = 1}) async {
    box.ids
      ..clear()
      ..addAll([for (var i = 600; i >= 1; i--) i]);
    await tester.pumpWidget(const MaterialApp(home: MePage()));
    await _drain(tester);
    final state = tester.state<MePageState>(find.byType(MePage));
    while (state.items.length < pages * 90) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await _drain(tester);
    }
    expect(state.items.length, pages * 90,
        reason: 'only the first $pages page(s) loaded');
    expect(state.end, isFalse);
    return state;
  }

  Future<void> scrollToEnd(WidgetTester tester, MePageState state) async {
    for (var i = 0; i < 120 && !state.end; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
      await _drain(tester);
    }
    expect(state.end, isTrue);
  }

  for (final pages in [1, 2]) {
    testWidgets(
        'delete with $pages of 7 pages loaded: later pages skip nothing',
        (tester) async {
      final state = await openFirstPage(tester, pages: pages);
      final victim = state.items[10];
      final done = state.deleteInPlace(victim);
      await _drain(tester);
      await done;
      await tester.pump(const Duration(seconds: 3)); // toast
      await _drain(tester);
      expect(box.deletes, [victim.id]);
      expect(box.ids, hasLength(599));
      if (pages > 1) {
        expect(state.offset, pages * 90 - 1,
            reason: 'next page starts one earlier to cover the removed slot');
      }

      await scrollToEnd(tester, state);
      final got = [for (final c in state.items) c.id];
      expect(got.toSet().length, got.length, reason: 'no duplicates');
      expect(got, hasLength(599), reason: '599 on the box → 599 shown');
      expect(got, box.ids);
    });
  }

  testWidgets('failed delete before all pages are loaded restores the offset',
      (tester) async {
    final state = await openFirstPage(tester, pages: 2);
    final order = [for (final c in state.items) c.id];
    box.failDelete = true;
    final done = state.deleteInPlace(state.items[10]);
    await _drain(tester);
    await done;
    expect(find.textContaining('盒子忙'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await _drain(tester);
    expect([for (final c in state.items) c.id], order,
        reason: 'item restored at the same index');
    expect(state.offset, 180, reason: 'offset shift undone');

    box.failDelete = false;
    await scrollToEnd(tester, state);
    final got = [for (final c in state.items) c.id];
    expect(got.toSet().length, got.length);
    expect(got, hasLength(600));
    expect(got, box.ids);
  });
}
