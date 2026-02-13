// lib/record/record_sheet.dart
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transcript/common/app_flushbar.dart';

import '../record/recording_service.dart';
import '../transcript/transcript_detail_page.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../transcript/background_transcriber.dart';

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

  static const String _kBusyTranscribing = 'busy_transcribing';
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

        if (wavPath == null || wavPath.trim().isEmpty) {
          if (!mounted) return;
          await AppFlushbar.error(context, message: 'Recording file missing.');
          return;
        }

        await _createTranscriptAndStartTranscription(
          wavPath: wavPath,
          targetSpeakers: _diarizationEnabled ? targetSpeakers : null,
          lang: _selectedLang,
        );
      }
    };

    RecordingService.addListener(_fgListener);
    _loadSettingsThenHydrate();
  }

  @override
  void dispose() {
    _targetSpeakersCtrl.dispose();
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

      if (!mounted) return;
      setState(() {
        _recording = false;
        _paused = false;
        _starting = false;
        _seconds = 0.0;
        _level = 0.0;
      });

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
  }) async {
    final placeholderDuration = (_seconds.isFinite && _seconds >= 0)
        ? _seconds
        : 0.0;

    final obx = ObjectBox.I;

    final tId = obx.transcripts.put(
      TranscriptEntity(
        title: '',
        model: 'whisper',
        lang: lang,
        audioPath: wavPath,
        durationSec: placeholderDuration,
        createdAt: DateTime.now(),
      ),
    );

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

    if (!mounted) return;

    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TranscriptDetailPage(transcriptId: tId),
      ),
    );

    try {
      await BackgroundTranscriber.start(
        wavPath: wavPath,
        translateToEnglish: false,
        titleHint: null,
        existingTranscriptId: tId,
        targetSpeakers: targetSpeakers,
        lang: lang,
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

      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Processing Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height * 0.72;

    final title = _recording
        ? (_paused ? 'Paused' : (_starting ? 'Starting…' : 'Recording…'))
        : 'Record';

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    const sheetBg = Color(0xFF0B0C10);
    final border = (isDark ? Colors.white : Colors.black).withOpacity(0.10);

    return SizedBox(
      height: h,
      child: Container(
        decoration: BoxDecoration(
          color: sheetBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          border: Border.all(color: border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // Positioned.fill(
            //   child: IgnorePointer(
            //     child: Container(
            //       decoration: BoxDecoration(
            //         gradient: LinearGradient(
            //           begin: Alignment.topCenter,
            //           end: Alignment.bottomCenter,
            //           colors: [
            //             const Color(0xFFCD66FD).withOpacity(0.12),
            //             Colors.transparent,
            //           ],
            //         ),
            //       ),
            //     ),
            //   ),
            // ),
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Center(
                            //   child: Container(
                            //     width: 44,
                            //     height: 5,
                            //     margin: const EdgeInsets.only(bottom: 10),
                            //     decoration: BoxDecoration(
                            //       borderRadius: BorderRadius.circular(99),
                            //       color: Colors.white.withOpacity(0.14),
                            //     ),
                            //   ),
                            // ),
                            Row(
                              children: [
                                const Icon(Icons.mic, color: Colors.white),
                                const SizedBox(width: 8),
                                Text(
                                  title,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
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
                                        Colors.white.withOpacity(0.75),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Panel(
                          child: Column(
                            children: [
                              _TimerRing(
                                timeText: _fmtTime(_seconds),
                                active: _recording && !_paused,
                                paused: _paused,
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
                                    child: OutlinedButton.icon(
                                      onPressed: _recording ? _cancel : null,
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        color: Colors.white,
                                      ),
                                      label: const Text(
                                        'Cancel',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: (!_recording || _starting)
                                          ? null
                                          : (_paused ? _resume : _pause),
                                      icon: Icon(
                                        _paused
                                            ? Icons.play_arrow_rounded
                                            : Icons.pause_rounded,
                                        color: Colors.white,
                                      ),
                                      label: Text(
                                        _paused ? 'Resume' : 'Pause',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: _recording ? _stop : _start,
                                  icon: Icon(
                                    _recording
                                        ? Icons.stop_rounded
                                        : Icons.fiber_manual_record,
                                  ),
                                  label: Text(
                                    _recording
                                        ? 'Stop & transcribe'
                                        : 'Start recording',
                                  ),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        _Panel(
                          title: 'Options',
                          subtitle: 'Set before recording',
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  const Expanded(
                                    child: Text(
                                      'Language',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 180,
                                    child: DropdownButtonFormField<String>(
                                      value: _selectedLang,
                                      items: _langOptions.entries
                                          .map(
                                            (e) => DropdownMenuItem<String>(
                                              value: e.key,
                                              child: Text(e.value),
                                            ),
                                          )
                                          .toList(),
                                      onChanged: (_recording || _starting)
                                          ? null
                                          : (v) {
                                              if (v == null) return;
                                              setState(() => _selectedLang = v);
                                            },
                                      decoration: const InputDecoration(
                                        isDense: true,
                                        border: OutlineInputBorder(),
                                        enabledBorder: OutlineInputBorder(
                                          borderSide: BorderSide(
                                            color: Color(0xFFff8143),
                                            width: 1,
                                          ),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderSide: BorderSide(
                                            color: Color(0xFFff8143),
                                            width: 1,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  const Expanded(
                                    child: Text(
                                      'Speaker diarization',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Switch(
                                    value: _diarizationEnabled,
                                    onChanged: (_recording || _starting)
                                        ? null
                                        : _setDiarizationEnabledLocal,
                                    activeColor: Colors.black, // thumb
                                    activeTrackColor: const Color(
                                      0xFFff8143,
                                    ), // track
                                  ),
                                ],
                              ),
                              if (_diarizationEnabled) ...[
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    const Expanded(
                                      child: Text(
                                        'Target speakers',
                                        style: TextStyle(
                                          color: Colors.white70,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 120,
                                      child: TextField(
                                        controller: _targetSpeakersCtrl,
                                        enabled: !_recording && !_starting,
                                        keyboardType: TextInputType.number,
                                        inputFormatters: [
                                          FilteringTextInputFormatter
                                              .digitsOnly,
                                        ],
                                        decoration: const InputDecoration(
                                          hintText: '0',
                                          isDense: true,
                                          border: OutlineInputBorder(),
                                          enabledBorder: OutlineInputBorder(
                                            borderSide: BorderSide(
                                              color: Color(0xFFff8143),
                                              width: 1,
                                            ),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderSide: BorderSide(
                                              color: Color(0xFFff8143),
                                              width: 1,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                const Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'Use 0 for auto-detect.',
                                    style: TextStyle(
                                      color: Colors.white54,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Tip: keep the phone close and speak clearly. You can rename speakers later in the transcript view.',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
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

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.title, this.subtitle});

  final Widget child;
  final String? title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg = isDark ? const Color(0xFF101018) : theme.colorScheme.surface;
    final border = (isDark ? Colors.white : Colors.black).withOpacity(0.10);

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            color: Colors.black.withOpacity(isDark ? 0.25 : 0.08),
            offset: const Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(title!, style: const TextStyle(fontWeight: FontWeight.w800)),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
          ],
          child,
        ],
      ),
    );
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
        ? Colors.white.withOpacity(0.25)
        : (active ? Colors.white : Colors.white.withOpacity(0.20));

    return Container(
      width: 124,
      height: 124,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: ringColor, width: 3),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            color: ringColor.withOpacity(0.18),
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
                      color: Colors.white.withOpacity(0.90),
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
