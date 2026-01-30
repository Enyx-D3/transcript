import 'dart:ffi';
import 'dart:isolate';
import 'dart:async';
import 'package:fllama/fllama.dart';
import 'package:flutter/material.dart';

const int qwenMaxContext = 32768;
/// Qwen chat template – used for ALL requests.
String _formatQwenPrompt(List<Message> messages) {
  final prompt = StringBuffer();
  for (final msg in messages) {
    if (msg.role == Role.system) {
      prompt.write('<|im_start|>system\n${msg.text}<|im_end|>\n');
    } else if (msg.role == Role.user) {
      prompt.write('<|im_start|>user\n${msg.text}<|im_end|>\n');
    } else if (msg.role == Role.assistant) {
      prompt.write('<|im_start|>assistant\n${msg.text}<|im_end|>\n');
    }
  }
  prompt.write('<|im_start|>assistant');
  return prompt.toString();
}

/// Build logical chat messages (system + history + latest user prompt)
List<Message> formatPromptForModel({
  required String modelPath, // kept for compatibility; not used
  required String prompt,
  required List<Map<String, dynamic>> conversationHistory,
}) {
  final messages = <Message>[
    Message(
      Role.system,
      'You are a concise AI assistant. Keep responses brief and relevant to the conversation context.',
    ),
  ];

  for (var i = 0; i < conversationHistory.length; i++) {
    final msg = conversationHistory[i];
    final isUser = msg['isUser'] as bool;
    final text = msg['text'] as String;

    messages.add(
      Message(isUser ? Role.user : Role.assistant, text),
    );

    // If an old user message is dangling without a response, add a placeholder assistant message
    if (isUser) {
      final hasAssistantNext =
          i + 1 < conversationHistory.length &&
          (conversationHistory[i + 1]['isUser'] == false);
      if (!hasAssistantNext) {
        messages.add(Message(Role.assistant, ''));
      }
    }
  }

  messages.add(Message(Role.user, prompt));
  return messages;
}

/// Build summary prompt over transcript (as user content)
String _buildSummaryPrompt(String transcript,int maxWord) {
  return '''
Summarize the following *Transcript*.
The summary should be at max $maxWord words.
Focus on:
- Overall summary
- Key decisions if available
- Action items if available (with owners if mentioned)
- Risks / open questions if available
- Dont add any thing
Transcript:
$transcript
''';
}

/// Build QA prompt over transcript (as user content)
String _buildQaPrompt({
  required String question,
  required String transcript,
}) {
  return '''
You must answer the *Question* strictly based on the *Transcript*.

Rules:
- Only use information from the transcript.
- If the answer is not clearly in the transcript, say: "I don't know based on the transcript."
- Keep the answer concise and directly address the question.

Transcript:
$transcript

Question:
$question

''';
}

/// Low-level runner: takes logical messages, wraps in Qwen format, calls fllamaChat.
Future<void> _runChat({
  required Map<String, dynamic> request,
  required SendPort replyPort,
  required List<Message> messages,
}) async {
  final qwenPrompt = _formatQwenPrompt(messages);
  debugPrint('Qwen prompt: $qwenPrompt');

  String lastSentText = '';

  await fllamaChat(
    OpenAiRequest(
      // Single user message containing the fully formatted Qwen prompt
      messages: [Message(Role.user, qwenPrompt)],
      modelPath: request['model_path'],
      maxTokens: request['max_tokens'],
      temperature: (request['temperature'] ?? 0.7) as double,
      contextSize: request['context_size'],
      numGpuLayers: 99,
      frequencyPenalty: 0.5,
      presencePenalty: 0.6,
      topP: 0.95,
    ),
    (String chunk, String messageId, bool done) {
      String newText = chunk;
      if (chunk.startsWith(lastSentText)) {
        newText = chunk.substring(lastSentText.length);
      }

      if (newText.isNotEmpty) {
        lastSentText = chunk;
        replyPort.send({
          'new_text': newText,
          'full_text': chunk,
          'done': done,
        });
      } else if (done) {
        replyPort.send({'done': true, 'full_text': chunk});
      }
    },
  );
}

class LLMService {
  static Completer<SendPort>? _isolateCompleter;
  static Isolate? _isolate;
  static ReceivePort? _receivePort;

  /// Initialize isolate once
  static Future<void> initialize() async {
    if (_isolate != null) return;

    _receivePort = ReceivePort();
    _isolateCompleter = Completer<SendPort>();

    _isolate = await Isolate.spawn(
      _isolateEntry,
      _receivePort!.sendPort,
      debugName: 'LLMIsolate',
    );

    _receivePort!.listen((message) {
      if (message is SendPort) {
        _isolateCompleter!.complete(message);
      }
    });
  }

  /// Isolate entry point
  static void _isolateEntry(SendPort mainSendPort) {
    final receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);

