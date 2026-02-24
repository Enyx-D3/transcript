// lib/transcript/isolated_embedding_diarization.dart
import 'dart:math' as math;

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

  /// Require a margin between best and 2nd-best cluster before switching.
  /// Helps both meetings (avoids flip-flops) and podcasts (avoids false switches).
  final double switchMargin;

  final double mergeClustersThreshold;

  /// ✅ NEW: sandwich-collapse (stable speaker bridge)
  /// If we see A -> B -> A and B is short, and cosine(B,A) >= stableMergeThreshold,
  /// relabel B to A (prevents fake extra speakers).
  final double stableMergeThreshold;
  final double stableBridgeMaxSec;

  final double minClusterTalkSec;
  final double minSegmentSec;

  /// Safety cap only (keeps the online clustering from exploding)
  final int maxSpeakersCap;

  /// ✅ prevent fake speakers (create new only after N consecutive windows)
  final double newSpeakerFloor; // below this => "maybe new"
  final int newSpeakerConfirmWindows;

  /// ✅ stay hysteresis
  final double stayHysteresis;

  /// ✅ OPTIONAL: if provided, force FINAL number of speakers to this count (merge-until-N)
  /// This is applied at the end (safe), not during window clustering.
  final int? targetSpeakers;

  final bool matchSpeakers;
  final double matchThreshold;


  /// Require a margin between best and 2nd-best enrolled speaker match.
  /// Prevents wrong name assignment when voices are similar.
  final double matchMargin;

  // ignore: unintended_html_in_doc_comment
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
    this.switchMargin = 0.04,

    this.mergeClustersThreshold = 0.86,

    /// sensible defaults (you can tweak from caller)
    this.stableMergeThreshold = 0.78,
    this.stableBridgeMaxSec = 1.6,

    this.minClusterTalkSec = 2.5,
    this.minSegmentSec = 0.8,

    this.maxSpeakersCap = 12,

    this.newSpeakerFloor = 0.58,
    this.newSpeakerConfirmWindows = 4,
    this.stayHysteresis = 0.06,

    this.targetSpeakers,

    this.matchSpeakers = true,
    this.matchThreshold = 0.67,
    this.matchMargin = 0.04,
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
        'stableBridgeMaxSec': stableBridgeMaxSec,

        'minClusterTalkSec': minClusterTalkSec,
        'minSegmentSec': minSegmentSec,
        'maxSpeakersCap': maxSpeakersCap,
        'newSpeakerFloor': newSpeakerFloor,
        'newSpeakerConfirmWindows': newSpeakerConfirmWindows,
        'stayHysteresis': stayHysteresis,
        'targetSpeakers': targetSpeakers,
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

      stableMergeThreshold:
          (json['stableMergeThreshold'] as num?)?.toDouble() ?? 0.78,
      stableBridgeMaxSec: (json['stableBridgeMaxSec'] as num?)?.toDouble() ?? 1.6,

      minClusterTalkSec: (json['minClusterTalkSec'] as num).toDouble(),
      minSegmentSec: (json['minSegmentSec'] as num).toDouble(),
      maxSpeakersCap: (json['maxSpeakersCap'] as int?) ?? 12,
      newSpeakerFloor: (json['newSpeakerFloor'] as num?)?.toDouble() ?? 0.58,
      newSpeakerConfirmWindows: (json['newSpeakerConfirmWindows'] as int?) ?? 4,
      stayHysteresis: (json['stayHysteresis'] as num?)?.toDouble() ?? 0.06,
      targetSpeakers: (json['targetSpeakers'] as int?),
      matchSpeakers: (json['matchSpeakers'] as bool?) ?? true,
      matchThreshold: (json['matchThreshold'] as num?)?.toDouble() ?? 0.67,
      speakerMemoryData: json['speakerMemoryData'] != null
          ? (json['speakerMemoryData'] as Map<String, dynamic>).map(
              (k, v) => MapEntry(
                k,
                (v as List)
                    .map((e) => (e as List)
                        .map((x) => (x as num).toDouble())
                        .toList())
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
  var wave = readWaveSimple(params.wavPath);
  var samples = wave.samples;
  final fs = wave.sampleRate;
  // Release Wave object's reference early (samples var still holds it)
  wave = Wave(samples: Float32List(0), sampleRate: fs);

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

  // ✅ new-speaker confirmation (delay creation)
  int pendingNewCount = 0;
      final pendingNewEmbs = <Float32List>[];
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
      double secondBest = -1;
      _IsolatedCluster? bestC;
      for (final c in clusters) {
        final sim = IsolatedSpeakerMatcher.cosine(c.centroid, v);
        if (sim > best) {
          secondBest = best;
          best = sim;
          bestC = c;
        } else if (sim > secondBest) {
          secondBest = sim;
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
        // first speaker
        candidateCid = nextId++;
        clusters.add(_IsolatedCluster(candidateCid, v));
        pendingNewCount = 0;
        pendingNewEmb = null;
          pendingNewEmbs.clear();
        if (kDebugMode) {
          debugPrint(
              '[DIA]   FIRST SPEAKER created cid=$candidateCid clustersNow=${clusters.length}');
        }
      } else {
        final isStay = (currentCid != null && bestC.id == currentCid);
        final th = isStay ? params.stayThreshold : params.switchThreshold;

        // ✅ stay hysteresis
        if (isStay && best >= (params.stayThreshold - params.stayHysteresis)) {
          candidateCid = currentCid!;
          pendingNewCount = 0;
          pendingNewEmb = null;
          pendingNewEmbs.clear();
          if (kDebugMode) {
            debugPrint(
                '[DIA]   STAY-HYSTERESIS -> keep cid=$candidateCid (best=${best.toStringAsFixed(3)})');
          }
        } else if (!isStay && (best - secondBest) < params.switchMargin) {
          // Not enough margin vs second best -> avoid flip-flop.
          candidateCid = currentCid ?? bestC.id;
          pendingNewCount = 0;
          pendingNewEmb = null;
          pendingNewEmbs.clear();
          pendingNewEmbs.clear();
          if (kDebugMode) {
            debugPrint('[DIA]   NO-SWITCH (margin ${(best - secondBest).toStringAsFixed(3)} < ${params.switchMargin})');
          }
        } else if (best >= th) {
          // normal match
          if (best >= th + 0.05) bestC.update(v);
          candidateCid = bestC.id;
          pendingNewCount = 0;
          pendingNewEmb = null;
          pendingNewEmbs.clear();
          if (kDebugMode) {
            debugPrint(
              '[DIA]   MATCH -> cid=$candidateCid (best=${best.toStringAsFixed(3)} >= th=${th.toStringAsFixed(3)})',
            );
          }
        } else {
          // not confident match -> maybe new speaker (confirmed across windows)
          if (best < params.newSpeakerFloor &&
              clusters.length < params.maxSpeakersCap) {
            pendingNewCount++;
            pendingNewEmb = v;
            pendingNewEmbs.add(v);
            if (pendingNewEmbs.length > params.newSpeakerConfirmWindows) {
              pendingNewEmbs.removeAt(0);
            }

            if (kDebugMode) {
              debugPrint(
                '[DIA]   maybe NEW (best=${best.toStringAsFixed(3)} < floor=${params.newSpeakerFloor}) '
                'pendingNew=$pendingNewCount/${params.newSpeakerConfirmWindows}',
              );
            }

            if (pendingNewCount >= params.newSpeakerConfirmWindows) {
              candidateCid = nextId++;
              final seed = _meanNormalizeIsolate(pendingNewEmbs.isNotEmpty ? pendingNewEmbs : [pendingNewEmb!]);
              clusters.add(_IsolatedCluster(candidateCid, seed));
              pendingNewCount = 0;
              pendingNewEmb = null;
          pendingNewEmbs.clear();

              if (kDebugMode) {
                debugPrint(
                    '[DIA]   NEW SPEAKER CONFIRMED -> created cid=$candidateCid clustersNow=${clusters.length}');
              }
            } else {
              candidateCid = bestC.id; // until confirmed, stick to closest
              if (kDebugMode) {
                debugPrint(
                    '[DIA]   NEW NOT CONFIRMED -> keep closest cid=$candidateCid');
              }
            }
          } else {
            candidateCid = bestC.id;
            pendingNewCount = 0;
            pendingNewEmb = null;
          pendingNewEmbs.clear();
            if (kDebugMode) {
              debugPrint(
                  '[DIA]   NO-MATCH but CLOSE/CAP -> keep cid=$candidateCid (best=${best.toStringAsFixed(3)})');
            }
          }
        }
      }

      // switch confirmation logic
      if (currentCid == null) {
        currentCid = candidateCid;
        pendingCid = null;
        pendingCount = 0;
        if (kDebugMode) debugPrint('[DIA]   set currentCid=$currentCid (initial)');
      } else if (candidateCid == currentCid) {
        pendingCid = null;
        pendingCount = 0;
        if (kDebugMode) debugPrint('[DIA]   stay on cid=$currentCid (reset pending)');
      } else {
        if (pendingCid == candidateCid) {
          pendingCount++;
        } else {
          pendingCid = candidateCid;
          pendingCount = 1;
        }

        if (kDebugMode) {
          debugPrint(
              '[DIA]   switch pending to cid=$candidateCid count=$pendingCount/${params.switchConfirmWindows}');
        }

        if (pendingCount >= params.switchConfirmWindows) {
          currentCid = candidateCid;
          pendingCid = null;
          pendingCount = 0;
          if (kDebugMode) debugPrint('[DIA]   SWITCH CONFIRMED -> currentCid=$currentCid');
        } else {
          candidateCid = currentCid; // keep current until confirmed
          if (kDebugMode) debugPrint('[DIA]   SWITCH NOT CONFIRMED -> stick cid=$currentCid');
        }
      }

      assigns.add((a: a, b: b, cid: currentCid!, emb: v));
      if (kDebugMode) {
        debugPrint(
          '[DIA]   ASSIGN final cid=$currentCid t=${(a / fs).toStringAsFixed(2)}–${(b / fs).toStringAsFixed(2)}',
        );
      }

      i += hop;
      winIndex++;
    }
  } finally {
    ext.free();
    // ── Release the ~115 MB samples array – only assigns is needed now ──
    samples = Float32List(0);
    if (kDebugMode) debugPrint('[DIA] extractor freed, samples released');
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
    final parts = talk.entries
        .map((e) => '${e.key}:${(e.value / fs).toStringAsFixed(2)}s')
        .join(', ');
    debugPrint('[DIA] assigns=${assigns.length}, mergedWin=${mergedWin.length}');
    debugPrint('[DIA] talkByCid: $parts');
  }

  // drop tiny noise clusters
  final minTalkSamples = (params.minClusterTalkSec * fs).round();
  talk.removeWhere((cid, samplesCount) => samplesCount < minTalkSamples);
  final allowedCids = talk.keys.toSet();

  if (kDebugMode) {
    debugPrint(
        '[DIA] allowedCids(minTalk=${params.minClusterTalkSec}s): ${allowedCids.toList()}');
  }

  final filteredMergedWin =
      mergedWin.where((w) => allowedCids.contains(w.cid)).toList();
  if (filteredMergedWin.isEmpty) {
    return EnhancedDiarizationResult(turns: const [], speakerMatches: const {});
  }

  // 3) union-find merge similar clusters (centroid similarity)
  final rep = <int, int>{};
  int find(int x) => rep[x] == null ? x : (rep[x] = find(rep[x]!));
  void unite(int a, int b) {
    final ra = find(a);
    final rb = find(b);
    if (ra != rb) rep[rb] = ra;
  }

  final clusterIds = allowedCids.toList();
  // Recompute centroids from assigned window embeddings (more stable than online centroids).
  final centroidMap = <int, Float32List>{};
  final cidToEmbs = <int, List<Float32List>>{};
  for (final w in filteredMergedWin) {
    cidToEmbs.putIfAbsent(w.cid, () => <Float32List>[]).addAll(w.embs);
  }
  for (final e in cidToEmbs.entries) {
    centroidMap[e.key] = _meanNormalizeIsolate(e.value);
  }


  for (int x = 0; x < clusterIds.length; x++) {
    for (int y = x + 1; y < clusterIds.length; y++) {
      final aId = clusterIds[x];
      final bId = clusterIds[y];
      final ca = centroidMap[aId];
      final cb = centroidMap[bId];
      if (ca == null || cb == null) continue;

      final sim = IsolatedSpeakerMatcher.cosine(ca, cb);
      if (kDebugMode) {
        debugPrint(
          '[DIA] mergeCheck $aId vs $bId sim=${sim.toStringAsFixed(3)} th=${params.mergeClustersThreshold.toStringAsFixed(3)}',
        );
      }
      if (sim >= params.mergeClustersThreshold) unite(aId, bId);
    }
  }

  if (kDebugMode) {
    final roots = clusterIds.map((c) => '$c->${find(c)}').join(', ');
    debugPrint('[DIA] unionRoots: $roots');
  }

  // 4) relabel merged windows by root id + collect diar embeddings
  final relabeled = <_IsolatedTurn>[];
  final diarEmbs = <String, List<Float32List>>{}; // diarLabel -> embeddings
  for (final s in filteredMergedWin) {
    final root = find(s.cid);
    final lab = 'S$root';
    relabeled.add(_IsolatedTurn(lab, s.a / fs, s.b / fs));
    diarEmbs.putIfAbsent(lab, () => <Float32List>[]).addAll(s.embs);
  }

  // 5) min segment filter
  final out =
      relabeled.where((t) => (t.b - t.a) >= params.minSegmentSec).toList();
  if (out.isEmpty) {
    return EnhancedDiarizationResult(turns: const [], speakerMatches: const {});
  }

  // 6) fix overlaps
  out.sort((a, b) => a.a.compareTo(b.a));
  final fixed = <_IsolatedTurn>[];
  for (int j = 0; j < out.length; j++) {
    var turn = out[j];
    if (j > 0) {
      final prev = fixed.last;
      if (turn.a < prev.b) {
        if (kDebugMode) {
          debugPrint(
              '[DIA] overlapFix prevEnd=${prev.b.toStringAsFixed(2)} turnStart=${turn.a.toStringAsFixed(2)}');
        }
        if (turn.b <= prev.b + 0.10) {
          // Fully overlapped (or tiny). Drop it.
          continue;
        }
        // Clamp start to previous end without extending end artificially.
        turn = _IsolatedTurn(turn.spk, prev.b, turn.b);
      }
    }
    if (turn.b > turn.a) fixed.add(turn);
  }

  // 7) gap-aware merge
  var mergedTurns = _mergeGapAwareTurnsIsolate(fixed, maxGap: 0.4);
  if (mergedTurns.isEmpty) {
    return EnhancedDiarizationResult(turns: const [], speakerMatches: const {});
  }

  // ===== SPEAKER MATCHING (OPTIONAL) + COLLAPSE SAME ENROLLED =====

  // enrolledName -> centroid embedding
  final enrolled = <String, Float32List>{};
  if (params.matchSpeakers && params.speakerMemoryData.isNotEmpty) {
    params.speakerMemoryData.forEach((name, list) {
      final embs = <Float32List>[];
      for (final e in list) {
        embs.add(_l2normIsolate(
            Float32List.fromList(e.map((x) => x.toDouble()).toList())));
      }
      final cen = _meanAndNorm(embs);
      if (cen.isNotEmpty) enrolled[name] = cen;
    });
  }

  // diarLabel -> enrolledName (best >= threshold)
  final diarToEnrolled = <String, String>{};
  if (params.matchSpeakers && enrolled.isNotEmpty) {
    for (final entry in diarEmbs.entries) {
      final diarLab = entry.key;
      final diarCentroid = _meanAndNorm(entry.value);
      if (diarCentroid.isEmpty) continue;

      double best = -1;
      double secondBest = -1;
      String? bestName;
      enrolled.forEach((name, emb) {
        final sim = IsolatedSpeakerMatcher.cosine(diarCentroid, emb);
        if (sim > best) {
          secondBest = best;
          best = sim;
          bestName = name;
        } else if (sim > secondBest) {
          secondBest = sim;
        }
      });

      if (bestName != null &&
          best >= params.matchThreshold &&
          (best - secondBest) >= params.matchMargin) {
        diarToEnrolled[diarLab] = bestName!;
        if (kDebugMode) {
          debugPrint(
            '[DIA] MATCHED $diarLab -> $bestName sim=${best.toStringAsFixed(3)} th=${params.matchThreshold.toStringAsFixed(3)}',
          );
        }
      } else if (kDebugMode) {
        debugPrint(
            '[DIA] NO MATCH for $diarLab best=${best.toStringAsFixed(3)} th=${params.matchThreshold.toStringAsFixed(3)}');
      }
    }
  }

  // If multiple diar labels match the same enrolled speaker, collapse to ONE canonical diar label by talk duration
  final talkByDiar0 = <String, double>{};
  for (final t in mergedTurns) {
    talkByDiar0[t.spk] = (talkByDiar0[t.spk] ?? 0) + (t.b - t.a);
  }

  final canonicalByEnrolled = <String, String>{}; // enrolled -> diarLabel
  for (final e in diarToEnrolled.entries) {
    final diarLab = e.key;
    final name = e.value;

    final curCanon = canonicalByEnrolled[name];
    if (curCanon == null) {
      canonicalByEnrolled[name] = diarLab;
    } else {
      final durA = talkByDiar0[diarLab] ?? 0.0;
      final durB = talkByDiar0[curCanon] ?? 0.0;
      if (durA > durB) canonicalByEnrolled[name] = diarLab;
    }
  }

  // Apply collapse to turns
  if (canonicalByEnrolled.isNotEmpty) {
    mergedTurns = mergedTurns.map((t) {
      final enrolledName = diarToEnrolled[t.spk];
      if (enrolledName == null) return t;
      final canon = canonicalByEnrolled[enrolledName] ?? t.spk;
      return _IsolatedTurn(canon, t.a, t.b);
    }).toList();
    mergedTurns = _mergeGapAwareTurnsIsolate(mergedTurns, maxGap: 0.4);
  }

  // Apply collapse to diarEmbs too (so later constraints use the collapsed labels)
  final diarEmbsCollapsed = <String, List<Float32List>>{};
  diarEmbs.forEach((lab, list) {
    final enrolledName = diarToEnrolled[lab];
    final canon =
        (enrolledName == null) ? lab : (canonicalByEnrolled[enrolledName] ?? lab);
    diarEmbsCollapsed.putIfAbsent(canon, () => <Float32List>[]).addAll(list);
  });

  // ===== ✅ STABLE “SANDWICH” COLLAPSE (uses stableMergeThreshold / stableBridgeMaxSec) =====
  final diarCentroids = <String, Float32List>{};
  diarEmbsCollapsed.forEach((lab, list) {
    final c = _meanAndNorm(list);
    if (c.isNotEmpty) diarCentroids[lab] = c;
  });

  mergedTurns = _collapseSandwichTurns(
    mergedTurns,
    diarCentroid: diarCentroids,
    stableMergeThreshold: params.stableMergeThreshold,
    stableBridgeMaxSec: params.stableBridgeMaxSec,
  );

  // ===== OPTIONAL: FORCE FINAL SPEAKER COUNT (merge-until-N) =====
  if (params.targetSpeakers != null && params.targetSpeakers! > 0) {
    final res = _forceSpeakerCount(
      mergedTurns: mergedTurns,
      diarEmbs: diarEmbsCollapsed,
      diarToEnrolled: diarToEnrolled,
      target: params.targetSpeakers!,
      debug: kDebugMode,
    );
    mergedTurns = res.mergedTurns;
    // res.diarEmbs is available if you later want to log centroids, etc.
  }

  // ===== FINAL LABELING (S1, S2, ...) =====
  final talkDuration = <String, double>{};
  for (final t in mergedTurns) {
    talkDuration[t.spk] = (talkDuration[t.spk] ?? 0) + (t.b - t.a);
  }

  final sortedSpeakers = talkDuration.keys.toList()
    ..sort((a, b) => talkDuration[b]!.compareTo(talkDuration[a]!));

  final finalLabelMap = <String, String>{
    for (int i = 0; i < sortedSpeakers.length; i++)
      sortedSpeakers[i]: 'S${i + 1}',
  };

  if (kDebugMode) debugPrint('[DIA] finalLabelMap: $finalLabelMap');

  final finalTurns = mergedTurns
      .where((t) => (t.b - t.a) >= params.minSegmentSec)
      .map((t) => _IsolatedTurn(finalLabelMap[t.spk]!, t.a, t.b))
      .toList();

  // Final speakerMatches: finalLabel -> enrolledName (only for canonical diar labels)
  final finalMatches = <String, String>{};
  canonicalByEnrolled.forEach((enrolledName, diarCanon) {
    final fl = finalLabelMap[diarCanon];
    if (fl != null) finalMatches[fl] = enrolledName;
  });

  if (kDebugMode) {
    final speakersCount = finalTurns.map((t) => t.spk).toSet().length;
    debugPrint(
        '[DIA] DONE mergedTurns=${finalTurns.length} speakers=$speakersCount matches=$finalMatches');
  }

  return EnhancedDiarizationResult(
    turns: finalTurns.map((t) => t.toSerializable()).toList(),
    speakerMatches: finalMatches,
  );
}

