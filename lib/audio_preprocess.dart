// lib/audio_preprocess.dart
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

import 'audio_utils.dart';

class PreprocessOptions {
  // Existing-ish
  final bool removeDc;
  final bool highpassRumble; // one-pole HPF
  final double hpCutHz; // ~80 Hz default
  final bool preEmphasis;
  final double preEmphasisCoeff;

  // ✅ Safer gate (duration-based)
  final bool gateByRun;
  final double gateRmsDb; // e.g. -55 dBFS
  final double gateAtten; // 0..1 attenuation (0.8 = gentle)
  final int gateMinRunMs; // e.g. 80 ms
  final int rmsWindowMs; // for RMS estimation, e.g. 20ms

  // Trim
  final bool trimSilence;
  final double trimBelowDb; // e.g. -55 dBFS for meetings
  final int trimMinRunMs; // e.g. 200ms
  final int trimPadMs; // ✅ keep context around trimmed audio, e.g. 250ms

  // ✅ RMS normalize (better for speech than peak normalize)
  final bool rmsNormalize;
  final double targetRmsDbfs; // e.g. -20
  final double rmsMaxGainDb; // e.g. +12
  final double rmsMinGainDb; // e.g. -12

  // ✅ Compressor + limiter (huge for meetings)
  final bool compressor;
  final double compThresholdDb; // e.g. -18
  final double compRatio; // e.g. 3.0
  final int compAttackMs; // e.g. 5
  final int compReleaseMs; // e.g. 80
  final bool limiter;
  final double limiterCeilDbfs; // e.g. -1.0

  // (Optional) keep your old peak normalize if you want, but limiter usually makes it redundant
  final bool peakNormalize;
  final double targetPeakDbfs;

  const PreprocessOptions({
    this.removeDc = true,
    this.highpassRumble = true,
    this.hpCutHz = 80.0,
    this.preEmphasis = false,
    this.preEmphasisCoeff = 0.97,

    this.gateByRun = false, // Start OFF; turn ON only if you really need it
    this.gateRmsDb = -55.0,
    this.gateAtten = 0.8,
    this.gateMinRunMs = 80,
    this.rmsWindowMs = 20,

    this.trimSilence = true,
    this.trimBelowDb = -55.0,
    this.trimMinRunMs = 200,
    this.trimPadMs = 250,

    this.rmsNormalize = true,
    this.targetRmsDbfs = -20.0,
    this.rmsMaxGainDb = 12.0,
    this.rmsMinGainDb = -12.0,

    this.compressor = true,
    this.compThresholdDb = -18.0,
    this.compRatio = 3.0,
    this.compAttackMs = 5,
    this.compReleaseMs = 80,
    this.limiter = true,
    this.limiterCeilDbfs = -1.0,

    this.peakNormalize = false,
    this.targetPeakDbfs = -1.0,
  });
}

// ---------------- DSP helpers ----------------

double _dbToAmp(double db) => math.pow(10.0, db / 20.0).toDouble();
double _ampToDb(double amp) => 20.0 * math.log(amp.clamp(1e-12, 1e12)) / math.ln10;

double _rms(Float32List x) {
  double s = 0;
  for (final v in x) s += v * v;
  return math.sqrt(s / x.length.clamp(1, 1 << 30));
}

void _applyGain(Float32List x, double g) {
  for (int i = 0; i < x.length; i++) {
    x[i] = (x[i] * g).clamp(-1.0, 1.0).toDouble();
  }
}

void _rmsNormalize(
  Float32List x, {
  required double targetDb,
  required double minGainDb,
  required double maxGainDb,
}) {
  if (x.isEmpty) return;
  final cur = _rms(x);
  if (cur < 1e-8) return;

  final target = _dbToAmp(targetDb);
  var g = target / cur;

  final gDb = _ampToDb(g);
  final clampedDb = gDb.clamp(minGainDb, maxGainDb).toDouble();
  g = _dbToAmp(clampedDb);

  _applyGain(x, g);
}

