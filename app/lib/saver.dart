/// 原生保存到系统相册（photo_manager）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'album_prep.dart';
import 'api.dart';
import 'live_photo.dart';
import 'upload_prep.dart';

class Saver {
  @visibleForTesting
  static Future<String?> Function()? permissionOverride;

  /// 读相册（上传）+ 写入相册（保存），对应系统「照片和视频」权限。
  static const permissionOption = PermissionRequestOption(
    androidPermission: AndroidPermission(
      type: RequestType.common,
      mediaLocation: false,
    ),
  );

  /// 第一次进入 App 时主动弹出系统权限框。已授权则立即返回。
  static Future<PermissionState> requestOnLaunch() {
    return PhotoManager.requestPermissionExtend(
      requestOption: permissionOption,
    );
  }

  /// 确认相册权限，返回错误信息或 null
  static Future<String?> ensurePermission() async {
    final override = permissionOverride;
    if (override != null) return override();
    var state = await PhotoManager.getPermissionState(
      requestOption: permissionOption,
    );
    if (state.hasAccess) return null;
    state = await PhotoManager.requestPermissionExtend(
      requestOption: permissionOption,
    );
    if (state.hasAccess) return null;
    return '没有相册权限，请在系统设置里允许「照片和视频」';
  }

  /// 已保存记忆：盒子地址|媒体ID|系统相册资源ID。
  /// 用资源 ID 查相册：用户删了系统照片后资源 ID 查不到，自然允许再存；
  /// 文件名+日期只是跨会话的兜底提示，不当硬拦截。
  static const _prefKey = 'saved_media_ids';

  @visibleForTesting
  static Future<bool> Function(CardItem c)? alreadySavedOverride;

  static String mediaKey(CardItem c) => '${Api.I.base}|${c.id}';

  static Future<List<String>> _remembered() async {
    final p = await SharedPreferences.getInstance();
    return p.getStringList(_prefKey) ?? const [];
  }

  static Future<void> _remember(
    CardItem c,
    String? localId, {
    bool live = false,
  }) async {
    final p = await SharedPreferences.getInstance();
    final keys = p.getStringList(_prefKey) ?? <String>[];
    final k =
        live ? '${mediaKey(c)}|$localId|live-v11' : '${mediaKey(c)}|$localId';
    if (keys.contains(k)) return;
    keys.add(k);
    if (keys.length > 2000) keys.removeRange(0, keys.length - 2000);
    await p.setStringList(_prefKey, keys);
  }

  /// `盒子|媒体ID|系统相册ID` 或 `盒子|媒体ID|系统相册ID|live`。
  @visibleForTesting
  static ({String localId, bool liveMarked})? parseSavedEntry(
    String entry,
    String key,
  ) {
    if (!entry.startsWith('$key|')) return null;
    final rest = entry.substring(key.length + 1);
    if (rest.isEmpty) return (localId: '', liveMarked: false);
    final parts = rest.split('|');
    return (localId: parts.first, liveMarked: parts.contains('live-v11'));
  }

