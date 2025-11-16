// lib/main.dart
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:whisper_flutter_new/whisper_flutter_new.dart' show WhisperModel;
import 'package:sherpa_onnx/sherpa_onnx.dart' show initBindings;

import 'whisper_service.dart';
import 'diarizer_service.dart';
import 'transcribe_page.dart';

// First-run voice enrollment flow
import 'onboarding/enroll_flow.dart';
import 'speaker_memory.dart';

/// Globals used across the app
final whisper = WhisperService();
final diarizer = DiarizerService();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Transcript',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0B0F),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF8E7CFF),
          secondary: Color(0xFF8E7CFF),
        ),
        cardColor: const Color(0xFF13131A),
      ),
      home: const SplashGate(),
    );
  }
}

class SplashGate extends StatefulWidget {
  const SplashGate({super.key});
  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  String _status = 'Preparing…';
  bool _failed = false;
  String _errorText = '';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      setState(() {
        _failed = false;
        _status = 'Requesting microphone access…';
      });

      final mic = await Permission.microphone.request();
      if (!mic.isGranted) {
        throw Exception('Microphone permission is required');
      }

      // Optional: storage permission is NOT required for app-dir usage.
      await Future.delayed(const Duration(milliseconds: 100));

      // Initialize FFI for sherpa_onnx (safe to call multiple times)
      initBindings();

      setState(() => _status = 'Loading speech model…');
      await whisper.init(model: WhisperModel.tiny); // tiny is fast for boot

      setState(() => _status = 'Preparing diarization models…');
      // This will download segmentation & embedding (if missing) and init the engine.
      await diarizer.init(expectedNumSpeakers: 0);

      await _routeNext();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _errorText = e.toString();
        _status = 'Failed to initialize.';
      });
    }
  }

  Future<void> _routeNext() async {
    if (!mounted) return;

    // Check if we already have any enrolled voice profiles
    final memory = await SpeakerMemory.instance();
    final hasProfiles = memory.profiles.isNotEmpty;

    final next = hasProfiles
        ? const TranscribePage()
        : const EnrollmentFlowPage(); // first-run voice setup

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => next),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async => false, // block back during boot
      child: Scaffold(
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
                    child: const Icon(Icons.mic_rounded, size: 36, color: Color(0xFF8E7CFF)),
                  ),
                  const SizedBox(height: 20),
                  const Text('Speech to Text', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(
                    _failed ? _status : _status,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  if (_failed) ...[
                    const SizedBox(height: 8),
                    Text(
                      _errorText,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (!_failed) const LinearProgressIndicator(minHeight: 3),
                  if (_failed) ...[
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FilledButton(
                          onPressed: _boot,
                          child: const Text('Retry'),
                        ),
                        const SizedBox(width: 12),
                        // Fallback: continue without diarization if whisper is ready
                        OutlinedButton(
                          onPressed: () async {
                            // If whisper init already succeeded, go on; otherwise retry boot.
                            try {
                              if (!whisper.isReady) {
                                setState(() => _status = 'Loading speech model…');
                                await whisper.init(model: WhisperModel.tiny);
                              }
                              await _routeNext();
                            } catch (_) {
                              // stay on splash if even whisper fails
                            }
                          },
                          child: const Text('Continue anyway'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
