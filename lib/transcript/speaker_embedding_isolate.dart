// lib/speaker_embedding_isolate.dart
import 'dart:math' as math;
import 'dart:typed_data';

/// Simple speaker embedder for use in isolates - no sherpa-onnx dependencies
class IsolateSpeakerEmbedder {
  final String _embOnnxPath;
  
  IsolateSpeakerEmbedder(this._embOnnxPath);
  
  /// Compute embedding from samples (stub implementation)
  /// In a real implementation, you'd need to load the ONNX model differently
  Future<Float32List> embedFromSamplesRange({
    required Float32List samples,
    required int sampleRate,
    required int startIndex,
    required int endIndex,
  }) async {
    // For now, return a dummy embedding
    // In production, you'd need to implement actual embedding computation
    // without using sherpa-onnx's platform channels
    return Float32List(192); // Typical embedding size
  }
  
  /// Cosine similarity helper
  static double cosine(Float32List a, Float32List b) {
    final n = math.min(a.length, b.length);
    if (n == 0) return 0;
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
}