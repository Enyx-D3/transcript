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

    messages.add(Message(isUser ? Role.user : Role.assistant, text));

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

/// ✅ Chunk summary prompt
String _buildChunkSummaryPrompt({
  required String chunkText,
  required int chunkIndex,
  required int totalChunks,
  required int maxWord,
}) {
  return '''
Summarize the following *Transcript Chunk* ($chunkIndex/$totalChunks).
The summary should be at max $maxWord words.
Focus on:
- Key points
- Decisions (if any)
- Action items (if any, with owners if mentioned)
- Risks / open questions (if any)
- Dont add any thing
Transcript Chunk:
$chunkText
''';
}

/// ✅ Final merge prompt: summarize concatenated chunk summaries
String _buildFinalMergeSummaryPrompt({
  required String combinedChunkSummaries,
  required int maxWord,
}) {
  return '''
You are given multiple chunk summaries of a single meeting.
Create ONE final summary (max $maxWord words).

Focus on:
- Overall summary
- Key decisions if available
- Action items if available (with owners if mentioned)
- Risks / open questions if available
- Dont add any thing

Chunk Summaries:
$combinedChunkSummaries
''';
}

/// Build QA prompt over transcript (as user content)
String _buildQaPrompt({required String question, required String transcript}) {
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

String _buildTypoFixPrompt({required String transcript}) {
  return '''
You are a transcript typo fixer.

Task:
Fix ONLY obvious typos / misspellings / wrong words caused by speech-to-text.
Do NOT change grammar, sentence structure, tone, or meaning.
Do NOT rewrite, paraphrase, summarize, or reorder anything.
Do NOT add new punctuation styles. Keep punctuation and line breaks as-is as much as possible.
Do NOT add speaker labels or timestamps if not present.
Return ONLY the corrected transcript text. No explanations.

Transcript:
$transcript
''';
}

String _buildTranscriptFinalizerPrompt({
  required String language,
  required String blockId,
  required String timeStart,
  required String timeEnd,
  required String speakerHint,
  required List<String> knownNames,
  required List<String> knownTerms,
  required String moonshineText,
  required String sherpaText,
  required String alignedCandidate,
  required String speakerDetailsJson,
  required String rollingContext,
}) {
  return '''
language: $language
block_id: $blockId
time_start: $timeStart
time_end: $timeEnd
speaker_hint: $speakerHint
known_names: ${knownNames.join(', ')}
known_terms: ${knownTerms.join(', ')}

speaker_details:
$speakerDetailsJson

rolling_context:
$rollingContext

moonshine:
$moonshineText

sherpa:
$sherpaText

aligned_candidate:
$alignedCandidate

task:
Merge the ASR outputs into one clean meeting transcript.
Preserve meaning.
Do not invent details.
Do not summarize.
Do not remove important details.
Fix punctuation, casing, names, acronyms, and obvious ASR errors.
Keep the speaker meaning unchanged.
Return only the final transcript text.
''';
}

/// ✅ Split transcript into chunks by word-count (simple + stable)
List<String> _splitIntoChunksByWords(String text, {required int chunkWords}) {
  final words = text
      .split(RegExp(r'\s+'))
      .where((w) => w.trim().isNotEmpty)
      .toList();
  if (words.isEmpty) return const [];

  final chunks = <String>[];
  for (int i = 0; i < words.length; i += chunkWords) {
    final end = (i + chunkWords < words.length) ? i + chunkWords : words.length;
    chunks.add(words.sublist(i, end).join(' '));
  }
  return chunks;
}

/// Low-level runner: takes logical messages, wraps in Qwen format, calls fllamaChat.
Future<void> _runChat({
  required Map<String, dynamic> request,
  required SendPort replyPort,
  required List<Message> messages,
}) async {
  final qwenPrompt = _formatQwenPrompt(messages);
  debugPrint(
    'Qwen prompt length=${qwenPrompt.length} preview='
    '${qwenPrompt.substring(0, qwenPrompt.length.clamp(0, 240))}',
  );

  String lastSentText = '';

  await fllamaChat(
    OpenAiRequest(
      // Single user message containing the fully formatted Qwen prompt
      messages: [Message(Role.user, qwenPrompt)],
      modelPath: request['model_path'],
      maxTokens: request['max_tokens'],
      temperature: (request['temperature'] ?? 0.7) as double,
      contextSize: request['context_size'],
      numGpuLayers: (request['num_gpu_layers'] ?? 99) as int,
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
        replyPort.send({'new_text': newText, 'full_text': chunk, 'done': done});
      } else if (done) {
        replyPort.send({'done': true, 'full_text': chunk});
      }
    },
  );
}

