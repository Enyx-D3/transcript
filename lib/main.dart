import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;
import 'package:path/path.dart' as p;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:transcript/send_transcript/auto_email_service.dart';
import 'package:transcript/send_transcript/send_transcript_healper.dart';
import 'package:transcript/transcript/audio_cleanup.dart';
import 'package:transcript/ui/glass/glass_background.dart';
import 'package:transcript/widgets/brand_logo.dart';
import 'package:transcript/widgets/status_pill.dart';

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


import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_button.dart';
import '../ui/glass/glass_tokens.dart';


final whisper = WhisperService(); // UI-only: downloads & selection

final TranscriptMailService _mailer = TranscriptMailService(
  baseUrl: 'https://enyx.app',
  // authToken: 'optional', // if you use it
);

// Future<void> _normalizeImportAudioPaths(int transcriptId, String wavPath) async {
//   final obx = ObjectBox.I;

//   final t = obx.transcripts.get(transcriptId);
//   if (t == null) return;

//   final st = t.sourceType; // expects 2=audio import, 3=video import
//   if (st != 2 && st != 3) return;

//   final a = (t.audioPath ?? '').trim();
//   final p = (t.processedAudioPath ?? '').trim();

//   // Already correct => do nothing
//   if (p.isEmpty && a == wavPath.trim()) return;
//   if (p.isEmpty && a.isNotEmpty && wavPath.trim().isEmpty) return;

//   // Force import rule
//   t.audioPath = wavPath.trim().isEmpty ? (a.isEmpty ? null : a) : wavPath.trim();
//   t.processedAudioPath = null;

//   // optional timestamp
//   t.updatedAt = DateTime.now();

//   obx.transcripts.put(t);

//   debugPrint('[IMPORT-FIX] Applied for transcriptId=$transcriptId (sourceType=$st)');
// }

