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
  final res = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (ctx) {
      final isDark = GlassTokens.isDark(ctx);

      final fg = Colors.white.withValues(alpha: 0.92);
      final sub = Colors.white.withValues(alpha: 0.70);

      final dialogBlur = isDark ? 10.0 : 7.0;

      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: LiquidGlass(
              borderRadius: BorderRadius.circular(22),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              shadow: true,
              blurX: dialogBlur,
              blurY: dialogBlur,
              grain: false,
              tintOpacityDark: 0.16,
              tintOpacityLight: 0.14,
              borderOpacityDark: 0.22,
              borderOpacityLight: 0.20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ---------- Title row ----------
                  Row(
                    children: [
                      // red icon pill (keeps your warning affordance)
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.red.withValues(alpha: 0.28),
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
                          style: TextStyle(
                            color: fg,
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                            letterSpacing: -0.1,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
            
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
                        color: Colors.red.withValues(alpha: 0.20),
                      ),
                    ),
                    child: Text(
                      message,
                      style: TextStyle(
                        color: sub,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),

                  const SizedBox(height: 14),

                  // ---------- Actions ----------
                  Row(
                    children: [
                      Expanded(
                        child: _GlassActionButton(
                          label: cancelText,
                          kind: _GlassActionButtonKind.secondary,
                          onPressed: () => Navigator.of(ctx).pop(false),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _GlassActionButton(
                          label: confirmText,
                          kind: _GlassActionButtonKind.danger,
                          onPressed: () => Navigator.of(ctx).pop(true),
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
    
    // ✅ keep danger red, others black/white glass
    final isDanger = kind == _GlassActionButtonKind.danger;

    final tintDark = isDanger ? 0.10 : (kind == _GlassActionButtonKind.primary ? 0.12 : 0.085);
    final tintLight = isDanger ? 0.10 : (kind == _GlassActionButtonKind.primary ? 0.10 : 0.070);

    final borderDark = isDanger ? 0.26 : (kind == _GlassActionButtonKind.primary ? 0.22 : 0.18);
    final borderLight = isDanger ? 0.24 : (kind == _GlassActionButtonKind.primary ? 0.20 : 0.16);

    final fg = isDanger
        ? Colors.redAccent
        : Colors.white.withValues(alpha: 0.92);

    return LayoutBuilder(
      builder: (_, c) {
        final small = c.maxWidth < 160;

        return LiquidGlass(
          borderRadius: BorderRadius.circular(16),
          padding: EdgeInsets.symmetric(
            vertical: small ? 10 : 12,
            horizontal: small ? 10 : 14,
          ),
          shadow: false,
          blurX: 0,
          blurY: 0,
          grain: false,
          tintOpacityDark: tintDark,
          tintOpacityLight: tintLight,
          borderOpacityDark: borderDark,
          borderOpacityLight: borderLight,
          onTap: onPressed,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w900,
                  fontSize: small ? 13.0 : 14.5,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}