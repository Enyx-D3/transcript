import 'package:another_flushbar/flushbar.dart';
import 'package:flutter/material.dart';

class AppFlushbar {
  AppFlushbar._();

  // Prevent stacking multiple toasts
  static Flushbar<void>? _active;

  static BuildContext _rootOverlayContext(BuildContext context) {
    final nav = Navigator.of(context, rootNavigator: true);
    final overlay = nav.overlay;
    if (overlay != null) return overlay.context;
    return context; // fallback
  }

  static Future<void> show(
    BuildContext context, {
    required String message,
    String? title,
    IconData? icon,
    Duration duration = const Duration(seconds: 2),
    required Color iconColor,
    bool showClose = false,
    int maxLines = 3,
  }) async {
    final overlayCtx = _rootOverlayContext(context);

    // If the widget tree is already gone, bail safely.
    if (!overlayCtx.mounted) return;

    final theme = Theme.of(overlayCtx);

    final safeTop = MediaQuery.of(overlayCtx).padding.top;
    final topMargin = (safeTop > 0 ? safeTop : 0) + 8.0;

    // ✅ Dismiss any existing flushbar to avoid overlapping + overflow issues
    try {
      await _active?.dismiss();
    } catch (_) {}
    _active = null;

    late final Flushbar<void> flush;

    flush = Flushbar<void>(
      // --- Content ---
      titleText: title == null
          ? null
          : Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: 0.2,
              ),
            ),
      messageText: Text(
        message,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: Colors.white.withValues(alpha: 0.95),
          height: 1.15,
          fontWeight: FontWeight.w600,
        ),
      ),
      icon: icon == null
          ? null
          : Padding(
            padding: const EdgeInsets.all(4.0),
            child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: iconColor.withValues(alpha: 0.25)),
                ),
                child: Icon(icon, color: iconColor, size: 20),
              ),
          ),

      // ✅ Close button: dismiss THIS flushbar (not routes)
      mainButton: showClose
          ? TextButton(
              onPressed: () => flush.dismiss(),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 36),
                foregroundColor: Colors.white70,
              ),
              child: const Icon(Icons.close, size: 18),
            )
          : null,

      duration: duration,

      // ✅ Top + floating
      flushbarPosition: FlushbarPosition.TOP,
      flushbarStyle: FlushbarStyle.FLOATING,

      // --- Look & feel ---
      margin: EdgeInsets.fromLTRB(18, topMargin, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      borderRadius: BorderRadius.circular(16),
      backgroundColor:  const Color.fromARGB(100, 0, 0, 0),
      borderColor: Colors.white.withValues(alpha: 0.08),
      borderWidth: 1,

      // --- Animation / shadow ---
      animationDuration: const Duration(milliseconds: 220),
      forwardAnimationCurve: Curves.easeOutCubic,
      reverseAnimationCurve: Curves.easeInCubic,
      boxShadows: const [
        BoxShadow(
          blurRadius: 22,
          spreadRadius: 1,
          offset: Offset(0, 12),
          color: Colors.black45,
        ),
      ],

      // ✅ Keep reference clean
      onStatusChanged: (status) {
        if (status == FlushbarStatus.DISMISSED ||
            status == FlushbarStatus.IS_HIDING) {
          if (identical(_active, flush)) _active = null;
        }
      },
    );

    _active = flush;

    // ✅ Show using root overlay context so it stays visible regardless of scroll.
    try {
      await flush.show(overlayCtx);
    } catch (_) {
      // ignore if overlay is gone mid-show
    }
  }

  static Future<void> success(
    BuildContext context, {
    required String message,
    String? title,
  }) =>
      show(
        context,
        title: title ?? 'Success',
        message: message,
        icon: Icons.check_circle_outline,
        iconColor: Colors.greenAccent,
      );

  static Future<void> error(
    BuildContext context, {
    required String message,
    String? title,
  }) =>
      show(
        context,
        title: title ?? 'Error',
        message: message,
        icon: Icons.error_outline,
        duration: const Duration(seconds: 3),
        iconColor: Colors.redAccent,
      );

  static Future<void> info(
    BuildContext context, {
    required String message,
    String? title,
  }) =>
      show(
        context,
        title: title ?? 'Info',
        message: message,
        icon: Icons.info_outline,
        iconColor: const Color(0xFF65D6FF),
      );
}