Future<void> _finalizeTranscriptAfterProcessing({
  required int transcriptId,
  required String audioPath,
}) async {
  final obx = ObjectBox.I;
  final t = obx.transcripts.get(transcriptId);
  if (t == null) return;

  final st = t.sourceType;

  // ------------------------------------------------------------
  // sourceType == 1: recorded => title from first 5 words
  // ------------------------------------------------------------
  if (st == 1) {
    final currentTitle = (t.title ?? '').trim();
    if (currentTitle.isEmpty) {
      final full = (t.fullTextCache ?? '').trim();
      if (full.isNotEmpty) {
        final words = full
            .replaceAll(RegExp(r'\s+'), ' ')
            .split(' ')
            .where((w) => w.trim().isNotEmpty)
            .toList();

        if (words.isNotEmpty) {
          final title = words.take(5).join(' ').trim();
          if (title.isNotEmpty) {
            t.title = title;
            obx.transcripts.put(t);
            debugPrint('[FINALIZE] sourceType=1 title="$title"');
          }
        }
      }
    }
    return; // nothing else to do for recordings
  }

  // ------------------------------------------------------------
  // sourceType == 2/3: imports => title from filename + delete audio
  // ------------------------------------------------------------
  if (st != 2 && st != 3) return;

  final trimmedPath = audioPath.trim();
  if (trimmedPath.isEmpty) return;

  // 1) Title = file name (without extension)
  try {
    final filename = p.basename(trimmedPath); // e.g. meeting.wav
    final nameWithoutExt = p.basenameWithoutExtension(filename); // meeting
    if (nameWithoutExt.trim().isNotEmpty) {
      t.title = nameWithoutExt.trim();
    }
  } catch (e) {
    debugPrint('[FINALIZE] Failed extracting filename: $e');
  }

  // 2) Delete audio file
  try {
    final file = File(trimmedPath);
    if (await file.exists()) {
      await file.delete();
      debugPrint('[FINALIZE] Deleted file: $trimmedPath');
    }
  } catch (e) {
    debugPrint('[FINALIZE] Failed deleting file: $e');
  }

  // 3) Null both audio paths
  t.audioPath = null;
  t.processedAudioPath = null;

  obx.transcripts.put(t);

  debugPrint('[FINALIZE] Applied transcriptId=$transcriptId sourceType=$st');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  await Supabase.initialize(
    url: 'https://ncpxlqykawquordwnxmw.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5jcHhscXlrYXdxdW9yZHdueG13Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjQxNzQwMjAsImV4cCI6MjA3OTc1MDAyMH0.eDYqntQBhp_AxfhFw1PdR6gIFp50zDKzhqYKUzSs0EU',
  );

  await ObjectBox.init();
  await RecordingService.ensureInitialized();

  runApp(const MyApp());

  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      // ✅ 1) init comm port FIRST
      FlutterForegroundTask.initCommunicationPort();

      // ✅ 2) register onData AFTER port init
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
              // await _normalizeImportAudioPaths(transcriptId, wavPath);
              await _finalizeTranscriptAfterProcessing(transcriptId:  transcriptId,audioPath: wavPath);
              await deleteTranscriptAudioIfUserEnabled(existingId);
            } else {
              transcriptId = await persistNewTranscriptionFromResult(
                wavPath: wavPath,
                result: result,
              );
              // await _normalizeImportAudioPaths(transcriptId, wavPath);
              await _finalizeTranscriptAfterProcessing(transcriptId:  transcriptId,audioPath: wavPath);
              await deleteTranscriptAudioIfUserEnabled(transcriptId);
            }

            await AutoEmailService.sendIfEnabled(
              transcriptId: transcriptId,
              mailer: _mailer,
            );
          }

          if (type == 'transcribe_error') {
            debugPrint('BG transcription error: ${data['error']}');
          }
        } catch (e, st) {
          debugPrint('BG -> main persistence failed: $e');
          debugPrint('$st');
        }
      });

      // ✅ 3) init the background transcriber LAST
      await BackgroundTranscriber.init();

      // ✅ 4) downloader tracking last (optional)
      FileDownloader().trackTasks().catchError((_) => null);
    } catch (e, st) {
      debugPrint('Post-frame init failed: $e');
      debugPrint('$st');
    }
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Transcript',

      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,

        // ✅ IMPORTANT: let your GlassBackground show through
        scaffoldBackgroundColor: Colors.transparent,

        // Black/white only
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          secondary: Colors.white,
          surface: Color(0x0FFFFFFF), // translucent surfaces
          onSurface: Colors.white,
          onPrimary: Colors.black,
        ),

        // Remove weird tints
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,

        // Text: iOS-ish
        textTheme: ThemeData.dark().textTheme.apply(
          bodyColor: Colors.white.withValues(alpha: 0.92),
          displayColor: Colors.white.withValues(alpha: 0.92),
        ),

        // Default cards should not paint solid blocks
        cardColor: Colors.transparent,

        dividerColor: Colors.white.withValues(alpha: 0.10),
      ),

      // ✅ Global wallpaper behind EVERYTHING
      builder: (context, child) {
        return GlassBackground(child: child ?? const SizedBox.shrink());
      },

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
      // await _recoverStaleTranscriptionLock();

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
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context, alpha: 0.78);
    final isDark = GlassTokens.isDark(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {},
      child: Scaffold(
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
                      StatusPill(text: _status,isError: _failed),
                      
                      const SizedBox(height: 14),

                      // ---- Progress / error card ----
                      GlassCard(
                        variant: GlassCardVariant.panel,
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (!_failed) ...[
                              // keep same simple progress look
                              ClipRRect(
                                borderRadius: BorderRadius.circular(999),
                                child: LinearProgressIndicator(
                                  minHeight: 3,
                                  backgroundColor:
                                      Colors.white.withValues(alpha: 0.10),
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
                                onPressed: () {
                                  setState(() {
                                    _failed = false;
                                    _status = 'Retrying…';
                                  });
                                  _boot();
                                },
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
      ),
    );
  }
}

