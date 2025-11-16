import 'dart:math' as math;
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'audio_utils.dart';

class PreprocessOptions {
  final bool removeDc;
  final bool highpassRumble;   // one-pole HPF
  final double hpCutHz;        // ~80 Hz default
  final bool preEmphasis;      // y[n] = x[n] - a*x[n-1]
  final double preEmphasisCoeff; // 0.97
  final bool noiseGate;        // mild gate by window RMS
  final double gateRmsDb;      // -45 dBFS
  final double gateAtten;      // 0..1 attenuation (0 = hard mute)
  final int rmsWindowMs;       // 20 ms
  final bool trimSilence;      // trim head/tail by RMS threshold
  final double trimBelowDb;    // -50 dBFS
  final int trimMinRunMs;      // 150 ms
  final bool peakNormalize;    // normalize to target peak
  final double targetPeakDbfs; // -1.0 dBFS

  const PreprocessOptions({
    this.removeDc = true,
    this.highpassRumble = true,
    this.hpCutHz = 80.0,
    this.preEmphasis = false,
    this.preEmphasisCoeff = 0.97,
    this.noiseGate = true,
    this.gateRmsDb = -45.0,
    this.gateAtten = 0.15,
    this.rmsWindowMs = 20,
    this.trimSilence = true,
    this.trimBelowDb = -50.0,
    this.trimMinRunMs = 150,
    this.peakNormalize = true,
    this.targetPeakDbfs = -1.0,
  });
}

/// Pipeline:
/// DC remove → HPF → (pre-emphasis) → noise gate → trim → normalize
Future<String> preprocessWav16kMono(String inputPath,
    {PreprocessOptions opts = const PreprocessOptions(), String? outPath}) async {
  final info = await parseWavInfo(inputPath);
  if (info.channels != 1 || info.bitsPerSample != 16) {
    throw UnsupportedError('Expected PCM16 mono 16 kHz WAV');
  }
  final fs = info.sampleRate;
  final s16 = await readPcm16MonoSamples(inputPath);
  final N = s16.length;
  if (N == 0) return inputPath;

  // int16 -> float [-1,1]
  final x = Float32List(N);
  for (var i = 0; i < N; i++) {
    x[i] = (s16[i] / 32768.0).clamp(-1.0, 1.0).toDouble();
  }

  // DC removal
  if (opts.removeDc) {
    double mean = 0;
    for (final v in x) { mean += v; }
    mean /= N;
    for (var i = 0; i < N; i++) x[i] -= mean;
  }

  // One-pole HPF (~80 Hz)
  if (opts.highpassRumble && opts.hpCutHz > 0) {
    final fc = opts.hpCutHz;
    final dt = 1.0 / fs;
    final rc = 1.0 / (2 * math.pi * fc);
    final alpha = rc / (rc + dt);
    double yPrev = 0.0;
    double xPrev = x[0];
    for (var i = 0; i < N; i++) {
      final y = alpha * (yPrev + x[i] - xPrev);
      xPrev = x[i];
      yPrev = y;
      x[i] = y;
    }
  }

  // Optional pre-emphasis
  if (opts.preEmphasis) {
    final a = opts.preEmphasisCoeff;
    double prev = x[0];
    for (var i = 1; i < N; i++) {
      final cur = x[i];
      x[i] = (cur - a * prev);
      prev = cur;
    }
  }

  // Windowed RMS (for gate & trim)
  final w = (opts.rmsWindowMs * fs / 1000).clamp(8, 2048).toInt();
  final sq = Float32List(N);
  for (var i = 0; i < N; i++) sq[i] = x[i] * x[i];
  final prefix = Float32List(N + 1);
  for (var i = 0; i < N; i++) prefix[i + 1] = prefix[i] + sq[i];

  double _rmsAt(int idx) {
    final a = math.max(0, idx - w ~/ 2);
    final b = math.min(N, a + w);
    final sum = prefix[b] - prefix[a];
    final len = (b - a).clamp(1, 1 << 30);
    final rms = math.sqrt(sum / len);
    return rms;
  }

  // Noise gate (soft)
  if (opts.noiseGate) {
    final thr = math.pow(10.0, opts.gateRmsDb / 20.0).toDouble(); // amplitude
    final atten = opts.gateAtten.clamp(0.0, 1.0).toDouble();
    for (var i = 0; i < N; i++) {
      final rms = _rmsAt(i);
      if (rms < thr) x[i] *= atten;
    }
  }

  // Trim head/tail silence
  int start = 0, end = N;
  if (opts.trimSilence) {
    final thr = math.pow(10.0, opts.trimBelowDb / 20.0).toDouble();
    final run = (opts.trimMinRunMs * fs / 1000).clamp(1, N).toInt();

    // head
    int head = 0, consec = 0;
    for (var i = 0; i < N; i++) {
      if (_rmsAt(i) >= thr) {
        consec++;
        if (consec >= run) { head = math.max(0, i - run); break; }
      } else {
        consec = 0;
      }
    }

    // tail
    int tail = N, consec2 = 0;
    for (var i = N - 1; i >= 0; i--) {
      if (_rmsAt(i) >= thr) {
        consec2++;
        if (consec2 >= run) { tail = math.min(N, i + run); break; }
      } else {
        consec2 = 0;
      }
    }

    if (tail > head) { start = head; end = tail; }
  }

  // Slice to [start, end)
  final M = (end - start).clamp(0, N);
  final y = Float32List(M);
  for (var i = 0; i < M; i++) y[i] = x[start + i];

  // Peak normalize
  if (opts.peakNormalize && M > 0) {
    double maxAbs = 0;
    for (var i = 0; i < M; i++) { final a = y[i].abs(); if (a > maxAbs) maxAbs = a; }
    final target = math.pow(10.0, opts.targetPeakDbfs / 20.0).toDouble(); // e.g., -1 dBFS
    if (maxAbs > 1e-9) {
      final g = (target / maxAbs);
      for (var i = 0; i < M; i++) y[i] = (y[i] * g).clamp(-1.0, 1.0).toDouble();
    }
  }

  // float -> int16
  final out = Int16List(M);
  for (var i = 0; i < M; i++) {
    final v = (y[i] * 32768.0).round();
    out[i] = v.clamp(-32768, 32767);
  }

  final tmp = outPath ??
      '${(await getTemporaryDirectory()).path}/pre_${DateTime.now().millisecondsSinceEpoch}.wav';
  await writePcm16MonoWav(tmp, sampleRate: fs, samples: out);
  return tmp;
}
