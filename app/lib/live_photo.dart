/// Android Motion Photo / 苹果 Live Photo 配对资源。
/// 原始照片与动态视频成套；缩略图只是派生，不能取代原件。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// 动态部分至少要超过这个长度，才可能是可配对的视频，而不是空壳或截断文件。
const minLiveVideoBytes = 1000;

const _xmpNs = 'http://ns.adobe.com/xap/1.0/';

/// Android has one portable Motion Photo container, but some galleries only
/// recognize files carrying their own vendor markers.  Keep the target profile
/// explicit so a file downloaded on vivo is never stamped as an OPlus camera
/// asset (and vice versa).
enum AndroidMotionPhotoProfile { google, oplus, vivo }

extension AndroidMotionPhotoProfileWire on AndroidMotionPhotoProfile {
  String get wireName => name;
}

AndroidMotionPhotoProfile androidMotionPhotoProfileFromWire(Object? raw) {
  final value = raw?.toString().trim().toLowerCase();
  return AndroidMotionPhotoProfile.values.firstWhere(
    (profile) => profile.name == value,
    orElse: () => AndroidMotionPhotoProfile.google,
  );
}

/// Pick the exporter for the phone that is saving the asset, not the phone
/// that originally shot it.  Brand is checked as well as manufacturer because
/// several OEMs report parent-company or regional values here.
AndroidMotionPhotoProfile androidMotionPhotoProfileForDevice({
  required String manufacturer,
  required String brand,
}) {
  final device = '${manufacturer.toLowerCase()} ${brand.toLowerCase()}';
  if (const ['oppo', 'oneplus', 'realme', 'oplus'].any(device.contains)) {
    return AndroidMotionPhotoProfile.oplus;
  }
  if (const ['vivo', 'iqoo'].any(device.contains)) {
    return AndroidMotionPhotoProfile.vivo;
  }
  return AndroidMotionPhotoProfile.google;
}

bool isJpegBytes(List<int> bytes) =>
    bytes.length >= 4 && bytes[0] == 0xFF && bytes[1] == 0xD8;

/// 已封装的动态照片：JPEG 尾部跟 MP4，并带 Motion Photo 元数据。
class MotionPhotoInfo {
  const MotionPhotoInfo({
    required this.videoOffset,
    required this.videoLength,
    this.presentationTimestampUs,
    this.hasXmpFlag = false,
    this.gainMapOffset,
    this.gainMapLength,
  });

  final int videoOffset;
  final int videoLength;
  final int? presentationTimestampUs;
  final bool hasXmpFlag;
  final int? gainMapOffset;
  final int? gainMapLength;

  bool get looksComplete => videoLength >= minLiveVideoBytes && videoOffset > 0;
}

int? motionVideoOffset(List<int> bytes) => parseMotionPhoto(bytes)?.videoOffset;

MotionPhotoInfo? parseMotionPhoto(List<int> bytes) {
  if (!isJpegBytes(bytes) || bytes.length < 128) return null;
  final fromXmp = _infoFromXmp(bytes);
  if (fromXmp != null && _videoAt(bytes, fromXmp.videoOffset)) {
    return fromXmp;
  }
  final scanned = _scanFtypOffset(bytes);
  if (scanned == null) return null;
  final len = bytes.length - scanned;
  if (len < minLiveVideoBytes || !_videoAt(bytes, scanned)) return null;
  final gainMapLength = fromXmp?.gainMapLength;
  final gainMapOffset = gainMapLength != null && scanned > gainMapLength
      ? scanned - gainMapLength
      : fromXmp?.gainMapOffset;
  return MotionPhotoInfo(
    videoOffset: scanned,
    videoLength: len,
    presentationTimestampUs: fromXmp?.presentationTimestampUs,
    hasXmpFlag: fromXmp?.hasXmpFlag ?? false,
    gainMapOffset: gainMapOffset,
    gainMapLength: gainMapLength,
  );
}

Uint8List? extractMotionVideo(List<int> bytes) {
  final info = parseMotionPhoto(bytes);
  if (info == null || !info.looksComplete) return null;
  if (info.videoOffset >= bytes.length - 32) return null;
  return trimLiveVideoToIsoMedia(
    bytes.sublist(info.videoOffset, info.videoOffset + info.videoLength),
  );
}

/// HDR Gain Map sits between the primary JPEG and the motion video.
Uint8List? extractMotionGainMap(List<int> bytes) {
  final info = parseMotionPhoto(bytes);
  final offset = info?.gainMapOffset;
  final length = info?.gainMapLength;
  if (info == null || offset == null || length == null) return null;
  if (length < 32 || offset < 2 || offset + length > info.videoOffset) {
    return null;
  }
  final slice = bytes.sublist(offset, offset + length);
  if (!isJpegBytes(slice)) return null;
  return Uint8List.fromList(slice);
}

/// Top-level ISO-BMFF boxes that belong to a portable Motion Photo video.
/// Vendor `uuid` tails (vivoMediaEStream / realme GT trailer) stay out.
const _isoMediaBoxTypes = {
  'ftyp',
  'free',
  'mdat',
  'moov',
  'moof',
  'mfra',
  'skip',
  'wide',
  'sidx',
  'ssix',
};

int isoMediaUsableLength(List<int> bytes) {
  var offset = 0;
  var lastGood = 0;
  final n = bytes.length;
  while (offset + 8 <= n) {
    int uint32(int at) =>
        (bytes[at] << 24) |
        (bytes[at + 1] << 16) |
        (bytes[at + 2] << 8) |
        bytes[at + 3];
    var size = uint32(offset);
    final type = ascii.decode(
      bytes.sublist(offset + 4, offset + 8),
      allowInvalid: true,
    );
    var header = 8;
    if (size == 1) {
      if (offset + 16 > n) break;
      size = uint32(offset + 8) * 0x100000000 + uint32(offset + 12);
      header = 16;
    } else if (size == 0) {
      size = n - offset;
    }
    if (offset == 0 && (type != 'ftyp' || size < 16)) return 0;
    if (size < header || size > n - offset) break;
    if (!_isoMediaBoxTypes.contains(type)) break;
    offset += size;
    lastGood = offset;
  }
  return lastGood;
}

