import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import 'live_photo.dart';

/// Shared by grid and preview. Android normally has no Live subtype flag.
/// Keep file/metadata work bounded and deduplicate simultaneous callers.
class AlbumLiveProbe {
  static final shared = AlbumLiveProbe();
  final _cache = <String, bool>{};
  final _jobs = <String, Future<bool>>{};
  final _waiters = Queue<Completer<void>>();
  int _running = 0;

  @visibleForTesting
  Future<bool> Function(AssetEntity)? probeOverride;

  String key(AssetEntity asset) => '${asset.id}:${asset.modifiedDateSecond}';

  bool? cached(AssetEntity asset) =>
      asset.isLivePhoto ? true : _cache[key(asset)];

  Future<bool> detect(AssetEntity asset) {
    if (asset.type != AssetType.image) return Future.value(false);
    if (asset.isLivePhoto) return Future.value(true);
    final id = key(asset);
    final known = _cache[id];
    if (known != null) return Future.value(known);
    return _jobs.putIfAbsent(id, () => _detect(asset, id));
  }

  Future<bool> _detect(AssetEntity asset, String id) async {
    if (_running >= 2) {
      final turn = Completer<void>();
      _waiters.add(turn);
      await turn.future;
    } else {
      _running++;
    }
    try {
      final override = probeOverride;
      bool live;
      if (override != null) {
        live = await override(asset);
      } else if (Platform.isAndroid) {
        // Android resolves the original MediaStore path; no video export here.
        final token = PMCancelToken();
        final file =
            await asset.loadFile(isOrigin: true, cancelToken: token).timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            token.cancelRequest();
            throw TimeoutException('local live metadata');
          },
        );
        live = file != null && await compute(probeLocalLivePhoto, file.path);
      } else {
        live =
            false; // iOS uses the authoritative PHAsset subtype, no iCloud download.
      }
      while (_cache.length >= 400) {
        _cache.remove(_cache.keys.first);
      }
      _cache[id] = live;
      return live;
    } catch (_) {
      return false; // Permission/transient failures are not cached.
    } finally {
      // Defer removal: a synchronous no-op may finish before putIfAbsent stores.
      scheduleMicrotask(() => _jobs.remove(id));
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().complete();
      } else {
        _running--;
      }
    }
  }

  @visibleForTesting
  void clearCache() => _cache.clear();
}
