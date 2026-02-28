// lib/audio_preprocess.dart
import 'dart:io';
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
  for (final v in x) {
    s += v * v;
  }
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
/// Uses running-sum RMS to avoid allocating large temporary arrays.
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
  final halfW = w ~/ 2;
  final minRun = (minRunMs * fs / 1000).clamp(1, x.length).toInt();

  // Sliding-window running sum – O(N) time, O(1) extra space
  double runSum = 0;
  int wA = 0, wB = 0;

  int runStart = -1;
  for (int i = 0; i < x.length; i++) {
    final desiredA = math.max(0, i - halfW);
    final desiredB = math.min(x.length, desiredA + w);
    while (wB < desiredB) {
      runSum += x[wB] * x[wB];
      wB++;
    }
    while (wA < desiredA) {
      runSum -= x[wA] * x[wA];
      wA++;
    }
    final len = (wB - wA).clamp(1, 1 << 30);
    final rms = math.sqrt(runSum / len);
    final silent = rms < thr;

    if (silent) {
      if (runStart < 0) runStart = i;
    } else {
      if (runStart >= 0) {
        final runLen = i - runStart;
        if (runLen >= minRun) {
          for (int k = runStart; k < i; k++) {
            x[k] *= atten;
          }
        }
        runStart = -1;
      }
    }
  }

  // tail run
  if (runStart >= 0) {
    final runLen = x.length - runStart;
    if (runLen >= minRun) {
      for (int k = runStart; k < x.length; k++) {
        x[k] *= atten;
      }
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
  final N = info.dataLength ~/ 2; // PCM16 mono: 2 bytes per sample
  if (N == 0) return inputPath;

  // ── Read PCM16 directly into Float32 (skip Int16List) ──
  // Saves ~57 MB for 30-min audio by avoiding an intermediate array.
  final x = Float32List(N);
  final raf = File(inputPath).openSync(mode: FileMode.read);
  try {
    raf.setPositionSync(info.dataOffset);
    const chunkSamples = 512 * 1024; // ~1 MB read buffer
    int offset = 0;
    int remaining = N;
    while (remaining > 0) {
      final toRead = remaining < chunkSamples ? remaining : chunkSamples;
      final bytes = raf.readSync(toRead * 2);
      final bd = ByteData.view(bytes.buffer);
      for (int i = 0; i < toRead; i++) {
        x[offset++] =
            (bd.getInt16(i * 2, Endian.little) / 32768.0).clamp(-1.0, 1.0);
      }
      remaining -= toRead;
    }
  } finally {
    raf.closeSync();
  }

  // DC removal
  if (opts.removeDc) {
    double mean = 0;
    for (final v in x) {
      mean += v;
    }
    mean /= N;
    for (int i = 0; i < N; i++) {
      x[i] -= mean;
    }
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

  // ---- Trim head/tail silence (running-sum RMS – no extra arrays) ----
  // Eliminates two Float32List(N) arrays (~230 MB for 30-min audio).
  int start = 0;
  int end = N;

  if (opts.trimSilence) {
    final w = (opts.rmsWindowMs * fs / 1000).clamp(8, 4096).toInt();
    final halfW = w ~/ 2;
    final thr = _dbToAmp(opts.trimBelowDb);
    final run = (opts.trimMinRunMs * fs / 1000).clamp(1, N).toInt();

    // head – forward scan with sliding window running sum
    {
      double runSum = 0;
      int wA = 0, wB = 0;
      int consec = 0;
      for (int i = 0; i < N; i++) {
        final desiredA = math.max(0, i - halfW);
        final desiredB = math.min(N, desiredA + w);
        while (wB < desiredB) {
          runSum += x[wB] * x[wB];
          wB++;
        }
        while (wA < desiredA) {
          runSum -= x[wA] * x[wA];
          wA++;
        }
        final len = (wB - wA).clamp(1, 1 << 30);
        final rms = math.sqrt(runSum / len);
        if (rms >= thr) {
          consec++;
          if (consec >= run) {
            start = math.max(0, i - run);
            break;
          }
        } else {
          consec = 0;
        }
      }
    }

    // tail – reverse scan with sliding window running sum
    {
      double runSum = 0;
      int wA = N, wB = N;
      int consec = 0;
      for (int i = N - 1; i >= 0; i--) {
        final desiredB = math.min(N, i + halfW + 1);
        final desiredA = math.max(0, desiredB - w);
        while (wA > desiredA) {
          wA--;
          runSum += x[wA] * x[wA];
        }
        while (wB > desiredB) {
          wB--;
          runSum -= x[wB] * x[wB];
        }
        final len = (wB - wA).clamp(1, 1 << 30);
        final rms = math.sqrt(runSum / len);
        if (rms >= thr) {
          consec++;
          if (consec >= run) {
            end = math.min(N, i + run);
            break;
          }
        } else {
          consec = 0;
        }
      }
    }

    if (end <= start) {
      start = 0;
      end = N;
    }

    // add padding after trim to preserve context
    final pad = (opts.trimPadMs * fs / 1000).toInt();
    start = math.max(0, start - pad);
    end = math.min(N, end + pad);
  }

  final M = (end - start).clamp(0, N);
  if (M <= 0) return inputPath;

  // ── Use a view into x instead of copying to a new array ──
  // Saves ~115 MB for 30-min audio.
  final y = Float32List.view(x.buffer, start * Float32List.bytesPerElement, M);

  // Speech RMS normalize
  if (opts.rmsNormalize) {
    _rmsNormalize(
      y,
      targetDb: opts.targetRmsDbfs,
      minGainDb: opts.rmsMinGainDb,
      maxGainDb: opts.rmsMaxGainDb,
    );
  }

  // Compressor
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

  // Limiter
  if (opts.limiter) {
    _limit(y, ceilDb: opts.limiterCeilDbfs);
  }

  // Optional peak normalize (usually not needed with limiter)
  if (opts.peakNormalize) {
    _peakNormalize(y, targetPeakDbfs: opts.targetPeakDbfs);
  }

  // ── Write output in chunks to avoid a second large allocation ──
  final tmp = outPath ??
      '${(await getTemporaryDirectory()).path}/pre_${DateTime.now().millisecondsSinceEpoch}.wav';

  await _writePcm16MonoWavChunked(tmp, sampleRate: fs, floatSamples: y);
  return tmp;
}

/// Write a PCM16 mono WAV converting Float32 → Int16 in small chunks
/// to avoid allocating a full-length Int16List (~57 MB for 30-min audio).
Future<void> _writePcm16MonoWavChunked(
  String path, {
  required int sampleRate,
  required Float32List floatSamples,
}) async {
  const channels = 1;
  const bitsPerSample = 16;
  final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
  final blockAlign = channels * (bitsPerSample ~/ 8);
  final dataChunkSize = floatSamples.length * 2; // 16-bit samples
  final riffChunkSize = 4 + (8 + 16) + (8 + dataChunkSize);

  final raf = File(path).openSync(mode: FileMode.write);
  try {
    // RIFF header
    void putStr(String s) => raf.writeStringSync(s);
    void putU32(int v) {
      final bd = ByteData(4)..setUint32(0, v, Endian.little);
      raf.writeFromSync(bd.buffer.asUint8List());
    }
    void putU16(int v) {
      final bd = ByteData(2)..setUint16(0, v, Endian.little);
      raf.writeFromSync(bd.buffer.asUint8List());
    }

    putStr('RIFF');
    putU32(riffChunkSize);
    putStr('WAVE');
    putStr('fmt ');
    putU32(16); // fmtChunkSize
    putU16(1); // PCM
    putU16(channels);
    putU32(sampleRate);
    putU32(byteRate);
    putU16(blockAlign);
    putU16(bitsPerSample);
    putStr('data');
    putU32(dataChunkSize);

    // Write samples in ~64 K-sample chunks (~128 KB each)
    const chunkSize = 65536;
    for (int i = 0; i < floatSamples.length; i += chunkSize) {
      final n = math.min(chunkSize, floatSamples.length - i);
      final buf = Int16List(n);
      for (int j = 0; j < n; j++) {
        buf[j] = (floatSamples[i + j] * 32768.0).round().clamp(-32768, 32767);
      }
      raf.writeFromSync(Uint8List.view(buf.buffer));
    }
  } finally {
    raf.closeSync();
  }
}
