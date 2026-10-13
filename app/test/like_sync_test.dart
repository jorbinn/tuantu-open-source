import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/like_sync.dart';

void main() {
  test('连续双击只会保持赞，不会变成取消', () async {
    final item = LikeTarget(liked: false, likes: 0);
    final coord = LikeCoordinator();
    final gate = Completer<Map<String, dynamic>>();
    var sends = 0;
    final first = coord.apply(
      id: 1,
      item: item,
      ensureLiked: true,
      send: (id, {liked}) async {
        sends++;
        expect(liked, isTrue);
        return gate.future;
      },
      onChanged: () {},
      onError: (e) => fail('$e'),
    );
    expect(item.liked, isTrue);
    expect(item.likes, 1);
    await coord.apply(
      id: 1,
      item: item,
      ensureLiked: true,
      send: (id, {liked}) async => fail('第二下不应再发切换'),
      onChanged: () {},
      onError: (e) => fail('$e'),
    );
    gate.complete({'liked': true, 'likes': 1});
    await first;
    expect(sends, 1);
    expect(item.liked, isTrue);
    expect(item.likes, 1);
  });

  test('按钮在途时连点被忽略，失败回滚到确认值', () async {
    final item = LikeTarget(liked: false, likes: 0);
    final coord = LikeCoordinator();
    final gate = Completer<Map<String, dynamic>>();
    final first = coord.apply(
      id: 7,
      item: item,
      ensureLiked: false,
      send: (id, {liked}) => gate.future,
      onChanged: () {},
      onError: (_) {},
    );
    expect(item.liked, isTrue);
    await coord.apply(
      id: 7,
      item: item,
      ensureLiked: false,
      send: (id, {liked}) async => fail('在途按钮不应再切换'),
      onChanged: () {},
      onError: (_) {},
    );
    expect(item.liked, isTrue);
    gate.completeError('timeout');
    await first;
    expect(item.liked, isFalse);
    expect(item.likes, 0);
  });

  test('在途取消时双击会改成赞', () async {
    final item = LikeTarget(liked: true, likes: 1);
    final coord = LikeCoordinator();
    final firstGate = Completer<Map<String, dynamic>>();
    var second = false;
    final unlike = coord.apply(
      id: 3,
      item: item,
      ensureLiked: false,
      send: (id, {liked}) async {
        if (!second) {
          expect(liked, isFalse);
          return firstGate.future;
        }
        expect(liked, isTrue);
        return {'liked': true, 'likes': 1};
      },
      onChanged: () {},
      onError: (e) => fail('$e'),
    );
    expect(item.liked, isFalse);
    await coord.apply(
      id: 3,
      item: item,
      ensureLiked: true,
      send: (id, {liked}) async => fail('应并入在途请求'),
      onChanged: () {},
      onError: (e) => fail('$e'),
    );
    expect(item.liked, isTrue);
    second = true;
    firstGate.complete({'liked': false, 'likes': 0});
    await unlike;
    expect(item.liked, isTrue);
    expect(item.likes, 1);
  });

  test('播放资格要同时看条目、路由和应用前后台', () {
    expect(
      feedPlayable(active: true, routeCurrent: true, foreground: true),
      isTrue,
    );
    expect(
      feedPlayable(active: true, routeCurrent: false, foreground: true),
      isFalse,
    );
    expect(
      feedPlayable(active: true, routeCurrent: true, foreground: false),
      isFalse,
    );
    expect(
      feedPlayable(active: false, routeCurrent: true, foreground: true),
      isFalse,
    );
  });
}
