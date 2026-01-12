// lib/transcript/isolated_embedding_diarization.dart
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

import '../audio_utils.dart';
import 'isolated_speaker_matcher.dart';

/// Serializable turn structure for isolate communication
class IsolatedEmbeddingTurn {
  final String speaker;
  final double startSec;
  final double endSec;

  IsolatedEmbeddingTurn({
    required this.speaker,
    required this.startSec,
    required this.endSec,
  });

  Map<String, dynamic> toJson() => {
        'speaker': speaker,
        'startSec': startSec,
        'endSec': endSec,
      };

  factory IsolatedEmbeddingTurn.fromJson(Map<String, dynamic> json) {
    return IsolatedEmbeddingTurn(
      speaker: json['speaker'] as String,
      startSec: (json['startSec'] as num).toDouble(),
      endSec: (json['endSec'] as num).toDouble(),
    );
  }
}

/// Enhanced diarization result with speaker matches
class EnhancedDiarizationResult {
  final List<IsolatedEmbeddingTurn> turns;

  /// Map from final label (e.g. S1) -> enrolled speaker name/id (e.g. "Alice")
  final Map<String, String> speakerMatches;

  EnhancedDiarizationResult({
    required this.turns,
    required this.speakerMatches,
  });

  Map<String, dynamic> toJson() => {
        'turns': turns.map((t) => t.toJson()).toList(),
        'speakerMatches': speakerMatches,
      };

  factory EnhancedDiarizationResult.fromJson(Map<String, dynamic> json) {
    return EnhancedDiarizationResult(
      turns: (json['turns'] as List)
          .map((t) => IsolatedEmbeddingTurn.fromJson(t))
          .toList(),
      speakerMatches:
          (json['speakerMatches'] as Map<String, dynamic>).cast<String, String>(),
    );
  }
}

/// Serializable parameters
class DiarizationParams {
  final String wavPath;
  final double durationSec;
  final String embOnnxPath;

  final double windowSec;
  final double hopSec;

  final double stayThreshold;
  final double switchThreshold;
  final int switchConfirmWindows;

  /// Old centroid merge threshold (kept)
  final double mergeClustersThreshold;

  /// ✅ NEW: stable centroid merge threshold (speaker-level, more important)
  final double stableMergeThreshold;

  final double minClusterTalkSec;
  final double minSegmentSec;

  /// Safety cap only
  final int maxSpeakersCap;

  /// ✅ prevent fake speakers
  final double newSpeakerFloor;
  final int newSpeakerConfirmWindows;

  /// ✅ stay hysteresis
  final double stayHysteresis;

  /// ✅ OPTIONAL hard limit (0 disables)
  final int hardMaxSpeakers;

  final bool matchSpeakers;
  final double matchThreshold;

  /// enrolled speaker embeddings: name -> list of embeddings (each embedding is List<double>)
  final Map<String, List<List<double>>> speakerMemoryData;

  DiarizationParams({
    required this.wavPath,
    required this.durationSec,
    required this.embOnnxPath,
    this.windowSec = 2.5,
    this.hopSec = 1.25,
    this.stayThreshold = 0.68,
    this.switchThreshold = 0.80,
    this.switchConfirmWindows = 3,
    this.mergeClustersThreshold = 0.86,

    /// ✅ good default: will merge “same speaker split into 2 clusters”
    this.stableMergeThreshold = 0.78,

    this.minClusterTalkSec = 2.5,
    this.minSegmentSec = 0.8,
    this.maxSpeakersCap = 12,

    this.newSpeakerFloor = 0.58,
    this.newSpeakerConfirmWindows = 4,
    this.stayHysteresis = 0.06,

    /// ✅ if you KNOW there are 2 speakers, set hardMaxSpeakers=2
    this.hardMaxSpeakers = 0,

    this.matchSpeakers = true,
    this.matchThreshold = 0.67,
    this.speakerMemoryData = const {},
  });