/// Simple compressor using envelope follower. Good enough for meetings.
void _compress(
  Float32List x,
  int fs, {
  required double thresholdDb,
  required double ratio,
  required int attackMs,
  required int releaseMs,
}) {
  if (x.isEmpty) return;

  final thr = _dbToAmp(thresholdDb);
  final attack = (attackMs * fs / 1000).clamp(1, 1 << 30).toInt();
  final release = (releaseMs * fs / 1000).clamp(1, 1 << 30).toInt();

  double env = 0.0;
  final aA = math.exp(-1.0 / attack);
  final aR = math.exp(-1.0 / release);

  for (int i = 0; i < x.length; i++) {
    final v = x[i].abs();

    if (v > env) {
      env = aA * env + (1 - aA) * v;
    } else {
      env = aR * env + (1 - aR) * v;
    }

    double g = 1.0;
    if (env > thr) {
      final over = env / thr;
      final desired = thr * math.pow(over, 1.0 / ratio);
      g = desired / env;
    }

    x[i] = (x[i] * g).clamp(-1.0, 1.0).toDouble();
  }
}

void _limit(Float32List x, {required double ceilDb}) {
  final ceil = _dbToAmp(ceilDb);
  for (int i = 0; i < x.length; i++) {
    x[i] = x[i].clamp(-ceil, ceil).toDouble();
  }
}

/// Duration-based gentle gate: only attenuate if below threshold for >= minRunMs.
/// Safer than per-sample gating (won't kill consonants as much).
void _gateByRun(
  Float32List x,
  int fs, {
  required double gateDb,
  required double atten,
  required int minRunMs,
  required int rmsWindowMs,
}) {
  if (x.isEmpty) return;

  final thr = _dbToAmp(gateDb);
  final w = (rmsWindowMs * fs / 1000).clamp(8, 4096).toInt();
  final minRun = (minRunMs * fs / 1000).clamp(1, x.length).toInt();

  final sq = Float32List(x.length);
  for (int i = 0; i < x.length; i++) sq[i] = x[i] * x[i];

  final pre = Float32List(x.length + 1);
  for (int i = 0; i < x.length; i++) pre[i + 1] = pre[i] + sq[i];

  double rmsAt(int idx) {
    final a = math.max(0, idx - w ~/ 2);
    final b = math.min(x.length, a + w);
    final sum = pre[b] - pre[a];
    final len = (b - a).clamp(1, 1 << 30);
    return math.sqrt(sum / len);
  }

  int runStart = -1;
  for (int i = 0; i < x.length; i++) {
    final silent = rmsAt(i) < thr;

    if (silent) {
      if (runStart < 0) runStart = i;
    } else {
      if (runStart >= 0) {
        final runLen = i - runStart;
        if (runLen >= minRun) {
          for (int k = runStart; k < i; k++) x[k] *= atten;
        }
        runStart = -1;
      }
    }
  }

  // tail run
  if (runStart >= 0) {
    final runLen = x.length - runStart;
    if (runLen >= minRun) {
      for (int k = runStart; k < x.length; k++) x[k] *= atten;
    }
  }
}

/// Peak normalize (optional)
void _peakNormalize(Float32List x, {required double targetPeakDbfs}) {
  if (x.isEmpty) return;
  double maxAbs = 0;
  for (int i = 0; i < x.length; i++) {
    final a = x[i].abs();
    if (a > maxAbs) maxAbs = a;
  }
  if (maxAbs < 1e-9) return;

  final target = _dbToAmp(targetPeakDbfs);
  final g = target / maxAbs;
  _applyGain(x, g);
}

// ---------------- Main preprocess ----------------

