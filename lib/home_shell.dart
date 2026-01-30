// lib/home_shell.dart
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';

import 'tabs/timeline_tab.dart';
import 'calendar/calendar_page.dart';
import 'record/record_sheet.dart';
import 'tabs/search_tab.dart';
import 'tabs/favourites_tab.dart';
import 'settings/settings_page.dart';
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

  final Future<EligibilityGateResult> Function() onRetryEligibility;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  /// 0 Timeline, 1 Calendar, 2 Record(action), 3 Search, 4 Favourites
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

    // Record is an ACTION (opens sheet) — do not switch tabs.
    if (i == 2) {
      await _openRecordSheet();
      return;
    }

    if (!mounted) return;
    setState(() => _index = i);
  }

  bool get _showLockOverlay => !_eligible;

  void _handleUpgradeSuccess() {
    // AccountTab/Settings expects a VoidCallback (sync).
    // Trigger the async refresh without awaiting.
    if (_retrying) return;
    // ignore: unawaited_futures
    _retryEligibility();
  }

  void _openSettingsToAccount() {
    if (!mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          openAccount: true, // ✅ Settings auto-opens Account page
          onUpgradeSuccess: _handleUpgradeSuccess, // ✅ flows to AccountTab
        ),
      ),
    );
  }

  Future<void> _retryEligibility() async {
    if (_retrying) return;
    setState(() => _retrying = true);

    try {
      // ✅ hard timeout so UI never freezes
      final res = await widget.onRetryEligibility().timeout(
        const Duration(seconds: 12),
        onTimeout: () => const EligibilityGateResult(eligible: false),
      );

      if (!mounted) return;
      setState(() {
        _eligible = res.eligible;
        _eligibilityError = res.error;
      });

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
      TimelineTab(
        onNavigateToTab: _goTo,
        onUpgradeSuccess:
            _handleUpgradeSuccess, // ✅ Timeline -> Settings -> Account
      ), // 0
      const CalendarPage(), // 1
      const SizedBox.shrink(), // 2 (never shown; record is action)
      const SearchTab(), // 3
      const FavouritesTab(), // 4
    ];

    return Scaffold(
      body: Stack(
        children: [
          IgnorePointer(
            ignoring: _showLockOverlay,
            child: _AnimatedIndexedStack(index: _index, children: pages),
          ),
          if (_showLockOverlay)
            _AccessLockedOverlaySheet(
              error: _eligibilityError,
              retrying: _retrying,
              onUpgrade:
                  _openSettingsToAccount, // ✅ Upgrade -> Settings -> Account
              onRetry: _retryEligibility,
            ),
        ],
      ),

      // ✅ Still a bottom nav, but styled as a dock
      bottomNavigationBar: IgnorePointer(
        ignoring: _showLockOverlay,
        child: _BottomDockNav(
          index: _index,
          eligible: _eligible,
          onSelect: (i) async {
            _unfocus();
            if (!_eligible) return;
            await _goTo(i);
          },
        ),
      ),
    );
  }
}

/// Keeps tab state but adds a subtle fade when switching.
class _AnimatedIndexedStack extends StatelessWidget {
  const _AnimatedIndexedStack({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, anim) =>
          FadeTransition(opacity: anim, child: child),
      child: _KeyedIndexedStack(
        key: ValueKey(index),
        index: index,
        children: children,
      ),
    );
  }
}

class _KeyedIndexedStack extends StatelessWidget {
  const _KeyedIndexedStack({
    super.key,
    required this.index,
    required this.children,
  });

  final int index;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return IndexedStack(index: index, children: children);
  }
}