/// Drop vendor uuid tails and the undocumented realme trailer after `moov`.
Uint8List trimLiveVideoToIsoMedia(List<int> bytes) {
  final usable = isoMediaUsableLength(bytes);
  if (usable >= minLiveVideoBytes &&
      usable <= bytes.length &&
      isStructurallyCompleteLiveVideo(bytes.sublist(0, usable))) {
    return Uint8List.fromList(bytes.sublist(0, usable));
  }
  return Uint8List.fromList(bytes);
}

int _u32At(List<int> bytes, int at) =>
    (bytes[at] << 24) |
    (bytes[at + 1] << 16) |
    (bytes[at + 2] << 8) |
    bytes[at + 3];

int _u64At(List<int> bytes, int at) =>
    _u32At(bytes, at) * 0x100000000 + _u32At(bytes, at + 4);

void _writeU32(Uint8List bytes, int at, int value) {
  bytes[at] = (value >> 24) & 0xFF;
  bytes[at + 1] = (value >> 16) & 0xFF;
  bytes[at + 2] = (value >> 8) & 0xFF;
  bytes[at + 3] = value & 0xFF;
}

void _writeU64(Uint8List bytes, int at, int value) {
  _writeU32(bytes, at, (value >> 32) & 0xFFFFFFFF);
  _writeU32(bytes, at + 4, value & 0xFFFFFFFF);
}

const _isoChunkContainers = {'moov', 'trak', 'mdia', 'minf', 'stbl'};

typedef _IsoBox = ({
  String type,
  int offset,
  int size,
  int header,
  Uint8List data,
});

List<_IsoBox>? _readTopLevelIsoBoxes(List<int> bytes) {
  final boxes = <_IsoBox>[];
  var offset = 0;
  final n = bytes.length;
  while (offset + 8 <= n) {
    var size = _u32At(bytes, offset);
    final type = ascii.decode(
      bytes.sublist(offset + 4, offset + 8),
      allowInvalid: true,
    );
    var header = 8;
    if (size == 1) {
      if (offset + 16 > n) return null;
      size = _u64At(bytes, offset + 8);
      header = 16;
    } else if (size == 0) {
      size = n - offset;
    }
    if (offset == 0 && (type != 'ftyp' || size < 16)) return null;
    if (size < header || size > n - offset) break;
    if (!_isoMediaBoxTypes.contains(type)) break;
    boxes.add((
      type: type,
      offset: offset,
      size: size,
      header: header,
      data: Uint8List.fromList(bytes.sublist(offset, offset + size)),
    ));
    offset += size;
  }
  return boxes;
}

Uint8List _withExplicitSize(Uint8List data) {
  if (data.length < 8) return data;
  if (_u32At(data, 0) != 0) return data;
  if (data.length > 0xFFFFFFFF) {
    throw ArgumentError('ISO box too large for 32-bit size');
  }
  final out = Uint8List.fromList(data);
  _writeU32(out, 0, data.length);
  return out;
}

bool _rewriteChunkTable(
  Uint8List data,
  int offset,
  int size,
  int header,
  bool wide,
  int? Function(int old) map,
) {
  final body = offset + header;
  if (body + 8 > offset + size) return false;
  if (data[body] != 0) return false;
  final count = _u32At(data, body + 4);
  if (count < 0) return false;
  final width = wide ? 8 : 4;
  if (header + 8 + count * width > size) return false;
  for (var i = 0; i < count; i++) {
    final at = body + 8 + i * width;
    final old = wide ? _u64At(data, at) : _u32At(data, at);
    final next = map(old);
    if (next == null || next < 0) return false;
    if (wide) {
      _writeU64(data, at, next);
    } else {
      if (next > 0xFFFFFFFF) return false;
      _writeU32(data, at, next);
    }
  }
  return true;
}

bool _patchChunkOffsetTables(
  Uint8List data,
  int start,
  int end,
  int? Function(int old) map,
  void Function() onTable,
) {
  var offset = start;
  while (offset + 8 <= end) {
    var size = _u32At(data, offset);
    final type = ascii.decode(
      data.sublist(offset + 4, offset + 8),
      allowInvalid: true,
    );
    var header = 8;
    if (size == 1) {
      if (offset + 16 > end) return false;
      size = _u64At(data, offset + 8);
      header = 16;
    } else if (size == 0) {
      size = end - offset;
    }
    if (size < header || offset + size > end) return false;
    if (type == 'stco' || type == 'co64') {
      onTable();
      if (!_rewriteChunkTable(
        data,
        offset,
        size,
        header,
        type == 'co64',
        map,
      )) {
        return false;
      }
    } else if (type == 'saio') {
      return false;
    } else if (_isoChunkContainers.contains(type)) {
      if (!_patchChunkOffsetTables(
        data,
        offset + header,
        offset + size,
        map,
        onTable,
      )) {
        return false;
      }
    }
    offset += size;
  }
  return true;
}

void _collectChunkOffsets(Uint8List data, int start, int end, List<int> out) {
  var offset = start;
  while (offset + 8 <= end) {
    var size = _u32At(data, offset);
    final type = ascii.decode(
      data.sublist(offset + 4, offset + 8),
      allowInvalid: true,
    );
    var header = 8;
    if (size == 1) {
      if (offset + 16 > end) return;
      size = _u64At(data, offset + 8);
      header = 16;
    } else if (size == 0) {
      size = end - offset;
    }
    if (size < header || offset + size > end) return;
    if (type == 'stco' || type == 'co64') {
      final body = offset + header;
      if (body + 8 <= offset + size && data[body] == 0) {
        final count = _u32At(data, body + 4);
        final width = type == 'co64' ? 8 : 4;
        if (header + 8 + count * width <= size) {
          for (var i = 0; i < count; i++) {
            final at = body + 8 + i * width;
            out.add(type == 'co64' ? _u64At(data, at) : _u32At(data, at));
          }
        }
      }
    } else if (_isoChunkContainers.contains(type)) {
      _collectChunkOffsets(data, offset + header, offset + size, out);
    }
    offset += size;
  }
}

List<String> isoMediaTopLevelTypes(List<int> bytes) {
  final boxes = _readTopLevelIsoBoxes(bytes);
  if (boxes == null) return const [];
  return [for (final box in boxes) box.type];
}

