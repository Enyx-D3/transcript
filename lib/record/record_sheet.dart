import 'dart:io';
import 'package:flutter/material.dart';
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
          _starting = false;
        });
        return;
      }

      if (type == 'limit_reached') {
        // Just informational. The actual stop event will arrive as 'stopped'.
        await AppFlushbar.info(
          context,
          message: 'Recording limit reached. Stopping…',
        );
        return;
      }

      // ✅ This fires both for manual stop and auto-stop (limit reached)
      if (type == 'stopped') {
        if (_handledStop) return;
        _handledStop = true;

        final fp = data['filePath'];
        final wavPath = fp is String ? fp : null;

        setState(() {
          _recording = false;
          _paused = false;
          _starting = false;
        });

        if (wavPath == null || wavPath.trim().isEmpty) {
          await AppFlushbar.error(context, message: 'Recording file missing.');
          return;
        }

        // ✅ Create transcript + job + navigate (same as your manual _stop flow)
        await _createTranscriptAndStartTranscription(wavPath: wavPath);
      }
    };

    RecordingService.addListener(_fgListener);
  }

  @override
  void dispose() {
    RecordingService.removeListener(_fgListener);
    super.dispose();
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

  Future<void> _start() async {
    if (_recording || _starting) return;

    try {
      _handledStop = false;

      await _ensureMic();

      setState(() {
        _starting = true;
        _seconds = 0.0;
        _level = 0.0;
      });

      final path = await RecordingService.start();
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

  // Manual stop just requests stop; actual handling is in 'stopped' event above.
  Future<void> _stop() async {
    if (!_recording) return;

    try {
      setState(() {
        _recording = false;
        _paused = false;
      });

      await RecordingService.stop();
      // ✅ do NOT navigate here anymore (avoid duplicates)
      // Navigation happens when we receive the 'stopped' callback with filePath.
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Failed to stop recording: $e');
    }
  }

  Future<void> _cancel() async {
    try {
      _handledStop = true; // prevent auto handler if any late events arrive

      final p = await RecordingService.stop(); // stop and discard

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
  }) async {
    final placeholderDuration =
        (_seconds.isFinite && _seconds >= 0) ? _seconds : 0.0;

    final obx = ObjectBox.I;

    // 1) Create transcript placeholder
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

    // 2) Create job row
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

    // 3) Mark busy immediately
    await FlutterForegroundTask.saveData(key: _kBusyTranscribing, value: true);

    if (!mounted) return;

    // close sheet then open transcript detail
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TranscriptDetailPage(transcriptId: tId),
      ),
    );

    // 4) start background transcriber
    try {
      await BackgroundTranscriber.start(
        wavPath: wavPath,
        translateToEnglish: false,
        titleHint: null,
        existingTranscriptId: tId,
      );

      // mark job running
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

// keep your LevelBars as-is
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
