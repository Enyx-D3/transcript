import 'package:another_flushbar/flushbar.dart';
import 'package:flutter/material.dart';

class AppFlushbar {
  AppFlushbar._();

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
    bool showClose = true,
    int maxLines = 3,
  }) async {
    final overlayCtx = _rootOverlayContext(context);
    final theme = Theme.of(overlayCtx);

    final safeTop = MediaQuery.of(overlayCtx).padding.top;
    final topMargin = (safeTop > 0 ? safeTop : 0) + 8.0;

    // Create it first so the close button can dismiss THIS flushbar.
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
          color: Colors.white.withOpacity(0.95),
          height: 1.15,
        ),
      ),

      icon: icon == null
          ? null
          : Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.14),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: iconColor.withOpacity(0.25)),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),

      // ✅ Close button: dismiss flushbar (DON'T pop routes)
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

      // --- Look & feel (UNCHANGED) ---
      margin: EdgeInsets.fromLTRB(14, topMargin, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      borderRadius: BorderRadius.circular(16),
      backgroundColor: const Color(0xFF12131A).withOpacity(0.98),
      borderColor: Colors.white.withOpacity(0.08),
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
    );

    // ✅ Show using root overlay context so it stays visible regardless of scroll.
    await flush.show(overlayCtx);
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
