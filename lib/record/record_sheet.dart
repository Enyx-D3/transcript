import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
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
      backgroundColor: const Color(0xFF0B0C10),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
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

  double _seconds = 0.0; // from service ticks
  double _level = 0.0; // from service ticks
  late final void Function(Object) _fgListener;

  static const String _kBusyTranscribing = 'busy_transcribing';

  // ✅ prevents double navigation / double transcript creation
  bool _handledStop = false;

  // ✅ user input: target speakers (0 = auto/null)
  final TextEditingController _targetSpeakersCtrl =
      TextEditingController(text: '0');

  // ✅ keys written by recording task so UI can restore instantly after reopening sheet
  static const String _kLastElapsedSec = 'rec_last_elapsed_sec';
  static const String _kLastLevel = 'rec_last_level';
  static const String _kLastPaused = 'rec_last_paused';

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

        setState(() {
          if (sec != null) _seconds = sec;
          if (lv != null) _level = lv.clamp(0.0, 1.0);
          if (pa != null) _paused = pa;

          // ✅ if ticks are coming, we're recording
          _recording = true;
          _starting = false;
        });
        return;
      }

      if (type == 'limit_reached') {
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

        // ✅ target speakers in stop payload
        final ts = data['targetSpeakers'];
        final int? targetSpeakers = (ts is int) ? ts : null;

        setState(() {
          _recording = false;
          _paused = false;
          _starting = false;
        });

        if (wavPath == null || wavPath.trim().isEmpty) {
          await AppFlushbar.error(context, message: 'Recording file missing.');
          return;
        }

        await _createTranscriptAndStartTranscription(
          wavPath: wavPath,
          targetSpeakers: targetSpeakers,
        );
      }
    };

    RecordingService.addListener(_fgListener);

    // ✅ IMPORTANT: if user closed sheet and reopened while recording,
    // restore state immediately (buttons/time) instead of waiting for next tick.
    _hydrateFromRecordingService();
  }

  @override
  void dispose() {
    _targetSpeakersCtrl.dispose();
    RecordingService.removeListener(_fgListener);
    super.dispose();
  }

  /// ✅ Restore UI state instantly if the recording service is already running.
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

    // service is running -> show correct buttons immediately
    final elapsed = await FlutterForegroundTask.getData(key: _kLastElapsedSec);
    final level = await FlutterForegroundTask.getData(key: _kLastLevel);
    final paused = await FlutterForegroundTask.getData(key: _kLastPaused);

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

  // ✅ parse textbox: 0 or invalid => null
  int? _parseTargetSpeakers() {
    final raw = _targetSpeakersCtrl.text.trim();
    if (raw.isEmpty) return null;

    final n = int.tryParse(raw);
    if (n == null) return null;

    if (n <= 0) return null; // 0 => null(auto)

    return n.clamp(1, 12);
  }

  Future<void> _start() async {
    if (_recording || _starting) return;

    try {
      _handledStop = false;

      final int? targetSpeakers = _parseTargetSpeakers();

      await _ensureMic();

      setState(() {
        _starting = true;
        _seconds = 0.0;
        _level = 0.0;
      });

      final path =
          await RecordingService.start(targetSpeakers: targetSpeakers);
      if (path == null) {
        setState(() => _starting = false);
        if (!mounted) return;
        await AppFlushbar.error(context, message: 'Couldn’t start recording.');
        return;
      }

      setState(() {
        _recording = true;
        _paused = false;
      });
    } catch (e) {
      setState(() => _starting = false);
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Failed to start recording: $e');
    }
  }

  Future<void> _pause() async {
    if (!_recording || _paused) return;
    try {
      RecordingService.pause();
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
      setState(() => _paused = false);
    } catch (_) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Failed to resume recording');
    }
  }

  Future<void> _stop() async {
    if (!_recording) return;

    try {
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
  }) async {
    final placeholderDuration =
        (_seconds.isFinite && _seconds >= 0) ? _seconds : 0.0;

    final obx = ObjectBox.I;

    final tId = obx.transcripts.put(
      TranscriptEntity(
        title: '',
        model: 'whisper',
        lang: 'auto',
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
      await FlutterForegroundTask.saveData(key: _kBusyTranscribing, value: false);

      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Processing Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height * 0.70;
    final title = _recording
        ? (_paused ? 'Paused' : (_starting ? 'Starting…' : 'Recording…'))
        : 'Record';

    return SizedBox(
      height: h,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.mic, color: Color(0xFFCD66FD)),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Card(
              elevation: 0.6,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _fmtTime(_seconds),
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    LevelBars(level: _level, height: 16, barCount: 20),

                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Target speakers (0 = auto)',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 110,
                          child: TextField(
                            controller: _targetSpeakersCtrl,
                            enabled: !_recording && !_starting,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            decoration: const InputDecoration(
                              hintText: '0',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'If you’re unsure, keep 0. We treat 0 as auto-detect (null).',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ),

                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton.icon(
                          onPressed: _recording ? _cancel : null,
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: (!_recording || _starting)
                              ? null
                              : (_paused ? _resume : _pause),
                          icon: Icon(
                            _paused
                                ? Icons.play_circle_fill
                                : Icons.pause_circle_filled,
                          ),
                          label: Text(_paused ? 'Resume' : 'Pause'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: _recording ? _stop : _start,
                          icon: Icon(
                            _recording
                                ? Icons.stop_circle
                                : Icons.fiber_manual_record,
                          ),
                          label: Text(_recording ? 'Stop' : 'Start'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Tip: hold the phone close and speak clearly. You can rename speakers later in the transcript view.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
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

class LevelBars extends StatelessWidget {
  const LevelBars({
    super.key,
    required this.level,
    this.height = 16,
    this.barCount = 16,
  });

  final double level; // 0.0 - 1.0
  final double height;
  final int barCount;

  @override
  Widget build(BuildContext context) {
    final weights = List<double>.generate(barCount, (i) {
      final x = (i / (barCount - 1)) * 2 - 1; // -1..1
      final bell = 1 - (x * x); // 0..1
      return 0.4 + 0.6 * bell; // 0.4..1.0
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
              final barH =
                  (height * weights[i] * (0.2 + 0.8 * v)).clamp(2.0, height);
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: Container(
                    height: barH,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.9),
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
