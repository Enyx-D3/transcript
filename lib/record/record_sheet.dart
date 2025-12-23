// lib/record/record_sheet.dart
import 'dart:async';
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
    final v = await FlutterForegroundTask.getData(key: kBusyTranscribing);
    final busy = v == true;

    if (busy) {
      if (!context.mounted) return;
      await AppFlushbar.success(
        context,
        message: 'Transcription in progress… Please wait.',
      );
      return;
    }

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

  double _seconds = 0.0;
  Timer? _ticker;
  Timer? _startDelayTimer;
  double _level = 0.0;
  late final void Function(Object) _fgListener;

  @override
  void initState() {
    super.initState();
    _fgListener = (Object data) {
      if (!mounted) return;
      if (data is Map && data['type'] == 'tick') {
        final lv = (data['level'] as num?)?.toDouble();
        if (lv != null) setState(() => _level = lv.clamp(0.0, 1.0));
        final sec = (data['elapsedSec'] as num?)?.toDouble();
        if (sec != null) setState(() => _seconds = sec);
      }
    };
    RecordingService.addListener(_fgListener);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _startDelayTimer?.cancel();
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

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_recording && !_paused) {
        setState(() => _seconds += 1);
      }
    });
  }

  Future<void> _start() async {
    if (_recording) return;
    try {
      await _ensureMic();

      setState(() {
        _starting = true;
        _seconds = 0.0;
      });

      final path = await RecordingService.start();
      if (path == null) {
        debugPrint("HERE IS THE PROBLEM");
        setState(() => _starting = false);
        if (!mounted) return;
        await AppFlushbar.error(context, message: 'Couldn’t start recording.');
        return;
      }

      setState(() {
        _recording = true;
        _paused = false;
      });

      _startDelayTimer?.cancel();
      _startDelayTimer = Timer(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        if (_recording && !_paused) {
          _startTicker();
        }
        setState(() => _starting = false);
      });
    } catch (e) {
      setState(() => _starting = false);
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Filed to Start Recording, $e');
    }
  }

  Future<void> _pause() async {
    if (!_recording || _paused) return;
    try {
      RecordingService.pause();
      setState(() => _paused = true);
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Failed to Pause Recording');
    }
  }

  Future<void> _resume() async {
    if (!_recording || !_paused) return;
    try {
      RecordingService.resume();
      setState(() => _paused = false);
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Failed to Resuming Recording');
    }
  }

  Future<void> _stop() async {
    if (!_recording) return;
    try {
      _startDelayTimer?.cancel();
      _ticker?.cancel();
      setState(() {
        _recording = false;
        _paused = false;
      });

      final wavPath = await RecordingService.stop();
      if (wavPath == null) {
        if (!mounted) return;
        await AppFlushbar.error(context, message: 'Failed to Stop Recording');
        return;
      }

      final placeholderDuration = _seconds.isFinite && _seconds >= 0
          ? _seconds
          : 0.0;

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

      if (!mounted) return;
      Navigator.of(context).pop(); // close sheet
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TranscriptDetailPage(transcriptId: tId),
        ),
      );

      // Kick off background transcribe (non-blocking – all heavy work in BG isolate).
      try {
        await BackgroundTranscriber.start(
          wavPath: wavPath,
          translateToEnglish: false,
          titleHint: null,
          existingTranscriptId: tId,
        );
      } catch (e) {
        if (!mounted) return;
        await AppFlushbar.error(context, message: 'Processing Error');
      }
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Processing Error');
    }
  }

  Future<void> _cancel() async {
    try {
      _startDelayTimer?.cancel();
      _ticker?.cancel();
      final p = await RecordingService.stop(); // stop and discard
      setState(() {
        _recording = false;
        _paused = false;
        _seconds = 0.0;
      });
      if (p != null) {
        try {
          File(p).deleteSync();
        } catch (_) {}
      }
      if (!mounted) return;
      await AppFlushbar.success(context, message: 'Recording Cancelled');
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Failed to Stop Recording');
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

  // Future<void> _snack(String msg) async {
  //   if (!mounted) return;
  //   await AppFlushbar.error(context, message:  msg);
  // }
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
      duration: const Duration(milliseconds: 500),
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
                      color: Colors.white.withOpacity(0.9),
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
