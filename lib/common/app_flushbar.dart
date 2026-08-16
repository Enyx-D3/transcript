import 'package:another_flushbar/flushbar.dart';
import 'package:flutter/material.dart';

import '../ui/glass/glass_tokens.dart';

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

    final isDark = GlassTokens.isDark(overlayCtx);
    final bgColor = isDark ? const Color(0xFF1E1E26) : Colors.white;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.08);
    final titleColor = isDark ? Colors.white : const Color(0xFF1A1A1E);
    final messageColor = isDark
        ? Colors.white.withValues(alpha: 0.92)
        : const Color(0xFF2C2C34);
    final closeColor = isDark ? Colors.white70 : const Color(0xFF6B6B78);
    final shadowColor = isDark
        ? Colors.black.withValues(alpha: 0.50)
        : Colors.black.withValues(alpha: 0.12);

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
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 14,
                color: titleColor,
                letterSpacing: 0.2,
              ),
            ),
      messageText: Text(
        message,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: messageColor,
          fontSize: 13.5,
          height: 1.25,
          fontWeight: FontWeight.w600,
        ),
      ),
      icon: icon == null
          ? null
          : Padding(
              padding: const EdgeInsets.all(4.0),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: isDark ? 0.16 : 0.10),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: iconColor.withValues(alpha: isDark ? 0.28 : 0.20),
                  ),
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
                foregroundColor: closeColor,
              ),
              child: Icon(Icons.close, size: 18, color: closeColor),
            )
          : null,

      duration: duration,

      // ✅ Top + floating
      flushbarPosition: FlushbarPosition.TOP,
      flushbarStyle: FlushbarStyle.FLOATING,

      // --- Look & feel ---
      margin: EdgeInsets.fromLTRB(16, topMargin, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      borderRadius: BorderRadius.circular(16),
      backgroundColor: bgColor,
      borderColor: borderColor,
      borderWidth: 1,

      // --- Animation / shadow ---
      animationDuration: const Duration(milliseconds: 240),
      forwardAnimationCurve: Curves.easeOutCubic,
      reverseAnimationCurve: Curves.easeInCubic,
      boxShadows: [
        BoxShadow(
          blurRadius: 20,
          spreadRadius: 0,
          offset: const Offset(0, 8),
          color: shadowColor,
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
      if (overlayCtx.mounted) {
        await flush.show(overlayCtx);
      }
    } catch (_) {
      // ignore if overlay is gone mid-show
    }
  }

  static Future<void> success(
    BuildContext context, {
    required String message,
    String? title,
  }) => show(
    context,
    title: title ?? 'Success',
    message: message,
    icon: Icons.check_circle_rounded,
    iconColor: const Color(0xFF34C759),
  );

  static Future<void> error(
    BuildContext context, {
    required String message,
    String? title,
  }) => show(
    context,
    title: title ?? 'Error',
    message: message,
    icon: Icons.error_rounded,
    duration: const Duration(seconds: 3),
    iconColor: const Color(0xFFFF3B30),
  );

  static Future<void> info(
    BuildContext context, {
    required String message,
    String? title,
  }) => show(
    context,
    title: title ?? 'Info',
    message: message,
    icon: Icons.info_rounded,
    iconColor: GlassTokens.primary(context),
  );
}
