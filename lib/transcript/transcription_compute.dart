// lib/transcript/transcription_compute.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transcript/debug/speaker_memory.dart';

import '../audio_preprocess.dart';
import '../audio_utils.dart';
import '../llm_service.dart';
import '../model_bootstrap.dart';
import '../moonshine_service.dart';
import '../qwen_model_service.dart';
import '../speaker_embedding.dart';
import 'sherpa_secondary_asr_service.dart';
import 'transcript_alignment_service.dart';
import 'transcription_models.dart';
import 'isolated_embedding_diarization.dart'
    show runEmbeddingDiarizationInIsolate, IsolatedEmbeddingTurn;

typedef ProgressCallback =
    void Function({
      required String stage,
      required double processedSec,
      required double totalSec,
    });

String _logTs() => DateTime.now().toIso8601String();

void _pipelineLog(String step, String message) {
  debugPrint('[${_logTs()}][BG-PIPELINE][$step] $message');
}

void _pipelineError(String step, Object error, [StackTrace? st]) {
  _pipelineLog(step, 'ERROR: $error');
  if (st != null) {
    debugPrint('$st');
  }
}

// ---------------- Internal merged turn structure ----------------

class _Turn {
  final String spk; // final speaker label S1/S2/...
  final double a; // startSec
  final double b; // endSec
  _Turn(this.spk, this.a, this.b);
}

class _PreparedSegment {
  final int blockId;
  final IsolatedEmbeddingTurn turn;
  final String slicePath;
  final String speakerLabel;
  final SpeakerTurnDetail speakerDetail;

  const _PreparedSegment({
    required this.blockId,
    required this.turn,
    required this.slicePath,
    required this.speakerLabel,
    required this.speakerDetail,
  });
}

List<IsolatedEmbeddingTurn> _splitLongTurns(
  List<IsolatedEmbeddingTurn> turns, {
  double maxSegmentSec = 29.5,
}) {
  final out = <IsolatedEmbeddingTurn>[];
  for (final turn in turns) {
    final duration = turn.endSec - turn.startSec;
    if (duration <= maxSegmentSec) {
      out.add(turn);
      continue;
    }

    double start = turn.startSec;
    while (start < turn.endSec) {
      final end = math.min(turn.endSec, start + maxSegmentSec);
      out.add(
        IsolatedEmbeddingTurn(
          speaker: turn.speaker,
          startSec: start,
          endSec: end,
        ),
      );
      start = end;
    }
  }
  return out;
}

/// Merge consecutive segments for the same speaker if the gap between them
/// is <= [maxGap] seconds.
List<_Turn> _mergeGapAwareTurns(List<_Turn> segs, {double maxGap = 0.4}) {
  if (segs.isEmpty) return const [];
  final s = [...segs]..sort((a, b) => a.a.compareTo(b.a));
  final out = <_Turn>[];

  var cur = s.first;
  for (int i = 1; i < s.length; i++) {
    final n = s[i];
    if (n.spk == cur.spk && (n.a - cur.b) <= maxGap) {
      cur = _Turn(cur.spk, cur.a, math.max(cur.b, n.b));
    } else {
      out.add(cur);
      cur = n;
    }
  }
  out.add(cur);
  return out;
}

