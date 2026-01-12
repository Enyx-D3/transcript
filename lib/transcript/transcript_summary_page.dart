// lib/transcript/transcript_summary_page.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../objectbox.g.dart';

import '../llm_service.dart' show LLMService, qwenMaxContext;
import '../qwen_model_service.dart';
import '../whisper_service.dart' show ModelProgress;

import '../common/app_flushbar.dart';

// ✅ adjust these imports to match your project structure
import '../report/report_service.dart';
import '../report/report_dialog.dart';

/// Shows or generates a meeting summary for a transcript.
/// Always stores the latest summary in ObjectBox (id == transcriptId).
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

  // ✅ You must initialize this with your values (or inject it)
  // Example:
  // final ReportService _reportService =
  //     const ReportService(baseUrl: 'https://YOUR_SITE.netlify.app');
  final ReportService _reportService =
      const ReportService(baseUrl: 'YOUR_BASE_URL_HERE');

  @override
  void initState() {
    super.initState();
    _loadExistingSummary();
    _initModelState();
  }

  @override
  void dispose() {
    _qwenSub?.cancel();
    _streamSub?.cancel();
    super.dispose();
  }

  // Load last saved summary (if any) from ObjectBox.
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

  // Mirror AiChatTab's model-check logic
  Future<void> _initModelState() async {
    final exists = await _qwenService.isModelDownloaded();
    final path = await _qwenService.modelFilePath();

    if (!mounted) return;
    setState(() {
      _initializing = false;
      _modelAvailable = exists;
      _modelPath = exists ? path : null;
    });

    // Watch for future downloads (from ModelPicker)
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

  Future<void> _reportSummary() async {
    final text = (_summaryText ?? '').trim();
    if (text.isEmpty) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Nothing to report.');
      return;
    }

    // ✅ uses your dialog + report service
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
        setState(() {
          _error = 'Please download the Qwen model first (Model picker).';
        });
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

      // 1) Load transcript turns
      final t = obx.transcripts.get(widget.transcriptId);
      if (t == null) {
        throw Exception('Transcript not found.');
      }

      final qb = obx.turns
          .query(TranscriptTurnEntity_.transcript.equals(widget.transcriptId))
        ..order(TranscriptTurnEntity_.startSec);
      final q = qb.build();
      final turns = q.find();
      q.close();

      if (turns.isEmpty) {
        throw Exception('Transcript has no segments yet.');
      }

      // Build plain text transcript "Speaker: ...\n"
      final buf = StringBuffer();
      for (final u in turns) {
        final txt = u.text.trim();
        if (txt.isEmpty) continue;
        buf.writeln('${u.speakerLabel}: $txt');
      }
      final transcriptText = buf.toString().trim();
      if (transcriptText.isEmpty) {
        throw Exception('Transcript text is empty.');
      }

      // 2) Stream summary from Qwen via LLMService
      String latestFullText = '';

      final stream = LLMService.summarizeTranscript(
        transcript: transcriptText,
        modelPath: _modelPath!,
        maxTokens: 1025,
        temperature: 0.3,
        contextSize: qwenMaxContext,
      );

      _streamSub = stream.listen(
        (evt) {
          final full = (evt['full_text'] ?? '') as String;
          if (full.isNotEmpty) latestFullText = full;

          if (!mounted) return;
          setState(() {
            _summaryText = latestFullText;
          });
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

          setState(() {
            _generating = false;
          });

          // 3) Persist latest summary to ObjectBox
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

  Widget _buildSummaryBubble(String text) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E26),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white, height: 1.35),
        ),
      ),
    );
  }

  Widget _buildSummaryActions({required bool enabled}) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            onPressed: enabled ? _copySummary : null,
            icon: const Icon(Icons.copy, size: 12),
            label: const Text('Copy',style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: enabled ? _reportSummary : null,
            icon: const Icon(Icons.flag_outlined, size: 12,),
            label: const Text('Report',style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasSummary = _summaryText != null && _summaryText!.trim().isNotEmpty;
    final canGenerate = !_generating && _modelAvailable && _modelPath != null;

    final actionLabel = hasSummary ? 'Regenerate' : 'Generate';
    final actionIcon = hasSummary ? Icons.refresh : Icons.auto_awesome;

    if (_initializing) {
      return Scaffold(
        appBar: AppBar(title: const Text('Summary')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Summary'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed:
                  canGenerate ? () => _generateSummary(userTriggered: true) : null,
              icon: Icon(actionIcon),
              label: Text(actionLabel),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!_modelAvailable && !hasSummary) ...[
              Card(
                color: Colors.amber.withOpacity(0.1),
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'To generate a summary, please download the Qwen model '
                    'from the Model picker screen first.',
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (!_modelAvailable && hasSummary) ...[
              Card(
                color: Colors.blueGrey.withOpacity(0.2),
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'Showing the last saved summary. Download the Qwen model '
                    'if you want to regenerate it.',
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_generating) ...[
              const LinearProgressIndicator(minHeight: 3),
              const SizedBox(height: 12),
              const Text('Generating summary…'),
              const SizedBox(height: 12),
            ],
            if (_error != null) ...[
              Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent),
              ),
              const SizedBox(height: 12),
            ],

            if (hasSummary)
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSummaryBubble(_summaryText!.trim()),
                      _buildSummaryActions(enabled: !_generating),
                    ],
                  ),
                ),
              )
            else if (!_generating)
              const Text(
                'No summary yet. Tap Generate to create one.',
                style: TextStyle(color: Colors.white70),
              ),
          ],
        ),
      ),
    );
  }
}
