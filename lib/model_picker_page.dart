import 'dart:async';
import 'package:flutter/material.dart';
import 'package:transcript/widgets/icon_pill_button.dart';

import 'qwen_model_service.dart';
import 'model_progress.dart';

// ✅ Glass primitives (match your new system)
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/glass_tokens.dart';
import '../ui/glass/liquid_glass.dart';

class ModelPickerPage extends StatefulWidget {
  const ModelPickerPage({super.key});

  @override
  State<ModelPickerPage> createState() => _ModelPickerPageState();
}

class _ModelPickerPageState extends State<ModelPickerPage> {
  String? _error;

  // Qwen state
  final QwenModelService _qwenService = QwenModelService();
  ModelProgress _qwenProgress = ModelProgress.idle;
  bool _qwenDownloaded = false;
  StreamSubscription<ModelProgress>? _qwenSub;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _qwenSub?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (mounted) setState(() => _error = null);
    try {
      _qwenDownloaded = await _qwenService.isModelDownloaded();
      _qwenProgress = ModelProgress.idle;

      _qwenSub?.cancel();
      _qwenSub = _qwenService.progress.listen((p) async {
        if (!mounted) return;
        setState(() => _qwenProgress = p);

        final finishedOk =
            !p.downloading &&
            p.error == null &&
            p.total == 1 &&
            p.received == 1;
        if (finishedOk) {
          final ok2 = await _qwenService.isModelDownloaded();
          if (!mounted) return;
          setState(() => _qwenDownloaded = ok2);
        }
      });

      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = 'Init failed: $e');
    }
  }

  Future<void> _downloadQwen() async {
    if (mounted) setState(() => _error = null);
    try {
      await _qwenService.downloadModel();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Download failed: $e');
    }
  }

  Future<void> _cancelQwen() async {
    if (mounted) setState(() => _error = null);
    try {
      await _qwenService.cancelDownload();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Cancel failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = GlassTokens.isDark(context);

    final fg = GlassTokens.fg(context, alpha: 0.92);
    final muted = GlassTokens.muted(context, alpha: 0.70);

    final p = _qwenProgress;
    final isDl = p.downloading;
    final isReady = _qwenDownloaded;

    // ✅ Keep your percentage exactly as-is
    final pct = (p.percent * 100).clamp(0, 100).toStringAsFixed(0);

    // ✅ progress bar uses received/total
    final barValue = (p.total <= 0)
        ? null
        : (p.received / p.total).clamp(0.0, 1.0);

    final statusText = isDl
        ? (p.error != null ? 'Error: ${p.error}' : 'Downloading…')
        : (isReady ? 'Downloaded' : 'Not downloaded');

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
          children: [
            // ---------- Header (glass, no AppBar) ----------
            Row(
              children: [
                IconPillButton(
                  tooltip: 'Close',
                  icon: Icons.close,
                  onTap: () => Navigator.of(context).pop(),
                ),

                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Models',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.2,
                            color: fg,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Download local AI models',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 14),

            // ---------- Qwen panel (glass) ----------
            GlassCard(
              variant: GlassCardVariant.panel,
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Top row
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LiquidGlass(
                        borderRadius: BorderRadius.circular(14),
                        padding: const EdgeInsets.all(10),
                        shadow: false,
                        blurX: isDark ? 16 : 12,
                        blurY: isDark ? 16 : 12,
                        tintOpacityDark: 0.040,
                        tintOpacityLight: 0.032,
                        borderOpacityDark: 0.14,
                        borderOpacityLight: 0.18,
                        child: Icon(Icons.smart_toy_outlined, color: fg),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Enyx Lite',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                                color: fg,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Local LLM used for AI features.',
                              style: TextStyle(
                                color: muted,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _StatusPill(
                                  label: statusText,
                                  tone: isReady
                                      ? _PillTone.good
                                      : (p.error != null
                                            ? _PillTone.bad
                                            : _PillTone.neutral),
                                ),
                                if (isDl)
                                  _StatusPill(
                                    label: '$pct%',
                                    tone: _PillTone.neutral,
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  // Progress
                  if (isDl) ...[
                    const SizedBox(height: 14),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        minHeight: 8,
                        value: barValue,
                        backgroundColor: (isDark ? Colors.white : Colors.black)
                            .withValues(alpha: 0.16),
                        valueColor: AlwaysStoppedAnimation<Color>(fg),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            p.error != null ? 'Issue detected' : 'Downloading…',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.error != null ? Colors.redAccent : muted,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton(
                          onPressed: _cancelQwen,
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(
                              color: Colors.redAccent,
                              width: 1.2,
                            ),
                            foregroundColor: Colors.redAccent,
                          ),
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 14),
                  const GlassDivider(height: 1, thickness: 0.8),
                  const SizedBox(height: 12),

                  // Bottom actions
                  Row(
                    children: [
                      Expanded(
                        child: isReady
                            ? OutlinedButton.icon(
                                onPressed: null,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: fg,
                                  side: BorderSide(
                                    color: isDark
                                        ? GlassTokens.borderDark
                                        : GlassTokens.borderLight,
                                  ),
                                ),
                                icon: Icon(
                                  Icons.verified,
                                  color: fg,
                                ),
                                label: Text(
                                  'Downloaded',
                                  style: TextStyle(color: fg),
                                ),
                              )
                            : FilledButton.icon(
                                onPressed: isDl ? null : _downloadQwen,
                                icon: isDl
                                    ? SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: isDark
                                              ? Colors.black
                                              : Colors.white,
                                        ),
                                      )
                                    : Icon(
                                        Icons.download,
                                        color: isDark
                                            ? Colors.black
                                            : Colors.white,
                                      ),
                                label: Text(isDl ? 'Downloading…' : 'Download'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: fg,
                                  foregroundColor: isDark
                                      ? Colors.black
                                      : Colors.white,
                                ),
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // ---------- Error panel ----------
            if (_error != null) ...[
              const SizedBox(height: 12),
              GlassCard(
                variant: GlassCardVariant.tile,
                padding: const EdgeInsets.all(12),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }
}

enum _PillTone { neutral, good, bad }

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.tone});

  final String label;
  final _PillTone tone;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    Color? accent;
    if (tone == _PillTone.bad) {
      accent = Colors.redAccent;
    }

    final base = accent ?? (isDark ? Colors.white : Colors.black);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: base.withValues(alpha: tone == _PillTone.bad ? 0.10 : 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: base.withValues(alpha: tone == _PillTone.bad ? 0.45 : 0.28),
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
          color: tone == _PillTone.good
              ? fg
              : (tone == _PillTone.bad ? Colors.redAccent : muted),
        ),
      ),
    );
  }
}
