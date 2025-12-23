// lib/tabs/ai_chat_tab.dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../llm_service.dart';
import '../qwen_model_service.dart';
import '../whisper_service.dart' show ModelProgress; // for Qwen progress type

class AiChatTab extends StatefulWidget {
  const AiChatTab({super.key});

  @override
  State<AiChatTab> createState() => _AiChatTabState();
}

class _AiChatTabState extends State<AiChatTab> {
  final List<Map<String, dynamic>> _history = []; // {isUser: bool, text: String}
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  StreamSubscription<Map<String, dynamic>>? _streamSub;
  StreamSubscription<ModelProgress>? _qwenSub;

  bool _isSending = false;
  bool _initializing = true;
  bool _modelAvailable = false;
  String? _modelPath;

  final QwenModelService _qwenService = QwenModelService(); // singleton

  @override
  void initState() {
    super.initState();
    _initModelState();
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    _qwenSub?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initModelState() async {
    // 1) Initial check: is the model already downloaded?
    final exists = await _qwenService.isModelDownloaded();
    final path = await _qwenService.modelFilePath();

    if (!mounted) return;

    setState(() {
      _initializing = false;
      _modelAvailable = exists;
      _modelPath = exists ? path : null;
    });

    // 2) Listen for future Qwen downloads (from the ModelPicker page)
    _qwenSub = _qwenService.progress.listen((p) async {
      if (!mounted) return;

      // Only care when a download fully completes successfully
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

    setState(() {
      _history.add({'isUser': true, 'text': text});
      _history.add({'isUser': false, 'text': ''}); // placeholder for LLM reply
      _isSending = true;
    });
    _scrollToBottom();

    final llmIndex = _history.length - 1;

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
        setState(() {
          _history[llmIndex]['text'] = fullText;
        });
        _scrollToBottom();
      },
      onError: (err) {
        setState(() {
          _history[llmIndex]['text'] =
              'Sorry, something went wrong.\n$err';
          _isSending = false;
        });
        _scrollToBottom();
      },
      onDone: () {
        setState(() {
          _isSending = false;
        });
        _scrollToBottom();
      },
    );
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

  Widget _buildMessageBubble(Map<String, dynamic> msg) {
    final bool isUser = msg['isUser'] as bool;
    final String text = msg['text'] as String;

    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text,style: TextStyle(color: Colors.black),),
    );

    final userIcon = const Icon(Icons.person, size: 20);
    final llmIcon = const Icon(Icons.smart_toy_outlined, size: 20);

    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(child: bubble),
            const SizedBox(width: 8),
            userIcon,
          ],
        ),
      );
    } else {
      return Align(
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            llmIcon,
            const SizedBox(width: 8),
            Flexible(child: bubble),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Initial async check still running
    if (_initializing) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    // Model not available yet
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

    // Normal chat UI
    return SafeArea(
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: const [
                Icon(Icons.smart_toy_outlined),
                SizedBox(width: 8),
                Text(
                  'AI Chat',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Messages
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              itemCount: _history.length,
              itemBuilder: (context, index) {
                final msg = _history[index];
                return _buildMessageBubble(msg);
              },
            ),
          ),

          const Divider(height: 1),

          // Input row
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
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
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
