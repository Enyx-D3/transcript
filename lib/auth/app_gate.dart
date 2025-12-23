// lib/app_gate.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../home_shell.dart';
import 'login_page.dart';

class AppGate extends StatefulWidget {
  const AppGate({super.key});

  @override
  State<AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<AppGate> {
  late final SupabaseClient _sb;
  StreamSubscription<AuthState>? _sub;

  Session? _session;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _sb = Supabase.instance.client;

    // 1) Read current session immediately
    _session = _sb.auth.currentSession;
    _ready = true;

    // 2) Listen to changes
    _sub = _sb.auth.onAuthStateChange.listen((state) {
      if (!mounted) return;
      setState(() {
        _session = state.session;
        _ready = true;
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // Logged in -> Home
    if (_session != null) {
      return const HomeShell();
    }

    // Not logged in -> Login
    return const LoginPage();
  }
}
