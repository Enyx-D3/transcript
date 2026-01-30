import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../objectbox.g.dart';

import '../llm_service.dart' show LLMService, qwenMaxContext;
import '../qwen_model_service.dart';
import '../whisper_service.dart' show ModelProgress;

import '../report/report_dialog.dart';
import '../report/report_service.dart';
import '../common/app_flushbar.dart';

// ✅ NEW (for clickable "Download model" banner)
import '../model_picker_page.dart';

class TranscriptChatPage extends StatefulWidget {
  const TranscriptChatPage({super.key, required this.transcriptId});

  final int transcriptId;

  @override
  State<TranscriptChatPage> createState() => _TranscriptChatPageState();
}

class _TranscriptChatPageState extends State<TranscriptChatPage> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  final QwenModelService _qwenService = QwenModelService();
  StreamSubscription<ModelProgress>? _qwenSub;

  final ReportService _reportService = const ReportService(
    baseUrl: 'https://enyx.app',
  );

  bool _initializing = true;
  bool _modelAvailable = false;
  String? _modelPath;

  bool _sending = false;
  String? _error;

  List<TranscriptChatMessageEntity> _messages = const [];

  StreamSubscription<Map<String, dynamic>>? _streamSub;

  // ✅ throttling: don’t write to DB too often while streaming
  int _lastPersistMs = 0;

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _initModelState();
  }

  @override
  void dispose() {
    _qwenSub?.cancel();
    _streamSub?.cancel();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // =========================
  // Helpers
  // =========================

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      final to = _scrollCtrl.position.maxScrollExtent + 160;
      if (!animate) {
        _scrollCtrl.jumpTo(to);
      } else {
        _scrollCtrl.animateTo(
          to,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _cleanModelOutput(String s) {
    var out = s.trim();

    // Remove any Qwen template tokens that leaked into the output
    out = out.replaceAll('<|im_end|>', '');
    out = out.replaceAll('<|im_start|>assistant', '');
    out = out.replaceAll('<|im_start|>', '');

    // If the model echoed "Answer:"
    if (out.toLowerCase().startsWith('answer:')) {
      out = out.substring('answer:'.length).trim();
    }

    return out.trim();
  }

  bool _shouldPersistNow() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastPersistMs >= 450) {
      _lastPersistMs = now;
      return true;
    }
    return false;
  }

  // =========================
  // Load & model state
  // =========================

  Future<void> _loadMessages() async {
    final obx = ObjectBox.I;
    final qb = obx.chatMessages.query(
      TranscriptChatMessageEntity_.transcriptId.equals(widget.transcriptId),
    )..order(TranscriptChatMessageEntity_.createdAt);
    final q = qb.build();
    final rows = q.find();
    q.close();

    if (!mounted) return;
    setState(() => _messages = rows);
    _scrollToBottom();
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

  Future<void> _openModelPicker() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ModelPickerPage()));
    await _initModelState(); // refresh model availability on return
  }

  // =========================
  // Send question (STREAMING UI)
  // =========================

  Future<void> _send() async {
    final question = _inputCtrl.text.trim();
    if (question.isEmpty || _sending) return;

    if (!_modelAvailable || _modelPath == null) {
      setState(() {
        _error = 'Please download the Qwen model first (Model picker).';
      });
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
    });

    // Cancel any previous stream (safety)
    await _streamSub?.cancel();
    _streamSub = null;

    final obx = ObjectBox.I;

    // 1) Persist user message
    obx.chatMessages.put(
      TranscriptChatMessageEntity(
        transcriptId: widget.transcriptId,
        isUser: true,
        text: question,
        createdAt: DateTime.now(),
      ),
    );

    _inputCtrl.clear();

    // 2) Insert placeholder assistant message (for live streaming)
    final placeholder = TranscriptChatMessageEntity(
      transcriptId: widget.transcriptId,
      isUser: false,
      text: '…',
      createdAt: DateTime.now(),
    );
    final placeholderId = obx.chatMessages.put(placeholder);

    await _loadMessages(); // show user msg + placeholder bubble

    try {
      // 3) Build transcript context
      final qbTurns = obx.turns.query(
        TranscriptTurnEntity_.transcript.equals(widget.transcriptId),
      )..order(TranscriptTurnEntity_.startSec);
      final qTurns = qbTurns.build();
      final turns = qTurns.find();
      qTurns.close();

      final buf = StringBuffer();
      for (final u in turns) {
        final txt = u.text.trim();
        if (txt.isEmpty) continue;
        buf.writeln('${u.speakerLabel}: $txt');
      }
      final transcriptText = buf.toString().trim();

      if (transcriptText.isEmpty) {
        throw Exception('Transcript has no segments yet.');
      }

      // 4) Stream QA (update UI live)
      String latestFullText = '';
      String accum = '';

      final stream = LLMService.qaOnTranscript(
        transcript: transcriptText,
        question: question,
        modelPath: _modelPath!,
        maxTokens: 512,
        temperature: 0.3,
        contextSize: qwenMaxContext,
      );

      final doneCompleter = Completer<void>();

      _streamSub = stream.listen(
        (evt) {
          final full = (evt['full_text'] ?? '') as String;
          final newText = (evt['new_text'] ?? '') as String;
          final done = evt['done'] == true;

          if (full.isNotEmpty) {
            latestFullText = full;
          } else if (newText.isNotEmpty) {
            accum += newText;
          }

          final raw = latestFullText.isNotEmpty ? latestFullText : accum;
          final cleaned = _cleanModelOutput(raw);

          // ✅ update local UI immediately
          if (mounted) {
            setState(() {
              final idx = _messages.indexWhere((m) => m.id == placeholderId);
              if (idx != -1) {
                _messages[idx].text = cleaned.isEmpty ? '…' : cleaned;
              }
            });
            _scrollToBottom();
          }

          // ✅ persist occasionally (throttled)
          if (_shouldPersistNow()) {
            final msg = obx.chatMessages.get(placeholderId);
            if (msg != null) {
              msg.text = cleaned.isEmpty ? '…' : cleaned;
              obx.chatMessages.put(msg);
            }
          }

          if (done && !doneCompleter.isCompleted) {
            doneCompleter.complete();
          }
        },
        onError: (err, st) {
          if (!doneCompleter.isCompleted) {
            doneCompleter.completeError(err, st);
          }
        },
      );

      await doneCompleter.future;

      // 5) Finalize + persist final clean text
      var finalText = latestFullText.isNotEmpty ? latestFullText : accum;
      finalText = _cleanModelOutput(finalText);

      if (finalText.trim().isEmpty) {
        finalText = "I don't know based on the transcript.";
      }

      final msg = obx.chatMessages.get(placeholderId);
      if (msg != null) {
        msg.text = finalText;
        obx.chatMessages.put(msg);
      }

      await _loadMessages();
    } catch (e) {
      // mark placeholder as error
      final msg = obx.chatMessages.get(placeholderId);
      if (msg != null) {
        msg.text = 'Failed to get answer.';
        obx.chatMessages.put(msg);
      }

      if (!mounted) return;
      setState(() {
        _error = 'Failed to get AI answer: $e';
      });
      await AppFlushbar.error(context, message: 'Failed to get answer.');
    } finally {
      await _streamSub?.cancel();
      _streamSub = null;

      if (!mounted) return;
      setState(() => _sending = false);
    }
  }

  // =========================
  // UI helpers
  // =========================

  Future<void> _copyText(String text) async {
    final t = text.trim();
    if (t.isEmpty) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Nothing to copy.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: t));
    if (!mounted) return;
    await AppFlushbar.success(context, message: 'Copied.');
  }

  Future<void> _reportAiMessage(TranscriptChatMessageEntity m) async {
    final meta = <String, dynamic>{
      'source': 'transcript_chat',
      'transcriptId': widget.transcriptId,
      'messageId': m.id,
      'createdAt': m.createdAt.toIso8601String(),
    };

    await showReportDialog(
      outerContext: context,
      responseText: m.text,
      meta: meta,
      sendReport:
          ({
            required String reason,
            required String note,
            required String response,
            Map<String, dynamic>? meta,
          }) {
            return _reportService.sendReport(
              reason: reason,
              note: note,
              response: response,
              meta: meta,
            );
          },
    );
  }

  Widget _chipAction({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withOpacity(0.10)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white70),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBubble(TranscriptChatMessageEntity m) {
    final isUser = m.isUser;

    final align = isUser ? Alignment.centerRight : Alignment.centerLeft;
    final bubbleColor = isUser
        ? Colors.white30
        : const Color(0xFF14141B);
    final borderColor = isUser
        ? Colors.transparent
        : Colors.white.withOpacity(0.10);

    return Align(
      alignment: align,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: isUser
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: borderColor),
                ),
                child: Text(
                  m.text,
                  style: const TextStyle(color: Colors.white, height: 1.35),
                ),
              ),

              // ✅ Actions for AI only
              if (!isUser)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 2),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _chipAction(
                        icon: Icons.copy,
                        label: 'Copy',
                        onTap: () => _copyText(m.text),
                      ),
                      _chipAction(
                        icon: Icons.flag_outlined,
                        label: 'Report',
                        onTap: () => _reportAiMessage(m),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modelBanner() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _openModelPicker, // ✅ clickable
        child: Ink(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withOpacity(0.10)),
          ),
          child: Row(
            children: [
              const Icon(Icons.smart_toy_outlined, color: Colors.white70),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Model required to ask new questions.\nTap to open Model Download.',
                  style: TextStyle(color: Colors.white70, height: 1.25),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color:  Colors.white.withOpacity(0.18),
                  border: Border.all(
                    color:  Colors.white.withOpacity(0.35),
                  ),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.download, size: 16, color: Colors.white),
                    SizedBox(width: 6),
                    Text(
                      'Download',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _composer(bool canSend) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF14141B),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.10)),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  cursorColor: Colors.white,
                  controller: _inputCtrl,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    hintText: 'Ask about this transcript…',
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: canSend ? _send : null,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2,color: Colors.white,),
                      )
                    : const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // =========================
  // Build
  // =========================

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          titleSpacing: 12, // ✅ nice left padding
          title: Row(
            children: [
              _IconPillButton(
                tooltip: 'Back',
                icon: Icons.arrow_back,
                onTap: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: 10),
              const Text('Ask AI'),
            ],
          ),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final canSend = _modelAvailable && _modelPath != null && !_sending;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 12, // ✅ nice left padding
        title: Row(
          children: [
            _IconPillButton(
              tooltip: 'Back',
              icon: Icons.arrow_back,
              onTap: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 10),
            const Text('Ask AI'),
          ],
        ),
      ),
      body: Column(
        children: [
          if (!_modelAvailable) _modelBanner(),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.redAccent.withOpacity(0.25)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              itemCount: _messages.length,
              itemBuilder: (ctx, i) => _buildBubble(_messages[i]),
            ),
          ),

          _composer(canSend),
        ],
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

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: (isDark ? Colors.white : Colors.black).withOpacity(0.06),
            border: Border.all(
              color: (isDark ? Colors.white : Colors.black).withOpacity(0.10),
            ),
          ),
          child: Icon(icon, size: 20),
        ),
      ),
    );
  }
}