  Map<String, dynamic> toJson() => {
        'wavPath': wavPath,
        'durationSec': durationSec,
        'embOnnxPath': embOnnxPath,
        'windowSec': windowSec,
        'hopSec': hopSec,
        'stayThreshold': stayThreshold,
        'switchThreshold': switchThreshold,
        'switchConfirmWindows': switchConfirmWindows,
        'mergeClustersThreshold': mergeClustersThreshold,
        'stableMergeThreshold': stableMergeThreshold,
        'minClusterTalkSec': minClusterTalkSec,
        'minSegmentSec': minSegmentSec,
        'maxSpeakersCap': maxSpeakersCap,
        'newSpeakerFloor': newSpeakerFloor,
        'newSpeakerConfirmWindows': newSpeakerConfirmWindows,
        'stayHysteresis': stayHysteresis,
        'hardMaxSpeakers': hardMaxSpeakers,
        'matchSpeakers': matchSpeakers,
        'matchThreshold': matchThreshold,
        'speakerMemoryData': speakerMemoryData,
      };

  factory DiarizationParams.fromJson(Map<String, dynamic> json) {
    return DiarizationParams(
      wavPath: json['wavPath'] as String,
      durationSec: (json['durationSec'] as num).toDouble(),
      embOnnxPath: json['embOnnxPath'] as String,
      windowSec: (json['windowSec'] as num).toDouble(),
      hopSec: (json['hopSec'] as num).toDouble(),
      stayThreshold: (json['stayThreshold'] as num).toDouble(),
      switchThreshold: (json['switchThreshold'] as num).toDouble(),
      switchConfirmWindows: json['switchConfirmWindows'] as int,
      mergeClustersThreshold: (json['mergeClustersThreshold'] as num).toDouble(),
      stableMergeThreshold: (json['stableMergeThreshold'] as num?)?.toDouble() ?? 0.78,
      minClusterTalkSec: (json['minClusterTalkSec'] as num).toDouble(),
      minSegmentSec: (json['minSegmentSec'] as num).toDouble(),
      maxSpeakersCap: (json['maxSpeakersCap'] as int?) ?? 12,
      newSpeakerFloor: (json['newSpeakerFloor'] as num?)?.toDouble() ?? 0.58,
      newSpeakerConfirmWindows: (json['newSpeakerConfirmWindows'] as int?) ?? 4,
      stayHysteresis: (json['stayHysteresis'] as num?)?.toDouble() ?? 0.06,
      hardMaxSpeakers: (json['hardMaxSpeakers'] as int?) ?? 0,
      matchSpeakers: (json['matchSpeakers'] as bool?) ?? true,
      matchThreshold: (json['matchThreshold'] as num?)?.toDouble() ?? 0.67,
      speakerMemoryData: json['speakerMemoryData'] != null
          ? (json['speakerMemoryData'] as Map<String, dynamic>).map(
              (k, v) => MapEntry(
                k,
                (v as List)
                    .map((e) => (e as List).map((x) => (x as num).toDouble()).toList())
                    .toList(),
              ),
            )
          : const {},
    );
  }
}

class _IsolatedCluster {
  final int id;
  Float32List centroid;
  int n;
  _IsolatedCluster(this.id, this.centroid) : n = 1;

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

class _IsolatedTurn {
  final String spk;
  final double a;
  final double b;
  _IsolatedTurn(this.spk, this.a, this.b);

