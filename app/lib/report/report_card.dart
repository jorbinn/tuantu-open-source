/// 团队/个人共享的 1080×1350 旅行报告画布。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'report_snapshot.dart';
import 'report_template.dart';

const kCardWidth = 1080.0;
const kCardHeight = 1350.0;

const _paper = Color(0xFFF4F1E8);
const _ink = Color(0xFF25302B);
const _muted = Color(0xFF59615D);
const _terracotta = Color(0xFFB86F4C);

class ReportCardAssets {
  ReportCardAssets({this.photos = const {}, this.avatars = const {}});
  final Map<int, ui.Image> photos;
  final Map<String, ui.Image> avatars;

  ui.Image? photo(int? id) => id == null ? null : photos[id];
  ui.Image? avatar(String? path) => path == null ? null : avatars[path];
}

class ReportMetric {
  const ReportMetric({
    required this.label,
    required this.value,
    required this.icon,
    this.detail,
    this.avatar,
  });

  final String label;
  final String value;
  final String? detail;
  final IconData icon;
  final ui.Image? avatar;
}

class TeamReportCard extends StatelessWidget {
  const TeamReportCard({
    super.key,
    required this.model,
    required this.assets,
    required this.title,
    required this.rangeLabel,
    this.location,
    this.sceneId = 'vienna-stephansdom',
    this.layoutIndex = 0,
  });

  final TeamCardModel model;
  final ReportCardAssets assets;
  final String title;
  final String rangeLabel;
  final String? location;
  final String sceneId;
  final int layoutIndex;

  @override
  Widget build(BuildContext context) {
    final photos = [
      for (final id in model.photoIds)
        if (assets.photo(id) != null) assets.photo(id)!,
    ].take(5).toList();
    final face = model.appearingMembers
        .where((member) => member.photos >= 3)
        .firstOrNull;
    final uploaders = [...model.snap.uploaders]
      ..sort((a, b) => b.photos.compareTo(a.photos));
    final uploader = uploaders.where((item) => item.photos >= 3).firstOrNull;
    return EditorialReportCard(
      rootKey: const ValueKey('team-report-card-root'),
      title: title,
      dateLabel: rangeLabel,
      scene: reportSceneById(sceneId),
      layout: reportLayouts[layoutIndex % reportLayouts.length],
      photos: photos,
      metrics: [
        ReportMetric(
          label: '照片总数',
          value: '${model.snap.photos}',
          detail: '张照片',
          icon: Icons.photo_outlined,
        ),
        if (face != null)
          ReportMetric(
            label: '出镜最多',
            value: face.name,
            detail: '${face.photos} 张',
            icon: Icons.workspace_premium_outlined,
            avatar: assets.avatar(face.avatarPath),
          ),
        if (uploader != null)
          ReportMetric(
            label: '上传最多',
            value: uploader.name,
            detail: '${uploader.photos} 张',
            icon: Icons.camera_alt_outlined,
          ),
      ],
    );
  }
}

class PersonalReportCard extends StatelessWidget {
  const PersonalReportCard({
    super.key,
    required this.model,
    required this.assets,
    required this.title,
    required this.rangeLabel,
    this.location,
    required this.multiDay,
    this.sceneId = 'vienna-stephansdom',
    this.layoutIndex = 0,
  });

  final PersonalCardModel model;
  final ReportCardAssets assets;
  final String title;
  final String rangeLabel;
  final String? location;
  final bool multiDay;
  final String sceneId;
  final int layoutIndex;

  @override
  Widget build(BuildContext context) {
    final photos = [
      for (final id in model.photoIds)
        if (assets.photo(id) != null) assets.photo(id)!,
    ].take(5).toList();
    final photographer = model.topPhotographer;
    return EditorialReportCard(
      rootKey: const ValueKey('personal-report-card-root'),
      title: title,
      dateLabel: rangeLabel,
      scene: reportSceneById(sceneId),
      layout: reportLayouts[layoutIndex % reportLayouts.length],
      photos: photos,
      metrics: [
        ReportMetric(
          label: '出镜照片',
          value: '${model.appearPhotos}',
          detail: '张照片',
          icon: Icons.photo_outlined,
          avatar: assets.avatar(model.member.avatarPath),
        ),
        if (model.partnerRows.isNotEmpty)
          ReportMetric(
            label: '同框团员',
            value: '${model.partnerRows.length}',
            detail: '位团员',
            icon: Icons.people_outline,
          ),
        if (photographer != null)
          ReportMetric(
            label: '上传最多',
            value: photographer.name,
            detail: '${photographer.photos} 张',
            icon: Icons.camera_alt_outlined,
          ),
      ],
    );
  }
}

class EditorialReportCard extends StatelessWidget {
  const EditorialReportCard({
    super.key,
    required this.rootKey,
    required this.title,
    required this.dateLabel,
    required this.scene,
    required this.layout,
    required this.photos,
    required this.metrics,
  });

