import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'mic_recorder.dart';
import 'whisper_service.dart';
import 'diarizer_service.dart';
import 'audio_utils.dart';
import 'main.dart' show whisper, diarizer;

class TranscribePage extends StatefulWidget {
  const TranscribePage({super.key});

  @override
  State<TranscribePage> createState() => _TranscribePageState();
}

class _TranscribePageState extends State<TranscribePage> {
  final _rec = MicRecorder();

  bool _recording = false;
  bool _busy = false;
  bool _translate = false;
  String? _lastAudioPath;
  String _transcript = '';
  List<SpeakerTurn> _turns = const [];

  @override
  void initState() {
    super.initState();
    if (!whisper.isReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _toast(context, 'Whisper not initialized');
      });
    }
  }

  Future<void> _ensureMic() async {
    final status = await Permission.microphone.status;
    if (status.isDenied || status.isPermanentlyDenied) {
      final granted = await Permission.microphone.request();
      if (!granted.isGranted) {
        throw Exception('Microphone permission is required');
      }
    }
  }

  Future<void> _onHoldStart() async {
    try {
      await _ensureMic();
      final path = await _rec.start();
      if (!mounted) return;
      setState(() {
        _recording = true;
        _lastAudioPath = path;
      });
      _toast(context, 'Recording… release to transcribe');
    } catch (e) {
      if (!mounted) return;
      _toast(context, e.toString());
    }
  }

  Future<void> _onHoldEnd() async {
    try {
      final path = await _rec.stop();
      if (!mounted) return;
      setState(() => _recording = false);
      if (path == null) return;
      await _transcribe(path);
    } catch (e) {
      if (!mounted) return;
      _toast(context, e.toString());
    }
  }

  Future<void> _cancelRecording() async {
    await _rec.cancel();
    if (!mounted) return;
    setState(() => _recording = false);
    _toast(context, 'Canceled');
  }

  Future<void> _transcribe(String wavPath) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _transcript = '';
      _turns = const [];
    });

    try {
      // 1) dynamic diarization (no hard-coded speakers)
      final turns = diarizer.isReady
          ? await diarizer.diarizeFile(
              wavPath,
              minSegDur: 0.40,
              minorMinSec: 1.00,
              minorMaxShare: 0.08,
            )
          : const <SpeakerTurn>[];

      // 2) fallback → single S1 over full duration
      if (turns.isEmpty) {
        final full = await whisper.transcribeWav(
          wavPath: wavPath,
          translateToEnglish: _translate,
          noTimestamps: false,
          splitOnWord: true,
          diarize: false,
        );
        final dur = await readWavDuration(wavPath);
        final line = 's1: ${full.trim()} : 0.00–${dur.toStringAsFixed(2)}s';
        if (!mounted) return;
        setState(() {
          _turns = const [];
          _transcript = line;
        });
        return;
      }

      // 3) per-turn slice + transcribe → "sX: text : start–end"
      final tmp = await getTemporaryDirectory();
      final lines = <String>[];

      for (int i = 0; i < turns.length; i++) {
        final t = turns[i];
        final out = '${tmp.path}/slice_$i.wav';

        await trimWav16kMonoPcm(
          inputPath: wavPath,
          startSec: t.startSec,
          endSec: t.endSec,
          outputPath: out,
        );

        final text = await whisper.transcribeWav(
          wavPath: out,
          translateToEnglish: _translate,
          noTimestamps: false,
          splitOnWord: true,
          diarize: false,
        );

        final spk = t.speaker.toLowerCase(); // s1, s2, ...
        lines.add('$spk: ${text.trim()} : '
            '${t.startSec.toStringAsFixed(2)}–${t.endSec.toStringAsFixed(2)}s');

        try { File(out).deleteSync(); } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _turns = turns;
        _transcript = lines.join('\n');
      });
    } catch (e) {
      if (!mounted) return;
      _toast(context, 'Transcription failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearTranscript() async {
    setState(() {
      _transcript = '';
      _turns = const [];
    });
  }

  Future<void> _openFolder() async {
    final dir = await getApplicationDocumentsDirectory();
    if (!mounted) return;
    _toast(context, 'Audio folder: ${dir.path}');
  }

  @override
  Widget build(BuildContext context) {
    final micGlow = _recording ? 1.0 : 0.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Speech → Text (whisper.cpp + diarization)'),
        actions: [
          Row(
            children: [
              const Text('Translate to English'),
              Switch(
                value: _translate,
                onChanged: _busy ? null : (v) => setState(() => _translate = v),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: _card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header('Output'),
                    const SizedBox(height: 8),
                    if (_busy) const LinearProgressIndicator(minHeight: 3),
                    if (!_busy && _transcript.isEmpty)
                      const Text('No transcript yet. Hold the mic to speak.',
                          style: TextStyle(color: Colors.white70)),
                    if (_transcript.isNotEmpty)
                      SelectableText(
                        _transcript,
                        style: const TextStyle(fontSize: 16, height: 1.35),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: _transcript.isEmpty && _turns.isEmpty ? null : _clearTranscript,
                          icon: const Icon(Icons.clear),
                          label: const Text('Clear'),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: _openFolder,
                          icon: const Icon(Icons.folder_open),
                          label: const Text('Audio folder'),
                        ),
                      ],
                    )
                  ],
                ),
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: GestureDetector(
                onLongPressStart: (_) => _onHoldStart(),
                onLongPressEnd: (_) => _onHoldEnd(),
                onLongPressCancel: _cancelRecording,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  height: 72,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A22),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: micGlow > 0
                        ? [
                            BoxShadow(
                              color: const Color(0xFF8E7CFF).withValues(alpha: 0.45),
                              blurRadius: 24,
                              spreadRadius: 1,
                            )
                          ]
                        : [],
                    border: Border.all(
                      color: const Color(0xFF8E7CFF).withValues(alpha: _recording ? 0.9 : 0.3),
                      width: 1.4,
                    ),
                  ),
                  child: Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _recording ? Icons.mic_rounded : Icons.mic_none_rounded,
                          size: 28,
                          color: const Color(0xFF8E7CFF),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _recording ? 'Listening… release to transcribe' : 'Hold to speak',
                          style: const TextStyle(fontSize: 16),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card({required Widget child}) => Card(
        elevation: 0.6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      );

  Widget _header(String text) => Text(
        text,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14,
          color: Colors.white70,
          letterSpacing: 0.2,
        ),
      );
}

void _toast(BuildContext ctx, String msg) {
  ScaffoldMessenger.of(ctx).hideCurrentSnackBar();
  ScaffoldMessenger.of(ctx).showSnackBar(
    SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
  );
}
