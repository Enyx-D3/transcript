// lib/speaker_embedding.dart
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:sherpa_onnx/sherpa_onnx.dart';

class SpeakerEmbedder {
  static SpeakerEmbedder? _instance;
  final SpeakerEmbeddingExtractor _ext;

  SpeakerEmbedder._(this._ext);

  static Future<SpeakerEmbedder> instance(String embeddingOnnxPath) async {
    if (_instance != null) return _instance!;
    initBindings(); // required before using FFI
    final cfg = SpeakerEmbeddingExtractorConfig(
      model: embeddingOnnxPath,
      numThreads: 2,
      provider: 'cpu',
      debug: false,
    );
    final ext = SpeakerEmbeddingExtractor(config: cfg);
    _instance = SpeakerEmbedder._(ext);
    return _instance!;
  }

  /// Compute a normalized embedding from a WAV file (PCM16 mono).
  /// If [startSec]..[endSec] provided, only that span is used.
  Future<Float32List> embedFromWav(
    String wavPath, {
    double startSec = -1,
    double endSec = -1,
  }) async {
    final wave = readWave(wavPath); // Float32List samples, int sampleRate
    var samples = wave.samples;

    if (startSec >= 0 && endSec > startSec) {
      final fs = wave.sampleRate;
      final a = (startSec * fs).floor().clamp(0, samples.length);
      final b = (endSec * fs).ceil().clamp(0, samples.length);
      samples = samples.sublist(a, b);
    }

    final stream = _ext.createStream();
    stream.acceptWaveform(samples: samples, sampleRate: wave.sampleRate);
    stream.inputFinished();
    final vec = _ext.compute(stream);
    stream.free();

    return _l2norm(vec);
  }

  /// Average a set of embeddings then L2-normalize.
  Float32List meanPool(Iterable<Float32List> vecs) {
    Float32List? sum;
    var count = 0;
    for (final v in vecs) {
      if (sum == null) {
        sum = Float32List.fromList(v);
      } else {
        for (var i = 0; i < v.length; i++) sum[i] += v[i];
      }
      count++;
    }
    if (sum == null) return Float32List(0);
    for (var i = 0; i < sum.length; i++) sum[i] /= count;
    return _l2norm(sum);
  }

  static double cosine(Float32List a, Float32List b) {
    final n = math.min(a.length, b.length);
    double s = 0.0;
    for (var i = 0; i < n; i++) s += a[i] * b[i];
    return s;
  }

  static Float32List _l2norm(Float32List v) {
    double s = 0.0;
    for (final x in v) s += x * x;
    final r = math.sqrt(math.max(s, 1e-12));
    final out = Float32List(v.length);
    for (var i = 0; i < v.length; i++) out[i] = v[i] / r;
    return out;
  }

  void dispose() => _ext.free();
}