    receivePort.listen((message) async {
      if (message is! Map) return;

      final type = message['type'] as String?;
      if (type == null) return;

      final request = message['request'] as Map<String, dynamic>;
      final replyPort = message['replyPort'] as SendPort;

      switch (type) {
        /// General chat / prompt-enhance path
        case 'generate':
          final history =
              message['history'] as List<Map<String, dynamic>>?;

          if (history != null) {
            // Chat with conversation history
            final logicalMessages = formatPromptForModel(
              modelPath: request['model_path'],
              prompt: request['prompt'],
              conversationHistory: history,
            );

            await _runChat(
              request: request,
              replyPort: replyPort,
              messages: logicalMessages,
            );
          } else {
            // Prompt enhance / rewrite (no history)
            final logicalMessages = <Message>[
              Message(
                Role.system,
                'You rewrite and enhance the user\'s prompt while preserving its original intent. '
                'Make it clearer, more specific, and more effective for an AI assistant.',
              ),
              Message(Role.user, request['prompt'] as String),
            ];

            await _runChat(
              request: request,
              replyPort: replyPort,
              messages: logicalMessages,
            );
          }
          break;

        /// Meeting transcript summary
        case 'summary':
          final transcript = request['transcript'] as String;
          final maxWord = request['max_tokens'] as int;
          final logicalMessages = <Message>[
            Message(
              Role.system,
              'You summarize meetings clearly and concisely.',
            ),
            Message(Role.user, _buildSummaryPrompt(transcript,maxWord)),
          ];

          await _runChat(
            request: request,
            replyPort: replyPort,
            messages: logicalMessages,
          );
          break;

        /// Meeting transcript Q&A
        case 'qa':
          final transcript = request['transcript'] as String;
          final question = request['question'] as String;

          final logicalMessages = <Message>[
            Message(
              Role.system,
              'You answer questions strictly based on the provided meeting transcript.',
            ),
            Message(
              Role.user,
              _buildQaPrompt(
                question: question,
                transcript: transcript,
              ),
            ),
          ];

          await _runChat(
            request: request,
            replyPort: replyPort,
            messages: logicalMessages,
          );
          break;

        default:
          debugPrint('LLM isolate: unknown type $type');
      }
    });
  }

  /// Normal chat generation with conversation history
  static Stream<Map<String, dynamic>> generateText({
    required String prompt,
    required String modelPath,
    required int maxTokens,
    required double temperature,
    required int contextSize,
    required List<Map<String, dynamic>> conversationHistory,
  }) async* {
    await initialize();
    final sendPort = await _isolateCompleter!.future;
    final responsePort = ReceivePort();

    sendPort.send({
      'type': 'generate',
      'request': {
        'prompt': prompt,
        'model_path': modelPath,
        'max_tokens': maxTokens,
        'temperature': temperature,
        'context_size': contextSize,
      },
      'history': conversationHistory,
      'replyPort': responsePort.sendPort,
    });

    await for (final response in responsePort) {
      if (response is Map<String, dynamic>) {
        yield response;
        if (response['done'] == true) break;
      }
    }
    responsePort.close();
  }

  /// Prompt rewrite / enhancement (no history)
  static Stream<Map<String, dynamic>> rewritePrompt({
    required String prompt,
    required String modelPath,
    required int maxTokens,
    required double temperature,
    required int contextSize,
  }) async* {
    await initialize();
    final sendPort = await _isolateCompleter!.future;
    final responsePort = ReceivePort();

    sendPort.send({
      'type': 'generate',
      'request': {
        'prompt': prompt,
        'model_path': modelPath,
        'max_tokens': maxTokens,
        'temperature': temperature,
        'context_size': contextSize,
      },
      'history': null,
      'replyPort': responsePort.sendPort,
    });

    await for (final response in responsePort) {
      if (response is Map<String, dynamic>) {
        yield response;
        if (response['done'] == true) break;
      }
    }
    responsePort.close();
  }

  /// Meeting transcript summary (type 1)
  static Stream<Map<String, dynamic>> summarizeTranscript({
    required String transcript,
    required String modelPath,
    int maxTokens = 1025,
    double temperature = 0.3,
    int contextSize = qwenMaxContext,
  }) async* {
    await initialize();
    final sendPort = await _isolateCompleter!.future;
    final responsePort = ReceivePort();

    sendPort.send({
      'type': 'summary',
      'request': {
        'transcript': transcript,
        'model_path': modelPath,
        'max_tokens': maxTokens,
        'temperature': temperature,
        'context_size': contextSize,
      },
      'replyPort': responsePort.sendPort,
    });

    await for (final response in responsePort) {
      if (response is Map<String, dynamic>) {
        yield response;
        if (response['done'] == true) break;
      }
    }
    responsePort.close();
  }

  /// Meeting transcript Q&A (type 2)
  static Stream<Map<String, dynamic>> qaOnTranscript({
    required String transcript,
    required String question,
    required String modelPath,
    int maxTokens = 512,
    double temperature = 0.3,
    int contextSize = qwenMaxContext,
  }) async* {
    await initialize();
    final sendPort = await _isolateCompleter!.future;
    final responsePort = ReceivePort();

    sendPort.send({
      'type': 'qa',
      'request': {
        'transcript': transcript,
        'question': question,
        'model_path': modelPath,
        'max_tokens': maxTokens,
        'temperature': temperature,
        'context_size': contextSize,
      },
      'replyPort': responsePort.sendPort,
    });

    await for (final response in responsePort) {
      if (response is Map<String, dynamic>) {
        yield response;
        if (response['done'] == true) break;
      }
    }
    responsePort.close();
  }

  static void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _isolateCompleter = null;
    _receivePort?.close();
  }
}
