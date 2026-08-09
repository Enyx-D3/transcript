// lib/record/record_sheet.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:objectbox/objectbox.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transcript/common/app_flushbar.dart';

import '../record/recording_service.dart';
import '../transcript/transcript_detail_page.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../transcript/background_transcriber.dart';
import 'live_whisper_preview_service.dart';

// ✅ Glass primitives (same language as ImportAudioSheet)
import '../ui/glass/liquid_glass.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_button.dart';
import '../ui/glass/glass_divider.dart';

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
  double _level = 0.0;
  late final void Function(Object) _fgListener;
  late final LiveWhisperPreviewService _livePreviewService;
  StreamSubscription<LiveWhisperPreview>? _livePreviewSub;
  late final ValueNotifier<LiveWhisperPreview> _livePreview;

  static const String _kBusyTranscribing = 'busy_transcribing';
  static const String _kActiveTranscriptId = 'bg_active_transcript_id';
  bool _handledStop = false;

  final TextEditingController _targetSpeakersCtrl = TextEditingController(
    text: '0',
  );

  static const Map<String, String> _langOptions = {
    'en': 'English',
    'es': 'Spanish',
    'fr': 'French',
    'ar': 'Arabic',
    'pt': 'Portuguese',
    'it': 'Italian',
    'zh': 'Chinese',
    'auto': 'Auto',
  };

  // loaded from prefs
  String _selectedLang = 'en';
  bool _diarizationEnabled = true;

  static const String _kLastElapsedSec = 'rec_last_elapsed_sec';
  static const String _kLastLevel = 'rec_last_level';
  static const String _kLastPaused = 'rec_last_paused';

  // must match SettingsPage keys
  static const String _kPrefDefaultLang = 'pref_default_lang';
  static const String _kPrefDiarizationEnabled = 'pref_diarization_enabled';

  @override
  void initState() {
    super.initState();
    _livePreview = ValueNotifier<LiveWhisperPreview>(LiveWhisperPreview.idle());
    _livePreviewService = LiveWhisperPreviewService();
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
        final pa = data['paused'] as bool?;

        if (!mounted) return;
        setState(() {
          if (sec != null) _seconds = sec;
          if (lv != null) _level = lv.clamp(0.0, 1.0);
          if (pa != null) _paused = pa;

          _recording = true;
          _starting = false;
        });
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
    _targetSpeakersCtrl.dispose();
    _livePreviewSub?.cancel();
    _livePreview.dispose();
    _livePreviewService.dispose();
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
    final level = await FlutterForegroundTask.getData(key: _kLastLevel);
    final paused = await FlutterForegroundTask.getData(key: _kLastPaused);

    if (!mounted) return;
    setState(() {
      _recording = true;
      _starting = false;

      _paused = (paused is bool) ? paused : false;
      if (elapsed is num) _seconds = elapsed.toDouble();
      if (level is num) _level = level.toDouble().clamp(0.0, 1.0);
    });
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
    final raw = _targetSpeakersCtrl.text.trim();
    if (raw.isEmpty) return null;

    final n = int.tryParse(raw);
    if (n == null) return null;
    if (n <= 0) return null;
    return n.clamp(1, 12);
  }

  Future<void> _start() async {
    if (_recording || _starting) return;

    try {
      _handledStop = false;

      final int? targetSpeakers = _diarizationEnabled
          ? _parseTargetSpeakers()
          : null;

      await _ensureMic();

      if (!mounted) return;
      setState(() {
        _starting = true;
        _seconds = 0.0;
        _level = 0.0;
      });
      _livePreview.value = LiveWhisperPreview.idle();

      final path = await RecordingService.start(targetSpeakers: targetSpeakers);
      if (path == null) {
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

      final p = await RecordingService.stop();
      await _livePreviewService.stop(finalize: false);

      if (!mounted) return;
      setState(() {
        _recording = false;
        _paused = false;
        _starting = false;
        _seconds = 0.0;
        _level = 0.0;
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
              speakerLabel: 'Draft',
              startSec: start,
              endSec: start + chunkSec,
              text: draftLines[i],
              rawText: draftLines[i],
              calibratedText: draftLines[i],
              originalSpeakerLabel: 'Draft',
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
    final h = MediaQuery.of(context).size.height * 0.72;

    final title = _recording
        ? (_paused ? 'Paused' : (_starting ? 'Starting…' : 'Recording…'))
        : 'Record';

    final fg = Colors.white.withValues(alpha: 0.92);

    // ✅ close pill = tint-only (same as ImportAudioSheet preferred)
    Widget closePill() {
      return LiquidGlass(
        borderRadius: BorderRadius.circular(999),
        padding: const EdgeInsets.all(8),
        shadow: false,
        blurX: 0,
        blurY: 0,
        grain: false,
        tintOpacityDark: 0.070,
        tintOpacityLight: 0.055,
        borderOpacityDark: 0.16,
        borderOpacityLight: 0.20,
        onTap: _starting ? null : () => Navigator.of(context).pop(),
        child: Icon(Icons.close, color: fg, size: 20),
      );
    }

    return SizedBox(
      height: h,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        child: Stack(
          children: [
            // ✅ sheet backdrop (moderate blur + stronger tint for readability)
            LiquidGlass(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(22),
              ),
              padding: EdgeInsets.zero,
              shadow: false,
              blurX: 9.0,
              blurY: 9.0,
              grain: false,
              tintOpacityDark: 0.10,
              tintOpacityLight: 0.08,
              borderOpacityDark: 0.18,
              borderOpacityLight: 0.22,
              child: const SizedBox.expand(),
            ),

            Column(
              children: [
                // ---------- Header ----------
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Icon(Icons.mic, color: fg),
                            const SizedBox(width: 8),
                            Text(
                              title,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: fg,
                              ),
                            ),
                            if (_starting) ...[
                              const SizedBox(width: 10),
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white.withValues(alpha: 0.75),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      closePill(),
                    ],
                  ),
                ),

                const GlassDivider(),

                // ---------- Body ----------
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // ===== Main panel =====
                        GlassCard(
                          variant: GlassCardVariant.tile,
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Center(
                                child: _TimerRing(
                                  timeText: _fmtTime(_seconds),
                                  active: _recording && !_paused,
                                  paused: _paused,
                                ),
                              ),
                              const SizedBox(height: 12),
                              LevelBars(
                                level: _level,
                                height: 16,
                                barCount: 22,
                              ),
                              const SizedBox(height: 14),

                              Row(
                                children: [
                                  Expanded(
                                    child: GlassButton(
                                      kind: GlassButtonKind.secondary,
                                      label: 'Cancel',
                                      icon: Icons.close_rounded,
                                      onPressed: _recording ? _cancel : null,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: GlassButton(
                                      kind: GlassButtonKind.secondary,
                                      label: _paused ? 'Resume' : 'Pause',
                                      icon: _paused
                                          ? Icons.play_arrow_rounded
                                          : Icons.pause_rounded,
                                      onPressed: (!_recording || _starting)
                                          ? null
                                          : (_paused ? _resume : _pause),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),

                              GlassButton(
                                kind: GlassButtonKind.primary,
                                label: _recording
                                    ? 'Stop & transcribe'
                                    : 'Start recording',
                                icon: _recording
                                    ? Icons.stop_rounded
                                    : Icons.fiber_manual_record,
                                onPressed: _starting
                                    ? null
                                    : (_recording ? _stop : _start),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 12),

                        ValueListenableBuilder<LiveWhisperPreview>(
                          valueListenable: _livePreview,
                          builder: (context, preview, _) {
                            if (!_recording && preview.text.isEmpty) {
                              return const SizedBox.shrink();
                            }
                            return Column(
                              children: [
                                _LiveTranscriptCard(preview: preview),
                                const SizedBox(height: 12),
                              ],
                            );
                          },
                        ),

                        // ===== Options =====
                        GlassCard(
                          variant: GlassCardVariant.tile,
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'Options',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: fg,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Set before recording',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.65),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 12),

                              // Language row
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Language',
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.72,
                                        ),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 180,
                                    child: _GlassField(
                                      enabled: !_recording && !_starting,
                                      child: DropdownButtonFormField<String>(
                                        initialValue: _selectedLang,
                                        isDense: true,
                                        iconEnabledColor: Colors.white
                                            .withValues(alpha: 0.80),
                                        dropdownColor: const Color(0xFF0B0C10),
                                        items: _langOptions.entries
                                            .map(
                                              (e) => DropdownMenuItem<String>(
                                                value: e.key,
                                                child: Text(
                                                  e.value,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: Colors.white
                                                        .withValues(
                                                          alpha: 0.92,
                                                        ),
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                            )
                                            .toList(),
                                        onChanged: (_recording || _starting)
                                            ? null
                                            : (v) {
                                                if (v == null) return;
                                                setState(
                                                  () => _selectedLang = v,
                                                );
                                              },
                                        decoration: const InputDecoration(
                                          isDense: true,
                                          border: InputBorder.none,
                                          contentPadding: EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 10,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),

                              const SizedBox(height: 12),

                              // Diarization
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Speaker diarization',
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.72,
                                        ),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Switch(
                                    value: _diarizationEnabled,
                                    onChanged: (_recording || _starting)
                                        ? null
                                        : _setDiarizationEnabledLocal,
                                    activeThumbColor: Colors.black,
                                    activeTrackColor: Colors.white.withValues(
                                      alpha: 0.55,
                                    ),
                                    inactiveThumbColor: Colors.white.withValues(
                                      alpha: 0.70,
                                    ),
                                    inactiveTrackColor: Colors.white.withValues(
                                      alpha: 0.18,
                                    ),
                                  ),
                                ],
                              ),

                              if (_diarizationEnabled) ...[
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        'Target speakers',
                                        style: TextStyle(
                                          color: Colors.white.withValues(
                                            alpha: 0.72,
                                          ),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 120,
                                      child: Theme(
                                        data: Theme.of(context).copyWith(
                                          textSelectionTheme:
                                              TextSelectionThemeData(
                                                selectionHandleColor: Colors
                                                    .white
                                                    .withValues(alpha: 0.90),
                                                cursorColor: Colors.white
                                                    .withValues(alpha: 0.90),
                                                selectionColor: Colors.white
                                                    .withValues(alpha: 0.18),
                                              ),
                                        ),
                                        child: _GlassField(
                                          enabled: !_recording && !_starting,
                                          child: TextField(
                                            cursorColor: Colors.white
                                                .withValues(alpha: 0.90),
                                            controller: _targetSpeakersCtrl,
                                            enabled: !_recording && !_starting,
                                            keyboardType: TextInputType.number,
                                            inputFormatters: [
                                              FilteringTextInputFormatter
                                                  .digitsOnly,
                                            ],
                                            style: TextStyle(
                                              color: Colors.white.withValues(
                                                alpha: 0.92,
                                              ),
                                              fontWeight: FontWeight.w600,
                                            ),
                                            decoration: InputDecoration(
                                              hintText: '0',
                                              hintStyle: TextStyle(
                                                color: Colors.white.withValues(
                                                  alpha: 0.45,
                                                ),
                                                fontWeight: FontWeight.w600,
                                              ),
                                              isDense: true,
                                              border: InputBorder.none,
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 10,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Use 0 for auto-detect.',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.55),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),

                        const SizedBox(height: 12),

                        Text(
                          'Tip: keep the phone close and speak clearly. You can rename speakers later in the transcript view.',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmtTime(double s) {
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toStringAsFixed(1).padLeft(4, '0');
    return '$mm:$ss';
  }
}

class _LiveTranscriptCard extends StatelessWidget {
  const _LiveTranscriptCard({required this.preview});

  final LiveWhisperPreview preview;

  @override
  Widget build(BuildContext context) {
    final textColor = Colors.white.withValues(alpha: 0.90);
    final muted = Colors.white.withValues(alpha: 0.58);
    final lines = preview.text.trim();
    final partial = preview.partial.trim();

    return GlassCard(
      variant: GlassCardVariant.tile,
      padding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 104, maxHeight: 220),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.subtitles_rounded,
                  size: 18,
                  color: preview.available ? textColor : muted,
                ),
                const SizedBox(width: 8),
                Text(
                  'Live transcript',
                  style: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: SingleChildScrollView(
                reverse: true,
                child: Text.rich(
                  TextSpan(
                    children: [
                      if (lines.isNotEmpty)
                        TextSpan(
                          text: lines,
                          style: TextStyle(
                            color: textColor,
                            height: 1.35,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      if (lines.isNotEmpty && partial.isNotEmpty)
                        const TextSpan(text: '\n'),
                      if (partial.isNotEmpty)
                        TextSpan(
                          text: partial,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.62),
                            height: 1.35,
                            fontStyle: FontStyle.italic,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      if (lines.isEmpty && partial.isEmpty)
                        TextSpan(
                          text: preview.status,
                          style: TextStyle(
                            color: muted,
                            height: 1.35,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ✅ your preferred: tint-only interactive field container
class _GlassField extends StatelessWidget {
  const _GlassField({required this.child, required this.enabled});

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    Widget field = LiquidGlass(
      borderRadius: BorderRadius.circular(14),
      padding: EdgeInsets.zero,
      shadow: false,

      // ✅ PERF: interactive => tint-only
      blurX: 0,
      blurY: 0,
      grain: false,

      tintOpacityDark: 0.075,
      tintOpacityLight: 0.060,
      borderOpacityDark: 0.16,
      borderOpacityLight: 0.20,
      child: child,
    );

    if (!enabled) field = Opacity(opacity: 0.55, child: field);
    return field;
  }
}

class _TimerRing extends StatelessWidget {
  const _TimerRing({
    required this.timeText,
    required this.active,
    required this.paused,
  });

  final String timeText;
  final bool active;
  final bool paused;

  @override
  Widget build(BuildContext context) {
    final ringColor = paused
        ? Colors.white.withValues(alpha: 0.25)
        : (active ? Colors.white : Colors.white.withValues(alpha: 0.20));

    return Container(
      width: 124,
      height: 124,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: ringColor, width: 3),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            color: ringColor.withValues(alpha: 0.18),
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Center(
        child: Text(
          timeText,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
        ),
      ),
    );
  }
}

class LevelBars extends StatelessWidget {
  const LevelBars({
    super.key,
    required this.level,
    this.height = 16,
    this.barCount = 16,
  });

  final double level;
  final double height;
  final int barCount;

  @override
  Widget build(BuildContext context) {
    final weights = List<double>.generate(barCount, (i) {
      final x = (i / (barCount - 1)) * 2 - 1;
      final bell = 1 - (x * x);
      return 0.4 + 0.6 * bell;
    });

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: level),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) {
        return SizedBox(
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(barCount, (i) {
              final barH = (height * weights[i] * (0.2 + 0.8 * v)).clamp(
                2.0,
                height,
              );
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: Container(
                    height: barH,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.90),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              );
            }),
          ),
        );
      },
    );
  }
}
