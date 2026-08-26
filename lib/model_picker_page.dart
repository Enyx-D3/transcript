import 'dart:async';
import 'package:flutter/material.dart';
import 'package:transcript/widgets/icon_pill_button.dart';

import 'qwen_model_service.dart';
import 'model_progress.dart';
import '../ui/glass/glass_tokens.dart';

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
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);
    final primaryColor = GlassTokens.primary(context);

    final p = _qwenProgress;
    final isDl = p.downloading;
    final isReady = _qwenDownloaded;

    final pct = (p.percent * 100).clamp(0, 100).toStringAsFixed(0);

    final barValue = (p.total <= 0)
        ? null
        : (p.received / p.total).clamp(0.0, 1.0);

    return Scaffold(
      backgroundColor: GlassTokens.backgroundColor(context),
      body: SafeArea(
        child: Column(
          children: [
            // Top App Bar with bold 'Models' title
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  IconPillButton(
                    tooltip: 'Back',
                    icon: Icons.arrow_back_rounded,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Models',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                        color: fg,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            Divider(
              height: 1,
              thickness: 1,
              color: GlassTokens.borderColor(context),
            ),

            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  // Model panel (Solid High Contrast Card)
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: GlassTokens.cardColor(context),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: GlassTokens.borderColor(context),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: isDark ? 0.20 : 0.04,
                          ),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Top row
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                color: primaryColor.withValues(
                                  alpha: isDark ? 0.16 : 0.10,
                                ),
                              ),
                              child: Icon(
                                Icons.smart_toy_outlined,
                                color: primaryColor,
                                size: 24,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Enyx Lite',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                      color: fg,
                                      letterSpacing: -0.2,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Local on-device LLM for AI transcription & summaries.',
                                    style: TextStyle(
                                      color: muted,
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w500,
                                      height: 1.3,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _StatusPill(
                                        label: isReady
                                            ? 'Downloaded'
                                            : (isDl
                                                  ? 'Downloading…'
                                                  : (p.error != null
                                                        ? 'Error'
                                                        : 'Not downloaded')),
                                        tone: isReady
                                            ? _PillTone.good
                                            : (p.error != null
                                                  ? _PillTone.bad
                                                  : _PillTone.neutral),
                                        primaryColor: primaryColor,
                                        isDark: isDark,
                                      ),
                                      if (isDl)
                                        _StatusPill(
                                          label: '$pct%',
                                          tone: _PillTone.neutral,
                                          primaryColor: primaryColor,
                                          isDark: isDark,
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),

                        // Progress bar during download
                        if (isDl) ...[
                          const SizedBox(height: 16),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              minHeight: 8,
                              value: barValue,
                              backgroundColor:
                                  (isDark ? Colors.white : Colors.black)
                                      .withValues(alpha: 0.10),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                primaryColor,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  p.error != null
                                      ? 'Issue detected'
                                      : 'Downloading AI model ($pct%)…',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: p.error != null
                                        ? const Color(0xFFFF3B30)
                                        : muted,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton(
                                onPressed: _cancelQwen,
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(
                                    color: Color(0xFFFF3B30),
                                    width: 1,
                                  ),
                                  foregroundColor: const Color(0xFFFF3B30),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 8,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                child: const Text(
                                  'Cancel',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                            ],
                          ),
                        ],

                        const SizedBox(height: 16),
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: GlassTokens.borderColor(context),
                        ),
                        const SizedBox(height: 14),

                        // Bottom Action Button
                        Row(
                          children: [
                            Expanded(
                              child: isReady
                                  ? OutlinedButton.icon(
                                      onPressed: null,
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: const Color(
                                          0xFF34C759,
                                        ),
                                        disabledForegroundColor: const Color(
                                          0xFF34C759,
                                        ),
                                        backgroundColor: const Color(0xFF34C759)
                                            .withValues(
                                              alpha: isDark ? 0.14 : 0.08,
                                            ),
                                        side: BorderSide(
                                          color: const Color(
                                            0xFF34C759,
                                          ).withValues(alpha: 0.35),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 13,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                      ),
                                      icon: const Icon(
                                        Icons.check_circle_rounded,
                                        size: 19,
                                        color: Color(0xFF34C759),
                                      ),
                                      label: const Text(
                                        'Downloaded & Ready',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 14,
                                          color: Color(0xFF34C759),
                                        ),
                                      ),
                                    )
                                  : ElevatedButton.icon(
                                      onPressed: isDl ? null : _downloadQwen,
                                      icon: isDl
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2.2,
                                                color: Colors.white,
                                              ),
                                            )
                                          : const Icon(
                                              Icons.download_rounded,
                                              size: 20,
                                              color: Colors.white,
                                            ),
                                      label: Text(
                                        isDl
                                            ? 'Downloading…'
                                            : 'Download Model',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 14,
                                        ),
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: primaryColor,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 13,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                        elevation: 2,
                                        shadowColor: primaryColor.withValues(
                                          alpha: 0.4,
                                        ),
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // Error alert panel
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(
                          0xFFFF3B30,
                        ).withValues(alpha: isDark ? 0.16 : 0.08),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: const Color(
                            0xFFFF3B30,
                          ).withValues(alpha: 0.35),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            color: Color(0xFFFF3B30),
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _error!,
                              style: const TextStyle(
                                color: Color(0xFFFF3B30),
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
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
}

enum _PillTone { neutral, good, bad }

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.tone,
    required this.primaryColor,
    required this.isDark,
  });

  final String label;
  final _PillTone tone;
  final Color primaryColor;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    Color bg;
    Color border;
    Color textColor;

    switch (tone) {
      case _PillTone.good:
        bg = const Color(0xFF34C759).withValues(alpha: isDark ? 0.18 : 0.10);
        border = const Color(0xFF34C759).withValues(alpha: 0.35);
        textColor = const Color(0xFF34C759);
        break;
      case _PillTone.bad:
        bg = const Color(0xFFFF3B30).withValues(alpha: isDark ? 0.18 : 0.10);
        border = const Color(0xFFFF3B30).withValues(alpha: 0.35);
        textColor = const Color(0xFFFF3B30);
        break;
      case _PillTone.neutral:
        bg = isDark ? const Color(0xFF242432) : const Color(0xFFEEEEF4);
        border = isDark ? const Color(0xFF343444) : const Color(0xFFDCDCE6);
        textColor = muted;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border, width: 1),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: textColor,
          height: 1.0,
        ),
      ),
    );
  }
}
