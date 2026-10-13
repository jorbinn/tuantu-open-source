/// 信息流右侧操作列：发布者头像、喜欢、评论、下载。
library;

import 'package:flutter/material.dart';

import '../api.dart';
import 'box_image.dart';

String nameInitial(String name) {
  if (name.isEmpty) return '?';
  return String.fromCharCodes(name.runes.take(1));
}

Color avatarColor(String name) {
  const colors = [
    Color(0xFFFF5E7A),
    Color(0xFF38BDF8),
    Color(0xFF34D399),
    Color(0xFFFBBF24),
    Color(0xFFA78BFA),
  ];
  return colors[name.hashCode.abs() % colors.length];
}

class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.name,
    this.url,
    this.radius = 22,
  });

  final String name;
  final String? url;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;
    final src = url;
    return CircleAvatar(
      radius: radius,
      backgroundColor: avatarColor(name),
      child: src == null || src.isEmpty
          ? Text(
              nameInitial(name),
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: radius * 0.82,
              ),
            )
          : ClipOval(
              child: BoxImage(
                src,
                width: size,
                height: size,
                fit: BoxFit.cover,
                cacheWidth: (size * 3).round(),
              ),
            ),
    );
  }
}

class FeedActionRail extends StatelessWidget {
  const FeedActionRail({
    super.key,
    required this.item,
    required this.onLike,
    required this.onComment,
    required this.onDownload,
    this.onProfile,
  });

  final CardItem item;
  final VoidCallback onLike;
  final VoidCallback onComment;
  final VoidCallback onDownload;
  final VoidCallback? onProfile;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onProfile,
          behavior: HitTestBehavior.opaque,
          child: Semantics(
            button: true,
            label: '主页',
            child: SizedBox(
              width: 48,
              height: 48,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  UserAvatar(
                    name: item.uploader,
                    url: item.avatarUrl,
                    radius: 24,
                  ),
                  const IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.fromBorderSide(
                          BorderSide(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 22),
        _action(
          icon: item.liked ? Icons.favorite : Icons.favorite_border,
          color: item.liked ? const Color(0xFFFE2C55) : Colors.white,
          label: _count(item.likes),
          onTap: onLike,
          semanticLabel: '喜欢',
        ),
        const SizedBox(height: 16),
        _action(
          icon: Icons.mode_comment_outlined,
          color: Colors.white,
          label: _count(item.commentCount),
          onTap: onComment,
          semanticLabel: '评论',
        ),
        const SizedBox(height: 16),
        _action(
          icon: Icons.download_rounded,
          color: Colors.white,
          label: '下载',
          onTap: onDownload,
          semanticLabel: '下载',
        ),
      ],
    );
  }

  static String _count(int n) => n <= 0 ? '0' : (n > 9999 ? '${(n / 10000).toStringAsFixed(1)}w' : '$n');

  static Widget _action({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
    required String semanticLabel,
  }) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 32, shadows: const [
                Shadow(blurRadius: 8, color: Colors.black54),
              ]),
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
