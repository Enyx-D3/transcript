// lib/transcript/transcription_compute.dart
//
// Pure compute pipeline used in the background isolate.
// No ObjectBox here.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../audio_preprocess.dart';
import '../audio_utils.dart';
import '../diarizer_service.dart';
import '../speaker_embedding.dart';
import '../speaker_memory.dart';
import '../model_bootstrap.dart';
import '../whisper_service.dart';

import 'transcription_models.dart';

// ---------------- Internal merged turn structure ----------------

class _Turn {
  final String spk; // diarizer speaker id (S1, S2, or known name)
  final double a;   // startSec
  final double b;   // endSec
  _Turn(this.spk, this.a, this.b);
}

/// Merge consecutive segments for the same speaker if the gap between them
/// is <= [maxGap] seconds.
///
/// NOTE: diarizer_service already merges S1/S2 with its own gap.
/// This is just an extra safety net for tiny splits.
List<_Turn> _mergeGapAware(List<SpeakerTurn> segs, {double maxGap = 0.4}) {
  if (segs.isEmpty) return const [];
  final s = [...segs]..sort((a, b) => a.startSec.compareTo(b.startSec));
  final out = <_Turn>[];

  var cur = _Turn(s.first.speaker, s.first.startSec, s.first.endSec);
  for (int i = 1; i < s.length; i++) {
    final n = s[i];
    if (n.speaker == cur.spk && (n.startSec - cur.b) <= maxGap) {
      // same speaker, small gap -> extend
      cur = _Turn(cur.spk, cur.a, n.endSec);
    } else {
      // different speaker or large gap -> close current, start new
      out.add(cur);
      cur = _Turn(n.speaker, n.startSec, n.endSec);
    }
  }
  out.add(cur);

  return out;
}

// ---------------- Speaker memory mapping (no fallback here) ----------------

/// Returns ONLY recognized names: diarizerSpeakerId -> "alex".
/// If a speaker is unknown, it does NOT add an entry for them.
///
/// We operate on merged _Turn spans (less segments, same speakers).
Future<Map<String, String>> _memoryNameMapFromMerged(
  String wavPath,
  List<_Turn> turns, {
  double perSpeakerBudgetSec = 10,
  double windowSec = 2,
  double threshold = 0.67,
}) async {
  final mem = await SpeakerMemory.instance();
  final mp = await ensureDiarizationModels();
  final emb = await SpeakerEmbedder.instance(mp.embOnnx);

  // Group merged spans by diarizer speaker id (S1/S2/...)
  final byId = <String, List<_Turn>>{};
  for (final t in turns) (byId[t.spk] ??= []).add(t);

  final ids = byId.keys.toList()..sort();
  final map = <String, String>{};

  for (final spkId in ids) {
    final spans = byId[spkId]!..sort((a, b) => a.a.compareTo(b.a));

    double budget = perSpeakerBudgetSec;
    final parts = <Float32List>[];

    for (final s in spans) {
      if (budget <= 0) break;
      final segDur = s.b - s.a;
      final nWins = (segDur / windowSec).ceil().clamp(1, 4);
      for (int k = 0; k < nWins && budget > 0; k++) {
        final st = s.a + k * windowSec;
        if (st >= s.b) break;
        final en = (st + windowSec) > s.b ? s.b : (st + windowSec);
        final take = (en - st).clamp(0.5, budget);
        if (take <= 0) break;

        final v = await emb.embedFromWav(
          wavPath,
          startSec: st,
          endSec: st + take,
        );
        if (v.isNotEmpty) parts.add(v);

        budget -= take;
        if (budget <= 0) break;
      }
    }

    if (parts.isEmpty) {
      // Unknown → no entry; fallback handled later.
      continue;
    }

    final centroid = emb.meanPool(parts);
    final best = mem.identify(centroid, threshold: threshold);

    if (best.key != null) {
      map[spkId] = best.key!;
      if (best.value >= threshold + 0.08) {
        await mem.enrollAppend(name: best.key!, embedding: centroid);
      }
    }
  }

  return map;
}

// Local services for this isolate (not the globals from main.dart)
final _whisper = WhisperService();
final _diarizer = DiarizerService();

// ---------------- Core compute-only pipeline ----------------

