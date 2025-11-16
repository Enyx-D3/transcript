// lib/speaker_memory.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'speaker_embedding.dart';

class SpeakerProfile {
  final String name;
  final List<List<double>> vectors; // multiple prototypes per speaker

  SpeakerProfile({required this.name, required this.vectors});

  Map<String, dynamic> toJson() => {'name': name, 'vectors': vectors};

  static SpeakerProfile fromJson(Map<String, dynamic> j) => SpeakerProfile(
        name: j['name'] as String,
        vectors: (j['vectors'] as List)
            .map((e) => (e as List).map((x) => (x as num).toDouble()).toList())
            .toList(),
      );
}

class SpeakerMemory {
  static const _kKey = 'speaker_profiles_v2';
  static const int _maxVectorsPerSpeaker = 12; // cap to bound size
  static SpeakerMemory? _inst;

  final List<SpeakerProfile> _profiles = [];

  SpeakerMemory._();

  static Future<SpeakerMemory> instance() async {
    if (_inst != null) return _inst!;
    final m = SpeakerMemory._();
    await m._load();
    _inst = m;
    return m;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKey);
    if (raw == null) return;
    final list = (json.decode(raw) as List).cast<Map<String, dynamic>>();
    _profiles
      ..clear()
      ..addAll(list.map(SpeakerProfile.fromJson));
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = json.encode(_profiles.map((p) => p.toJson()).toList());
    await prefs.setString(_kKey, raw);
  }

  List<SpeakerProfile> get profiles => List.unmodifiable(_profiles);

  /// Append a prototype for [name]; create profile if needed; cap to max.
  Future<void> enrollAppend({
    required String name,
    required Float32List embedding, // must be L2-normalized
  }) async {
    final vec = embedding.map((e) => e.toDouble()).toList();
    final idx =
        _profiles.indexWhere((p) => p.name.toLowerCase() == name.toLowerCase());
    if (idx >= 0) {
      final v = List<List<double>>.from(_profiles[idx].vectors);
      v.add(vec);
      if (v.length > _maxVectorsPerSpeaker) {
        v.removeAt(0); // FIFO
      }
      _profiles[idx] = SpeakerProfile(name: _profiles[idx].name, vectors: v);
    } else {
      _profiles.add(SpeakerProfile(name: name, vectors: [vec]));
    }
    await _save();
  }

  /// Identify by best cosine over all prototypes of all speakers.
  /// Returns (name, score) or (null, 0.0) if below threshold or no profiles.
  MapEntry<String?, double> identify(
    Float32List query, {
    double threshold = 0.67,
    double marginToSecond = 0.04, // require a small gap vs #2
  }) {
    String? bestName;
    double best = -1.0;
    double second = -1.0;

    for (final p in _profiles) {
      for (final proto in p.vectors) {
        final s = SpeakerEmbedder.cosine(query, Float32List.fromList(proto));
        if (s > best) {
          second = best;
          best = s;
          bestName = p.name;
        } else if (s > second) {
          second = s;
        }
      }
    }

    if (best >= threshold && (best - second) >= marginToSecond) {
      return MapEntry(bestName, best);
    }
    return const MapEntry(null, 0.0);
  }

  Future<void> remove(String name) async {
    _profiles.removeWhere((p) => p.name.toLowerCase() == name.toLowerCase());
    await _save();
  }

  static Future<String> dataFilePath() async {
  final dir = await getApplicationDocumentsDirectory();
  return '${dir.path}/profiles/speaker_memory.json';
}

Future<String> rawJson() async {
  final p = await SpeakerMemory.dataFilePath();
  final f = File(p);
  if (await f.exists()) return await f.readAsString();
  return '{}';
}
}
