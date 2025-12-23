// lib/onboarding/enroll_flow.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:transcript/common/app_flushbar.dart';
import 'package:transcript/tabs/timeline_tab.dart';

import '../mic_recorder.dart';
import '../audio_preprocess.dart';
import '../speaker_embedding.dart';
import '../speaker_memory.dart';
import '../model_bootstrap.dart';
import '../audio_utils.dart';
import 'enroll_prompts.dart';

class EnrollmentFlowPage extends StatefulWidget {
  final List<EnrollmentPrompt> prompts;
  const EnrollmentFlowPage({super.key, List<EnrollmentPrompt>? prompts})
    : prompts = prompts ?? kDefaultEnrollmentPrompts;

  @override
  State<EnrollmentFlowPage> createState() => _EnrollmentFlowPageState();
}

class _EnrollmentFlowPageState extends State<EnrollmentFlowPage> {
  final _rec = MicRecorder();
  final _player = AudioPlayer()..setReleaseMode(ReleaseMode.stop);

  int _index = 0;
  bool _busy = false;
  bool _recording = false;
  double _seconds = 0.0;
  Timer? _ticker;

  // 🔊 playback state
  bool _playingGuide = false;
  bool _playingUser = false;

  /// One vector per prompt (mean-pooled windows). We keep them separate → multi-prototype.
  final List<Float32List?> _vectors = [];

  /// Cleaned .wav per prompt (previewable & can delete)
  final List<String?> _clips = [];

  final _nameCtrl = TextEditingController(text: '');