  IsolatedEmbeddingTurn toSerializable() => IsolatedEmbeddingTurn(
        speaker: spk,
        startSec: a,
        endSec: b,
      );
}

Future<EnhancedDiarizationResult> _runEmbeddingDiarizationInIsolate(
  DiarizationParams params,
) async {
  final wave = readWaveSimple(params.wavPath);
  final samples = wave.samples;
  final fs = wave.sampleRate;

  initBindings();
  final cfg = SpeakerEmbeddingExtractorConfig(
    model: params.embOnnxPath,
    numThreads: 2,
    provider: 'cpu',
    debug: false,
  );
  final ext = SpeakerEmbeddingExtractor(config: cfg);

  final win = (params.windowSec * fs).round().clamp(1, 1 << 30);
  final hop = (params.hopSec * fs).round().clamp(1, 1 << 30);
  final totalSamples = samples.length;

  final clusters = <_IsolatedCluster>[];
  int nextId = 1;

  final assigns = <({int a, int b, int cid, Float32List emb})>[];

  int? currentCid;

  // switch confirmation
  int? pendingCid;
  int pendingCount = 0;

  // new-speaker confirmation
  int pendingNewCount = 0;
  Float32List? pendingNewEmb;

  try {
    int i = 0;
    int winIndex = 0;

    while (i < totalSamples) {
      final a = i;
      final b = math.min(a + win, totalSamples);
      if (b - a < (0.6 * fs)) break;

      if (_isSilentIsolate(samples, a, b)) {
        i += hop;
        winIndex++;
        continue;
      }

      final slice = samples.sublist(a, b);
      final stream = ext.createStream();
      stream.acceptWaveform(samples: slice, sampleRate: fs);
      stream.inputFinished();
      final raw = ext.compute(stream);
      stream.free();

      final v = _l2normIsolate(raw);
      if (v.isEmpty) {
        i += hop;
        winIndex++;
        continue;
      }

      // best cluster
      double best = -1;
      _IsolatedCluster? bestC;
      for (final c in clusters) {
        final sim = IsolatedSpeakerMatcher.cosine(c.centroid, v);
        if (sim > best) {
          best = sim;
          bestC = c;
        }
      }

      if (kDebugMode) {
        debugPrint(
          '[DIA] win#$winIndex ${(a / fs).toStringAsFixed(2)}–${(b / fs).toStringAsFixed(2)} '
          'best=${best.toStringAsFixed(3)} bestCid=${bestC?.id} cur=$currentCid clusters=${clusters.length} '
          '(stayTh=${params.stayThreshold} swTh=${params.switchThreshold})',
        );
      }

      int candidateCid;

      if (bestC == null) {
        candidateCid = nextId++;
        clusters.add(_IsolatedCluster(candidateCid, v));
        pendingNewCount = 0;
        pendingNewEmb = null;
      } else {
        final isStay = (currentCid != null && bestC.id == currentCid);
        final th = isStay ? params.stayThreshold : params.switchThreshold;

        if (isStay && best >= (params.stayThreshold - params.stayHysteresis)) {
          candidateCid = currentCid!;
          pendingNewCount = 0;
          pendingNewEmb = null;
        } else if (best >= th) {
          if (best >= th + 0.05) bestC.update(v);
          candidateCid = bestC.id;
          pendingNewCount = 0;
          pendingNewEmb = null;
        } else {
          // not confident match
          if (best < params.newSpeakerFloor && clusters.length < params.maxSpeakersCap) {
            pendingNewCount++;
            pendingNewEmb = v;

            if (pendingNewCount >= params.newSpeakerConfirmWindows) {
              candidateCid = nextId++;
              clusters.add(_IsolatedCluster(candidateCid, pendingNewEmb!));
              pendingNewCount = 0;
              pendingNewEmb = null;
            } else {
              candidateCid = bestC.id;
            }
          } else {
            candidateCid = bestC.id;
            pendingNewCount = 0;
            pendingNewEmb = null;
          }
        }
      }

      // switch confirmation
      if (currentCid == null) {
        currentCid = candidateCid;
        pendingCid = null;
        pendingCount = 0;
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

        if (pendingCount >= params.switchConfirmWindows) {
          currentCid = candidateCid;
          pendingCid = null;
          pendingCount = 0;
        } else {
          candidateCid = currentCid;
        }
      }

      assigns.add((a: a, b: b, cid: currentCid!, emb: v));

      i += hop;
      winIndex++;
    }
  } finally {
    ext.free();
    if (kDebugMode) debugPrint('[DIA] extractor freed');
  }

  if (assigns.isEmpty) {
    return EnhancedDiarizationResult(turns: const [], speakerMatches: const {});
  }

  // 1) merge consecutive windows with same cluster id
  final mergedWin = <({int a, int b, int cid, List<Float32List> embs})>[];
  var curW = (
    a: assigns.first.a,
    b: assigns.first.b,
    cid: assigns.first.cid,
    embs: <Float32List>[assigns.first.emb],
  );

  for (int k = 1; k < assigns.length; k++) {
    final n = assigns[k];
    if (n.cid == curW.cid && (n.a - curW.b) <= hop + (0.1 * fs)) {
      curW = (
        a: curW.a,
        b: math.max(curW.b, n.b),
        cid: curW.cid,
        embs: [...curW.embs, n.emb],
      );
    } else {
      mergedWin.add(curW);
      curW = (a: n.a, b: n.b, cid: n.cid, embs: [n.emb]);
    }
  }
  mergedWin.add(curW);

  // 2) talk time per cluster
  final talk = <int, int>{};
  for (final s in mergedWin) {
    talk[s.cid] = (talk[s.cid] ?? 0) + (s.b - s.a);
  }

  if (kDebugMode) {
    final parts =
        talk.entries.map((e) => '${e.key}:${(e.value / fs).toStringAsFixed(2)}s').join(', ');
    debugPrint('[DIA] assigns=${assigns.length}, mergedWin=${mergedWin.length}');
    debugPrint('[DIA] talkByCid: $parts');
  }

  // drop tiny noise clusters
  final minTalkSamples = (params.minClusterTalkSec * fs).round();
  talk.removeWhere((cid, samplesCount) => samplesCount < minTalkSamples);
  var allowedCids = talk.keys.toSet();

  if (allowedCids.isEmpty) {
    return EnhancedDiarizationResult(turns: const [], speakerMatches: const {});
  }

  // 3) ✅ build STABLE centroids per cluster using ALL embeddings assigned
  final stableCentroidByCid = <int, Float32List>{};
  final embsByCid = <int, List<Float32List>>{};
  for (final w in mergedWin) {
    if (!allowedCids.contains(w.cid)) continue;
    embsByCid.putIfAbsent(w.cid, () => <Float32List>[]).addAll(w.embs);
  }
  embsByCid.forEach((cid, embs) {
    stableCentroidByCid[cid] = _meanAndNorm(embs);
  });

  // 4) union-find merge similar clusters using stable centroids
  final rep = <int, int>{};
  int find(int x) => rep[x] == null ? x : (rep[x] = find(rep[x]!));
  void unite(int a, int b) {
    final ra = find(a);
    final rb = find(b);
    if (ra != rb) rep[rb] = ra;
  }

  final clusterIds = allowedCids.toList();

  for (int x = 0; x < clusterIds.length; x++) {
    for (int y = x + 1; y < clusterIds.length; y++) {
      final aId = clusterIds[x];
      final bId = clusterIds[y];
      final ca = stableCentroidByCid[aId];
      final cb = stableCentroidByCid[bId];
      if (ca == null || cb == null) continue;

      final sim = IsolatedSpeakerMatcher.cosine(ca, cb);

      if (kDebugMode) {
        debugPrint(
          '[DIA] stableMergeCheck $aId vs $bId sim=${sim.toStringAsFixed(3)} th=${params.stableMergeThreshold.toStringAsFixed(3)}',
        );
      }

      if (sim >= params.stableMergeThreshold) {
        unite(aId, bId);
        if (kDebugMode) {
          debugPrint('[DIA] ✅ stableMerge $aId -> $bId (sim=${sim.toStringAsFixed(3)})');
        }
      }
    }
  }

  // 5) relabel merged windows by root id
  final relabeled = <_IsolatedTurn>[];
  for (final w in mergedWin) {
    if (!allowedCids.contains(w.cid)) continue;
    final root = find(w.cid);
    relabeled.add(_IsolatedTurn('S$root', w.a / fs, w.b / fs));
  }

  // 6) min segment + overlap fix + gap merge
  var out = relabeled.where((t) => (t.b - t.a) >= params.minSegmentSec).toList();
  if (out.isEmpty) return EnhancedDiarizationResult(turns: const [], speakerMatches: const {});

  out.sort((a, b) => a.a.compareTo(b.a));
  final fixed = <_IsolatedTurn>[];
  for (int j = 0; j < out.length; j++) {
    var turn = out[j];
    if (j > 0) {
      final prev = fixed.last;
      if (turn.a < prev.b) {
        turn = _IsolatedTurn(turn.spk, prev.b, math.max(prev.b + 0.5, turn.b));
      }
    }
    if (turn.b > turn.a) fixed.add(turn);
  }

  var mergedTurns = _mergeGapAwareTurnsIsolate(fixed, maxGap: 0.4);

  // ===== Speaker matching (RESTORED) =====

  // Build diar label -> centroid from stable (post-merge) using its windows
  final diarEmbs = <String, List<Float32List>>{};
  for (final w in mergedWin) {
    if (!allowedCids.contains(w.cid)) continue;
    final root = find(w.cid);
    final lab = 'S$root';
    diarEmbs.putIfAbsent(lab, () => <Float32List>[]).addAll(w.embs);
  }

  // enrolled name -> centroid
  final enrolled = <String, Float32List>{};
  if (params.matchSpeakers && params.speakerMemoryData.isNotEmpty) {
    params.speakerMemoryData.forEach((name, list) {
      final embs = <Float32List>[];
      for (final e in list) {
        embs.add(_l2normIsolate(Float32List.fromList(e.map((x) => x.toDouble()).toList())));
      }
      final cen = _meanAndNorm(embs);
      if (cen.isNotEmpty) enrolled[name] = cen;
    });
  }

  final diarToEnrolled = <String, String>{};
  if (params.matchSpeakers && enrolled.isNotEmpty) {
    for (final entry in diarEmbs.entries) {
      final diarLab = entry.key;
      final diarCentroid = _meanAndNorm(entry.value);
      if (diarCentroid.isEmpty) continue;

      double best = -1;
      String? bestName;
      enrolled.forEach((name, emb) {
        final sim = IsolatedSpeakerMatcher.cosine(diarCentroid, emb);
        if (sim > best) {
          best = sim;
          bestName = name;
        }
      });

      if (bestName != null && best >= params.matchThreshold) {
        diarToEnrolled[diarLab] = bestName!;
      }
    }
  }

  // ===== Optional: hard max speakers (works even without memory) =====
  if (params.hardMaxSpeakers > 0) {
    final talkBy = <String, double>{};
    for (final t in mergedTurns) {
      talkBy[t.spk] = (talkBy[t.spk] ?? 0) + (t.b - t.a);
    }

    final kept = talkBy.keys.toList()
      ..sort((a, b) => talkBy[b]!.compareTo(talkBy[a]!));
    final keepSet = kept.take(params.hardMaxSpeakers).toSet();

    mergedTurns = mergedTurns.where((t) => keepSet.contains(t.spk)).toList();

    // After dropping extra speakers, merge again
    mergedTurns = _mergeGapAwareTurnsIsolate(mergedTurns, maxGap: 0.4);
  }

  // ===== Final labeling by talk duration =====
  final talkDuration = <String, double>{};
  for (final t in mergedTurns) {
    talkDuration[t.spk] = (talkDuration[t.spk] ?? 0) + (t.b - t.a);
  }

  final sortedSpeakers = talkDuration.keys.toList()
    ..sort((a, b) => talkDuration[b]!.compareTo(talkDuration[a]!));

  final finalLabelMap = <String, String>{
    for (int i = 0; i < sortedSpeakers.length; i++) sortedSpeakers[i]: 'S${i + 1}',
  };

  final finalTurns = mergedTurns
      .where((t) => (t.b - t.a) >= params.minSegmentSec)
      .map((t) => _IsolatedTurn(finalLabelMap[t.spk]!, t.a, t.b))
      .toList();

  final finalMatches = <String, String>{};
  diarToEnrolled.forEach((diarLab, name) {
    final fl = finalLabelMap[diarLab];
    if (fl != null) finalMatches[fl] = name;
  });

  if (kDebugMode) {
    final speakersCount = finalTurns.map((t) => t.spk).toSet().length;
    debugPrint('[DIA] finalLabelMap: $finalLabelMap');
    debugPrint('[DIA] DONE mergedTurns=${finalTurns.length} speakers=$speakersCount matches=$finalMatches');
  }

  return EnhancedDiarizationResult(
    turns: finalTurns.map((t) => t.toSerializable()).toList(),
    speakerMatches: finalMatches,
  );
}

bool _isSilentIsolate(
  Float32List samples,
  int a,
  int b, {
  double rmsThresh = 0.008,
}) {
  if (b <= a) return true;
  double s = 0;
  final len = b - a;
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

List<_IsolatedTurn> _mergeGapAwareTurnsIsolate(
  List<_IsolatedTurn> segs, {
  double maxGap = 0.4,
}) {
  if (segs.isEmpty) return [];
  final s = [...segs]..sort((a, b) => a.a.compareTo(b.a));
  final out = <_IsolatedTurn>[];

  var cur = s.first;
  for (int i = 1; i < s.length; i++) {
    final n = s[i];
    if (n.spk == cur.spk && (n.a - cur.b) <= maxGap) {
      cur = _IsolatedTurn(cur.spk, cur.a, math.max(cur.b, n.b));
    } else {
      out.add(cur);
      cur = n;
    }
  }
  out.add(cur);
  return out;
}

Float32List _l2normIsolate(Float32List v) {
  double s = 0.0;
  for (final x in v) s += x * x;
  final r = math.sqrt(math.max(s, 1e-12));
  final out = Float32List(v.length);
  for (int i = 0; i < v.length; i++) out[i] = v[i] / r;
  return out;
}

Float32List _meanAndNorm(List<Float32List> embs) {
  if (embs.isEmpty) return Float32List(0);
  final dim = embs.first.length;
  if (dim == 0) return Float32List(0);

  final acc = Float32List(dim);
  int n = 0;
  for (final e in embs) {
    final m = math.min(dim, e.length);
    for (int i = 0; i < m; i++) {
      acc[i] += e[i];
    }
    n++;
  }
  if (n <= 0) return Float32List(0);

  for (int i = 0; i < dim; i++) acc[i] /= n;
  return _l2normIsolate(acc);
}

/// Public API
Future<EnhancedDiarizationResult> runEmbeddingDiarizationInIsolate({
  required String wavPath,
  required double durationSec,
  required String embOnnxPath,
  double windowSec = 2.5,
  double hopSec = 1.25,
  double stayThreshold = 0.68,
  double switchThreshold = 0.80,
  int switchConfirmWindows = 3,

  /// kept
  double mergeClustersThreshold = 0.86,

  /// ✅ new stable merge
  double stableMergeThreshold = 0.78,

  double minClusterTalkSec = 2.5,
  double minSegmentSec = 0.8,
  int maxSpeakersCap = 12,
  double newSpeakerFloor = 0.58,
  int newSpeakerConfirmWindows = 4,
  double stayHysteresis = 0.06,

  /// ✅ if you know it’s 2 speakers set hardMaxSpeakers=2
  int hardMaxSpeakers = 0,

  bool matchSpeakers = true,
  double matchThreshold = 0.67,
  Map<String, List<List<double>>> speakerMemoryData = const {},
}) async {
  final params = DiarizationParams(
    wavPath: wavPath,
    durationSec: durationSec,
    embOnnxPath: embOnnxPath,
    windowSec: windowSec,
    hopSec: hopSec,
    stayThreshold: stayThreshold,
    switchThreshold: switchThreshold,
    switchConfirmWindows: switchConfirmWindows,
    mergeClustersThreshold: mergeClustersThreshold,
    stableMergeThreshold: stableMergeThreshold,
    minClusterTalkSec: minClusterTalkSec,
    minSegmentSec: minSegmentSec,
    maxSpeakersCap: maxSpeakersCap,
    newSpeakerFloor: newSpeakerFloor,
    newSpeakerConfirmWindows: newSpeakerConfirmWindows,
    stayHysteresis: stayHysteresis,
    hardMaxSpeakers: hardMaxSpeakers,
    matchSpeakers: matchSpeakers,
    matchThreshold: matchThreshold,
    speakerMemoryData: speakerMemoryData,
  );

  return compute(_runEmbeddingDiarizationInIsolate, params);
}
