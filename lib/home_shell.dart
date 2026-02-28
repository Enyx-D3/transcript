// lib/home_shell.dart
import 'dart:async';
import 'package:flutter/material.dart';

import 'tabs/timeline_tab.dart';
import 'calendar/calendar_page.dart';
import 'record/record_sheet.dart';
import 'tabs/search_tab.dart';
import 'tabs/favourites_tab.dart';
import 'settings/settings_page.dart';
import 'auth/eligibility_gate.dart';

// ✅ glass primitives
import 'ui/glass/glass_dock.dart';
import 'ui/glass/glass_modal.dart';
import 'ui/glass/glass_button.dart';
import 'ui/glass/liquid_glass.dart';
import 'ui/glass/glass_tokens.dart';

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
    if (_retrying) return;
    // ignore: unawaited_futures
    _retryEligibility();
  }

  void _openSettingsToAccount() {
    if (!mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          openAccount: true,
          onUpgradeSuccess: _handleUpgradeSuccess,
        ),
      ),
    );
  }

  Future<void> _retryEligibility() async {
    if (_retrying) return;
    setState(() => _retrying = true);

    try {
      final res = await widget.onRetryEligibility().timeout(
        const Duration(seconds: 12),
        onTimeout: () => const EligibilityGateResult(eligible: false),
      );

      if (!mounted) return;
      setState(() {
        _eligible = res.eligible;
        _eligibilityError = res.error;
      });

      if (res.eligible) setState(() => _index = 0);
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

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      TimelineTab(
        onNavigateToTab: _goTo,
        onUpgradeSuccess: _handleUpgradeSuccess,
      ),
      const CalendarPage(),
      const SizedBox.shrink(),
      const SearchTab(),
      const FavouritesTab(),
    ];

    return Scaffold(
      backgroundColor: Colors.transparent, // ✅ let wallpaper show
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
              onUpgrade: _openSettingsToAccount,
              onRetry: _retryEligibility,
            ),
        ],
      ),
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
    final isDark = GlassTokens.isDark(context);

    Color iconColor(Set<WidgetState > states) {
      final selected = states.contains(WidgetState.selected);
      if (selected) return Colors.white.withValues(alpha: 0.96);
      return Colors.white.withValues(alpha: 0.70);
    }

    TextStyle labelStyle(Set<WidgetState > states) {
      final selected = states.contains(WidgetState.selected);
      return TextStyle(
        fontSize: 12,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w600, // ✅ Apple-ish
        letterSpacing: 0.1,
        color: selected
            ? Colors.white.withValues(alpha: 0.92)
            : Colors.white.withValues(alpha: 0.68),
      );
    }

    Widget recordIcon(bool selected) {
      final fg = selected
          ? Colors.white.withValues(alpha: 0.95)
          : Colors.white.withValues(alpha: 0.72);

      return LiquidGlass(
        borderRadius: BorderRadius.circular(999),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        blurX: isDark ? 16 : 12,
        blurY: isDark ? 16 : 12,
        shadow: false,
        tintOpacityDark: selected ? 0.070 : 0.045,
        tintOpacityLight: selected ? 0.055 : 0.035,
        borderOpacityDark: selected ? 0.18 : 0.14,
        borderOpacityLight: selected ? 0.22 : 0.18,
        child: Icon(Icons.mic, size: 22, color: fg),
      );
    }

    return GlassDock(
      // Dock tuning already “Apple”; keep it.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: NavigationBarTheme(
          data: NavigationBarThemeData(
            height: 66,
            backgroundColor: Colors.transparent,
            elevation: 0,
            indicatorColor: Colors.white.withValues(alpha: 0.08),
            indicatorShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            labelTextStyle: WidgetStateProperty.resolveWith(labelStyle),
            iconTheme: WidgetStateProperty .resolveWith(
              (states) => IconThemeData(size: 22, color: iconColor(states)),
            ),
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
    );
  }
}

// ---------------- Overlay (Glass Modal) ----------------

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
    final isDark = GlassTokens.isDark(context);
    final titleColor = Colors.white.withValues(alpha: 0.92);
    final subColor = Colors.white.withValues(alpha: 0.70);

    return Stack(
      children: [
        // ✅ Proper glass barrier (blur + dim)
        GlassModalBarrier(onTap: null),

        // ✅ Glass panel
        GlassModal(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  LiquidGlass(
                    borderRadius: BorderRadius.circular(14),
                    padding: const EdgeInsets.all(10),
                    blurX: isDark ? 16 : 12,
                    blurY: isDark ? 16 : 12,
                    shadow: false,
                    tintOpacityDark: 0.055,
                    tintOpacityLight: 0.040,
                    borderOpacityDark: 0.14,
                    borderOpacityLight: 0.18,
                    child: Icon(Icons.lock_outline,
                        color: Colors.white.withValues(alpha: 0.92)),
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
                            fontWeight: FontWeight.w700, // ✅ less heavy
                            color: titleColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Trial ended or Pro inactive',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: subColor,
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
                  color: subColor,
                  fontWeight: FontWeight.w600,
                ),
              ),

              if (error != null && error!.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                LiquidGlass(
                  borderRadius: BorderRadius.circular(14),
                  padding: const EdgeInsets.all(10),
                  blurX: isDark ? 16 : 12,
                  blurY: isDark ? 16 : 12,
                  shadow: false,
                  tintOpacityDark: 0.040,
                  tintOpacityLight: 0.035,
                  borderOpacityDark: 0.14,
                  borderOpacityLight: 0.18,
                  child: Text(
                    'Internet is required to verify access.\nDetails: $error',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.82),
                      height: 1.25,
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: GlassButton(
                      label: retrying ? 'Checking…' : 'Retry',
                      kind: GlassButtonKind.secondary,
                      onPressed: retrying ? null : onRetry,
                      loading: retrying,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GlassButton(
                      label: 'Upgrade',
                      kind: GlassButtonKind.primary,
                      icon: Icons.workspace_premium_outlined,
                      onPressed: onUpgrade,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
