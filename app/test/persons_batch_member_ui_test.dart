/// 人物页多选后可一次标记为团员。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/pages/persons_page.dart';

class _PersonsAdapter implements HttpClientAdapter {
  _PersonsAdapter({this.people});

  final List<Map<String, dynamic>>? people;
  final requests = <Map<String, dynamic>>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.path.endsWith('/api/persons/members')) {
      requests.add(Map<String, dynamic>.from(options.data as Map));
      return _json({'ok': true, 'count': 2, 'status': 1});
    }
    if (options.path.endsWith('/api/persons')) {
      return _json(people ?? [
        _person(1, '甲'),
        _person(2, '乙'),
        _person(3, '丙'),
      ]);
    }
    return _json({'ok': true});
  }

  Map<String, dynamic> _person(
    int id,
    String name, {
    bool mine = false,
    int member = 0,
    List<Object> pending = const [],
  }) {
    return {
      'id': id,
      'name': name,
      'count': 3,
      'cover': null,
      'claimed_by_me': mine,
      'member': member,
      'pending': pending,
    };
  }

  ResponseBody _json(Object body) => ResponseBody.fromBytes(
        utf8.encode(jsonEncode(body)),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  testWidgets('人物按这是我、小伙伴们、其他人分组且卡片不显示状态图标',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final adapter = _PersonsAdapter();
    final people = [
      adapter._person(1, '本人', mine: true, member: 1),
      adapter._person(2, '朋友', member: 1),
      adapter._person(3, '路人', pending: const [
        {'user_id': 9}
      ]),
    ];
    final groupedAdapter = _PersonsAdapter(people: people);
    Api.I.configure('http://box.test:8000', 'token');
    Api.I.dio.httpClientAdapter = groupedAdapter;

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PersonsPage()),
    ));
    await _drain(tester);

    expect(find.text('这是我'), findsOneWidget);
    expect(find.text('小伙伴们'), findsOneWidget);
    expect(find.text('其他人'), findsOneWidget);
    expect(find.text('本人'), findsOneWidget,
        reason: '已认领人物即使也是团员，也只出现在「这是我」');
    expect(tester.getTopLeft(find.text('这是我')).dy,
        lessThan(tester.getTopLeft(find.text('小伙伴们')).dy));
    expect(tester.getTopLeft(find.text('小伙伴们')).dy,
        lessThan(tester.getTopLeft(find.text('其他人')).dy));
    expect(find.byIcon(Icons.group), findsNothing);
    expect(find.byIcon(Icons.help_outline), findsNothing);
  });

  testWidgets('长按后可多选人物并一次标记为团员', (tester) async {
    final adapter = _PersonsAdapter();
    Api.I.configure('http://box.test:8000', 'token');
    Api.I.dio.httpClientAdapter = adapter;

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PersonsPage()),
    ));
    await _drain(tester);

    Finder cards() => find.byWidgetPredicate(
        (widget) => widget is GestureDetector && widget.onLongPress != null);
    expect(cards(), findsNWidgets(3));
    await tester.longPress(cards().at(0));
    await tester.pump();
    await tester.tap(cards().at(1));
    await tester.pump();
    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));

    await tester.tap(find.text('团员'));
    await tester.pumpAndSettle();
    expect(find.text('批量标记 2 个人物'), findsOneWidget);
    await tester.tap(find.widgetWithText(SimpleDialogOption, '团员'));
    await _drain(tester);

    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single['ids'], unorderedEquals([1, 2]));
    expect(adapter.requests.single['status'], 1);
    expect(find.byIcon(Icons.check_circle), findsNothing,
        reason: '成功后退出多选状态');
  });

  testWidgets('无人物相册回调时轻点头像直接进入选择', (tester) async {
    final adapter = _PersonsAdapter();
    Api.I.configure('http://box.test:8000', 'token');
    Api.I.dio.httpClientAdapter = adapter;

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PersonsPage()),
    ));
    await _drain(tester);

    final cards = find.byWidgetPredicate(
        (widget) => widget is GestureDetector && widget.onLongPress != null);
    await tester.tap(cards.at(0));
    await tester.pump();

    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text('这是我'), findsOneWidget);
  });
}
