import 'package:another_flushbar/flushbar.dart';
import 'package:flutter/material.dart';

class AppFlushbar {
  AppFlushbar._();

  static Future<void> show(
    BuildContext context, {
    required String message,
    String? title,
    IconData? icon,
    Duration duration = const Duration(seconds: 2),
    required Color iconColor,
  }) {
    final theme = Theme.of(context);

    return Flushbar(
      titleText: title == null
          ? null
          : Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
      messageText: Text(
        message,
        style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white),
      ),
      icon: icon == null
          ? null
          : Icon(icon, color: iconColor, size: 22),
      duration: duration,

      // ✅ Top + floating
      flushbarPosition: FlushbarPosition.TOP,
      flushbarStyle: FlushbarStyle.FLOATING,

      // Look & feel
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      borderRadius: BorderRadius.circular(14),
      backgroundColor: theme.colorScheme.surface.withOpacity(0.96),

      // A bit of polish
      animationDuration: const Duration(milliseconds: 250),
      forwardAnimationCurve: Curves.easeOut,
      reverseAnimationCurve: Curves.easeIn,
      boxShadows: const [
        BoxShadow(
          blurRadius: 18,
          spreadRadius: 1,
          offset: Offset(0, 10),
          color: Colors.black26,
        ),
      ],
    ).show(context);
  }

  static Future<void> success(
    BuildContext context, {
    required String message,
    String? title,
  }) =>
      show(
        context,
        title: title,
        message: message,
        icon: Icons.check_circle_outline,
        iconColor: Colors.green
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
        iconColor: Colors.red
      );

  static Future<void> info(
    BuildContext context, {
    required String message,
    String? title,
  }) =>
      show(
        context,
        title: title,
        message: message,
        icon: Icons.info_outline,
        iconColor: Colors.blue
      );
}
