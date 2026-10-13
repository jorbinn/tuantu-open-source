import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../report/story_chapter.dart';
import '../report/story_day.dart';
import '../report/story_model.dart';
import '../widgets/box_image.dart';
import 'persons_page.dart';
import 'report_config_page.dart';
import 'report_story_page.dart';

class ReportListPage extends StatefulWidget {
  const ReportListPage({super.key});
  @override
  State<ReportListPage> createState() => _ReportListPageState();
}

class _ReportListPageState extends State<ReportListPage> {
  final offset = DateTime.now().timeZoneOffset.inMinutes;
  final days = <Map<String, dynamic>>[];
  Map<String, dynamic>? identity;
  String? next, error;
  bool loading = true,
      loadingMore = false,
      claimRequired = false,
      upgrade = false;
  CancelToken? _cancel;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    Api.endpointChanges.addListener(_endpointChanged);
    _load();
  }

  @override
  void dispose() {
    Api.endpointChanges.removeListener(_endpointChanged);
    _cancel?.cancel();
    super.dispose();
  }

  void _endpointChanged() {
    if (mounted) _load(preservePosition: true);
  }

  Future<void> _load({bool more = false, bool preservePosition = false}) async {
    if (more && (loading || loadingMore || next == null)) return;
    final generation = ++_generation;
    _cancel?.cancel();
    final token = _cancel = CancelToken();
    setState(() {
      error = null;
      if (more) {
        loadingMore = true;
      } else {
        loading = true;
        loadingMore = false;
        claimRequired = false;
        upgrade = false;
      }
    });
    try {
      final data = await Api.I.storyDays(
        offset: offset,
        before: more ? next : null,
        cancelToken: token,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        if (!more && !preservePosition) days.clear();
        identity = data['identity'] is Map
            ? Map<String, dynamic>.from(data['identity'] as Map)
            : <String, dynamic>{};
        final rows = data['days'] is List ? data['days'] as List : const [];
        for (final row in rows.whereType<Map>()) {
          if (!days.any((d) => d['day'] == row['day'])) {
            days.add(Map<String, dynamic>.from(row));
          }
        }
        // 游标本身也可能是 0000 年这类盒子无法接受的日期：它之后只剩
        // 更「早」的异常日期，已归入「时间未知」，不再翻页。
        if (!preservePosition) {
          final cursor = data['next'];
          next = StoryDay.tryParse(cursor, offset) == null
              ? null
              : cursor as String;
        }
      });
    } on DioException catch (e) {
      if (!mounted || generation != _generation || CancelToken.isCancel(e)) {
        return;
      }
      final body = e.response?.data;
      setState(() {
        claimRequired = body is Map && body['code'] == 'claim_required';
        upgrade = e.response?.statusCode == 404;
        if (claimRequired) {
          days.clear();
          identity = null;
        }
        error = claimRequired || upgrade
            ? null
            : e.response?.statusCode == 429
                ? '报告正在排队，稍后重试即可。'
                : '信号不稳或盒子暂时无响应，请稍后重试。';
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => error = '报告列表加载失败，请重试。');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          loading = false;
          loadingMore = false;
        });
      }
    }
  }

  Future<void> _claim() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: const Color(0xFF0F1216),
          appBar: AppBar(title: const Text('找到照片里的自己')),
          body: const PersonsPage(claimOnly: true),
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _open(StoryDay day) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReportStoryPage(day: day),
      ),
    );
    if (mounted) await _load();
  }

  Widget _message(
    String title,
    String body,
    String action,
    VoidCallback onTap,
  ) =>
      Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.auto_stories_outlined,
                  color: storyAccent, size: 64),
              const SizedBox(height: 24),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: storyInk,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                body,
                textAlign: TextAlign.center,
                style: const TextStyle(color: storyMuted, height: 1.7),
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: onTap, child: Text(action)),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final split = splitStoryDays(days, offset);
    return _build(context, split.dated, split.unknown);
  }

  Widget _build(
    BuildContext context,
    List<StoryDayRow> dated,
    StoryUnknownDays? unknown,
  ) => Theme(
        data: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: storyAccent,
            brightness: Brightness.dark,
            surface: storySurface,
          ),
          scaffoldBackgroundColor: storyPaper,
          appBarTheme: const AppBarTheme(
            backgroundColor: storyPaper,
            foregroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
          ),
        ),
        child: Scaffold(
          backgroundColor: storyPaper,
          appBar: AppBar(
            backgroundColor: storyPaper,
            title: const Text('旅行故事'),
            actions: [
              IconButton(
                tooltip: '刷新报告列表',
                onPressed: loading ? null : () => _load(),
                icon: const Icon(Icons.refresh),
              ),
              if (identity != null && !claimRequired)
                PopupMenuButton<String>(
                  onSelected: (_) => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ReportConfigPage()),
                  ),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'card', child: Text('制作原版纪念卡')),
                  ],
                ),
            ],
          ),
          body: loading && days.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : claimRequired
                  ? _message(
                      '先让故事认识你',
                      '选择自己的头像，再点「确认」。\n认领完成后，会自动回到你的旅行故事。',
                      '去认领「这是我」',
                      _claim,
                    )
                  : upgrade
                      ? _message(
                          '故事准备好了，\n盒子还需要更新',
                          '请先升级团长手机上的团图，再回来查看每日故事。',
                          '重新检查',
                          () => _load(),
                        )
                      : error != null && days.isEmpty
                          ? _message('暂时无法加载', error!, '重试', () => _load())
                          : dated.isEmpty && unknown == null
                              ? _message(
                                  '第一张，就能开始',
                                  '共享相册有照片或视频后，就能按拍摄日期回看。\n无需等旅行结束，也没有最低张数。',
                                  '刷新看看',
                                  () => _load(),
                                )
                              : RefreshIndicator(
                                  onRefresh: () => _load(),
                                  child: ListView(
                                    padding: const EdgeInsets.fromLTRB(
                                        24, 16, 24, 36),
                                    children: [
                                      const Text(
                                        'YOUR DAYS, TOGETHER',
                                        style: TextStyle(
                                          color: storyAccent,
                                          fontSize: 11,
                                          letterSpacing: 2,
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        '${identity?['name'] ?? '你'}，\n每一天都值得回看。',
                                        style: const TextStyle(
                                          fontSize: 30,
                                          fontWeight: FontWeight.w800,
                                          height: 1.35,
                                        ),
                                      ),
                                      const SizedBox(height: 28),
                                      for (var i = 0; i < dated.length; i++)
                                        _dayCard(dated[i], i),
                                      if (unknown != null)
                                        _unknownCard(unknown),
                                      if (error != null)
                                        Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: Text(error!),
                                        ),
                                      if (loadingMore)
                                        const Center(
                                            child: CircularProgressIndicator())
                                      else if (next != null)
                                        TextButton(
                                          onPressed: () => _load(more: true),
                                          child: const Text('更早的故事'),
                                        ),
                                    ],
                                  ),
                                ),
        ),
      );

  /// 拍摄日期异常（如 EXIF 0000:00:00）的影像：不能生成当天故事，
  /// 只汇总展示在列表最后，照片仍可在相册「时间未知」分组里看到。
  Widget _unknownCard(StoryUnknownDays u) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Material(
          color: storySurface,
          borderRadius: BorderRadius.circular(24),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                const SizedBox(
                  width: 76,
                  height: 94,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0xFF252A33),
                      borderRadius: BorderRadius.all(Radius.circular(16)),
                    ),
                    child: Icon(Icons.help_outline, color: Colors.white30),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '时间未知',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${u.photos} 张照片 · ${u.videos} 段视频',
                        style: const TextStyle(fontSize: 12, color: storyMuted),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        '拍摄日期缺失或异常，无法生成当天故事；可在相册「时间未知」分组查看。',
                        style: TextStyle(
                          fontSize: 12,
                          color: storyMuted,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _dayCard(StoryDayRow item, int index) {
    final day = item.day;
    final row = item.row;
    final mine = storyInt(row['mine']);
    final delay = index > 5 ? 5 : index;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 420 + delay * 70),
      curve: Curves.easeOutCubic,
      builder: (_, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 22 * (1 - value)),
          child: child,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Material(
          color: storySurface,
          borderRadius: BorderRadius.circular(24),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _open(day),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      width: 76,
                      height: 94,
                      child: storyInt(row['cover_id']) <= 0
                          ? const ColoredBox(
                              color: Color(0xFF252A33),
                              child: Icon(
                                Icons.movie_outlined,
                                color: Colors.white30,
                              ),
                            )
                          : BoxImage(
                              '${Api.I.base}/api/asset/${storyInt(row['cover_id'])}/thumb',
                              cacheWidth: 200,
                            ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          day.label,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${storyInt(row['photos'])} 张照片 · ${storyInt(row['videos'])} 段视频',
                          style: const TextStyle(
                            fontSize: 12,
                            color: storyMuted,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          mine > 0 ? '$mine 张照片里有你 →' : '看看你和大家的这一天 →',
                          style: const TextStyle(
                            fontSize: 12,
                            color: storyAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
