import 'dart:async';

import 'package:flutter/material.dart';

OverlayEntry? _activeToast;

/// Informational only: the entire overlay, including its background and margins,
/// passes taps/drags through. Actionable prompts should keep using SnackBar.
void showAppToast(BuildContext context, String message) {
  if (!context.mounted) return;
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  final previous = _activeToast;
  _activeToast = null;
  previous?.remove();
  previous?.dispose();

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _ToastMessage(
      message: message,
      onExpired: () {
        if (_activeToast != entry) return;
        _activeToast = null;
        entry.remove();
        entry.dispose();
      },
      onDisposed: () {
        if (_activeToast == entry) _activeToast = null;
      },
    ),
  );
  _activeToast = entry;
  overlay.insert(entry);
}

class _ToastMessage extends StatefulWidget {
  const _ToastMessage({
    required this.message,
    required this.onExpired,
    required this.onDisposed,
  });

  final String message;
  final VoidCallback onExpired;
  final VoidCallback onDisposed;

  @override
  State<_ToastMessage> createState() => _ToastMessageState();
}

class _ToastMessageState extends State<_ToastMessage> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 2), widget.onExpired);
  }

  @override
  void dispose() {
    _timer.cancel();
    widget.onDisposed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Positioned.fill(
        child: IgnorePointer(
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                24,
                0,
                24,
                108 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Semantics(
                    liveRegion: true,
                    child: DecoratedBox(
                      key: const ValueKey('app-toast-background'),
                      decoration: BoxDecoration(
                        // Only the background is 75% transparent, never the text.
                        color: Colors.black.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Text(
                          widget.message,
                          textAlign: TextAlign.center,
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.normal,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}
