// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'objectbox/objectbox_store.dart';
import 'record/recording_service.dart';

import 'transcript/background_transcriber.dart';
import 'transcript/transcription_models.dart';
import 'transcript/transcription_persistence.dart';

// App gate
import 'auth/app_gate.dart';

// If you still need the global Whisper for ModelPickerPage, keep this:
import 'whisper_service.dart';

final whisper = WhisperService(); // UI-only: downloads & selection

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1) Supabase init ONCE here
  await Supabase.initialize(
    url: 'https://ncpxlqykawquordwnxmw.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5jcHhscXlrYXdxdW9yZHdueG13Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjQxNzQwMjAsImV4cCI6MjA3OTc1MDAyMH0.eDYqntQBhp_AxfhFw1PdR6gIFp50zDKzhqYKUzSs0EU',
  );

  // 2) ObjectBox store: main isolate only
  await ObjectBox.init();

  // 3) Recorder
  await RecordingService.ensureInitialized();

  // 4) Foreground task (background isolate)
  await BackgroundTranscriber.init();
  FlutterForegroundTask.initCommunicationPort();
  // // 5) BG -> main persistence hook (register once)
  BackgroundTranscriber.onData((data) async {
    if (data is! Map) return;

    try {
      if (data['type'] == 'transcribe_result') {
        final wavPath = data['wavPath'] as String;
        final existingId = data['existingId'] as int?;
        final payload = Map<String, dynamic>.from(data['payload'] as Map);

        final result = TranscriptionResult.fromJson(payload);

        if (existingId != null) {
          await persistExistingTranscriptionFromResult(
            transcriptId: existingId,
            wavPath: wavPath,
            result: result,
          );
        } else {
          await persistNewTranscriptionFromResult(
            wavPath: wavPath,
            result: result,
          );
        }
      } else if (data['type'] == 'transcribe_error') {
        debugPrint('BG transcription error: ${data['error']}');
      }
    } catch (e) {
      debugPrint('BG -> main persistence failed: $e');
    }
  });

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

      final p = await FlutterForegroundTask.checkNotificationPermission();
      if (p != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }

      await Future.delayed(const Duration(milliseconds: 120));

      if (!mounted) return;
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const AppGate()));
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
    return PopScope(
      canPop: false,
      onPopInvoked: (_) {},
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
                    child: const Icon(
                      Icons.mic_rounded,
                      size: 36,
                      color: Color(0xFF8E7CFF),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Starting up…',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
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