  /// 相册里是否已有这张（按本 App 保存过的资源 ID 精确查，
  /// 查不到再按文件名+日期近似查）。
  /// 实况照片：以前分开保存的静态条目不能挡住完整 Live 再存。
  static Future<bool> alreadySaved(CardItem c) async {
    final override = alreadySavedOverride;
    if (override != null) return override(c);
    final key = mediaKey(c);
    final wantLive = c.hasLive;
    for (final entry in await _remembered()) {
      final parsed = parseSavedEntry(entry, key);
      if (parsed == null) continue;
      if (parsed.localId.isEmpty) {
        if (wantLive) continue;
        return true;
      }
      try {
        final a = await AssetEntity.fromId(parsed.localId);
        if (a != null) {
          if (wantLive) {
            if (Platform.isIOS && a.isLivePhoto) return true;
            if (Platform.isAndroid && parsed.liveMarked) {
              final file = await a.originFile;
              if (file != null &&
                  await compute(motionPhotoFileComplete, file.path)) {
                // A structurally complete Motion Photo can still be indexed as
                // a plain JPEG by some Oppo/Realme galleries (notably when the
                // embedded video is an Apple QuickTime stream). Such an entry
                // must not block a corrected save.
                final recognized = await _galleryRecognizesMotionPhoto(
                  file.path,
                );
                if (recognized != false) return true;
              }
            }
            continue;
          }
          return true;
        }
      } catch (_) {}
      // 资源没了（用户删了系统照片）：允许再存，清掉失效记录
      final p = await SharedPreferences.getInstance();
      final keys = p.getStringList(_prefKey) ?? <String>[];
      keys.remove(entry);
      await p.setStringList(_prefKey, keys);
    }
    try {
      final err = await ensurePermission();
      if (err != null) return false;
      final name = c.origName.split(RegExp(r'[\\/]')).last.toLowerCase();
      if (name.isEmpty) return false;
      final day = dayKey(c.takenAt);
      final wantDay = day == 'unknown'
          ? (c.createdAt == null ? 'unknown' : dayKey(c.createdAt!.round()))
          : day;
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        filterOption: albumFilterOption(),
      );
      if (paths.isEmpty) return false;
      final recent = await paths.first.getAssetListPaged(page: 0, size: 200);
      for (final a in recent) {
        final title = (a.title ?? '').toLowerCase();
        if (title != name &&
            title != name.replaceAll(RegExp(r'\.[^.]+$'), '')) {
          continue;
        }
        if (wantLive) continue;
        if (wantDay == 'unknown' || mediaDay(a.createDateTime) == wantDay) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// 把一张卡片的原片存进系统相册，返回给用户看的消息。
  /// [onProgress] 0~1（视频/大图下载进度）；[isCancelled] 置 true 中止下载。
  static Future<String> save(
    Api api,
    CardItem c, {
    void Function(double)? onProgress,
    bool Function()? isCancelled,
    bool allowDuplicate = false,
  }) async {
    if (!allowDuplicate && await alreadySaved(c)) return '相册里已经有这张了';
    final err = await ensurePermission();
    if (err != null) throw err;
    if (isCancelled?.call() == true) throw '已取消';
    final name = c.origName.isNotEmpty ? c.origName : 'tuantu_${c.id}.${c.ext}';
    final ext = c.ext.toLowerCase();
    final tmp = await _tmpPath(name);
    try {
      if (c.kind == 'audio') {
        throw '音频请在网页版下载';
      }
      if (c.kind != 'video' && !_imageExts.contains(ext) && c.kind != 'image') {
        throw 'RAW/未知格式请用网页版下载';
      }
      // 统一流式下载到临时文件，几百 MB 的视频也不会撑爆内存
      final got = await api.downloadRawToFile(
        c.id,
        tmp,
        onProgress: (p) =>
            onProgress?.call(c.hasLive && c.kind != 'video' ? p * 0.55 : p),
        isCancelled: isCancelled,
      );
      if (isCancelled?.call() == true) throw '已取消';
      if (got <= 0) throw '没有下载到内容';
      var wantLive = c.hasLive && c.kind != 'video';
      if (!wantLive && c.kind != 'video') {
        try {
          wantLive = await compute(motionPhotoFileHasEmbedded, tmp);
        } catch (_) {
          wantLive = false;
        }
      }
      if (!wantLive) onProgress?.call(1);

      if (c.kind == 'video') {
        AssetEntity asset;
        try {
          asset = await PhotoManager.editor.saveVideo(File(tmp), title: name);
        } catch (_) {
          throw '保存失败：系统相册没有接受这个视频（格式或空间问题）';
        }
        await _remember(c, asset.id);
        return '已存入相册';
      }

      if (wantLive) {
        return await _saveLivePair(
          api,
          c,
          stillPath: tmp,
          name: name,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
      }

      // 普通静图必须整文件落盘，saveImage 会丢掉内嵌视频。
      AssetEntity asset;
      try {
        asset = await PhotoManager.editor.saveImageWithPath(tmp, title: name);
      } catch (_) {
        throw '保存失败：系统相册没有接受这张照片（格式或空间问题）';
      }
      await _remember(c, asset.id);
      return '已存入相册';
    } finally {
      try {
        final f = File(tmp);
        if (f.existsSync()) await f.delete();
      } catch (_) {}
    }
  }

  static const _imageExts = [
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
    'heic',
    'heif',
    'avif',
    'tif',
    'tiff',
  ];

  static String _liveTitle(String name) {
    final base = name.split(RegExp(r'[\\/]')).last;
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }

  static const _mediaChannel = MethodChannel('dev.tuantu/media');

  @visibleForTesting
  static Future<String?> Function(String src, String dest)? stillToJpegOverride;

  @visibleForTesting
  static Future<String?> Function(String src, String dest)?
      normalizeLiveVideoOverride;

  @visibleForTesting
  static Future<bool?> Function(String path)? motionRecognitionOverride;

  @visibleForTesting
  static Future<AndroidMotionPhotoProfile> Function()?
      androidMotionPhotoProfileOverride;

  static Future<AndroidMotionPhotoProfile> _androidMotionPhotoProfile() async {
    final override = androidMotionPhotoProfileOverride;
    if (override != null) return override();
    if (!Platform.isAndroid) return AndroidMotionPhotoProfile.google;
    try {
      final raw = await _mediaChannel.invokeMethod<String>('livePhotoProfile');
      return androidMotionPhotoProfileFromWire(raw);
    } catch (_) {
      return AndroidMotionPhotoProfile.google;
    }
  }

  static Future<String?> _stillToJpeg(
    String src,
    String dest,
    AndroidMotionPhotoProfile profile,
  ) async {
    if (stillToJpegOverride != null) return stillToJpegOverride!(src, dest);
    if (!Platform.isAndroid) return null;
    try {
      return await _mediaChannel.invokeMethod<String>('stillToJpeg', {
        'src': src,
        'dest': dest,
        'profile': profile.wireName,
      });
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _normalizeLiveVideo(
    String src,
    String dest, {
    AndroidMotionPhotoProfile? profile,
  }) async {
    if (normalizeLiveVideoOverride != null) {
      return normalizeLiveVideoOverride!(src, dest);
    }
    if (!Platform.isAndroid) return null;
    return _mediaChannel.invokeMethod<String>('normalizeLiveVideo', {
      'src': src,
      'dest': dest,
      'profile': (profile ?? AndroidMotionPhotoProfile.google).wireName,
    });
  }

  @visibleForTesting
  static Future<String?> Function(
      String path, AndroidMotionPhotoProfile profile)? stampLiveStillOverride;

  static Future<void> _stampLiveStill(
    String path,
    AndroidMotionPhotoProfile profile,
  ) async {
    if (stampLiveStillOverride != null) {
      await stampLiveStillOverride!(path, profile);
      return;
    }
    if (!Platform.isAndroid) return;
    try {
      await _mediaChannel.invokeMethod<String>('stampLiveStill', {
        'dest': path,
        'profile': profile.wireName,
      });
    } catch (_) {
      if (profile == AndroidMotionPhotoProfile.oplus) {
        throw '保存失败：无法写入 realme/OPPO 实况标记';
      }
    }
  }

  /// Returns null on Android versions whose MediaProvider does not expose an
  /// OEM Live Photo recognition flag. Oppo/Realme expose `o_is_live_photo`;
  /// poll briefly because indexing completes after the file is inserted.
  static Future<bool?> _galleryRecognizesMotionPhoto(
    String path, {
    AndroidMotionPhotoProfile? profile,
  }) async {
    if (motionRecognitionOverride != null) {
      return motionRecognitionOverride!(path);
    }
    if (!Platform.isAndroid) return null;
    final target = profile ?? await _androidMotionPhotoProfile();
    bool? latest;
    for (var attempt = 0; attempt < 8; attempt++) {
      try {
        latest = await _mediaChannel.invokeMethod<bool>(
          'isRecognizedMotionPhoto',
          {'path': path, 'profile': target.wireName},
        );
      } on PlatformException {
        return null;
      } on MissingPluginException {
        return null;
      }
      if (latest == true) return true;
      if (attempt < 7) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    return latest;
  }

  static String _jpgTitle(String name) {
    final base = _liveTitle(name);
    return '${base.endsWith('MP') ? base : '${base}_MP'}.jpg';
  }

  static String _oplusCameraTitle(String name) {
    var base = name.split(RegExp(r'[\\/]')).last;
    final lower = base.toLowerCase();
    if (lower.endsWith('_mp.jpg')) {
      base = '${base.substring(0, base.length - 7)}.jpg';
    } else if (!lower.endsWith('.jpg')) {
      base = '${_liveTitle(base)}.jpg';
    }
    return base;
  }

  /// 两份有效资源都落盘后才创建相册资产。
  /// iOS：一次 PHAssetCreationRequest 写入 Live Photo。
  /// 安卓：封装成一个 Motion Photo JPEG，只写入一个图片条目。
  static Future<String> _saveLivePair(
    Api api,
    CardItem c, {
    required String stillPath,
    required String name,
    void Function(double)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (c.ext.toLowerCase() == 'gif') {
      throw '保存失败：GIF 不是可配对的实况照片';
    }
    final stillFile = File(stillPath);
    final stillBytes = stillFile.existsSync() ? stillFile.lengthSync() : 0;
    if (stillBytes <= 0) throw '没有下载到原片';

    final livePath = await _tmpPath('$name.live.mp4');
    var liveGot = 0;
    try {
      try {
        liveGot = await api.downloadLiveToFile(
          c.id,
          livePath,
          onProgress: (p) => onProgress?.call(0.55 + p * 0.45),
          isCancelled: isCancelled,
        );
      } catch (_) {
        liveGot = 0;
      }
      if (isCancelled?.call() == true) throw '已取消';
      onProgress?.call(1);

      final liveFile = File(livePath);
      var liveOk = liveGot > 0 && liveVideoFileReady(liveFile);
      if (!liveOk) {
        final recovered = await compute(recoverLiveSidecarFromPaths, [
          stillFile.path,
          liveFile.path,
        ]);
        liveOk = recovered != null;
      }
      if (!liveOk) throw '保存失败：动态部分缺失或损坏，请重新上传完整实况照片';

      if (Platform.isIOS) {
        // Genuine Apple pairs retain their pairing identifiers and key-frame
        // timing. Android Motion Photos need the plugin to create Apple metadata.
        Map<String, dynamic>? preserved;
        try {
          preserved = await const MethodChannel('dev.tuantu/live_photo')
              .invokeMapMethod<String, dynamic>('savePair', {
            'still': stillPath,
            'video': livePath,
          });
        } on PlatformException {
          // Photos rejects an unpaired Android resource atomically. Re-pair it.
        }
        if (preserved != null) {
          if (preserved['live'] == true && preserved['id'] is String) {
            await _remember(c, preserved['id'] as String, live: true);
            return '已存入相册';
          }
        }
        AssetEntity asset;
        try {
          asset = await PhotoManager.editor.darwin.saveLivePhoto(
            imageFile: stillFile,
            videoFile: liveFile,
            title: _liveTitle(name),
          );
        } catch (_) {
          throw '保存失败：系统相册没有接受这张实况照片';
        }
        if (!asset.isLivePhoto) {
          try {
            await PhotoManager.editor.deleteWithIds([asset.id]);
          } catch (_) {}
          throw '保存失败：系统相册未能识别实况配对';
        }
        await _remember(c, asset.id, live: true);
        return '已存入相册';
      }

      final profile = await _androidMotionPhotoProfile();
      if (profile == AndroidMotionPhotoProfile.oplus &&
          await compute(stillHasColorOsLiveTrailer, stillFile.path)) {
        return await _saveMotionFile(
          c,
          stillFile.path,
          name,
          profile: profile,
        );
      }

      return await _muxAndSaveAndroid(c, stillFile, liveFile, name);
    } finally {
      try {
        final f = File(livePath);
        if (f.existsSync()) await f.delete();
      } catch (_) {}
    }
  }

  static Future<String> _muxAndSaveAndroid(
    CardItem c,
    File stillFile,
    File liveFile,
    String name,
  ) async {
    final dest = '${stillFile.path}.still.jpg';
    final outPath = '${stillFile.path}.motion.jpg';
    String? normalizedPath;
    try {
      final profile = await _androidMotionPhotoProfile();
      var videoPath = liveFile.path;
      var keepUuidTails = false;
      normalizedPath = '${stillFile.path}.android.mp4';
      if (profile == AndroidMotionPhotoProfile.oplus) {
        // The verified WeChat save retains MP4 bytes, including vivo UUIDs.
        // Do not reorder moov or manufacture a second live.subVideo. MOV/PCM
        // still needs the existing MP4/AAC conversion.
        final alreadyMp4 =
            await compute(liveVideoCanPreserveOplusContainer, liveFile.path);
        if (!alreadyMp4) {
          String? convertedVideo;
          try {
            convertedVideo = await _normalizeLiveVideo(
              liveFile.path,
              normalizedPath,
              profile: profile,
            );
          } catch (_) {
            convertedVideo = null;
          }
          if (convertedVideo == null ||
              !await compute(liveVideoPathReady, convertedVideo)) {
            throw '保存失败：无法把动态部分转换为安卓相册格式';
          }
          videoPath = convertedVideo;
        }
        keepUuidTails = true;
      } else {
        String? convertedVideo;
        try {
          convertedVideo = await _normalizeLiveVideo(
            liveFile.path,
            normalizedPath,
            profile: profile,
          );
        } catch (_) {
          convertedVideo = null;
        }
        if (convertedVideo != null &&
            await compute(liveVideoPathReady, convertedVideo)) {
          videoPath = convertedVideo;
          keepUuidTails = profile == AndroidMotionPhotoProfile.vivo;
        } else {
          // Keeping a MOV after a failed audio/orientation conversion can look
          // successful while losing sound or showing sideways video.
          throw '保存失败：无法完整转换动态视频的声音或方向，盒子原片已保留';
        }
      }
      final decodable = await _mediaChannel.invokeMethod<bool>(
        'validateLiveVideo',
        {'src': videoPath},
      );
      if (decodable != true) throw '保存失败：此手机无法解码动态视频，请保留盒子原片';
      // JPEG 原件保留像素和 Gain Map；HEIC 等才解码成 JPEG。
      // Bitmap 重压会把 HDR 静图打成 SDR，和 10-bit 视频对不上。
      var keepGainMap = false;
      var jpegPath = dest;
      if (await compute(copyJpegPrimaryFile, [stillFile.path, dest])) {
        jpegPath = dest;
        keepGainMap = true;
        // Stamp the numeric ColorOS Live flags before composing the file.
        // The composer rebuilds MPF after EXIF/XMP changes; the gain map is
        // recovered independently from the untouched source, not this copy.
        await _stampLiveStill(jpegPath, profile);
      } else {
        final converted = await _stillToJpeg(stillFile.path, dest, profile);
        if (converted == null || !File(converted).existsSync()) {
          throw '无法把这张实况照片转成安卓动态照片';
        }
        jpegPath = converted;
      }
      await compute(buildMotionPhotoFile, <String, Object?>{
        'jpeg': jpegPath,
        'still': stillFile.path,
        'video': videoPath,
        'output': outPath,
        'fallback': c.livePts,
        'profile': profile.wireName,
        'keepGainMap': keepGainMap,
        'keepUuidTails': keepUuidTails,
      });
      return await _saveMotionFile(c, outPath, name, profile: profile);
    } finally {
      try {
        if (File(dest).existsSync()) File(dest).deleteSync();
      } catch (_) {}
      try {
        File(outPath).deleteSync();
      } catch (_) {}
      if (normalizedPath != null) {
        try {
          File(normalizedPath).deleteSync();
        } catch (_) {}
        try {
          File('$normalizedPath.trim.mp4').deleteSync();
        } catch (_) {}
        try {
          File('$normalizedPath.oplus.mp4').deleteSync();
        } catch (_) {}
      }
    }
  }

  static Future<String> _saveMotionFile(
    CardItem c,
    String path,
    String name, {
    required AndroidMotionPhotoProfile profile,
  }) async {
    AssetEntity asset;
    try {
      asset = await PhotoManager.editor.saveImageWithPath(
        path,
        title: profile == AndroidMotionPhotoProfile.oplus
            ? _oplusCameraTitle(name)
            : _jpgTitle(name),
        relativePath:
            profile == AndroidMotionPhotoProfile.oplus ? 'DCIM/Camera/' : null,
      );
    } catch (_) {
      throw '保存失败：系统相册没有接受这张动态照片';
    }
    final saved = await asset.originFile;
    if (saved == null ||
        !await compute(motionPhotoFilesMatch, [saved.path, path])) {
      try {
        await PhotoManager.editor.deleteWithIds([asset.id]);
      } catch (_) {}
      throw '保存失败：相册没有保留完整动态文件，请勿删除盒子原片';
    }
    final recognized = await _galleryRecognizesMotionPhoto(
      saved.path,
      profile: profile,
    );
    if (recognized == false) {
      try {
        await PhotoManager.editor.deleteWithIds([asset.id]);
      } catch (_) {}
      throw '保存失败：系统相册未能识别这张动态照片，请保留盒子原片';
    }
    await _remember(c, asset.id, live: true);
    return '已存入相册';
  }

  static Future<String> _tmpPath(String name) async {
    final dir = Directory.systemTemp;
    final safe = name.split(RegExp(r'[\\/]')).last;
    return '${dir.path}/tuantu_save_${DateTime.now().millisecondsSinceEpoch}_$safe';
  }

  /// 把生成好的图片字节（旅行报告纪念卡）存进系统相册。
  /// 报告图片不来自盒子媒体流，不走 alreadySaved 去重，重复点击由调用方拦截。
  static Future<String> saveReportImage(
    List<int> bytes, {
    String? title,
  }) async {
    final err = await ensurePermission();
    if (err != null) throw err;
    final name = (title == null || title.trim().isEmpty)
        ? 'tuantu_report_${DateTime.now().millisecondsSinceEpoch}.jpg'
        : title;
    final tmp = await _tmpPath(name);
    try {
      await File(tmp).writeAsBytes(bytes, flush: true);
      try {
        await PhotoManager.editor.saveImageWithPath(tmp, title: name);
      } catch (_) {
        throw '保存失败：系统相册没有接受这张图片（格式或空间问题）';
      }
      return '纪念卡已存入相册';
    } finally {
      try {
        final f = File(tmp);
        if (f.existsSync()) await f.delete();
      } catch (_) {}
    }
  }
}