/// Absolute file offsets from every `stco` / `co64` table. Empty if the file
/// has no movie box or no chunk offset table.
List<int> isoMediaChunkOffsets(List<int> bytes) {
  final boxes = _readTopLevelIsoBoxes(bytes);
  if (boxes == null) return const [];
  final out = <int>[];
  for (final box in boxes) {
    if (box.type != 'moov') continue;
    _collectChunkOffsets(box.data, box.header, box.data.length, out);
  }
  return out;
}

Uint8List? _isoMediaMoovAtEnd(List<int> bytes) {
  final boxes = _readTopLevelIsoBoxes(bytes);
  if (boxes == null || boxes.isEmpty) return null;
  _IsoBox? ftyp;
  _IsoBox? moov;
  _IsoBox? mdat;
  var moovCount = 0;
  var mdatCount = 0;
  for (final box in boxes) {
    if (box.type == 'moof' || box.type == 'mfra') return null;
    if (box.type == 'ftyp') {
      ftyp ??= box;
    } else if (box.type == 'moov') {
      moovCount++;
      moov = box;
    } else if (box.type == 'mdat') {
      mdatCount++;
      mdat = box;
    }
  }
  if (ftyp == null || moov == null || mdat == null) return null;
  if (moovCount != 1 || mdatCount != 1) return null;

  final ordered = <_IsoBox>[ftyp];
  for (final box in boxes) {
    if (box.type == 'ftyp' || box.type == 'moov' || box.type == 'mdat') {
      continue;
    }
    ordered.add(box);
  }
  ordered.add(mdat);
  ordered.add(moov);

  var cursor = 0;
  final newOffsets = <int, int>{};
  for (final box in ordered) {
    newOffsets[box.offset] = cursor;
    cursor += box.size;
  }
  final newMdatOffset = newOffsets[mdat.offset]!;
  final shift = newMdatOffset - mdat.offset;
  final payloadStart = mdat.offset + mdat.header;
  final payloadEnd = mdat.offset + mdat.size;
  final moovOut = Uint8List.fromList(moov.data);
  var tables = 0;
  if (!_patchChunkOffsetTables(moovOut, moov.header, moovOut.length, (old) {
    if (old < payloadStart || old >= payloadEnd) return null;
    return old + shift;
  }, () => tables++)) {
    return null;
  }
  if (tables == 0 && shift != 0) return null;

  final last = boxes.last;
  final trailer = _nonUuidTrailer(bytes, last.offset + last.size);
  final out = BytesBuilder(copy: false);
  for (final box in ordered) {
    out.add(_withExplicitSize(box.type == 'moov' ? moovOut : box.data));
  }
  if (trailer.isNotEmpty) out.add(trailer);
  final result = out.toBytes();
  if (!isStructurallyCompleteLiveVideo(
    result.sublist(0, isoMediaUsableLength(result)),
  )) {
    return null;
  }
  return result;
}

Uint8List _nonUuidTrailer(List<int> bytes, int start) {
  var offset = start;
  final n = bytes.length;
  while (offset + 8 <= n) {
    var size = _u32At(bytes, offset);
    final type = ascii.decode(
      bytes.sublist(offset + 4, offset + 8),
      allowInvalid: true,
    );
    var header = 8;
    if (size == 1) {
      if (offset + 16 > n) break;
      size = _u64At(bytes, offset + 8);
      header = 16;
    } else if (size == 0) {
      size = n - offset;
    }
    if (size < header || offset + size > n) break;
    if (type != 'uuid') break;
    offset += size;
  }
  if (offset >= n) return Uint8List(0);
  return Uint8List.fromList(bytes.sublist(offset));
}

/// ColorOS 实况播放器按相机原片来：ftyp / free / mdat / moov。
/// MediaMuxer 常把 moov 提前；移动 mdat 后必须改写 stco/co64，否则
/// 外层盒子仍合法，播放器却读到错误的音视频数据。
Uint8List isoMediaMoovAtEnd(List<int> bytes) {
  final result = _isoMediaMoovAtEnd(bytes);
  if (result == null) {
    throw ArgumentError(
      'cannot move moov after mdat without updating chunk offsets',
    );
  }
  return result;
}

bool isoMediaMoovAtEndFile(List<String> paths) {
  if (paths.length != 2) return false;
  try {
    final ordered = _isoMediaMoovAtEnd(File(paths[0]).readAsBytesSync());
    if (ordered == null || !isStructurallyCompleteLiveVideo(ordered)) {
      return false;
    }
    final dest = File(paths[1]);
    dest.parent.createSync(recursive: true);
    dest.writeAsBytesSync(ordered, flush: true);
    return liveVideoFileReady(dest);
  } catch (_) {
    return false;
  }
}

bool shouldAdaptAndroidLive({
  required bool hasLiveFlag,
  required bool stillHasEmbeddedLive,
}) =>
    hasLiveFlag || stillHasEmbeddedLive;

/// 把 JPEG 静图和 MP4/MOV 动态部分封装成一个 Motion Photo 文件。
///
/// 只写 Motion Photo 1.0 Container。ColorOS 16 的图库解析器看到旧版
/// `GCamera:MicroVideoVersion` 会直接放弃整个 XMP，即使文件同时带有完整的
/// Motion Photo 字段，最终就会出现 MediaProvider 标记为 Live、图库却只显示
/// 静图的矛盾状态。
Uint8List buildMotionPhotoJpeg(
  List<int> jpeg,
  List<int> video, {
  int presentationTimestampUs = -1,
  AndroidMotionPhotoProfile profile = AndroidMotionPhotoProfile.google,
  List<int>? gainMap,
  bool trimVendor = true,
}) {
  if (!isJpegBytes(jpeg)) {
    throw ArgumentError('still is not JPEG');
  }
  final clip =
      trimVendor ? trimLiveVideoToIsoMedia(video) : Uint8List.fromList(video);
  final isoLen = isoMediaUsableLength(clip);
  final playable = isoLen >= minLiveVideoBytes && isoLen <= clip.length
      ? clip.sublist(0, isoLen)
      : clip;
  if (!isStructurallyCompleteLiveVideo(playable)) {
    throw ArgumentError('live video is not a usable MP4/MOV');
  }
  final map = gainMap != null && isJpegBytes(gainMap)
      ? Uint8List.fromList(gainMap)
      : null;
  final still = jpegStillBytes(jpeg);
  final isOplus = profile == AndroidMotionPhotoProfile.oplus;
  // Rebuild MPF from final byte positions. Reusing a source index after XMP
  // replacement leaves the primary size (and sometimes the gain-map offset)
  // stale. ColorOS' OLive decoder actually reads these entries.
  final stripped = _withoutXmpApp1(still, removeMpf: isOplus);
  final xmp = _motionXmp(
    isOplus ? clip.length : playable.length,
    presentationTimestampUs,
    liveVideoMime(playable),
    profile,
    gainMapLength: map?.length ?? 0,
    containerVideoLength: clip.length,
  );
  final app1 = _xmpApp1(xmp);
  final insertAt = _jpegXmpInsertAt(stripped);
  final out = BytesBuilder(copy: false);
  out.add(stripped.sublist(0, insertAt));
  out.add(app1);
  if (isOplus) {
    final mpfSize = 58 + (map == null ? 16 : 32);
    final primarySize = stripped.length + app1.length + mpfSize;
    final tiffStart = insertAt + app1.length + 8;
    out.add(_motionMpfApp2(primarySize, map?.length, primarySize - tiffStart));
  }
  out.add(stripped.sublist(insertAt));
  if (map != null) out.add(map);
  out.add(clip);
  return out.toBytes();
}

