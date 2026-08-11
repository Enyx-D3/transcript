import 'package:flutter/material.dart';

// ✅ Glass primitives (match your app)
import '../ui/glass/liquid_glass.dart';
import '../ui/glass/glass_tokens.dart';
import '../ui/glass/glass_divider.dart';

Future<bool> showConfirmDeleteDialog(
  BuildContext context, {
  required String title,
  required String message,
  IconData icon = Icons.delete_outline,
  String confirmText = 'Delete',
  String cancelText = 'Cancel',
}) async {
  final parentTheme = Theme.of(context);
  final parentDefaultText = DefaultTextStyle.of(context);

  final res = await showDialog<bool>(
    context: context,
    // ✅ IMPORTANT: don't jump to root navigator, keep the same Theme/font chain
    useRootNavigator: false,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (ctx) {
      final isDark = GlassTokens.isDark(ctx);

      final fg = GlassTokens.fg(ctx);
      final sub = GlassTokens.muted(ctx);

      final dialogBlur = isDark ? 10.0 : 7.0;

      // ✅ clamp text scaling inside dialog to prevent overflow from app-wide scaling
      final mq = MediaQuery.of(ctx);
      final clampedScaler = mq.textScaler.clamp(
        minScaleFactor: 0.95,
        maxScaleFactor: 1.12,
      );

      return Theme(
        // ✅ Force same theme (and thus font family) as the caller page
        data: parentTheme,
        child: DefaultTextStyle(
          style: parentDefaultText.style,
          child: MediaQuery(
            data: mq.copyWith(textScaler: clampedScaler),
            child: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: LiquidGlass(
                      borderRadius: BorderRadius.circular(22),
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                      backgroundColor:
                          isDark ? GlassTokens.cardDark : GlassTokens.cardLight,
                      shadow: true,
                      child: LayoutBuilder(
                        builder: (context, c) {
                          return ConstrainedBox(
                            constraints: BoxConstraints(maxHeight: c.maxHeight),
                            child: SingleChildScrollView(
                              physics: const BouncingScrollPhysics(),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // ---------- Title row ----------
                                  Row(
                                    children: [
                                      Container(
                                        width: 38,
                                        height: 38,
                                        decoration: BoxDecoration(
                                          color: Colors.red.withValues(
                                            alpha: 0.14,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          border: Border.all(
                                            color: Colors.red.withValues(
                                              alpha: 0.28,
                                            ),
                                          ),
                                        ),
                                        child: Icon(
                                          icon,
                                          color: Colors.redAccent,
                                          size: 20,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                          title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: parentTheme
                                              .textTheme
                                              .titleMedium
                                              ?.copyWith(
                                                color: fg,
                                                fontWeight: FontWeight.w900,
                                                letterSpacing: -0.1,
                                                height: 1.1,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),

                                  const SizedBox(height: 12),
                                  const GlassDivider(height: 1),
                                  const SizedBox(height: 12),

                                  // ---------- Message ----------
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Colors.red.withValues(alpha: 0.07),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: Colors.red.withValues(
                                          alpha: 0.20,
                                        ),
                                      ),
                                    ),
                                    child: Text(
                                      message,
                                      style: parentTheme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: sub,
                                            height: 1.28,
                                            fontWeight: FontWeight.w600,
                                            fontSize: 14,
                                          ),
                                    ),
                                  ),

                                  const SizedBox(height: 14),

                                  // ---------- Actions (no overflow) ----------
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 10,
                                    children: [
                                      SizedBox(
                                        width: double.infinity,
                                        child: _GlassActionButton(
                                          label: cancelText,
                                          kind:
                                              _GlassActionButtonKind.secondary,
                                          onPressed: () =>
                                              Navigator.of(ctx).pop(false),
                                        ),
                                      ),
                                      SizedBox(
                                        width: double.infinity,
                                        child: _GlassActionButton(
                                          label: confirmText,
                                          kind: _GlassActionButtonKind.danger,
                                          onPressed: () =>
                                              Navigator.of(ctx).pop(true),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  return res ?? false;
}

enum _GlassActionButtonKind { primary, secondary, danger }

class _GlassActionButton extends StatelessWidget {
  const _GlassActionButton({
    required this.label,
    required this.onPressed,
    required this.kind,
  });

  final String label;
  final VoidCallback onPressed;
  final _GlassActionButtonKind kind;

  @override
  Widget build(BuildContext context) {
    final isDanger = kind == _GlassActionButtonKind.danger;
    final isDark = GlassTokens.isDark(context);

    final bg = isDanger
        ? (isDark ? const Color(0xFF331418) : const Color(0xFFFFECEF))
        : (isDark ? GlassTokens.surfaceDark : GlassTokens.surfaceLight);

    final border = isDanger
        ? (isDark ? const Color(0xFF551E24) : const Color(0xFFFFCCD5))
        : (isDark ? GlassTokens.borderDark : GlassTokens.borderLight);

    final fg = isDanger
        ? Colors.redAccent
        : GlassTokens.fg(context);

    return LayoutBuilder(
      builder: (_, c) {
        final small = c.maxWidth < 220;

        return LiquidGlass(
          borderRadius: BorderRadius.circular(16),
          padding: EdgeInsets.symmetric(
            vertical: small ? 10 : 12,
            horizontal: small ? 10 : 14,
          ),
          backgroundColor: bg,
          borderColor: border,
          shadow: false,
          onTap: onPressed,
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: fg,
                fontWeight: FontWeight.w900,
                fontSize: small ? 13.0 : 14.5,
                letterSpacing: 0.2,
                height: 1.05,
              ),
            ),
          ),
        );
      },
    );
  }
}
