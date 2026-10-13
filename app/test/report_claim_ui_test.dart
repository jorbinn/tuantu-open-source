import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/pages/persons_page.dart';
import 'package:tuantu_app/pages/report_list_page.dart';

class _Adapter implements HttpClientAdapter {
  bool claimed = false;
  bool alreadyMine = false;
  bool fail = false;
  bool conflict = false;
  Completer<void>? pending;
  int daysReads = 0;
  final claims = <RequestOptions>[];
  final paths = <String>[];

  ResponseBody json(Object body, [int status = 200]) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    if (options.path == '/api/report/days') {
      daysReads++;
      return claimed
          ? json({
              'identity': {'name': '自己'},
              'days': [],
              'next': null,
            })
          : json({'code': 'claim_required'}, 409);
    }
    if (options.path == '/api/persons') {
      return json([
        for (var id = 1; id <= 3; id++)
          {
            'id': id,
            'name': '人物$id',
            'count': 3,
            'cover': null,
            'claimed_by_me': alreadyMine && id == 1,
            'member': 0,
          },
      ]);
    }
    if (options.path.endsWith('/claim')) {
      claims.add(options);
      await pending?.future;
      if (fail) return json({'error': 'test failure'}, 500);
      if (conflict) {
        return json({
          'conflict': {
            'my_person': {'id': 7, 'name': '旧人物'},
            'person_user': {'id': claims.length == 1 ? 9 : 10, 'name': '他人'},
            'person_member': 2,
          },
        }, 409);
      }
      claimed = true;
      return json({'ok': true, 'already': alreadyMine});
    }
    throw StateError('Unexpected request: ${options.path}');
  }

  @override
  void close({bool force = false}) {}
}

Future<void> drain(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<void> _open(WidgetTester tester, _Adapter adapter) async {
  Api.I.configure('http://claim.test:8000', 'token');
  Api.I.dio.httpClientAdapter = adapter;
  await tester.pumpWidget(const MaterialApp(home: ReportListPage()));
  await drain(tester);
  await tester.tap(find.text('去认领「这是我」'));
  await drain(tester);
  expect(
    tester.widget<PersonsPage>(find.byType(PersonsPage)).claimOnly,
    isTrue,
  );
}

Finder avatar(int id) => find.byKey(ValueKey('person-$id'));
Finder confirm() => find.widgetWithText(FilledButton, '确认');

void main() {
  testWidgets('报告认领只单选头像，确认后自动返回并刷新', (tester) async {
    final adapter = _Adapter();
    await _open(tester, adapter);
    expect(tester.widget<FilledButton>(confirm()).onPressed, isNull);
    for (final label in ['重命名', '合并', '团员', '这不是我']) {
      expect(find.text(label), findsNothing);
    }
    expect(tester.widget<GestureDetector>(avatar(1)).onLongPress, isNull);
    await tester.tap(avatar(1));
    await tester.pump();
    await tester.tap(avatar(2));
    await tester.pump();
    await tester.tap(avatar(2));
    await tester.pump();
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(
      find.descendant(of: avatar(2), matching: find.byIcon(Icons.check_circle)),
      findsOneWidget,
    );
    expect(adapter.claims, isEmpty, reason: '选中头像不提交请求');
    await tester.tap(confirm());
    await drain(tester);
    expect(adapter.claims.single.path, '/api/persons/2/claim');
    expect(find.byType(PersonsPage), findsNothing);
    expect(adapter.daysReads, 2);
    expect(find.text('第一张，就能开始'), findsOneWidget);
  });

  testWidgets('提交中禁用确认及换选，失败可在原页重试', (tester) async {
    final adapter = _Adapter()..fail = true;
    adapter.pending = Completer<void>();
    await _open(tester, adapter);
    await tester.tap(avatar(1));
    await tester.pump();
    await tester.tap(confirm());
    await drain(tester);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认中…'))
          .onPressed,
      isNull,
    );
    expect(tester.widget<GestureDetector>(avatar(2)).onTap, isNull);
    expect(adapter.claims, hasLength(1));
    adapter.pending!.complete();
    await drain(tester);
    expect(find.byType(PersonsPage), findsOneWidget);
    expect(tester.widget<FilledButton>(confirm()).onPressed, isNotNull);
    adapter.fail = false;
    await tester.tap(confirm());
    await drain(tester);
    expect(adapter.claims, hasLength(2));
    expect(find.byType(PersonsPage), findsNothing);
  });

  testWidgets('已认领自己的头像再次确认不会取消认领', (tester) async {
    final adapter = _Adapter()..alreadyMine = true;
    await _open(tester, adapter);
    await tester.tap(avatar(1));
    await tester.pump();
    await tester.tap(confirm());
    await drain(tester);
    expect(adapter.claims, hasLength(1));
    expect(adapter.paths.any((p) => p.endsWith('/unclaim')), isFalse);
    expect(find.byType(PersonsPage), findsNothing);
  });

  testWidgets('冲突需明确同意，状态变更后重新确认而非覆盖', (tester) async {
    final adapter = _Adapter()..conflict = true;
    await _open(tester, adapter);
    await tester.tap(avatar(1));
    await tester.pump();
    await tester.tap(confirm());
    await drain(tester);
    expect(find.textContaining('会解除 他人'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '认领'));
    await drain(tester);
    expect(adapter.claims, hasLength(2));
    expect(adapter.claims.last.data, containsPair('confirm', true));
    expect(adapter.claims.last.data, containsPair('expect_my_person', 7));
    expect(adapter.claims.last.data, containsPair('expect_person_user', 9));
    expect(find.text('认领这个人物？'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await drain(tester);
    expect(adapter.claims, hasLength(2));
    expect(find.byType(PersonsPage), findsOneWidget);
    expect(adapter.claimed, isFalse);
    expect(tester.widget<FilledButton>(confirm()).onPressed, isNotNull);
  });

  testWidgets('等待认领时返回，不会在响应后误退报告页', (tester) async {
    final adapter = _Adapter()..pending = Completer<void>();
    await _open(tester, adapter);
    await tester.tap(avatar(1));
    await tester.pump();
    await tester.tap(confirm());
    await drain(tester);
    await tester.pageBack();
    await drain(tester);
    adapter.pending!.complete();
    await drain(tester);
    expect(find.byType(ReportListPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
