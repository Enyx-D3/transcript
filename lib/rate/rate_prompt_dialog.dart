import 'package:flutter/material.dart';

import '../ui/glass/glass_tokens.dart';
import 'in_app_review_helper.dart';
import 'rate_gate.dart';

Future<void> showRatePrompt(BuildContext context) async {
  final shouldRate = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (ctx) => const _RateCardDialog(),
  );

  if (shouldRate != true) {
    await RateGate.onDismiss();
    return;
  }

  await InAppReviewHelper.requestReviewOrStoreFallback();
  await RateGate.markRated();
}

class _RateCardDialog extends StatelessWidget {
  const _RateCardDialog();

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);
    final primaryColor = GlassTokens.primary(context);

    final dialogBg = isDark ? const Color(0xFF191922) : Colors.white;
    final dialogBorder =
        isDark ? const Color(0xFF282836) : const Color(0xFFE2E4EB);

    return Dialog(
      backgroundColor: dialogBg,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: dialogBorder, width: 1),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Stars badge container
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFB800).withValues(alpha: isDark ? 0.16 : 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(
                    5,
                    (i) => const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 2.5),
                      child: Icon(
                        Icons.star_rounded,
                        size: 24,
                        color: Color(0xFFFFB800),
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 18),

              Text(
                'Liking the experience?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 20,
                  letterSpacing: -0.3,
                  color: fg,
                ),
              ),

              const SizedBox(height: 8),

              Text(
                'A quick rating helps us improve and reach more people.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: muted,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  height: 1.35,
                ),
              ),

              const SizedBox(height: 22),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: isDark
                            ? const Color(0xFF22222E)
                            : const Color(0xFFF0F1F6),
                        foregroundColor: fg,
                        side: BorderSide(
                          color: isDark
                              ? const Color(0xFF333344)
                              : const Color(0xFFE2E4EB),
                          width: 1,
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        'Not now',
                        style: TextStyle(
                          color: muted,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 2,
                        shadowColor: primaryColor.withValues(alpha: 0.4),
                      ),
                      child: const Text(
                        'Rate now',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              Text(
                'You can change your mind anytime.',
                style: TextStyle(
                  color: muted.withValues(alpha: 0.75),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