  final Key rootKey;
  final String title;
  final String dateLabel;
  final ReportScene scene;
  final ReportLayout layout;
  final List<ui.Image> photos;
  final List<ReportMetric> metrics;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: rootKey,
      width: kCardWidth,
      height: kCardHeight,
      color: _paper,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          const Positioned.fill(child: _PaperTexture()),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 345,
            child: Image.asset(scene.asset, fit: BoxFit.fill),
          ),
          _header(),
          ..._photoFrames(),
          Positioned(
            left: 58,
            right: 58,
            top: 835,
            height: 175,
            child: _MetricStrip(metrics: metrics.take(3).toList()),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    final normalized = title.trim().isEmpty ? '我们的今天' : title.trim();
    final size = normalized.characters.length <= 6 ? 104.0 : 80.0;
    return Positioned(
      left: 48,
      top: 36,
      width: 575,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            normalized,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _ink,
              fontFamily: 'serif',
              fontSize: size,
              height: .9,
              fontWeight: FontWeight.w700,
              letterSpacing: -3,
            ),
          ),
          const SizedBox(height: 12),
          Container(width: 38, height: 2, color: _ink),
          const SizedBox(height: 8),
          Text(
            dateLabel,
            style: const TextStyle(
              color: _muted,
              fontSize: 25,
              letterSpacing: 2,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _photoFrames() {
    if (photos.isEmpty) return const [];
    final slots = _slotsForCount(photos.length);
    final entries = <({int index, ReportPhotoSlot slot})>[
      for (var i = 0; i < slots.length && i < photos.length; i++)
        (index: i, slot: slots[i]),
    ]..sort((a, b) => a.slot.layer.compareTo(b.slot.layer));
    return [
      for (final entry in entries)
        Positioned.fromRect(
          rect: entry.slot.rect,
          child: Transform.rotate(
            angle: entry.slot.radians,
            child: _PhotoFrame(
              image: photos[entry.index],
              showTape: entry.index == 1 || entry.index == 3,
            ),
          ),
        ),
    ];
  }

  List<ReportPhotoSlot> _slotsForCount(int count) {
    if (count == 1) {
      return const [ReportPhotoSlot(Rect.fromLTWH(55, 215, 970, 585))];
    }
    if (count == 2) {
      return const [
        ReportPhotoSlot(Rect.fromLTWH(42, 245, 490, 535), degrees: -2),
        ReportPhotoSlot(Rect.fromLTWH(548, 205, 490, 555),
            degrees: 2.5, layer: 1),
      ];
    }
    final slots = [...layout.slots];
    if (count >= 5) {
      slots.add(const ReportPhotoSlot(
        Rect.fromLTWH(430, 615, 220, 185),
        degrees: -1.5,
        layer: 9,
      ));
    }
    return slots.take(count).toList();
  }
}

class _PhotoFrame extends StatelessWidget {
  const _PhotoFrame({required this.image, required this.showTape});

  final ui.Image image;
  final bool showTape;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 30),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFEF8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .15),
                  blurRadius: 16,
                  offset: const Offset(3, 7),
                ),
              ],
            ),
            child: RawImage(image: image, fit: BoxFit.cover),
          ),
        ),
        if (showTape)
          Positioned(
            top: -10,
            left: 0,
            right: 0,
            child: Center(
              child: Transform.rotate(
                angle: -.08,
                child: Container(
                  width: 86,
                  height: 25,
                  color: const Color(0xFFD9C7A9).withValues(alpha: .62),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _MetricStrip extends StatelessWidget {
  const _MetricStrip({required this.metrics});

  final List<ReportMetric> metrics;

  @override
  Widget build(BuildContext context) {
    if (metrics.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        for (var i = 0; i < metrics.length; i++) ...[
          if (i > 0)
            Container(
              width: 1.2,
              height: 128,
              margin: const EdgeInsets.symmetric(horizontal: 24),
              color: _ink.withValues(alpha: .34),
            ),
          Expanded(child: _MetricCell(metric: metrics[i])),
        ],
      ],
    );
  }
}

class _MetricCell extends StatelessWidget {
  const _MetricCell({required this.metric});

  final ReportMetric metric;

  @override
  Widget build(BuildContext context) {
    final hasAvatar = metric.avatar != null;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              metric.icon,
              size: 32,
              color: metric.icon == Icons.workspace_premium_outlined
                  ? _terracotta
                  : _ink,
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                metric.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _ink, fontSize: 25),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            if (hasAvatar) ...[
              ClipOval(
                child: SizedBox(
                  width: 66,
                  height: 66,
                  child: RawImage(image: metric.avatar, fit: BoxFit.cover),
                ),
              ),
              const SizedBox(width: 14),
            ],
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    metric.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _ink,
                      fontFamily: 'serif',
                      fontSize: hasAvatar ? 39 : 54,
                      height: .9,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (metric.detail != null)
                    Text(
                      metric.detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _ink, fontSize: 24),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _PaperTexture extends StatelessWidget {
  const _PaperTexture();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _PaperTexturePainter());
  }
}

class _PaperTexturePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF7E796E).withValues(alpha: .025)
      ..strokeWidth = .7;
    for (var y = 7.0; y < size.height; y += 17) {
      final shift = (y.toInt() % 31) * .7;
      canvas.drawLine(Offset(shift, y), Offset(size.width, y + 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
