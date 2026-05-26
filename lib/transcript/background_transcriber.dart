// lib/transcript/background_transcriber.dart
import 'dart:async';
import 'dart:ui';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'transcription_models.dart';
import 'transcription_compute.dart' show transcribeToResult;

// ✅ Typo-fix LLM runner
import '../llm_service.dart' show LLMService;

// ✅ Qwen model path provider
import '../qwen_model_service.dart';

@pragma('vm:entry-point')
void transcribeStartCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(_TranscribeTaskHandler());
}

class BackgroundTranscriber {
  static const _serviceId = 741;

  static const _kWavPath = 'bg_wav_path';
  static const _kTranslate = 'bg_translate';
  static const _kTitleHint = 'bg_title_hint';
  static const _kExistingId = 'bg_existing_id';
  static const _kResultId = 'bg_result_id';
  static const _kBusyTranscribing = 'busy_transcribing';
  static const _kActiveTranscriptId = 'bg_active_transcript_id';

  // ✅ target speakers stored int where 0 == null/auto
  static const _kTargetSpeakers = 'bg_target_speakers';

  // ✅ language (always stored as non-null String; default 'auto')
  static const _kLang = 'bg_lang';

  static const _kProgressProcessedSec = 'progress_processed_sec';
  static const _kProgressTotalSec = 'progress_total_sec';
  static const _kProgressStage = 'progress_stage';
  static const _kTypoFixEnabled = 'bg_typo_fix_enabled_int';
  static const _kPrefTypoFixEnabled = 'pref_typo_fix_enabled';

