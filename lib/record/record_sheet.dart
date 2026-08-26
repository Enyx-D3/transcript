// lib/record/record_sheet.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:objectbox/objectbox.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transcript/common/app_flushbar.dart';
import 'package:waveform_flutter/waveform_flutter.dart' as waveform;

import '../record/recording_service.dart';
import '../transcript/transcript_detail_page.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../transcript/background_transcriber.dart';
import 'live_whisper_preview_service.dart';

import '../ui/glass/glass_tokens.dart';

class RecordSheet extends StatefulWidget {
  const RecordSheet({super.key});

  static Future<void> show(BuildContext context) async {
    const kBusyTranscribing = 'busy_transcribing';

    final busyFlag =
        (await FlutterForegroundTask.getData(key: kBusyTranscribing)) == true;

    final running = await FlutterForegroundTask.isRunningService;

    final busy = busyFlag && running;
    if (busyFlag && !running) {
      await FlutterForegroundTask.saveData(
        key: kBusyTranscribing,
        value: false,
      );
    }
    if (busy) {
      if (!context.mounted) return;
      await AppFlushbar.info(
        context,
        message: 'Transcription in progress… Please wait.',
      );
      return;
    }

    if (!context.mounted) return;

    return showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const RecordSheet(),
    );
  }

  @override
  State<RecordSheet> createState() => _RecordSheetState();
}

class _RecordSheetState extends State<RecordSheet> {
  bool _recording = false;
  bool _paused = false;
  bool _starting = false;

  double _seconds = 0.0;
  late final void Function(Object) _fgListener;
  late final LiveWhisperPreviewService _livePreviewService;
  StreamSubscription<LiveWhisperPreview>? _livePreviewSub;
  late final ValueNotifier<LiveWhisperPreview> _livePreview;
  StreamController<waveform.Amplitude>? _amplitudeStreamController;

  static const String _kBusyTranscribing = 'busy_transcribing';
  static const String _kActiveTranscriptId = 'bg_active_transcript_id';
  bool _handledStop = false;

  int _targetSpeakersCount = 0; // 0 == auto

  static const Map<String, String> _langOptions = {
    'en': 'English',
    'es': 'Spanish',
    'fr': 'French',
    'ar': 'Arabic',
    'pt': 'Portuguese',
    'it': 'Italian',
    'zh': 'Chinese',
    'auto': 'Auto-detect',
  };

  String _selectedLang = 'en';
  bool _diarizationEnabled = true;

  static const String _kLastElapsedSec = 'rec_last_elapsed_sec';
  static const String _kLastPaused = 'rec_last_paused';

  static const String _kPrefDefaultLang = 'pref_default_lang';
  static const String _kPrefDiarizationEnabled = 'pref_diarization_enabled';

  @override
  void initState() {
    super.initState();
    _livePreviewService = LiveWhisperPreviewService.instance;
    _livePreview = ValueNotifier<LiveWhisperPreview>(
      _livePreviewService.currentPreview,
    );
    _livePreviewSub = _livePreviewService.updates.listen((preview) {
      _livePreview.value = preview;
    });

    _fgListener = (Object data) async {
      if (!mounted) return;
      if (data is! Map) return;

      final type = data['type'];

      if (type == 'tick') {
        final sec = (data['elapsedSec'] as num?)?.toDouble();
        final lv = (data['level'] as num?)?.toDouble();
        final db =
            (data['db'] as num?)?.toDouble() ??
            ((lv != null) ? (lv * 60.0) - 60.0 : -60.0);
        final pa = data['paused'] as bool?;

        if (!mounted) return;
        setState(() {
          if (sec != null) _seconds = sec;
          if (pa != null) _paused = pa;

          _recording = true;
          _starting = false;
        });

        if (_recording && !_paused) {
          RecordingService.recentAmplitudes.add(db);
          if (RecordingService.recentAmplitudes.length > 40) {
            RecordingService.recentAmplitudes.removeAt(0);
          }
          _amplitudeStreamController?.add(
            waveform.Amplitude(current: db, max: 0.0),
          );
        }
        return;
      }

      if (type == 'limit_reached') {
        if (!mounted) return;
        await AppFlushbar.info(
          context,
          message: 'Recording limit reached. Stopping…',
        );
        return;
      }

      if (type == 'stopped') {
        if (_handledStop) return;
        _handledStop = true;

        final fp = data['filePath'];
        final wavPath = fp is String ? fp : null;

        final ts = data['targetSpeakers'];
        final int? targetSpeakers = (ts is int) ? ts : null;

        _amplitudeStreamController?.close();
        _amplitudeStreamController = null;

        if (!mounted) return;
        setState(() {
          _recording = false;
          _paused = false;
          _starting = false;
        });
        final draftText = _livePreviewService.currentText.isNotEmpty
            ? _livePreviewService.currentText
            : _livePreview.value.text.trim();
        await _livePreviewService.stop();

        if (wavPath == null || wavPath.trim().isEmpty) {
          if (!mounted) return;
          await AppFlushbar.error(context, message: 'Recording file missing.');
          return;
        }

        await _createTranscriptAndStartTranscription(
          wavPath: wavPath,
          targetSpeakers: _diarizationEnabled ? targetSpeakers : null,
          lang: _selectedLang,
          draftText: draftText,
        );
      }
    };

    RecordingService.addListener(_fgListener);
    _loadSettingsThenHydrate();
  }