/// ✅ Run chat and RETURN final full output (useful for chunk summaries)
Future<String> _runChatCollect({
  required Map<String, dynamic> request,
  required SendPort replyPort,
  required List<Message> messages,
  bool stream = true,
}) async {
  final qwenPrompt = _formatQwenPrompt(messages);

  String lastSentText = '';
  String finalText = '';

  await fllamaChat(
    OpenAiRequest(
      messages: [Message(Role.user, qwenPrompt)],
      modelPath: request['model_path'],
      maxTokens: request['max_tokens'],
      temperature: (request['temperature'] ?? 0.7) as double,
      contextSize: request['context_size'],
      numGpuLayers: (request['num_gpu_layers'] ?? 99) as int,
      frequencyPenalty: 0.5,
      presencePenalty: 0.6,
      topP: 0.95,
    ),
    (String chunk, String messageId, bool done) {
      finalText = chunk;

      if (!stream) return;

      String newText = chunk;
      if (chunk.startsWith(lastSentText)) {
        newText = chunk.substring(lastSentText.length);
      }

      if (newText.isNotEmpty) {
        lastSentText = chunk;
        replyPort.send({'new_text': newText, 'full_text': chunk, 'done': done});
      } else if (done) {
        replyPort.send({'done': true, 'full_text': chunk});
      }
    },
  );

  return finalText;
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
          final history = message['history'] as List<Map<String, dynamic>>?;

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

        /// ✅ UPDATED: Meeting transcript summary (hierarchical chunk -> merge -> final)
        case 'summary':
          final transcript = request['transcript'] as String;
          final int finalMaxWord = request['max_tokens'] as int;

          const int chunkWords = 1200;
          const int chunkSummaryWord = 180;

          final chunks = _splitIntoChunksByWords(
            transcript,
            chunkWords: chunkWords,
          );

          if (chunks.isEmpty) {
            replyPort.send({'done': true, 'full_text': ''});
            break;
          }

          final chunkSummaries = <String>[];

          // 1) summarize each chunk silently (NO streaming)
          for (int i = 0; i < chunks.length; i++) {
            final logicalMessages = <Message>[
              Message(
                Role.system,
                'You summarize meetings clearly and concisely.',
              ),
              Message(
                Role.user,
                _buildChunkSummaryPrompt(
                  chunkText: chunks[i],
                  chunkIndex: i + 1,
                  totalChunks: chunks.length,
                  maxWord: chunkSummaryWord,
                ),
              ),
            ];

            final chunkReq = Map<String, dynamic>.from(request);
            chunkReq['max_tokens'] = chunkSummaryWord;

            final chunkOut = await _runChatCollect(
              request: chunkReq,
              replyPort: replyPort, // ignored because stream:false
              messages: logicalMessages,
              stream: false,
            );

            chunkSummaries.add(chunkOut.trim());
          }

          // 2) combine chunk summaries
          final combined = chunkSummaries
              .where((s) => s.isNotEmpty)
              .join('\n\n');

          if (combined.trim().isEmpty) {
            debugPrint(
              'LLM summary skipped final merge because chunk summaries were empty.',
            );
            replyPort.send({'done': true, 'full_text': ''});
            break;
          }

          // 3) final summary over combined summaries (STREAM this one)
          final finalMessages = <Message>[
            Message(
              Role.system,
              'You summarize meetings clearly and concisely.',
            ),
            Message(
              Role.user,
              _buildFinalMergeSummaryPrompt(
                combinedChunkSummaries: combined,
                maxWord: finalMaxWord,
              ),
            ),
          ];

          await _runChat(
            request: request,
            replyPort: replyPort,
            messages: finalMessages,
          );

          break;

        case 'typo_fix':
          final transcript = request['transcript'] as String;

          final logicalMessages = <Message>[
            Message(Role.system, 'You only fix typos in transcripts.'),
            Message(Role.user, _buildTypoFixPrompt(transcript: transcript)),
          ];

          await _runChat(
            request: request,
            replyPort: replyPort,
            messages: logicalMessages,
          );
          break;

        case 'finalize_transcript':
          final language = (request['language'] ?? 'en').toString();
          final blockId = (request['block_id'] ?? '').toString();
          final timeStart = (request['time_start'] ?? '').toString();
          final timeEnd = (request['time_end'] ?? '').toString();
          final speakerHint = (request['speaker_hint'] ?? '').toString();
          final knownNames =
              (request['known_names'] as List<dynamic>? ?? const [])
                  .map((e) => e.toString())
                  .toList();
          final knownTerms =
              (request['known_terms'] as List<dynamic>? ?? const [])
                  .map((e) => e.toString())
                  .toList();
          final moonshineText = (request['moonshine_text'] ?? '').toString();
          final sherpaText = (request['sherpa_text'] ?? '').toString();
          final alignedCandidate = (request['aligned_candidate'] ?? '')
              .toString();
          final speakerDetailsJson = (request['speaker_details_json'] ?? '[]')
              .toString();
          final rollingContext = (request['rolling_context'] ?? '').toString();

          final logicalMessages = <Message>[
            Message(
              Role.system,
              'You repair transcript blocks and never chat.',
            ),
            Message(
              Role.user,
              _buildTranscriptFinalizerPrompt(
                language: language,
                blockId: blockId,
                timeStart: timeStart,
                timeEnd: timeEnd,
                speakerHint: speakerHint,
                knownNames: knownNames,
                knownTerms: knownTerms,
                moonshineText: moonshineText,
                sherpaText: sherpaText,
                alignedCandidate: alignedCandidate,
                speakerDetailsJson: speakerDetailsJson,
                rollingContext: rollingContext,
              ),
            ),
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
              _buildQaPrompt(question: question, transcript: transcript),
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

  static Stream<Map<String, dynamic>> fixTypos({
    required String transcript,
    required String modelPath,
    int maxTokens = 2048,
    double temperature = 0.0, // ✅ important for “no rewriting”
    int contextSize = qwenMaxContext,
  }) async* {
    await initialize();
    final sendPort = await _isolateCompleter!.future;
    final responsePort = ReceivePort();

    sendPort.send({
      'type': 'typo_fix',
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

  static Stream<Map<String, dynamic>> finalizeTranscriptBlock({
    required String language,
    required String blockId,
    required String timeStart,
    required String timeEnd,
    required String speakerHint,
    required List<String> knownNames,
    required List<String> knownTerms,
    required String moonshineText,
    required String sherpaText,
    required String alignedCandidate,
    required String speakerDetailsJson,
    required String rollingContext,
    required String modelPath,
    int maxTokens = 512,
    double temperature = 0.1,
    int contextSize = qwenMaxContext,
    int numGpuLayers = 99,
  }) async* {
    await initialize();
    final sendPort = await _isolateCompleter!.future;
    final responsePort = ReceivePort();

    sendPort.send({
      'type': 'finalize_transcript',
      'request': {
        'language': language,
        'block_id': blockId,
        'time_start': timeStart,
        'time_end': timeEnd,
        'speaker_hint': speakerHint,
        'known_names': knownNames,
        'known_terms': knownTerms,
        'moonshine_text': moonshineText,
        'sherpa_text': sherpaText,
        'aligned_candidate': alignedCandidate,
        'speaker_details_json': speakerDetailsJson,
        'rolling_context': rollingContext,
        'model_path': modelPath,
        'max_tokens': maxTokens,
        'temperature': temperature,
        'context_size': contextSize,
        'num_gpu_layers': numGpuLayers,
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