  static Future<void> init() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'transcribe_channel',
        channelName: 'Transcription',
        channelDescription: 'Background transcription service',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.once(),
        allowWakeLock: true,
        allowWifiLock: false,
        autoRunOnBoot: false,
      ),
    );

    FlutterForegroundTask.initCommunicationPort();
  }

  static Future<void> start({
    required String wavPath,
    bool translateToEnglish = false,
    String? titleHint,
    int? existingTranscriptId,
    // ✅ diarization
    int? targetSpeakers,

    // ✅ language code ('auto','en','bn','hi','es')
    String lang = 'auto',
  }) async {
    final sp = await SharedPreferences.getInstance();
    final typoFixEnabled = sp.getBool(_kPrefTypoFixEnabled) ?? false;

    if (Platform.isIOS) {
      return _startIOS(
        wavPath: wavPath,
        titleHint: titleHint,
        existingTranscriptId: existingTranscriptId,
        targetSpeakers: targetSpeakers,
        lang: lang,
        typoFixEnabled: typoFixEnabled,
      );
    }

    return _startAndroid(
      wavPath: wavPath,
      translateToEnglish: translateToEnglish,
      titleHint: titleHint,
      existingTranscriptId: existingTranscriptId,
      targetSpeakers: targetSpeakers,
      lang: lang,
      typoFixEnabled: typoFixEnabled,
    );
  }

  static Future<void> _startAndroid({
    required String wavPath,
    required bool translateToEnglish,
    String? titleHint,
    int? existingTranscriptId,
    int? targetSpeakers,
    required String lang,
    required bool typoFixEnabled,
  }) async {
    await FlutterForegroundTask.saveData(key: _kWavPath, value: wavPath);
    await FlutterForegroundTask.saveData(
      key: _kTranslate,
      value: translateToEnglish,
    );
    await FlutterForegroundTask.saveData(key: _kBusyTranscribing, value: true);
    await FlutterForegroundTask.saveData(
      key: _kActiveTranscriptId,
      value: existingTranscriptId ?? 0,
    );

    await FlutterForegroundTask.saveData(
      key: _kProgressProcessedSec,
      value: 0.0,
    );
    await FlutterForegroundTask.saveData(key: _kProgressTotalSec, value: 0.0);
    await FlutterForegroundTask.saveData(
      key: _kProgressStage,
      value: 'Preparing',
    );

    // ✅ store int (0 means null/auto)
    await FlutterForegroundTask.saveData(
      key: _kTargetSpeakers,
      value: targetSpeakers ?? 0,
    );

    // ✅ store language (must be non-null Object)
    await FlutterForegroundTask.saveData(
      key: _kLang,
      value: (lang.trim().isEmpty) ? 'auto' : lang.trim(),
    );

    await FlutterForegroundTask.saveData(
      key: _kTypoFixEnabled,
      value: typoFixEnabled ? 1 : 0,
    );

    if (titleHint != null) {
      await FlutterForegroundTask.saveData(key: _kTitleHint, value: titleHint);
    }
    if (existingTranscriptId != null) {
      await FlutterForegroundTask.saveData(
        key: _kExistingId,
        value: existingTranscriptId,
      );
    }

    await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      notificationTitle: 'Transcribing…',
      notificationText: 'Preparing Transcript',
      callback: transcribeStartCallback,
    );
  }

  static Future<void> _startIOS({
    required String wavPath,
    String? titleHint,
    int? existingTranscriptId,
    int? targetSpeakers,
    required String lang,
    required bool typoFixEnabled,
  }) async {
    try {
      await FlutterForegroundTask.saveData(
        key: _kBusyTranscribing,
        value: true,
      );
      await FlutterForegroundTask.saveData(
        key: _kActiveTranscriptId,
        value: existingTranscriptId ?? 0,
      );

      await FlutterForegroundTask.saveData(
        key: _kProgressProcessedSec,
        value: 0.0,
      );

      await FlutterForegroundTask.saveData(key: _kProgressTotalSec, value: 0.0);

      await FlutterForegroundTask.saveData(
        key: _kProgressStage,
        value: 'Preparing',
      );
      await FlutterForegroundTask.saveData(
        key: _kTypoFixEnabled,
        value: typoFixEnabled ? 1 : 0,
      );

      final result = await transcribeToResult(
        wavPath: wavPath,
        titleHint: titleHint,
        targetSpeakers: targetSpeakers,
        lang: lang,
        onProgress:
            ({
              required String stage,
              required double processedSec,
              required double totalSec,
            }) async {
              await FlutterForegroundTask.saveData(
                key: _kProgressProcessedSec,
                value: processedSec,
              );

              await FlutterForegroundTask.saveData(
                key: _kProgressTotalSec,
                value: totalSec,
              );

              await FlutterForegroundTask.saveData(
                key: _kProgressStage,
                value: stage,
              );
            },
      );

      Map<String, dynamic> payload = result.toJson();

      if (typoFixEnabled) {
        final helper = _TranscribeTaskHandler();
        final typoFixModelPath = await helper._resolveTypoFixModelPath();
        if (typoFixModelPath != null) {
          final turns = helper._turnsFromResultJson(payload);
          if (turns.isNotEmpty) {
            await FlutterForegroundTask.saveData(
              key: _kProgressStage,
              value: 'Fixing typos',
            );

            final fixedTurns = await helper._typoFixChunkTurnsIfPossible(
              modelPath: typoFixModelPath,
              modelReady: true,
              turns: turns,
            );

            payload['turns'] = helper._turnsToJson(fixedTurns);

            await FlutterForegroundTask.saveData(
              key: _kProgressStage,
              value: 'Finalizing',
            );
          }
        }
      }

      FlutterForegroundTask.sendDataToMain({
        'type': 'transcribe_result',
        'existingId': existingTranscriptId,
        'wavPath': wavPath,
        'payload': payload,
        'typoFixEnabled': typoFixEnabled,
      });
    } catch (e) {
      FlutterForegroundTask.sendDataToMain({
        'type': 'transcribe_error',
        'existingId': existingTranscriptId,
        'error': e.toString(),
      });
    } finally {
      await FlutterForegroundTask.saveData(
        key: _kBusyTranscribing,
        value: false,
      );
      await FlutterForegroundTask.saveData(key: _kActiveTranscriptId, value: 0);
    }
  }

  static Future<int?> getLastResultId() async {
    final v = await FlutterForegroundTask.getData<int>(key: _kResultId);
    return v;
  }

  /// ✅ FIXED: returns a cancelable subscription that *actually* removes callback.
  static StreamSubscription<dynamic> onData(
    void Function(dynamic data) handler,
  ) {
    FlutterForegroundTask.addTaskDataCallback(handler);
    return _TaskDataSubscription(
      onCancel: () {
        FlutterForegroundTask.removeTaskDataCallback(handler);
      },
    );
  }
}

