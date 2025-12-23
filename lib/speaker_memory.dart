// lib/speaker_memory.dart (file-based, no ObjectBox)
//
// - One embedding per name (averaged over time).
// - JSON on disk: { "Alex": [0.1, 0.2, ...], ... }
// - Cached in memory per isolate.
// - Safe to call from background isolate (no ObjectBox).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Small helper so call-sites can use `.key` and `.value`
/// similar to MapEntry.
class IdentifyResult {
  final String? key;   // speaker name
  final double value;  // similarity score

  const IdentifyResult(this.key, this.value);
}

class SpeakerMemory {
  SpeakerMemory._();

  static SpeakerMemory? _instance;

  /// Singleton per isolate.
  static Future<SpeakerMemory> instance() async {
    _instance ??= SpeakerMemory._();
    await _instance!._ensureLoaded();
    return _instance!;
  }

  /// name -> embedding
  final Map<String, Float32List> _embeds = {};

  bool _loaded = false;
  File? _file;

  // --------------------------------------------------
  // Load / save
  // --------------------------------------------------

  Future<void> _ensureLoaded() async {
    if (_loaded) return;

    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/speaker_memory.json');

    if (await _file!.exists()) {
      try {
        final txt = await _file!.readAsString();
        if (txt.trim().isNotEmpty) {
          final decoded = jsonDecode(txt) as Map<String, dynamic>;
          decoded.forEach((name, value) {
            final list =
                (value as List).cast<num>().map((e) => e.toDouble()).toList();
            _embeds[name] = Float32List.fromList(list);
          });
        }
      } catch (e, st) {
        debugPrint('SpeakerMemory load failed: $e\n$st');
        _embeds.clear();
      }
    }

    _loaded = true;
  }

  Future<void> _flush() async {
    if (_file == null) return;

    final map = <String, List<double>>{};
    _embeds.forEach((name, emb) {
      map[name] = emb.map((e) => e.toDouble()).toList();
    });

    try {
      await _file!.writeAsString(jsonEncode(map));
    } catch (e, st) {
      debugPrint('SpeakerMemory save failed: $e\n$st');
    }
  }

  // --------------------------------------------------
  // Math helpers
  // --------------------------------------------------

  double _cosine(Float32List a, Float32List b) {
    final n = math.min(a.length, b.length);
    double dot = 0.0, na = 0.0, nb = 0.0;
    for (int i = 0; i < n; i++) {
      final x = a[i];
      final y = b[i];
      dot += x * y;
      na += x * x;
      nb += y * y;
    }
    if (na <= 0 || nb <= 0) return 0.0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  // --------------------------------------------------
  // Public API used by diarization pipeline
  // --------------------------------------------------

  /// Identify the closest known speaker.
  /// Returns IdentifyResult(key: nameOrNull, value: similarityScore).
  IdentifyResult identify(
    Float32List probe, {
    double threshold = 0.67,
  }) {
    String? bestName;
    double bestScore = -1.0;

    _embeds.forEach((name, emb) {
      final s = _cosine(emb, probe);
      if (s > bestScore) {
        bestScore = s;
        bestName = name;
      }
    });

    if (bestScore >= threshold && bestName != null) {
      return IdentifyResult(bestName, bestScore);
    }
    return const IdentifyResult(null, 0.0);
  }

  /// Enroll or update a speaker by averaging embeddings.
  Future<void> enrollAppend({
    required String name,
    required Float32List embedding,
  }) async {
    final existing = _embeds[name];
    if (existing == null) {
      _embeds[name] = embedding;
    } else {
      final n = math.min(existing.length, embedding.length);
      final out = Float32List(n);
      for (int i = 0; i < n; i++) {
        out[i] = (existing[i] + embedding[i]) * 0.5;
      }
      _embeds[name] = out;
    }
    await _flush();
  }

  // --------------------------------------------------
  // Helpers (debug / management)
  // --------------------------------------------------

  /// Snapshot of all stored speakers.
  Map<String, Float32List> dumpAll() => Map.unmodifiable(_embeds);

  /// Remove a single speaker by exact name.
  Future<void> remove(String name) async {
    _embeds.remove(name);
    await _flush();
  }

  /// Nicer alias, in case you prefer this in your UI.
  Future<void> removeSpeaker(String name) => remove(name);

  /// Clear all stored speakers and wipe the JSON.
  Future<void> clearAll() async {
    _embeds.clear();
    await _flush();
  }
}
