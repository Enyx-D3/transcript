// lib/tabs/account_tab.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../common/app_flushbar.dart';
import '../objectbox/objectbox_store.dart';

import '../auth/profile_model.dart';
import '../auth/app_gate.dart';
import '../auth/eligibility_gate.dart';
import '../billing/subscription_service.dart';
import '../billing/subscription_products.dart';
import '../common/confirm_dialog.dart';

// ✅ Glass primitives (same set you used elsewhere)
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/liquid_glass.dart';

class AccountTab extends StatefulWidget {
  const AccountTab({super.key, this.onUpgradeSuccess});

  final VoidCallback? onUpgradeSuccess;

  @override
  State<AccountTab> createState() => _AccountTabState();
}

class _AccountTabState extends State<AccountTab> {
  AppProfile? _profile;
  bool _loading = true;
  String? _error;

  Future<void>? _activeLoad;
  StreamSubscription<AuthState>? _authSub;
  Timer? _authDebounce;

  bool _upgrading = false;
  Future<void>? _activeUpgrade;

  bool _restoring = false;
  bool _deleting = false;

  List<ProductDetails>? _storeProducts;
  bool _pricingLoading = false;

  SupabaseClient get _sb => Supabase.instance.client;

  static const String _androidPackageName = 'com.enyxd.transcript';
  bool _navigatingToGate = false;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _loadProfile();
      await _prefetchPricing();
    });

    _authSub = _sb.auth.onAuthStateChange.listen((_) {
      _authDebounce?.cancel();
      _authDebounce = Timer(const Duration(milliseconds: 250), () async {
        if (!mounted) return;

        if (_sb.auth.currentUser == null) {
          _resetToAppGate();
          return;
        }

        await _loadProfile(force: true);

        try {
          await SubscriptionService.I.initialize();
          await SubscriptionService.I.reconcileNow(
            timeout: const Duration(seconds: 20),
          );
        } catch (_) {}

        if (mounted) await _loadProfile(force: true);
      });
    });
  }

  @override
  void dispose() {
    _authDebounce?.cancel();
    _authSub?.cancel();
    super.dispose();
  }

  void _resetToAppGate() {
    if (!mounted || _navigatingToGate) return;
    _navigatingToGate = true;

    final nav = Navigator.of(context, rootNavigator: true);
    nav.pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => const AppGate(
          initialEligibility: EligibilityGateResult(eligible: false),
        ),
      ),
      (route) => false,
    );
  }

  // ---------------- Load profile ----------------

  Future<void> _loadProfile({bool force = false}) async {
    if (_activeLoad != null) {
      await _activeLoad;
      return;
    }
    _activeLoad = _loadProfileInternal(force: force);
    try {
      await _activeLoad;
    } finally {
      _activeLoad = null;
    }
  }

  Future<void> _loadProfileInternal({required bool force}) async {
    if (!mounted) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final user = _sb.auth.currentUser;
      if (user == null) {
        if (!mounted) return;
        setState(() {
          _profile = null;
          _loading = false;
        });
        return;
      }

      final row = await _sb
          .from('profiles')
          .select()
          .eq('id', user.id)
          .maybeSingle();

      if (row == null) {
        final now = DateTime.now().toUtc();
        await _sb.from('profiles').insert({
          'id': user.id,
          'email': user.email,
          'date_joined': now.toIso8601String(),
          'is_upgraded': false,
          'trial_expires_at': now
              .add(const Duration(days: 7))
              .toIso8601String(),
        });

        final row2 = await _sb
            .from('profiles')
            .select()
            .eq('id', user.id)
            .maybeSingle();
        if (row2 == null) throw Exception('Profile creation failed.');

        if (!mounted) return;
        setState(() {
          _profile = AppProfile.fromMap(Map<String, dynamic>.from(row2));
          _loading = false;
        });
        return;
      }

      if (!mounted) return;
      setState(() {
        _profile = AppProfile.fromMap(Map<String, dynamic>.from(row));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // ---------------- Pricing ----------------

  Future<void> _prefetchPricing() async {
    if (_pricingLoading) return;
    _pricingLoading = true;

    try {
      await SubscriptionService.I.initialize();
      final products = await SubscriptionService.I.fetchProducts();
      if (!mounted) return;
      setState(() => _storeProducts = products);
    } catch (_) {
      // ignore
    } finally {
      _pricingLoading = false;
    }
  }

  ProductDetails? _productById(String id) {
    final list = _storeProducts;
    if (list == null) return null;
    for (final p in list) {
      if (p.id == id) return p;
    }
    return null;
  }

  String _priceLabel(String id) => _productById(id)?.price ?? '—';

  // ---------------- Status ----------------

  bool get _trialActive {
    final p = _profile;
    if (p == null) return false;
    final ex = p.trialExpiresAt;
    if (ex == null) return false;
    return ex.isAfter(DateTime.now().toUtc());
  }

  bool get _proActive {
    final p = _profile;
    if (p == null) return false;
    if (!p.isUpgraded) return false;

    if (_isLifetime) return true;

    final ex = p.proExpiresAt;
    if (ex == null) return false;
    return ex.isAfter(DateTime.now().toUtc());
  }

  bool get _isLifetime => (_profile?.isLifetime ?? false);

  bool get _isActiveSubscription => _proActive && !_isLifetime;

  String get _proExpiryLabel {
    if (!_proActive) return '—';
    if (_isLifetime) return 'Lifetime';
    return _fmtDateLong(_profile?.proExpiresAt);
  }

  // ---------------- Date format ----------------

  String _fmtDateLong(DateTime? d) {
    if (d == null) return '—';
    final local = d.toLocal();
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${local.day} ${months[local.month - 1]} ${local.year}';
  }

  // ---------------- Actions ----------------

  Future<void> _openManageSubscription() async {
    if (!Platform.isAndroid) {
      if (mounted) {
        await AppFlushbar.error(
          context,
          message: 'Manage subscription is Android-only right now',
        );
      }
      return;
    }

    final url = Uri.parse(
      'https://play.google.com/store/account/subscriptions?package=$_androidPackageName&sku=$kProMonthlyId',
    );

    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      await AppFlushbar.error(
        context,
        message: 'Could not open Play Store subscriptions',
      );
    }
  }

  // ---------------- Gate overlay + eligibility ----------------

  Future<EligibilityGateResult> _showGateSplashAndVerify({
    required String status,
    bool pollForPro = false,
  }) async {
    if (!mounted) return const EligibilityGateResult(eligible: false);

    showDialog(
      context: context,
      barrierDismissible: false,
      useSafeArea: false,
      builder: (_) => _GateSplashLike(status: status),
    );

    final started = DateTime.now();
    EligibilityGateResult res = const EligibilityGateResult(eligible: false);

    Future<void> safeLoadProfile({required bool force}) async {
      try {
        await _loadProfile(force: force).timeout(const Duration(seconds: 10));
      } catch (_) {}
    }

    Future<void> safeReconcile() async {
      try {
        await SubscriptionService.I
            .reconcileNow(timeout: const Duration(seconds: 20))
            .timeout(const Duration(seconds: 22));
      } catch (_) {}
    }

    try {
      await safeLoadProfile(force: true);

      if (pollForPro) {
        await safeReconcile();

        for (int i = 0; i < 10; i++) {
          await safeLoadProfile(force: true);
          if (_proActive) break;
          await Future.delayed(const Duration(milliseconds: 600));
        }
      }

      try {
        res = await checkEligibilityOnce(_sb).timeout(
          const Duration(seconds: 8),
          onTimeout: () => const EligibilityGateResult(eligible: false),
        );
      } catch (_) {
        res = const EligibilityGateResult(eligible: false);
      }

      final elapsed = DateTime.now().difference(started);
      const minVisible = Duration(milliseconds: 1400);
      final remaining = minVisible - elapsed;
      if (remaining > Duration.zero) await Future.delayed(remaining);
    } finally {
      final nav = Navigator.of(context, rootNavigator: true);
      if (mounted && nav.canPop()) nav.pop();
    }

    return res;
  }

  // ---------------- Restore ----------------

  Future<void> _restorePurchasesFlow() async {
    if (_restoring || _upgrading) return;

    if (!mounted) return;
    setState(() {
      _restoring = true;
      _error = null;
    });

    bool ok = false;

    try {
      await SubscriptionService.I.initialize();

      ok = await SubscriptionService.I.restore(
        timeout: const Duration(seconds: 35),
      );

      final res = await _showGateSplashAndVerify(
        status: 'Restoring purchases…',
        pollForPro: true,
      );

      if (!mounted) return;

      final code = SubscriptionService.I.lastVerifyCode;

      if (code == 'TOKEN_ALREADY_CLAIMED') {
        await AppFlushbar.error(
          context,
          message: 'This purchase is already linked to another account.',
        );
        return;
      }

      if (_proActive && res.eligible) {
        await AppFlushbar.success(context, message: 'Restore successful');
      } else if (ok) {
        await AppFlushbar.success(
          context,
          message: 'Restore applied. Refreshing…',
        );
      } else {
        await AppFlushbar.error(context, message: 'No active purchase found');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Restore failed: $e');
      await AppFlushbar.error(context, message: 'Restore failed');
    } finally {
      if (!mounted) return;
      setState(() => _restoring = false);
    }
  }

  // ---------------- Purchase / Upgrade ----------------

  Future<void> _startMonthlyFlow() async {
    if (_upgrading || _restoring) return;
    await _upgradeWithStore(kProMonthlyId);
  }

  Future<void> _startYearlyFlow() async {
    if (_upgrading || _restoring) return;
    await _upgradeWithStore(kProYearlyId);
  }

  Future<void> _startLifetimeFlow() async {
    if (_upgrading || _restoring) return;
    await _upgradeWithStore(kProLifetimeId);
  }

  Future<void> _upgradeWithStore(String productId) async {
    if (_upgrading || _restoring) return;

    _activeUpgrade = _upgradeInternal(productId);
    await _activeUpgrade;
    _activeUpgrade = null;
  }

  Future<void> _upgradeInternal(String productId) async {
    if (!mounted) return;
    setState(() {
      _upgrading = true;
      _error = null;
    });

    bool purchaseStarted = false;

    try {
      await SubscriptionService.I.initialize();

      if (_storeProducts == null) {
        await _prefetchPricing();
      }

      final products =
          _storeProducts ?? await SubscriptionService.I.fetchProducts();
      ProductDetails? product;
      for (final p in products) {
        if (p.id == productId) {
          product = p;
          break;
        }
      }
      if (product == null) throw Exception('Product not found: $productId');

      final ok = await SubscriptionService.I.buy(product);
      if (!ok) throw Exception('Purchase not completed. Try Restore.');

      purchaseStarted = true;

      if (mounted) {
        await AppFlushbar.success(
          context,
          message: 'Purchase received. Verifying…',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Purchase failed: $e');
        await AppFlushbar.error(context, message: 'Purchase failed');
      }
    } finally {
      if (!mounted) return;

      final res = await _showGateSplashAndVerify(
        status: purchaseStarted ? 'Verifying purchase…' : 'Refreshing status…',
        pollForPro: purchaseStarted,
      );

      if (!mounted) return;

      final code = SubscriptionService.I.lastVerifyCode;

      if (purchaseStarted && code == 'TOKEN_ALREADY_CLAIMED') {
        await AppFlushbar.error(
          context,
          message: 'This purchase is already linked to another account.',
        );
        setState(() => _upgrading = false);
        return;
      }

      if (purchaseStarted && res.eligible) {
        await AppFlushbar.success(context, message: 'Pro verified');
        widget.onUpgradeSuccess?.call();
      } else if (purchaseStarted && !res.eligible) {
        await AppFlushbar.error(
          context,
          message: 'Verification pending (try Restore)',
        );
      }

      setState(() => _upgrading = false);
    }
  }

  // ---------------- Sheet (glass) ----------------

  Future<void> _showUpgradeOptionsSheet() async {
    if (!mounted) return;

    if (_storeProducts == null) {
      // ignore: unawaited_futures
      _prefetchPricing();
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        final monthly = _priceLabel(kProMonthlyId);
        final yearly = _priceLabel(kProYearlyId);
        final lifetime = _priceLabel(kProLifetimeId);

        String rightMonthly() => monthly == '—' ? 'Loading…' : '$monthly / mo';
        String rightYearly() => yearly == '—' ? 'Loading…' : '$yearly / yr';
        String rightLifetime() => lifetime == '—' ? 'Loading…' : lifetime;

        Widget optionTile({
          required IconData icon,
          required String title,
          required String subtitle,
          required String priceRight,
          required VoidCallback onTap,
          Widget? badge,
        }) {
          return GlassCard(
            variant: GlassCardVariant.panel,
            padding: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(icon, color: Colors.white.withValues(alpha: 0.90)),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Colors.white.withValues(alpha: 0.92),
                      ),
                    ),
                  ),
                  if (badge != null) ...[const SizedBox(width: 8), badge],
                ],
              ),
              subtitle: Text(
                subtitle,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.70)),
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    priceRight,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Colors.white.withValues(alpha: 0.92),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Icon(
                    Icons.chevron_right,
                    color: Colors.white.withValues(alpha: 0.70),
                  ),
                ],
              ),
              onTap: onTap,
            ),
          );
        }

        Widget badgePill(String text) {
          // ✅ black/white only, no orange (you asked everywhere else)
          return LiquidGlass(
            borderRadius: BorderRadius.circular(999),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            shadow: false,
            blurX: 10,
            blurY: 10,
            tintOpacityDark: 0.040,
            tintOpacityLight: 0.032,
            borderOpacityDark: 0.14,
            borderOpacityLight: 0.18,
            child: Text(
              text,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.2,
                color: Colors.white.withValues(alpha: 0.78),
              ),
            ),
          );
        }

        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: GlassCard(
              variant: GlassCardVariant.tile,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 44,
                    height: 5,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(99),
                      color: Colors.white.withValues(alpha: 0.14),
                    ),
                  ),
                  Row(
                    children: [
                      Icon(
                        Icons.workspace_premium_outlined,
                        color: Colors.white.withValues(alpha: 0.90),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Go Pro',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                            color: Colors.white.withValues(alpha: 0.92),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.close,
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  optionTile(
                    icon: Icons.calendar_month_outlined,
                    title: 'Monthly',
                    subtitle: 'Pay month-to-month. Cancel anytime.',
                    priceRight: rightMonthly(),
                    onTap: () async {
                      Navigator.of(ctx).pop();
                      await _startMonthlyFlow();
                    },
                  ),
                  const SizedBox(height: 10),

                  optionTile(
                    icon: Icons.event_available_outlined,
                    title: 'Yearly',
                    subtitle: 'Best value for long-term use.',
                    priceRight: rightYearly(),
                    badge: badgePill('Best value'),
                    onTap: () async {
                      Navigator.of(ctx).pop();
                      await _startYearlyFlow();
                    },
                  ),
                  const SizedBox(height: 10),

                  optionTile(
                    icon: Icons.all_inclusive,
                    title: 'Lifetime',
                    subtitle: 'One-time purchase. Keep Pro forever.',
                    priceRight: rightLifetime(),
                    badge: badgePill('Best offer'),
                    onTap: () async {
                      Navigator.of(ctx).pop();
                      await _startLifetimeFlow();
                    },
                  ),

                  const SizedBox(height: 12),

                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: (_restoring || _upgrading)
                          ? null
                          : () async {
                              Navigator.of(ctx).pop();
                              await _restorePurchasesFlow();
                            },
                      icon: _restoring
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.restore, color: Colors.white),
                      label: Text(
                        _restoring ? 'Restoring…' : 'Restore Purchases',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------- Sign out ----------------

  Future<void> _signOut() async {
    final ok = await showConfirmDeleteDialog(
      context,
      title: 'Sign out?',
      icon: Icons.logout,
      message: 'You will be signed out of your account.',
      confirmText: 'Sign out',
      cancelText: 'Cancel',
    );
    if (!ok) return;

    if (mounted) {
      setState(() {
        _profile = null;
        _error = null;
        _loading = true;
      });
    }

    await _sb.auth.signOut();
    if (mounted) _resetToAppGate();
  }

  // ---------------- Delete account ----------------

  Future<void> _deleteAccount() async {
    if (_deleting) return;

    final user = _sb.auth.currentUser;
    if (user == null) return;

    final ok = await showConfirmDeleteDialog(
      context,
      title: 'Delete account?',
      message:
          'This will permanently delete your account and transcripts. This action cannot be undone.',
      confirmText: 'Delete',
      cancelText: 'Cancel',
    );
    if (!ok) return;

    if (!mounted) return;
    setState(() {
      _deleting = true;
      _error = null;
    });

    try {
      await _sb.functions.invoke('delete-account');
      await ObjectBox.I.clearAllData();

      if (!mounted) return;
      await AppFlushbar.success(context, message: 'Account deleted');
      await _sb.auth.signOut();
      if (mounted) _resetToAppGate();
      setState(() => _deleting = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _error = 'Delete failed: $e';
      });
      await AppFlushbar.error(context, message: 'Delete failed');
    }
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final user = _sb.auth.currentUser;

    if (user == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.person_outline, size: 48),
              SizedBox(height: 10),
              Text('Not signed in'),
              SizedBox(height: 8),
              Text(
                'Go to the login page to sign in.',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    final meta = user.userMetadata ?? {};
    final displayName =
        (meta['full_name'] ?? meta['name'] ?? meta['display_name']) as String?;
    final heroName = (displayName != null && displayName.trim().isNotEmpty)
        ? displayName.trim()
        : (user.email ?? 'User');

    final accessEnabled = (_proActive || _trialActive);

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return RefreshIndicator(
      color: Colors.white,
      onRefresh: () async {
        await _loadProfile(force: true);
        await _prefetchPricing();
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          // ---------- Profile panel (glass) ----------
          GlassCard(
            variant: GlassCardVariant.panel,
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Avatar(profile: _profile, fallbackEmail: user.email),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        heroName,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                          color: Colors.white.withValues(alpha: 0.92),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _profile?.email ?? user.email ?? 'Unknown',
                        style: TextStyle(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.70)
                              : Colors.black54,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _Pill('Joined ${_fmtDateLong(_profile?.dateJoined)}'),
                          if (_proActive)
                            _Pill(
                              _isLifetime
                                  ? 'Plan Pro (Lifetime)'
                                  : 'Plan Pro (Subscription)',
                            )
                          else if (_trialActive)
                            const _Pill('Plan Trial')
                          else
                            const _Pill('Plan Free'),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),

          if (!_loading && _profile != null) ...[
            // ---------- Plan details panel ----------
            GlassCard(
              variant: GlassCardVariant.panel,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Plan details',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Colors.white.withValues(alpha: 0.92),
                    ),
                  ),
                  const SizedBox(height: 12),

                  _kvRow(
                    'Current plan',
                    _proActive
                        ? 'Pro'
                        : _trialActive
                        ? 'Trial'
                        : 'Free',
                  ),

                  const SizedBox(height: 10),
                  const GlassDivider(height: 1),
                  const SizedBox(height: 10),

                  if (!_proActive)
                    _kvRow(
                      'Trial ends',
                      _fmtDateLong(_profile!.trialExpiresAt),
                      trailing: _trialActive
                          ? const _Pill('Active')
                          : const _Pill('Expired'),
                    ),

                  if (_proActive)
                    _kvRow(
                      _isLifetime ? 'Pro plan' : 'Pro expiry',
                      _proExpiryLabel,
                      trailing: const _Pill('Active'),
                    ),

                  const SizedBox(height: 14),

                  // 1) lifetime => disabled button
                  // 2) active subscription => manage subscription
                  // 3) not pro => get pro sheet
                  if (_proActive && _isLifetime) ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: null,
                        icon: const Icon(Icons.verified),
                        label: const Text('You are Pro (Lifetime)'),
                      ),
                    ),
                  ] else if (_isActiveSubscription) ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: (_upgrading || _restoring)
                            ? null
                            : _openManageSubscription,
                        icon: const Icon(Icons.manage_accounts_outlined),
                        label: const Text('Manage subscription'),
                        style: FilledButton.styleFrom(
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ] else ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: (_upgrading || _restoring)
                            ? null
                            : _showUpgradeOptionsSheet,
                        icon: _upgrading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.workspace_premium_outlined),
                        label: Text(_upgrading ? 'Processing…' : 'Get Pro'),
                        style: FilledButton.styleFrom(
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ---------- Access status panel ----------
            GlassCard(
              variant: GlassCardVariant.panel,
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    accessEnabled
                        ? Icons.lock_open_outlined
                        : Icons.lock_outline,
                    color: Colors.white.withValues(alpha: 0.88),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      accessEnabled ? 'Access enabled' : 'Access disabled',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Colors.white.withValues(alpha: 0.88),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ---------- Actions ----------
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _signOut,
                icon: const Icon(Icons.logout, color: Colors.white),
                label: const Text(
                  'Sign out',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),

            const SizedBox(height: 10),

            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _deleting ? null : _deleteAccount,
                icon: _deleting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        Icons.delete_forever_outlined,
                        color: Colors.white.withValues(alpha: 0.92),
                      ),
                label: Text(
                  _deleting ? 'Deleting…' : 'Delete account',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.92),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],

          if (_error != null) ...[
            const SizedBox(height: 12),
            GlassCard(
              variant: GlassCardVariant.panel,
              padding: const EdgeInsets.all(12),
              child: Text(
                _error!,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],

          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _kvRow(String k, String v, {Widget? trailing}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Row(
      children: [
        Expanded(
          child: Text(
            k,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.70)
                  : Colors.black54,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(
                child: Text(
                  v,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: Colors.white.withValues(alpha: 0.92),
                  ),
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing],
            ],
          ),
        ),
      ],
    );
  }
}

// -------------------- Reusable small widgets --------------------

class _Pill extends StatelessWidget {
  const _Pill(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return LiquidGlass(
      borderRadius: BorderRadius.circular(999),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      shadow: false,
      blurX: 12,
      blurY: 12,
      tintOpacityDark: 0.040,
      tintOpacityLight: 0.032,
      borderOpacityDark: 0.14,
      borderOpacityLight: 0.18,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
          color: Colors.white.withValues(alpha: 0.78),
        ),
      ),
    );
  }
}