  @override
  void initState() {
    super.initState();
    _vectors.length = widget.prompts.length;
    _clips.length = widget.prompts.length;

    // Keep UI in sync with player
    _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _playingGuide = false;
        _playingUser = false;
      });
    });
    _player.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      if (s == PlayerState.playing) return;
      if (s == PlayerState.paused || s == PlayerState.stopped) {
        setState(() {
          _playingGuide = false;
          _playingUser = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _player.stop();
    _player.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _ensureMic() async {
    final st = await Permission.microphone.status;
    if (st.isDenied || st.isPermanentlyDenied) {
      final g = await Permission.microphone.request();
      if (!g.isGranted) throw Exception('Microphone permission is required');
    }
  }

  // ---------- Recording ----------

  Future<void> _onHoldStart() async {
    if (_busy) return;
    try {
      await _ensureMic();

      // Stop any playback while recording
      await _stopPlayback();

      // Use your MicRecorder API that writes to a known path
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/enroll_${widget.prompts[_index].id}.wav';
      await _rec.startToPath(path); // ✅ you said this exists

      setState(() {
        _recording = true;
        _seconds = 0.0;
      });
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!mounted || !_recording) return;
        setState(() => _seconds += 0.1);
      });
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Error Recording');
    }
  }

  Future<void> _onHoldEnd() async {
    if (!_recording) return;
    try {
      final wav = await _rec.stop();
      _ticker?.cancel();
      if (!mounted) return;
      setState(() => _recording = false);
      if (wav == null) return;

      final minSec = widget.prompts[_index].minSec;
      if (_seconds + 0.05 < minSec) {
        try {
          File(wav).deleteSync();
        } catch (_) {}
         await AppFlushbar.error(context, message: 'Please record at least ${minSec.toStringAsFixed(1)}s');
        return;
      }

      await _processClip(wav);
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Error Stopping Recording');
    }
  }

  Future<void> _cancelRecording() async {
    await _rec.cancel();
    _ticker?.cancel();
    if (!mounted) return;
    setState(() {
      _recording = false;
      _seconds = 0.0;
    });
   await AppFlushbar.success(context, message: 'Recording Cancelled');
  }

  Future<void> _processClip(String wavPath) async {
    setState(() => _busy = true);
    try {
      // 1) same preprocessing as runtime (consistency!)
      final cleaned = await preprocessWav16kMono(wavPath);

      // 2) embedding windows over this clip, then mean-pool
      final mp = await ensureDiarizationModels(); // gives embOnnx
      final embedder = await SpeakerEmbedder.instance(mp.embOnnx);

      final dur = await readWavDuration(cleaned);
      const window = 2.0;
      final parts = <Float32List>[];
      double pos = 0.0;

      while (pos < dur) {
        final end = (pos + window <= dur) ? pos + window : dur;
        final take = end - pos;
        if (take < 0.5) break; // too tiny
        final v = await embedder.embedFromWav(
          cleaned,
          startSec: pos,
          endSec: end,
        );
        if (v.isNotEmpty) parts.add(v);
        pos += window;
        if (parts.length >= 4) break; // cap windows per prompt
      }

      if (parts.isEmpty) {
        if (!mounted) return;
        await AppFlushbar.error(context, message: 'Could not extract voice features. Please re-record.');
        return;
      }

      final centroid = embedder.meanPool(parts);
      _vectors[_index] = centroid;
      _clips[_index] = cleaned;

      setState(() {}); // refresh UI
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Processing Failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reRecord() async {
    if (_busy) return;
    final old = _clips[_index];
    _vectors[_index] = null;
    _clips[_index] = null;
    if (old != null) {
      try {
        File(old).deleteSync();
      } catch (_) {}
    }
    setState(() {});
  }

  Future<void> _next() async {
    if (_busy) return;
    if (_vectors[_index] == null) {
      await AppFlushbar.error(context, message: 'Please record this step first.');
      return;
    }
    if (_index + 1 < widget.prompts.length) {
      setState(() => _index++);
      await _stopPlayback(); // stop when switching steps
    } else {
      await _askAndSaveName();
    }
  }

  Future<void> _askAndSaveName() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(
          controller: _nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Display name (e.g., Alex)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _nameCtrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;

    setState(() => _busy = true);
    try {
      final mem = await SpeakerMemory.instance();
      for (final v in _vectors) {
        if (v != null && v.isNotEmpty) {
          await mem.enrollAppend(name: name, embedding: v);
        }
      }
      if (!mounted) return;
      await AppFlushbar.success(context, message:  'Voice enrolled for $name');
      await _stopPlayback();

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => TimelineTab(onNavigateToTab: (int tabIndex) {  },)),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
       await AppFlushbar.error(context, message:  'Save failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- 🔊 Playback helpers ----------

  bool _isUrl(String s) => s.startsWith('http://') || s.startsWith('https://');

  Future<void> _stopPlayback() async {
    _playingGuide = false;
    _playingUser = false;
    try {
      await _player.stop();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  /// Plays either an asset (e.g. assets/guides/neutral.mp3) or a remote URL.
  Future<void> _togglePlayGuide() async {
    final src = widget.prompts[_index].audioAsset;
    if (src == null) return;

    // if already playing, stop
    if (_playingGuide) {
      await _stopPlayback();
      return;
    }

    // switching sources → stop first
    await _stopPlayback();

    try {
      if (_isUrl(src)) {
        await _player.play(UrlSource(src));
      } else {
        // treat anything else as an asset path inside your Flutter assets
        // (ensure it's listed under `flutter: assets:` in pubspec.yaml)
        await _player.play(AssetSource(src));
      }
      if (!mounted) return;
      setState(() => _playingGuide = true);
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message:  'Could not play guide');
    }
  }

  /// Plays back the user’s own cleaned recording (local file).
  Future<void> _togglePlayMyRecording() async {
    final clip = _clips[_index];
    if (clip == null || !File(clip).existsSync()) {
      await AppFlushbar.error(context, message:  'No recording for this step yet.');
      return;
    }

    if (_playingUser) {
      await _stopPlayback();
      return;
    }

    await _stopPlayback();

    try {
      await _player.play(DeviceFileSource(clip));
      if (!mounted) return;
      setState(() => _playingUser = true);
    } catch (e) {
      if (!mounted) return;
        await AppFlushbar.error(context, message:  'Could not play your recording');
    }
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final p = widget.prompts[_index];
    final done = _vectors[_index] != null;

    return Scaffold(
      appBar: AppBar(
        title: Text('Voice Setup (${_index + 1}/${widget.prompts.length})'),
        actions: [
          IconButton(
            tooltip: 'Stop audio',
            onPressed: _playingGuide || _playingUser ? _stopPlayback : null,
            icon: const Icon(Icons.stop_circle_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _stepHeader(p),
              const SizedBox(height: 16),
              _scriptCard(p),
              const Spacer(),
              if (_recording) _recordingHint(p.minSec),
              const SizedBox(height: 8),
              _recordButton(done),
              const SizedBox(height: 8),
              Row(
                children: [
                  // Left: three options in a single, scrollable row
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _smallActionButton(
                            icon: Icons.replay,
                            label: 'Re-record',
                            onPressed: (!done || _busy) ? null : _reRecord,
                          ),
                          const SizedBox(width: 8),
                          _smallActionButton(
                            icon: _playingGuide
                                ? Icons.pause_circle_filled
                                : Icons.volume_up,
                            label: _playingGuide ? 'Stop guide' : 'Play guide',
                            onPressed: (p.audioAsset == null || _busy)
                                ? null
                                : _togglePlayGuide,
                          ),
                          const SizedBox(width: 8),
                          _smallActionButton(
                            icon: _playingUser
                                ? Icons.pause_circle_filled
                                : Icons.graphic_eq,
                            label: _playingUser
                                ? 'Stop my clip'
                                : 'Play my clip',
                            onPressed: (_clips[_index] == null || _busy)
                                ? null
                                : _togglePlayMyRecording,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Right: primary action
                  FilledButton.icon(
                    onPressed: _busy ? null : _next,
                    icon: Icon(
                      _index + 1 < widget.prompts.length
                          ? Icons.arrow_forward
                          : Icons.check,
                    ),
                    label: Text(
                      _index + 1 < widget.prompts.length ? 'Next' : 'Finish',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _smallActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label, overflow: TextOverflow.ellipsis),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 40), // reduce horizontal footprint
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Widget _stepHeader(EnrollmentPrompt p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          p.title,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(p.subtitle, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }

  Widget _scriptCard(EnrollmentPrompt p) {
    final done = _vectors[_index] != null;
    return Card(
      elevation: 0.6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              done ? Icons.check_circle : Icons.info,
              color: done ? Colors.greenAccent : Colors.amber,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Say this',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    p.script,
                    style: const TextStyle(fontSize: 16, height: 1.35),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Minimum ${p.minSec.toStringAsFixed(1)} seconds.',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  if (p.audioAsset != null) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Tip: Tap “Play guide” to hear an example.',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recordButton(bool done) {
    final glow = _recording ? 1.0 : 0.0;
    return GestureDetector(
      onLongPressStart: (_) => _onHoldStart(),
      onLongPressEnd: (_) => _onHoldEnd(),
      onLongPressCancel: _cancelRecording,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 72,
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A22),
          borderRadius: BorderRadius.circular(20),
          boxShadow: glow > 0
              ? [
                  BoxShadow(
                    color: const Color(
                      0xFF8E7CFF,
                    ).withValues(alpha: _recording ? 0.45 : 0.0),
                    blurRadius: 24,
                    spreadRadius: 1,
                  ),
                ]
              : [],
          border: Border.all(
            color: const Color(
              0xFF8E7CFF,
            ).withValues(alpha: _recording ? 0.9 : 0.3),
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
                _recording
                    ? 'Recording… release to finish'
                    : (done ? 'Recorded — hold to replace' : 'Hold to record'),
                style: const TextStyle(fontSize: 16),
              ),
              if (_recording) ...[
                const SizedBox(width: 12),
                Text(_fmt(_seconds), style: const TextStyle(fontFeatures: [])),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _recordingHint(double minSec) {
    final need = (minSec - _seconds).clamp(0.0, 999.0);
    return Align(
      alignment: Alignment.center,
      child: Text(
        need > 0.05
            ? 'Keep holding… ${need.toStringAsFixed(1)}s more'
            : 'Good! You can release now.',
        style: const TextStyle(color: Colors.white70),
      ),
    );
  }
}

// void _toast(BuildContext ctx, String msg) {
//   ScaffoldMessenger.of(ctx).hideCurrentSnackBar();
//   ScaffoldMessenger.of(ctx).showSnackBar(
//     SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
//   );
// }

String _fmt(double s) {
  final mm = (s ~/ 60).toString().padLeft(2, '0');
  final ss = (s % 60).toStringAsFixed(1).padLeft(4, '0');
  return '$mm:$ss';
}