/// Minimal StreamSubscription that only supports cancel()
class _TaskDataSubscription implements StreamSubscription<dynamic> {
  _TaskDataSubscription({required this.onCancel});

  final VoidCallback onCancel;
  bool _canceled = false;

  @override
  Future<void> cancel() async {
    if (_canceled) return;
    _canceled = true;
    onCancel();
  }

  // The rest are no-ops (not used by your code)
  @override
  void onData(void Function(dynamic data)? handleData) {}

  @override
  void onError(Function? handleError) {}

  @override
  void onDone(void Function()? handleDone) {}

  @override
  void pause([Future<void>? resumeSignal]) {}

  @override
  void resume() {}

  @override
  bool get isPaused => false;

  @override
  Future<E> asFuture<E>([E? futureValue]) => Future<E>.value(futureValue as E);
}

class _TranscribeTaskHandler extends TaskHandler {
  // ✅ create inside task isolate (no shared prefs, no UI state)
  final QwenModelService _qwenService = QwenModelService();

  String _fmtMmSs(double sec) {
    final s = (sec.isFinite && sec > 0) ? sec : 0.0;
    final total = s.round();
    final m = total ~/ 60;
    final ss = (total % 60).toString().padLeft(2, '0');
    return '$m:$ss';
  }

  // -------------------------
  // ✅ Typo-fix helpers
  // -------------------------

  String _escapeTurnText(String s) {
    // Keep TSV single-line per turn; avoid breaking format.
    return s
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\n', r'\n')
        .replaceAll('\t', r'\t');
  }

  Future<String> _runTypoFixModel({
    required String modelPath,
    required String prompt,
  }) async {
    final buf = StringBuffer();

    await for (final r in LLMService.generateText(
      prompt: prompt,
      modelPath: modelPath,
      maxTokens: 4096,
      temperature: 0.0,
      contextSize: 32768,
      conversationHistory: const [],
    )) {
      final newText = r['new_text'] as String?;
      if (newText != null && newText.isNotEmpty) buf.write(newText);
      if (r['done'] == true) break;
    }

    final out = buf.toString().trim();
    return out.isEmpty ? prompt : out;
  }

  Future<List<LiteTurn>> _typoFixChunkTurnsIfPossible({
    required String? modelPath,
    required bool modelReady,
    required List<LiteTurn> turns,
  }) async {
    if (!modelReady) return turns;
    final mp = (modelPath ?? '').trim();
    if (mp.isEmpty) return turns;
    if (turns.isEmpty) return turns;

    final b = StringBuffer();
    b.writeln('You will receive transcript turns in TSV format:');
    b.writeln('SPEAKER<TAB>START_SEC<TAB>END_SEC<TAB>TEXT');
    b.writeln('');
    b.writeln('Task: Fix ONLY obvious typos in the TEXT field.');
    b.writeln('- Do NOT change SPEAKER, START_SEC, END_SEC.');
    b.writeln(
      '- Do NOT rewrite, paraphrase, summarize, or change grammar/structure.',
    );
    b.writeln('- Keep punctuation/casing as-is as much as possible.');
    b.writeln('- Output ONLY TSV lines, same count, same first 3 columns.');
    b.writeln('- if no ovious typos return the text as it is');
    b.writeln('');
    b.writeln('TSV:');
    for (final t in turns) {
      b.writeln(
        '${t.speaker}\t${t.startSec.toStringAsFixed(2)}\t${t.endSec.toStringAsFixed(2)}\t${_escapeTurnText(t.text)}',
      );
    }

    final fixedRaw = await _runTypoFixModel(
      modelPath: mp,
      prompt: b.toString(),
    );

    final lines = fixedRaw
        .split('\n')
        .map((e) => e.trimRight())
        .where((e) => e.trim().isNotEmpty)
        .toList();

    int firstTsv = -1;
    for (int i = 0; i < lines.length; i++) {
      if (!lines[i].contains('\t')) continue;
      final parts = lines[i].split('\t');
      if (parts.length >= 4) {
        firstTsv = i;
        break;
      }
    }
    if (firstTsv < 0) return turns;

    final tsvLines = lines.sublist(firstTsv);
    if (tsvLines.length < turns.length) return turns;

    final out = <LiteTurn>[];
    for (int i = 0; i < turns.length; i++) {
      final raw = tsvLines[i];
      final parts = raw.split('\t');
      if (parts.length < 4) return turns;

      final spk = parts[0].trim();
      final startStr = parts[1].trim();
      final endStr = parts[2].trim();
      final text = parts.sublist(3).join('\t').trim();

      final orig = turns[i];
      final origStart = orig.startSec.toStringAsFixed(2);
      final origEnd = orig.endSec.toStringAsFixed(2);

      if (spk != orig.speaker || startStr != origStart || endStr != origEnd) {
        return turns;
      }

      out.add(LiteTurn(spk, orig.startSec, orig.endSec, text));
    }

    return out;
  }

