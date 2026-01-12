// lib/home_shell.dart
import 'dart:async';
import 'package:flutter/material.dart';

import 'tabs/timeline_tab.dart';
import 'calendar/calendar_page.dart';
import 'record/record_sheet.dart';
import 'tabs/ai_chat_tab.dart';
import 'tabs/account_tab.dart';
import 'tabs/search_tab.dart';
// IMPORTANT: import the result type for callback return value
import 'auth/eligibility_gate.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.initialEligible,
    this.eligibilityError,
    required this.onRetryEligibility,
  });

  final bool initialEligible;
  final String? eligibilityError;

  /// ✅ Retry will call AppGate to re-check and return latest result
  final Future<EligibilityGateResult> Function() onRetryEligibility;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  late bool _eligible;
  String? _eligibilityError;

  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _eligible = widget.initialEligible;
    _eligibilityError = widget.eligibilityError;
  }

  // ---------------- Navigation ----------------

  Future<void> _openRecordSheet() async {
    if (!_eligible) return;
    await RecordSheet.show(context);
  }

  void _unfocus() => FocusManager.instance.primaryFocus?.unfocus();

  Future<void> _goTo(int i) async {
     _unfocus();
    if (i == 2) {
      await _openRecordSheet();
      return;
    }

    if (!mounted) return;
    setState(() => _index = i);
  }

  void _jumpToAccount() {
    if (!mounted) return;
    setState(() => _index = 4);
  }

  bool get _showLockOverlay => !_eligible && _index != 4;

  Future<void> _retryEligibility() async {
    if (_retrying) return;
    setState(() => _retrying = true);

    try {
      final res = await widget.onRetryEligibility();

      if (!mounted) return;
      setState(() {
        _eligible = res.eligible;
        _eligibilityError = res.error;
      });

      // If retry succeeds, you may want to auto-close overlay by going Timeline
      if (res.eligible) {
        setState(() => _index = 0);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _eligible = false;
        _eligibilityError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() => _retrying = false);
    }
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      TimelineTab(onNavigateToTab: _goTo), // 0
      const CalendarPage(),               // 1
      const SizedBox.shrink(),            // 2
      const SearchTab(),                  // 3
      AccountTab(
        onUpgradeSuccess: () async {
          // After upgrade, do a real retry check (not optimistic)
          await _retryEligibility();
          if (!mounted) return;
          if (_eligible) {
            setState(() => _index = 0);
          } else {
            setState(() => _index = 4);
          }
        },
      ), // 4
    ];

    return Scaffold(
      body: Stack(
        children: [
          IgnorePointer(
            ignoring: _showLockOverlay,
            child: IndexedStack(index: _index, children: pages),
          ),

          if (_showLockOverlay)
            _AccessLockedOverlay(
              error: _eligibilityError,
              retrying: _retrying,
              onUpgrade: _jumpToAccount,
              onRetry: _retryEligibility, // ✅ real retry
            ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) async {
          _unfocus();
          if (!_eligible && i != 4) return;
          await _goTo(i);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.timeline), label: 'Timeline'),
          NavigationDestination(icon: Icon(Icons.calendar_month), label: 'Calendar'),
          NavigationDestination(icon: Icon(Icons.mic), label: 'Record'),
          NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
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
    this.retrying = false,
  });

  final VoidCallback onUpgrade;
  final VoidCallback onRetry;
  final String? error;
  final bool retrying;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
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
                            "Internet is required to verify the access",
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
                                onPressed: retrying ? null : onRetry,
                                child: retrying
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Text('Retry'),
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
