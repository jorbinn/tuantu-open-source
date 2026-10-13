import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/download.dart';

CardItem _card(int id, {bool live = false}) => CardItem({
  'id': id,
  'thumb': '/api/asset/$id/thumb',
  'kind': 'image',
  'ext': 'jpg',
  'orig_name': 'IMG_$id.jpg',
  'has_thumb': 1,
  'uploader': '小明',
  'liked': false,
  'mine': false,
  'width': 100,
  'height': 80,
  'likes': 0,
  'comments': 0,
  'has_live': live ? 1 : 0,
  'live_ready': live ? 1 : 0,
  if (live) 'live_pts': 456000,
  'taken_at': 1780000000,
});

void main() {
  setUp(() {
    Api.I.configure('http://box.test:8000', 'token');
    Api.I.boxId = 'box-1';
    DownloadStore.I.resetForTest();
  });

  tearDown(() => DownloadStore.I.resetForTest());

  test('下载任务持久化保留 Live 信息和目标盒子', () {
    final added = DownloadStore.I.add(_card(7, live: true));
    final restored = DownloadJob.fromJson(added.job.toJson());
    expect(restored.assetId, 7);
    expect(restored.hasLive, isTrue);
    expect(restored.livePts, 456000);
    expect(restored.targetBase, 'http://box.test:8000');
    expect(restored.boxId, 'box-1');
    expect(restored.toCardItem().hasLive, isTrue);
  });

  test('同一盒子同一媒体已有活动任务时不重复排队', () {
    final first = DownloadStore.I.add(_card(8));
    final second = DownloadStore.I.add(_card(8));
    expect(first.added, isTrue);
    expect(second.added, isFalse);
    expect(second.job.id, first.job.id);
    expect(DownloadStore.I.jobs, hasLength(1));
  });

  test('后台队列单路依次保存，不占住调用下载的页面', () async {
    final order = <int>[];
    DownloadStore.I.saveOverride = (job, onProgress, isCancelled) async {
      order.add(job.assetId);
      onProgress(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return '已存入相册';
    };
    DownloadStore.I.addAll([_card(1), _card(2)]);
    await DownloadStore.I.run();
    expect(order, [1, 2]);
    expect(DownloadStore.I.jobs.every((job) => job.state == 'done'), isTrue);
    expect(DownloadStore.I.jobs.every((job) => job.progress == 1), isTrue);
  });

  test('切换盒子后不会把排队任务下载成另一台盒子的媒体', () async {
    final job = DownloadStore.I.add(_card(3)).job;
    Api.I.configure('http://other.test:8000', 'token-2');
    Api.I.boxId = 'box-2';
    expect(downloadDestinationError(job), contains('原来的盒子'));
    await DownloadStore.I.run();
    expect(job.state, 'failed');
  });
}