  @override
  void dispose() {
    _amplitudeStreamController?.close();
    _livePreviewSub?.cancel();
    _livePreview.dispose();
    RecordingService.removeListener(_fgListener);
    super.dispose();
  }

  Future<void> _loadSettingsThenHydrate() async {
    try {
      final sp = await SharedPreferences.getInstance();

      final lang = sp.getString(_kPrefDefaultLang) ?? 'en';
      final safeLang = _langOptions.containsKey(lang) ? lang : 'en';

      final diar = sp.getBool(_kPrefDiarizationEnabled) ?? true;

      if (!mounted) return;
      setState(() {
        _selectedLang = safeLang;
        _diarizationEnabled = diar;
      });
    } catch (_) {}

    await _hydrateFromRecordingService();
  }

  void _setDiarizationEnabledLocal(bool v) {
    if (!mounted) return;
    setState(() => _diarizationEnabled = v);
  }

  Future<void> _hydrateFromRecordingService() async {
    final running = await FlutterForegroundTask.isRunningService;
    if (!mounted) return;

    if (!running) {
      setState(() {
        _recording = false;
        _paused = false;
        _starting = false;
      });
      return;
    }

    final elapsed = await FlutterForegroundTask.getData(key: _kLastElapsedSec);
    final paused = await FlutterForegroundTask.getData(key: _kLastPaused);

    if (!mounted) return;
    setState(() {
      _recording = true;
      _starting = false;

      _paused = (paused is bool) ? paused : false;
      if (elapsed is num) _seconds = elapsed.toDouble();
    });

    _livePreview.value = _livePreviewService.currentPreview;

    if (_recording) {
      if (!_livePreviewService.isRunning) {
        final wavPath = await RecordingService.getCurrentWavPath();
        if (wavPath != null) {
          unawaited(_livePreviewService.start(wavPath, lang: _selectedLang));
        }
      }

      if (_amplitudeStreamController == null) {
        _amplitudeStreamController =
            StreamController<waveform.Amplitude>.broadcast();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          for (final db in RecordingService.recentAmplitudes) {
            _amplitudeStreamController?.add(
              waveform.Amplitude(current: db, max: 0.0),
            );
          }
        });
      }
    }
  }

  Future<void> _ensureMic() async {
    final st = await Permission.microphone.status;
    if (st.isDenied || st.isPermanentlyDenied) {
      final g = await Permission.microphone.request();
      if (!g.isGranted) {
        throw Exception('Microphone permission is required.');
      }
    }
  }

  int? _parseTargetSpeakers() {
    if (_targetSpeakersCount <= 0) return null;
    return _targetSpeakersCount.clamp(1, 12);
  }

  Future<void> _start() async {
    if (_recording || _starting) return;

    try {
      _handledStop = false;

      final int? targetSpeakers = _diarizationEnabled
          ? _parseTargetSpeakers()
          : null;

      await _ensureMic();

      RecordingService.recentAmplitudes.clear();
      _amplitudeStreamController?.close();
      _amplitudeStreamController =
          StreamController<waveform.Amplitude>.broadcast();

      if (!mounted) return;
      setState(() {
        _starting = true;
        _seconds = 0.0;
      });
      _livePreview.value = LiveWhisperPreview.idle();

      final path = await RecordingService.start(targetSpeakers: targetSpeakers);
      if (path == null) {
        _amplitudeStreamController?.close();
        _amplitudeStreamController = null;
        if (!mounted) return;
        setState(() => _starting = false);
        await AppFlushbar.error(context, message: 'Couldn’t start recording.');
        return;
      }

      if (!mounted) return;
      setState(() {
        _recording = true;
        _paused = false;
      });
      unawaited(_livePreviewService.start(path, lang: _selectedLang));
    } catch (e) {
      _amplitudeStreamController?.close();
      _amplitudeStreamController = null;
      if (!mounted) return;
      setState(() => _starting = false);
      await AppFlushbar.error(
        context,
        message: 'Failed to start recording: $e',
      );
    }
  }

  Future<void> _pause() async {
    if (!_recording || _paused) return;
    try {
      RecordingService.pause();
      await _livePreviewService.pause();
      if (!mounted) return;
      setState(() => _paused = true);
    } catch (_) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Failed to pause recording');
    }
  }

  Future<void> _resume() async {
    if (!_recording || !_paused) return;
    try {
      RecordingService.resume();
      await _livePreviewService.resume();
      if (!mounted) return;
      setState(() => _paused = false);
    } catch (_) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Failed to resume recording');
    }
  }

  Future<void> _stop() async {
    if (!_recording) return;

    try {
      _amplitudeStreamController?.close();
      _amplitudeStreamController = null;

      if (!mounted) return;
      setState(() {
        _recording = false;
        _paused = false;
      });

      await RecordingService.stop();
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Failed to stop recording: $e');
    }
  }

  Future<void> _cancel() async {
    try {
      _handledStop = true;
      _amplitudeStreamController?.close();
      _amplitudeStreamController = null;

      final p = await RecordingService.stop();
      await _livePreviewService.stop(finalize: false);

      if (!mounted) return;
      setState(() {
        _recording = false;
        _paused = false;
        _starting = false;
        _seconds = 0.0;
      });
      _livePreview.value = LiveWhisperPreview.idle();

      if (p != null) {
        try {
          File(p).deleteSync();
        } catch (_) {}
      }

      if (!mounted) return;
      await AppFlushbar.success(context, message: 'Recording cancelled');
    } catch (_) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Failed to cancel recording');
    }
  }

  Future<void> _createTranscriptAndStartTranscription({
    required String wavPath,
    int? targetSpeakers,
    required String lang,
    required String draftText,
  }) async {
    final placeholderDuration = (_seconds.isFinite && _seconds >= 0)
        ? _seconds
        : 0.0;

    final obx = ObjectBox.I;

    final draftLines = _draftLines(draftText);
    final draftCache = draftLines.isEmpty ? null : draftLines.join('\n');

    final tId = obx.store.runInTransaction(TxMode.write, () {
      final transcript = TranscriptEntity(
        title: '',
        model: 'sherpa-onnx-whisper-tiny',
        lang: lang,
        audioPath: wavPath,
        durationSec: placeholderDuration,
        createdAt: DateTime.now(),
        rawText: draftCache,
        calibratedText: draftCache,
        fullTextCache: draftCache,
        searchText: draftCache,
      );
      final id = obx.transcripts.put(transcript);

      if (draftLines.isNotEmpty) {
        final chunkSec = placeholderDuration > 0
            ? placeholderDuration / draftLines.length
            : 8.0;
        obx.turns.putMany(
          List.generate(draftLines.length, (i) {
            final start = i * chunkSec;
            return TranscriptTurnEntity(
              speakerLabel: 'Speaker 1',
              startSec: start,
              endSec: start + chunkSec,
              text: draftLines[i],
              rawText: draftLines[i],
              calibratedText: draftLines[i],
              originalSpeakerLabel: 'Speaker 1',
            )..transcript.targetId = id;
          }),
        );
      }

      return id;
    });

    final jobId = obx.jobs.put(
      TranscriptionJobEntity(
        wavPath: wavPath,
        translateToEnglish: false,
        titleHint: null,
        transcriptId: tId,
        status: 'PENDING',
        createdAt: DateTime.now(),
      ),
    );

    await FlutterForegroundTask.saveData(key: _kBusyTranscribing, value: true);
    await FlutterForegroundTask.saveData(key: _kActiveTranscriptId, value: tId);

    if (!mounted) return;

    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TranscriptDetailPage(transcriptId: tId),
      ),
    );

    try {
      final sp = await SharedPreferences.getInstance();
      final typoFix = sp.getBool('pref_typo_fix_enabled') ?? false;
      await BackgroundTranscriber.start(
        wavPath: wavPath,
        translateToEnglish: false,
        titleHint: null,
        existingTranscriptId: tId,
        targetSpeakers: targetSpeakers,
        lang: lang,
        typoFixEnabled: typoFix,
        diarizationEnabled: _diarizationEnabled,
      );

      final job = obx.jobs.get(jobId);
      if (job != null && job.status == 'PENDING') {
        job.status = 'RUNNING';
        obx.jobs.put(job);
      }
    } catch (e) {
      final job = obx.jobs.get(jobId);
      if (job != null) {
        job.status = 'ERROR';
        job.error = 'Failed to start transcription.';
        obx.jobs.put(job);
      }
      await FlutterForegroundTask.saveData(
        key: _kBusyTranscribing,
        value: false,
      );
      await FlutterForegroundTask.saveData(key: _kActiveTranscriptId, value: 0);

      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Processing Error: $e');
    }
  }

  List<String> _draftLines(String value) => value
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);
    final primaryBlue = GlassTokens.primary(context);
    const recordRed = Color(0xFFFF3B30);
    const pauseAmber = Color(0xFFFF9500);

    final sheetHeight = MediaQuery.of(context).size.height * 0.58;

    return Container(
      height: sheetHeight,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF131419) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.50 : 0.12),
            blurRadius: 30,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: Column(
        children: [
          // Drag Handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 8, bottom: 2),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: (isDark ? Colors.white : Colors.black).withValues(
                  alpha: 0.16,
                ),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
            child: Row(
              children: [
                Text(
                  'Record',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: fg,
                    letterSpacing: -0.3,
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: _starting ? null : () => Navigator.of(context).pop(),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: (isDark ? Colors.white : Colors.black).withValues(
                        alpha: 0.05,
                      ),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.close_rounded, size: 17, color: muted),
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ===== Minimalist Voice Stage =====
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        // 🌊 Dynamic AI Waveform Visualizer (On Top)
                        SizedBox(
                          height: 36,
                          child:
                              _recording && _amplitudeStreamController != null
                              ? waveform.AnimatedWaveList(
                                  stream: _amplitudeStreamController!.stream,
                                  barBuilder: (animation, amplitude) {
                                    final db = amplitude.current.abs().clamp(
                                      1.0,
                                      60.0,
                                    );
                                    final barHeight =
                                        (((60.0 - db) / 60.0) * 28.0 + 4.0)
                                            .clamp(4.0, 32.0);

                                    return SizeTransition(
                                      sizeFactor: animation,
                                      axis: Axis.horizontal,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 1.5,
                                        ),
                                        child: Center(
                                          child: Container(
                                            width: 3.5,
                                            height: barHeight,
                                            decoration: BoxDecoration(
                                              color: _paused
                                                  ? pauseAmber.withValues(
                                                      alpha: 0.70,
                                                    )
                                                  : primaryBlue,
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                )
                              : const SizedBox.shrink(),
                        ),
                        const SizedBox(height: 8),

                        // Timer text (Below Wave)
                        Text(
                          _fmtTime(_seconds),
                          style: TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w900,
                            color: _recording
                                ? (_paused ? pauseAmber : fg)
                                : fg.withValues(alpha: 0.85),
                            letterSpacing: -1.0,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        Text(
                          _recording
                              ? (_paused ? 'Paused' : 'Recording…')
                              : 'Ready',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _recording
                                ? (_paused ? pauseAmber : primaryBlue)
                                : muted,
                          ),
                        ),
                        const SizedBox(height: 10),

                        // Minimal Action Controls
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            // Cancel
                            SizedBox(
                              width: 56,
                              child: Opacity(
                                opacity: _recording ? 1.0 : 0.0,
                                child: InkWell(
                                  onTap: _recording ? _cancel : null,
                                  borderRadius: BorderRadius.circular(24),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 4,
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.close_rounded,
                                          size: 20,
                                          color: recordRed,
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Cancel',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w700,
                                            color: recordRed,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),

                            // Main Record Button
                            GestureDetector(
                              onTap: _starting
                                  ? null
                                  : (_recording ? _stop : _start),
                              child: Container(
                                width: 60,
                                height: 60,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _recording ? recordRed : primaryBlue,
                                ),
                                child: Center(
                                  child: _starting
                                      ? const SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.2,
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                                  Colors.white,
                                                ),
                                          ),
                                        )
                                      : (_recording
                                            ? Container(
                                                width: 20,
                                                height: 20,
                                                decoration: BoxDecoration(
                                                  color: Colors.white,
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                              )
                                            : const Icon(
                                                Icons.mic_rounded,
                                                size: 28,
                                                color: Colors.white,
                                              )),
                                ),
                              ),
                            ),

                            // Pause / Resume
                            SizedBox(
                              width: 56,
                              child: Opacity(
                                opacity: _recording ? 1.0 : 0.0,
                                child: InkWell(
                                  onTap: (!_recording || _starting)
                                      ? null
                                      : (_paused ? _resume : _pause),
                                  borderRadius: BorderRadius.circular(24),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 4,
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _paused
                                              ? Icons.play_arrow_rounded
                                              : Icons.pause_rounded,
                                          size: 20,
                                          color: _paused
                                              ? primaryBlue
                                              : pauseAmber,
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          _paused ? 'Resume' : 'Pause',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w700,
                                            color: _paused
                                                ? primaryBlue
                                                : pauseAmber,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // ===== Live Speech Preview (when recording) =====
                  ValueListenableBuilder<LiveWhisperPreview>(
                    valueListenable: _livePreview,
                    builder: (context, preview, _) {
                      if (!_recording && preview.text.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      final lines = preview.text.trim();
                      final partial = preview.partial.trim();
                      final hasText = lines.isNotEmpty || partial.isNotEmpty;

                      return Container(
                        margin: const EdgeInsets.only(top: 22, bottom: 16),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: (isDark ? Colors.white : Colors.black)
                              .withValues(alpha: 0.035),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: (isDark ? Colors.white : Colors.black)
                                .withValues(alpha: 0.06),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.subtitles_rounded,
                                  size: 15,
                                  color: primaryBlue,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'Live transcript',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: fg,
                                  ),
                                ),
                                const Spacer(),
                                if (_recording && !_paused)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: primaryBlue.withValues(
                                        alpha: 0.12,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 6,
                                          height: 6,
                                          decoration: BoxDecoration(
                                            color: primaryBlue,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          'LIVE',
                                          style: TextStyle(
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w800,
                                            color: primaryBlue,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                            if (hasText) ...[
                              const SizedBox(height: 8),
                              Text.rich(
                                TextSpan(
                                  children: [
                                    if (lines.isNotEmpty)
                                      TextSpan(
                                        text: lines,
                                        style: TextStyle(
                                          color: fg,
                                          fontSize: 13,
                                          height: 1.3,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    if (lines.isNotEmpty && partial.isNotEmpty)
                                      const TextSpan(text: ' '),
                                    if (partial.isNotEmpty)
                                      TextSpan(
                                        text: partial,
                                        style: TextStyle(
                                          color: muted,
                                          fontSize: 13,
                                          height: 1.3,
                                          fontStyle: FontStyle.italic,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),

                  // ===== Minimal Options Group (Smooth Animated Cross-Fade & Collapse) =====
                  AnimatedCrossFade(
                    duration: const Duration(milliseconds: 350),
                    firstCurve: Curves.easeOutCubic,
                    secondCurve: Curves.easeInCubic,
                    sizeCurve: Curves.easeInOutCubic,
                    crossFadeState: _recording
                        ? CrossFadeState.showSecond
                        : CrossFadeState.showFirst,
                    secondChild: const SizedBox(
                      width: double.infinity,
                      height: 0,
                    ),
                    firstChild: Container(
                      margin: const EdgeInsets.only(top: 20, bottom: 12),
                      decoration: BoxDecoration(
                        color: (isDark ? Colors.white : Colors.black)
                            .withValues(alpha: 0.035),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: (isDark ? Colors.white : Colors.black)
                              .withValues(alpha: 0.06),
                        ),
                      ),
                      child: Column(
                        children: [
                          // Language Row
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                Text(
                                  'Language',
                                  style: TextStyle(
                                    color: fg,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
                                ),
                                const Spacer(),
                                DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    value: _selectedLang,
                                    isDense: true,
                                    icon: Icon(
                                      Icons.unfold_more_rounded,
                                      size: 18,
                                      color: primaryBlue,
                                    ),
                                    dropdownColor: isDark
                                        ? const Color(0xFF1E1E26)
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(14),
                                    items: _langOptions.entries
                                        .map(
                                          (e) => DropdownMenuItem<String>(
                                            value: e.key,
                                            child: Text(
                                              e.value,
                                              style: TextStyle(
                                                color: fg,
                                                fontWeight: FontWeight.w600,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: (_recording || _starting)
                                        ? null
                                        : (v) {
                                            if (v == null) return;
                                            setState(() => _selectedLang = v);
                                          },
                                  ),
                                ),
                              ],
                            ),
                          ),

                          Divider(
                            height: 1,
                            indent: 16,
                            endIndent: 16,
                            color: (isDark ? Colors.white : Colors.black)
                                .withValues(alpha: 0.05),
                          ),

                          // Diarization Switch Row
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Speaker diarization',
                                        style: TextStyle(
                                          color: fg,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 14,
                                        ),
                                      ),
                                      const SizedBox(height: 1),
                                      Text(
                                        'Distinguish multiple speakers',
                                        style: TextStyle(
                                          color: muted,
                                          fontSize: 11.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Transform.scale(
                                  scale: 0.82,
                                  child: Switch(
                                    value: _diarizationEnabled,
                                    activeTrackColor: primaryBlue,
                                    onChanged: (_recording || _starting)
                                        ? null
                                        : (v) => _setDiarizationEnabledLocal(v),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // Target Speakers Counter (if diarization is on)
                          if (_diarizationEnabled) ...[
                            Divider(
                              height: 1,
                              indent: 16,
                              endIndent: 16,
                              color: (isDark ? Colors.white : Colors.black)
                                  .withValues(alpha: 0.05),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    'Target speakers',
                                    style: TextStyle(
                                      color: fg,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const Spacer(),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      InkWell(
                                        onTap:
                                            (_recording ||
                                                _starting ||
                                                _targetSpeakersCount <= 0)
                                            ? null
                                            : () => setState(
                                                () => _targetSpeakersCount--,
                                              ),
                                        borderRadius: BorderRadius.circular(12),
                                        child: Padding(
                                          padding: const EdgeInsets.all(4),
                                          child: Icon(
                                            Icons.remove_circle_outline_rounded,
                                            size: 20,
                                            color: _targetSpeakersCount > 0
                                                ? primaryBlue
                                                : muted,
                                          ),
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                        ),
                                        child: Text(
                                          _targetSpeakersCount == 0
                                              ? 'Auto'
                                              : '$_targetSpeakersCount',
                                          style: TextStyle(
                                            color: fg,
                                            fontWeight: FontWeight.w800,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                      InkWell(
                                        onTap:
                                            (_recording ||
                                                _starting ||
                                                _targetSpeakersCount >= 10)
                                            ? null
                                            : () => setState(
                                                () => _targetSpeakersCount++,
                                              ),
                                        borderRadius: BorderRadius.circular(12),
                                        child: Padding(
                                          padding: const EdgeInsets.all(4),
                                          child: Icon(
                                            Icons.add_circle_outline_rounded,
                                            size: 20,
                                            color: _targetSpeakersCount < 10
                                                ? primaryBlue
                                                : muted,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _fmtTime(double s) {
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toStringAsFixed(1).padLeft(4, '0');
    return '$mm:$ss';
  }
}
