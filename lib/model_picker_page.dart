import 'dart:async';
import 'package:flutter/material.dart';

import 'qwen_model_service.dart';
import 'whisper_service.dart';

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
    setState(() => _error = null);
    try {
      _qwenDownloaded = await _qwenService.isModelDownloaded();
      _qwenProgress = ModelProgress.idle;

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
    setState(() => _error = null);
    try {
      await _qwenService.downloadModel();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Download failed: $e');
    }
  }

  Future<void> _cancelQwen() async {
    setState(() => _error = null);
    try {
      await _qwenService.cancelDownload();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Cancel failed: $e');
    }
  }

  // ---------- UI helpers ----------
  BoxDecoration _panelDecoration(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg = isDark ? const Color(0xFF101018) : theme.colorScheme.surface;
    final border = isDark
        ? Colors.white.withOpacity(0.10)
        : Colors.black.withOpacity(0.08);

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

    final p = _qwenProgress;
    final isDl = p.downloading;
    final isReady = _qwenDownloaded;

    // ✅ Keep your percentage exactly as-is (you said it's fine)
    final pct = (p.percent * 100).clamp(0, 100).toStringAsFixed(0);

    // ✅ FIX: progress bar must NOT use p.percent; use received/total directly
    final barValue = (p.total <= 0)
        ? null
        : (p.received / p.total).clamp(0.0, 1.0);

    final statusText = isDl
        ? (p.error != null ? 'Error: ${p.error}' : 'Downloading…')
        : (isReady ? 'Downloaded' : 'Not downloaded');

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
          children: [
            // ---------- Custom header ----------
            Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Models',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Download local AI models',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isDark ? Colors.white70 : Colors.black54,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                _IconPillButton(
                  tooltip: 'Close',
                  icon: Icons.close,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),

            const SizedBox(height: 14),

            // ---------- Qwen panel ----------
            Container(
              decoration: _panelDecoration(context),
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Top row
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          color: (isDark ? Colors.white : Colors.black)
                              .withOpacity(0.06),
                          border: Border.all(
                            color: (isDark ? Colors.white : Colors.black)
                                .withOpacity(0.10),
                          ),
                        ),
                        child: const Icon(Icons.smart_toy_outlined),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Enyx Lite',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Local LLM used for AI features.',
                              style: TextStyle(
                                color: isDark ? Colors.white70 : Colors.black54,
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

                  // ✅ Progress bar when downloading (NOW WORKS)
                  if (isDl) ...[
                    const SizedBox(height: 14),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        minHeight: 8,
                        value: barValue, // ✅ fixed'
                        backgroundColor: Colors.white10,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Text(
                          p.error != null ? 'Issue detected' : 'Downloading…',
                          style: TextStyle(
                            color: p.error != null
                                ? Colors.red
                                : (isDark ? Colors.white70 : Colors.black54),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        OutlinedButton(
                          onPressed: _cancelQwen,
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(
                              color: Colors.red, // 👈 border color
                              width: 1.2,
                            ),
                          ),
                          child: const Text('Cancel',style: TextStyle(color: Colors.red),),
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 14),
                  const Divider(height: 1, thickness: 0.6),
                  const SizedBox(height: 12),

                  // Bottom actions (download / downloaded)
                  Row(
                    children: [
                      Expanded(
                        child: isReady
                            ? OutlinedButton.icon(
                                onPressed: null,
                                icon: const Icon(Icons.verified),
                                label: const Text('Downloaded'),
                                
                              )
                            : FilledButton.icon(
                                onPressed: isDl ? null : _downloadQwen,
                                icon: isDl
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.black,
                                        ),
                                      )
                                    : const Icon(Icons.download),
                                label: Text(isDl ? 'Downloading…' : 'Download',style: TextStyle(color: Colors.black),),
                                style:OutlinedButton.styleFrom(backgroundColor: Colors.white),
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
              Container(
                decoration: _panelDecoration(context),
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

class _IconPillButton extends StatelessWidget {
  const _IconPillButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

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
        child: Tooltip(message: tooltip, child: Icon(icon)),
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
    Color? accent;
    if (tone == _PillTone.good) accent = Colors.green;
    if (tone == _PillTone.bad) accent = Colors.redAccent;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: (accent ?? Colors.white24).withOpacity(0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: (accent ?? Colors.white24).withOpacity(0.45)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: accent ?? Colors.white70,
        ),
      ),
    );
  }
}
