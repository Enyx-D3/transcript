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
    this.devBypassPremium = false,
  });

  final bool initialEligible;
  final String? eligibilityError;
  final Future<EligibilityGateResult> Function() onRetryEligibility;
  final bool devBypassPremium;

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
          devBypassPremium: widget.devBypassPremium,
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
        devBypassPremium: widget.devBypassPremium,
      ),
      const CalendarPage(),
      const SizedBox.shrink(),
      const SearchTab(),
      const FavouritesTab(),
    ];

    return Scaffold(
      backgroundColor: GlassTokens.backgroundColor(context),
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

/// Keeps tab state and adds a smooth directional slide + fade transition when switching.
class _AnimatedIndexedStack extends StatefulWidget {
  const _AnimatedIndexedStack({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<_AnimatedIndexedStack> createState() => _AnimatedIndexedStackState();
}

class _AnimatedIndexedStackState extends State<_AnimatedIndexedStack>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  int _prevIndex = 0;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.index;
    _prevIndex = widget.index;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _controller.value = 1.0;
  }

  @override
  void didUpdateWidget(_AnimatedIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != oldWidget.index) {
      setState(() {
        _prevIndex = oldWidget.index;
        _currentIndex = widget.index;
      });
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isForward = _currentIndex >= _prevIndex;

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        final animVal = _animation.value;
        final isAnimating = animVal < 1.0;

        return Stack(
          fit: StackFit.expand,
          children: widget.children.asMap().entries.map((entry) {
            final idx = entry.key;
            final child = entry.value;

            final isCurrent = idx == _currentIndex;
            final isPrev = idx == _prevIndex && isAnimating;
            final isVisible = isCurrent || isPrev;

            if (!isVisible) {
              return Offstage(
                offstage: true,
                child: TickerMode(enabled: false, child: child),
              );
            }

            if (isCurrent && isAnimating) {
              final double slideX =
                  (1.0 - animVal) * (isForward ? 20.0 : -20.0);
              return Transform.translate(
                offset: Offset(slideX, 0),
                child: Opacity(opacity: animVal.clamp(0.0, 1.0), child: child),
              );
            }

            if (isPrev) {
              final double slideX = animVal * (isForward ? -20.0 : 20.0);
              return Transform.translate(
                offset: Offset(slideX, 0),
                child: Opacity(
                  opacity: (1.0 - animVal).clamp(0.0, 1.0),
                  child: TickerMode(enabled: false, child: child),
                ),
              );
            }

            return child;
          }).toList(),
        );
      },
    );
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
    final primaryColor = GlassTokens.primary(context);
    final isDark = GlassTokens.isDark(context);
    final inactiveColor = isDark
        ? const Color(0xFFA0A0AB)
        : const Color(0xFF6B6B78);
    final bg = isDark ? const Color(0xFF14141A) : const Color(0xFFFFFFFF);
    final border = isDark ? const Color(0xFF282832) : const Color(0xFFE8E8EE);
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Container(
      color: bg,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset > 0 ? bottomInset : 16),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.topCenter,
          children: [
            // Main Navigation Bar Container
            Container(
              height: 76,
              decoration: BoxDecoration(
                color: bg,
                border: Border(top: BorderSide(color: border, width: 1)),
                // Removed the glow/shadow as requested
              ),
              child: Row(
                children: [
                  // 1. Timeline
                  Expanded(
                    child: _NavItem(
                      icon: Icons.graphic_eq_rounded,
                      label: 'Timeline',
                      isSelected: index == 0,
                      activeColor: primaryColor,
                      inactiveColor: inactiveColor,
                      onTap: () => onSelect(0),
                    ),
                  ),

                  // 2. Calendar
                  Expanded(
                    child: _NavItem(
                      icon: index == 1
                          ? Icons.calendar_month_rounded
                          : Icons.calendar_month_outlined,
                      label: 'Calendar',
                      isSelected: index == 1,
                      activeColor: primaryColor,
                      inactiveColor: inactiveColor,
                      onTap: () => onSelect(1),
                    ),
                  ),

                  // 3. Center gap for the protruding floating mic button
                  const SizedBox(width: 68),

                  // 4. Search
                  Expanded(
                    child: _NavItem(
                      icon: Icons.search_rounded,
                      label: 'Search',
                      isSelected: index == 3,
                      activeColor: primaryColor,
                      inactiveColor: inactiveColor,
                      onTap: () => onSelect(3),
                    ),
                  ),

                  // 5. Favorites
                  Expanded(
                    child: _NavItem(
                      icon: index == 4
                          ? Icons.favorite_rounded
                          : Icons.favorite_outline_rounded,
                      label: 'Favorites',
                      isSelected: index == 4,
                      activeColor: primaryColor,
                      inactiveColor: inactiveColor,
                      onTap: () => onSelect(4),
                    ),
                  ),
                ],
              ),
            ),

            // Floating Center Mic Button (Slightly lowered, clean with no glow)
            Positioned(
              top: 0,
              child: _FloatingMicButton(onTap: () => onSelect(2)),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.activeColor,
    required this.inactiveColor,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final Color activeColor;
  final Color inactiveColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? activeColor : inactiveColor;

    return InkWell(
      onTap: onTap,
      splashColor: activeColor.withValues(alpha: 0.08),
      highlightColor: Colors.transparent,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 24, color: color),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                color: color,
                letterSpacing: -0.15,
                height: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FloatingMicButton extends StatefulWidget {
  const _FloatingMicButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_FloatingMicButton> createState() => _FloatingMicButtonState();
}

class _FloatingMicButtonState extends State<_FloatingMicButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _pressed ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: GlassTokens.primary(context),
          ),
          child: const Center(
            child: Icon(Icons.mic_none_rounded, size: 28, color: Colors.white),
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
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    return Stack(
      children: [
        const GlassModalBarrier(onTap: null),
        GlassModal(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  LiquidGlass(
                    borderRadius: BorderRadius.circular(14),
                    padding: const EdgeInsets.all(10),
                    shadow: false,
                    child: Icon(Icons.lock_outline, color: fg),
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
                            fontWeight: FontWeight.w700,
                            color: fg,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Trial ended or Pro inactive',
                          style: TextStyle(
                            fontSize: 12,
                            color: muted,
                            fontWeight: FontWeight.w600,
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
                style: TextStyle(color: muted, fontWeight: FontWeight.w600),
              ),

              if (error != null && error!.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                LiquidGlass(
                  borderRadius: BorderRadius.circular(14),
                  padding: const EdgeInsets.all(10),
                  shadow: false,
                  backgroundColor: isDark
                      ? GlassTokens.surfaceDark
                      : GlassTokens.surfaceLight,
                  child: Text(
                    error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),

              GlassButton(
                label: 'View Plans',
                icon: Icons.workspace_premium_outlined,
                onPressed: onUpgrade,
              ),

              const SizedBox(height: 8),

              GlassButton(
                label: retrying ? 'Checking…' : 'Retry',
                icon: Icons.refresh,
                kind: GlassButtonKind.secondary,
                loading: retrying,
                onPressed: retrying ? null : onRetry,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