Future<TranscriptionResult> transcribeToResult({
  required String wavPath,
  bool translateToEnglish = false,
  String? titleHint,
}) async {
  // 0) Preprocess
  final cleaned = await preprocessWav16kMono(wavPath);
  final duration = await readWavDuration(cleaned);

  final modelName = _whisper.currentModel?.name ?? 'whisper';
  final lang = translateToEnglish ? 'en' : 'auto';

  // 1) Diarize (BG isolate only)
  if (!_diarizer.isReady) {
    debugPrint('[BG-PIPELINE] diarizer not ready, calling init()');
    await _diarizer.init(
      expectedNumSpeakers: 0, // 0 = auto; set 2/3 if you know typical count
      threshold: 0.55,
    );
  }

  final diarized = _diarizer.isReady
      ? await _diarizer.diarizeFile(
          cleaned,
          minSegDur: 0.30,
          gapMergeSec: 1.0, // match diarizer_service gap
        )
      : const <SpeakerTurn>[];

  // DEBUG: log diarizer results
  debugPrint('--- DIARIZER DEBUG (BG) ---');
  debugPrint('isReady: ${_diarizer.isReady}');
  debugPrint('segments: ${diarized.length}');
  final uniqueSpeakers = diarized.map((s) => s.speaker).toSet().toList()
    ..sort();
  debugPrint('unique speakers: $uniqueSpeakers');
  for (final s in diarized) {
    debugPrint(
      'seg speaker=${s.speaker} '
      'start=${s.startSec.toStringAsFixed(2)} '
      'end=${s.endSec.toStringAsFixed(2)}',
    );
  }
  debugPrint('--- END DIARIZER DEBUG (BG) ---');

  // 2) Merge tiny gaps again (just in case)
  final merged = _mergeGapAware(diarized, maxGap: 0.4);

  // 3) Fallback: no diarization => single s1
  if (merged.isEmpty) {
    final text = await _whisper.transcribeWav(
      wavPath: cleaned,
      translateToEnglish: translateToEnglish,
      diarize: false,
      noTimestamps: false,
      splitOnWord: true,
    );
    final baseTitle = text.trim();
    final title = (titleHint != null && titleHint.trim().isNotEmpty)
        ? titleHint.trim()
        : (baseTitle.isEmpty
            ? null
            : (baseTitle.length > 48
                ? '${baseTitle.substring(0, 48)}…'
                : baseTitle));

    return TranscriptionResult(
      model: modelName,
      lang: lang,
      durationSec: duration,
      title: title,
      turns: [LiteTurn('s1', 0.0, duration, text.trim())],
    );
  }

  // 4) Count speakers (S1, S2, ...)
  final speakerIds = merged.map((t) => t.spk).toSet().toList()..sort();

  // 5) Match with speaker memory -> subset mapping: S1 -> alex, etc.
  final memoryNames = await _memoryNameMapFromMerged(cleaned, merged);

  // 6) Build label map:
  final knownIds = <String>[];
  final unknownIds = <String>[];
  for (final id in speakerIds) {
    if (memoryNames.containsKey(id)) {
      knownIds.add(id);
    } else {
      unknownIds.add(id);
    }
  }

  final labelMap = <String, String>{};

  // known -> memory name
  for (final id in knownIds) {
    labelMap[id] = memoryNames[id]!;
  }

  // unknown -> s1, s2, s3...
  for (int i = 0; i < unknownIds.length; i++) {
    final id = unknownIds[i];
    labelMap[id] = 's${i + 1}';
  }

   // 7) TRANSCRIBE per merged block using labelMap
  final tmp = await getTemporaryDirectory();
  final out = <LiteTurn>[];

  for (int i = 0; i < merged.length; i++) {
    final m = merged[i];
    final slice = '${tmp.path}/slice_$i.wav';

    await trimWav16kMonoPcm(
      inputPath: cleaned,
      startSec: m.a,
      endSec: m.b,
      outputPath: slice,
    );

    final text = await _whisper.transcribeWav(
      wavPath: slice,
      translateToEnglish: translateToEnglish,
      diarize: false,
      noTimestamps: false,
      splitOnWord: true,
    );

    final label = labelMap[m.spk] ?? 's1';

    out.add(
      LiteTurn(
        label,
        m.a,
        m.b,
        text.trim(),
      ),
    );

    try {
      File(slice).deleteSync();
    } catch (_) {}
  }

  // 8) Drop empty-text turns entirely (e.g. "S2" with no words)
  final nonEmpty = out.where((t) => t.text.trim().isNotEmpty).toList();

  if (nonEmpty.isEmpty) {
    // If everything ended up empty, just return a transcript with no turns.
    final title = (titleHint != null && titleHint.trim().isNotEmpty)
        ? titleHint.trim()
        : null;

    return TranscriptionResult(
      model: modelName,
      lang: lang,
      durationSec: duration,
      title: title,
      turns: const [],
    );
  }

  // 9) Re-merge consecutive turns with the same speaker after
  // removing empties. This fixes: S1 text, S2 (empty), S1 text -> single S1.
  final mergedTurns = <LiteTurn>[];
  LiteTurn? current;

  for (final t in nonEmpty) {
    if (current == null) {
      current = t;
      continue;
    }

    final sameSpeaker = t.speaker == current.speaker;
    final gap = t.startSec - current.endSec; // can be slightly negative due to rounding

    if (sameSpeaker && gap >= -0.05 && gap <= 0.5) {
      // Merge into current: extend end time, concatenate text
      current = LiteTurn(
        current.speaker,
        current.startSec,
        t.endSec,
        '${current.text} ${t.text}'.trim(),
      );
    } else {
      mergedTurns.add(current);
      current = t;
    }
  }
  if (current != null) mergedTurns.add(current);

  final firstText = mergedTurns.isNotEmpty ? mergedTurns.first.text.trim() : '';
  final title = (titleHint != null && titleHint.trim().isNotEmpty)
      ? titleHint.trim()
      : (firstText.isEmpty
          ? null
          : (firstText.length > 48
              ? '${firstText.substring(0, 48)}…'
              : firstText));

  return TranscriptionResult(
    model: modelName,
    lang: lang,
    durationSec: duration,
    title: title,
    turns: mergedTurns,
  );
}
