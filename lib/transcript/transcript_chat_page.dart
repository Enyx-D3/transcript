// lib/transcript/transcript_chat_page.dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../objectbox.g.dart';

import '../llm_service.dart' show LLMService, qwenMaxContext;
import '../qwen_model_service.dart';
import '../whisper_service.dart' show ModelProgress;

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

  bool _initializing = true;
  bool _modelAvailable = false;
  String? _modelPath;

  bool _sending = false;
  String? _error;
  List<TranscriptChatMessageEntity> _messages = const [];

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _initModelState();
  }

  @override
  void dispose() {
    _qwenSub?.cancel();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    final obx = ObjectBox.I;
    final qb = obx.chatMessages
        .query(TranscriptChatMessageEntity_.transcriptId.equals(widget.transcriptId))
      ..order(TranscriptChatMessageEntity_.createdAt);
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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent + 80,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

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

    final obx = ObjectBox.I;
    final now = DateTime.now();

    // 1) Persist user message
    final userMsg = TranscriptChatMessageEntity(
      transcriptId: widget.transcriptId,
      isUser: true,
      text: question,
      createdAt: now,
    );
    obx.chatMessages.put(userMsg);

    _inputCtrl.clear();
    await _loadMessages();

    try {
      // 2) Build transcript text as context
      final qbTurns = obx.turns
          .query(TranscriptTurnEntity_.transcript.equals(widget.transcriptId))
        ..order(TranscriptTurnEntity_.startSec);
      final qTurns = qbTurns.build();
      final turns = qTurns.find();
      qTurns.close();

      final buf = StringBuffer();
      for (final u in turns) {
        buf.writeln('${u.speakerLabel}: ${u.text}');
      }
      final transcriptText = buf.toString();

      // 3) Call QA API (streaming)
      String fullReply = '';
      await for (final evt in LLMService.qaOnTranscript(
        transcript: transcriptText,
        question: question,
        modelPath: _modelPath!,
        maxTokens: 512,
        temperature: 0.3,
        contextSize: qwenMaxContext,
      )) {
        final fullChunk = evt['full_text'] as String?;
        final newText = evt['new_text'] as String?;
        if (fullChunk != null && fullChunk.isNotEmpty) {
          fullReply = fullChunk;
        } else if (newText != null && newText.isNotEmpty) {
          fullReply += newText;
        }

        // (Optional streaming UI: show "typing" bubble.)
        // For now we only update once at the end.
      }

      // 4) Persist assistant reply
      final botMsg = TranscriptChatMessageEntity(
        transcriptId: widget.transcriptId,
        isUser: false,
        text: fullReply,
        createdAt: DateTime.now(),
      );
      obx.chatMessages.put(botMsg);

      await _loadMessages();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to get AI answer: $e';
      });
    } finally {
      if (!mounted) return;
      setState(() => _sending = false);
    }
  }

  Widget _buildBubble(TranscriptChatMessageEntity m) {
    final isUser = m.isUser;
    final align =
        isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bgColor = isUser
        ? const Color(0xFF8E7CFF)
        : const Color(0xFF1E1E26);
    final textColor = Colors.white;

    return Column(
      crossAxisAlignment: align,
      children: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: const BoxConstraints(maxWidth: 320),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            m.text,
            style: TextStyle(color: textColor),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return Scaffold(
        appBar: AppBar(title: const Text('Ask AI')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final canSend = _modelAvailable && _modelPath != null && !_sending;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ask AI'),
      ),
      body: Column(
        children: [
          if (!_modelAvailable)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                'Download the Qwen model in the Model picker to ask new questions. '
                'You can still read past answers below.',
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
              itemCount: _messages.length,
              itemBuilder: (ctx, i) {
                final m = _messages[i];
                return _buildBubble(m);
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputCtrl,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: 'Ask about this transcript…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: _sending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    onPressed: canSend ? _send : null,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
