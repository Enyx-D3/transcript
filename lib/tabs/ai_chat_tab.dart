import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:transcript/common/app_flushbar.dart';
import 'package:transcript/common/confirm_dialog.dart';

import '../llm_service.dart';
import '../qwen_model_service.dart';
import '../model_progress.dart';

import '../objectbox/objectbox_store.dart';

import '../report/report_service.dart';
import '../report/report_dialog.dart';

class AiChatTab extends StatefulWidget {
  const AiChatTab({super.key});

  @override
  State<AiChatTab> createState() => _AiChatTabState();
}

class _AiChatTabState extends State<AiChatTab> {
  final List<Map<String, dynamic>> _history =
      []; // {isUser: bool, text: String}
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  StreamSubscription<Map<String, dynamic>>? _streamSub;
  StreamSubscription<ModelProgress>? _qwenSub;

  bool _isSending = false;
  bool _initializing = true;
  bool _modelAvailable = false;
  String? _modelPath;

  final QwenModelService _qwenService = QwenModelService();

  late final ObjectBox _obx;

  // assistant streaming persistence
  int? _assistantMsgId;
  int? _assistantHistoryIndex;

  Timer? _saveTimer;
  String _pendingAssistantText = '';

  late final ReportService _reportService = ReportService(
    baseUrl: 'https://enyx.app', // e.g. https://xyz.netlify.app
    authToken: null, // optional
  );

  @override
  void initState() {
    super.initState();
    _obx = ObjectBox.I;

    _initModelState();
    _loadChatFromDb();
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    _qwenSub?.cancel();
    _saveTimer?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _loadChatFromDb() {
    final msgs = _obx.loadAiChat();
    setState(() {
      _history
        ..clear()
        ..addAll(msgs.map((m) => {'isUser': m.isUser, 'text': m.text}));
    });
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

  Future<void> _sendMessage() async {
    if (_isSending) return;
    if (!_modelAvailable || _modelPath == null) return;

    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    _inputController.clear();
    FocusScope.of(context).unfocus();

    final previousHistory = List<Map<String, dynamic>>.from(_history);

    // ✅ save user message immediately
    _obx.addAiChatMessage(isUser: true, text: text);

    setState(() {
      _history.add({'isUser': true, 'text': text});
      _history.add({'isUser': false, 'text': ''}); // assistant placeholder
      _isSending = true;
    });
    _scrollToBottom();

    _assistantHistoryIndex = _history.length - 1;

    // ✅ create assistant message in DB now (empty), update during streaming
    _assistantMsgId = _obx.addAiChatMessage(isUser: false, text: '');

    await _streamSub?.cancel();

    final stream = LLMService.generateText(
      prompt: text,
      modelPath: _modelPath!,
      maxTokens: 512,
      temperature: 0.7,
      contextSize: 32768,
      conversationHistory: previousHistory,
    );

    _streamSub = stream.listen(
      (event) {
        final fullText = (event['full_text'] ?? '') as String;

        final idx = _assistantHistoryIndex;
        if (idx != null && idx >= 0 && idx < _history.length) {
          setState(() {
            _history[idx]['text'] = fullText;
          });
        }

        _throttledSaveAssistant(fullText);
        _scrollToBottom();
      },
      onError: (err) {
        final msg = 'Sorry, something went wrong.\n$err';

        final idx = _assistantHistoryIndex;
        if (idx != null && idx >= 0 && idx < _history.length) {
          setState(() {
            _history[idx]['text'] = msg;
            _isSending = false;
          });
        } else {
          setState(() => _isSending = false);
        }

        _saveAssistantNow(msg);
        _scrollToBottom();
      },
      onDone: () {
        setState(() => _isSending = false);

        final idx = _assistantHistoryIndex;
        final finalText = (idx != null && idx >= 0 && idx < _history.length)
            ? (_history[idx]['text'] as String)
            : '';

        _saveAssistantNow(finalText);
        _scrollToBottom();
      },
    );
  }

  void _throttledSaveAssistant(String text) {
    _pendingAssistantText = text;
    _saveTimer ??= Timer(const Duration(milliseconds: 400), () {
      _saveTimer = null;
      _saveAssistantNow(_pendingAssistantText);
    });
  }

  void _saveAssistantNow(String text) {
    final id = _assistantMsgId;
    if (id == null || id == 0) return;
    _obx.updateAiChatMessage(id, text);
  }

  Future<void> _clearChat() async {
    await _streamSub?.cancel();
    _streamSub = null;

    _saveTimer?.cancel();
    _saveTimer = null;

    _assistantMsgId = null;
    _assistantHistoryIndex = null;
    _pendingAssistantText = '';

    setState(() {
      _isSending = false;
      _history.clear();
    });

    _obx.clearAiChat();
  }

  void _scrollToBottom() {
    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollController.hasClients) return;

      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

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

  Future<void> _reportText(String responseText) async {
    await showReportDialog(
      outerContext: context,
      responseText: responseText,
      sendReport:
          ({
            Map<String, dynamic>? meta, // ✅ add this
            required String reason,
            required String note,
            required String response,
          }) async {
            // (optional) you can forward meta later if your backend supports it
            await _reportService.sendReport(
              reason: reason,
              note: note,
              response: response,
            );
          },
    );
  }

  Widget _buildMessageBubble(Map<String, dynamic> msg) {
    final bool isUser = msg['isUser'] as bool;
    final String text = (msg['text'] as String?) ?? '';

    // Bubble styles
    final bubbleColor = isUser
        ? const Color(0xFF8E7CFF)
        : const Color(0xFF1E1E26);
    final textColor = Colors.white;

    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      margin: const EdgeInsets.symmetric(vertical: 4),
      constraints: const BoxConstraints(maxWidth: 320),
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(text, style: TextStyle(color: textColor)),
    );

    // ✅ AI actions (below bubble)
    Widget aiActions() {
      // Don’t show buttons while streaming empty placeholder
      final canAct = text.trim().isNotEmpty;

      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton.icon(
              onPressed: canAct ? () => _copyText(text) : null,
              icon: const Icon(Icons.copy, size: 12),
              label: const Text('Copy', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 6),
            TextButton.icon(
              onPressed: canAct ? () => _reportText(text) : null,
              icon: const Icon(Icons.flag_outlined, size: 12),
              label: const Text('Report', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );
    }

    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [bubble],
        ),
      );
    } else {
      return Align(
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [bubble, aiActions()],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_modelAvailable) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Text(
            'Please download the model first.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                const Icon(Icons.smart_toy_outlined),
                const SizedBox(width: 8),
                const Text(
                  'AI Chat',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Clear chat',
                  // Disable button if history is already empty and no message is currently being generated
                  onPressed: (_history.isEmpty && !_isSending)
                      ? null
                      : () async {
                          // 1. Call your custom helper dialog
                          final confirmed = await showConfirmDeleteDialog(
                            context,
                            title: 'Clear chat history?',
                            message:
                                'This will permanently delete all messages in this conversation.',
                            confirmText: 'Clear All',
                          );

                          // 2. If the user confirmed (true), proceed with deletion
                          if (confirmed) {
                            await _clearChat();

                            // 3. Show the success notification using your Flushbar utility
                            if (context.mounted) {
                              AppFlushbar.success(
                                context,
                                message: 'Chat history has been cleared.',
                              );
                            }
                          }
                        },
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: _history.length,
              itemBuilder: (context, index) =>
                  _buildMessageBubble(_history[index]),
            ),
          ),

          const Divider(height: 1),

          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    decoration: const InputDecoration(
                      hintText: 'Type a message…',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: _isSending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                  onPressed: _isSending ? null : _sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
