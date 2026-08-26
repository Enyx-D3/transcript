// lib/speaker_memory.dart (file-based, multi-prototype, no ObjectBox)
//
// - Multiple embeddings per name (prototypes).
// - JSON on disk:
//    {
//      "Alex": [[0.1, 0.2, ...], [0.11, 0.19, ...], ...],
//      "Sam":  [[...]]
//    }
// - Backward compatible with old format: { "Alex": [0.1, 0.2, ...] }

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class IdentifyResult {
  final String? key; // speaker name
  final double value; // similarity score
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

  /// name -> list of embeddings (prototypes)
  final Map<String, List<Float32List>> _embeds = {};

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
            // Backward compatible:
            // old:  "Alex": [0.1, 0.2, ...]
            // new:  "Alex": [[...], [...], ...]
            if (value is List && value.isNotEmpty && value.first is num) {
              final vec = value.cast<num>().map((e) => e.toDouble()).toList();
              _embeds[name] = [Float32List.fromList(vec)];
              return;
            }

            if (value is List) {
              final protos = <Float32List>[];
              for (final item in value) {
                if (item is List) {
                  final vec = item
                      .cast<num>()
                      .map((e) => e.toDouble())
                      .toList();
                  if (vec.isNotEmpty) protos.add(Float32List.fromList(vec));
                }
              }
              if (protos.isNotEmpty) _embeds[name] = protos;
            }
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

    final map = <String, List<List<double>>>{};
    _embeds.forEach((name, protos) {
      map[name] = protos
          .map((emb) => emb.map((e) => e.toDouble()).toList())
          .toList();
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

  /// Identify the closest known speaker using best prototype match.
  IdentifyResult identify(Float32List probe, {double threshold = 0.67}) {
    String? bestName;
    double bestScore = -1.0;

    _embeds.forEach((name, protos) {
      for (final emb in protos) {
        final s = _cosine(emb, probe);
        if (s > bestScore) {
          bestScore = s;
          bestName = name;
        }
      }
    });

    if (bestScore >= threshold && bestName != null) {
      return IdentifyResult(bestName, bestScore);
    }
    return const IdentifyResult(null, 0.0);
  }

  /// Append an embedding prototype (multi-prototype enrollment).
  ///
  /// `maxPrototypes` is how many embeddings to keep per speaker (5 for your flow).
  Future<void> enrollAppend({
    required String name,
    required Float32List embedding,
    int maxPrototypes = 5,
  }) async {
    if (embedding.isEmpty) return;

    final list = _embeds[name] ?? <Float32List>[];

    // copy defensively
    list.add(Float32List.fromList(embedding));

    // Keep last N
    if (maxPrototypes > 0 && list.length > maxPrototypes) {
      list.removeRange(0, list.length - maxPrototypes);
    }

    _embeds[name] = list;
    await _flush();
  }

  // --------------------------------------------------
  // Helpers (debug / management)
  // --------------------------------------------------

  /// Snapshot of all stored speakers (and their prototypes).
  Map<String, List<Float32List>> dumpAll() => Map.unmodifiable(_embeds);

  /// How many prototypes stored for a name.
  int countPrototypes(String name) => _embeds[name]?.length ?? 0;

  /// Remove a single speaker by exact name.
  Future<void> remove(String name) async {
    _embeds.remove(name);
    await _flush();
  }

  Future<void> removeSpeaker(String name) => remove(name);

  /// Clear all stored speakers and wipe the JSON.
  Future<void> clearAll() async {
    _embeds.clear();
    await _flush();
  }
}