/// MPF uses offsets relative to its TIFF header, except the primary image,
/// whose offset is zero. Only images actually appended are indexed.
Uint8List _motionMpfApp2(int primarySize, int? gainSize, int gainOffset) {
  final count = gainSize == null ? 1 : 2;
  final bytes = Uint8List(58 + 16 * count);
  final data = ByteData.sublistView(bytes);
  bytes.setRange(0, 8, [0xff, 0xe2, 0, 0, 0x4d, 0x50, 0x46, 0]);
  data.setUint16(2, bytes.length - 2);
  data.setUint16(8, 0x4d4d); // Big-endian TIFF.
  data.setUint16(10, 42);
  data.setUint32(12, 8);
  data.setUint16(16, 3);
  void tag(int at, int id, int type, int size, int value) {
    data.setUint16(at, id);
    data.setUint16(at + 2, type);
    data.setUint32(at + 4, size);
    data.setUint32(at + 8, value);
  }

  tag(18, 0xb000, 7, 4, 0x30313030); // MPFVersion 0100.
  tag(30, 0xb001, 4, 1, count);
  tag(42, 0xb002, 7, 16 * count, 50);
  data.setUint32(58, 0x030000); // Baseline primary image.
  data.setUint32(62, primarySize);
  if (gainSize != null) {
    data.setUint32(78, gainSize);
    data.setUint32(82, gainOffset);
  }
  return bytes;
}

/// 去掉尾部动态视频，只留 JPEG（含 EOI）。
Uint8List jpegStillBytes(List<int> jpeg) {
  if (!isJpegBytes(jpeg)) return Uint8List.fromList(jpeg);
  final eoi = _jpegEoiIndex(jpeg);
  if (eoi != null) {
    return Uint8List.fromList(jpeg.sublist(0, eoi + 2));
  }
  final info = parseMotionPhoto(jpeg);
  if (info != null && info.videoOffset > 2) {
    return Uint8List.fromList(jpeg.sublist(0, info.videoOffset));
  }
  return Uint8List.fromList(jpeg);
}

bool isCompleteMotionPhoto(List<int> bytes) {
  final info = parseMotionPhoto(bytes);
  return info != null && info.looksComplete && info.hasXmpFlag;
}

/// Top-level isolate callbacks. Only paths, numbers and collections of those
/// cross the isolate boundary; UI closures and progress completers never do.
bool motionPhotoFileComplete(String path) {
  try {
    return isCompleteMotionPhoto(File(path).readAsBytesSync());
  } catch (_) {
    return false;
  }
}

bool motionPhotoFileHasEmbedded(String path) {
  try {
    return extractMotionVideo(File(path).readAsBytesSync()) != null;
  } catch (_) {
    return false;
  }
}

/// Read JPEG APP1 metadata with seeks; never read compressed image/video data.
/// Limits also bound work for malformed camera files. Used off the UI isolate.
Uint8List readJpegMetadata(String path) {
  final input = File(path).openSync();
  try {
    final result = BytesBuilder()..add([0xff, 0xd8]);
    if (!isJpegBytes([...input.readSync(2), 0, 0])) return Uint8List(0);
    final length = input.lengthSync();
    var offset = 2;
    for (var segment = 0; segment < 256 && offset + 4 <= length; segment++) {
      input.setPositionSync(offset);
      final head = input.readSync(4);
      if (head[0] != 0xff || head[1] == 0xda || head[1] == 0xd9) break;
      final size = head[2] * 256 + head[3];
      if (size < 2 || offset + 2 + size > length) break;
      if (head[1] == 0xe1) {
        if (result.length + size > 2 * 1024 * 1024) break;
        result.add(head);
        result.add(input.readSync(size - 2));
      }
      offset += size + 2;
    }
    result.add([0xff, 0xd9]);
    return result.takeBytes();
  } finally {
    input.closeSync();
  }
}

/// Lightweight grid detection: metadata + ISO box headers, not full extraction.
bool probeLocalLivePhoto(String path) {
  try {
    final file = File(path);
    final info = _infoFromXmp(
      readJpegMetadata(path),
      fileLength: file.lengthSync(),
    );
    if (info != null) {
      final input = file.openSync();
      try {
        if (_completeVideo(info.videoLength, (offset, length) {
          input.setPositionSync(info.videoOffset + offset);
          return input.readSync(length);
        })) {
          return true;
        }
      } finally {
        input.closeSync();
      }
    }
    return siblingLiveVideo(path) != null;
  } catch (_) {
    return false;
  }
}

/// 从相册里的 Motion Photo 原件提取临时预览视频。
///
/// 作为 isolate 入口只接收字符串，避免在 UI isolate 读取整张原片。
bool extractMotionVideoFile(List<String> paths) {
  if (paths.length != 2) return false;
  try {
    final source = File(paths[0]);
    final dest = File(paths[1]);
    final video = extractMotionVideo(source.readAsBytesSync());
    if (video == null) return false;
    dest.parent.createSync(recursive: true);
    dest.writeAsBytesSync(video, flush: true);
    return liveVideoFileReady(dest);
  } catch (_) {
    return false;
  }
}

