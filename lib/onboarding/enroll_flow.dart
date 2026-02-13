// lib/onboarding/enroll_flow.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:transcript/common/app_flushbar.dart';
import 'package:transcript/main.dart';

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

  bool _playingGuide = false;
  bool _playingUser = false;

  final List<Float32List?> _vectors = [];
  final List<String?> _clips = [];

  final _nameCtrl = TextEditingController(text: '');

  @override
  void initState() {
    super.initState();
    _vectors.length = widget.prompts.length;
    _clips.length = widget.prompts.length;

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
      await _stopPlayback();

      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/enroll_${widget.prompts[_index].id}.wav';
      await _rec.startToPath(path);

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
        await AppFlushbar.error(
          context,
          message: 'Please record at least ${minSec.toStringAsFixed(1)}s',
        );
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
      final cleaned = await preprocessWav16kMono(wavPath);

      final mp = await ensureDiarizationModels();
      final embedder = await SpeakerEmbedder.instance(mp.embOnnx);

      final dur = await readWavDuration(cleaned);
      const window = 2.0;
      final parts = <Float32List>[];
      double pos = 0.0;

      while (pos < dur) {
        final end = (pos + window <= dur) ? pos + window : dur;
        final take = end - pos;
        if (take < 0.5) break;
        final v = await embedder.embedFromWav(
          cleaned,
          startSec: pos,
          endSec: end,
        );
        if (v.isNotEmpty) parts.add(v);
        pos += window;
        if (parts.length >= 4) break;
      }

      if (parts.isEmpty) {
        if (!mounted) return;
        await AppFlushbar.error(
          context,
          message: 'Could not extract voice features. Please re-record.',
        );
        return;
      }

      final centroid = embedder.meanPool(parts);
      _vectors[_index] = centroid;
      _clips[_index] = cleaned;

      setState(() {});
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
      await _stopPlayback();
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
      await AppFlushbar.success(context, message: 'Voice enrolled for $name');
      await _stopPlayback();

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const SplashGate()),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Save failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- Playback helpers ----------

  bool _isUrl(String s) => s.startsWith('http://') || s.startsWith('https://');

  Future<void> _stopPlayback() async {
    _playingGuide = false;
    _playingUser = false;
    try {
      await _player.stop();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _togglePlayGuide() async {
    final src = widget.prompts[_index].audioAsset;
    if (src == null) return;

    if (_playingGuide) {
      await _stopPlayback();
      return;
    }

    await _stopPlayback();

    try {
      if (_isUrl(src)) {
        await _player.play(UrlSource(src));
      } else {
        await _player.play(AssetSource(src));
      }
      if (!mounted) return;
      setState(() => _playingGuide = true);
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Could not play guide');
    }
  }

  Future<void> _togglePlayMyRecording() async {
    final clip = _clips[_index];
    if (clip == null || !File(clip).existsSync()) {
      await AppFlushbar.error(context, message: 'No recording for this step yet.');
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
      await AppFlushbar.error(context, message: 'Could not play your recording');
    }
  }

  // ---------- UI helpers ----------
  BoxDecoration _panelDecoration(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg = isDark ? const Color(0xFF101018) : theme.colorScheme.surface;
    final border = isDark ? Colors.white.withOpacity(0.10) : Colors.black.withOpacity(0.08);

    return BoxDecoration(
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final p = widget.prompts[_index];
    final done = _vectors[_index] != null;
    final progress = (widget.prompts.length <= 1)
        ? 1.0
        : (_index / (widget.prompts.length - 1)).clamp(0.0, 1.0);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---------- Header ----------
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Voice setup',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Step ${_index + 1} of ${widget.prompts.length}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: isDark ? Colors.white70 : Colors.black54,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _IconPillButton(
                    tooltip: 'Stop audio',
                    icon: Icons.stop_circle_outlined,
                    onTap: (_playingGuide || _playingUser) ? _stopPlayback : null,
                  ),
                  const SizedBox(width: 8),
                  _IconPillButton(
                    tooltip: 'Close',
                    icon: Icons.close,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ),

              const SizedBox(height: 10),

              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  value: progress,
                  color: Color(0xFFff8143),
                  backgroundColor: Colors.white,
                ),
              ),

              const SizedBox(height: 12),

              // ---------- Prompt panel ----------
              Container(
                decoration: _panelDecoration(context),
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _StatusChip(
                          label: done ? 'Recorded' : 'Not recorded',
                          tone: done ? _ChipTone.good : _ChipTone.neutral,
                        ),
                        const SizedBox(width: 8),
                        _StatusChip(
                          label: 'Min ${p.minSec.toStringAsFixed(1)}s',
                          tone: _ChipTone.neutral,
                        ),
                        const Spacer(),
                        Text(
                          p.title,
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      p.subtitle,
                      style: TextStyle(
                        color: isDark ? Colors.white70 : Colors.black54,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: (isDark ? Colors.white : Colors.black).withOpacity(0.04),
                        border: Border.all(
                          color: (isDark ? Colors.white : Colors.black).withOpacity(0.08),
                        ),
                      ),
                      child: Text(
                        p.script,
                        style: const TextStyle(fontSize: 16, height: 1.35, fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (p.audioAsset != null) ...[
                      const SizedBox(height: 10),
                      const Text(
                        'Tip: use “Play guide” to hear an example.',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // ---------- Record panel ----------
              Expanded(
                child: Container(
                  decoration: _panelDecoration(context),
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          // const Icon(Icons.mic, color: Color(0xFF8E7CFF)),
                          // const SizedBox(width: 8),
                          // const Text(
                          //   'Recording',
                          //   style: TextStyle(fontWeight: FontWeight.w900),
                          // ),
                          const Spacer(),
                          if (_recording)
                            _StatusChip(
                              label: _fmt(_seconds),
                              tone: _ChipTone.neutral,
                            ),
                          if (_busy) ...[
                            const SizedBox(width: 10),
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ]
                        ],
                      ),
                      const SizedBox(height: 10),

                      if (_recording) _recordingHint(p.minSec),

                      const Spacer(),

                      _recordButton(done),

                      const SizedBox(height: 12),

                      // Tools row (no overflow)
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _toolButton(
                              icon: Icons.replay,
                              label: 'Re-record',
                              onPressed: (!done || _busy) ? null : _reRecord,
                            ),
                            const SizedBox(width: 8),
                            _toolButton(
                              icon: _playingGuide ? Icons.pause_circle_filled : Icons.volume_up,
                              label: _playingGuide ? 'Stop guide' : 'Play guide',
                              onPressed: (p.audioAsset == null || _busy) ? null : _togglePlayGuide,
                            ),
                            const SizedBox(width: 8),
                            _toolButton(
                              icon: _playingUser ? Icons.pause_circle_filled : Icons.graphic_eq,
                              label: _playingUser ? 'Stop my clip' : 'Play my clip',
                              onPressed: (_clips[_index] == null || _busy) ? null : _togglePlayMyRecording,
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      // Primary action
                      SizedBox(
                        height: 46,
                        child: FilledButton.icon(
                          onPressed: _busy ? null : _next,
                          icon: Icon(
                            _index + 1 < widget.prompts.length ? Icons.arrow_forward : Icons.check,
                          ),
                          label: Text(
                            _index + 1 < widget.prompts.length ? 'Next step' : 'Finish setup',
                          ),
                          style: OutlinedButton.styleFrom(
                            backgroundColor: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18,color: Colors.white),
      label: Text(label,style: TextStyle(color: Colors.white),),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Widget _recordButton(bool done) {
    return GestureDetector(
      onLongPressStart: (_) => _onHoldStart(),
      onLongPressEnd: (_) => _onHoldEnd(),
      onLongPressCancel: _cancelRecording,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 78,
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A22),
          borderRadius: BorderRadius.circular(20),
          boxShadow: _recording
              ? [
                  BoxShadow(
                    color: const Color(0xFFff8143).withOpacity(0.45),
                    blurRadius: 26,
                    spreadRadius: 1,
                  ),
                ]
              : [],
          border: Border.all(
            color: Colors.white.withOpacity(_recording ? 1 : 0.30),
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
                color: Colors.white,
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  _recording
                      ? 'Recording… release to finish'
                      : (done ? 'Recorded — hold to replace' : 'Hold to record'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
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
        need > 0.05 ? 'Keep holding… ${need.toStringAsFixed(1)}s more' : 'Good! You can release now.',
        style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _IconPillButton extends StatelessWidget {
  const _IconPillButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: (isDark ? Colors.white : Colors.black).withOpacity(0.06),
          border: Border.all(
            color: (isDark ? Colors.white : Colors.black).withOpacity(0.10),
          ),
        ),
        child: Tooltip(
          message: tooltip,
          child: Icon(icon, color: onTap == null ? Colors.white38 : null),
        ),
      ),
    );
  }
}

enum _ChipTone { neutral, good, bad }

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.tone});
  final String label;
  final _ChipTone tone;

  @override
  Widget build(BuildContext context) {
    Color? c;
    if (tone == _ChipTone.good) c = Colors.black;
    if (tone == _ChipTone.bad) c = Colors.redAccent;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: (c ?? Colors.black),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color:Colors.white.withOpacity(0.45)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
          color: Colors.white70,
        ),
      ),
    );
  }
}

String _fmt(double s) {
  final mm = (s ~/ 60).toString().padLeft(2, '0');
  final ss = (s % 60).toStringAsFixed(1).padLeft(4, '0');
  return '$mm:$ss';
}