  List<LiteTurn> _turnsFromResultJson(Map<String, dynamic> j) {
    final raw = j['turns'];
    if (raw is! List) return const <LiteTurn>[];
    final out = <LiteTurn>[];
    for (final it in raw) {
      if (it is! Map) continue;
      final m = it.cast<String, dynamic>();
      final spk = (m['speaker'] ?? m['spk'] ?? '').toString();
      final s0 = m['startSec'] ?? m['start_sec'] ?? m['start'] ?? 0.0;
      final s1 = m['endSec'] ?? m['end_sec'] ?? m['end'] ?? 0.0;
      final txt = (m['text'] ?? '').toString();
      final start = (s0 is num) ? s0.toDouble() : double.tryParse('$s0') ?? 0.0;
      final end = (s1 is num) ? s1.toDouble() : double.tryParse('$s1') ?? 0.0;
      if (spk.isEmpty) continue;
      out.add(LiteTurn(spk, start, end, txt));
    }
    return out;
  }

  List<Map<String, dynamic>> _turnsToJson(List<LiteTurn> turns) {
    return turns
        .map(
          (t) => <String, dynamic>{
            'speaker': t.speaker,
            'startSec': t.startSec,
            'endSec': t.endSec,
            'text': t.text,
          },
        )
        .toList();
  }

  Future<void> _setStageNotification(String stage, {String? text}) async {
    await FlutterForegroundTask.saveData(
      key: BackgroundTranscriber._kProgressStage,
      value: stage,
    );
    await FlutterForegroundTask.updateService(
      notificationTitle: '$stage…',
      notificationText: text ?? stage,
    );
  }

  // ✅ resolve typo-fix model path INSIDE background task
  Future<String?> _resolveTypoFixModelPath() async {
    try {
      final ok = await _qwenService.isModelDownloaded();
      if (!ok) return null;
      final path = await _qwenService.modelFilePath();
      final p = (path).trim();
      if (p.isEmpty) return null;
      return p;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final wavPath = await FlutterForegroundTask.getData<String>(
      key: BackgroundTranscriber._kWavPath,
    );

    final translate =
        await FlutterForegroundTask.getData<bool>(
          key: BackgroundTranscriber._kTranslate,
        ) ??
        false;

    final titleHint = await FlutterForegroundTask.getData<String>(
      key: BackgroundTranscriber._kTitleHint,
    );
    final existingId = await FlutterForegroundTask.getData<int>(
      key: BackgroundTranscriber._kExistingId,
    );

    final tsRaw = await FlutterForegroundTask.getData(
      key: BackgroundTranscriber._kTargetSpeakers,
    );
    final tsInt = (tsRaw is int) ? tsRaw : 0;
    final int? targetSpeakers = (tsInt <= 0) ? null : tsInt;

    final langRaw = await FlutterForegroundTask.getData(
      key: BackgroundTranscriber._kLang,
    );
    final String lang = (langRaw is String && langRaw.trim().isNotEmpty)
        ? langRaw.trim()
        : 'auto';

    final rawTypo = await FlutterForegroundTask.getData(
      key: BackgroundTranscriber._kTypoFixEnabled,
    );
    final typoFixEnabled = _readTypoFixEnabled(rawTypo);

    if (wavPath == null || wavPath.isEmpty) {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Transcription failed',
        notificationText: 'No audio path',
      );
      await FlutterForegroundTask.stopService();
      return;
    }

    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Transcribing…',
        notificationText: 'Preparing Transcript',
      );