int? recoverLiveSidecarFromPaths(List<String> paths) {
  if (paths.length != 2) return null;
  try {
    final bytes = File(paths[0]).readAsBytesSync();
    if (!writeLiveSidecarFromStill(bytes, File(paths[1]))) return null;
    return parseMotionPhoto(bytes)?.presentationTimestampUs ?? -1;
  } catch (_) {
    return null;
  }
}

bool buildMotionPhotoFile(Map<String, Object?> args) {
  final jpegPath = args['jpeg'] as String;
  final stillPath = args['still'] as String;
  final videoPath = args['video'] as String;
  final outputPath = args['output'] as String;
  final fallback = (args['fallback'] as num?)?.toInt();
  final stillBytes = File(stillPath).readAsBytesSync();
  final jpegBytes = File(jpegPath).readAsBytesSync();
  final keepGainMap = args['keepGainMap'] == true;
  final keepUuidTails = args['keepUuidTails'] == true;
  final muxed = buildMotionPhotoJpeg(
    jpegBytes,
    File(videoPath).readAsBytesSync(),
    presentationTimestampUs: livePresentationUs(stillBytes, fallback: fallback),
    profile: androidMotionPhotoProfileFromWire(args['profile']),
    gainMap: keepGainMap ? extractMotionGainMap(stillBytes) : null,
    trimVendor: !keepUuidTails,
  );
  File(outputPath).writeAsBytesSync(muxed, flush: true);
  return true;
}

bool copyJpegPrimaryFile(List<String> paths) {
  if (paths.length != 2) return false;
  try {
    final bytes = File(paths[0]).readAsBytesSync();
    if (!isJpegBytes(bytes)) return false;
    final dest = File(paths[1]);
    dest.parent.createSync(recursive: true);
    dest.writeAsBytesSync(jpegStillBytes(bytes), flush: true);
    return dest.lengthSync() > 2;
  } catch (_) {
    return false;
  }
}

bool trimLiveVideoFile(List<String> paths) {
  if (paths.length != 2) return false;
  try {
    final trimmed = trimLiveVideoToIsoMedia(File(paths[0]).readAsBytesSync());
    if (!isStructurallyCompleteLiveVideo(trimmed)) return false;
    final dest = File(paths[1]);
    dest.parent.createSync(recursive: true);
    dest.writeAsBytesSync(trimmed, flush: true);
    return liveVideoFileReady(dest);
  } catch (_) {
    return false;
  }
}

bool motionPhotoFilesMatch(List<String> paths) {
  if (paths.length != 2) return false;
  try {
    final saved = File(paths[0]).readAsBytesSync();
    final source = File(paths[1]).readAsBytesSync();
    if (saved.length != source.length) return false;
    for (var i = 0; i < saved.length; i++) {
      if (saved[i] != source[i]) return false;
    }
    return isCompleteMotionPhoto(saved);
  } catch (_) {
    return false;
  }
}

/// 封装时用的关键照片时间点：优先静图 XMP，其次调用方提供的值，没有则 -1。
int livePresentationUs(List<int> stillBytes, {int? fallback}) {
  final pts = parseMotionPhoto(stillBytes)?.presentationTimestampUs;
  if (pts != null && pts >= 0) return pts;
  if (fallback != null && fallback >= 0) return fallback;
  return -1;
}

/// 从完整静图（Motion Photo JPEG）抽出动态部分写成 sidecar。
/// 旧数据只有内嵌视频、没有 `$id.live.mp4` 时用来补齐，不能凭静图发明动态。
bool writeLiveSidecarFromStill(List<int> stillBytes, File dest) {
  final video = extractMotionVideo(stillBytes);
  if (video == null) return false;
  dest.parent.createSync(recursive: true);
  dest.writeAsBytesSync(video, flush: true);
  return liveVideoFileReady(dest);
}

String? siblingLiveVideo(String imagePath) {
  final dir = File(imagePath).parent.path;
  final base = p.basenameWithoutExtension(imagePath);
  for (final ext in const ['mp4', 'mov', 'MP4', 'MOV', 'm4v']) {
    final f = File(p.join(dir, '$base.$ext'));
    if (liveVideoFileReady(f)) return f.path;
  }
  return null;
}

/// ISO BMFF / QuickTime：size + 'ftyp'。改后缀不能让任意字节变成视频。
bool looksLikeVideoContainer(List<int> bytes) {
  if (bytes.length < 8) return false;
  return bytes[4] == 0x66 &&
      bytes[5] == 0x74 &&
      bytes[6] == 0x79 &&
      bytes[7] == 0x70;
}

String liveVideoMime(List<int> bytes) => bytes.length >= 12 &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'qt  '
    ? 'video/quicktime'
    : 'video/mp4';

/// Reads only the ISO BMFF header, so callers can choose a platform-specific
/// compatibility path without loading a Live video into the UI isolate.
String liveVideoFileMime(String path) {
  try {
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() < 12) return 'video/mp4';
    final input = file.openSync();
    try {
      return liveVideoMime(input.readSync(12));
    } finally {
      input.closeSync();
    }
  } catch (_) {
    return 'video/mp4';
  }
}

/// Bounds-check every top-level box, requiring movie metadata and media data.
/// This checks transport integrity; native decoders still decide codec support.
bool isStructurallyCompleteLiveVideo(List<int> bytes) => _completeVideo(
      bytes.length,
      (offset, length) => bytes.sublist(offset, offset + length),
    );

bool _completeVideo(int length, List<int> Function(int, int) read) {
  if (length < minLiveVideoBytes) return false;
  var offset = 0;
  var movie = false;
  var media = false;
  while (offset < length) {
    if (length - offset < 8) return false;
    final head = read(offset, length - offset >= 16 ? 16 : 8);
    int uint32(int at) =>
        (head[at] << 24) |
        (head[at + 1] << 16) |
        (head[at + 2] << 8) |
        head[at + 3];
    var size = uint32(0);
    final type = ascii.decode(head.sublist(4, 8), allowInvalid: true);
    if (offset == 0 && (type != 'ftyp' || size < 16)) return false;
    var headerSize = 8;
    if (size == 1) {
      if (head.length < 16) return false;
      size = uint32(8) * 0x100000000 + uint32(12);
      headerSize = 16;
    } else if (size == 0) {
      size = length - offset;
    }
    if (size < headerSize || size > length - offset) return false;
    if (type == 'moov' && size > headerSize) movie = true;
    if (type == 'mdat' && size > headerSize) media = true;
    offset += size;
  }
  return movie && media;
}

