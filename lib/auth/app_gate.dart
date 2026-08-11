// lib/auth/app_gate.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:transcript/widgets/brand_logo.dart';
import 'package:transcript/widgets/status_pill.dart';

import '../home_shell.dart';
import '../billing/subscription_service.dart'; // ✅ ADD
import 'login_page.dart';
import 'eligibility_gate.dart';

import '../ui/glass/glass_background.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_button.dart';
import '../ui/glass/glass_tokens.dart';

class AppGate extends StatefulWidget {
  const AppGate({super.key, required this.initialEligibility});

  final EligibilityGateResult initialEligibility;

  @override
  State<AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<AppGate> {
  late final SupabaseClient _sb;
  StreamSubscription<AuthState>? _sub;

  Session? _session;
  bool _ready = false;
  bool _devBypass = false;

  late EligibilityGateResult _eligibility;

  // When true -> show splash screen (eligibility checking)
  bool _checkingEligibility = false;

  @override
  void initState() {
    super.initState();
    _sb = Supabase.instance.client;

    _eligibility = widget.initialEligibility;

    _session = _sb.auth.currentSession;
    _ready = true;

    // ✅ If already logged in at app start, show splash then check eligibility
    if (_session != null) {
      _checkingEligibility = true;
      _runEligibilityCheck();
    }

    // ✅ React to login/logout
    _sub = _sb.auth.onAuthStateChange.listen((state) {
      if (!mounted) return;

      final newSession = state.session;

      setState(() {
        _session = newSession;
        _ready = true;

        // ✅ If logged in -> show splash until eligibility check finishes
        _checkingEligibility = newSession != null;
      });

      if (newSession != null) {
        _runEligibilityCheck();
      } else {
        // logged out
        setState(() {
          _eligibility = const EligibilityGateResult(eligible: false);
          _checkingEligibility = false;
        });
      }
    });
  }

  // ✅ One place that does "reconcile + check" with timeouts
  Future<EligibilityGateResult> _reconcileAndCheck() async {
    // Step A: try to reconcile purchases (important after purchase/restart)
    try {
      await SubscriptionService.I
          .reconcileNow(timeout: const Duration(seconds: 18))
          .timeout(const Duration(seconds: 5));
    } catch (_) {}

    // Step B: read eligibility (timed)
    try {
      return await checkEligibilityOnce(_sb).timeout(
        const Duration(seconds: 5),
        onTimeout: () => const EligibilityGateResult(eligible: false),
      );
    } catch (e) {
      return EligibilityGateResult(eligible: false, error: e.toString());
    }
  }

  Future<void> _runEligibilityCheck() async {
    try {
      final res = await _reconcileAndCheck();

      if (!mounted) return;
      setState(() {
        _eligibility = res;
        _checkingEligibility = false; // ✅ splash -> homeshell
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _eligibility = EligibilityGateResult(
          eligible: false,
          error: e.toString(),
        );
        _checkingEligibility = false;
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  // ✅ Used by HomeShell Retry button
  Future<EligibilityGateResult> _retryEligibility() async {
    if (!mounted) return const EligibilityGateResult(eligible: false);

    setState(() => _checkingEligibility = true); // show splash-like loader

    final res = await _reconcileAndCheck();

    if (!mounted) return res;
    setState(() {
      _eligibility = res;
      _checkingEligibility = false;
    });
    return res;
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const _GateSplash(status: 'Preparing…');
    }

    // ✅ Not logged in -> Login
    if (_session == null && !_devBypass) {
      return LoginPage(
        onLoggedIn: () {
          setState(() {
            _session = _sb.auth.currentSession;
          });
        },
        onBypass: () {
          setState(() {
            _devBypass = true;
            _eligibility = const EligibilityGateResult(eligible: true);
            _checkingEligibility = false;
          });
        },
      );
    }

    // ✅ Logged in -> Splash until eligibility done
    if (_checkingEligibility) {
      return const _GateSplash(status: 'Initializing…');
    }

    // ✅ Logged in + eligibility ready -> Home
    return HomeShell(
      initialEligible: _eligibility.eligible,
      eligibilityError: _eligibility.error,
      onRetryEligibility: _retryEligibility,
    );
  }
}

/// A lightweight splash UI used by AppGate (NOT your main SplashGate boot screen)
class _GateSplash extends StatelessWidget {
  const _GateSplash({required this.status, this.failed = false, this.onRetry});

  final String status;

  // ✅ Optional error mode
  final bool failed;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context, alpha: 0.78);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GlassBackground(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // ---- Brand header ----
                    BrandLogo(),

                    const SizedBox(height: 16),

                    Text(
                      'Starting up',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: fg,
                      ),
                    ),

                    const SizedBox(height: 8),

                    // ---- Status pill ----
                    StatusPill(text: status, isError: failed),

                    const SizedBox(height: 14),

                    // ---- Progress / error card ----
                    GlassCard(
                      variant: GlassCardVariant.panel,
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!failed) ...[
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                minHeight: 3,
                                backgroundColor: Colors.white.withValues(
                                  alpha: 0.10,
                                ),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  GlassTokens.fg(context, alpha: 0.92),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Setting things up…',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: muted,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ] else ...[
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(
                                  Icons.error_outline,
                                  color: Colors.redAccent,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'We couldn’t finish setup. Please try again.',
                                    style: TextStyle(
                                      color: GlassTokens.muted(
                                        context,
                                        alpha: 0.80,
                                      ),
                                      height: 1.2,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            GlassButton(
                              kind: GlassButtonKind.primary,
                              label: 'Retry',
                              icon: Icons.refresh,
                              onPressed: onRetry,
                              innerChrome: false,
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 18),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
