// lib/transcript/background_transcriber.dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../audio_preprocess.dart';
import '../audio_utils.dart';
import '../model_bootstrap.dart';
import '../speaker_embedding.dart';
import 'isolated_speaker_matcher.dart';

import 'transcription_models.dart';
import 'transcription_compute.dart' show transcribeToResult;

// ✅ Your Qwen model service (adjust import path if different)
import '../qwen_model_service.dart';

// ✅ Your isolate-based runner you pasted (adjust import path if different)
import '../llm_service.dart' show LLMService;

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

  // ✅ target speakers stored int where 0 == null/auto
  static const _kTargetSpeakers = 'bg_target_speakers';

  // ✅ language (always stored as non-null String; default 'auto')
  static const _kLang = 'bg_lang';

  static const _kProgressProcessedSec = 'progress_processed_sec';
  static const _kProgressTotalSec = 'progress_total_sec';
  static const _kProgressStage = 'progress_stage';

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

    // diarization
    int? targetSpeakers,

    // language code ('auto','en','bn','hi','es')
    String lang = 'auto',
  }) async {
    await FlutterForegroundTask.saveData(key: _kWavPath, value: wavPath);
    await FlutterForegroundTask.saveData(
      key: _kTranslate,
      value: translateToEnglish,
    );

    // ✅ busy true for the whole job (all chunks)
    await FlutterForegroundTask.saveData(key: _kBusyTranscribing, value: true);

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
      key: _kTargetSpeakers,
      value: targetSpeakers ?? 0, // 0 means null/auto
    );

    await FlutterForegroundTask.saveData(
      key: _kLang,
      value: (lang.trim().isEmpty) ? 'auto' : lang.trim(),
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

  static Future<int?> getLastResultId() async {
    final v = await FlutterForegroundTask.getData<int>(key: _kResultId);
    return v;
  }

  static StreamSubscription<dynamic> onData(
    void Function(dynamic data) handler,
  ) {
    FlutterForegroundTask.addTaskDataCallback(handler);
    final ctrl = StreamController<dynamic>();
    ctrl.onCancel = () => FlutterForegroundTask.removeTaskDataCallback(handler);
    return ctrl.stream.listen((_) {});
  }
}

class _TranscribeTaskHandler extends TaskHandler {
  final QwenModelService _qwenService = QwenModelService();

  String _fmtMmSs(double sec) {
    final s = (sec.isFinite && sec > 0) ? sec : 0.0;
    final total = s.round();
    final m = total ~/ 60;
    final ss = (total % 60).toString().padLeft(2, '0');
    return '$m:$ss';
  }

  String _escapeTurnText(String s) {
    // TSV safety: avoid newlines/tabs breaking parsing
    return s
        .replaceAll('\t', ' ')
        .replaceAll('\r', ' ')
        .replaceAll('\n', ' ')
        .trim();
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
    // If model produced nothing, keep original prompt (we will reject later anyway).
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
    b.writeln('- Do NOT rewrite, paraphrase, summarize, or change grammar/structure.');
    b.writeln('- Keep punctuation/casing as-is as much as possible.');
    b.writeln('- Output ONLY TSV lines, same count, same first 3 columns.');
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

      // Strict guardrail: if model changed ANY of the first 3 columns -> reject.
      if (spk != orig.speaker || startStr != origStart || endStr != origEnd) {
        return turns;
      }

      out.add(LiteTurn(spk, orig.startSec, orig.endSec, text));
    }

    return out;
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

