// lib/transcript/transcription_persistence.dart
//
// Main-isolate only: writes TranscriptionResult into ObjectBox.

import 'dart:io';
import 'package:flutter/foundation.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../objectbox.g.dart';
import 'transcription_models.dart';

Future<int> persistNewTranscriptionFromResult({
  required String wavPath,
  required TranscriptionResult result,
  String? originalWavPath, // ✅ optional if you ever have it
}) async {
  final obx = ObjectBox.I;

  // For "new", treat wavPath as processed input (since BG sends processed).
  final parent = TranscriptEntity(
    title: result.title ?? '',
    model: result.model,
    lang: result.lang,
    durationSec: result.durationSec,
    audioPath: originalWavPath ?? wavPath, // ✅ keep something playable
    processedAudioPath: wavPath, // ✅ store processed explicitly
    createdAt: DateTime.now(),
  );

  final tId = obx.transcripts.put(parent);

  if (result.turns.isNotEmpty) {
    final rows = result.turns
        .map(
          (u) => TranscriptTurnEntity(
            speakerLabel: u.speaker,
            startSec: u.startSec,
            endSec: u.endSec,
            text: u.text,
          )..transcript.targetId = tId,
        )
        .toList();
    obx.turns.putMany(rows);
  }

  return tId;
}

Future<int> persistExistingTranscriptionFromResult({
  required int transcriptId,
  required String wavPath, // ✅ this is the file used for transcription (processed)
  required TranscriptionResult result,
}) async {
  final obx = ObjectBox.I;
  final t = obx.transcripts.get(transcriptId);

  if (t == null) {
    // Fallback: create new transcript, but still store processed path
    return persistNewTranscriptionFromResult(
      wavPath: wavPath,
      result: result,
    );
  }

  // ✅ DEBUG: before
  debugPrint('[PERSIST][BEFORE] id=${t.id}');
  debugPrint('[PERSIST][BEFORE] audioPath=${t.audioPath}');
  debugPrint('[PERSIST][BEFORE] processedAudioPath=${t.processedAudioPath}');
  debugPrint(
    '[PERSIST][BEFORE] audioExists=${t.audioPath != null && File(t.audioPath!).existsSync()}',
  );
  debugPrint(
    '[PERSIST][BEFORE] processedExists=${t.processedAudioPath != null && File(t.processedAudioPath!).existsSync()}',
  );

  // ✅ Update in place — DO NOT recreate TranscriptEntity.
  // Preserve audioPath + processedAudioPath.
  final incomingTitle = (result.title ?? '').trim();
  final existingTitle = (t.title ?? '').trim();

  if (existingTitle.isEmpty && incomingTitle.isNotEmpty) {
    t.title = incomingTitle;
  }

  t.model = result.model;
  t.lang = result.lang;
  t.durationSec = result.durationSec;

  // ✅ If we don't have processedAudioPath yet, fill it from wavPath (only if real)
  if ((t.processedAudioPath == null || t.processedAudioPath!.trim().isEmpty) &&
      wavPath.trim().isNotEmpty &&
      File(wavPath).existsSync()) {
    t.processedAudioPath = wavPath;
  }

  // ✅ If somehow audioPath is missing, keep it playable by falling back
  if ((t.audioPath == null || t.audioPath!.trim().isEmpty) &&
      wavPath.trim().isNotEmpty &&
      File(wavPath).existsSync()) {
    t.audioPath = wavPath;
  }

  obx.transcripts.put(t);

  // ✅ Replace turns: first delete old turns for this transcript,
  // then insert the new ones (prevents duplicates).
  final turnsBox = obx.store.box<TranscriptTurnEntity>();
  final qb = turnsBox
      .query(TranscriptTurnEntity_.transcript.equals(transcriptId))
      .build();
  final oldIds = qb.findIds();
  qb.close();
  if (oldIds.isNotEmpty) turnsBox.removeMany(oldIds);

  if (result.turns.isNotEmpty) {
    final rows = result.turns
        .map(
          (u) => TranscriptTurnEntity(
            speakerLabel: u.speaker,
            startSec: u.startSec,
            endSec: u.endSec,
            text: u.text,
          )..transcript.targetId = transcriptId,
        )
        .toList();
    turnsBox.putMany(rows);
  }

  // ✅ DEBUG: after
  final t2 = obx.transcripts.get(transcriptId);
  debugPrint('[PERSIST][AFTER] id=${t2?.id}');
  debugPrint('[PERSIST][AFTER] audioPath=${t2?.audioPath}');
  debugPrint('[PERSIST][AFTER] processedAudioPath=${t2?.processedAudioPath}');
  if (t2?.audioPath != null) {
    debugPrint(
      '[PERSIST][AFTER] audioExists=${File(t2!.audioPath!).existsSync()}',
    );
  }
  if (t2?.processedAudioPath != null) {
    debugPrint(
      '[PERSIST][AFTER] processedExists=${File(t2!.processedAudioPath!).existsSync()}',
    );
  }

  return transcriptId;
}
