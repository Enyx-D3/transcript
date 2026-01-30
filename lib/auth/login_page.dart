// lib/auth/login_page.dart
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.onLoggedIn});

  final VoidCallback? onLoggedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _busy = false;
  String? _error;

  // Email/password controllers
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _pwObscured = true;

  SupabaseClient get _sb => Supabase.instance.client;

  /// IMPORTANT:
  /// This must be the **Web application** OAuth client ID (server client ID).
  static const String _serverClientId =
      '909295591544-bd2add2ghl48rcdpr789rhkc6h2d5j33.apps.googleusercontent.com';

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _ensureProfile(User user) async {
    final now = DateTime.now().toUtc();

    await _sb.from('profiles').upsert({
      'id': user.id,
      'email': user.email,
      'date_joined': now.toIso8601String(),
      'is_upgraded': false,
      'trial_expires_at': now.add(const Duration(days: 1)).toIso8601String(),
    });
  }

  Future<void> _signInWithGoogle() async {
    if (_busy) return;

    if (!Platform.isAndroid) {
      setState(
        () => _error = 'This login flow is configured for Android only.',
      );
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final GoogleSignIn signIn = GoogleSignIn.instance;

      await signIn.initialize(
        serverClientId: _serverClientId, // Web OAuth client ID
      );

      final googleAccount = await signIn.authenticate();
      final googleAuthentication = googleAccount.authentication;
      final idToken = googleAuthentication.idToken;

      if (idToken == null) {
        throw Exception('No ID Token found. Check your serverClientId.');
      }

      final res = await _sb.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
      );

      final user = res.user;
      if (user == null) {
        throw Exception('Supabase sign-in failed (no user returned).');
      }

      await _ensureProfile(user);

      if (!mounted) return;
      setState(() => _busy = false);
      widget.onLoggedIn?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Login Failed';
      });
    }
  }

  Future<void> _signInWithEmailPassword() async {
    if (_busy) return;

    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter email and password.');
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final res = await _sb.auth.signInWithPassword(
        email: email,
        password: password,
      );

      final user = res.user;
      if (user == null) {
        throw Exception('Login failed (no user returned).');
      }

      await _ensureProfile(user);

      if (!mounted) return;
      setState(() => _busy = false);
      widget.onLoggedIn?.call();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Login Failed, Provide valid credentials';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => FocusScope.of(context).unfocus(),
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                // lets the content move above the keyboard
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Align(
                              alignment: Alignment.center,
                              child: Container(
                                height: 84,
                                width: 84,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1A1A22),
                                  borderRadius: BorderRadius.circular(22),
                                  border: Border.all(
                                    color: Colors.white
                                  ),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(18),
                                  child: Image.asset(
                                    'assets/logo/transcript-transparent.png',
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 22),
                            Text(
                              'Welcome back',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            // const Text(
                            //   'Sign in to sync your transcripts and unlock AI features.',
                            //   textAlign: TextAlign.center,
                            //   style: TextStyle(color: Colors.white70),
                            // ),
                            const SizedBox(height: 24),

                            Card(
                              elevation: 0.6,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    // GOOGLE
                                    FilledButton.icon(
                                      onPressed: _busy
                                          ? null
                                          : _signInWithGoogle,
                                      icon: _busy
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              color: Colors.black,
                                              ),
                                            )
                                          : const Icon(Icons.g_mobiledata),
                                      label: Text(
                                        _busy
                                            ? 'Signing in…'
                                            : 'Continue with Google',
                                            style: TextStyle(color: Colors.black),
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        backgroundColor: Colors.white
                                      ),
                                    ),

                                    // const SizedBox(height: 16),
                                    // const Divider(),
                                    // const SizedBox(height: 12),

                                    // // EMAIL/PASSWORD
                                    // TextField(
                                    //   controller: _emailCtrl,
                                    //   keyboardType: TextInputType.emailAddress,
                                    //   textInputAction: TextInputAction.next,
                                    //   autofillHints: const [
                                    //     AutofillHints.username,
                                    //     AutofillHints.email,
                                    //   ],
                                    //   decoration: const InputDecoration(
                                    //     labelText: 'Email',
                                    //     border: OutlineInputBorder(),
                                    //   ),
                                    // ),
                                    // const SizedBox(height: 10),
                                    // TextField(
                                    //   controller: _passwordCtrl,
                                    //   obscureText: _pwObscured,
                                    //   textInputAction: TextInputAction.done,
                                    //   onSubmitted: (_) => _busy
                                    //       ? null
                                    //       : _signInWithEmailPassword(),
                                    //   autofillHints: const [
                                    //     AutofillHints.password,
                                    //   ],
                                    //   decoration: InputDecoration(
                                    //     labelText: 'Password',
                                    //     border: const OutlineInputBorder(),
                                    //     suffixIcon: IconButton(
                                    //       onPressed: _busy
                                    //           ? null
                                    //           : () => setState(
                                    //               () => _pwObscured =
                                    //                   !_pwObscured,
                                    //             ),
                                    //       icon: Icon(
                                    //         _pwObscured
                                    //             ? Icons.visibility
                                    //             : Icons.visibility_off,
                                    //       ),
                                    //     ),
                                    //   ),
                                    // ),
                                    // const SizedBox(height: 10),
                                    // FilledButton(
                                    //   onPressed: _busy
                                    //       ? null
                                    //       : _signInWithEmailPassword,
                                    //   child: Text(
                                    //     _busy
                                    //         ? 'Signing in…'
                                    //         : 'Continue with Email',
                                    //   ),
                                    // ),

                                    const SizedBox(height: 10),
                                    RichText(
                                      textAlign: TextAlign.center,
                                      text: TextSpan(
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Colors.white54,
                                        ),
                                        children: [
                                          const TextSpan(
                                            text:
                                                'By continuing you agree to our ',
                                          ),
                                          TextSpan(
                                            text: 'Terms and Privacy Policy',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              decoration:
                                                  TextDecoration.underline,
                                            ),
                                            recognizer: TapGestureRecognizer()
                                              ..onTap = () async {
                                                final uri = Uri.parse(
                                                  'https://enyx.app/privacy/enyx-transcriptor',
                                                );

                                                final ok = await launchUrl(
                                                  uri,
                                                  mode: LaunchMode
                                                      .externalApplication,
                                                );

                                                if (!ok) {
                                                  debugPrint(
                                                    'Could not launch: $uri',
                                                  );
                                                }
                                              },
                                          ),
                                          const TextSpan(text: '.'),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            if (_error != null) ...[
                              const SizedBox(height: 14),
                              Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.redAccent),
                              ),
                            ],

                            const SizedBox(height: 20),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