class _BottomDockNav extends StatelessWidget {
  const _BottomDockNav({
    required this.index,
    required this.onSelect,
    required this.eligible,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final bool eligible;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg = isDark ? const Color(0xFF101018) : Colors.white;
    final border = isDark
        ? Colors.white.withOpacity(0.10)
        : Colors.black.withOpacity(0.08);

    // Record gets a distinctive “capsule” icon so the nav doesn’t look generic.
    Widget recordIcon(bool selected) {
      final base = selected
          ? (isDark ? Colors.white : Colors.black)
          : (isDark ? Colors.white70 : Colors.black54);

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: base.withOpacity(selected ? 0.10 : 0.06),
          border: Border.all(color: base.withOpacity(0.14)),
        ),
        child: Icon(Icons.mic, size: 22, color: base),
      );
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Container(
          decoration: BoxDecoration(
            color: bg.withOpacity(0.92),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: border),
            boxShadow: [
              BoxShadow(
                blurRadius: 20,
                spreadRadius: 0,
                color: Colors.black.withOpacity(isDark ? 0.35 : 0.12),
                offset: const Offset(0, 10),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: NavigationBarTheme(
            data: NavigationBarThemeData(
              height: 66,
              backgroundColor: Colors.transparent,
              elevation: 0,
              indicatorColor: (isDark ? Colors.white : Colors.black)
                  .withOpacity(0.08),
              indicatorShape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              labelTextStyle: MaterialStateProperty.resolveWith((states) {
                final selected = states.contains(MaterialState.selected);
                return TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected
                      ? (isDark ? Colors.white : Colors.black)
                      : (isDark ? Colors.white70 : Colors.black54),
                );
              }),
              iconTheme: MaterialStateProperty.resolveWith((states) {
                final selected = states.contains(MaterialState.selected);
                return IconThemeData(
                  size: 22,
                  color: selected
                      ? (isDark ? Colors.white : Colors.black)
                      : (isDark ? Colors.white70 : Colors.black54),
                );
              }),
            ),
            child: NavigationBar(
              selectedIndex: index,
              onDestinationSelected: onSelect,
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.timeline),
                  label: 'Timeline',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.calendar_month),
                  label: 'Calendar',
                ),

                // ✅ Record stays INSIDE the nav, but visually distinct
                NavigationDestination(
                  icon: recordIcon(false),
                  selectedIcon: recordIcon(true),
                  label: 'Record',
                ),

                const NavigationDestination(
                  icon: Icon(Icons.search),
                  label: 'Search',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.favorite_outline),
                  label: 'Favourites',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------- Overlay (Bottom Sheet style) ----------------

class _AccessLockedOverlaySheet extends StatelessWidget {
  const _AccessLockedOverlaySheet({
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final panelBg = isDark ? const Color(0xFF141422) : const Color(0xFFF7F7FB);
    final panelBorder = isDark
        ? Colors.white.withOpacity(0.10)
        : Colors.black.withOpacity(0.08);

    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: Stack(
          children: [
            // ✅ dim + blur background
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withOpacity(0.35),
                      Colors.black.withOpacity(0.60),
                    ],
                  ),
                ),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                  child: const SizedBox.expand(),
                ),
              ),
            ),

            // ✅ CENTERED panel (middle of screen)
            Center(
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Container(
                      decoration: BoxDecoration(
                        color: panelBg,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: panelBorder),
                        boxShadow: [
                          BoxShadow(
                            blurRadius: 30,
                            color: Colors.black.withOpacity(0.25),
                            offset: const Offset(0, 18),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // ✅ removed "drag handle" since this is not a bottom sheet
                          Row(
                            children: [
                              Container(
                                height: 44,
                                width: 44,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(14),
                                  color: (isDark ? Colors.white : Colors.black)
                                      .withOpacity(0.06),
                                  border: Border.all(
                                    color:
                                        (isDark ? Colors.white : Colors.black)
                                            .withOpacity(0.10),
                                  ),
                                ),
                                child: Icon(
                                  Icons.lock_outline,
                                  color: isDark ? Colors.white : Colors.black87,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Access locked',
                                      style: TextStyle(
                                        fontSize: 16.5,
                                        fontWeight: FontWeight.w800,
                                        color: isDark
                                            ? Colors.white
                                            : Colors.black87,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Trial ended or Pro inactive',
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600,
                                        color: isDark
                                            ? Colors.white70
                                            : Colors.black54,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 10),

                          Text(
                            'Upgrade to continue using the app.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: isDark ? Colors.white70 : Colors.black54,
                              fontWeight: FontWeight.w600,
                            ),
                          ),

                          if (error != null && error!.trim().isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.red.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: Colors.red.withOpacity(0.20),
                                ),
                              ),
                              child: Text(
                                'Internet is required to verify access.\nDetails: $error',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],

                          const SizedBox(height: 12),

                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: retrying ? null : onRetry,
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  child: retrying
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Text('Retry'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: onUpgrade,
                                  style: FilledButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.workspace_premium_outlined,
                                  ),
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
          ],
        ),
      ),
    );
  }
}

