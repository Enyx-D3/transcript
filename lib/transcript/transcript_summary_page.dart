// lib/transcript/transcript_summary_page.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../objectbox.g.dart';

import '../llm_service.dart' show LLMService, qwenMaxContext;
import '../qwen_model_service.dart';
import '../whisper_service.dart' show ModelProgress;

import '../common/app_flushbar.dart';

import '../report/report_service.dart';
import '../report/report_dialog.dart';
import '../model_picker_page.dart';

class TranscriptSummaryPage extends StatefulWidget {
  const TranscriptSummaryPage({super.key, required this.transcriptId});
  final int transcriptId;

  @override
  State<TranscriptSummaryPage> createState() => _TranscriptSummaryPageState();
}

class _TranscriptSummaryPageState extends State<TranscriptSummaryPage> {
  final QwenModelService _qwenService = QwenModelService();

  StreamSubscription<ModelProgress>? _qwenSub;

  bool _initializing = true;
  bool _modelAvailable = false;
  String? _modelPath;

  bool _generating = false;
  String? _summaryText;
  String? _error;
  StreamSubscription<Map<String, dynamic>>? _streamSub;

  final ReportService _reportService = const ReportService(
    baseUrl: 'YOUR_BASE_URL_HERE',
  );

  // ===================== Summary length preference =====================

  static const String _kSummaryLengthPref = 'summary_length_pref'; // 0/1/2
  int _summaryLengthIndex = 1; // ✅ default = Balanced (default)

  @override
  void initState() {
    super.initState();
    _loadLengthPref();
    _loadExistingSummary();
    _initModelState();
  }

  @override
  void dispose() {
    _qwenSub?.cancel();
    _streamSub?.cancel();
    super.dispose();
  }

