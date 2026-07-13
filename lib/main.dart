import 'dart:async';
import 'dart:ui' show DartPluginRegistrant;

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

import 'moonshine_service.dart';
import 'objectbox/objectbox_store.dart';
import 'qwen_model_service.dart';
import 'record/recording_service.dart';

import 'transcript/background_transcriber.dart';
import 'transcript/model_download_state.dart';
import 'transcript/sherpa_secondary_asr_service.dart';
import 'transcript/transcription_models.dart';
import 'transcript/transcription_persistence.dart';
import 'transcript/transcript_block_repository.dart';

// App gate
import 'auth/app_gate.dart';
import 'auth/eligibility_gate.dart';
import 'package:background_downloader/background_downloader.dart';

import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_button.dart';
import '../ui/glass/glass_tokens.dart';

final TranscriptMailService _mailer = TranscriptMailService(
  baseUrl: 'https://enyx.app',
  // authToken: 'optional', // if you use it
);

Future<void> _normalizeImportAudioPaths(
  int transcriptId,
  String wavPath,
) async {
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
  t.audioPath = wavPath.trim().isEmpty
      ? (a.isEmpty ? null : a)
      : wavPath.trim();
  t.processedAudioPath = null;

  // optional timestamp
  t.updatedAt = DateTime.now();

  obx.transcripts.put(t);

  debugPrint(
    '[IMPORT-FIX] Applied for transcriptId=$transcriptId (sourceType=$st)',
  );
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
              await _normalizeImportAudioPaths(transcriptId, wavPath);
              await deleteTranscriptAudioIfUserEnabled(existingId);
            } else {
              transcriptId = await persistNewTranscriptionFromResult(
                wavPath: wavPath,
                result: result,
              );
              // await _normalizeImportAudioPaths(transcriptId, wavPath);
              await _normalizeImportAudioPaths(transcriptId, wavPath);
              await deleteTranscriptAudioIfUserEnabled(transcriptId);
            }

            final blocksRaw = payload['blocks'];
            List<TranscriptBlockSnapshot> blocks = const [];
            if (blocksRaw is List) {
              blocks = blocksRaw
                  .whereType<Map>()
                  .map(
                    (e) => TranscriptBlockSnapshot.fromJson(
                      Map<String, dynamic>.from(e),
                    ),
                  )
                  .toList();
            }

            if (blocks.isEmpty) {
              final turnsRaw = payload['turns'];
              if (turnsRaw is List) {
                blocks = turnsRaw
                    .asMap()
                    .entries
                    .map((entry) {
                      final idx = entry.key;
                      final turn = entry.value;
                      if (turn is! Map) {
                        return null;
                      }
                      final m = Map<String, dynamic>.from(turn);
                      final speaker = (m['speaker'] ?? 'Speaker').toString();
                      final text = (m['text'] ?? '').toString();
                      final s0 =
                          m['startSec'] ?? m['start_sec'] ?? m['start'] ?? 0.0;
                      final s1 = m['endSec'] ?? m['end_sec'] ?? m['end'] ?? 0.0;
                      final start = (s0 is num)
                          ? s0.toDouble()
                          : double.tryParse('$s0') ?? 0.0;
                      final end = (s1 is num)
                          ? s1.toDouble()
                          : double.tryParse('$s1') ?? 0.0;
                      return TranscriptBlockSnapshot(
                        meetingId: transcriptId.toString(),
                        blockId: idx,
                        language: result.lang,
                        startSec: start,
                        endSec: end,
                        speakerId: speaker,
                        speakerLabel: speaker,
                        rawText: text,
                        alignedText: text,
                        finalText: text,
                        status: 'finalized',
                        confidence: 0.75,
                        createdAt: DateTime.now(),
                        updatedAt: DateTime.now(),
                      );
                    })
                    .whereType<TranscriptBlockSnapshot>()
                    .toList();
              }
            }

            if (blocks.isNotEmpty) {
              blocks = blocks
                  .map((b) => b.copyWith(meetingId: transcriptId.toString()))
                  .toList();
              await TranscriptBlockRepository.instance.save(
                transcriptId,
                blocks,
              );
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
      unawaited(FileDownloader().trackTasks());

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
  StreamSubscription<ModelProgress>? _qwenSub;
  StreamSubscription<ModelProgress>? _moonshineSub;
  StreamSubscription<ModelDownloadState>? _secondaryAsrSub;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _qwenSub?.cancel();
    _moonshineSub?.cancel();
    _secondaryAsrSub?.cancel();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      setState(() {
        _failed = false;
        _status = 'Requesting microphone access…';
      });

      final perm = await Permission.microphone.request();
      if (!perm.isGranted) {
        debugPrint('[BOOT] Microphone permission not granted yet: $perm');
      }

      final p = await FlutterForegroundTask.checkNotificationPermission();
      if (p != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }

      setState(() => _status = 'Initializing…');
      // await _recoverStaleTranscriptionLock();

      await _prepareRequiredModels();

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

  Future<void> _prepareRequiredModels() async {
    await _prepareQwenModel();
    await _prepareMoonshineModel();
    await _prepareSecondaryAsrModel();
  }

  Future<void> _prepareQwenModel() async {
    final service = QwenModelService();
    if (await service.isModelDownloaded()) {
      if (mounted) setState(() => _status = 'AI model ready (1/3)…');
      return;
    }

    _qwenSub?.cancel();
    _qwenSub = service.progress.listen((progress) {
      if (!mounted) return;
      setState(() {
        _status = _statusFromModelProgress(
          prefix: 'Downloading AI model (1/3)',
          progress: progress,
        );
      });
    });

    await service.ensureModelDownloaded();
    if (mounted) setState(() => _status = 'AI model ready (1/3)…');
  }

  Future<void> _prepareMoonshineModel() async {
    final service = MoonshineService();
    if (await service.isModelDownloaded()) {
      if (mounted) setState(() => _status = 'Moonshine ready (2/3)…');
      return;
    }

    _moonshineSub?.cancel();
    _moonshineSub = service.progress.listen((progress) {
      if (!mounted) return;
      setState(() {
        _status = _statusFromModelProgress(
          prefix: 'Downloading Moonshine (2/3)',
          progress: progress,
        );
      });
    });

    await service.ensureModelDownloaded();
    if (mounted) setState(() => _status = 'Moonshine ready (2/3)…');
  }

  Future<void> _prepareSecondaryAsrModel() async {
    final service = SherpaSecondaryAsrService();
    if (await service.isModelReady()) {
      if (mounted) setState(() => _status = 'Whisper ready (3/3)…');
      return;
    }

    _secondaryAsrSub?.cancel();
    _secondaryAsrSub = service.progress.listen((progress) {
      if (!mounted) return;
      setState(() {
        _status = _statusFromDownloadState(
          prefix: 'Downloading Whisper (3/3)',
          progress: progress,
        );
      });
    });

    await service.ensureModelDownloaded();
    if (mounted) setState(() => _status = 'Whisper ready (3/3)…');
  }

  String _statusFromModelProgress({
    required String prefix,
    required ModelProgress progress,
  }) {
    if (progress.error != null && progress.error!.isNotEmpty) {
      return progress.error!;
    }
    if (progress.stage == 'extracting') {
      return '$prefix • Preparing files…';
    }
    if (progress.total > 0) {
      final pct = (progress.percent * 100).clamp(0, 100).toStringAsFixed(0);
      return '$prefix • $pct%';
    }
    return prefix;
  }

  String _statusFromDownloadState({
    required String prefix,
    required ModelDownloadState progress,
  }) {
    if (progress.error != null && progress.error!.isNotEmpty) {
      return progress.error!;
    }
    if (progress.stage == 'extracting') {
      return '$prefix • Preparing files…';
    }
    if (progress.total > 0) {
      final pct = (progress.percent * 100).clamp(0, 100).toStringAsFixed(0);
      return '$prefix • $pct%';
    }
    return prefix;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context, alpha: 0.78);

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
                      StatusPill(text: _status, isError: _failed),

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