      final TranscriptionResult result = await transcribeToResult(
        wavPath: wavPath,
        titleHint: titleHint,
        targetSpeakers: targetSpeakers,
        lang: lang,
        onProgress:
            ({
              required String stage,
              required double processedSec,
              required double totalSec,
            }) async {
              final pct = (totalSec > 0)
                  ? (processedSec / totalSec * 100).round()
                  : 0;

              await FlutterForegroundTask.saveData(
                key: BackgroundTranscriber._kProgressProcessedSec,
                value: processedSec,
              );
              await FlutterForegroundTask.saveData(
                key: BackgroundTranscriber._kProgressTotalSec,
                value: totalSec,
              );
              await FlutterForegroundTask.saveData(
                key: BackgroundTranscriber._kProgressStage,
                value: stage,
              );

              await FlutterForegroundTask.updateService(
                notificationTitle: '$stage…',
                notificationText:
                    '${_fmtMmSs(processedSec)} / ${_fmtMmSs(totalSec)}  ($pct%)',
              );
            },
      );

      Map<String, dynamic> payload = result.toJson();

      if (typoFixEnabled) {
        final typoFixModelPath = await _resolveTypoFixModelPath();
        if (typoFixModelPath != null) {
          final turns = _turnsFromResultJson(payload);
          if (turns.isNotEmpty) {
            await _setStageNotification(
              'Fixing typos',
              text: 'Fixing obvious typos…',
            );

            final fixedTurns = await _typoFixChunkTurnsIfPossible(
              modelPath: typoFixModelPath,
              modelReady: true,
              turns: turns,
            );

            payload['turns'] = _turnsToJson(fixedTurns);

            await _setStageNotification(
              'Finalizing',
              text: 'Preparing result…',
            );
          }
        }
      }

      FlutterForegroundTask.sendDataToMain({
        'type': 'transcribe_result',
        'existingId': existingId,
        'wavPath': wavPath,
        'payload': payload,
        'translate': translate,
        'typoFixEnabled': typoFixEnabled,
      });

      if (existingId != null) {
        await FlutterForegroundTask.saveData(
          key: BackgroundTranscriber._kResultId,
          value: existingId,
        );
      }

      await FlutterForegroundTask.updateService(
        notificationTitle: 'Transcription complete',
        notificationText: 'Transcript is ready',
      );
    } catch (e) {
      FlutterForegroundTask.sendDataToMain({
        'type': 'transcribe_error',
        'existingId': existingId,
        'error': e.toString(),
      });
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Error!',
        notificationText: 'See app',
      );
    } finally {
      await FlutterForegroundTask.saveData(
        key: BackgroundTranscriber._kBusyTranscribing,
        value: false,
      );
      await FlutterForegroundTask.saveData(
        key: BackgroundTranscriber._kActiveTranscriptId,
        value: 0,
      );
      await FlutterForegroundTask.stopService();
    }
  }

  bool _readTypoFixEnabled(dynamic v) {
    if (v is bool) return v;
    if (v is int) return v != 0;
    if (v is num) return v.toInt() != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      if (s == 'true' || s == '1' || s == 'yes' || s == 'on') return true;
      if (s == 'false' || s == '0' || s == 'no' || s == 'off') return false;
    }
    return false;
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool bySystem) async {
    await FlutterForegroundTask.saveData(
      key: BackgroundTranscriber._kBusyTranscribing,
      value: false,
    );
    await FlutterForegroundTask.saveData(
      key: BackgroundTranscriber._kActiveTranscriptId,
      value: 0,
    );
  }
}
