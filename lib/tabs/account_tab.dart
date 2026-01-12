// lib/tabs/account_tab.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:transcript/common/app_flushbar.dart';
import 'package:transcript/objectbox/objectbox_store.dart';

import '../auth/profile_model.dart';
import '../auth/eligibility_gate.dart';
import '../billing/subscription_service.dart';
import '../billing/subscription_products.dart';
import '../common/confirm_dialog.dart';

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

  bool _upgrading = false;
  Future<void>? _activeUpgrade;

  bool _restoring = false;

  bool _deleting = false;

  SupabaseClient get _sb => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _loadProfile();

    _authSub = _sb.auth.onAuthStateChange.listen((_) {
      _loadProfile(force: true);
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  // ---------------- Load profile ----------------

  Future<void> _loadProfile({bool force = false}) async {
    if (!force && _activeLoad != null) {
      await _activeLoad;
      return;
    }

    _activeLoad = _loadProfileInternal();
    await _activeLoad;
    _activeLoad = null;
  }

  Future<void> _loadProfileInternal() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final user = _sb.auth.currentUser;
      if (user == null) {
        setState(() {
          _profile = null;
          _loading = false;
        });
        return;
      }

      final row = await _sb.from('profiles').select().eq('id', user.id).maybeSingle();

      if (row == null) {
        final now = DateTime.now().toUtc();
        await _sb.from('profiles').insert({
          'id': user.id,
          'email': user.email,
          'date_joined': now.toIso8601String(),
          'is_upgraded': false,
          'trial_expires_at': now.add(const Duration(days: 7)).toIso8601String(),
        });

        final row2 = await _sb.from('profiles').select().eq('id', user.id).maybeSingle();
        if (row2 == null) throw Exception('Profile creation failed.');

        setState(() {
          _profile = AppProfile.fromMap(Map<String, dynamic>.from(row2));
          _loading = false;
        });
        return;
      }

      setState(() {
        _profile = AppProfile.fromMap(Map<String, dynamic>.from(row));
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // ---------------- Status helpers ----------------

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

    final ex = p.proExpiresAt;
    if (ex == null) return true;
    return ex.isAfter(DateTime.now().toUtc());
  }

  // ---------------- Date format ----------------

  String _fmtDateLong(DateTime? d) {
    if (d == null) return '—';
    final local = d.toLocal();
    const months = [
      'January','February','March','April','May','June',
      'July','August','September','October','November','December',
    ];
    return '${local.day} ${months[local.month - 1]} ${local.year}';
  }

  Widget _pill(String text, {Color? color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: (color ?? Colors.white24).withOpacity(0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: (color ?? Colors.white24).withOpacity(0.45)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: color ?? Colors.white70,
        ),
      ),
    );
  }

  // ---------------- GateSplash-like overlay + eligibility check ----------------

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

    try {
      await _loadProfile(force: true);

      if (pollForPro) {
        for (int i = 0; i < 8; i++) {
          await _loadProfile(force: true);
          if (_proActive) break;
          await Future.delayed(const Duration(milliseconds: 600));
        }
      }

      final res = await checkEligibilityOnce(_sb);

      final elapsed = DateTime.now().difference(started);
      const minVisible = Duration(milliseconds: 1400);
      final remaining = minVisible - elapsed;
      if (remaining > Duration.zero) await Future.delayed(remaining);

      return res;
    } finally {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    }
  }

  // ---------------- Restore flow ----------------

  Future<void> _restorePurchasesFlow() async {
    if (_restoring || _upgrading) return;

    setState(() {
      _restoring = true;
      _error = null;
    });

    bool ok = false;

    try {
      // Ensure purchase stream is listening
      await SubscriptionService.I.initialize();

      // Trigger restore
      ok = await SubscriptionService.I.restore(timeout: const Duration(seconds: 35));

      // Regardless of restore result, refresh + verify
      final res = await _showGateSplashAndVerify(
        status: 'Restoring purchases…',
        pollForPro: true,
      );

      if (!mounted) return;

      if (_proActive && res.eligible) {
        await AppFlushbar.success(context, message: 'Restore successful');
      } else if (ok) {
        // entitlementApplied happened but UI may need another refresh
        await AppFlushbar.success(context, message: 'Restore applied. Refreshing…');
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

  // ---------------- Upgrade flow (single product) ----------------

  Future<void> _startUpgradeFlow() async {
    if (_upgrading || _restoring) return;
    await _upgradeWithStore(kProSubscriptionId);
  }

  Future<void> _upgradeWithStore(String productId) async {
    if (_upgrading || _restoring) return;

    _activeUpgrade = _upgradeInternal(productId);
    await _activeUpgrade;
    _activeUpgrade = null;
  }

  Future<void> _upgradeInternal(String productId) async {
    setState(() {
      _upgrading = true;
      _error = null;
    });

    bool purchaseOk = false;

    try {
      final products = await SubscriptionService.I.fetchProducts();
      final product = products.where((p) => p.id == productId).isNotEmpty
          ? products.firstWhere((p) => p.id == productId)
          : null;

      if (product == null) {
        throw Exception('Product not found in Play Console: $productId');
      }

      final ok = await SubscriptionService.I.buy(product);

      if (!ok) {
        // This covers:
        // - user canceled
        // - already owned (often needs restore)
        // - no purchaseStream update (timeout)
        throw Exception('Purchase not completed (cancelled/owned/timeout). Try Restore.');
      }

      purchaseOk = true;

      if (mounted) {
        await AppFlushbar.success(context, message: 'Purchase completed');
        widget.onUpgradeSuccess?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Upgrade failed: $e');
        await AppFlushbar.error(context, message: 'Upgrade failed');
      }
    } finally {
      if (!mounted) return;

      final res = await _showGateSplashAndVerify(
        status: purchaseOk ? 'Verifying purchase…' : 'Refreshing status…',
        pollForPro: purchaseOk,
      );

      if (!mounted) return;

      if (purchaseOk && res.eligible) {
        await AppFlushbar.success(context, message: 'Pro verified');
      } else if (purchaseOk && !res.eligible) {
        await AppFlushbar.error(context, message: 'Verification pending');
      }

      setState(() => _upgrading = false);
    }
  }

  Future<void> _signOut() async {
    final ok = await showConfirmDeleteDialog(
      context,
      title: 'Sign out?',
      message: 'You will be signed out of your account.',
      confirmText: 'Sign out',
      cancelText: 'Cancel',
    );
    if (!ok) return;
    await _sb.auth.signOut();
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

    return RefreshIndicator(
      onRefresh: () => _loadProfile(force: true),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 24, 6, 12),
            child: Row(
              children: [
                Icon(Icons.account_circle_outlined),
                SizedBox(width: 10),
                Text(
                  'Account',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),

          Card(
            elevation: 0.6,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
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
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _profile?.email ?? user.email ?? 'Unknown',
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _pill('Joined ${_fmtDateLong(_profile?.dateJoined)}'),
                            if (_proActive)
                              _pill('Plan Pro', color: const Color(0xFF8E7CFF))
                            else if (_trialActive)
                              _pill('Plan Trial', color: const Color(0xFF65D6FF))
                            else
                              _pill('Plan Free'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: CircularProgressIndicator(),
              ),
            ),

          if (_error != null)
            Card(
              elevation: 0.3,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            ),

          if (!_loading && _profile != null) ...[
            Card(
              elevation: 0.6,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Plan details',
                      style: TextStyle(fontWeight: FontWeight.w600),
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

                    const SizedBox(height: 6),

                    if (!_proActive)
                      _kvRow(
                        'Trial ends',
                        _fmtDateLong(_profile!.trialExpiresAt),
                        trailing: _trialActive
                            ? _pill('Active', color: const Color(0xFF65D6FF))
                            : _pill('Expired', color: Colors.redAccent),
                      ),

                    const SizedBox(height: 6),

                    if (_proActive)
                      _kvRow(
                        'Pro expiry',
                        _fmtDateLong(_profile!.proExpiresAt),
                        trailing: _pill('Active', color: const Color(0xFF8E7CFF)),
                      ),

                    const SizedBox(height: 14),

                    if (!_proActive) ...[
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: (_upgrading || _restoring) ? null : _startUpgradeFlow,
                          icon: _upgrading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.workspace_premium_outlined),
                          label: Text(_upgrading ? 'Upgrading…' : 'Upgrade to Pro'),
                        ),
                      ),

                      const SizedBox(height: 10),

                      // ✅ TEMP RESTORE BUTTON (remove later)
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: (_restoring || _upgrading) ? null : _restorePurchasesFlow,
                          icon: _restoring
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.restore),
                          label: Text(_restoring ? 'Restoring…' : 'Restore Purchases'),
                        ),
                      ),
                    ] else
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: null,
                          icon: const Icon(Icons.verified),
                          label: const Text('You are Pro'),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            Card(
              elevation: 0.6,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(
                      accessEnabled ? Icons.lock_open_outlined : Icons.lock_outline,
                      color: accessEnabled ? Colors.white : Colors.redAccent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        accessEnabled ? 'Access enabled' : 'Access disabled',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: accessEnabled ? Colors.white70 : Colors.redAccent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _signOut,
                icon: const Icon(Icons.logout),
                label: const Text('Sign out'),
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
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_forever_outlined, color: Colors.redAccent),
                label: Text(
                  _deleting ? 'Deleting…' : 'Delete account',
                  style: const TextStyle(color: Colors.redAccent),
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: Text(k, style: const TextStyle(color: Colors.white70))),
        Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
        if (trailing != null) ...[const SizedBox(width: 8), trailing],
      ],
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
                Container(
                  height: 72,
                  width: 72,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A22),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFF8E7CFF).withValues(alpha: 0.4),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Image.asset(
                      'assets/logo/logo-transparent.png',
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Starting up…',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 20),
                const LinearProgressIndicator(minHeight: 3),
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
    url ??= (meta['avatar_url'] ?? meta['picture'] ?? meta['photo_url']) as String?;

    if (url != null && url.trim().isNotEmpty) {
      return CircleAvatar(radius: 26, backgroundImage: NetworkImage(url));
    }

    final letter = (fallbackEmail != null && fallbackEmail!.isNotEmpty)
        ? fallbackEmail![0].toUpperCase()
        : 'U';

    return CircleAvatar(radius: 26, child: Text(letter));
  }
}
