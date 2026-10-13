/// 盒子上传辅助：流式 multipart 落盘，以及缩略图/头像的 isolate 计算。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as im;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import '../live_photo.dart';

/// 解码 [bytes] 生成 480px JPEG 缩略图，并读 EXIF 拍摄时间。
///
/// 入参/出参都是字节和基本类型，不传 [im.Image]。必须在独立 isolate 里调用。
Map<String, dynamic>? encodeThumbJpeg(Uint8List bytes) {
  final decoded = im.decodeImage(bytes);
  if (decoded == null) return null;
  final thumb = im.copyResize(decoded, width: 480);
  return <String, dynamic>{
    'jpeg': Uint8List.fromList(im.encodeJpg(thumb, quality: 82)),
    'width': decoded.width,
    'height': decoded.height,
    'taken': readExifTaken(decoded),
  };
}

/// 在独立 isolate 里跑 [encodeThumbJpeg]，避免堵住盒子 HTTP 事件循环。
Future<Map<String, dynamic>?> encodeThumbJpegOffload(Uint8List bytes) {
  return Isolate.run(() => encodeThumbJpeg(bytes));
}

/// 报告只取当前入选的少量照片，使用较大的派生图避免 1080px 分享图发糊。
Uint8List? encodeReportPreviewJpeg(Uint8List bytes) {
  final decoded = im.decodeImage(bytes);
  if (decoded == null) return null;
  im.Image resized;
  if (decoded.width >= decoded.height) {
    resized =
        decoded.width > 1600 ? im.copyResize(decoded, width: 1600) : decoded;
  } else {
    resized =
        decoded.height > 1600 ? im.copyResize(decoded, height: 1600) : decoded;
  }
  return Uint8List.fromList(im.encodeJpg(resized, quality: 88));
}

Future<Uint8List?> encodeReportPreviewJpegOffload(Uint8List bytes) {
  return Isolate.run(() => encodeReportPreviewJpeg(bytes));
}

/// 把头像裁成 480 正方形 JPEG。必须在独立 isolate 里调用。
Uint8List? encodeAvatarJpeg(Uint8List bytes) {
  final decoded = im.decodeImage(bytes);
  if (decoded == null) return null;
  var img = decoded;
  final side = img.width < img.height ? img.width : img.height;
  img = im.copyCrop(
    img,
    x: (img.width - side) ~/ 2,
    y: (img.height - side) ~/ 2,
    width: side,
    height: side,
  );
  img = im.copyResize(img, width: 480, height: 480);
  return Uint8List.fromList(im.encodeJpg(img, quality: 85));
}

/// 在独立 isolate 里跑 [encodeAvatarJpeg]。
Future<Uint8List?> encodeAvatarJpegOffload(Uint8List bytes) {
  return Isolate.run(() => encodeAvatarJpeg(bytes));
}

/// 从已解码的图里读 DateTimeOriginal / DateTime，返回 unix 秒。
double? readExifTaken(im.Image img) {
  return readExifTimestamp(img.exif);
}

double? readExifTimestamp(im.ExifData exif) {
  try {
    final v = exif.exifIfd['DateTimeOriginal'] ?? exif.imageIfd['DateTime'];
    if (v == null) return null;
    final s = v.toString().trim();
    final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})')
        .firstMatch(s);
    if (m == null) return null;
    // 没设时钟的相机写 0000:00:00；不合理的日期当作没有拍摄时间，
    // 交给客户端 meta / 上传时间兜底，避免入库公元前的时间。
    final year = int.parse(m[1]!), month = int.parse(m[2]!);
    final day = int.parse(m[3]!);
    if (year < 1900 ||
        year > 2100 ||
        month < 1 ||
        month > 12 ||
        day < 1 ||
        day > 31) {
      return null;
    }
    final d = DateTime.utc(
      int.parse(m[1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
      int.parse(m[4]!),
      int.parse(m[5]!),
      int.parse(m[6]!),
    );
    return d.millisecondsSinceEpoch / 1000.0;
  } catch (_) {
    return null;
  }
}

Future<double?> readUploadTakenAt(String path) => Isolate.run(() {
      try {
        final header = readJpegMetadata(path);
        if (header.isEmpty) return null;
        final exif = im.decodeJpgExif(header);
        return exif == null ? null : readExifTimestamp(exif);
      } catch (_) {
        return null;
      }
    });