/// Pipeline:
/// 1) int16 -> float
/// 2) DC remove
/// 3) HPF
/// 4) (optional) duration-based gate
/// 5) Trim head/tail + padding
/// 6) RMS normalize (speech loudness)
/// 7) Compressor
/// 8) Limiter
/// 9) (optional) Peak normalize
Future<String> preprocessWav16kMono(
  String inputPath, {
  PreprocessOptions opts = const PreprocessOptions(),
  String? outPath,
}) async {
  final info = await parseWavInfo(inputPath);
  if (info.channels != 1 || info.bitsPerSample != 16 || info.sampleRate != 16000) {
    throw UnsupportedError('Expected PCM16 mono 16 kHz WAV');
  }

  final fs = info.sampleRate;
  final s16 = await readPcm16MonoSamples(inputPath);
  final N = s16.length;
  if (N == 0) return inputPath;

  // int16 -> float [-1, 1]
  final x = Float32List(N);
  for (int i = 0; i < N; i++) {
    x[i] = (s16[i] / 32768.0).clamp(-1.0, 1.0).toDouble();
  }

  // DC removal
  if (opts.removeDc) {
    double mean = 0;
    for (final v in x) mean += v;
    mean /= N;
    for (int i = 0; i < N; i++) x[i] -= mean;
  }

  // One-pole HPF (rumble)
  if (opts.highpassRumble && opts.hpCutHz > 0) {
    final fc = opts.hpCutHz;
    final dt = 1.0 / fs;
    final rc = 1.0 / (2 * math.pi * fc);
    final alpha = rc / (rc + dt);

    double yPrev = 0.0;
    double xPrev = x[0];
    for (int i = 0; i < N; i++) {
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
    for (int i = 1; i < N; i++) {
      final cur = x[i];
      x[i] = cur - a * prev;
      prev = cur;
    }
  }

  // Optional gate-by-run (safer than per-sample gate)
  if (opts.gateByRun) {
    _gateByRun(
      x,
      fs,
      gateDb: opts.gateRmsDb,
      atten: opts.gateAtten.clamp(0.0, 1.0).toDouble(),
      minRunMs: opts.gateMinRunMs,
      rmsWindowMs: opts.rmsWindowMs,
    );
  }

  // ---- Trim head/tail silence (RMS window) ----
  int start = 0;
  int end = N;

  if (opts.trimSilence) {
    final w = (opts.rmsWindowMs * fs / 1000).clamp(8, 4096).toInt();
    final thr = _dbToAmp(opts.trimBelowDb);

    // prefix sum of squares
    final sq = Float32List(N);
    for (int i = 0; i < N; i++) sq[i] = x[i] * x[i];
    final pre = Float32List(N + 1);
    for (int i = 0; i < N; i++) pre[i + 1] = pre[i] + sq[i];

    double rmsAt(int idx) {
      final a = math.max(0, idx - w ~/ 2);
      final b = math.min(N, a + w);
      final sum = pre[b] - pre[a];
      final len = (b - a).clamp(1, 1 << 30);
      return math.sqrt(sum / len);
    }

    final run = (opts.trimMinRunMs * fs / 1000).clamp(1, N).toInt();

    // head
    int head = 0;
    int consec = 0;
    for (int i = 0; i < N; i++) {
      if (rmsAt(i) >= thr) {
        consec++;
        if (consec >= run) {
          head = math.max(0, i - run);
          break;
        }
      } else {
        consec = 0;
      }
    }

    // tail
    int tail = N;
    int consec2 = 0;
    for (int i = N - 1; i >= 0; i--) {
      if (rmsAt(i) >= thr) {
        consec2++;
        if (consec2 >= run) {
          tail = math.min(N, i + run);
          break;
        }
      } else {
        consec2 = 0;
      }
    }

    if (tail > head) {
      start = head;
      end = tail;
    }

    // ✅ add padding after trim to preserve context
    final pad = (opts.trimPadMs * fs / 1000).toInt();
    start = math.max(0, start - pad);
    end = math.min(N, end + pad);
  }

  final M = (end - start).clamp(0, N);
  if (M <= 0) return inputPath;

  // Slice
  final y = Float32List(M);
  for (int i = 0; i < M; i++) y[i] = x[start + i];

  // ✅ Speech RMS normalize
  if (opts.rmsNormalize) {
    _rmsNormalize(
      y,
      targetDb: opts.targetRmsDbfs,
      minGainDb: opts.rmsMinGainDb,
      maxGainDb: opts.rmsMaxGainDb,
    );
  }

  // ✅ Compressor
  if (opts.compressor) {
    _compress(
      y,
      fs,
      thresholdDb: opts.compThresholdDb,
      ratio: opts.compRatio,
      attackMs: opts.compAttackMs,
      releaseMs: opts.compReleaseMs,
    );
  }

  // ✅ Limiter
  if (opts.limiter) {
    _limit(y, ceilDb: opts.limiterCeilDbfs);
  }

  // Optional peak normalize (usually not needed with limiter)
  if (opts.peakNormalize) {
    _peakNormalize(y, targetPeakDbfs: opts.targetPeakDbfs);
  }

  // float -> int16
  final outS16 = Int16List(M);
  for (int i = 0; i < M; i++) {
    final v = (y[i] * 32768.0).round();
    outS16[i] = v.clamp(-32768, 32767);
  }

  final tmp = outPath ??
      '${(await getTemporaryDirectory()).path}/pre_${DateTime.now().millisecondsSinceEpoch}.wav';

  await writePcm16MonoWav(tmp, sampleRate: fs, samples: outS16);
  return tmp;
}