  Future<void> _loadLengthPref() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final v = sp.getInt(_kSummaryLengthPref);
      if (!mounted) return;
      setState(() => _summaryLengthIndex = (v ?? 1).clamp(0, 2));
    } catch (_) {
      // ignore
    }
  }

  Future<void> _saveLengthPref(int idx) async {
    _summaryLengthIndex = idx.clamp(0, 2);
    setState(() {});
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_kSummaryLengthPref, _summaryLengthIndex);
    } catch (_) {
      // ignore
    }
  }

  String _lengthLabel(int idx) {
    switch (idx) {
      case 0:
        return 'Short';
      case 2:
        return 'Detailed';
      case 1:
      default:
        return 'Balanced (default)';
    }
  }

  String _lengthDesc(int idx) {
    switch (idx) {
      case 0:
        return 'Concise and to the point';
      case 2:
        return 'More context and explanation';
      case 1:
      default:
        return 'Clear and complete';
    }
  }

  // ✅ Map preference → generation size
  int _maxTokensForLength(int idx) {
    switch (idx) {
      case 0:
        return 320; // Short
      case 2:
        return 1200; // Detailed
      case 1:
      default:
        return 650; // Balanced
    }
  }

  Future<void> _openLengthSheet() async {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final border = (isDark ? Colors.white : Colors.black).withOpacity(0.10);
    final bg = (isDark ? Colors.white : Colors.black).withOpacity(0.06);

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: false,
      builder: (_) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF101018),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(0.12)),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 22,
                    color: Colors.black.withOpacity(0.35),
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            color: Colors.white.withOpacity(0.06),
                            border:
                                Border.all(color: Colors.white.withOpacity(0.10)),
                          ),
                          child: const Icon(Icons.tune, size: 18),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Summary length',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        _IconPillButton(
                          tooltip: 'Close',
                          icon: Icons.close,
                          onTap: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Choose how detailed the summary should be',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.70),
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Options
                    _LengthTile(
                      selected: _summaryLengthIndex == 0,
                      title: 'Short',
                      subtitle: 'Concise and to the point',
                      border: border,
                      bg: bg,
                      onTap: () async {
                        await _saveLengthPref(0);
                        if (mounted) Navigator.of(context).pop();
                      },
                    ),
                    const SizedBox(height: 10),
                    _LengthTile(
                      selected: _summaryLengthIndex == 1,
                      title: 'Balanced (default)',
                      subtitle: 'Clear and complete',
                      border: border,
                      bg: bg,
                      onTap: () async {
                        await _saveLengthPref(1);
                        if (mounted) Navigator.of(context).pop();
                      },
                    ),
                    const SizedBox(height: 10),
                    _LengthTile(
                      selected: _summaryLengthIndex == 2,
                      title: 'Detailed',
                      subtitle: 'More context and explanation',
                      border: border,
                      bg: bg,
                      onTap: () async {
                        await _saveLengthPref(2);
                        if (mounted) Navigator.of(context).pop();
                      },
                    ),

                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ===================== Existing logic =====================

  Future<void> _loadExistingSummary() async {
    final obx = ObjectBox.I;

    final qb = obx.summaries.query(
      TranscriptSummaryEntity_.transcriptId.equals(widget.transcriptId),
    );
    final q = qb.build();
    final existing = q.findFirst();
    q.close();

    if (!mounted) return;
    if (existing != null) {
      setState(() {
        _summaryText = existing.summary;
        _error = null;
      });
    }
  }

  Future<void> _initModelState() async {
    final exists = await _qwenService.isModelDownloaded();
    final path = await _qwenService.modelFilePath();

    if (!mounted) return;
    setState(() {
      _initializing = false;
      _modelAvailable = exists;
      _modelPath = exists ? path : null;
    });

    _qwenSub = _qwenService.progress.listen((p) async {
      if (!mounted) return;

      final finishedOk =
          !p.downloading && p.error == null && p.total == 1 && p.received == 1;
      if (finishedOk) {
        final ok = await _qwenService.isModelDownloaded();
        if (!mounted) return;
        if (ok) {
          final newPath = await _qwenService.modelFilePath();
          if (!mounted) return;
          setState(() {
            _modelAvailable = true;
            _modelPath = newPath;
          });
        }
      }
    });
  }

  Future<void> _copySummary() async {
    final text = (_summaryText ?? '').trim();
    if (text.isEmpty) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Nothing to copy.');
      return;
    }

    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    await AppFlushbar.success(context, message: 'Summary copied.');
  }

  Future<void> _shareSummary() async {
    final text = (_summaryText ?? '').trim();
    if (text.isEmpty) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Nothing to share.');
      return;
    }

    // ✅ Share as plain text
    await SharePlus.instance.share(
      ShareParams(
        text: text,
        subject: 'Transcript summary',
      ),
    );
  }

  Future<void> _reportSummary() async {
    final text = (_summaryText ?? '').trim();
    if (text.isEmpty) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Nothing to report.');
      return;
    }

    await showReportDialog(
      outerContext: context,
      responseText: text,
      sendReport: ({
        Map<String, dynamic>? meta,
        required String reason,
        required String note,
        required String response,
      }) async {
        await _reportService.sendReport(
          reason: reason,
          note: note,
          response: response,
        );
      },
    );
  }

  Future<void> _generateSummary({bool userTriggered = false}) async {
    if (_generating) return;

    if (!_modelAvailable || _modelPath == null) {
      if (userTriggered) {
        setState(() => _error = 'Please download the AI model first.');
      }
      return;
    }

    setState(() {
      _generating = true;
      if (userTriggered) _error = null;
    });

    await _streamSub?.cancel();
    _streamSub = null;

    try {
      final obx = ObjectBox.I;

      final t = obx.transcripts.get(widget.transcriptId);
      if (t == null) throw Exception('Transcript not found.');

      final qb = obx.turns.query(
        TranscriptTurnEntity_.transcript.equals(widget.transcriptId),
      )..order(TranscriptTurnEntity_.startSec);
      final q = qb.build();
      final turns = q.find();
      q.close();

      if (turns.isEmpty) throw Exception('Transcript has no segments yet.');

      final buf = StringBuffer();
      for (final u in turns) {
        final txt = u.text.trim();
        if (txt.isEmpty) continue;
        buf.writeln('${u.speakerLabel}: $txt');
      }
      final transcriptText = buf.toString().trim();
      if (transcriptText.isEmpty) throw Exception('Transcript text is empty.');

      String latestFullText = '';

      // ===================== ✅ PASSING THE LENGTH VALUE =====================
      final maxTokens = _maxTokensForLength(_summaryLengthIndex);
      // 👇 This is where we pass it into the summary generation call:
      final stream = LLMService.summarizeTranscript(
        transcript: transcriptText,
        modelPath: _modelPath!,
        maxTokens: maxTokens, // ✅ uses Short/Balanced/Detailed
        temperature: 0.3,
        contextSize: qwenMaxContext,
      );
      // ======================================================================

      _streamSub = stream.listen(
        (evt) {
          final full = (evt['full_text'] ?? '') as String;
          if (full.isNotEmpty) latestFullText = full;

          if (!mounted) return;
          setState(() => _summaryText = latestFullText);
        },
        onError: (err, st) {
          if (!mounted) return;
          setState(() {
            _generating = false;
            _error = 'Failed to generate summary: $err';
          });
        },
        onDone: () async {
          if (!mounted) return;
          setState(() => _generating = false);

          try {
            final qb2 = obx.summaries.query(
              TranscriptSummaryEntity_.transcriptId.equals(widget.transcriptId),
            );
            final q2 = qb2.build();
            final existing = q2.findFirst();
            q2.close();

            final entity = TranscriptSummaryEntity(
              id: existing?.id ?? 0,
              transcriptId: widget.transcriptId,
              summary: latestFullText.trim(),
              updatedAt: DateTime.now(),
            );
            obx.summaries.put(entity);
          } catch (e) {
            debugPrint('Failed to persist summary: $e');
          }
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _error = 'Failed to generate summary: $e';
      });
    }
  }

  Future<void> _openModelPicker() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ModelPickerPage()),
    );

    await _initModelState();
  }

  // ===================== REDESIGNED UI HELPERS =====================

  Widget _panel({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF101018),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            color: Colors.black.withOpacity(0.25),
            offset: const Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: child,
    );
  }

  Widget _metaPill(String text, {Color? accent, IconData? icon}) {
    final c = accent;
    return Container(
      height: 32,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.white.withOpacity(0.06),
        border: Border.all(color:Colors.white.withOpacity(0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onPrimary,
    required String primaryLabel,
    required IconData primaryIcon,
  }) {
    return _panel(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: Colors.white.withOpacity(0.06),
                border: Border.all(color: Colors.white.withOpacity(0.10)),
              ),
              child: Icon(icon, size: 22),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: const TextStyle(color: Colors.white70, height: 1.25),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onPrimary,
                icon: Icon(primaryIcon,color: Colors.black,),
                label: Text(primaryLabel,style: TextStyle(color: Colors.black),),
                style: OutlinedButton.styleFrom(
                  backgroundColor: Colors.white
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryCard(String text) {
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: Colors.white.withOpacity(0.06),
                  border: Border.all(color: Colors.white.withOpacity(0.10)),
                ),
                child: const Icon(Icons.auto_awesome, size: 18),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Summary',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
              if (_generating) _metaPill('Writing…', icon: Icons.sync,),
            ],
          ),
          const SizedBox(height: 12),
          SelectableText(
            text,
            style: const TextStyle(color: Colors.white, height: 1.35),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _generating ? null : _copySummary,
                  icon: const Icon(Icons.copy, size: 18,color: Colors.white,),
                  label: const Text('Copy',style: TextStyle(color:Colors.white),),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _generating ? null : _reportSummary,
                  icon: const Icon(Icons.flag_outlined, size: 18,color: Colors.white,),
                  label: const Text('Report',style:TextStyle(color:Colors.white)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _banner({required IconData icon, required String text, Color? color}) {
    final c = color ?? Colors.white;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: c.withOpacity(0.08),
        border: Border.all(color: c.withOpacity(0.18)),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(icon, color: c.withOpacity(0.95)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white70, height: 1.2),
            ),
          ),
        ],
      ),
    );
  }

  // ===================== UI =====================

  @override
  Widget build(BuildContext context) {
    final hasSummary = (_summaryText ?? '').trim().isNotEmpty;
    final canGenerate = !_generating && _modelAvailable && _modelPath != null;
    final canShare = hasSummary && !_generating;

    final actionLabel = hasSummary ? 'Regenerate' : 'Generate';
    final actionIcon = hasSummary ? Icons.refresh : Icons.auto_awesome;

    if (_initializing) {
      return Scaffold(
        appBar: AppBar(title: const Text('Summary')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 18),
          children: [
            // Header row
            Row(
              children: [
                _IconPillButton(
                  tooltip: 'Back',
                  icon: Icons.arrow_back,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(width: 10),

                Text(
                  'Summary',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.2,
                      ),
                ),

                const SizedBox(width: 10),

                // ✅ shows current selection (tap to change)
                

                const Spacer(),

                // ✅ Share (active only when summary exists)
                _IconPillButton(
                  tooltip: 'Share',
                  icon: Icons.ios_share,
                  onTap: canShare ? _shareSummary : null,
                ),
                const SizedBox(width: 10),

                FilledButton.icon(
                  onPressed: canGenerate
                      ? () => _generateSummary(userTriggered: true)
                      : null,
                  icon: Icon(actionIcon,color: Colors.black,),
                  label: Text(actionLabel,style:TextStyle(color: Colors.black)),
                  style: OutlinedButton.styleFrom(backgroundColor: Colors.white),
                ),
              ],
            ),

            const SizedBox(height: 12),
            GestureDetector(
                  onTap: _openLengthSheet,
                  child: _metaPill(
                    _lengthLabel(_summaryLengthIndex),
                    icon: Icons.tune,
                    accent: const Color(0xFF65D6FF),
                  ),
                ),
                const SizedBox(height: 12),
            if (_generating) ...[
              _panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    LinearProgressIndicator(minHeight: 3,color: Colors.white,backgroundColor: Colors.white12,),
                    SizedBox(height: 10),
                    Text(
                      'Generating summary…',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Keep the app open while this finishes.',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            if (_error != null) ...[
              _banner(
                icon: Icons.error_outline,
                text: _error!,
                color: Colors.redAccent,
              ),
              const SizedBox(height: 12),
            ],

            if (!_modelAvailable && !hasSummary) ...[
              _emptyState(
                icon: Icons.smart_toy_outlined,
                title: 'Model required',
                subtitle: 'To generate a summary, download the AI model.',
                onPrimary: _openModelPicker,
                primaryLabel: 'Download Model',
                primaryIcon: Icons.download,
              ),
              const SizedBox(height: 12),
            ],

            if (!_modelAvailable && hasSummary) ...[
              _banner(
                icon: Icons.info_outline,
                text:
                    'Showing the last saved summary. Download the AI model if you want to regenerate it.',
                color: const Color(0xFF65D6FF),
              ),
              const SizedBox(height: 12),
            ],

            if (hasSummary)
              _summaryCard((_summaryText ?? '').trim())
            else if (!_generating)
              _panel(
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'No summary yet. Tap Generate to create one.',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ===================== UI components =====================

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

    final border = (isDark ? Colors.white : Colors.black).withOpacity(0.10);
    final bg = (isDark ? Colors.white : Colors.black).withOpacity(0.06);

    final disabled = onTap == null;
    final iconColor = disabled
        ? (isDark ? Colors.white38 : Colors.black38)
        : null;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(8), // ✅ small
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: bg,
            border: Border.all(color: border),
          ),
          child: Icon(icon, size: 20, color: iconColor),
        ),
      ),
    );
  }
}

class _LengthTile extends StatelessWidget {
  const _LengthTile({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.border,
    required this.bg,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String subtitle;
  final Color border;
  final Color bg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = const Color(0xFF65D6FF);

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: selected ? Colors.white : bg,
          border: Border.all(
            color: selected ? Colors.white : border,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: Colors.white,
                  width: 2,
                ),
              ),
              child: selected
                  ? Center(
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.70),
                      fontWeight: FontWeight.w600,
                      height: 1.15,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