class _ForceCountResult {
  final List<_IsolatedTurn> mergedTurns;
  final Map<String, List<Float32List>> diarEmbs;
  _ForceCountResult(this.mergedTurns, this.diarEmbs);
}

_ForceCountResult _forceSpeakerCount({
  required List<_IsolatedTurn> mergedTurns,
  required Map<String, List<Float32List>> diarEmbs,
  required Map<String, String> diarToEnrolled,
  required int target,
  required bool debug,
}) {
  Map<String, double> talkBy(List<_IsolatedTurn> turns) {
    final m = <String, double>{};
    for (final t in turns) {
      m[t.spk] = (m[t.spk] ?? 0) + (t.b - t.a);
    }
    return m;
  }

  var turns = mergedTurns;
  var embs = Map<String, List<Float32List>>.fromEntries(
    diarEmbs.entries.map((e) => MapEntry(e.key, [...e.value])),
  );

  Set<String> labelsInTurns() => turns.map((t) => t.spk).toSet();

  while (labelsInTurns().length > target) {
    final labels = labelsInTurns().toList();
    final talk = talkBy(turns);

    // Build centroids
    final centroids = <String, Float32List>{};
    for (final lab in labels) {
      final list = embs[lab] ?? const <Float32List>[];
      final c = _meanAndNorm(list);
      if (c.isNotEmpty) centroids[lab] = c;
    }

    double bestSim = -1;
    String? bestA;
    String? bestB;

    for (int i = 0; i < labels.length; i++) {
      for (int j = i + 1; j < labels.length; j++) {
        final a = labels[i];
        final b = labels[j];

        final ea = diarToEnrolled[a];
        final eb = diarToEnrolled[b];

        // Don't merge two DIFFERENT enrolled speakers (if both matched)
        if (ea != null && eb != null && ea != eb) continue;

        final ca = centroids[a];
        final cb = centroids[b];
        if (ca == null || cb == null) continue;

        final sim = IsolatedSpeakerMatcher.cosine(ca, cb);
        if (sim > bestSim) {
          bestSim = sim;
          bestA = a;
          bestB = b;
        }
      }
    }

    if (bestA == null || bestB == null) {
      if (debug) {
        debugPrint(
            '[DIA] targetSpeakers=$target: no mergeable pair found; stopping');
      }
      break;
    }

    // Merge into the label with higher talk
    final durA = talk[bestA] ?? 0.0;
    final durB = talk[bestB] ?? 0.0;
    final keep = (durA >= durB) ? bestA! : bestB!;
    final drop = (keep == bestA) ? bestB! : bestA!;

    if (debug) {
      debugPrint(
          '[DIA] targetSpeakers=$target: merging $drop -> $keep sim=${bestSim.toStringAsFixed(3)}');
    }

    // Relabel turns
    turns = turns.map((t) {
      if (t.spk != drop) return t;
      return _IsolatedTurn(keep, t.a, t.b);
    }).toList();
    turns = _mergeGapAwareTurnsIsolate(turns, maxGap: 0.4);

    // Merge embeddings
    embs.putIfAbsent(keep, () => <Float32List>[]);
    embs[keep]!.addAll(embs[drop] ?? const <Float32List>[]);
    embs.remove(drop);
  }

  return _ForceCountResult(turns, embs);
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
  for (final x in v) {
    s += x * x;
  }
  final r = math.sqrt(math.max(s, 1e-12));
  final out = Float32List(v.length);
  for (int i = 0; i < v.length; i++) {
    out[i] = v[i] / r;
  }
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
  for (int i = 0; i < dim; i++) {
    acc[i] /= n;
  }
  return _l2normIsolate(acc);
}

