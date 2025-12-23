// lib/tabs/account_tab.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:transcript/common/app_flushbar.dart';
import 'package:transcript/objectbox/objectbox_store.dart';

import '../auth/profile_model.dart';
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
    if (ex == null)
      return true; // current rule: upgraded without date => active
    return ex.isAfter(DateTime.now().toUtc());
  }

  // ---------------- Date format ----------------

  String _fmtDateLong(DateTime? d) {
    if (d == null) return '—';
    final local = d.toLocal();
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final day = local.day.toString();
    final month = months[local.month - 1];
    final year = local.year.toString();
    return '$day $month $year';
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

  // ---------------- Upgrade flow (single product) ----------------

  Future<void> _startUpgradeFlow() async {
    if (_upgrading) return;
    await _upgradeWithStore(kProSubscriptionId);
  }

  Future<void> _upgradeWithStore(String productId) async {
    if (_upgrading) return;

    _activeUpgrade = _upgradeInternal(productId);
    await _activeUpgrade;
    _activeUpgrade = null;
  }

  Future<void> _upgradeInternal(String productId) async {
    setState(() {
      _upgrading = true;
      _error = null;
    });

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
        throw Exception('Purchase not completed.');
      }

      await _loadProfile(force: true);

      if (!mounted) return;
      await AppFlushbar.success(context, message: 'Upgrade successful!');
      widget.onUpgradeSuccess?.call();

      setState(() => _upgrading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _upgrading = false;
        _error = 'Upgrade failed: $e';
      });
      await AppFlushbar.error(context, message: 'Upgrade failed');
    }
  }

  Future<void> _signOut() async {
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
      // Calls Supabase Edge Function: delete-account
      // This function must delete profile + auth user using service_role.
      await _sb.functions.invoke('delete-account');
      
      await ObjectBox.I.clearAllData();

      if (!mounted) return;
      await AppFlushbar.success(context, message: 'Account deleted');
      // Best-effort sign out on client
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
          // ✅ Header padding updated (icon + Account text)
          const Padding(
            padding: EdgeInsets.fromLTRB(6, 8, 6, 12),
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
                            _pill(
                              'Joined ${_fmtDateLong(_profile?.dateJoined)}',
                            ),
                            if (_proActive)
                              _pill('Plan Pro', color: const Color(0xFF8E7CFF))
                            else if (_trialActive)
                              _pill(
                                'Plan Trial',
                                color: const Color(0xFF65D6FF),
                              )
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
                        trailing: _pill(
                          'Active',
                          color: const Color(0xFF8E7CFF),
                        ),
                      ),

                    const SizedBox(height: 14),

                    if (!_proActive)
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _upgrading ? null : _startUpgradeFlow,
                          icon: _upgrading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.workspace_premium_outlined),
                          label: Text(
                            _upgrading ? 'Upgrading…' : 'Upgrade to Pro',
                          ),
                        ),
                      )
                    else
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

            // ✅ Refined access card: only enabled/disabled
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
                      accessEnabled
                          ? Icons.lock_open_outlined
                          : Icons.lock_outline,
                      color: accessEnabled ? Colors.white : Colors.redAccent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        accessEnabled ? 'Access enabled' : 'Access disabled',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: accessEnabled
                              ? Colors.white70
                              : Colors.redAccent,
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

            // ✅ Delete account button (no redesign; just an extra button)
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
                    : const Icon(
                        Icons.delete_forever_outlined,
                        color: Colors.redAccent,
                      ),
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
        Expanded(
          child: Text(k, style: const TextStyle(color: Colors.white70)),
        ),
        Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
        if (trailing != null) ...[const SizedBox(width: 8), trailing],
      ],
    );
  }
}

// ---------------- Avatar ----------------

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
      return CircleAvatar(radius: 26, backgroundImage: NetworkImage(url));
    }

    final letter = (fallbackEmail != null && fallbackEmail!.isNotEmpty)
        ? fallbackEmail![0].toUpperCase()
        : 'U';

    return CircleAvatar(radius: 26, child: Text(letter));
  }
}