/// 写盘前的暂存信息，供入库回调使用。
class StagedUpload {
  StagedUpload({
    required this.filename,
    required this.ext,
    required this.kind,
    required this.size,
    required this.sha256,
  });
  final String filename;
  final String ext;
  final String kind;
  final int size;
  final String sha256;
  double? takenAt;
}

/// 已改名入库的原片。
class IngestedAsset {
  IngestedAsset({
    required this.id,
    required this.filename,
    required this.ext,
    required this.kind,
    required this.size,
    required this.sha256,
    required this.file,
  });
  final int id;
  final String filename;
  final String ext;
  final String kind;
  final int size;
  final String sha256;
  final File file;
}

/// 命中作者 + 文件名 + 拍摄日的已有作品。同作者重传可补齐缺失附件。
class DupRecord {
  DupRecord({required this.id, this.uploaderId});
  final int id;
  final int? uploaderId;
}

/// 同作者的重复上传 + 本次请求携带了附件 → 补全候选。
/// 只对「作者还是本人」的旧作品生效，绝不动别人的作品。
class RepairedAsset {
  RepairedAsset({
    required this.id,
    required this.filename,
    required this.ext,
    required this.kind,
    required this.size,
    required this.sha256,
  });
  final int id;
  final String filename;
  final String ext;
  final String kind;
  final int size;
  final String sha256;
}

/// 一次 `/api/upload` 流式解析的结果。
class UploadIngestResult {
  UploadIngestResult({
    required this.accepted,
    required this.duplicates,
    required this.rejected,
    this.repaired = const [],
    this.liveFile,
    this.previewFile,
    this.meta = const {},
  });
  final List<IngestedAsset> accepted;
  final List<Map<String, dynamic>> duplicates;
  final List<String> rejected;

  /// 同作者重复、且本请求带附件可补全的作品。附件临时文件交给调用方处理。
  final List<RepairedAsset> repaired;
  final File? liveFile;

  /// 客户端附带的兼容预览（HEIC/视频首帧 JPEG），供缩略图管线使用。
  final File? previewFile;

  /// 客户端随上传发送的元数据：{filename: {'taken_at': unix秒}}。
  final Map<String, dynamic> meta;
}

/// 按 key 串行执行异步临界区，不同 key 互不阻塞。
/// 用于把「查重 + 插入」变成原子段，堵住并发上传同内容双入库的窗口。
class KeyedMutex {
  final _tails = <String, Future<void>>{};

  Future<T> run<T>(String key, Future<T> Function() fn) {
    final prev = _tails[key];
    final done = Completer<void>();
    _tails[key] = done.future;
    return () async {
      if (prev != null) {
        try {
          await prev;
        } catch (_) {}
      }
      try {
        return await fn();
      } finally {
        if (identical(_tails[key], done.future)) _tails.remove(key);
        if (!done.isCompleted) done.complete();
      }
    }();
  }
}

/// 把一个 part 流式写入临时文件（可选增量回调），可被外部中止。
class _PartWriter {
  _PartWriter(this.tmp, {IOSink Function(File file)? openSink})
      : _openSink = openSink;
  final File tmp;
  final IOSink Function(File file)? _openSink;
  IOSink? _sink;
  StreamSubscription<List<int>>? _sub;
  final done = Completer<void>();
  bool wroteAll = false;
  bool aborted = false;
  int size = 0;

  void start(
    Stream<List<int>> part, {
    void Function(List<int> chunk)? onChunk,
  }) {
    _sink = (_openSink ?? (f) => f.openWrite())(tmp);
    _sub = part.listen(
      (chunk) {
        if (aborted) return;
        onChunk?.call(chunk);
        size += chunk.length;
        _sink!.add(chunk);
      },
      onError: (Object e, StackTrace st) async {
        try {
          await _close(ok: false);
        } catch (_) {}
        if (!done.isCompleted) done.completeError(e, st);
      },
      onDone: () async {
        // 必须等 flush/close 真正落盘再放行，否则阶段 2 的 rename/读文件会拿到半截数据
        try {
          await _close(ok: true);
          if (!done.isCompleted) done.complete();
        } catch (e, st) {
          if (!done.isCompleted) done.completeError(e, st);
        }
      },
      cancelOnError: true,
    );
  }

