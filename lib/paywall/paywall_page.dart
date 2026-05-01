import 'package:flutter/material.dart';
import 'dart:io';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:transcript/widgets/icon_pill_button.dart';

import '../billing/subscription_products.dart';
import '../billing/subscription_service.dart';
import '../common/app_flushbar.dart';
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
    this.onClose,
    this.onPremiumUnlocked,
  });

  final Future<void> Function()? onClose;
  final Future<void> Function()? onPremiumUnlocked;

  @override
  State<PaywallPage> createState() => _PaywallPageState();
}

class _PaywallPageState extends State<PaywallPage> {
  bool _busy = false;
  bool _loadingProducts = true;
  bool _restoring = false;
  String? _error;
  List<ProductDetails> _products = const [];
  PaywallPlan _selectedPlan = PaywallPlan.yearly;

  static const String _privacyUrl = 'https://enyx.app/privacy/meeting-transcript-unlimited';
  static const String _termsUrl =
      'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/';

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

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
      await widget.onClose?.call();
    } catch (_) {}
  }

  ProductDetails? _productForPlan(PaywallPlan plan) {
    for (final p in _products) {
      if (plan == PaywallPlan.lifetime && p.id == kProLifetimeId) return p;
      if (plan == PaywallPlan.yearly && p.id == kProYearlyId) return p;
      if (plan == PaywallPlan.monthly && p.id == kProMonthlyId) return p;
    }
    return null;
  }

  ProductDetails? get _selectedProduct => _productForPlan(_selectedPlan);
  bool get _selectedPlanSupportsTrial => _selectedPlan != PaywallPlan.lifetime;
  bool get _premiumActive => SubscriptionService.I.premiumActive;

  String get _activePlanLabel {
    final id = SubscriptionService.I.activeProductId;
    if (id == kProLifetimeId) return 'Lifetime';
    if (id == kProYearlyId) return 'Yearly';
    if (id == kProMonthlyId) return 'Monthly';
    return 'Premium';
  }

  Future<void> _loadProducts() async {
    try {
      await SubscriptionService.I.initializePurchase();
      final products = await SubscriptionService.I.fetchProducts();
      if (!mounted) return;
      setState(() {
        _products = products;
        _loadingProducts = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingProducts = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _onPremiumUnlocked() async {
    try {
      await widget.onPremiumUnlocked?.call();
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).maybePop(true);
  }

  Future<void> _purchase(ProductDetails product) async {
    setState(() => _busy = true);

    try {
      final ok = await SubscriptionService.I.purchaseSubscription(product);
      if (!mounted) return;
      if (ok && SubscriptionService.I.premiumActive) {
        await _onPremiumUnlocked();
        return;
      }

      final message = SubscriptionService.I.lastStoreError ??
          SubscriptionService.I.lastVerifyError ??
          'Purchase could not be completed.';
      setState(() => _error = message);
      await AppFlushbar.error(context, message: message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startFreeTrial() async {
    if (_busy || _restoring) return;
    final product = (_selectedPlan == PaywallPlan.lifetime)
        ? (_productForPlan(PaywallPlan.yearly) ?? _productForPlan(PaywallPlan.monthly))
        : _selectedProduct;
    if (product == null) {
      await AppFlushbar.error(context, message: 'Subscription is unavailable right now.');
      return;
    }
    await _purchase(product);
  }

  Future<void> _subscribe() async {
    if (_busy || _restoring) return;
    final product = _selectedProduct;
    if (product == null) {
      await AppFlushbar.error(context, message: 'Subscription is unavailable right now.');
      return;
    }
    await _purchase(product);
  }

  Future<void> _restorePurchases() async {
    if (_busy || _restoring) return;
    setState(() => _restoring = true);
    try {
      final ok = await SubscriptionService.I.restorePurchases();
      if (!mounted) return;
      if (ok && SubscriptionService.I.premiumActive) {
        await _onPremiumUnlocked();
        return;
      }
      const message = 'No active purchase was found to restore.';
      setState(() => _error = message);
      await AppFlushbar.info(context, message: message);
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  Future<void> _openManageSubscription() async {
    final ok = await launchUrl(
      Uri.parse('https://apps.apple.com/account/subscriptions'),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      await AppFlushbar.error(
        context,
        message: 'Could not open App Store subscription settings.',
      );
    }
  }

  String _priceFor(PaywallPlan plan, {required String fallback}) {
    final product = _productForPlan(plan);
    return product?.price ?? fallback;
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
                          'Premium Transcription',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.4,
                                color: fg,
                              ),
                        ),
                      ),

                      const SizedBox(height: 14),

                      _Panel(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Premium Subscription Includes:',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w900,
                                    color: fg,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '• Unlimited audio transcription\n'
                              '• Transcribe YouTube videos\n'
                              '• Transcribe audio files\n'
                              '• Transcribe video files\n'
                              '• Voice recording transcription\n'
                              '• Phone call transcription (coming soon)',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.white.withValues(alpha: 0.76),
                                    height: 1.35,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

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
                            Icon(
                              _premiumActive ? Icons.verified : Icons.check_circle,
                              color: _premiumActive
                                  ? Colors.lightBlueAccent
                                  : Colors.lightGreenAccent,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _premiumActive
                                    ? 'Your $_activePlanLabel premium access is active'
                                    : (_selectedPlanSupportsTrial
                                        ? '3-day free trial for eligible new subscribers'
                                        : 'Lifetime unlock with one-time purchase'),
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: fg,
                                    ),
                              ),
                            ),
                            Text(
                              _premiumActive ? 'ACTIVE' : 'FREE',
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

                      // Plans
                      _Panel(
                        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
                        child: Column(
                          children: [
                            _PlanDisplayRow(
                              title: 'Lifetime',
                              subtitle: 'One-time payment',
                              price: _priceFor(PaywallPlan.lifetime, fallback: '\$99.99'),
                              subPrice: 'forever',
                              badge: 'BEST OFFER',
                              selected: _selectedPlan == PaywallPlan.lifetime,
                              onTap: () => setState(() => _selectedPlan = PaywallPlan.lifetime),
                            ),
                            const _DividerLineTight(),
                            _PlanDisplayRow(
                              title: 'Yearly',
                              subtitle: 'Billed yearly',
                              price: _priceFor(PaywallPlan.yearly, fallback: '\$49.99'),
                              subPrice: 'per year',
                              selected: _selectedPlan == PaywallPlan.yearly,
                              onTap: () => setState(() => _selectedPlan = PaywallPlan.yearly),
                            ),
                            const _DividerLineTight(),
                            _PlanDisplayRow(
                              title: 'Monthly',
                              subtitle: 'Billed monthly',
                              price: _priceFor(PaywallPlan.monthly, fallback: '\$8.99'),
                              subPrice: 'per month',
                              selected: _selectedPlan == PaywallPlan.monthly,
                              onTap: () => setState(() => _selectedPlan = PaywallPlan.monthly),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      if (_loadingProducts)
                        const Center(child: CircularProgressIndicator())
                      else ...[
                        if (_error != null && _error!.trim().isNotEmpty) ...[
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: const Color(0xFFFFB4B4),
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 10),
                        ],
                      ],

                      if (_premiumActive) ...[
                        GlassButton(
                          kind: GlassButtonKind.primary,
                          label: 'Manage Subscription',
                          icon: Icons.manage_accounts_outlined,
                          onPressed: _openManageSubscription,
                        ),
                        const SizedBox(height: 10),
                      ] else ...[
                        GlassButton(
                          kind: GlassButtonKind.primary,
                          label: _busy
                              ? 'Please wait…'
                              : (_selectedPlanSupportsTrial
                                  ? 'Start 3-Day Free Trial'
                                  : 'Buy Lifetime'),
                          icon: _selectedPlanSupportsTrial
                              ? Icons.bolt
                              : Icons.workspace_premium_outlined,
                          loading: _busy,
                          onPressed: (_busy || _loadingProducts || _restoring)
                              ? null
                              : (_selectedPlanSupportsTrial
                                  ? _startFreeTrial
                                  : _subscribe),
                        ),

                        const SizedBox(height: 10),

                        LayoutBuilder(
                          builder: (context, constraints) {
                            final stacked = constraints.maxWidth < 360;
                            final subscribeButton = GlassButton(
                              kind: GlassButtonKind.secondary,
                              label: _busy
                                  ? 'Processing…'
                                  : (_selectedPlan == PaywallPlan.lifetime
                                      ? 'Buy Lifetime'
                                      : 'Subscribe'),
                              icon: Icons.workspace_premium_outlined,
                              onPressed: (_busy || _loadingProducts || _restoring)
                                  ? null
                                  : _subscribe,
                            );
                            final restoreButton = GlassButton(
                              kind: GlassButtonKind.secondary,
                              label: _restoring ? 'Restoring…' : 'Restore Purchase',
                              icon: Icons.restore,
                              loading: _restoring,
                              onPressed: (_busy || _loadingProducts || _restoring)
                                  ? null
                                  : _restorePurchases,
                            );

                            if (stacked) {
                              return Column(
                                children: [
                                  subscribeButton,
                                  const SizedBox(height: 10),
                                  restoreButton,
                                ],
                              );
                            }

                            return Row(
                              children: [
                                Expanded(child: subscribeButton),
                                const SizedBox(width: 10),
                                Expanded(child: restoreButton),
                              ],
                            );
                          },
                        ),

                        const SizedBox(height: 10),
                      ],

                      Center(
                        child: Text(
                          'Auto-renewable subscription. Cancel anytime in App Store settings before the trial ends to avoid renewal.',
                          textAlign: TextAlign.center,
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
                              onPressed: () => _openExternal(_termsUrl),
                              child: const Text('Terms of Use'),
                            ),
                            TextButton(
                              onPressed: () => _openExternal(_privacyUrl),
                              child: const Text('Privacy Policy'),
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
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final String title;
  final String subtitle;
  final String price;
  final String subPrice;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final fg = Colors.white.withValues(alpha: 0.92);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: selected
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.transparent,
          border: Border.all(
            color: selected
                ? Colors.white.withValues(alpha: 0.28)
                : Colors.transparent,
          ),
        ),
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
            const SizedBox(width: 10),
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
