import 'package:sherpa_onnx/sherpa_onnx.dart';
import 'model_bootstrap.dart';

class SpeakerTurn {
  final double startSec;
  final double endSec;
  final String speaker; // "S1", "S2", ...
  const SpeakerTurn({required this.startSec, required this.endSec, required this.speaker});
  @override
  String toString() => '[$speaker] ${startSec.toStringAsFixed(2)}s → ${endSec.toStringAsFixed(2)}s';
}

class DiarizerService {
  OfflineSpeakerDiarization? _engine;
  bool get isReady => _engine != null;

  Future<void> init({
    int expectedNumSpeakers = 0,   // 0 = auto
    double threshold = 0.85,       // higher reduces false speakers
    int numThreads = 2,
  }) async {
    initBindings();
    final mp = await ensureDiarizationModels();

    final segCfg = OfflineSpeakerSegmentationModelConfig.new(
      pyannote: OfflineSpeakerSegmentationPyannoteModelConfig(model: mp.segOnnx),
      numThreads: numThreads,
      provider: 'cpu',
      debug: false,
    );

    final embCfg = SpeakerEmbeddingExtractorConfig.new(
      model: mp.embOnnx,
      numThreads: numThreads,
      provider: 'cpu',
      debug: false,
    );

    final clust = FastClusteringConfig(
      numClusters: expectedNumSpeakers <= 0 ? -1 : expectedNumSpeakers, // -1 = auto
      threshold: threshold,
    );

    final cfg = OfflineSpeakerDiarizationConfig(
      segmentation: segCfg,
      embedding: embCfg,
      clustering: clust,
      minDurationOn: 0.20,
      minDurationOff: 0.50,
    );

    _engine = OfflineSpeakerDiarization(cfg);
  }

  Future<List<SpeakerTurn>> diarizeFile(
    String wavPath, {
    double minSegDur = 0.40,      // drop super short blips
    double minorMinSec = 1.00,    // speakers below this absolute duration get merged
    double minorMaxShare = 0.08,  // or below this fraction of total speech
  }) async {
    final eng = _engine;
    if (eng == null) throw StateError('Diarizer not initialized');

    final wave = readWave(wavPath);
    if (wave.samples.isEmpty || wave.sampleRate <= 0) return const [];

    final segs = eng.process(samples: wave.samples);

    final raw = <_Turn>[
      for (final s in segs) _Turn(s.start, s.end, 'SPK_${s.speaker}')
    ];

    final filt = raw.where((t) => (t.end - t.start) >= minSegDur).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    if (filt.isEmpty) return const [];

    final merged = _mergeAdjacent(filt, gap: 0.15);

    final totals = <String, double>{};
    double totalAll = 0.0;
    for (final t in merged) {
      final d = (t.end - t.start);
      totals[t.spk] = (totals[t.spk] ?? 0) + d;
      totalAll += d;
    }

    final sorted = totals.keys.toList()
      ..sort((a, b) => (totals[b] ?? 0).compareTo(totals[a] ?? 0));
    final dominant = sorted.first;

    final keep = <String>{};
    for (final s in sorted) {
      final dur = totals[s] ?? 0;
      final share = totalAll <= 0 ? 0.0 : dur / totalAll;
      if (dur >= minorMinSec && share >= minorMaxShare) keep.add(s);
    }
    if (keep.isEmpty) keep.add(dominant);

    final reassigned = <_Turn>[];
    String lastKept = dominant;
    for (final t in merged) {
      final spk = keep.contains(t.spk) ? t.spk : lastKept;
      reassigned.add(_Turn(t.start, t.end, spk));
      lastKept = spk;
    }

    final keptSorted = keep.toList()
      ..sort((a, b) => (totals[b] ?? 0).compareTo(totals[a] ?? 0));
    final labelMap = <String, String>{};
    for (var i = 0; i < keptSorted.length; i++) {
      labelMap[keptSorted[i]] = 'S${i + 1}';
    }

    final finalTurns = _mergeAdjacent(reassigned, gap: 0.15)
        .map((t) => SpeakerTurn(
              startSec: t.start,
              endSec: t.end,
              speaker: labelMap[t.spk] ?? 'S1',
            ))
        .toList();

    return finalTurns;
  }

  void dispose() { _engine?.free(); _engine = null; }
}

class _Turn {
  final double start, end;
  final String spk;
  _Turn(this.start, this.end, this.spk);
}

List<_Turn> _mergeAdjacent(List<_Turn> input, {double gap = 0.15}) {
  if (input.isEmpty) return input;
  final out = <_Turn>[input.first];
  for (var i = 1; i < input.length; i++) {
    final a = out.last, b = input[i];
    if (a.spk == b.spk && (b.start - a.end) <= gap) {
      out[out.length - 1] = _Turn(a.start, b.end, a.spk);
    } else {
      out.add(b);
    }
  }
  return out;
}