  Future<void> _close({required bool ok}) async {
    final s = _sink;
    _sink = null;
    Object? closeErr;
    if (s != null) {
      try {
        await s.flush();
        await s.close();
      } catch (e) {
        closeErr = e;
        try {
          await s.close();
        } catch (_) {}
      }
    }
    var complete = ok && closeErr == null;
    if (complete) {
      try {
        if (!tmp.existsSync() || tmp.lengthSync() != size) {
          complete = false;
        }
      } catch (_) {
        complete = false;
      }
    }
    wroteAll = complete;
    if (!complete) _delete();
    if (closeErr != null) throw closeErr;
    if (ok && !complete) {
      throw const FileSystemException('上传文件未能完整落盘');
    }
  }

  void _delete() {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {}
  }

  /// 上传体中断时放弃这个 part：取消订阅、关文件、删临时文件。
  Future<void> abort() async {
    aborted = true;
    try {
      await _sub?.cancel();
    } catch (_) {}
    final s = _sink;
    _sink = null;
    try {
      await s?.close();
    } catch (_) {}
    _delete();
    if (!done.isCompleted) done.complete();
  }
}

/// 边收请求体边解析 multipart，把 `files` part 流式写到 [orig]。
///
/// 两阶段提交：阶段 1 只落临时文件（`_tmp_*`）并增量算 sha256，**不碰数据库**；
/// 整个请求体（含 preview/meta/live 附件）收完才进阶段 2 查重入库。
/// 这样「主文件传完、附件没收完就断网」时库里没有半成品，重试整包重发即可补齐。
/// 同作者的去重命中不直接丢弃，而是返回 [UploadIngestResult.repaired] 供调用方补附件。
///
/// 连接中断的错误必须能终结解析：mime 包的 transformer 把上游错误投给外层流，
/// 而消费方正 await 在内层 part 流上（内层永不结束）， naïve 写法会挂死整个请求。
/// 这里用「part 写完 vs 外层出错」赛跑，输了就 abort 当前 part 并清光临时文件。
Future<UploadIngestResult> ingestUploadMultipart({
  required Stream<List<int>> body,
  required String boundary,
  required Directory orig,
  required bool Function(String ext) isAllowed,
  required String Function(String ext) kindOf,
  required Future<DupRecord?> Function(StagedUpload file, double takenAt)
      findDup,
  required Future<int> Function(StagedUpload file) insertAsset,
  Future<void> Function(int id)? deleteAsset,
  int? userId,

  /// 把「查重 + 插入」包成同去重键的原子段，堵住并发双入库。
  Future<T> Function<T>(String key, Future<T> Function() fn)? dedupeLock,

  /// 清扫跳过这些正在写的临时/目标文件。创建前登记，用完或失败后撤销。
  void Function(String path)? trackFile,
  void Function(String path)? untrackFile,

  /// 测试用：注入可在 close 时失败的 sink。
  IOSink Function(File tmp)? openSink,
}) async {
  final staged = <({StagedUpload info, File tmp})>[];
  final tmpFiles = <File>[];
  File? liveFile;
  File? previewFile;
  var metaRaw = '';

  await orig.create(recursive: true);

  final parsed = MimeMultipartTransformer(boundary).bind(body);
  final parts = StreamController<MimeMultipart>(sync: true);
  final outerErr = Completer<void>();
  final sub = parsed.listen(
    parts.add,
    onError: (Object e, StackTrace st) {
      if (!outerErr.isCompleted) outerErr.completeError(e, st);
      parts.addError(e, st);
    },
    onDone: parts.close,
    cancelOnError: false,
  );

  Future<void> cleanupTmp() async {
    for (final f in tmpFiles) {
      untrackFile?.call(f.path);
      for (var attempt = 0; attempt < 5; attempt++) {
        try {
          if (!f.existsSync()) break;
          await f.delete();
          break;
        } catch (_) {
          if (attempt < 4) {
            await Future<void>.delayed(const Duration(milliseconds: 12));
          }
        }
      }
    }
  }

  final accepted = <IngestedAsset>[];
  final duplicates = <Map<String, dynamic>>[];
  final repaired = <RepairedAsset>[];
  final rejected = <String>[];
  var meta = const <String, dynamic>{};

  try {
    final it = StreamIterator<MimeMultipart>(parts.stream);
    var outerFailed = false;
    while (true) {
      final bool hasPart;
      try {
        hasPart = await it.moveNext();
      } catch (e) {
        outerFailed = true;
        rethrow;
      }
      if (!hasPart) break;
      final part = it.current;
      final disp = part.headers['content-disposition'] ?? '';
      final name = _headerParam(disp, 'name');
      final filename = _headerParam(disp, 'filename');

      final tmp = File(p.join(orig.path, '_tmp_${_tmpId()}'));
      tmpFiles.add(tmp);
      trackFile?.call(tmp.path);
      final w = _PartWriter(tmp, openSink: openSink);
      String? ext;
      final digestSink = _DigestSink();
      final hashIn = sha256.startChunkedConversion(digestSink);
      var isFiles = false;
      String? fname;
      if (name == 'files' && filename != null) {
        isFiles = true;
        fname = filename;
        ext = p.extension(filename).replaceFirst('.', '').toLowerCase();
        if (!isAllowed(ext)) {
          await w.abort();
          tmpFiles.remove(tmp);
          rejected.add('$filename（.$ext 不支持）');
          continue;
        }
        w.start(part, onChunk: (c) => hashIn.add(c));
      } else {
        w.start(part);
      }
      try {
        await Future.any([w.done.future, outerErr.future]);
      } on Object {
        outerFailed = true;
      }
      if (outerErr.isCompleted) {
        outerFailed = true;
        await w.abort();
        break;
      }
      if (!w.wroteAll) {
        // part 自身出错：临时文件已清，把错误抛给上层（走 catch 统一善后）
        await it.cancel();
        await sub.cancel();
        await w.done.future;
        break;
      }

      if (isFiles) {
        hashIn.close();
        if (w.size == 0) {
          tmpFiles.remove(tmp);
          untrackFile?.call(tmp.path);
          rejected.add(fname!);
        } else {
          staged.add((
            info: StagedUpload(
              filename: fname!,
              ext: ext!,
              kind: kindOf(ext),
              size: w.size,
              sha256: digestSink.value!.toString(),
            ),
            tmp: tmp,
          ));
        }
      } else if (name == 'live') {
        final prev = liveFile;
        if (prev != null) {
          try {
            await prev.delete();
          } catch (_) {}
          tmpFiles.remove(prev);
          untrackFile?.call(prev.path);
        }
        if (w.size == 0) {
          tmpFiles.remove(tmp);
          untrackFile?.call(tmp.path);
          liveFile = null;
        } else {
          liveFile = tmp;
        }
      } else if (name == 'preview') {
        final prev = previewFile;
        if (prev != null) {
          try {
            await prev.delete();
          } catch (_) {}
          tmpFiles.remove(prev);
          untrackFile?.call(prev.path);
        }
        if (w.size == 0) {
          tmpFiles.remove(tmp);
          untrackFile?.call(tmp.path);
          previewFile = null;
        } else {
          previewFile = tmp;
        }
      } else if (name == 'meta') {
        try {
          metaRaw = utf8.decode(tmp.readAsBytesSync());
        } catch (_) {}
        tmpFiles.remove(tmp);
        untrackFile?.call(tmp.path);
        try {
          await tmp.delete();
        } catch (_) {}
      } else {
        tmpFiles.remove(tmp);
        untrackFile?.call(tmp.path);
        try {
          await tmp.delete();
        } catch (_) {}
      }
    }
    if (outerFailed && outerErr.isCompleted) {
      await cleanupTmp();
      await sub.cancel();
      await outerErr.future; // rethrow 真实的中断原因
    }
    if (outerFailed) {
      await cleanupTmp();
      await sub.cancel();
      throw const MimeMultipartException('上传在完整收到前中断');
    }

    // A paired upload names exactly one primary. Validate before inserting it;
    // a broken attachment must not leave behind a successfully uploaded still.
    if (liveFile != null &&
        (staged.length != 1 ||
            staged.single.info.kind != 'image' ||
            !liveVideoFileReady(liveFile))) {
      throw const FormatException('实况上传必须包含一张照片和完整动态视频');
    }
    if (metaRaw.isNotEmpty) {
      final declared = jsonDecode(metaRaw);
      if (declared is Map) {
        meta = Map<String, dynamic>.from(declared);
        for (final e in staged) {
          final item = declared[e.info.filename];
          if (item is Map &&
              item['live_required'] == true &&
              liveFile == null) {
            throw const FormatException('实况上传缺少动态附件');
          }
        }
      }
    }

    // ---- 阶段 2：请求体完整收到，查重 + 入库 + 原子改名 ----
    final lock = dedupeLock ?? <T>(String _, Future<T> Function() fn) => fn();
    final fallbackTakenAt = DateTime.now().millisecondsSinceEpoch / 1000.0;
    for (final e in staged) {
      if (e.info.size == 0) {
        rejected.add(e.info.filename);
        try {
          await e.tmp.delete();
        } catch (_) {}
        tmpFiles.remove(e.tmp);
        untrackFile?.call(e.tmp.path);
        continue;
      }
      final itemMeta = meta[e.info.filename];
      final declaredTakenAt =
          itemMeta is Map ? (itemMeta['taken_at'] as num?)?.toDouble() : null;
      final exifTakenAt =
          e.info.kind == 'image' ? await readUploadTakenAt(e.tmp.path) : null;
      final dedupeTakenAt = exifTakenAt ??
          (declaredTakenAt != null &&
                  declaredTakenAt.isFinite &&
                  declaredTakenAt > 0
              ? declaredTakenAt
              : fallbackTakenAt);
      e.info.takenAt = dedupeTakenAt;
      final day = (dedupeTakenAt / Duration.secondsPerDay).floor();
      final dedupeKey = '${e.info.filename}\u0000$day';
      await lock(dedupeKey, () async {
        final dup = await findDup(e.info, dedupeTakenAt);
        if (dup != null) {
          try {
            await e.tmp.delete();
          } catch (_) {}
          tmpFiles.remove(e.tmp);
          untrackFile?.call(e.tmp.path);
          if (userId != null && dup.uploaderId == userId) {
            repaired.add(
              RepairedAsset(
                id: dup.id,
                filename: e.info.filename,
                ext: e.info.ext,
                kind: e.info.kind,
                size: e.info.size,
                sha256: e.info.sha256,
              ),
            );
          } else {
            duplicates.add({'name': e.info.filename, 'from': '?'});
          }
          return;
        }
        final id = await insertAsset(e.info);
        final dest = File(p.join(orig.path, '$id.${e.info.ext}'));
        trackFile?.call(dest.path);
        try {
          await _renameReplace(e.tmp, dest);
        } catch (_) {
          untrackFile?.call(dest.path);
          if (deleteAsset != null) {
            try {
              await deleteAsset(id);
            } catch (_) {}
          }
          try {
            if (e.tmp.existsSync()) await e.tmp.delete();
          } catch (_) {}
          untrackFile?.call(e.tmp.path);
          rethrow;
        }
        tmpFiles.remove(e.tmp);
        untrackFile?.call(e.tmp.path);
        accepted.add(
          IngestedAsset(
            id: id,
            filename: e.info.filename,
            ext: e.info.ext,
            kind: e.info.kind,
            size: e.info.size,
            sha256: e.info.sha256,
            file: dest,
          ),
        );
      });
    }
    await it.cancel();
    await sub.cancel();
  } catch (_) {
    for (final a in accepted) {
      untrackFile?.call(a.file.path);
    }
    await cleanupTmp();
    rethrow;
  }

  for (final a in accepted) {
    untrackFile?.call(a.file.path);
  }

  return UploadIngestResult(
    accepted: accepted,
    duplicates: duplicates,
    rejected: rejected,
    repaired: repaired,
    liveFile: liveFile,
    previewFile: previewFile,
    meta: meta,
  );
}

Future<void> _renameReplace(File tmp, File dest) async {
  try {
    await tmp.rename(dest.path);
  } on FileSystemException {
    await tmp.copy(dest.path);
    try {
      await tmp.delete();
    } catch (_) {}
  }
}

String? _headerParam(String header, String key) {
  return RegExp('$key="([^"]*)"').firstMatch(header)?.group(1);
}

String _tmpId() {
  final n = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  final r = Random().nextInt(0x7fffffff).toRadixString(16);
  return '$n$r';
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
