// lib/transcript/transcription_persistence.dart
//
// Main-isolate only: writes TranscriptionResult into ObjectBox.

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import 'transcription_models.dart';

Future<int> persistNewTranscriptionFromResult({
  required String wavPath,
  required TranscriptionResult result,
}) async {
  final obx = ObjectBox.I;

  final parent = TranscriptEntity(
    title: result.title ?? '',
    model: result.model,
    lang: result.lang,
    durationSec: result.durationSec,
    audioPath: wavPath,
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
  required String wavPath,
  required TranscriptionResult result,
}) async {
  final obx = ObjectBox.I;
  final t = obx.transcripts.get(transcriptId);
  if (t == null) {
    return persistNewTranscriptionFromResult(
      wavPath: wavPath,
      result: result,
    );
  }

  obx.transcripts.put(
    TranscriptEntity(
      id: t.id,
      title: result.title ?? t.title,
      model: result.model,
      lang: result.lang,
      audioPath: wavPath,
      durationSec: result.durationSec,
      createdAt: t.createdAt,
    ),
  );

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
    obx.turns.putMany(rows);
  }

  return transcriptId;
}
