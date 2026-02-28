import 'package:flutter/material.dart';
import 'dart:io';

import 'package:url_launcher/url_launcher.dart';
import 'package:transcript/widgets/icon_pill_button.dart';

// ✅ Glass primitives
import '../ui/glass/liquid_glass.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_button.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/glass_tokens.dart';
import '../ui/glass/glass_background.dart'; // <- your GlassBackground widget

enum PaywallPlan { lifetime, yearly, monthly }

class PaywallPage extends StatefulWidget {
  const PaywallPage({
    super.key,
    required this.onClose,
    required this.onContinue,
  });

  final Future<void> Function() onClose;
  final Future<void> Function(PaywallPlan plan) onContinue;

  @override
  State<PaywallPage> createState() => _PaywallPageState();
}

class _PaywallPageState extends State<PaywallPage> {
  bool _busy = false;

  // User won’t choose, but we must keep signature
  static const PaywallPlan _defaultPlan = PaywallPlan.lifetime;
  static const String _policyUrl = 'https://enyx.app/privacy/enyx-transcriptor';

  Future<void> _openExternal(String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok) return;
  }

  Future<void> _close() async {
    if (_busy) return;

    // ✅ Close first (instant UX)
    Navigator.of(context, rootNavigator: true).maybePop();

    // ✅ side effects after
    try {
      await widget.onClose();
    } catch (_) {}
  }

  Future<void> _continue() async {
    if (_busy) return;
    setState(() => _busy = true);

    try {
      await widget.onContinue(_defaultPlan);

      if (!mounted) return;

      // ✅ Close paywall ONLY (Timeline will show)
      Navigator.of(context, rootNavigator: true).maybePop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = Colors.white.withValues(alpha: 0.92);

    // // ✅ tint-only close pill (consistent with sheets)
    // Widget closePill() {
    //   return LiquidGlass(
    //     borderRadius: BorderRadius.circular(999),
    //     padding: const EdgeInsets.all(8),
    //     shadow: false,
    //     blurX: 0,
    //     blurY: 0,
    //     grain: false,
    //     tintOpacityDark: 0.070,
    //     tintOpacityLight: 0.055,
    //     borderOpacityDark: 0.16,
    //     borderOpacityLight: 0.20,
    //     onTap: _busy ? null : _close,
    //     child: Icon(Icons.close, color: fg, size: 20),
    //   );
    // }

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.all(10),
          child: IconPillButton(tooltip: 'close',onTap: _busy ? null : _close,icon: Icons.close,),
        ),
      ),
      body: GlassBackground(
        // ✅ your wallpaper
        child: SafeArea(
          top: false,
          child: Stack(
            children: [
              // ✅ Dark scrim for readability on any wallpaper
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    color: Colors.black.withValues(alpha: isDark ? 0.55 : 0.35),
                  ),
                ),
              ),

              // ✅ Subtle radial glow
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0, -0.8),
                        radius: 1.2,
                        colors: [
                          Colors.blue.withValues(alpha: isDark ? 0.18 : 0.14),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Main content
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 54, 16, 18),
                    children: [
                      const SizedBox(height: 6),

                      // ✅ Logo (inside glass)
                      Center(
                        child: LiquidGlass(
                          borderRadius: BorderRadius.circular(22),
                          padding: const EdgeInsets.all(10),
                          shadow: false,
                          blurX: 10,
                          blurY: 10,
                          tintOpacityDark: 0.10,
                          tintOpacityLight: 0.08,
                          borderOpacityDark: 0.18,
                          borderOpacityLight: 0.22,
                          child: SizedBox(
                            width: 74,
                            height: 74,
                            child: Image.asset(
                              'assets/logo/transcript-transparent.png',
                              fit: BoxFit.contain,
                              errorBuilder: (_, _, _) => const Icon(
                                Icons.image_not_supported_outlined,
                                color: Colors.white70,
                                size: 28,
                              ),
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Headline
                      Center(
                        child: Text(
                          'GET PRO ACCESS\nGO UNLIMITED',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.4,
                                color: fg,
                              ),
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Features
                      const _Benefit(
                        icon: Icons.all_inclusive,
                        color: Colors.cyanAccent,
                        text: 'Unlimited audio transcriptions',
                      ),
                      const _Benefit(
                        icon: Icons.timer_outlined,
                        color: Colors.greenAccent,
                        text: 'Record meetings of any duration',
                      ),
                      const _Benefit(
                        icon: Icons.play_circle_outline,
                        color: Colors.pinkAccent,
                        text: 'YouTube video transcription',
                      ),

                      const SizedBox(height: 12),

                      // Trial card (glass)
                      _Panel(
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle, color: Colors.lightGreenAccent),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '1-day trial enabled',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: fg,
                                    ),
                              ),
                            ),
                            Text(
                              'FREE',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.white.withValues(alpha: 0.70),
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.2,
                                  ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      // Plans: display-only list (no selection)
                      _Panel(
                        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
                        child: Column(
                          children: const [
                            _PlanDisplayRow(
                              title: 'Lifetime',
                              subtitle: 'One-time payment',
                              price: '\$79.00',
                              subPrice: 'forever',
                              badge: 'BEST OFFER',
                            ),
                            _DividerLineTight(),
                            _PlanDisplayRow(
                              title: 'Yearly',
                              subtitle: 'Billed yearly',
                              price: '\$50.00',
                              subPrice: 'per year',
                            ),
                            _DividerLineTight(),
                            _PlanDisplayRow(
                              title: 'Monthly',
                              subtitle: 'Billed monthly',
                              price: '\$9.00',
                              subPrice: 'per month',
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Continue (glass button)
                      GlassButton(
                        kind: GlassButtonKind.primary,
                        label: _busy ? 'Please wait…' : 'Continue',
                        icon: Icons.arrow_forward,
                        loading: _busy,
                        onPressed: _busy ? null : _continue,
                      ),

                      const SizedBox(height: 10),

                      Center(
                        child: Text(
                          'Cancel anytime',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.white.withValues(alpha: 0.60),
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),

                      if (Platform.isIOS) ...[
                        const SizedBox(height: 10),
                        Text(
                          'Payment will be charged to your Apple ID at confirmation. '
                          'Subscription renews automatically unless canceled at least 24 hours before the end of the current period.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.white54,
                                height: 1.3,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 12,
                          children: [
                            TextButton(
                              onPressed: () => _openExternal(_policyUrl),
                              child: const Text('Terms & Privacy'),
                            ),
                            TextButton(
                              onPressed: () => _openExternal(
                                'https://apps.apple.com/account/subscriptions',
                              ),
                              child: const Text('Manage Subscription'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* ---------- UI bits ---------- */

class _Benefit extends StatelessWidget {
  const _Benefit({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: color.withValues(alpha: 0.35)),
            ),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: Colors.white.withValues(alpha: 0.75),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanDisplayRow extends StatelessWidget {
  const _PlanDisplayRow({
    required this.title,
    required this.subtitle,
    required this.price,
    required this.subPrice,
    this.badge,
  });

  final String title;
  final String subtitle;
  final String price;
  final String subPrice;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final fg = Colors.white.withValues(alpha: 0.92);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 14.5,
                        color: fg,
                      ),
                    ),
                    if (badge != null) ...[
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.20),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: Colors.blue.withValues(alpha: 0.45)),
                        ),
                        child: Text(
                          badge!,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 10,
                            color: Colors.lightBlueAccent,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.70),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                price,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                  color: fg,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subPrice,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.70),
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DividerLineTight extends StatelessWidget {
  const _DividerLineTight();

  @override
  Widget build(BuildContext context) {
    // ✅ use your GlassDivider feel, but tighter
    return const GlassDivider(height: 1);
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      variant: GlassCardVariant.tile,
      padding: padding ?? const EdgeInsets.all(14),
      child: child,
    );
  }
}
