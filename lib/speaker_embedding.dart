// lib/speaker_embedding.dart
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'audio_utils.dart';

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

  // =====================================================================
  // ✅ CRASH-PROOF SETTINGS
  // =====================================================================

  /// Many speaker-embedding ONNX models (as packaged in sherpa) can SIGABRT
  /// if you feed arbitrary waveform lengths. Use a fixed window always.
  ///
  /// Use 2.5s at 16k by default (40,000 samples). This is generally safe and
  /// avoids the short/odd lengths (e.g., 12,288) that triggered your crashes.
  static const double kDefaultWindowSec = 2.5;

  int _windowSamples(int sampleRate, {double windowSec = kDefaultWindowSec}) {
    return (windowSec * sampleRate).round().clamp(1, 1 << 30);
  }

  Float32List _l2norm(Float32List v) {
    double s = 0.0;
    for (final x in v) {
      s += x * x;
    }
    final r = math.sqrt(math.max(s, 1e-12));
    final out = Float32List(v.length);
    for (var i = 0; i < v.length; i++) {
      out[i] = v[i] / r;
    }
    return out;
  }

  /// Build an exact-length window centered around [mid], returning null if
  /// we cannot extract full window without shrinking (shrinking causes crashes).
  Float32List? _extractFixedWindow({
    required Float32List samples,
    required int mid,
    required int win,
  }) {
    if (samples.isEmpty || win <= 0) return null;
    final start = mid - (win ~/ 2);
    final end = start + win;

    // ✅ Strict: DO NOT clamp to smaller window (variable sizes can crash ORT).
    if (start < 0) return null;
    if (end > samples.length) return null;

    // Copies the range - acceptable for small windows.
    return samples.sublist(start, end);
  }

  /// Low-level compute on a slice that MUST be fixed-length.
  Float32List _computeEmbeddingFixedSlice({
    required Float32List slice,
    required int sampleRate,
  }) {
    final stream = _ext.createStream();
    stream.acceptWaveform(samples: slice, sampleRate: sampleRate);
    stream.inputFinished();
    final vec = _ext.compute(stream);
    stream.free();
    return _l2norm(vec);
  }

  // =====================================================================
  // Public APIs
  // =====================================================================

  /// Compute a normalized embedding from a WAV file (PCM mono).
  /// If [startSec]..[endSec] provided, we will take a FIXED window centered
  /// inside that span. If the span is too close to boundary, returns empty.
  Future<Float32List> embedFromWav(
    String wavPath, {
    double startSec = -1,
    double endSec = -1,
    double windowSec = kDefaultWindowSec,
  }) async {
    final wave = readWave(wavPath); // Float32List samples, int sampleRate
    final samples = wave.samples;
    final fs = wave.sampleRate;

    // ✅ Hard guard (your pipeline assumes 16k for diarization/embedding)
    if (fs != 16000) return Float32List(0);

    final win = _windowSamples(fs, windowSec: windowSec);

    int mid;
    if (startSec >= 0 && endSec > startSec) {
      final a = (startSec * fs).round();
      final b = (endSec * fs).round();
      if (b <= a) return Float32List(0);
      mid = a + ((b - a) ~/ 2);
    } else {
      // Entire file: take a centered window in the middle.
      mid = samples.length ~/ 2;
    }

    final slice = _extractFixedWindow(samples: samples, mid: mid, win: win);
    if (slice == null) return Float32List(0);

    // If model still aborts, it will be native; fixed-size prevents the known issue.
    return _computeEmbeddingFixedSlice(slice: slice, sampleRate: fs);
  }

  /// ✅ FAST + SAFE: Compute embedding from already-loaded samples using a
  /// FIXED-length window centered inside [startIndex..endIndex].
  ///
  /// IMPORTANT: This is the method you should call from chunk post-processing.
  /// It never feeds variable-length slices to ORT; if it cannot form a full
  /// window, it returns empty (and your caller should skip that segment).
  Future<Float32List> embedFromSamplesFixedWindow({
    required Float32List samples,
    required int sampleRate,
    required int startIndex,
    required int endIndex,
    double windowSec = kDefaultWindowSec,
  }) async {
    // ✅ Hard guard
    if (sampleRate != 16000) return Float32List(0);

    final a = startIndex;
    final b = endIndex;
    if (b <= a) return Float32List(0);

    final win = _windowSamples(sampleRate, windowSec: windowSec);

    // center inside the requested span
    final mid = a + ((b - a) ~/ 2);

    final slice = _extractFixedWindow(samples: samples, mid: mid, win: win);
    if (slice == null) return Float32List(0);

    return _computeEmbeddingFixedSlice(slice: slice, sampleRate: sampleRate);
  }

  /// ⚠️ Legacy API (variable range). KEEPING for compatibility, but now it is
  /// made crash-proof by internally using fixed window behavior.
  ///
  /// If you *really* need raw range, don’t. That’s what triggers SIGABRT.
  Future<Float32List> embedFromSamplesRange({
    required Float32List samples,
    required int sampleRate,
    required int startIndex,
    required int endIndex,
  }) async {
    // Route to safe fixed-window method with default window size.
    return embedFromSamplesFixedWindow(
      samples: samples,
      sampleRate: sampleRate,
      startIndex: startIndex,
      endIndex: endIndex,
      windowSec: kDefaultWindowSec,
    );
  }

  /// Average a set of embeddings then L2-normalize.
  Float32List meanPool(Iterable<Float32List> vecs) {
    Float32List? sum;
    var count = 0;
    for (final v in vecs) {
      if (v.isEmpty) continue;
      if (sum == null) {
        sum = Float32List.fromList(v);
      } else {
        final m = math.min(sum.length, v.length);
        for (var i = 0; i < m; i++) {
          sum[i] += v[i];
        }
      }
      count++;
    }
    if (sum == null || count == 0) return Float32List(0);
    for (var i = 0; i < sum.length; i++) {
      sum[i] /= count;
    }
    return _l2norm(sum);
  }

  static double cosine(Float32List a, Float32List b) {
    if (a.isEmpty || b.isEmpty) return 0.0;
    if (a.length != b.length) return 0.0;
    double s = 0.0;
    for (int i = 0; i < a.length; i++) {
      s += a[i] * b[i];
    }
    return s; // embeddings are L2-normalized already
  }

  void dispose() => _ext.free();
}