Future<({
  List<IsolatedEmbeddingTurn> turns,
  Map<String, String> speakerMatches,
})> _runDiarizationPipeline({
  required String wavPath,
  required double duration,
  required bool useIsolatedDiarization,
  required bool matchWithEnrolledSpeakers,
  required bool diarEnabled,
  required int? targetSpeakers,
}) async {
  final speakerMatches = <String, String>{};
  List<IsolatedEmbeddingTurn> diarizationTurns = [];

  if (!diarEnabled) {
    return (
      turns: [IsolatedEmbeddingTurn(speaker: 'S1', startSec: 0.0, endSec: duration)],
      speakerMatches: speakerMatches,
    );
  }

  final mp = await ensureDiarizationModels();

  if (useIsolatedDiarization) {
    try {
      Map<String, List<List<double>>> speakerMemoryData = {};
      if (matchWithEnrolledSpeakers) {
        try {
          final memory = await SpeakerMemory.instance();
          final allSpeakers = memory.dumpAll();
          allSpeakers.forEach((name, embeddings) {
            speakerMemoryData[name] = embeddings.map((emb) => emb.toList()).toList();
          });
        } catch (e) {
          _pipelineError('Diarization', e);
        }
      }

      final enhancedResult = await runEmbeddingDiarizationInIsolate(
        wavPath: wavPath,
        durationSec: duration,
        embOnnxPath: mp.embOnnx,
        windowSec: 2.5,
        hopSec: 1.25,
        stayThreshold: 0.68,
        switchThreshold: 0.80,
        switchConfirmWindows: 3,
        mergeClustersThreshold: 0.86,
        minClusterTalkSec: 2.5,
        minSegmentSec: 0.8,
        maxSpeakersCap: 8,
        targetSpeakers: targetSpeakers,
        matchSpeakers: matchWithEnrolledSpeakers,
        matchThreshold: 0.67,
        speakerMemoryData: speakerMemoryData,
      );
      diarizationTurns = enhancedResult.turns;
      speakerMatches.addAll(enhancedResult.speakerMatches);
    } catch (e, st) {
      _pipelineError('Diarization', e, st);
    }
  }

  if (diarizationTurns.isEmpty) {
    try {
      final emb = await SpeakerEmbedder.instance(mp.embOnnx);
      final merged = await _diarizeByEmbeddings(
        wavPath: wavPath,
        durationSec: duration,
        emb: emb,
        windowSec: 2.5,
        hopSec: 1.25,
        stayThreshold: 0.68,
        switchThreshold: 0.80,
        switchConfirmWindows: 3,
        mergeClustersThreshold: 0.86,
        minClusterTalkSec: 2.5,
        minSegmentSec: 0.8,
        maxSpeakersCap: 8,
      );

      diarizationTurns = merged
          .map(
            (t) => IsolatedEmbeddingTurn(
              speaker: t.spk,
              startSec: t.a,
              endSec: t.b,
            ),
          )
          .toList();
    } catch (e, st) {
      _pipelineError('Diarization', e, st);
    }
  }

  if (diarizationTurns.isEmpty) {
    diarizationTurns = [
      IsolatedEmbeddingTurn(speaker: 'S1', startSec: 0.0, endSec: duration),
    ];
  }

  return (turns: diarizationTurns, speakerMatches: speakerMatches);
}

// ---------------- Embedding-only diarization (non-isolated version) ----------------

