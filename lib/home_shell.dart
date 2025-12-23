// lib/home_shell.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'tabs/timeline_tab.dart';
import 'calendar/calendar_page.dart';
import 'record/record_sheet.dart';
import 'tabs/ai_chat_tab.dart';
import 'tabs/account_tab.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  bool _checkingEligibility = true;
  bool _eligible = true;
  String? _eligibilityError;

  Future<void>? _activeEligibilityLoad;
  StreamSubscription<AuthState>? _authSub;

  SupabaseClient get _sb => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _refreshEligibility();

    _authSub = _sb.auth.onAuthStateChange.listen((_) {
      _refreshEligibility(force: true);
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  // ---------------- Eligibility check (NO inserts here) ----------------

  Future<void> _refreshEligibility({bool force = false}) async {
    if (!force && _activeEligibilityLoad != null) {
      await _activeEligibilityLoad;
      return;
    }

    _activeEligibilityLoad = _refreshEligibilityInternal();
    await _activeEligibilityLoad;
    _activeEligibilityLoad = null;
  }

  Future<void> _refreshEligibilityInternal() async {
    if (!mounted) return;

    setState(() {
      _checkingEligibility = true;
      _eligibilityError = null;
    });

    try {
      final user = _sb.auth.currentUser;
      if (user == null) {
        setState(() {
          _eligible = false;
          _checkingEligibility = false;
        });
        return;
      }

      final row = await _sb
          .from('profiles')
          .select('is_upgraded, trial_expires_at, pro_expires_at')
          .eq('id', user.id)
          .maybeSingle();

      if (row == null) {
        setState(() {
          _eligible = false;
          _checkingEligibility = false;
        });
        return;
      }

      final map = Map<String, dynamic>.from(row);

      final bool isUpgraded = (map['is_upgraded'] as bool?) ?? false;
      final DateTime? trialExpires = _parseDate(map['trial_expires_at']);
      final DateTime? proExpires = _parseDate(map['pro_expires_at']);

      final now = DateTime.now().toUtc();

      final bool trialActive =
          trialExpires != null && trialExpires.isAfter(now);

      final bool proActive = isUpgraded &&
          (proExpires == null || proExpires.isAfter(now));

      final bool eligible = trialActive || proActive;

      if (!mounted) return;
      setState(() {
        _eligible = eligible;
        _checkingEligibility = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _eligible = false;
        _checkingEligibility = false;
        _eligibilityError = e.toString();
      });
    }
  }

  DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v.toUtc();
    if (v is String) return DateTime.tryParse(v)?.toUtc();
    return null;
  }

  // ---------------- Navigation ----------------

  Future<void> _openRecordSheet() async {
    if (!_eligible) return;
    await RecordSheet.show(context);
  }

  Future<void> _goTo(int i) async {
    if (i == 2) {
      await _openRecordSheet();
      return;
    }

    if (!mounted) return;
    setState(() => _index = i);

    if (i == 4) {
      // refresh quickly when entering account
      unawaited(_refreshEligibility(force: true));
    }
  }

  void _jumpToAccount() {
    if (!mounted) return;

    // This ensures the bottom nav highlight updates immediately
    setState(() => _index = 4);

    // And we refresh state so Account can reflect new plan quickly
    unawaited(_refreshEligibility(force: true));
  }

  bool get _showLockOverlay =>
      !_checkingEligibility && !_eligible && _index != 4;

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      TimelineTab(onNavigateToTab: _goTo), // 0
      const CalendarPage(),               // 1
      const SizedBox.shrink(),            // 2
      const AiChatTab(),                  // 3
      AccountTab(
    onUpgradeSuccess: () {
      // Option A: remain on Account tab -> just remove this block
      // Option B: go to Timeline after success:
      setState(() => _index = 0);
      // refresh eligibility if you want:
      unawaited(_refreshEligibility(force: true));
    },
  ),        // 4
    ];

    return Scaffold(
      body: Stack(
        children: [
          // Block interactions with the app when locked (except Account tab)
          IgnorePointer(
            ignoring: _showLockOverlay,
            child: IndexedStack(index: _index, children: pages),
          ),

          if (_checkingEligibility)
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: LinearProgressIndicator(minHeight: 2),
            ),

          if (_showLockOverlay)
            _AccessLockedOverlay(
              error: _eligibilityError,
              onUpgrade: _jumpToAccount,
              onRetry: () => _refreshEligibility(force: true),
            ),
        ],
      ),

      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) async {
          // When locked, allow only Account tab
          if (!_checkingEligibility && !_eligible && i != 4) {
            return;
          }
          await _goTo(i);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.timeline), label: 'Timeline'),
          NavigationDestination(icon: Icon(Icons.calendar_month), label: 'Calendar'),
          NavigationDestination(icon: Icon(Icons.mic), label: 'Record'),
          NavigationDestination(icon: Icon(Icons.smart_toy_outlined), label: 'AI Chat'),
          NavigationDestination(icon: Icon(Icons.person), label: 'Account'),
        ],
      ),
    );
  }
}

// ---------------- Overlay ----------------

class _AccessLockedOverlay extends StatelessWidget {
  const _AccessLockedOverlay({
    required this.onUpgrade,
    required this.onRetry,
    this.error,
  });

  final VoidCallback onUpgrade;
  final VoidCallback onRetry;
  final String? error;

  @override
  Widget build(BuildContext context) {
    // GestureDetector eats taps outside the card,
    // but DOES NOT block the buttons inside the card.
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {}, // swallow taps
        child: Container(
          color: Colors.black.withOpacity(0.50),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Card(
                  elevation: 0.8,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          height: 64,
                          width: 64,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1A1A22),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: const Color(0xFF8E7CFF).withOpacity(0.35),
                            ),
                          ),
                          child: const Icon(
                            Icons.lock_outline,
                            size: 30,
                            color: Color(0xFF8E7CFF),
                          ),
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          'Access locked',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Your trial has ended or your Pro plan is inactive.\nUpgrade to continue using the app.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70),
                        ),

                        if (error != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.redAccent,
                              fontSize: 11.5,
                            ),
                          ),
                        ],

                        const SizedBox(height: 14),

                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: onRetry,
                                child: const Text('Retry'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: onUpgrade,
                                icon: const Icon(Icons.workspace_premium_outlined),
                                label: const Text('Upgrade'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
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
