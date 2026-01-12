// lib/auth/app_gate.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../home_shell.dart';
import 'login_page.dart';
import 'eligibility_gate.dart';

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

  Future<void> _runEligibilityCheck() async {
    try {
      final res = await checkEligibilityOnce(_sb);
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
    setState(() => _checkingEligibility = true); // show splash-like loader
    final res = await checkEligibilityOnce(_sb);
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
    if (_session == null) {
      return const LoginPage();
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
  const _GateSplash({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
