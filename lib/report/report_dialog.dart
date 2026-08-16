import 'package:flutter/material.dart';

import '../common/app_flushbar.dart';
import '../ui/glass/glass_tokens.dart';

Future<bool?> showReportDialog({
  required BuildContext outerContext,
  required String responseText,
  required Future<void> Function({
    required String reason,
    required String note,
    required String response,
    Map<String, dynamic>? meta,
  })
  sendReport,
  Map<String, dynamic>? meta,
}) {
  final reasons = <String>[
    'Incorrect / misleading',
    'Offensive / unsafe',
    'Spam / irrelevant',
    'Other',
  ];

  String selected = reasons.first;
  final noteController = TextEditingController();
  bool sending = false;

  return showDialog<bool>(
    context: outerContext,
    barrierDismissible: !sending,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          final isDark = GlassTokens.isDark(ctx);
          final fg = GlassTokens.fg(ctx);
          final muted = GlassTokens.muted(ctx);

          // App Theme Primary Color
          final primaryColor = GlassTokens.primary(ctx);

          // Solid, opaque background colors (never transparent in light or dark mode)
          final dialogBg = isDark ? const Color(0xFF191922) : Colors.white;
          final dialogBorder = isDark
              ? const Color(0xFF282836)
              : const Color(0xFFE2E4EB);
          final inputBg = isDark
              ? const Color(0xFF22222E)
              : const Color(0xFFF4F5F9);
          final inputBorder = isDark
              ? const Color(0xFF333346)
              : const Color(0xFFDDE0EB);

          return Dialog(
            backgroundColor: dialogBg,
            surfaceTintColor: Colors.transparent,
            elevation: 12,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: dialogBorder, width: 1),
            ),
            insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header Row: Icon + Title
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? primaryColor.withValues(alpha: 0.18)
                                  : primaryColor.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              Icons.flag_rounded,
                              color: primaryColor,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Report response',
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                    color: fg,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Help us improve by selecting an issue',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),
                      Divider(height: 1, color: dialogBorder),
                      const SizedBox(height: 12),

                      // Reasons selection list
                      ...reasons.map((r) {
                        final isSelected = selected == r;
                        return InkWell(
                          onTap: sending
                              ? null
                              : () {
                                  setState(() => selected = r);
                                },
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? (isDark
                                      ? primaryColor.withValues(alpha: 0.16)
                                      : primaryColor.withValues(alpha: 0.08))
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected
                                    ? primaryColor.withValues(alpha: 0.55)
                                    : (isDark
                                        ? const Color(0xFF2C2C3C)
                                        : const Color(0xFFECEEF4)),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  isSelected
                                      ? Icons.radio_button_checked_rounded
                                      : Icons.radio_button_off_rounded,
                                  size: 19,
                                  color: isSelected
                                      ? primaryColor
                                      : muted,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    r,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: isSelected
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      color: isSelected
                                          ? (isDark
                                              ? Colors.white
                                              : primaryColor)
                                          : fg,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),

                      const SizedBox(height: 14),

                      // Additional details text field
                      TextField(
                        controller: noteController,
                        maxLines: 3,
                        enabled: !sending,
                        style: TextStyle(
                          fontSize: 13.5,
                          color: fg,
                          fontWeight: FontWeight.w500,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Additional details (optional)',
                          hintStyle: TextStyle(
                            fontSize: 13,
                            color: muted,
                            fontWeight: FontWeight.w400,
                          ),
                          filled: true,
                          fillColor: inputBg,
                          contentPadding: const EdgeInsets.all(12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: inputBorder),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: inputBorder),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: primaryColor,
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 18),

                      // Action Buttons
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: sending
                                ? null
                                : () => Navigator.of(ctx).pop(false),
                            style: TextButton.styleFrom(
                              foregroundColor: muted,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                            ),
                            child: const Text(
                              'Cancel',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: sending
                                ? null
                                : () async {
                                    setState(() => sending = true);
                                    try {
                                      await sendReport(
                                        reason: selected,
                                        note: noteController.text.trim(),
                                        response: responseText,
                                        meta: meta,
                                      );

                                      if (!ctx.mounted) return;
                                      Navigator.of(ctx).pop(true);

                                      await AppFlushbar.success(
                                        outerContext,
                                        message:
                                            'We have received your complaint',
                                      );
                                    } catch (e) {
                                      debugPrint(e.toString());
                                      setState(() => sending = false);
                                      if (!ctx.mounted) return;

                                      await AppFlushbar.error(
                                        outerContext,
                                        message: 'Failed to report',
                                      );
                                    }
                                  },
                            style: FilledButton.styleFrom(
                              backgroundColor: primaryColor,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 10,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: sending
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.white,
                                      ),
                                    ),
                                  )
                                : const Icon(Icons.send_rounded, size: 16),
                            label: Text(
                              sending ? 'Sending...' : 'Send',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
}
