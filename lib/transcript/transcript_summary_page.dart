// lib/transcript/transcript_summary_page.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transcript/widgets/icon_pill_button.dart';

import '../export/document_export_service.dart';
import '../export/document_export_sheet.dart';
import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../objectbox.g.dart';

import '../llm_service.dart' show LLMService, qwenMaxContext;
import '../qwen_model_service.dart';
import '../model_progress.dart';

import '../common/app_flushbar.dart';

import '../report/report_service.dart';
import '../report/report_dialog.dart';
import '../model_picker_page.dart';

// ✅ Glass primitives (match ImportAudioSheet)
import '../ui/glass/liquid_glass.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_button.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/glass_tokens.dart';

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
  String _transcriptTitle = 'summary';
  String? _error;
  StreamSubscription<Map<String, dynamic>>? _streamSub;
  Timer? _busyWatch;

  final ReportService _reportService = const ReportService(
    baseUrl: 'YOUR_BASE_URL_HERE',
  );

  // ===================== Summary length preference =====================

  static const String _kSummaryLengthPref = 'summary_length_pref'; // 0/1/2
  int _summaryLengthIndex = 1; // ✅ default = Balanced

  // ===================== Shared busy flag (auto + manual) =====================
  String _summaryBusyKey(int id) => 'summary_busy_$id';

  Future<bool> _isSummaryBusy() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getBool(_summaryBusyKey(widget.transcriptId)) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _setSummaryBusy(bool v) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_summaryBusyKey(widget.transcriptId), v);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _loadLengthPref();
    _loadExistingSummary();
    _initModelState();
    _hydrateGeneratingFromBusyFlag(); // ✅ show “Generating…” if auto-summary is running
  }

  @override
  void dispose() {
    _busyWatch?.cancel();
    _busyWatch = null;
    _qwenSub?.cancel();
    _streamSub?.cancel();
    super.dispose();
  }

  void _startBusyWatch() {
    _busyWatch?.cancel();
    _busyWatch = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      final busy = await _isSummaryBusy();
      if (!mounted) return;
      if (!busy) {
        _busyWatch?.cancel();
        _busyWatch = null;

        await _loadExistingSummary();
        if (!mounted) return;
        setState(() => _generating = false);
      }
    });
  }

  Future<void> _hydrateGeneratingFromBusyFlag() async {
    try {
      final busy = await _isSummaryBusy();
      if (!mounted) return;
      if (busy) {
        if (!_generating) setState(() => _generating = true);
        _startBusyWatch();
      } else {
        if (_generating) setState(() => _generating = false);
      }
    } catch (_) {}
  }

  Future<void> _loadLengthPref() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final v = sp.getInt(_kSummaryLengthPref);
      if (!mounted) return;
      setState(
        () => _summaryLengthIndex = (v ?? 1).clamp(0, 2),
      ); // ✅ default Balanced
    } catch (_) {}
  }

  Future<void> _saveLengthPref(int idx) async {
    _summaryLengthIndex = idx.clamp(0, 2);
    if (mounted) setState(() {});
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_kSummaryLengthPref, _summaryLengthIndex);
    } catch (_) {}
  }

  String _lengthLabel(int idx) {
    switch (idx) {
      case 0:
        return 'Short';
      case 2:
        return 'Detailed';
      case 1:
      default:
        return 'Balanced';
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

  int _maxTokensForLength(int idx) {
    switch (idx) {
      case 0:
        return 320;
      case 2:
        return 1200;
      case 1:
      default:
        return 650; // ✅ Balanced default
    }
  }

  // ===================== Existing logic =====================

  Future<void> _loadExistingSummary() async {
    final obx = ObjectBox.I;
    final transcript = obx.transcripts.get(widget.transcriptId);

    final qb = obx.summaries.query(
      TranscriptSummaryEntity_.transcriptId.equals(widget.transcriptId),
    );
    final q = qb.build();
    final existing = q.findFirst();
    q.close();

    if (!mounted) return;
    setState(() {
      final rawTitle = (transcript?.title ?? 'summary').trim();
      _transcriptTitle = rawTitle.isEmpty ? 'summary' : rawTitle;
      if (existing != null) {
        _summaryText = existing.summary;
        _error = null;
      }
    });
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

    _qwenSub?.cancel();
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

  Future<void> _exportSummary(DocumentExportFormat format) async {
    final text = (_summaryText ?? '').trim();
    if (text.isEmpty) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Nothing to export.');
      return;
    }

    try {
      await DocumentExportService.shareDocument(
        title: '$_transcriptTitle summary',
        content: text,
        documentLabel: 'Transcript summary',
        format: format,
      );
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: e.toString());
    }
  }

  Future<void> _openSummaryExportSheet() async {
    final text = (_summaryText ?? '').trim();
    if (text.isEmpty) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Nothing to export.');
      return;
    }

    await showDocumentExportSheet(
      context: context,
      title: 'Export summary',
      onExport: _exportSummary,
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
      sendReport:
          ({
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

    // ✅ if auto-summary (or another page) is generating, reflect that in UI
    if (await _isSummaryBusy()) {
      if (mounted) {
        setState(() {
          _generating = true;
          _error = null;
        });
      }
      _startBusyWatch();
      return;
    }

    if (!_modelAvailable || _modelPath == null) {
      if (userTriggered && mounted) {
        setState(() => _error = 'Please download the AI model first.');
      }
      return;
    }

    // ✅ mark shared busy flag (manual start)
    await _setSummaryBusy(true);

    if (mounted) {
      setState(() {
        _generating = true;
        if (userTriggered) _error = null;
      });
    }

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

      final maxTokens = _maxTokensForLength(_summaryLengthIndex);

      final stream = LLMService.summarizeTranscript(
        transcript: transcriptText,
        modelPath: _modelPath!,
        maxTokens: maxTokens,
        temperature: 0.3,
        contextSize: qwenMaxContext,
      );

      _streamSub = stream.listen(
        (evt) {
          final full = (evt['full_text'] ?? '') as String;
          if (full.isNotEmpty) latestFullText = full;
          if (!mounted) return;
          setState(() => _summaryText = latestFullText);
        },
        onError: (err, st) async {
          await _setSummaryBusy(false);
          if (!mounted) return;
          setState(() {
            _generating = false;
            _error = 'Failed to generate summary: $err';
          });
        },
        onDone: () async {
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

          await _setSummaryBusy(false);
          if (!mounted) return;
          setState(() => _generating = false);
        },
      );
    } catch (e) {
      await _setSummaryBusy(false);
      if (!mounted) return;
      setState(() {
        _generating = false;
        _error = 'Failed to generate summary: $e';
      });
    }
  }

  Future<void> _openModelPicker() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ModelPickerPage()));
    await _initModelState();
  }

  // ===================== Glass helpers =====================

  Widget _metaPill(String text, {Color? accent, IconData? icon}) {
    final fg = GlassTokens.fg(context);
    final c = accent ?? fg;
    final isDark = GlassTokens.isDark(context);

    final radius = BorderRadius.circular(999);

    return ClipRRect(
      borderRadius: radius,
      child: LiquidGlass(
        borderRadius: radius,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        backgroundColor:
            isDark ? GlassTokens.surfaceDark : GlassTokens.surfaceLight,
        shadow: false,
        child: SizedBox(
          height: 32,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 14,
                  color: c,
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _banner({
    required IconData icon,
    required String text,
    Color? accent,
  }) {
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);
    final isDark = GlassTokens.isDark(context);
    final c = accent ?? fg;

    return GlassCard(
      variant: GlassCardVariant.tile,
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: LiquidGlass(
              borderRadius: BorderRadius.circular(14),
              padding: EdgeInsets.zero,
              backgroundColor:
                  isDark ? GlassTokens.surfaceDark : GlassTokens.surfaceLight,
              shadow: false,
              child: SizedBox(
                width: 34,
                height: 34,
                child: Center(
                  child: Icon(icon, size: 18, color: c),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: muted,
                fontWeight: FontWeight.w600,
                height: 1.2,
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
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);
    final isDark = GlassTokens.isDark(context);

    return GlassCard(
      variant: GlassCardVariant.tile,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: LiquidGlass(
              borderRadius: BorderRadius.circular(18),
              padding: EdgeInsets.zero,
              backgroundColor:
                  isDark ? GlassTokens.surfaceDark : GlassTokens.surfaceLight,
              shadow: false,
              child: SizedBox(
                width: 52,
                height: 52,
                child: Center(child: Icon(icon, size: 22, color: fg)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: fg,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              color: muted,
              height: 1.25,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          GlassButton(
            kind: GlassButtonKind.primary,
            label: primaryLabel,
            icon: primaryIcon,
            onPressed: onPrimary,
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(String text) {
    final fg = GlassTokens.fg(context);
    final isDark = GlassTokens.isDark(context);

    return GlassCard(
      variant: GlassCardVariant.tile,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: LiquidGlass(
                  borderRadius: BorderRadius.circular(14),
                  padding: EdgeInsets.zero,
                  backgroundColor:
                      isDark ? GlassTokens.surfaceDark : GlassTokens.surfaceLight,
                  shadow: false,
                  child: SizedBox(
                    width: 38,
                    height: 38,
                    child: Center(
                      child: Icon(Icons.auto_awesome, size: 18, color: fg),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Summary',
                  style: TextStyle(fontWeight: FontWeight.w900, color: fg),
                ),
              ),
              if (_generating) _metaPill('Writing…', icon: Icons.sync),
            ],
          ),
          const SizedBox(height: 12),
          SelectableText(
            text,
            style: TextStyle(
              color: fg,
              height: 1.35,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: GlassButton(
                  kind: GlassButtonKind.secondary,
                  label: 'Copy',
                  icon: Icons.copy,
                  onPressed: _generating ? null : _copySummary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GlassButton(
                  kind: GlassButtonKind.secondary,
                  label: 'Report',
                  icon: Icons.flag_outlined,
                  onPressed: _generating ? null : _reportSummary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ===================== Length sheet (ImportAudioSheet style) =====================

  Future<void> _openLengthSheet() async {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    await showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        final h = MediaQuery.of(context).size.height * 0.55;

        return SizedBox(
          height: h,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            child: Stack(
              children: [
                LiquidGlass(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(22),
                  ),
                  padding: EdgeInsets.zero,
                  shadow: false,
                  blurX: isDark ? 26 : 20,
                  blurY: isDark ? 26 : 20,
                  tintOpacityDark: 0.030,
                  tintOpacityLight: 0.028,
                  borderOpacityDark: 0.16,
                  borderOpacityLight: 0.20,
                  child: const SizedBox.expand(),
                ),
                Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Icon(Icons.tune, color: fg),
                                const SizedBox(width: 8),
                                Text(
                                  'Summary length',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w900,
                                    color: fg,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          LiquidGlass(
                            borderRadius: BorderRadius.circular(999),
                            padding: const EdgeInsets.all(8),
                            shadow: false,
                            blurX: isDark ? 16 : 12,
                            blurY: isDark ? 16 : 12,
                            tintOpacityDark: 0.040,
                            tintOpacityLight: 0.032,
                            borderOpacityDark: 0.14,
                            borderOpacityLight: 0.18,
                            onTap: () => Navigator.of(context).pop(),
                            child: Icon(Icons.close, color: fg, size: 20),
                          ),
                        ],
                      ),
                    ),
                    const GlassDivider(),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            GlassCard(
                              variant: GlassCardVariant.tile,
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Choose how detailed the summary should be',
                                    style: TextStyle(
                                      color: muted,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  _LengthTile(
                                    selected: _summaryLengthIndex == 0,
                                    title: 'Short',
                                    subtitle: _lengthDesc(0),
                                    onTap: () async {
                                      await _saveLengthPref(0);
                                      if (mounted) Navigator.of(context).pop();
                                    },
                                  ),
                                  const SizedBox(height: 10),
                                  _LengthTile(
                                    selected: _summaryLengthIndex == 1,
                                    title: 'Balanced',
                                    subtitle: _lengthDesc(1),
                                    onTap: () async {
                                      await _saveLengthPref(1);
                                      if (mounted) Navigator.of(context).pop();
                                    },
                                  ),
                                  const SizedBox(height: 10),
                                  _LengthTile(
                                    selected: _summaryLengthIndex == 2,
                                    title: 'Detailed',
                                    subtitle: _lengthDesc(2),
                                    onTap: () async {
                                      await _saveLengthPref(2);
                                      if (mounted) Navigator.of(context).pop();
                                    },
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'This only changes how long the AI writes. You can regenerate anytime.',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.55),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ===================== UI =====================

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    final hasSummary = (_summaryText ?? '').trim().isNotEmpty;
    final canGenerate = !_generating && _modelAvailable && _modelPath != null;
    final canShare = hasSummary && !_generating;

    final actionLabel = hasSummary ? 'Regenerate' : 'Generate';
    final actionIcon = hasSummary ? Icons.refresh : Icons.auto_awesome;

    if (_initializing) {
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 18),
          children: [
            // Header row (glass language)
            Row(
              children: [
                IconPillButton(
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
                    color: fg,
                  ),
                ),
                const Spacer(),
                IconPillButton(
                  tooltip: 'Share',
                  icon: Icons.ios_share,
                  onTap: canShare ? _openSummaryExportSheet : null,
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 140,
                  child: GlassButton(
                    kind: GlassButtonKind.primary,
                    label: actionLabel,
                    icon: actionIcon,
                    loading: _generating,
                    onPressed: canGenerate
                        ? () => _generateSummary(userTriggered: true)
                        : null,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Length control (glass tile)
            GestureDetector(
              onTap: _openLengthSheet,
              child: GlassCard(
                variant: GlassCardVariant.tile,
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: Colors.white.withValues(alpha: 0.06),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.10),
                        ),
                      ),
                      child: Icon(Icons.tune, size: 18, color: fg),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Summary length',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              color: fg,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _lengthDesc(_summaryLengthIndex),
                            style: TextStyle(
                              color: muted,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _metaPill(
                      _lengthLabel(_summaryLengthIndex),
                      icon: Icons.tune,
                      accent: const Color(0xFF65D6FF),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            if (_generating) ...[
              GlassCard(
                variant: GlassCardVariant.tile,
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const LinearProgressIndicator(
                      minHeight: 3,
                      color: Colors.white,
                      backgroundColor: Colors.white12,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Generating summary…',
                      style: TextStyle(fontWeight: FontWeight.w900, color: fg),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Keep the app open while this finishes.',
                      style: TextStyle(
                        color: muted,
                        fontWeight: FontWeight.w600,
                      ),
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
                accent: Colors.redAccent,
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
                accent: const Color(0xFF65D6FF),
              ),
              const SizedBox(height: 12),
            ],

            if (hasSummary)
              _summaryCard((_summaryText ?? '').trim())
            else if (!_generating)
              GlassCard(
                variant: GlassCardVariant.tile,
                padding: const EdgeInsets.all(16),
                child: Text(
                  'No summary yet. Tap Generate to create one.',
                  style: TextStyle(
                    color: muted,
                    fontWeight: FontWeight.w600,
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

class _LengthTile extends StatelessWidget {
  const _LengthTile({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    Widget tile = LiquidGlass(
      borderRadius: BorderRadius.circular(16),
      padding: const EdgeInsets.all(12),
      backgroundColor: selected
          ? (isDark ? GlassTokens.surfaceDark : GlassTokens.surfaceLight)
          : Colors.transparent,
      borderColor: selected
          ? fg
          : (isDark ? GlassTokens.borderDark : GlassTokens.borderLight),
      shadow: false,
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: selected ? fg : muted,
                width: 2,
              ),
              color: selected ? fg : Colors.transparent,
            ),
            child: selected
                ? Center(
                    child: Icon(
                      Icons.check,
                      size: 14,
                      color: isDark ? Colors.black : Colors.white,
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
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                    color: fg,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: muted,
                    fontWeight: FontWeight.w600,
                    height: 1.15,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return tile;
  }
}
