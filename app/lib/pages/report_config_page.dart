/// 旅行报告配置页：团队/个人 + 时间范围 + 旅程名/地点 → 生成。
library;

import 'package:flutter/material.dart';

import '../api.dart';
import '../main.dart';
import '../report/report_policy.dart';
import '../report/report_template.dart';
import '../widgets/box_image.dart';
import 'report_card_page.dart';

class ReportConfigPage extends StatefulWidget {
  const ReportConfigPage({super.key});

  @override
  State<ReportConfigPage> createState() => _ReportConfigPageState();
}

class _ReportConfigPageState extends State<ReportConfigPage> {
  bool personal = false;
  ReportRange range = ReportRange.defaultRange();
  final titleCtl = TextEditingController(text: '我们的今天');
  String sceneId = reportScenes.first.id;
  List<dynamic> persons = [];
  int? personId;
  String personName = '';
  bool loadingPersons = true;

  @override
  void initState() {
    super.initState();
    _loadPersons();
  }

  @override
  void dispose() {
    titleCtl.dispose();
    super.dispose();
  }

  Future<void> _loadPersons() async {
    try {
      final list = await Api.I.persons();
      if (!mounted) return;
      setState(() {
        // 个人报告只支持团员人物；先在人物页长按标记。
        persons = [
          for (final p in list)
            if ((p['member'] as num?)?.toInt() == 1) p
        ];
        loadingPersons = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => loadingPersons = false);
      toast(context, '团员列表加载失败：$e');
    }
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: now.add(const Duration(days: 1)),
      initialDateRange: DateTimeRange(
        start: DateTime(range.start.year, range.start.month, range.start.day),
        end: DateTime(range.end.year, range.end.month, range.end.day),
      ),
      helpText: '选择起止日期',
      cancelText: '取消',
      confirmText: '确定',
      saveText: '确定',
    );
    if (picked != null && mounted) {
      setState(() => range = ReportRange.fromDates(picked.start, picked.end));
    }
  }

  void _generate() {
    if (!range.isValid) {
      toast(context, '结束时间要晚于开始时间');
      return;
    }
    if (personal) {
      if (personId == null) {
        toast(context, '先选一位团员');
        return;
      }
    }
    final title = titleCtl.text.trim().isEmpty ? '我们的旅行' : titleCtl.text.trim();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReportCardPage(
        config: ReportConfig(
          personal: personal,
          personId: personal ? personId : null,
          personName: personName,
          title: title,
          location: null,
          sceneId: sceneId,
          range: range,
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(' itinerary 旅行报告')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          _seg(),
          const SizedBox(height: 18),
          if (personal) ...[
            _personPicker(),
            const SizedBox(height: 18),
          ],
          _field(
            icon: Icons.edit_outlined,
            child: TextField(
              controller: titleCtl,
              maxLength: 24,
              decoration: const InputDecoration(
                  hintText: '旅程名称', counterText: '', border: InputBorder.none),
            ),
          ),
          const SizedBox(height: 14),
          _scenePicker(),
          const SizedBox(height: 18),
          _rangeTile(),
          const Padding(
            padding: EdgeInsets.only(left: 4, top: 4),
            child: Text('一次选出起止日期。开始当天 0:00，结束当天 23:59:59，两端都包含。',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
          ),
          const SizedBox(height: 26),
          FilledButton(
            onPressed: _generate,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFF5E7A),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text('生成纪念卡', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }

  Widget _seg() {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment(
            value: false, label: Text('团队报告'), icon: Icon(Icons.groups)),
        ButtonSegment(value: true, label: Text('个人报告'), icon: Icon(Icons.face)),
      ],
      selected: {personal},
      onSelectionChanged: (s) {
        final next = s.first;
        setState(() {
          personal = next;
          if (next && titleCtl.text == '我们的今天') {
            titleCtl.text = personName.isEmpty ? '我的今天' : '$personName的今天';
          } else if (!next &&
              (titleCtl.text == '我的今天' || titleCtl.text.endsWith('的今天'))) {
            titleCtl.text = '我们的今天';
          }
        });
      },
    );
  }

  Widget _scenePicker() {
    return _field(
      icon: Icons.landscape_outlined,
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: sceneId,
          isExpanded: true,
          dropdownColor: const Color(0xFF222933),
          items: [
            for (final scene in reportScenes)
              DropdownMenuItem(
                value: scene.id,
                child: Text('${scene.region} · ${scene.name}'),
              ),
          ],
          onChanged: (value) {
            if (value != null) setState(() => sceneId = value);
          },
        ),
      ),
    );
  }

  Widget _personPicker() {
    if (loadingPersons) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (persons.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1F26),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          '还没有团员人物。到「人物」页长按头像，把要出报告的人标记为团员。',
          style: TextStyle(color: Colors.white54, height: 1.6),
        ),
      );
    }
    return SizedBox(
      height: 108,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: persons.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (_, i) {
          final p = persons[i];
          final id = (p['id'] as num).toInt();
          final on = id == personId;
          final cover = p['cover']?.toString();
          return GestureDetector(
            onTap: () => setState(() {
              personId = id;
              personName = (p['name'] ?? '人物$id').toString();
              if (titleCtl.text == '我的今天' || titleCtl.text == '我们的今天') {
                titleCtl.text = '$personName的今天';
              }
            }),
            child: Column(children: [
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
                    width: 62,
                    height: 62,
                    child: (cover == null || cover.isEmpty)
                        ? const ColoredBox(
                            color: Color(0xFF222933),
                            child: Icon(Icons.face, color: Colors.white24),
                          )
                        : BoxImage('${Api.I.base}$cover',
                            fit: BoxFit.cover, cacheWidth: 128),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                (p['name'] ?? '未命名').toString(),
                style: TextStyle(
                  fontSize: 12,
                  color: on ? const Color(0xFFFF5E7A) : Colors.white70,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ]),
          );
        },
      ),
    );
  }

  Widget _field({required Widget child, required IconData icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF222933),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2C343F)),
      ),
      child: Row(children: [
        Icon(icon, color: Colors.white38, size: 20),
        const SizedBox(width: 10),
        Expanded(child: child),
      ]),
    );
  }

  Widget _rangeTile() {
    String ymd(DateTime t) => '${t.year}年${t.month}月${t.day}日';
    final sameDay = range.start.year == range.end.year &&
        range.start.month == range.end.month &&
        range.start.day == range.end.day;
    final text = sameDay
        ? ymd(range.start)
        : '${ymd(range.start)}  –  ${ymd(range.end)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: _pickRange,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: const Color(0xFF222933),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF2C343F)),
          ),
          child: Row(children: [
            const Text('日期',
                style: TextStyle(color: Colors.white54, fontSize: 14)),
            const Spacer(),
            Text(
              text,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, color: Colors.white38),
          ]),
        ),
      ),
    );
  }
}
