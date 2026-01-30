import 'dart:ui';
import 'package:flutter/material.dart';
import 'in_app_review_helper.dart';
import 'rate_gate.dart';

Future<void> showRatePrompt(BuildContext context) async {
  final shouldRate = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withOpacity(0.55),
    builder: (ctx) => const _RateDialog(),
  );

  // If user taps outside / closes / Not now => treat as dismiss
  if (shouldRate != true) {
    await RateGate.onDismiss();
    return;
  }

  // User chose "Rate now"
  await InAppReviewHelper.requestReviewOrStoreFallback();

  // ✅ Treat "Rate now" as rated (stop all future prompts)
  await RateGate.markRated();
}

class _RateDialog extends StatelessWidget {
  const _RateDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg = isDark ? const Color(0xFF101018) : theme.colorScheme.surface;
    final border = isDark
        ? Colors.white.withOpacity(0.12)
        : Colors.black.withOpacity(0.10);

    final titleColor = isDark ? Colors.white : Colors.black;
    final subColor = isDark ? Colors.white70 : Colors.black54;

    // Brand accent
    final accent = theme.colorScheme.primary;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 420),
                decoration: BoxDecoration(
                  color: bg.withOpacity(isDark ? 0.92 : 0.96),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: border),
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 28,
                      offset: const Offset(0, 18),
                      color: Colors.black.withOpacity(isDark ? 0.55 : 0.18),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // top row: just close (top-right)
                      Row(
                        children: [
                          const Spacer(),
                          _PillIconButton(
                            tooltip: 'Close',
                            icon: Icons.close,
                            onTap: () => Navigator.of(context).pop(false),
                          ),
                        ],
                      ),

                      const SizedBox(height: 6),

                      // ✅ 5 stars ABOVE title
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(5, (_) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: Icon(
                              Icons.star_rounded,
                              size: 22,
                              color: Colors.green.withOpacity(
                                isDark ? 0.95 : 0.9,
                              ),
                            ),
                          );
                        }),
                      ),

                      const SizedBox(height: 10),

                      Text(
                        'Liking the experience?',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.2,
                          color: titleColor,
                        ),
                      ),

                      const SizedBox(height: 8),

                      Text(
                        'A quick rating helps us improve and reach more people.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: subColor,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),

                      const SizedBox(height: 16),

                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                side: BorderSide(
                                  color: isDark
                                      ? Colors.white.withOpacity(0.14)
                                      : Colors.black.withOpacity(0.12),
                                ),
                              ),
                              child: Text(
                                'Not now',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  color: isDark ? Colors.white70 : Colors.black,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              onPressed: () => Navigator.of(context).pop(true),
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                backgroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              child: const Text(
                                'Rate now',
                                style: TextStyle(fontWeight: FontWeight.w900),
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 6),

                      Text(
                        'You can change your mind anytime.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: isDark ? Colors.white60 : Colors.black45,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PillIconButton extends StatelessWidget {
  const _PillIconButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final border = (isDark ? Colors.white : Colors.black).withOpacity(0.10);
    final bg = (isDark ? Colors.white : Colors.black).withOpacity(0.06);

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: bg,
            border: Border.all(color: border),
          ),
          child: Icon(icon, size: 18),
        ),
      ),
    );
  }
}
