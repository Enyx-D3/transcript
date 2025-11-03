// lib/main.dart
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:whisper_flutter_new/whisper_flutter_new.dart' show WhisperModel;
import 'transcribe_page.dart';
import 'whisper_service.dart';
import 'diarizer_service.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' show initBindings; // optional here; we also call inside service

final whisper = WhisperService();
final diarizer = DiarizerService(); // 👈 export this symbol

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
      title: 'Whisper Demo',
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

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      setState(() => _status = 'Requesting microphone access…');
      final perm = await Permission.microphone.request();
      if (!perm.isGranted) {
        throw Exception('Microphone permission is required');
      }

      await Future.delayed(const Duration(milliseconds: 100));

      setState(() => _status = 'Loading speech model…');
      await whisper.init(model: WhisperModel.tiny);

      setState(() => _status = 'Preparing diarization models…');
      // This downloads + initializes Sherpa-ONNX
      await diarizer.init(expectedNumSpeakers: 0);

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const TranscribePage()),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _status = 'Failed to initialize: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async => false,
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
                  Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: 20),
                  if (!_failed) const LinearProgressIndicator(minHeight: 3),
                  if (_failed) ...[
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () {
                        setState(() {
                          _failed = false;
                          _status = 'Retrying…';
                        });
                        _boot();
                      },
                      child: const Text('Retry'),
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