    if (wavPath == null || wavPath.isEmpty) {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Transcription failed',
        notificationText: 'No audio path',
      );
      await FlutterForegroundTask.stopService();
      return;
    }

    // ✅ Determine typo-fix availability (NO storing/searching/saving)
    bool typoModelReady = false;
    String typoModelPath = '';
    try {
      typoModelReady = await _qwenService.isModelDownloaded();
      if (typoModelReady) {
        typoModelPath = (await _qwenService.modelFilePath()).trim();
        if (typoModelPath.isEmpty) typoModelReady = false;
      }
    } catch (_) {
      typoModelReady = false;
      typoModelPath = '';
    }

    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Transcribing…',
        notificationText: 'Preparing Transcript',
      );

      const double chunkSec = 10 * 60.0;

      final cleaned = await preprocessWav16kMono(wavPath);
      final totalDuration = await readWavDuration(cleaned);

      final wavInfo = await parseWavInfo(cleaned);
      final totalChunks = (totalDuration / chunkSec).ceil().clamp(1, 1 << 30);

      // Speaker continuity across chunks (only anonymous labels S1, S2...)
      final globalCentroids = <String, Float32List>{};
      int nextGlobalSpeaker = 1;

      bool isAnon(String s) => RegExp(r'^S\d+$').hasMatch(s.trim());

      Float32List normalize(Float32List v) {
        double n = 0;
        for (final x in v) {
          n += x * x;
        }
        n = math.sqrt(math.max(n, 1e-12));
        final out = Float32List(v.length);
        for (int i = 0; i < v.length; i++) {
          out[i] = v[i] / n;
        }
        return out;
      }

      Future<Map<String, String>> buildSpeakerMapForChunk({
        required String chunkPath,
        required TranscriptionResult r,
      }) async {
        final localLabels = <String>{};
        for (final t in r.turns) {
          if (isAnon(t.speaker)) localLabels.add(t.speaker);
        }
        if (localLabels.isEmpty) return const {};

        // Load models once
        final mp = await ensureDiarizationModels();
        final emb = await SpeakerEmbedder.instance(mp.embOnnx);

        final wave = readWaveSimple(chunkPath);
        final samples = wave.samples;
        final fs = wave.sampleRate;

        // ✅ Hard guard: Titanet expects 16k
        if (fs != 16000 || samples.isEmpty) return const {};

        const double windowSec = 2.5;
        const int maxSegsPerSpeaker = 3;

        final localCentroids = <String, Float32List>{};

        for (final lab in localLabels) {
          // ✅ Only segments long enough to support fixed embedding window.
          // Pick LONGEST for better SNR / stability.
          final segs =
              r.turns
                  .where((t) => t.speaker == lab)
                  .where((t) => (t.endSec - t.startSec) >= windowSec)
                  .toList()
                ..sort(
                  (a, b) =>
                      (b.endSec - b.startSec).compareTo(a.endSec - a.startSec),
                );

          if (segs.isEmpty) continue;

          final embs = <Float32List>[];

          for (final s in segs.take(maxSegsPerSpeaker)) {
            final startIndex = (s.startSec * fs).round();
            final endIndex = (s.endSec * fs).round();
            if (endIndex <= startIndex) continue;

            // ✅ Fixed-window embedding avoids ORT shape crash.
            final v = await emb.embedFromSamplesFixedWindow(
              samples: samples,
              sampleRate: fs,
              startIndex: startIndex,
              endIndex: endIndex,
              windowSec: windowSec,
            );
            if (v.isNotEmpty) embs.add(v);
          }

          if (embs.isEmpty) continue;

          final len = embs.first.length;
          final sum = Float32List(len);
          for (final v in embs) {
            final m = math.min(len, v.length);
            for (int i = 0; i < m; i++) {
              sum[i] += v[i];
            }
          }
          for (int i = 0; i < len; i++) {
            sum[i] /= embs.length;
          }
          localCentroids[lab] = normalize(sum);
        }

        if (localCentroids.isEmpty) return const {};

        // ✅ NEW: stabilize speaker count across chunks
        // - Accept match with threshold + margin vs 2nd best
        // - DO NOT create new global speaker for "maybe same person"
        // - Only create new global speaker when similarity is clearly low
        const double matchTh = 0.74; // chunk-to-chunk is harder than within-chunk
        const double matchMargin = 0.03;
        const double newSpeakerFloor = 0.62; // below this => truly new

        final mapping = <String, String>{};

        for (final e in localCentroids.entries) {
          final localLab = e.key;
          final vec = e.value;

          String? bestName;
          double best = -1;
          double secondBest = -1;

          globalCentroids.forEach((name, g) {
            final sim = IsolatedSpeakerMatcher.cosine(vec, g);
            if (sim > best) {
              secondBest = best;
              best = sim;
              bestName = name;
            } else if (sim > secondBest) {
              secondBest = sim;
            }
          });

          final okMatch = bestName != null &&
              best >= matchTh &&
              (best - secondBest) >= matchMargin;

          if (okMatch) {
            mapping[localLab] = bestName!;

            // Optional: slowly adapt centroid (helps drift across long recordings)
            // Weighted update to reduce noise; keep normalized.
            final prev = globalCentroids[bestName!];
            if (prev != null && prev.length == vec.length) {
              final out = Float32List(vec.length);
              for (int i = 0; i < vec.length; i++) {
                out[i] = (prev[i] * 0.85) + (vec[i] * 0.15);
              }
              globalCentroids[bestName!] = normalize(out);
            }

            continue;
          }

          // ✅ key: prevent speaker explosion.
          // If it's "close-ish", do NOT mint a new global label.
          if (best >= newSpeakerFloor) {
            // Keep local label; we still preserve transcript text/timestamps.
            mapping[localLab] = localLab;
            continue;
          }

          // ✅ Only now: create a truly new global speaker
          final newName = 'S$nextGlobalSpeaker';
          nextGlobalSpeaker += 1;
          globalCentroids[newName] = vec;
          mapping[localLab] = newName;
        }

        return mapping;
      }

      Future<void> emitProgress({
        required String stage,
        required double processedSec,
      }) async {
        final pct = (totalDuration > 0)
            ? (processedSec / totalDuration * 100).round()
            : 0;

        await FlutterForegroundTask.saveData(
          key: BackgroundTranscriber._kProgressProcessedSec,
          value: processedSec,
        );
        await FlutterForegroundTask.saveData(
          key: BackgroundTranscriber._kProgressTotalSec,
          value: totalDuration,
        );
        await FlutterForegroundTask.saveData(
          key: BackgroundTranscriber._kProgressStage,
          value: stage,
        );

        await FlutterForegroundTask.updateService(
          notificationTitle: '$stage…',
          notificationText:
              '${_fmtMmSs(processedSec)} / ${_fmtMmSs(totalDuration)}  ($pct%)',
        );
      }

      final tmpDir = Directory(
        '${Directory.systemTemp.path}/tx_chunks_${DateTime.now().millisecondsSinceEpoch}',
      )..createSync(recursive: true);

      final merged = <LiteTurn>[];
      String modelName = 'whisper';
      String resultLang = lang;

      for (int ci = 0; ci < totalChunks; ci++) {
        final start = ci * chunkSec;
        final end = math.min(totalDuration, (ci + 1) * chunkSec);
        if (end <= start + 0.05) break;

        final humanChunk = ci + 1;
        await emitProgress(
          stage: 'Preparing (chunk $humanChunk/$totalChunks)',
          processedSec: start,
        );

        final slicePath =
            '${tmpDir.path}/chunk_${humanChunk.toString().padLeft(3, '0')}.wav';

        await trimWav16kMonoPcm(
          inputPath: cleaned,
          startSec: start,
          endSec: end,
          outputPath: slicePath,
          preParsedInfo: wavInfo,
        );

        // Run existing pipeline on CHUNK
        final chunkResult = await transcribeToResult(
          wavPath: slicePath,
          titleHint: null,
          targetSpeakers: targetSpeakers,
          lang: lang,
          onProgress: ({
            required String stage,
            required double processedSec,
            required double totalSec,
          }) async {
            final local = (processedSec.isFinite ? processedSec : 0.0);
            final globalProcessed = math.min(totalDuration, start + local);
            await emitProgress(
              stage: '$stage (chunk $humanChunk/$totalChunks)',
              processedSec: globalProcessed,
            );
          },
        );

        modelName = chunkResult.model;
        resultLang = chunkResult.lang;

        final spkMap = await buildSpeakerMapForChunk(
          chunkPath: slicePath,
          r: chunkResult,
        );

        // Map -> global speakers + offset timestamps (chunk local -> global)
        final chunkTurnsMapped = <LiteTurn>[];
        for (final t in chunkResult.turns) {
          final spk = spkMap[t.speaker] ?? t.speaker;
          chunkTurnsMapped.add(
            LiteTurn(spk, t.startSec + start, t.endSec + start, t.text),
          );
        }

        // ✅ Post-process typos per chunk (only if Qwen model exists locally)
        if (typoModelReady && chunkTurnsMapped.isNotEmpty) {
          await emitProgress(
            stage: 'Fixing typos (chunk $humanChunk/$totalChunks)',
            processedSec: math.min(totalDuration, start + 0.01),
          );

          final fixedTurns = await _typoFixChunkTurnsIfPossible(
            modelPath: typoModelPath,
            modelReady: typoModelReady,
            turns: chunkTurnsMapped,
          );

          merged.addAll(fixedTurns);
        } else {
          merged.addAll(chunkTurnsMapped);
        }

        await emitProgress(
          stage: 'Finalizing (chunk $humanChunk/$totalChunks)',
          processedSec: end,
        );

        try {
          File(slicePath).deleteSync();
        } catch (_) {}
      }

      try {
        if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      } catch (_) {}

      // Clean preprocessed temp WAV if different from input
      if (cleaned != wavPath) {
        try {
          File(cleaned).deleteSync();
        } catch (_) {}
      }

      // Merge consecutive turns with same speaker
      merged.sort((a, b) => a.startSec.compareTo(b.startSec));
      final outTurns = <LiteTurn>[];
      LiteTurn? cur;
      for (final t in merged) {
        final txt = t.text.trim();
        if (txt.isEmpty) continue;

        if (cur == null) {
          cur = LiteTurn(t.speaker, t.startSec, t.endSec, txt);
          continue;
        }

        final gap = t.startSec - cur.endSec;
        final same = (t.speaker == cur.speaker);

        if (same && gap >= -0.05 && gap <= 0.5) {
          cur = LiteTurn(
            cur.speaker,
            cur.startSec,
            math.max(cur.endSec, t.endSec),
            '${cur.text} $txt'.trim(),
          );
        } else {
          outTurns.add(cur);
          cur = LiteTurn(t.speaker, t.startSec, t.endSec, txt);
        }
      }
      if (cur != null) outTurns.add(cur);

      await emitProgress(stage: 'Finalizing', processedSec: totalDuration);

      final firstText = outTurns.isNotEmpty ? outTurns.first.text.trim() : '';
      final title = (titleHint != null && titleHint.trim().isNotEmpty)
          ? titleHint.trim()
          : (firstText.isEmpty
                ? null
                : (firstText.length > 48
                      ? '${firstText.substring(0, 48)}…'
                      : firstText));

      final result = TranscriptionResult(
        model: modelName,
        lang: resultLang,
        durationSec: totalDuration,
        title: title,
        turns: outTurns,
      );

      FlutterForegroundTask.sendDataToMain({
        'type': 'transcribe_result',
        'existingId': existingId,
        'wavPath': wavPath,
        'payload': result.toJson(),
        'translated': translate, // keep for your UI if needed
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
        'error': e.toString(),
      });
      await FlutterForegroundTask.updateService(
        notificationTitle: e.toString(),
        notificationText: 'See app',
      );
    } finally {
      await FlutterForegroundTask.saveData(
        key: BackgroundTranscriber._kBusyTranscribing,
        value: false,
      );
      await FlutterForegroundTask.stopService();
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool bySystem) async {
    await FlutterForegroundTask.saveData(
      key: BackgroundTranscriber._kBusyTranscribing,
      value: false,
    );
  }
}