// Backward-compatible helper name used in a couple of call sites.
// (Mean of embeddings + L2 normalize)
Float32List _meanNormalizeIsolate(List<Float32List> embs) => _meanAndNorm(embs);

/// ✅ Collapse “A -> B -> A” when B is short and centroid(B) close to centroid(A)
List<_IsolatedTurn> _collapseSandwichTurns(
  List<_IsolatedTurn> turns, {
  required Map<String, Float32List> diarCentroid,
  required double stableMergeThreshold,
  required double stableBridgeMaxSec,
}) {
  if (turns.length < 3) return turns;

  final t = [...turns]..sort((a, b) => a.a.compareTo(b.a));
  final out = <_IsolatedTurn>[];

  for (int i = 0; i < t.length; i++) {
    if (i == 0 || i == t.length - 1) {
      out.add(t[i]);
      continue;
    }

    final prev = out.last;
    final mid = t[i];
    final next = t[i + 1];

    if (prev.spk == next.spk && mid.spk != prev.spk) {
      final midDur = mid.b - mid.a;
      if (midDur <= stableBridgeMaxSec) {
        final cPrev = diarCentroid[prev.spk];
        final cMid = diarCentroid[mid.spk];
        if (cPrev != null &&
            cMid != null &&
            cPrev.isNotEmpty &&
            cMid.isNotEmpty) {
          final sim = IsolatedSpeakerMatcher.cosine(cPrev, cMid);
          if (sim >= stableMergeThreshold) {
            out.add(_IsolatedTurn(prev.spk, mid.a, mid.b));
            continue;
          }
        }
      }
    }
    out.add(mid);
  }

  // ensure last exists
  if (t.isNotEmpty) {
    final last = t.last;
    if (out.isEmpty ||
        out.last.spk != last.spk ||
        out.last.a != last.a ||
        out.last.b != last.b) {
      out.add(last);
    }
  }

  return _mergeGapAwareTurnsIsolate(out, maxGap: 0.4);
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

  double mergeClustersThreshold = 0.86,

  /// ✅ added back to public API
  double stableMergeThreshold = 0.78,
  double stableBridgeMaxSec = 1.6,

  double minClusterTalkSec = 2.5,
  double minSegmentSec = 0.8,

  int maxSpeakersCap = 12,

  // ✅ new speaker controls
  double newSpeakerFloor = 0.58,
  int newSpeakerConfirmWindows = 4,
  double stayHysteresis = 0.06,

  // ✅ OPTIONAL: force final number of speakers
  int? targetSpeakers,

  // ✅ speaker matching (only used if speakerMemoryData is not empty AND matchSpeakers=true)
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
    stableBridgeMaxSec: stableBridgeMaxSec,

    minClusterTalkSec: minClusterTalkSec,
    minSegmentSec: minSegmentSec,

    maxSpeakersCap: maxSpeakersCap,

    newSpeakerFloor: newSpeakerFloor,
    newSpeakerConfirmWindows: newSpeakerConfirmWindows,
    stayHysteresis: stayHysteresis,

    targetSpeakers: targetSpeakers,

    matchSpeakers: matchSpeakers,
    matchThreshold: matchThreshold,
    speakerMemoryData: speakerMemoryData,
  );

  return compute(_runEmbeddingDiarizationInIsolate, params);
}