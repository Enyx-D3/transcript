// lib/transcript/isolated_speaker_matcher.dart
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Simple speaker matcher for use in isolates
class IsolatedSpeakerMatcher {
  /// Match a speaker feature vector with enrolled speakers
  static String? matchSpeaker(
    Float32List probe,
    Map<String, List<Float32List>> enrolledSpeakers,
    double threshold,
  ) {
    String? bestMatch;
    double bestScore = -1.0;

    enrolledSpeakers.forEach((name, embeddings) {
      for (final emb in embeddings) {
        final score = cosine(probe, emb);
        if (score > bestScore) {
          bestScore = score;
          bestMatch = name;
        }
      }
    });

    if (bestScore >= threshold && bestMatch != null) {
      return bestMatch;
    }
    return null;
  }

  /// Match multiple speakers and return mapping
  static Map<String, String> matchSpeakers(
    Map<String, List<Float32List>> speakerFeatures,
    Map<String, List<Float32List>> enrolledSpeakers,
    double threshold,
  ) {
    final matches = <String, String>{};
    
    if (enrolledSpeakers.isEmpty) return matches;
    
    for (final entry in speakerFeatures.entries) {
      final speakerLabel = entry.key;
      final features = entry.value;
      
      if (features.isEmpty) continue;
      
      // Compute centroid
      final centroid = _computeCentroid(features);
      
      // Find best match
      final matchedName = matchSpeaker(centroid, enrolledSpeakers, threshold);
      if (matchedName != null) {
        matches[speakerLabel] = matchedName;
      }
    }
    
    return matches;
  }

  /// Compute centroid of feature vectors
  static Float32List _computeCentroid(List<Float32List> vectors) {
    if (vectors.isEmpty) return Float32List(0);
    
    final length = vectors.first.length;
    final sum = Float32List(length);
    
    for (final vec in vectors) {
      for (int i = 0; i < vec.length; i++) {
        sum[i] += vec[i];
      }
    }
    
    final avg = Float32List(length);
    for (int i = 0; i < length; i++) {
      avg[i] = sum[i] / vectors.length;
    }
    
    return _normalize(avg);
  }

  /// Cosine similarity
static double cosine(Float32List a, Float32List b) {
  if (a.isEmpty || b.isEmpty) return 0;
  if (a.length != b.length) return 0; // prevent silent mismatch

  final n = a.length;
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

  /// Normalize vector
  static Float32List _normalize(Float32List vec) {
    double norm = 0;
    for (final val in vec) {
      norm += val * val;
    }
    norm = math.sqrt(math.max(norm, 1e-12));
    
    final normalized = Float32List(vec.length);
    for (int i = 0; i < vec.length; i++) {
      normalized[i] = vec[i] / norm;
    }
    
    return normalized;
  }

  /// Compute simple audio features (no ONNX dependency)
  static Float32List computeSimpleFeatures(
    Float32List samples, 
    int start, 
    int end, 
    int sampleRate,
  ) {
    const numFeatures = 20;
    final features = Float32List(numFeatures);
    
    if (end <= start) return features;
    
    final window = end - start;
    
    // 1. Energy/RMS (feature 0-2)
    double sum = 0, sumAbs = 0, maxVal = 0;
    for (int i = start; i < end && i < samples.length; i++) {
      final val = samples[i];
      sum += val * val;
      sumAbs += val.abs();
      if (val.abs() > maxVal) maxVal = val.abs();
    }
    
    features[0] = math.log(1 + sum / window).toDouble(); // Log energy
    features[1] = math.sqrt(sum / window); // RMS
    features[2] = sumAbs / window; // Average amplitude
    
    // 2. Zero-crossing rate (feature 3)
    int zeroCrossings = 0;
    for (int i = start + 1; i < end && i < samples.length; i++) {
      if (samples[i] * samples[i - 1] < 0) {
        zeroCrossings++;
      }
    }
    features[3] = zeroCrossings / window.toDouble();
    
    // 3. Spectral features approximation (features 4-13)
    // Simple band energies (crude FFT approximation)
    const numBands = 10;
    for (int band = 0; band < numBands; band++) {
      double bandEnergy = 0;
      final bandSize = window ~/ numBands;
      final bandStart = start + band * bandSize;
      final bandEnd = (band == numBands - 1) ? end : bandStart + bandSize;
      
      // Simple spectral approximation using sine/cosine basis
      final freq = (band + 1) * sampleRate / (2 * window);
      for (int i = bandStart; i < bandEnd && i < samples.length; i++) {
        final t = (i - start) / sampleRate.toDouble();
        final basis = math.sin(2 * math.pi * freq * t);
        bandEnergy += samples[i].abs() * basis.abs();
      }
      
      features[4 + band] = bandEnergy / (bandEnd - bandStart);
    }
    
    // 4. Temporal features (features 14-19)
    // Auto-correlation at different lags
    const maxLag = 6;
    for (int lag = 1; lag <= maxLag; lag++) {
      double autocorr = 0;
      int count = 0;
      for (int i = start; i < end - lag && i < samples.length - lag; i++) {
        autocorr += samples[i] * samples[i + lag];
        count++;
      }
      features[13 + lag] = count > 0 ? autocorr / count : 0;
    }
    
    return _normalize(features);
  }
}