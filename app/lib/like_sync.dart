/// 点赞意图：双击只表示赞，按钮才切换。在途请求合并，失败回滚到服务端确认值。
library;

class LikeTarget {
  LikeTarget({required this.liked, required this.likes});
  bool liked;
  int likes;
}

class LikeCoordinator {
  final _inflight = <int>{};
  final _wanted = <int, bool>{};
  final _confirmedLiked = <int, bool>{};
  final _confirmedLikes = <int, int>{};

  bool get isBusy => _inflight.isNotEmpty;

  bool inflightFor(int id) => _inflight.contains(id);

  /// [ensureLiked]=true：双击。已经是赞则忽略；在途时只记下「要赞」。
  /// 按钮切换在途时直接忽略，避免连点打成反向。
  Future<void> apply({
    required int id,
    required LikeTarget item,
    required bool ensureLiked,
    required Future<Map<String, dynamic>> Function(int id, {bool? liked}) send,
    required void Function() onChanged,
    required void Function(Object error) onError,
  }) async {
    _confirmedLiked.putIfAbsent(id, () => item.liked);
    _confirmedLikes.putIfAbsent(id, () => item.likes);

    if (ensureLiked) {
      if (item.liked && !_inflight.contains(id)) return;
      if (!item.liked) {
        item.liked = true;
        item.likes += 1;
        onChanged();
      }
      _wanted[id] = true;
    } else {
      if (_inflight.contains(id)) return;
      item.liked = !item.liked;
      item.likes += item.liked ? 1 : -1;
      if (item.likes < 0) item.likes = 0;
      onChanged();
      _wanted[id] = item.liked;
    }

    if (_inflight.contains(id)) return;
    _inflight.add(id);
    try {
      while (true) {
        final want = _wanted[id];
        final r = await send(id, liked: want);
        final liked = r['liked'] == true;
        final likes = (r['likes'] as num?)?.toInt() ?? item.likes;
        _confirmedLiked[id] = liked;
        _confirmedLikes[id] = likes;
        final still = _wanted[id];
        if (still == null || still == want || still == liked) {
          item.liked = liked;
          item.likes = likes;
          _wanted.remove(id);
          onChanged();
          break;
        }
      }
    } catch (e) {
      item.liked = _confirmedLiked[id] ?? item.liked;
      item.likes = _confirmedLikes[id] ?? item.likes;
      _wanted.remove(id);
      onChanged();
      onError(e);
    } finally {
      _inflight.remove(id);
    }
  }
}

bool feedPlayable({
  required bool active,
  required bool routeCurrent,
  required bool foreground,
}) =>
    active && routeCurrent && foreground;
