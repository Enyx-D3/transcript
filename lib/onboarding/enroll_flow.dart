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

import 'mic_recorder.dart';
import '../audio_preprocess.dart';
import '../speaker_embedding.dart';
import '../debug/speaker_memory.dart';
import '../model_bootstrap.dart';
import '../audio_utils.dart';
import 'enroll_prompts.dart';

// ✅ Glass primitives
import '../ui/glass/glass_background.dart';
import '../ui/glass/glass_button.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/glass_tokens.dart';
import '../ui/glass/liquid_glass.dart';

// ✅ Use this for the close (X) button
import '../widgets/icon_pill_button.dart';

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
    } catch (_) {
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
    } catch (_) {
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

      if (mounted) setState(() {});
    } catch (_) {
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
    if (mounted) setState(() {});
  }

  Future<void> _next() async {
    if (_busy) return;
    if (_vectors[_index] == null) {
      await AppFlushbar.error(
        context,
        message: 'Please record this step first.',
      );
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
      builder: (ctx) => _GlassNameDialog(controller: _nameCtrl, busy: _busy),
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
    } catch (_) {
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
    } catch (_) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Could not play guide');
    }
  }

  Future<void> _togglePlayMyRecording() async {
    final clip = _clips[_index];
    if (clip == null || !File(clip).existsSync()) {
      await AppFlushbar.error(
        context,
        message: 'No recording for this step yet.',
      );
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
    } catch (_) {
      if (!mounted) return;
      await AppFlushbar.error(
        context,
        message: 'Could not play your recording',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final p = widget.prompts[_index];
    final done = _vectors[_index] != null;

    final progress = (widget.prompts.length <= 1)
        ? 1.0
        : (_index / (widget.prompts.length - 1)).clamp(0.0, 1.0);

    return Scaffold(
      body: GlassBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ---------- App bar ----------
                Row(
                  children: [
                    IconPillButton(
                      tooltip: 'Close',
                      icon: Icons.close,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 10),
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
                              color: GlassTokens.fg(context),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Step ${_index + 1} of ${widget.prompts.length}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: GlassTokens.muted(context),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconPillButton(
                      tooltip: 'Stop audio',
                      icon: Icons.stop_circle_outlined,
                      onTap: (_playingGuide || _playingUser)
                          ? _stopPlayback
                          : null,
                    ),
                  ],
                ),

                const SizedBox(height: 10),

                // ---------- Progress ----------
                LiquidGlass(
                  borderRadius: BorderRadius.circular(999),
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 12,
                  ),
                  // ✅ page already glass: keep crisp (avoid double blur)
                  blurX: 0,
                  blurY: 0,
                  shadow: false,
                  grain: false,
                  tintOpacityLight: 0.045,
                  tintOpacityDark: 0.060,
                  borderOpacityLight: 0.20,
                  borderOpacityDark: 0.16,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          minHeight: 6,
                          value: progress,
                          backgroundColor: Colors.white.withValues(alpha: 0.22),
                        ),
                      ),
                      const SizedBox(height: 6),
                      // Text(
                      //   '${(progress * 100).round()}% • ${_index + 1}/${widget.prompts.length}',
                      //   style: TextStyle(
                      //     color: GlassTokens.muted(context, alpha: 0.62),
                      //     fontWeight: FontWeight.w700,
                      //     fontSize: 12,
                      //   ),
                      // ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // ---------- Prompt panel ----------
                GlassCard(
                  variant: GlassCardVariant.panel,
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _ToneChip(
                            label: done ? 'Recorded' : 'Not recorded',
                            tone: done ? _ChipTone.good : _ChipTone.neutral,
                          ),
                          const SizedBox(width: 8),
                          _ToneChip(
                            label: 'Min ${p.minSec.toStringAsFixed(1)}s',
                            tone: _ChipTone.neutral,
                          ),
                          const Spacer(),
                          Text(
                            p.title,
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              color: GlassTokens.fg(context),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        p.subtitle,
                        style: TextStyle(
                          color: GlassTokens.muted(context),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      GlassCard(
                        variant: GlassCardVariant.tile,
                        padding: const EdgeInsets.all(14),
                        child: Text(
                          p.script,
                          style: TextStyle(
                            fontSize: 16,
                            height: 1.35,
                            fontWeight: FontWeight.w700,
                            color: GlassTokens.fg(context),
                          ),
                        ),
                      ),
                      if (p.audioAsset != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          'Tip: use “Play guide” to hear an example.',
                          style: TextStyle(
                            color: GlassTokens.muted(context, alpha: 0.55),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // ---------- Record panel ----------
                Expanded(
                  child: GlassCard(
                    variant: GlassCardVariant.panel,
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Spacer(),
                            if (_recording)
                              _ToneChip(
                                label: _fmt(_seconds),
                                tone: _ChipTone.neutral,
                                icon: Icons.timer_outlined,
                              ),
                            if (_busy) ...[
                              const SizedBox(width: 10),
                              SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    GlassTokens.fg(context, alpha: 0.85),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 10),

                        if (_recording) _recordingHint(p.minSec),

                        const Spacer(),

                        _recordButton(done),

                        const SizedBox(height: 12),

                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              GlassButton(
                                label: 'Re-record',
                                icon: Icons.replay,
                                kind: GlassButtonKind.secondary,
                                expand: false,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                onPressed: (!done || _busy) ? null : _reRecord,
                                innerChrome: false,
                              ),
                              const SizedBox(width: 8),
                              GlassButton(
                                label: _playingGuide
                                    ? 'Stop guide'
                                    : 'Play guide',
                                icon: _playingGuide
                                    ? Icons.pause_circle_filled
                                    : Icons.volume_up,
                                kind: GlassButtonKind.secondary,
                                expand: false,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                onPressed: (p.audioAsset == null || _busy)
                                    ? null
                                    : _togglePlayGuide,
                                innerChrome: false,
                              ),
                              const SizedBox(width: 8),
                              GlassButton(
                                label: _playingUser
                                    ? 'Stop my clip'
                                    : 'Play my clip',
                                icon: _playingUser
                                    ? Icons.pause_circle_filled
                                    : Icons.graphic_eq,
                                kind: GlassButtonKind.secondary,
                                expand: false,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                onPressed: (_clips[_index] == null || _busy)
                                    ? null
                                    : _togglePlayMyRecording,
                                innerChrome: false,
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 12),
                        const GlassDivider(height: 1, thickness: 0.8),
                        const SizedBox(height: 12),

                        GlassButton(
                          label: _index + 1 < widget.prompts.length
                              ? 'Next step'
                              : 'Finish setup',
                          icon: _index + 1 < widget.prompts.length
                              ? Icons.arrow_forward
                              : Icons.check,
                          kind: GlassButtonKind.primary,
                          onPressed: _busy ? null : _next,
                          innerChrome: false,
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
      ),
    );
  }

  Widget _recordButton(bool done) {
    final fg = GlassTokens.fg(context);
    final isDark = GlassTokens.isDark(context);

    return GestureDetector(
      onLongPressStart: (_) => _onHoldStart(),
      onLongPressEnd: (_) => _onHoldEnd(),
      onLongPressCancel: _cancelRecording,
      child: LiquidGlass(
        borderRadius: BorderRadius.circular(20),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        // ✅ keep some blur for the big CTA (readability)
        blurX: isDark ? 9 : 7,
        blurY: isDark ? 9 : 7,
        shadow: _recording,
        shadowBlur: 26,
        shadowOffset: const Offset(0, 12),
        shadowOpacityDark: _recording ? 0.24 : 0.18,
        shadowOpacityLight: _recording ? 0.10 : 0.06,
        grain: false,
        tintOpacityLight: _recording ? 0.09 : 0.06,
        tintOpacityDark: _recording ? 0.12 : 0.08,
        borderOpacityLight: _recording ? 0.26 : 0.20,
        borderOpacityDark: _recording ? 0.22 : 0.18,
        child: SizedBox(
          height: 42,
          child: Row(
            children: [
              Icon(
                _recording ? Icons.mic_rounded : Icons.mic_none_rounded,
                size: 28,
                color: fg,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Align(
                  alignment: Alignment.center,
                  // ✅ never overflow; scales down if needed
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: Text(
                      _recording
                          ? 'Recording… release to finish'
                          : (done
                                ? 'Recorded — hold to replace'
                                : 'Hold to record'),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: fg,
                      ),
                    ),
                  ),
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
        need > 0.05
            ? 'Keep holding… ${need.toStringAsFixed(1)}s more'
            : 'Good! You can release now.',
        style: TextStyle(
          color: GlassTokens.muted(context),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Glass helpers
// -----------------------------------------------------------------------------

enum _ChipTone { neutral, good, bad }

class _ToneChip extends StatelessWidget {
  const _ToneChip({required this.label, required this.tone, this.icon});

  final String label;
  final _ChipTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context, alpha: 0.92);

    // slightly stronger than normal (this page is glass)
    double tl, td, bl, bd;
    switch (tone) {
      case _ChipTone.good:
        tl = 0.060;
        td = 0.080;
        bl = 0.22;
        bd = 0.18;
        break;
      case _ChipTone.bad:
        tl = 0.080;
        td = 0.105;
        bl = 0.24;
        bd = 0.20;
        break;
      case _ChipTone.neutral:
      default:
        tl = 0.050;
        td = 0.070;
        bl = 0.20;
        bd = 0.16;
        break;
    }

    return LiquidGlass(
      borderRadius: BorderRadius.circular(999),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      shadow: false,
      // ✅ chips: crisp (no extra blur)
      blurX: 0,
      blurY: 0,
      grain: false,
      tintOpacityLight: tl,
      tintOpacityDark: td,
      borderOpacityLight: bl,
      borderOpacityDark: bd,
      onTap: null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon ??
                (tone == _ChipTone.good
                    ? Icons.check_circle_outline
                    : (tone == _ChipTone.bad
                          ? Icons.error_outline
                          : Icons.info_outline)),
            size: 16,
            color: fg,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassNameDialog extends StatelessWidget {
  const _GlassNameDialog({required this.controller, required this.busy});

  final TextEditingController controller;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: LiquidGlass(
        borderRadius: BorderRadius.circular(22),
        padding: const EdgeInsets.all(14),
        blurX: GlassTokens.isDark(context) ? GlassTokens.blurLg : 22,
        blurY: GlassTokens.isDark(context) ? GlassTokens.blurLg : 22,
        shadow: true,
        grain: false,
        tintOpacityLight: 0.10,
        tintOpacityDark: 0.12,
        borderOpacityLight: 0.22,
        borderOpacityDark: 0.20,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Your name',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 16,
                color: fg,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              autofocus: true,
              style: TextStyle(color: fg, fontWeight: FontWeight.w700),
              decoration: InputDecoration(
                labelText: 'Display name (e.g., Alex)',
                labelStyle: TextStyle(
                  color: muted,
                  fontWeight: FontWeight.w600,
                ),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.04),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: Colors.white.withValues(alpha: 0.14),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: Colors.white.withValues(alpha: 0.14),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: Colors.white.withValues(alpha: 0.26),
                    width: 1.2,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: GlassButton(
                    label: 'Cancel',
                    kind: GlassButtonKind.secondary,
                    onPressed: busy ? null : () => Navigator.pop(context),
                    innerChrome: false,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GlassButton(
                    label: 'Save',
                    icon: Icons.check,
                    kind: GlassButtonKind.primary,
                    onPressed: busy
                        ? null
                        : () => Navigator.pop(context, controller.text.trim()),
                    innerChrome: false,
                  ),
                ),
              ],
            ),
          ],
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
