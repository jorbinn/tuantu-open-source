import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/pages/me_page.dart';

class _Box implements HttpClientAdapter {
  _Box([int n = 30]) : ids = [for (var i = n; i >= 1; i--) i];
  final List<int> ids;
  final deletes = <int>[];
  bool failDelete = false;

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

Finder _cells() => find.byWidgetPredicate((w) =>
    w is KeyedSubtree &&
    w.key is ValueKey<String> &&
    (w.key as ValueKey<String>).value.startsWith('me-cell-'));

int _idOf(Finder f) => int.parse(
    ((f.evaluate().first.widget.key as ValueKey<String>).value).split('-').last);

void main() {
  late _Box box;

  setUp(() {
    Api.listAttempts = 1;
    Api.I.configure('http://box.test:8000', 'token');
    Api.I.userId = 1;
    box = _Box(30);
    Api.I.dio.httpClientAdapter = box;
  });

  Future<MePageState> openMine(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: MePage()));
    await _drain(tester);
    return tester.state<MePageState>(find.byType(MePage));
  }

  testWidgets('cancel confirmation deletes nothing', (tester) async {
    final state = await openMine(tester);
    final before = [for (final c in state.items) c.id];
    final cell = _cells().hitTestable().first;
    final id = _idOf(cell);

    await tester.longPress(cell);
    await _drain(tester);
    expect(state.selecting, isTrue);
    expect(state.selected, {id});
    expect(find.text('删除（1）'), findsOneWidget);

    await tester.tap(find.text('删除（1）'));
    await tester.pumpAndSettle();
    expect(find.text('确定删除这 1 张照片？'), findsOneWidget);
    expect(find.text('删除后无法恢复'), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('取消'),
    ));
    await tester.pumpAndSettle();
    await _drain(tester);

    expect(box.deletes, isEmpty, reason: 'cancel must not hit the box');
    expect([for (final c in state.items) c.id], before);
    expect(state.selecting, isTrue, reason: 'still in multi-select after cancel');
    expect(state.selected, {id});
  });

  testWidgets('confirm deletes all selected in place', (tester) async {
    final state = await openMine(tester);
    final a = _cells().hitTestable().at(0);
    final b = _cells().hitTestable().at(1);
    final c = _cells().hitTestable().at(2);
    final ids = {_idOf(a), _idOf(b), _idOf(c)};

    await tester.longPress(a);
    await _drain(tester);
    await tester.tap(b);
    await _drain(tester);
    await tester.tap(c);
    await _drain(tester);
    expect(state.selected, ids);
    expect(find.text('删除（3）'), findsOneWidget);

    await tester.tap(find.text('删除（3）'));
    await tester.pumpAndSettle();
    expect(find.text('确定删除这 3 张照片？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    await _drain(tester);
    await tester.pump(const Duration(seconds: 3));
    await _drain(tester);

    expect(box.deletes.toSet(), ids);
    expect(state.items.any((e) => ids.contains(e.id)), isFalse);
    expect(state.selecting, isFalse);
    expect(state.selected, isEmpty);
    expect(state.me?['uploaded'], 27);
  });

  testWidgets('empty selection disables the delete button', (tester) async {
    final state = await openMine(tester);
    final cell = _cells().hitTestable().first;
    await tester.longPress(cell);
    await _drain(tester);
    expect(find.text('删除（1）'), findsOneWidget);

    // Deselect the only selected tile → 删除（0）, button disabled.
    await tester.tap(cell);
    await _drain(tester);
    expect(state.selected, isEmpty);
    expect(state.selecting, isTrue);
    expect(find.text('删除（0）'), findsOneWidget);

    final btn = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '删除（0）'));
    expect(btn.onPressed, isNull);

    // Tapping the disabled button must not open the dialog.
    await tester.tap(find.text('删除（0）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('确定删除'), findsNothing);
    expect(box.deletes, isEmpty);
  });

  testWidgets('other people\'s profile has no multi-select delete', (tester) async {
    // Simulate opening someone else's page: MePage(userId: 2).
    Api.I.userId = 1;
    box = _Box(12);
    Api.I.dio.httpClientAdapter = box;
    // user assets endpoint
    final orig = box;
    Api.I.dio.httpClientAdapter = _OtherBox(orig);

    await tester.pumpWidget(const MaterialApp(
      home: MePage(userId: 2, userName: '别人'),
    ));
    await _drain(tester);
    final state = tester.state<MePageState>(find.byType(MePage));
    expect(state.items, isNotEmpty);

    final cell = _cells().hitTestable().first;
    await tester.longPress(cell);
    await _drain(tester);

    expect(state.selecting, isFalse);
    expect(find.textContaining('删除（'), findsNothing);
    expect(find.text('取消'), findsNothing);
  });

  testWidgets('batch delete before all pages loaded skips nothing', (tester) async {
    box = _Box(600);
    Api.I.dio.httpClientAdapter = box;
    final state = await openMine(tester);
    // load 2 pages
    while (state.items.length < 180) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await _drain(tester);
    }
    expect(state.items.length, 180);
    final victims = [state.items[5], state.items[40], state.items[100]];
    state.selected
      ..clear()
      ..addAll(victims.map((c) => c.id));
    state.selecting = true;
    final done = state.deleteSelectedInPlace();
    await _drain(tester);
    await done;
    await tester.pump(const Duration(seconds: 3));
    await _drain(tester);

    expect(box.deletes.toSet(), victims.map((c) => c.id).toSet());
    expect(box.ids, hasLength(597));
    expect(state.offset, 177, reason: 'offset shifted by 3');

    for (var i = 0; i < 120 && !state.end; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
      await _drain(tester);
    }
    final got = [for (final c in state.items) c.id];
    expect(got.toSet().length, got.length);
    expect(got, hasLength(597));
    expect(got, box.ids);
  });
}

/// Routes /api/user/2/* and falls back to the shared me-shaped adapter fields.
class _OtherBox implements HttpClientAdapter {
  _OtherBox(this.inner);
  final _Box inner;

  @override
  void close({bool force = false}) => inner.close(force: force);

  @override
  Future<ResponseBody> fetch(
      RequestOptions o, Stream<Uint8List>? s, Future<void>? cancel) async {
    if (o.path == '/api/user/2') {
      return ResponseBody.fromString(
        jsonEncode({
          'id': 2,
          'name': '别人',
          'uploaded': inner.ids.length,
        }),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    if (o.path == '/api/user/2/assets') {
      final off = int.parse('${o.queryParameters['offset']}');
      final page = inner.ids.skip(off).take(90).toList();
      return ResponseBody.fromString(
        jsonEncode({
          'items': [
            for (final id in page)
              {
                'id': id,
                'thumb': '/thumb/$id',
                'has_thumb': 0,
                'kind': 'image',
                'ext': 'jpg',
                'taken_at': 1770000000 - id * 60,
                'uploader': '别人',
                'uploader_id': 2,
                'mine': false,
                'width': 100,
                'height': 100,
              }
          ],
          'offset': off + page.length,
          'end': off + page.length >= inner.ids.length,
        }),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return inner.fetch(o, s, cancel);
  }
}
