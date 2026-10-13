import 'package:flutter/material.dart';

/// Compact system-style Live marker, shared by local and uploaded photos.
class LivePhotoBadge extends StatelessWidget {
  const LivePhotoBadge({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    label: '实况照片',
    child: Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: Colors.black45,
          borderRadius: BorderRadius.circular(12)),
      child: const Icon(Icons.motion_photos_on, color: Colors.white, size: 19),
    ),
  );
}