class _GateSplashLike extends StatelessWidget {
  const _GateSplashLike({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                LiquidGlass(
                  borderRadius: BorderRadius.circular(20),
                  padding: const EdgeInsets.all(0),
                  shadow: false,
                  blurX: 18,
                  blurY: 18,
                  tintOpacityDark: 0.05,
                  tintOpacityLight: 0.04,
                  borderOpacityDark: 0.16,
                  borderOpacityLight: 0.20,
                  child: SizedBox(
                    height: 72,
                    width: 72,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Image.asset(
                        'assets/logo/transcript-transparent.png',
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Icon(
                          Icons.graphic_eq,
                          color: Colors.white.withValues(alpha: 0.80),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Starting up…',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withValues(alpha: 0.92),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  status,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.70)),
                ),
                const SizedBox(height: 20),
                LinearProgressIndicator(
                  minHeight: 3,
                  color: Colors.white.withValues(alpha: 0.92),
                  backgroundColor: Colors.black,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.profile, required this.fallbackEmail});

  final AppProfile? profile;
  final String? fallbackEmail;

  @override
  Widget build(BuildContext context) {
    String? url = profile?.avatarUrl;

    final user = Supabase.instance.client.auth.currentUser;
    final meta = user?.userMetadata ?? {};
    url ??=
        (meta['avatar_url'] ?? meta['picture'] ?? meta['photo_url']) as String?;

    if (url != null && url.trim().isNotEmpty) {
      return CircleAvatar(
        radius: 26,
        backgroundImage: NetworkImage(url),
        backgroundColor: Colors.white.withValues(alpha: 0.08),
        onBackgroundImageError: (_, _) {},
      );
    }

    final email = fallbackEmail;
    final letter = (email != null && email.isNotEmpty)
        ? email[0].toUpperCase()
        : 'U';

    return CircleAvatar(
      radius: 26,
      backgroundColor: Colors.white,
      child: Text(letter, style: const TextStyle(fontWeight: FontWeight.w900)),
    );
  }
}
