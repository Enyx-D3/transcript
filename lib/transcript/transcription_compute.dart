// lib/transcript/transcription_compute.dart
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transcript/speaker_memory.dart';

import '../audio_preprocess.dart';
import '../audio_utils.dart';
import '../model_bootstrap.dart';
import '../speaker_embedding.dart';
import '../whisper_service.dart';
import 'transcription_models.dart';
import 'isolated_embedding_diarization.dart'
    show runEmbeddingDiarizationInIsolate, EnhancedDiarizationResult, IsolatedEmbeddingTurn;

// ---------------- Internal merged turn structure ----------------

class _Turn {
  final String spk; // final speaker label S1/S2/...
  final double a; // startSec
  final double b; // endSec
  _Turn(this.spk, this.a, this.b);
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
Future<List<_Turn>> diarizeByEmbeddings({
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
  final wave = readWaveSimple(wavPath);
  final samples = wave.samples;
  final fs = wave.sampleRate;

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
          debugPrint(
            '[Diarize] Low sim ($best), but sticking to closest speaker $candidateCid',
          );
        } else {
          candidateCid = nextId++;
          clusters.add(_Cluster(candidateCid, v));
          debugPrint(
            '[Diarize] Creating NEW speaker $candidateCid (sim: $best)',
          );
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

    assigns.add((a: a, b: b, cid: currentCid!));
    i += hop;
  }

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
        debugPrint('[Diarize] Merging clusters $aId and $bId (sim: $sim)');
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
    for (int i = 0; i < sortedSpeakers.length; i++) sortedSpeakers[i]: 'S${i + 1}',
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

// Local service for this isolate
final _whisper = WhisperService();

// ✅ SharedPreferences keys (must match SettingsPage)
const String _kPrefTranslateToEnglish = 'pref_translate_to_english';
const String _kPrefDiarizationEnabled = 'pref_diarization_enabled';

// ---------------- Core compute-only pipeline ----------------

Future<TranscriptionResult> transcribeToResult({
  required String wavPath,
  String? titleHint,
  bool useIsolatedDiarization = true,
  bool matchWithEnrolledSpeakers = true,
  String lang = 'auto',
  int? targetSpeakers,
}) async {
  // ✅ read from settings (default false/true on fail/missing)
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
  final cleaned = await preprocessWav16kMono(wavPath);
  final duration = await readWavDuration(cleaned);

  final modelName = _whisper.currentModel?.name ?? 'whisper';

  // ✅ simple rule:
  // - translate ON => lang en
  // - translate OFF => lang from parameter (or auto)
  final normalizedLang = (lang.trim().isEmpty ? 'auto' : lang.trim());
  final resultLang = translate ? 'en' : normalizedLang;

  // ✅ if diarization is OFF, skip diarization step entirely
  if (!diarEnabled) {
    debugPrint('[BG-PIPELINE] Diarization disabled in settings. Single-pass transcription.');

    final text = await _whisper.transcribeWav(
      wavPath: cleaned,
      translateToEnglish: translate,
      diarize: false,
      noTimestamps: false,
      splitOnWord: true,
      lang: resultLang,
    );

    final baseTitle = text.trim();
    final title = (titleHint != null && titleHint.trim().isNotEmpty)
        ? titleHint.trim()
        : (baseTitle.isEmpty
            ? null
            : (baseTitle.length > 48 ? '${baseTitle.substring(0, 48)}…' : baseTitle));

    return TranscriptionResult(
      model: modelName,
      lang: resultLang,
      durationSec: duration,
      title: title,
      turns: [LiteTurn('S1', 0.0, duration, text.trim())],
    );
  }

  // 1) Prepare diarization models
  final mp = await ensureDiarizationModels();

  List<IsolatedEmbeddingTurn> diarizationTurns = [];
  Map<String, String> speakerMatches = {};

  if (useIsolatedDiarization) {
    debugPrint('[BG-PIPELINE] Starting enhanced diarization with speaker matching...');

    try {
      Map<String, List<List<double>>> speakerMemoryData = {};
      if (matchWithEnrolledSpeakers) {
        try {
          final memory = await SpeakerMemory.instance();
          final allSpeakers = memory.dumpAll();

          allSpeakers.forEach((name, embeddings) {
            final serializedEmbeddings = embeddings.map((emb) => emb.toList()).toList();
            speakerMemoryData[name] = serializedEmbeddings;
          });

          debugPrint('[BG-PIPELINE] Loaded speaker memory: ${speakerMemoryData.length} speakers');
        } catch (e) {
          debugPrint('[BG-PIPELINE] Failed to load speaker memory: $e');
        }
      }

      final EnhancedDiarizationResult enhancedResult =
          await runEmbeddingDiarizationInIsolate(
        wavPath: cleaned,
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
      speakerMatches = enhancedResult.speakerMatches;

      debugPrint(
        '[BG-PIPELINE] Enhanced diarization done. segs=${diarizationTurns.length}, matches=${speakerMatches.length}',
      );
    } catch (e, stackTrace) {
      debugPrint('[BG-PIPELINE] Enhanced diarization failed: $e');
      debugPrint('[BG-PIPELINE] Stack trace: $stackTrace');

      final emb = await SpeakerEmbedder.instance(mp.embOnnx);
      final merged = await diarizeByEmbeddings(
        wavPath: cleaned,
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
          .map((t) => IsolatedEmbeddingTurn(speaker: t.spk, startSec: t.a, endSec: t.b))
          .toList();
    }
  } else {
    final emb = await SpeakerEmbedder.instance(mp.embOnnx);
    debugPrint('[BG-PIPELINE] In-thread diarization start...');
    final merged = await diarizeByEmbeddings(
      wavPath: cleaned,
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
        .map((t) => IsolatedEmbeddingTurn(speaker: t.spk, startSec: t.a, endSec: t.b))
        .toList();
  }

  final turns = diarizationTurns.map((t) {
    final speakerName =
        matchWithEnrolledSpeakers ? (speakerMatches[t.speaker] ?? t.speaker) : t.speaker;

    return LiteTurn(speakerName, t.startSec, t.endSec, '');
  }).toList();

  // Fallback: diarization returned nothing
  if (turns.isEmpty) {
    debugPrint('[BG-PIPELINE] No diarization segments found, using single speaker');

    final text = await _whisper.transcribeWav(
      wavPath: cleaned,
      translateToEnglish: translate,
      diarize: false,
      noTimestamps: false,
      splitOnWord: true,
      lang: resultLang,
    );

    final baseTitle = text.trim();
    final title = (titleHint != null && titleHint.trim().isNotEmpty)
        ? titleHint.trim()
        : (baseTitle.isEmpty
            ? null
            : (baseTitle.length > 48 ? '${baseTitle.substring(0, 48)}…' : baseTitle));

    return TranscriptionResult(
      model: modelName,
      lang: resultLang,
      durationSec: duration,
      title: title,
      turns: [LiteTurn('S1', 0.0, duration, text.trim())],
    );
  }

  debugPrint('[BG-PIPELINE] Starting transcription of ${turns.length} segments');

  final tmpDir = Directory(
    '${Directory.systemTemp.path}/transcript_tmp_${DateTime.now().millisecondsSinceEpoch}',
  )..createSync(recursive: true);

  final out = <LiteTurn>[];

  for (int i = 0; i < turns.length; i++) {
    final turn = turns[i];

    if ((turn.endSec - turn.startSec) < 0.1) {
      debugPrint('[BG-PIPELINE] Skipping very short segment: ${turn.endSec - turn.startSec}s');
      continue;
    }

    final slice = '${tmpDir.path}/slice_$i.wav';

    debugPrint(
      '[BG-PIPELINE] Processing segment $i: ${turn.speaker} (${turn.startSec}s - ${turn.endSec}s)',
    );

    try {
      await trimWav16kMonoPcm(
        inputPath: cleaned,
        startSec: turn.startSec,
        endSec: turn.endSec,
        outputPath: slice,
      );

      final text = await _whisper.transcribeWav(
        wavPath: slice,
        translateToEnglish: translate,
        diarize: false,
        noTimestamps: false,
        splitOnWord: true,
        lang: resultLang,
      );

      final trimmedText = text.trim();
      if (trimmedText.isNotEmpty) {
        out.add(LiteTurn(turn.speaker, turn.startSec, turn.endSec, trimmedText));
      }

      try {
        File(slice).deleteSync();
      } catch (_) {}
    } catch (e, stackTrace) {
      debugPrint('[BG-PIPELINE] Error transcribing segment $i: $e');
      debugPrint('[BG-PIPELINE] Stack trace: $stackTrace');
    }
  }

  try {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  } catch (_) {}

  final nonEmpty = out.where((t) => t.text.trim().isNotEmpty).toList();
  if (nonEmpty.isEmpty) {
    final title = (titleHint != null && titleHint.trim().isNotEmpty) ? titleHint.trim() : null;

    return TranscriptionResult(
      model: modelName,
      lang: resultLang,
      durationSec: duration,
      title: title,
      turns: const [],
    );
  }

  // Re-merge consecutive turns with same speaker
  final mergedTurns = <LiteTurn>[];
  LiteTurn? cur;
  for (final t in nonEmpty) {
    if (cur == null) {
      cur = t;
      continue;
    }
    final gap = t.startSec - cur.endSec;
    final same = t.speaker == cur.speaker;

    if (same && gap >= -0.05 && gap <= 0.5) {
      cur = LiteTurn(cur.speaker, cur.startSec, t.endSec, '${cur.text} ${t.text}'.trim());
    } else {
      mergedTurns.add(cur);
      cur = t;
    }
  }
  if (cur != null) mergedTurns.add(cur);

  final firstText = mergedTurns.isNotEmpty ? mergedTurns.first.text.trim() : '';
  final title = (titleHint != null && titleHint.trim().isNotEmpty)
      ? titleHint.trim()
      : (firstText.isEmpty
          ? null
          : (firstText.length > 48 ? '${firstText.substring(0, 48)}…' : firstText));

  return TranscriptionResult(
    model: modelName,
    lang: resultLang,
    durationSec: duration,
    title: title,
    turns: mergedTurns,
  );
}
