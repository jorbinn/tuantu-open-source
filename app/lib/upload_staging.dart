import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;

/// Only this app-owned directory is managed; album originals are never deleted.
class UploadStaging {
  UploadStaging(this.root);
  final Directory root;
  static final _random = Random.secure();
  static bool validId(String id) => RegExp(r'^[a-f0-9]{32}$').hasMatch(id);
  String resolve(String id, String storedPath) {
    if (!validId(id)) throw const FormatException('Invalid upload stage');
    return p.join(root.path, id, p.basename(storedPath));
  }

  Future<Map<String, dynamic>> copy(Map<String, dynamic> job) async {
    final id = List.generate(
            16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    final dir = Directory(p.join(root.path, id));
    try {
      await dir.create(recursive: true);
      final out = {...job, 'stageId': id};
      for (final key in ['path', 'livePath', 'previewPath']) {
        final source = job[key] as String?;
        if (source == null || source.isEmpty) continue;
        final input = File(source);
        if (!await input.exists() || await input.length() == 0) {
          throw FileSystemException('上传文件不可用，请重新选择', source);
        }
        final target = p.join(dir.path, '$key${p.extension(source)}');
        await input.copy(target);
        out[key] = target;
      }
      if (job['liveRequired'] == true &&
          (out['livePath'] as String? ?? '').isEmpty) {
        throw const FormatException('实况不完整，请重新选择');
      }
      return out;
    } catch (_) {
      if (await dir.exists()) await dir.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> remove(String id) async {
    if (!validId(id)) return;
    final dir = Directory(p.join(root.path, id));
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
