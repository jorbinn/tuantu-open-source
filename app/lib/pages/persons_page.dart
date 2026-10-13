/// 人物页：认领自己的脸；长按进入多选。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../box/box_faces.dart';
import '../main.dart';
import '../widgets/box_image.dart';

class PersonsPage extends StatefulWidget {
  const PersonsPage({
    super.key,
    this.onBrowse,
    this.active = true,
    this.claimOnly = false,
  });
  final void Function(int pid, String label)? onBrowse;
  final bool active;

  /// 报告入口：单选头像、确认后返回，不提供人物管理操作。
  final bool claimOnly;
  @override
  State<PersonsPage> createState() => PersonsPageState();
}

class PersonsPageState extends State<PersonsPage>
    with AutomaticKeepAliveClientMixin {
  List<dynamic> persons = [];
  bool loading = false;
  String? _loadError;
  bool selecting = false;
  bool _claimSubmitting = false;
  final selected = <int>{};
  int _lastClusterEpoch = 0;
  bool _reloadQueued = false;
  int _coverRetryEpoch = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    FaceEngine.I.addListener(_onFace);
    Api.endpointChanges.addListener(_endpointChanged);
    _lastClusterEpoch = FaceEngine.I.clusterEpoch;
    if (widget.active) load();
  }

  @override
  void dispose() {
    FaceEngine.I.removeListener(_onFace);
    Api.endpointChanges.removeListener(_endpointChanged);
    super.dispose();
  }

  void _onFace() {
    final epoch = FaceEngine.I.clusterEpoch;
    if (epoch == _lastClusterEpoch) return;
    _lastClusterEpoch = epoch;
    if (!widget.active) return;
    // 识别刚完成时 pending 已是 0，真正写出人物是之后的聚类。
    // 若此时 load() 还在飞，记下脏标记，结束再拉一次。
    if (loading) {
      _reloadQueued = true;
      return;
    }
    load();
  }

  @override
  void didUpdateWidget(covariant PersonsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      if (loading) {
        _reloadQueued = true;
      } else {
        load();
      }
    }
  }

  bool consumeBack() {
    if (!selecting) return false;
    setState(() {
      selecting = false;
      selected.clear();
    });
    return true;
  }

  void _endpointChanged() {
    if (mounted && widget.active) load();
  }

  Future<void> load() async {
    if (!mounted) return;
    if (loading) {
      _reloadQueued = true;
      return;
    }
    setState(() {
      loading = true;
      _loadError = null;
    });
    _reloadQueued = false;
    try {
      persons = await Api.I.persons();
      _coverRetryEpoch++;
      selected.removeWhere((id) => persons.every((p) => p['id'] != id));
      if (selected.isEmpty) selecting = false;
    } catch (e) {
      if (mounted) setState(() => _loadError = friendlyNet(e, '加载人物'));
    }
    if (mounted) setState(() => loading = false);
    if (mounted && _reloadQueued && widget.active) {
      _reloadQueued = false;
      await load();
    }
  }

  int _pid(p) => (p['id'] as num).toInt();

  void _enterSelect(int id) {
    HapticFeedback.mediumImpact();
    setState(() {
      selecting = true;
      selected
        ..clear()
        ..add(id);
    });
  }

  void _tapCard(dynamic p) {
    if (_claimSubmitting) return;
    final id = _pid(p);
    if (widget.claimOnly) {
      _enterSelect(id);
      return;
    }
    if (selecting) {
      setState(() {
        if (selected.contains(id)) {
          selected.remove(id);
        } else {
          selected.add(id);
        }
        if (selected.isEmpty) selecting = false;
      });
      return;
    }
    // 专用的认领页没有人物相册可跳转；此时单击应直接选中，
    // 否则点头像会像“没反应”，只有长按才能继续认领。
    if (widget.onBrowse == null) {
      _enterSelect(id);
      return;
    }
    widget.onBrowse!(id, (p['name'] ?? '人物$id') as String);
  }

  Future<void> _rename() async {
    if (selected.length != 1) return;
    final id = selected.first;
    final cur = persons.firstWhere((p) => _pid(p) == id, orElse: () => null);
    final ctl = TextEditingController(text: (cur?['name'] ?? '').toString());
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 20,
          decoration: const InputDecoration(hintText: '给这个人起个名字'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (name == null || !mounted) return;
    try {
      await Api.I.renamePerson(id, name);
      selecting = false;
      selected.clear();
      await load();
      if (mounted) toast(context, '已改名');
    } catch (e) {
      if (mounted) toast(context, '改名失败：$e');
    }
  }

  Future<void> _merge() async {
    if (selected.length < 2) return;
    final n = selected.length;
    Object? keepClaim; // null=还没定；'none'=全部取消；int=保留该用户认领
    while (true) {
      if (keepClaim == null) {
        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('合并人物？'),
            content: Text('会把这 $n 个人合成一个，合并后没法拆开。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(
                  '继续',
                  style: TextStyle(color: Color(0xFFFF6B6B)),
                ),
              ),
            ],
          ),
        );
        if (ok != true || !mounted) return;
      }
      try {
        final res = await Api.I.mergePersons(
          selected.toList(),
          keepClaimUser: keepClaim,
        );
        final conflict = res['conflict'];
        if (conflict is Map && conflict['type'] == 'merge_claims') {
          // 不同账号的认领撞在一起：操作者明确选保留谁的，或全部取消。
          final claims = (conflict['claims'] as List? ?? const [])
              .whereType<Map>()
              .toList();
          final users = <int, String>{};
          for (final c in claims) {
            final uid = (c['user_id'] as num?)?.toInt();
            final name = c['user_name']?.toString();
            if (uid != null && name != null) users[uid] = name;
          }
          if (!mounted) return;
          final choice = await showDialog<Object>(
            context: context,
            builder: (ctx) => SimpleDialog(
              title: const Text('合并后保留谁的「这是我」？'),
              children: [
                for (final e in users.entries)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, e.key),
                    child: Text('保留 ${e.value} 的认领'),
                  ),
                const SimpleDialogOption(
                  onPressed: null,
                  child: Text(
                    '（其他人的认领会解除，作品不受影响）',
                    style: TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                ),
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, 'none'),
                  child: const Text('全部取消'),
                ),
              ],
            ),
          );
          if (choice == null || !mounted) return;
          keepClaim = choice;
          continue; // 带选择重试
        }
        break;
      } catch (e) {
        if (mounted) toast(context, '合并失败：$e');
        return;
      }
    }
    try {
      selecting = false;
      selected.clear();
      await load();
      if (mounted) toast(context, '已合并');
    } catch (e) {
      if (mounted) toast(context, '刷新失败：$e');
    }
  }

  bool _claimed(dynamic p) => p is Map && p['claimed_by_me'] == true;
  bool _member(dynamic p) => p is Map && (p['member'] as num?)?.toInt() == 1;

  List<dynamic> get _mine => [
        for (final p in persons)
          if (_claimed(p)) p,
      ];
  List<dynamic> get _companions => [
        for (final p in persons)
          if (!_claimed(p) && _member(p)) p,
      ];
  List<dynamic> get _others => [
        for (final p in persons)
          if (!_claimed(p) && !_member(p)) p,
      ];

  bool get _selectedIsMe {
    if (selected.length != 1) return false;
    final id = selected.first;
    return persons.any((p) => _pid(p) == id && _claimed(p));
  }

  Future<void> _confirmClaim() async {
    if (_claimSubmitting || loading || selected.length != 1) return;
    setState(() => _claimSubmitting = true);
    try {
      await _claimMe();
    } finally {
      if (mounted) setState(() => _claimSubmitting = false);
    }
  }

  Future<void> _claimMe() async {
    if (selected.length != 1) return;
    final id = selected.first;
    if (_selectedIsMe && !widget.claimOnly) {
      // 「不是我」：只取消自己的认领，不动团员标记，不禁止再次认领。
      try {
        await Api.I.unclaim(id);
        await load();
        if (mounted) toast(context, '已取消「这是我」');
      } catch (e) {
        if (mounted) toast(context, '操作失败：$e');
      }
      return;
    }
    // 一对一认领：冲突时确认框说清完整影响，确认期间被别人动过就再确认一次。
    try {
      var res = await Api.I.claim(id);
      var guard = 0;
      while (res['conflict'] is Map && guard++ < 3) {
        if (!mounted ||
            (widget.claimOnly && ModalRoute.of(context)?.isCurrent != true)) {
          return;
        }
        final c = res['conflict'] as Map;
        final lines = <String>[];
        final my = c['my_person'];
        final their = c['person_user'];
        if (my is Map) lines.add('会解除你对「${my['name']}」的认领');
        if (their is Map) lines.add('会解除 ${their['name']} 对这个人物的认领');
        if ((c['person_member'] as num? ?? 0) == 2) {
          lines.add('这个人物会恢复标记为团员');
        }
        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('认领这个人物？'),
            content: Text(lines.isEmpty ? '确认认领吗？' : lines.join('\n')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('认领'),
              ),
            ],
          ),
        );
        if (ok != true || !mounted) return;
        res = await Api.I.claim(
          id,
          confirm: true,
          expectMyPerson: my is Map ? (my['id'] as num?)?.toInt() : null,
          expectPersonUser:
              their is Map ? (their['id'] as num?)?.toInt() : null,
        );
      }
      if (res['ok'] == true) {
        if (widget.claimOnly) {
          if (mounted && ModalRoute.of(context)?.isCurrent == true) {
            Navigator.of(context).pop(true);
          }
          return;
        }
        await load();
        if (mounted) {
          toast(context, res['already'] == true ? '已经认领过了' : '认领成功！「有我的」视图已更新');
        }
      } else if (mounted) {
        toast(context, '认领未完成，请重新确认');
      }
    } catch (e) {
      if (mounted) toast(context, '操作失败：$e');
    }
  }

  /// 团员标记：未标记/团员/非团员三态，可改、留修改人。
  Future<void> _markMember() async {
    if (selected.isEmpty) return;
    final ids = selected.toList(growable: false);
    final statuses = <int>{
      for (final p in persons)
        if (selected.contains(_pid(p))) (p['member'] as num?)?.toInt() ?? 0,
    };
    final currentStatus = statuses.length == 1 ? statuses.single : null;
    final batch = ids.length > 1;
    if (!mounted) return;
    final choice = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(batch ? '批量标记 ${ids.length} 个人物' : '团员标记'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 1),
            child: Text(
              '团员${currentStatus == 1 ? ' （当前）' : ''}',
              style: const TextStyle(color: Color(0xFF38BDF8)),
            ),
          ),
          const SimpleDialogOption(
            onPressed: null,
            child: Text(
              '计入旅行报告出镜，可生成个人报告',
              style: TextStyle(fontSize: 12, color: Colors.white38),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 2),
            child: Text('非团员${currentStatus == 2 ? ' （当前）' : ''}'),
          ),
          const SimpleDialogOption(
            onPressed: null,
            child: Text(
              '只影响人物统计，不删照片',
              style: TextStyle(fontSize: 12, color: Colors.white38),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 0),
            child: Text('清除标记${currentStatus == 0 ? ' （当前）' : ''}'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    try {
      await Api.I.setPersonsMember(ids, choice);
      selecting = false;
      selected.clear();
      await load();
      if (mounted) {
        final prefix = batch ? '已将 ${ids.length} 个人物' : '已';
        final action =
            choice == 1 ? '标记为团员' : (choice == 2 ? '标记为非团员' : '清除标记');
        toast(context, '$prefix$action');
      }
    } catch (e) {
      if (mounted) toast(context, '操作失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: load,
            child: persons.isEmpty && !loading
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 80),
                      Center(
                        child: Text(
                          _loadError ?? '还没识别出人物。\n照片上传后需要几分钟在盒子里慢慢分析。',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white38, height: 1.8),
                        ),
                      ),
                      if (_loadError != null)
                        Center(
                            child: TextButton(
                                onPressed: load, child: const Text('重新加载'))),
                    ],
                  )
                : CustomScrollView(
                    // ignore: deprecated_member_use
                    cacheExtent: 200,
                    slivers: [
                      if (_loadError != null)
                        SliverToBoxAdapter(
                            child: TextButton(
                                onPressed: load,
                                child: Text('$_loadError，点击重试'))),
                      if (widget.claimOnly) ...[
                        _section('选择自己的头像'),
                        _grid(persons, padTop: 16),
                      ] else ...[
                        if (_mine.isNotEmpty) ...[
                          _section('这是我'),
                          _grid(_mine, padTop: 8),
                        ],
                        if (_companions.isNotEmpty) ...[
                          _section('小伙伴们'),
                          _grid(_companions, padTop: 8),
                        ],
                        if (_others.isNotEmpty) ...[
                          _section('其他人'),
                          _grid(_others, padTop: 8),
                        ],
                      ],
                      const SliverToBoxAdapter(child: SizedBox(height: 28)),
                    ],
                  ),
          ),
        ),
        if (widget.claimOnly)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed:
                      selected.length == 1 && !loading && !_claimSubmitting
                          ? _confirmClaim
                          : null,
                  child: Text(_claimSubmitting ? '确认中…' : '确认'),
                ),
              ),
            ),
          )
        else if (selecting)
          _actionBar(),
      ],
    );
  }

  Widget _actionBar() {
    final one = selected.length == 1;
    final many = selected.length >= 2;
    return Material(
      color: const Color(0xFF1A1F26),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              _barBtn(Icons.edit_outlined, '重命名', one ? _rename : null),
              _barBtn(Icons.merge_type, '合并', many ? _merge : null),
              _barBtn(
                _selectedIsMe ? Icons.face_retouching_off : Icons.face,
                _selectedIsMe ? '这不是我' : '这是我',
                one ? _claimMe : null,
              ),
              _barBtn(Icons.group_outlined, '团员', _markMember),
            ],
          ),
        ),
      ),
    );
  }

  Widget _barBtn(IconData icon, String label, VoidCallback? onTap) {
    final on = onTap != null;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: on ? Colors.white : Colors.white24),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: on ? Colors.white : Colors.white24,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
        child: Row(
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Colors.white70,
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(child: Divider(color: Color(0x33FFFFFF), height: 1)),
          ],
        ),
      ),
    );
  }

  Widget _grid(List<dynamic> list, {required double padTop}) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(16, padTop, 16, 0),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 18,
          crossAxisSpacing: 12,
          childAspectRatio: .82,
        ),
        delegate: SliverChildBuilderDelegate(
          (_, i) => _card(list[i]),
          childCount: list.length,
          addAutomaticKeepAlives: false,
        ),
      ),
    );
  }

  Widget _card(p) {
    final id = _pid(p);
    final on = selected.contains(id);
    final cover = p['cover']?.toString();
    final url =
        (cover != null && cover.isNotEmpty) ? '${Api.I.base}$cover' : null;
    return Column(
      children: [
        GestureDetector(
          key: ValueKey('person-$id'),
          onTap: _claimSubmitting ? null : () => _tapCard(p),
          onLongPress: widget.claimOnly ? null : () => _enterSelect(id),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: on ? const Color(0xFFFF5E7A) : Colors.transparent,
                    width: 3,
                  ),
                ),
                child: ClipOval(
                  child: SizedBox(
                    width: 72,
                    height: 72,
                    child: url == null
                        ? const ColoredBox(
                            color: Color(0xFF222933),
                            child: Icon(Icons.face, color: Colors.white24),
                          )
                        : BoxImage(
                            url,
                            fit: BoxFit.cover,
                            width: 72,
                            height: 72,
                            cacheWidth: 160,
                            retryEpoch: _coverRetryEpoch,
                          ),
                  ),
                ),
              ),
              if (selecting || widget.claimOnly)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Icon(
                    on ? Icons.check_circle : Icons.circle_outlined,
                    color: on ? const Color(0xFFFF5E7A) : Colors.white70,
                    size: 22,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          p['name'] ?? '未命名',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13),
        ),
        Text(
          '${p['count']} 张',
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
      ],
    );
  }
}
