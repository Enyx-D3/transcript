// lib/transcript/transcript_summary_page.dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../objectbox.g.dart';

import '../llm_service.dart' show LLMService, qwenMaxContext;
import '../qwen_model_service.dart';
import '../whisper_service.dart' show ModelProgress;

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

  final qb = obx.summaries
      .query(TranscriptSummaryEntity_.transcriptId.equals(widget.transcriptId));
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

  Future<void> _generateSummary({bool userTriggered = false}) async {
  // prevent parallel runs
  if (_generating) return;

  // If user tapped a button and model is missing, show error.
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

  // Safety: cancel any previous stream (if for some reason one was still alive)
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

    // Build plain text transcript "S1: ...\nS2: ...\n"
    final buf = StringBuffer();
    for (final u in turns) {
      final txt = u.text.trim();
      if (txt.isEmpty) continue; // skip empty turns
      buf.writeln('${u.speakerLabel}: $txt');
    }
    final transcriptText = buf.toString().trim();
    if (transcriptText.isEmpty) {
      throw Exception('Transcript text is empty.');
    }

    // 2) Stream summary from Qwen via LLMService (using isolate)
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
        if (full.isNotEmpty) {
          latestFullText = full;
        }

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
          // Find existing summary for this transcript
          final qb2 = obx.summaries.query(
            TranscriptSummaryEntity_.transcriptId.equals(widget.transcriptId),
          );
          final q2 = qb2.build();
          final existing = q2.findFirst();
          q2.close();

          final entity = TranscriptSummaryEntity(
            id: existing?.id ?? 0, // 0 => insert; existing.id => update
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


  @override
  Widget build(BuildContext context) {
    final hasSummary = _summaryText != null && _summaryText!.trim().isNotEmpty;
    final canRegenerate =
        !_generating && _modelAvailable && _modelPath != null;

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
          IconButton(
            tooltip: 'Regenerate',
            onPressed: canRegenerate
                ? () => _generateSummary(userTriggered: true)
                : null,
            icon: const Icon(Icons.refresh),
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
                  child: Text(
                    _summaryText!,
                    style: const TextStyle(fontSize: 15, height: 1.4),
                  ),
                ),
              )
            else if (!_generating)
              const Text(
                'No summary yet. Use the regenerate button to create one.',
                style: TextStyle(color: Colors.white70),
              ),
          ],
        ),
      ),
    );
  }
}
