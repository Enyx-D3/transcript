import 'package:flutter/material.dart';
import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

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

  static const bg = Color(0xFF0B0C10);

  // User won’t choose, but we must keep signature
  // so we send lifetime by default (you can change later).
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: bg,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close),
          onPressed: _busy ? null : _close,
        ),
      ),
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            // Subtle background glow
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.8),
                      radius: 1.2,
                      colors: [
                        Colors.blue.withOpacity(isDark ? 0.18 : 0.14),
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

                    // ✅ Logo
                    Center(
                      child: Container(
                        width: 74,
                        height: 74,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(22),
                          color: Colors.white.withOpacity(0.06),
                          border: Border.all(color: Colors.white.withOpacity(0.12)),
                          boxShadow: [
                            BoxShadow(
                              blurRadius: 28,
                              color: Colors.blue.withOpacity(0.18),
                              offset: const Offset(0, 14),
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.all(10),
                        child: Image.asset(
                          'assets/logo/transcript-transparent.png',
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Icon(
                            Icons.image_not_supported_outlined,
                            color: Colors.white70,
                            size: 28,
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
                            ),
                      ),
                    ),

                    const SizedBox(height: 14),

                    // Features (last updated)
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
                    // const _Benefit(
                    //   icon: Icons.language,
                    //   color: Colors.purpleAccent,
                    //   text: '120+ languages supported',
                    // ),
                    const _Benefit(
                      icon: Icons.play_circle_outline,
                      color: Colors.pinkAccent,
                      text: 'YouTube video transcription',
                    ),

                    const SizedBox(height: 12),

                    // Trial card
                    _Panel(
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle, color: Colors.lightGreenAccent),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '1-day trial enabled',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                          ),
                          Text(
                            'FREE',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Colors.white70,
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

                    // Continue
                    SizedBox(
                      height: 54,
                      child: FilledButton(
                        onPressed: _busy ? null : _continue,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.blue,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              _busy ? 'Please wait…' : 'Continue',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Icon(Icons.arrow_forward),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 10),

                    Center(
                      child: Text(
                        'Cancel anytime',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.white60,
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
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: color.withOpacity(0.35)),
            ),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: Colors.white70,
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
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 14.5,
                      ),
                    ),
                    if (badge != null) ...[
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.blue.withOpacity(0.20),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: Colors.blue.withOpacity(0.45)),
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
                  style: const TextStyle(
                    color: Colors.white70,
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
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subPrice,
                style: const TextStyle(
                  color: Colors.white70,
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
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: Colors.white.withOpacity(0.08),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF101018),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
      ),
      child: child,
    );
  }
}