bool liveVideoFileReady(File f) {
  try {
    if (!f.existsSync()) return false;
    if (f.lengthSync() < minLiveVideoBytes) return false;
    final raf = f.openSync();
    try {
      return _completeVideo(raf.lengthSync(), (offset, length) {
        raf.setPositionSync(offset);
        return raf.readSync(length);
      });
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return false;
  }
}

bool liveVideoPathReady(String path) => liveVideoFileReady(File(path));

/// WeChat's confirmed ColorOS export preserves moov-first MP4 and vivo UUIDs.
/// QuickTime still goes through the native MP4/AAC normalizer.
bool liveVideoCanPreserveOplusContainer(String path) {
  try {
    if (liveVideoFileMime(path) != 'video/mp4') return false;
    final bytes = File(path).readAsBytesSync();
    final usable = isoMediaUsableLength(bytes);
    if (usable < minLiveVideoBytes || usable > bytes.length) return false;
    if (!isStructurallyCompleteLiveVideo(bytes.sublist(0, usable))) {
      return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// 静图本身已是 ColorOS 实况（含 moov 后的非 uuid 尾巴）。
/// 下载自己上传的原片时应原样落盘，不能拆成 sidecar 再重封装。
bool stillHasColorOsLiveTrailer(String path) {
  try {
    final bytes = File(path).readAsBytesSync();
    final info = parseMotionPhoto(bytes);
    if (info == null || !info.looksComplete) return false;
    final end = info.videoOffset + info.videoLength;
    if (info.videoOffset < 0 || end > bytes.length) return false;
    final vid = bytes.sublist(info.videoOffset, end);
    final usable = isoMediaUsableLength(vid);
    if (usable < minLiveVideoBytes || usable + 8 > vid.length) return false;
    if (!isStructurallyCompleteLiveVideo(vid.sublist(0, usable))) return false;
    final type = ascii.decode(
      vid.sublist(usable + 4, usable + 8),
      allowInvalid: true,
    );
    return type != 'uuid';
  } catch (_) {
    return false;
  }
}

/// 盒子侧素材分类：完整配对 / 有标记但需核验 / 原片或动态缺失。
enum LiveResourceStatus { complete, needsVerify, missing }

/// 相册里挑到的静图要不要带动态、以哪种方式成套上传。
/// 返回 null 表示这是实况/动态照片但动态不可用，不能当静图上传。
enum LiveUploadKind { stillOnly, applePair, embeddedMotion, siblingVideo }

LiveUploadKind? classifyLiveUpload({
  required bool isLivePhoto,
  required bool stillHasEmbeddedLive,
  required bool pairedVideoReady,
  required bool siblingReady,
}) {
  if (isLivePhoto) {
    if (pairedVideoReady) return LiveUploadKind.applePair;
    if (stillHasEmbeddedLive) return LiveUploadKind.embeddedMotion;
    return null;
  }
  if (stillHasEmbeddedLive) return LiveUploadKind.embeddedMotion;
  if (siblingReady) return LiveUploadKind.siblingVideo;
  return LiveUploadKind.stillOnly;
}

LiveResourceStatus classifyLiveResource({
  required bool hasLiveFlag,
  required int stillBytes,
  required int liveBytes,
  required bool liveLooksLikeVideo,
}) {
  if (stillBytes <= 0) return LiveResourceStatus.missing;
  final liveOk = liveBytes >= minLiveVideoBytes && liveLooksLikeVideo;
  if (liveOk) return LiveResourceStatus.complete;
  if (hasLiveFlag || liveBytes > 0) return LiveResourceStatus.needsVerify;
  return LiveResourceStatus.missing;
}

bool _videoAt(List<int> bytes, int offset) {
  final eoi = _jpegEoiIndex(bytes);
  if (eoi == null || offset < eoi + 2 || offset + 8 > bytes.length) {
    return false;
  }
  return _completeVideo(
    bytes.length - offset,
    (at, length) => bytes.sublist(offset + at, offset + at + length),
  );
}

int? _scanFtypOffset(List<int> bytes) {
  const f = 0x66, t = 0x74, y = 0x79, pCode = 0x70;
  final eoi = _jpegEoiIndex(bytes);
  if (eoi == null) return null;
  final start = eoi + 6;
  final last = bytes.length - 12;
  for (var i = start; i < last; i++) {
    if (bytes[i] == f &&
        bytes[i + 1] == t &&
        bytes[i + 2] == y &&
        bytes[i + 3] == pCode &&
        i >= 4) {
      if (_videoAt(bytes, i - 4)) return i - 4;
    }
  }
  return null;
}

MotionPhotoInfo? _infoFromXmp(List<int> bytes, {int? fileLength}) {
  final totalLength = fileLength ?? bytes.length;
  final text = _jpegXmpText(bytes);
  if (text == null) return null;
  final hasFlag = RegExp(r'''(?:MotionPhoto|MicroVideo)\s*=\s*["']1["']''')
          .hasMatch(text) &&
      !RegExp(r'''MotionPhoto\s*=\s*["']0["']''').hasMatch(text);
  final ts = int.tryParse(
    RegExp(
          r'(?:MotionPhotoPresentationTimestampUs|MicroVideoPresentationTimestampUs)\s*=\s*"(-?\d+)"',
        ).firstMatch(text)?.group(1) ??
        '',
  );
  var videoLen = int.tryParse(
    RegExp(r'MicroVideoOffset\s*=\s*"(\d+)"').firstMatch(text)?.group(1) ?? '',
  );
  int? gainMapLen;
  for (final item in RegExp(r'<Container:Item\b([^>]*)/?>').allMatches(text)) {
    final attrs = item.group(1) ?? '';
    final semantic =
        RegExp(r'Item:Semantic\s*=\s*"([^"]*)"').firstMatch(attrs)?.group(1) ??
            '';
    final mime =
        RegExp(r'Item:Mime\s*=\s*"([^"]*)"').firstMatch(attrs)?.group(1) ?? '';
    final length = int.tryParse(
          RegExp(r'Item:Length\s*=\s*"(\d+)"').firstMatch(attrs)?.group(1) ??
              '',
        ) ??
        0;
    if (semantic == 'GainMap' && length >= 32) gainMapLen = length;
    if (semantic == 'MotionPhoto' || mime.startsWith('video/')) {
      if (length >= minLiveVideoBytes) videoLen = length;
    }
  }
  if (videoLen == null || videoLen < minLiveVideoBytes) {
    final lengths = RegExp(r'Item:Length\s*=\s*"(\d+)"')
        .allMatches(text)
        .map((m) => int.tryParse(m.group(1) ?? '') ?? 0)
        .where((n) => n >= minLiveVideoBytes)
        .toList();
    if (lengths.isNotEmpty) videoLen = lengths.last;
  }
  if (videoLen == null ||
      videoLen < minLiveVideoBytes ||
      videoLen >= totalLength - 8) {
    return null;
  }
  final videoOffset = totalLength - videoLen;
  final gainMapOffset = gainMapLen != null && videoOffset > gainMapLen
      ? videoOffset - gainMapLen
      : null;
  return MotionPhotoInfo(
    videoOffset: videoOffset,
    videoLength: videoLen,
    presentationTimestampUs: ts,
    hasXmpFlag: hasFlag,
    gainMapOffset: gainMapOffset,
    gainMapLength: gainMapLen,
  );
}

/// Reads XMP from its JPEG APP1 segment instead of assuming it is near the
/// start of the file. Phone cameras may place hundreds of kilobytes of EXIF,
/// gain-map, depth, or maker-note APP segments before the Motion Photo XMP.
String? _jpegXmpText(List<int> jpeg) {
  if (!isJpegBytes(jpeg) || jpeg.length < 6) return null;
  final signature = utf8.encode(_xmpNs);
  final packets = <String>[];
  var i = 2;
  while (i + 3 < jpeg.length && jpeg[i] == 0xFF) {
    final marker = jpeg[i + 1];
    if (marker == 0xDA || marker == 0xD9) break;
    if (marker == 0x00 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD8)) {
      i += 2;
      continue;
    }
    final len = (jpeg[i + 2] << 8) | jpeg[i + 3];
    final next = i + 2 + len;
    if (len < 2 || next > jpeg.length) break;
    final payloadOffset = i + 4;
    final payloadLength = len - 2;
    if (marker == 0xE1 && _isXmpApp1(jpeg, payloadOffset, payloadLength)) {
      var xmlOffset = payloadOffset + signature.length;
      if (xmlOffset < next && jpeg[xmlOffset] == 0) xmlOffset++;
      if (xmlOffset < next) {
        packets.add(
          utf8.decode(jpeg.sublist(xmlOffset, next), allowMalformed: true),
        );
      }
    }
    i = next;
  }
  return packets.isEmpty ? null : packets.join('\n');
}

int? _jpegEoiIndex(List<int> jpeg) {
  if (!isJpegBytes(jpeg)) return null;
  var i = 2;
  while (i + 1 < jpeg.length && jpeg[i] == 0xFF) {
    final marker = jpeg[i + 1];
    if (marker == 0xD9) return i;
    if (marker == 0xDA) {
      var j = i + 2;
      while (j + 1 < jpeg.length) {
        if (jpeg[j] != 0xFF) {
          j++;
          continue;
        }
        final m = jpeg[j + 1];
        if (m == 0x00) {
          j += 2;
          continue;
        }
        if (m == 0xD9) return j;
        if (m >= 0xD0 && m <= 0xD7) {
          j += 2;
          continue;
        }
        j += 2;
      }
      return null;
    }
    if (marker == 0x00 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD8)) {
      i += 2;
      continue;
    }
    if (i + 3 >= jpeg.length) break;
    final len = (jpeg[i + 2] << 8) | jpeg[i + 3];
    if (len < 2) break;
    i += 2 + len;
  }
  for (var k = jpeg.length - 2; k >= 2; k--) {
    if (jpeg[k] == 0xFF && jpeg[k + 1] == 0xD9) return k;
  }
  return null;
}

bool _isXmpApp1(List<int> jpeg, int payloadOff, int payloadLen) {
  final sig = utf8.encode(_xmpNs);
  if (payloadLen < sig.length) return false;
  for (var i = 0; i < sig.length; i++) {
    if (jpeg[payloadOff + i] != sig[i]) return false;
  }
  return true;
}

Uint8List _withoutXmpApp1(List<int> jpeg, {bool removeMpf = false}) {
  if (!isJpegBytes(jpeg) || jpeg.length < 6) {
    return Uint8List.fromList(jpeg);
  }
  final out = BytesBuilder(copy: false);
  out.add(jpeg.sublist(0, 2));
  var i = 2;
  while (i + 3 < jpeg.length && jpeg[i] == 0xFF) {
    final marker = jpeg[i + 1];
    if (marker == 0xDA || marker == 0xD9) break;
    if (marker == 0x00 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD8)) {
      out.add(jpeg.sublist(i, i + 2));
      i += 2;
      continue;
    }
    final len = (jpeg[i + 2] << 8) | jpeg[i + 3];
    final next = i + 2 + len;
    if (len < 2 || next > jpeg.length) break;
    if (marker == 0xE1 && _isXmpApp1(jpeg, i + 4, len - 2)) {
      i = next;
      continue;
    }
    if (removeMpf &&
        marker == 0xe2 &&
        len >= 6 &&
        jpeg[i + 4] == 0x4d &&
        jpeg[i + 5] == 0x50 &&
        jpeg[i + 6] == 0x46 &&
        jpeg[i + 7] == 0) {
      i = next;
      continue;
    }
    out.add(jpeg.sublist(i, next));
    i = next;
  }
  out.add(jpeg.sublist(i));
  return out.toBytes();
}

int _jpegXmpInsertAt(List<int> jpeg) {
  // ColorOS 原片是 EXIF → XMP → MPF。插到所有 APP 之后会把 MPF
  // 索引全部挪位，图库能标 Live 却播不出来。
  var i = 2;
  var insertAt = 2;
  while (i + 3 < jpeg.length && jpeg[i] == 0xFF) {
    final marker = jpeg[i + 1];
    if (marker == 0xDA || marker == 0xD9) break;
    if (marker == 0x00 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD8)) {
      i += 2;
      continue;
    }
    final len = (jpeg[i + 2] << 8) | jpeg[i + 3];
    final next = i + 2 + len;
    if (len < 2 || next > jpeg.length) break;
    if (marker == 0xE1 && _isXmpApp1(jpeg, i + 4, len - 2)) {
      i = next;
      continue;
    }
    if (marker == 0xE1) {
      insertAt = next;
      i = next;
      continue;
    }
    break;
  }
  return insertAt;
}

