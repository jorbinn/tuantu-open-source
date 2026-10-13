import 'dart:async';
import 'package:flutter/services.dart';
import 'album_prep.dart';

const _channel = MethodChannel('dev.tuantu/live_photo');
int _sequence = 0;

/// Cancels the Photos resource requests as well as releasing the Dart waiter.
Future<Map<String, String>?> exportIosLive(
  String assetId, {
  required AlbumPrepSession session,
  Duration budget = const Duration(seconds: 90),
}) async {
  if (session.cancelled) return null;
  final requestId = '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
  var delivered = false;
  try {
    final value = await Future.any<Map<String, String>?>([
      _channel.invokeMapMethod<String, String>('exportPair', {
        'id': assetId,
        'requestId': requestId,
        'timeoutSeconds': budget.inMilliseconds / 1000,
      }),
      session.whenCancelled.then((_) => null),
    ]).timeout(budget);
    if (session.cancelled) return null;
    delivered = value != null;
    return value;
  } catch (_) {
    return null;
  } finally {
    // Native retains successful exports until acknowledgement, so a cancellation
    // racing with delivery also removes files that Dart never took ownership of.
    unawaited(_channel
        .invokeMethod<void>(
            delivered ? 'ackExport' : 'cancelExport', {'requestId': requestId})
        .timeout(const Duration(seconds: 2))
        .catchError((_) {}));
  }
}
