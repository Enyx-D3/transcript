// lib/diarizer_service.dart
import 'package:sherpa_onnx/sherpa_onnx.dart';
import 'model_bootstrap.dart';

class SpeakerTurn {
  final double startSec;
  final double endSec;
  final String speaker; // "S1", "S2", ...
  const SpeakerTurn({
    required this.startSec,
    required this.endSec,
    required this.speaker,
  });

  @override
  String toString() =>
      '[$speaker] ${startSec.toStringAsFixed(2)}s → ${endSec.toStringAsFixed(2)}s';
}

class DiarizerService {
  OfflineSpeakerDiarization? _engine;
  bool get isReady => _engine != null;

  /// IMPORTANT: call this ONLY from the background isolate (FlutterForegroundTask).
  Future<void> init({
    int expectedNumSpeakers = 0, // 0 = auto
    double threshold = 0.55,     // lower => more clusters, better chance to see S2
    int numThreads = 2,
  }) async {
    if (_engine != null) return; // avoid re-init in same isolate

    initBindings();
    final mp = await ensureDiarizationModels();

    final segCfg = OfflineSpeakerSegmentationModelConfig(
      pyannote: OfflineSpeakerSegmentationPyannoteModelConfig(
        model: mp.segOnnx,
      ),
      numThreads: numThreads,
      provider: 'cpu',
      debug: false,
    );

    final embCfg = SpeakerEmbeddingExtractorConfig(
      model: mp.embOnnx,
      numThreads: numThreads,
      provider: 'cpu',
      debug: false,
    );

    final clustCfg = FastClusteringConfig(
      numClusters: expectedNumSpeakers <= 0 ? -1 : expectedNumSpeakers,
      threshold: threshold,
    );

    final cfg = OfflineSpeakerDiarizationConfig(
      segmentation: segCfg,
      embedding: embCfg,
      clustering: clustCfg,
      minDurationOn: 0.15,
      minDurationOff: 0.25,
    );

    _engine = OfflineSpeakerDiarization(cfg);
  }

  /// Main diarization call. **Background isolate only.**
  Future<List<SpeakerTurn>> diarizeFile(
    String wavPath, {
    double minSegDur = 0.30,   // ignore very short blips
    double gapMergeSec = 1.0,  // merge same-speaker segments within this gap
  }) async {
    final eng = _engine;
    if (eng == null) throw StateError('Diarizer not initialized');

    final wave = readWave(wavPath);
    if (wave.samples.isEmpty || wave.sampleRate <= 0) return const [];

    final segs = eng.process(samples: wave.samples);

    // Raw segments: SPK_0, SPK_1, ...
    final raw = <_Turn>[
      for (final s in segs) _Turn(s.start, s.end, 'SPK_${s.speaker}'),
    ];

    // Filter out tiny segments
    final filt = raw
        .where((t) => (t.end - t.start) >= minSegDur)
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    if (filt.isEmpty) return const [];

    // 1) Merge adjacent segments from same raw SPK_* with small gaps.
    final mergedPerSpk = _mergeAdjacent(filt, gap: gapMergeSec);

    // 2) Compute total talking time per raw SPK_*.
    final totals = <String, double>{};
    for (final t in mergedPerSpk) {
      totals[t.spk] = (totals[t.spk] ?? 0) + (t.end - t.start);
    }

    // 3) Rank speakers by total duration and assign S1, S2, ...
    final ordered = totals.keys.toList()
      ..sort((a, b) => (totals[b] ?? 0).compareTo(totals[a] ?? 0));
    if (ordered.isEmpty) return const [];

    final labelMap = <String, String>{};
    for (var i = 0; i < ordered.length; i++) {
      labelMap[ordered[i]] = 'S${i + 1}';
    }

    // 4) Convert SPK_* → S1/S2 and merge again to remove tiny splits on the same S*
    final labeled = mergedPerSpk
        .map((t) => _Turn(t.start, t.end, labelMap[t.spk] ?? 'S1'))
        .toList();
    final mergedFinal = _mergeAdjacent(labeled, gap: gapMergeSec);

    return [
      for (final t in mergedFinal)
        SpeakerTurn(
          startSec: t.start,
          endSec: t.end,
          speaker: t.spk,
        ),
    ];
  }

  void dispose() {
    _engine?.free();
    _engine = null;
  }
}

class _Turn {
  final double start;
  final double end;
  final String spk;
  _Turn(this.start, this.end, this.spk);
}

/// Merge adjacent segments with the same speaker if the gap is small.
List<_Turn> _mergeAdjacent(List<_Turn> input, {double gap = 1.0}) {
  if (input.isEmpty) return const [];
  final out = <_Turn>[];
  var cur = input.first;

  for (var i = 1; i < input.length; i++) {
    final next = input[i];
    if (next.spk == cur.spk && (next.start - cur.end) <= gap) {
      cur = _Turn(cur.start, next.end, cur.spk); // extend current
    } else {
      out.add(cur);
      cur = next;
    }
  }
  out.add(cur);
  return out;
}