double _cosine(Float32List a, Float32List b) {
  final n = math.min(a.length, b.length);
  if (n == 0) return 0;

  double dot = 0, na = 0, nb = 0;
  for (int i = 0; i < n; i++) {
    final x = a[i];
    final y = b[i];
    dot += x * y;
    na += x * x;
    nb += y * y;
  }
  if (na == 0 || nb == 0) return 0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

class _Cluster {
  final int id;
  Float32List centroid;
  int n;
  _Cluster(this.id, this.centroid) : n = 1;

  void update(Float32List v) {
    final m = math.min(centroid.length, v.length);
    if (m == 0) return;
    final out = Float32List(m);
    for (int i = 0; i < m; i++) {
      out[i] = (centroid[i] * n + v[i]) / (n + 1);
    }
    centroid = out;
    n += 1;
  }
}

/// Very small energy gate to avoid clustering silence.
bool _isSilent(Float32List samples, int a, int b, {double rmsThresh = 0.008}) {
  if (b <= a) return true;
  double s = 0;
  final len = b - a;
  // subsample for speed
  final step = (len / 800).ceil().clamp(1, 200);
  int count = 0;
  for (int i = a; i < b; i += step) {
    final x = samples[i];
    s += x * x;
    count++;
  }
  if (count == 0) return true;
  final rms = math.sqrt(s / count);
  return rms < rmsThresh;
}

/// Offline diarization by embeddings + online clustering.
/// No fixed num speakers required.
Future<List<_Turn>> _diarizeByEmbeddings({
  required String wavPath,
  required double durationSec,
  required SpeakerEmbedder emb,
  double windowSec = 2.5,
  double hopSec = 1.25,
  double stayThreshold = 0.60,
  double switchThreshold = 0.82,
  int switchConfirmWindows = 3,
  double mergeClustersThreshold = 0.76,
  double minClusterTalkSec = 1.5,
  double minSegmentSec = 0.8,
  int maxSpeakersCap = 8,
}) async {
  var wave = readWaveSimple(wavPath);
  var samples = wave.samples;
  final fs = wave.sampleRate;
  wave = Wave(samples: Float32List(0), sampleRate: fs);

  final win = (windowSec * fs).round().clamp(1, 1 << 30);
  final hop = (hopSec * fs).round().clamp(1, 1 << 30);
  final totalSamples = samples.length;

  final clusters = <_Cluster>[];
  int nextId = 1;

  final assigns = <({int a, int b, int cid})>[];

  int? currentCid;
  int? pendingCid;
  int pendingCount = 0;

  int i = 0;
  while (i < totalSamples) {
    final a = i;
    final b = math.min(a + win, totalSamples);
    if (b - a < (0.6 * fs)) break;

    if (_isSilent(samples, a, b)) {
      i += hop;
      continue;
    }

    Float32List v;
    try {
      v = await emb.embedFromSamplesRange(
        samples: samples,
        sampleRate: fs,
        startIndex: a,
        endIndex: b,
      );
    } catch (_) {
      i += hop;
      continue;
    }
    if (v.isEmpty) {
      i += hop;
      continue;
    }

    double best = -1;
    _Cluster? bestC;
    for (final c in clusters) {
      final sim = _cosine(c.centroid, v);
      if (sim > best) {
        best = sim;
        bestC = c;
      }
    }

    int candidateCid;

    if (bestC != null) {
      final isStay = (currentCid != null && bestC.id == currentCid);
      final th = isStay ? stayThreshold : switchThreshold;

      if (best >= th) {
        // Strong match
        if (best >= th + 0.05) bestC.update(v);
        candidateCid = bestC.id;
      } else {
        const newSpeakerFloor = 0.58;

        if (best > newSpeakerFloor || clusters.length >= maxSpeakersCap) {
          candidateCid = bestC.id;
        } else {
          candidateCid = nextId++;
          clusters.add(_Cluster(candidateCid, v));
        }
      }
    } else {
      candidateCid = nextId++;
      clusters.add(_Cluster(candidateCid, v));
    }

    // ---- Switch confirmation logic ----
    if (currentCid == null) {
      currentCid = candidateCid;
    } else if (candidateCid == currentCid) {
      pendingCid = null;
      pendingCount = 0;
    } else {
      if (pendingCid == candidateCid) {
        pendingCount++;
      } else {
        pendingCid = candidateCid;
        pendingCount = 1;
      }

      if (pendingCount >= switchConfirmWindows) {
        currentCid = candidateCid;
        pendingCid = null;
        pendingCount = 0;
      } else {
        candidateCid = currentCid; // Use current until confirmed
      }
    }

    assigns.add((a: a, b: b, cid: currentCid));
    i += hop;
  }

  // Release audio samples – only assigns is needed from here
  samples = Float32List(0);

  if (assigns.isEmpty) return const [];

  // 1. Merge consecutive windows with same speaker
  final mergedWin = <({int a, int b, int cid})>[];
  var curW = assigns.first;
  for (int k = 1; k < assigns.length; k++) {
    final n = assigns[k];
    if (n.cid == curW.cid && (n.a - curW.b) <= hop + (0.1 * fs)) {
      curW = (a: curW.a, b: math.max(curW.b, n.b), cid: curW.cid);
    } else {
      mergedWin.add(curW);
      curW = n;
    }
  }
  mergedWin.add(curW);

  // 2. Compute talk time for merging
  final talk = <int, int>{};
  for (final s in mergedWin) {
    talk[s.cid] = (talk[s.cid] ?? 0) + (s.b - s.a);
  }

  // 3. Post-merge clusters (Union-Find)
  final rep = <int, int>{};
  int find(int x) => rep[x] == null ? x : (rep[x] = find(rep[x]!));
  void unite(int a, int b) {
    final ra = find(a);
    final rb = find(b);
    if (ra != rb) rep[rb] = ra;
  }

  final clusterIds = talk.keys.toList();
  final centroidMap = {for (var c in clusters) c.id: c.centroid};

  for (int x = 0; x < clusterIds.length; x++) {
    for (int y = x + 1; y < clusterIds.length; y++) {
      final aId = clusterIds[x];
      final bId = clusterIds[y];
      final sim = _cosine(centroidMap[aId]!, centroidMap[bId]!);

      if (sim >= mergeClustersThreshold) {
        unite(aId, bId);
      }
    }
  }

  // 4. Relabel and convert to Turns
  final relabeled = <_Turn>[];
  for (final s in mergedWin) {
    final root = find(s.cid);
    relabeled.add(_Turn('S$root', s.a / fs, s.b / fs));
  }

  // 5. Finalize Labels (S1, S2...) based on total duration
  final talkDuration = <String, double>{};
  for (final t in relabeled) {
    talkDuration[t.spk] = (talkDuration[t.spk] ?? 0) + (t.b - t.a);
  }
  final sortedSpeakers = talkDuration.keys.toList()
    ..sort((a, b) => talkDuration[b]!.compareTo(talkDuration[a]!));

  final finalLabelMap = {
    for (int i = 0; i < sortedSpeakers.length; i++)
      sortedSpeakers[i]: 'S${i + 1}',
  };

  final out = relabeled
      .where((t) => (t.b - t.a) >= minSegmentSec)
      .map((t) => _Turn(finalLabelMap[t.spk]!, t.a, t.b))
      .toList();

  // 6. ✅ FIX OVERLAPS
  if (out.isEmpty) return const [];
  out.sort((a, b) => a.a.compareTo(b.a));

  final finalTurns = <_Turn>[];
  for (int j = 0; j < out.length; j++) {
    var turn = out[j];

    if (j > 0) {
      final prev = finalTurns.last;
      if (turn.a < prev.b) {
        turn = _Turn(turn.spk, prev.b, math.max(prev.b + 0.5, turn.b));
      }
    }

    if (turn.b > turn.a) finalTurns.add(turn);
  }

  return _mergeGapAwareTurns(finalTurns, maxGap: 0.4);
}

// Local services for this isolate
final _moonshineAsr = MoonshineService();
final _secondaryAsr = SherpaSecondaryAsrService();
final _qwenService = QwenModelService();
const _alignmentService = TranscriptAlignmentService();
// ✅ SharedPreferences keys (must match SettingsPage)
const String _kPrefTranslateToEnglish = 'pref_translate_to_english';
const String _kPrefDiarizationEnabled = 'pref_diarization_enabled';

String _cleanModelOutput(String s) {
  var out = s.trim();
  out = out.replaceAll('<|im_end|>', '');
  out = out.replaceAll('<|im_start|>assistant', '');
  out = out.replaceAll('<|im_start|>', '');
  if (out.toLowerCase().startsWith('answer:')) {
    out = out.substring('answer:'.length).trim();
  }
  return out.trim();
}

String _fmtPromptSec(double sec) => sec.toStringAsFixed(2);

String _rollingContext(List<TranscriptBlockSnapshot> blocks, {int take = 3}) {
  final recent = blocks
      .where((b) => b.displayText.trim().isNotEmpty)
      .toList();
  if (recent.isEmpty) return '';
  final start = math.max(0, recent.length - take);
  return recent
      .sublist(start)
      .map((b) => '${b.speakerLabel}: ${b.displayText}')
      .join('\n');
}

Future<String> _runQwenFinalizer({
  required String language,
  required TranscriptBlockSnapshot block,
  required String moonshineText,
  required String sherpaText,
  required String alignedCandidate,
  required String speakerDetailsJson,
  required String rollingContext,
  required String modelPath,
  required List<String> knownNames,
  required List<String> knownTerms,
}) async {
  String latest = '';
  await for (final event in LLMService.finalizeTranscriptBlock(
    language: language,
    blockId: block.blockId.toString(),
    timeStart: _fmtPromptSec(block.startSec),
    timeEnd: _fmtPromptSec(block.endSec),
    speakerHint: block.speakerLabel,
    knownNames: knownNames,
    knownTerms: knownTerms,
    moonshineText: moonshineText,
    sherpaText: sherpaText,
    alignedCandidate: alignedCandidate,
    speakerDetailsJson: speakerDetailsJson,
    rollingContext: rollingContext,
    modelPath: modelPath,
    maxTokens: 160,
    contextSize: 4096,
    numGpuLayers: 0,
  )) {
    final full = (event['full_text'] ?? '').toString();
    if (full.trim().isNotEmpty) {
      latest = full;
    }
  }
  return _cleanModelOutput(latest);
}

// ---------------- Core compute-only pipeline ----------------

Future<TranscriptionResult> transcribeToResult({
  required String wavPath,
  String? titleHint,
  bool useIsolatedDiarization = true,
  bool matchWithEnrolledSpeakers = true,
  String lang = 'auto',
  int? targetSpeakers,
  // ✅ Future callback so background can await saveData()
  Future<void> Function({
    required String stage,
    required double processedSec,
    required double totalSec,
  })?
  onProgress,
  Future<void> Function(TranscriptBlockSnapshot block)? onBlockUpdated,
  Future<void> Function(String stage)? onStageCompleted,
}) async {
  Future<void> emit(String stage, double processedSec, double totalSec) async {
    try {
      if (onProgress != null) {
        await onProgress(
          stage: stage,
          processedSec: processedSec,
          totalSec: totalSec,
        );
      }
    } catch (_) {
      // never let progress reporting break transcription
    }
  }

  bool translate = false;
  bool diarEnabled = true;

  try {
    final prefs = await SharedPreferences.getInstance();
    translate = prefs.getBool(_kPrefTranslateToEnglish) ?? false;
    diarEnabled = prefs.getBool(_kPrefDiarizationEnabled) ?? true;
  } catch (_) {
    translate = false;
    diarEnabled = true;
  }

  // 0) Preprocess
  await emit('Preparing', 0.0, 0.0);

  final cleaned = await preprocessWav16kMono(wavPath);
  final duration = await readWavDuration(cleaned);

  await emit('Preparing', 0.0, duration);

  final normalizedLang = (lang.trim().isEmpty ? 'auto' : lang.trim());
  final resultLang = translate ? 'en' : normalizedLang;

  await emit('Diarizing', 0.0, duration);
  _pipelineLog('Diarization', 'Started for ${duration.toStringAsFixed(2)}s audio');
  final diarizationResult = await _runDiarizationPipeline(
    wavPath: cleaned,
    duration: duration,
    useIsolatedDiarization: useIsolatedDiarization,
    matchWithEnrolledSpeakers: matchWithEnrolledSpeakers,
    diarEnabled: diarEnabled,
    targetSpeakers: targetSpeakers,
  );
  final speakerMatches = diarizationResult.speakerMatches;
  final diarizationTurns = _splitLongTurns(diarizationResult.turns);
  final turns = diarizationTurns;

  final blocks = <TranscriptBlockSnapshot>[];
  final wavInfo = await parseWavInfo(cleaned);
  final preparedSegments = <_PreparedSegment>[];
  final speakerDetails = <SpeakerTurnDetail>[];
  final knownNames = speakerMatches.values
      .where((value) => value.trim().isNotEmpty)
      .toSet()
      .toList()
    ..sort();
  const knownTerms = <String>[];

  _pipelineLog('Moonshine', 'Starting Moonshine ASR stage for ${turns.length} segments');
  await emit('Moonshine', 0.0, duration);

  double processedSec = 0.0;

  for (int i = 0; i < turns.length; i++) {
    final turn = turns[i];
    if ((turn.endSec - turn.startSec) < 0.1) continue;

    final slice =
        '${Directory.systemTemp.path}/transcript_segment_${DateTime.now().millisecondsSinceEpoch}_$i.wav';
    try {
      await trimWav16kMonoPcm(
        inputPath: cleaned,
        startSec: turn.startSec,
        endSec: turn.endSec,
        outputPath: slice,
        preParsedInfo: wavInfo,
      );

      final speakerLabel = matchWithEnrolledSpeakers
          ? (speakerMatches[turn.speaker] ?? turn.speaker)
          : turn.speaker;

      final speakerDetail = SpeakerTurnDetail(
        speakerId: turn.speaker,
        speakerLabel: speakerLabel,
        startSec: turn.startSec,
        endSec: turn.endSec,
        confidence: 0.78,
        matchSource: speakerMatches.containsKey(turn.speaker)
            ? 'speaker_memory'
            : 'heuristic',
        matchedName: speakerMatches[turn.speaker],
        note: 'Dual ASR transcription.',
      );
      speakerDetails.add(speakerDetail);

      final segment = _PreparedSegment(
        blockId: i,
        turn: turn,
        slicePath: slice,
        speakerLabel: speakerLabel,
        speakerDetail: speakerDetail,
      );
      preparedSegments.add(segment);

      final moonshineText = await _moonshineAsr.transcribeWav(
        wavPath: slice,
        lang: resultLang,
        translateToEnglish: translate,
        noTimestamps: false,
      );
      final moonshineDraft = moonshineText.trim();
      if (moonshineDraft.isEmpty) {
        continue;
      }

      final block = TranscriptBlockSnapshot(
        meetingId: '0',
        blockId: segment.blockId,
        language: resultLang,
        startSec: turn.startSec,
        endSec: turn.endSec,
        speakerId: turn.speaker,
        speakerLabel: speakerLabel,
        rawText: moonshineDraft,
        alignedText: null,
        finalText: null,
        status: 'moonshine',
        confidence: 0.74,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        speakerDetails: [speakerDetail],
        metadata: {
          'moonshineText': moonshineDraft,
          'transcriptionSource': 'moonshine_primary',
          'transcriptionStage': 'moonshine_draft',
        },
      );
      blocks.add(block);

      if (onBlockUpdated != null) {
        await onBlockUpdated(block);
      }
    } catch (e, st) {
      _pipelineError('Moonshine', e, st);
    } finally {
      processedSec = math.max(processedSec, turn.endSec);
      await emit('Moonshine', processedSec, duration);

      if ((i + 1) % 10 == 0) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
    }
  }

  try {
    if (onStageCompleted != null) {
      await onStageCompleted('moonshine_complete');
    }
  } catch (_) {}

  _pipelineLog('Whisper', 'Starting secondary ASR stage for ${preparedSegments.length} segments');
  await emit('Whisper', 0.0, duration);
  processedSec = 0.0;

  for (final segment in preparedSegments) {
    try {
      final whisperText = await _secondaryAsr.transcribeWav(
        wavPath: segment.slicePath,
        lang: resultLang,
        translateToEnglish: translate,
        noTimestamps: false,
      );
      final sherpaText = whisperText.trim();
      if (sherpaText.isEmpty) {
        continue;
      }

      final blockIndex = blocks.indexWhere((b) => b.blockId == segment.blockId);
      final existing = blockIndex >= 0 ? blocks[blockIndex] : null;
      final moonshineText = (existing?.metadata['moonshineText'] ?? existing?.rawText ?? '')
          .toString()
          .trim();

      final alignment = _alignmentService.alignBlock(
        language: resultLang,
        blockId: segment.blockId,
        moonshineText: moonshineText,
        sherpaText: sherpaText,
        speakerHint: segment.speakerLabel,
        knownNames: knownNames,
        knownTerms: knownTerms,
      );

      final nextBlock = (existing ??
              TranscriptBlockSnapshot(
                meetingId: '0',
                blockId: segment.blockId,
                language: resultLang,
                startSec: segment.turn.startSec,
                endSec: segment.turn.endSec,
                speakerId: segment.turn.speaker,
                speakerLabel: segment.speakerLabel,
                rawText: moonshineText.isNotEmpty ? moonshineText : sherpaText,
                alignedText: null,
                finalText: null,
                status: 'moonshine',
                confidence: 0.72,
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
                speakerDetails: [segment.speakerDetail],
                metadata: const {},
              ))
          .copyWith(
            rawText: moonshineText.isNotEmpty ? moonshineText : sherpaText,
            alignedText: alignment.alignedText.trim().isEmpty
                ? sherpaText
                : alignment.alignedText.trim(),
            finalText: null,
            status: 'aligned',
            confidence: alignment.confidence,
            updatedAt: DateTime.now(),
            metadata: {
              ...?existing?.metadata,
              'moonshineText': moonshineText,
              'whisperText': sherpaText,
              'alignedCandidate': alignment.alignedText,
              'alignmentConfidence': alignment.confidence,
              'disagreementSpans': alignment.disagreementSpans,
              'uncertainWords': alignment.uncertainWords,
              'transcriptionSource': 'dual_asr',
              'transcriptionStage': 'whisper_aligned',
            },
          );

      if (blockIndex >= 0) {
        blocks[blockIndex] = nextBlock;
      } else {
        blocks.add(nextBlock);
        blocks.sort((a, b) => a.blockId.compareTo(b.blockId));
      }

      if (onBlockUpdated != null) {
        await onBlockUpdated(nextBlock);
      }
    } catch (e, st) {
      _pipelineError('Whisper', e, st);
    } finally {
      processedSec = math.max(processedSec, segment.turn.endSec);
      await emit('Whisper', processedSec, duration);
    }
  }

  _secondaryAsr.dispose();

  try {
    if (onStageCompleted != null) {
      await onStageCompleted('whisper_complete');
    }
  } catch (_) {}

  final hasQwenModel = await _qwenService.isModelDownloaded();
  if (hasQwenModel && blocks.isNotEmpty) {
    final qwenPath = await _qwenService.modelFilePath();
    _pipelineLog('Qwen', 'Starting transcript finalizer for ${blocks.length} blocks');
    await emit('Qwen', 0.0, duration);
    processedSec = 0.0;

    for (int i = 0; i < blocks.length; i++) {
      final existing = blocks[i];
      try {
        final moonshineText = (existing.metadata['moonshineText'] ?? existing.rawText)
            .toString();
        final sherpaText = (existing.metadata['whisperText'] ?? existing.alignedText ?? '')
            .toString();
        final alignedCandidate = (existing.metadata['alignedCandidate'] ??
                existing.alignedText ??
                existing.displayText)
            .toString();
        final speakerDetailsJson = jsonEncode(
          existing.speakerDetails.map((e) => e.toJson()).toList(),
        );
        final qwenText = await _runQwenFinalizer(
          language: resultLang,
          block: existing,
          moonshineText: moonshineText,
          sherpaText: sherpaText,
          alignedCandidate: alignedCandidate,
          speakerDetailsJson: speakerDetailsJson,
          rollingContext: _rollingContext(blocks.sublist(0, i)),
          modelPath: qwenPath,
          knownNames: knownNames,
          knownTerms: knownTerms,
        );
        if (qwenText.trim().isEmpty) {
          continue;
        }

        final nextBlock = existing.copyWith(
          finalText: qwenText.trim(),
          status: 'finalized',
          confidence: math.max(existing.confidence, 0.88),
          updatedAt: DateTime.now(),
          metadata: {
            ...existing.metadata,
            'qwenText': qwenText.trim(),
            'transcriptionStage': 'qwen_finalized',
            'transcriptionSource': 'qwen_finalizer',
          },
        );
        blocks[i] = nextBlock;

        if (onBlockUpdated != null) {
          await onBlockUpdated(nextBlock);
        }
      } catch (e, st) {
        _pipelineError('Qwen', e, st);
      } finally {
        processedSec = math.max(processedSec, existing.endSec);
        await emit('Qwen', processedSec, duration);
      }
    }

    try {
      if (onStageCompleted != null) {
        await onStageCompleted('qwen_complete');
      }
    } catch (_) {}
  }

  final mergedTurns = blocks
      .where((block) => block.displayText.isNotEmpty)
      .map(
        (block) => LiteTurn(
          block.speakerLabel,
          block.startSec,
          block.endSec,
          block.displayText,
        ),
      )
      .toList();

  final firstText = mergedTurns.isNotEmpty ? mergedTurns.first.text.trim() : '';
  final title = (titleHint != null && titleHint.trim().isNotEmpty)
      ? titleHint.trim()
      : (firstText.isEmpty
            ? null
            : (firstText.length > 48
                  ? '${firstText.substring(0, 48)}…'
                  : firstText));

  await emit('Finalizing', duration, duration);
  _pipelineLog(
    'Done',
    'Completed transcription with ${mergedTurns.length} turns and ${blocks.length} blocks',
  );

  for (final segment in preparedSegments) {
    try {
      File(segment.slicePath).deleteSync();
    } catch (_) {}
  }

  try {
    if (cleaned != wavPath) {
      File(cleaned).deleteSync();
    }
  } catch (_) {}

  return TranscriptionResult(
    model: 'moonshine_whisper_qwen',
    lang: resultLang,
    durationSec: duration,
    title: title,
    turns: mergedTurns,
    speakerDetails: speakerDetails,
    blocks: blocks,
  );
}
