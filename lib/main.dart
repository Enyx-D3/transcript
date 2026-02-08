
// lib/main.dart
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:transcript/send_transcript/auto_email_service.dart';
import 'package:transcript/send_transcript/send_transcript_healper.dart';
import 'package:transcript/transcript/audio_cleanup.dart';

import 'objectbox/objectbox_store.dart';
import 'record/recording_service.dart';

import 'transcript/background_transcriber.dart';
import 'transcript/transcription_models.dart';
import 'transcript/transcription_persistence.dart';

// App gate
import 'auth/app_gate.dart';
import 'auth/eligibility_gate.dart';
// If you still need the global Whisper for ModelPickerPage, keep this:
import 'whisper_service.dart';
import 'package:background_downloader/background_downloader.dart';

final whisper = WhisperService(); // UI-only: downloads & selection

final TranscriptMailService _mailer = TranscriptMailService(
  baseUrl: 'https://enyx.app',
  // authToken: 'optional', // if you use it
);

Future<void> _normalizeImportAudioPaths(int transcriptId, String wavPath) async {
  final obx = ObjectBox.I;

  final t = obx.transcripts.get(transcriptId);
  if (t == null) return;

  final st = t.sourceType; // expects 2=audio import, 3=video import
  if (st != 2 && st != 3) return;

  final a = (t.audioPath ?? '').trim();
  final p = (t.processedAudioPath ?? '').trim();

  // Already correct => do nothing
  if (p.isEmpty && a == wavPath.trim()) return;
  if (p.isEmpty && a.isNotEmpty && wavPath.trim().isEmpty) return;

  // Force import rule
  t.audioPath = wavPath.trim().isEmpty ? (a.isEmpty ? null : a) : wavPath.trim();
  t.processedAudioPath = null;

  // optional timestamp
  t.updatedAt = DateTime.now();

  obx.transcripts.put(t);

  debugPrint('[IMPORT-FIX] Applied for transcriptId=$transcriptId (sourceType=$st)');
}

Future<void> main() async {
    WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await FileDownloader().trackTasks();
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
    final type = data['type'];

    if (type == 'transcribe_result') {
      final wavPath = (data['wavPath'] as String?) ?? '';
      final existingId = data['existingId'] as int?;
      final payloadRaw = data['payload'];

      if (wavPath.trim().isEmpty || payloadRaw is! Map) return;

      final payload = Map<String, dynamic>.from(payloadRaw);
      final result = TranscriptionResult.fromJson(payload);

      int transcriptId;

      if (existingId != null) {
        await persistExistingTranscriptionFromResult(
          transcriptId: existingId,
          wavPath: wavPath,
          result: result,
        );
        transcriptId = existingId;

        // ✅ FIX IMPORTS HERE (no sourceType passing needed)
        await _normalizeImportAudioPaths(transcriptId, wavPath);

        await deleteTranscriptAudioIfUserEnabled(existingId);
      } else {
        final newId = await persistNewTranscriptionFromResult(
          wavPath: wavPath,
          result: result,
        );
        transcriptId = newId;

        // ✅ FIX IMPORTS HERE TOO (in case an import didn’t pre-create a row)
        await _normalizeImportAudioPaths(transcriptId, wavPath);

        await deleteTranscriptAudioIfUserEnabled(newId);
      }

      await AutoEmailService.sendIfEnabled(
        transcriptId: transcriptId,
        mailer: _mailer,
      );

      return;
    }

    if (type == 'transcribe_error') {
      debugPrint('BG transcription error: ${data['error']}');
      return;
    }
  } catch (e, st) {
    debugPrint('BG -> main persistence failed: $e');
    debugPrint('$st');
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

  Future<void> _recoverStaleTranscriptionLock() async {
    const kBusy = 'busy_transcribing';

    final busyFlag = (await FlutterForegroundTask.getData(key: kBusy)) == true;
    final running = await FlutterForegroundTask.isRunningService;

    if (busyFlag && !running) {
      await FlutterForegroundTask.saveData(key: kBusy, value: false);
    }
  }

  Future<void> _boot() async {
    try {
      setState(() {
        _failed = false;
        _status = 'Requesting microphone access…';
      });

      final perm = await Permission.microphone.request();
      if (!perm.isGranted) {
        throw Exception('Microphone permission is required');
      }

      final p = await FlutterForegroundTask.checkNotificationPermission();
      if (p != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }

      setState(() => _status = 'Initializing…');
      await _recoverStaleTranscriptionLock();

      setState(() => _status = 'Checking access…');
      final eligibility = await checkEligibilityOnce(Supabase.instance.client);

      await Future.delayed(const Duration(milliseconds: 120));

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => AppGate(initialEligibility: eligibility),
        ),
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
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {},
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // ---- Brand header ----
                    Container(
                      width: 86,
                      height: 86,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF12131A),
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.35),
                        ),
                        // boxShadow: [
                        //   BoxShadow(
                        //     blurRadius: 26,
                        //     offset: const Offset(0, 14),
                        //     color: const Color(0xFF8E7CFF).withOpacity(0.18),
                        //   ),
                        // ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Image.asset(
                          'assets/logo/transcript-transparent.png',
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Starting up',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),

                    // ---- Status pill ----
                    _StatusPill(text: _status, isError: _failed),

                    const SizedBox(height: 14),

                    // ---- Progress / error card ----
                    Card(
                      elevation: 0.6,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            if (!_failed) ...[
                              const LinearProgressIndicator(minHeight: 3,color: Colors.white,backgroundColor: Colors.black,),
                              const SizedBox(height: 12),
                              // Row(
                              //   children: const [
                              //     Icon(Icons.bolt, size: 18, color: Colors.white70),
                              //     SizedBox(width: 8),
                              //     Expanded(
                              //       child: Text(
                              //         'Please keep the app open.',
                              //         style: TextStyle(color: Colors.white70),
                              //       ),
                              //     ),
                              //   ],
                              // ),
                            ] else ...[
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: const [
                                  Icon(
                                    Icons.error_outline,
                                    color: Colors.redAccent,
                                  ),
                                  SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'We couldn’t finish setup. Please try again.',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        height: 1.2,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: () {
                                    setState(() {
                                      _failed = false;
                                      _status = 'Retrying…';
                                    });
                                    _boot();
                                  },
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Retry'),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 18),

                    // subtle footer
                    // Text(
                    //   'Tip: Allow microphone + notifications for best results.',
                    //   textAlign: TextAlign.center,
                    //   style: theme.textTheme.bodySmall?.copyWith(
                    //     color: Colors.white54,
                    //   ),
                    // ),
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

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.text, required this.isError});
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? Colors.redAccent : Colors.white;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isError
                ? Icons.warning_amber_rounded
                : Icons.hourglass_bottom_rounded,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, height: 1.15),
            ),
          ),
        ],
      ),
    );
  }
}