Uint8List _xmpApp1(String xml) {
  final payload = <int>[...utf8.encode(_xmpNs), 0, ...utf8.encode(xml)];
  final len = payload.length + 2;
  if (len > 0xFFFF) {
    throw StateError('XMP too large for JPEG APP1');
  }
  return Uint8List.fromList([
    0xFF,
    0xE1,
    (len >> 8) & 0xFF,
    len & 0xFF,
    ...payload,
  ]);
}

String _motionXmp(
  int videoLen,
  int presentationTimestampUs,
  String videoMime,
  AndroidMotionPhotoProfile profile, {
  int gainMapLength = 0,
  int? containerVideoLength,
}) {
  // ColorOS/OPlus MediaProvider requires its vendor ownership fields before it
  // exposes a standards-compliant Motion Photo as a Live Photo. Keep the
  // Google container fields as the source of truth for other Android devices.
  final keyFrameUs =
      presentationTimestampUs >= 0 ? presentationTimestampUs : 500000;
  final oplusNamespace = profile == AndroidMotionPhotoProfile.oplus
      ? '    xmlns:OpCamera="http://ns.oplus.com/photos/1.0/camera/"\n'
      : '';
  final oplusAttributes = profile == AndroidMotionPhotoProfile.oplus
      ? '''
    OpCamera:MotionPhotoPrimaryPresentationTimestampUs="$keyFrameUs"
    OpCamera:MotionPhotoOwner="oplus"
    OpCamera:OLivePhotoVersion="2"
    OpCamera:VideoLength="$videoLen"'''
      : '';
  // OriginOS' bundled MotionPhotoXmpParser reads these exact VCamera fields.
  // They were verified against both a vivo V2547DA camera original and the
  // parser shipped in vivo Gallery 10.2.5.8.  Keep the portable Google
  // container alongside them so other readers can still extract the video.
  final vivoNamespace = profile == AndroidMotionPhotoProfile.vivo
      ? '    xmlns:VCamera="http://ns.vivo.com/photos/1.0/camera/"\n'
      : '';
  final vivoAttributes = profile == AndroidMotionPhotoProfile.vivo
      ? '''
    VCamera:VMotionPhotoVersion="1"
    VCamera:VMotionPhotoSource="1"
    VCamera:VMediaKitVersion="1.0.0.9"'''
      : '';
  final gainMapItem = gainMapLength >= 32
      ? '''
      <rdf:li rdf:parseType="Resource">
       <Container:Item Item:Mime="image/jpeg" Item:Semantic="GainMap" Item:Length="$gainMapLength" Item:Padding="0"/>
      </rdf:li>
'''
      : '';
  final hdrgmNamespace = gainMapLength >= 32
      ? '    xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/"\n'
      : '';
  final hdrgmAttribute =
      gainMapLength >= 32 ? '\n      hdrgm:Version="1.0"' : '';
  final itemVideoLen = containerVideoLength ?? videoLen;
  if (profile == AndroidMotionPhotoProfile.oplus) {
    final hdrgmNs = gainMapLength >= 32
        ? '        xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/"\n'
        : '';
    final hdrgmAttr = gainMapLength >= 32 ? '      hdrgm:Version="1.0"\n' : '';
    final gainItem = gainMapLength >= 32
        ? '''          <rdf:li rdf:parseType="Resource">
            <Container:Item
              Item:Mime="image/jpeg"
              Item:Semantic="GainMap"
              Item:Length="$gainMapLength"
              Item:Padding="0"/>
          </rdf:li>
'''
        : '';
    return '''
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.1.0-jc003">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
$hdrgmNs        xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"
        xmlns:OpCamera="http://ns.oplus.com/photos/1.0/camera/"
        xmlns:Container="http://ns.google.com/photos/1.0/container/"
        xmlns:Item="http://ns.google.com/photos/1.0/container/item/"
$hdrgmAttr      GCamera:MotionPhoto="1"
      GCamera:MotionPhotoVersion="1"
      GCamera:MotionPhotoPresentationTimestampUs="$keyFrameUs"
      OpCamera:MotionPhotoPrimaryPresentationTimestampUs="$keyFrameUs"
      OpCamera:MotionPhotoVideoStart="0"
      OpCamera:MotionPhotoVideoEnd="0"
      OpCamera:MotionPhotoOwner="oplus"
      OpCamera:OLivePhotoVersion="2"
      OpCamera:VideoLength="$videoLen">
      <Container:Directory>
        <rdf:Seq>
          <rdf:li rdf:parseType="Resource">
            <Container:Item
              Item:Mime="image/jpeg"
              Item:Semantic="Primary"
              Item:Length="0"
              Item:Padding="0"/>
          </rdf:li>
$gainItem          <rdf:li rdf:parseType="Resource">
            <Container:Item
              Item:Mime="$videoMime"
              Item:Semantic="MotionPhoto"
              Item:Length="$itemVideoLen"
              Item:Padding="0"/>
          </rdf:li>
        </rdf:Seq>
      </Container:Directory>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
''';
  }
  return '''
<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"
$hdrgmNamespace$oplusNamespace$vivoNamespace    xmlns:Container="http://ns.google.com/photos/1.0/container/"
    xmlns:Item="http://ns.google.com/photos/1.0/container/item/"$hdrgmAttribute
    GCamera:MotionPhoto="1"
    GCamera:MotionPhotoVersion="1"
    GCamera:MotionPhotoPresentationTimestampUs="$keyFrameUs"$oplusAttributes$vivoAttributes>
   <Container:Directory>
    <rdf:Seq>
     <rdf:li rdf:parseType="Resource">
      <Container:Item Item:Mime="image/jpeg" Item:Semantic="Primary" Item:Length="0" Item:Padding="0"/>
     </rdf:li>
$gainMapItem     <rdf:li rdf:parseType="Resource">
      <Container:Item Item:Mime="$videoMime" Item:Semantic="MotionPhoto" Item:Length="$itemVideoLen"/>
     </rdf:li>
    </rdf:Seq>
   </Container:Directory>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
'''
      .trim();
}
