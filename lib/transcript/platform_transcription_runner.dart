import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../objectbox/objectbox_store.dart';
import '../send_transcript/auto_email_service.dart';
import '../send_transcript/send_transcript_healper.dart';
import 'audio_cleanup.dart';
import 'transcript_block_repository.dart';
import 'transcription_compute.dart';
import 'transcription_models.dart';
import 'transcription_persistence.dart';

class PlatformTranscriptionRunner {
  PlatformTranscriptionRunner._();

  static const String _kBusyTranscribing = 'busy_transcribing';
  static const String _kActiveTranscriptId = 'bg_active_transcript_id';

  static const TranscriptMailService _mailer = TranscriptMailService(
    baseUrl: 'https://enyx.app',
  );

  static bool get usesForegroundRunner => Platform.isIOS;

  static Future<void> runForegroundExistingTranscript({
    required int transcriptId,
    required int jobId,
    required String wavPath,
    required String lang,
    int? targetSpeakers,
    String? titleHint,
  }) async {
    await FlutterForegroundTask.saveData(key: _kBusyTranscribing, value: true);
    await FlutterForegroundTask.saveData(
      key: _kActiveTranscriptId,
      value: transcriptId,
    );

    _markJobStatus(jobId, 'RUNNING');

    try {
      await TranscriptBlockRepository.instance.clear(transcriptId);

      final result = await transcribeToResult(
        wavPath: wavPath,
        titleHint: titleHint,
        lang: lang,
        targetSpeakers: targetSpeakers,
        onBlockUpdated: (block) async {
          await TranscriptBlockRepository.instance.upsert(
            transcriptId,
            block.copyWith(meetingId: transcriptId.toString()),
          );
        },
      );

      await persistExistingTranscriptionFromResult(
        transcriptId: transcriptId,
        wavPath: wavPath,
        result: result,
      );

      await _normalizeImportAudioPaths(transcriptId, wavPath);
      await _saveBlocks(transcriptId, result.blocks);
      await AutoEmailService.sendIfEnabled(
        transcriptId: transcriptId,
        mailer: _mailer,
      );
      await deleteTranscriptAudioIfUserEnabled(transcriptId);

      _markJobStatus(jobId, 'DONE');
    } catch (e, st) {
      debugPrint('[IOS-TRANSCRIBE] failed: $e');
      debugPrint('$st');
      _markJobStatus(jobId, 'ERROR', error: e.toString());
      rethrow;
    } finally {
      await FlutterForegroundTask.saveData(
        key: _kBusyTranscribing,
        value: false,
      );
      await FlutterForegroundTask.saveData(key: _kActiveTranscriptId, value: 0);
    }
  }

  static void _markJobStatus(int jobId, String status, {String? error}) {
    final obx = ObjectBox.I;
    final job = obx.jobs.get(jobId);
    if (job == null) return;
    job.status = status;
    job.error = error;
    obx.jobs.put(job);
  }

  static Future<void> _saveBlocks(
    int transcriptId,
    List<TranscriptBlockSnapshot> blocks,
  ) async {
    if (blocks.isEmpty) return;
    final normalized = blocks
        .map((b) => b.copyWith(meetingId: transcriptId.toString()))
        .toList();
    await TranscriptBlockRepository.instance.save(transcriptId, normalized);
  }

  static Future<void> _normalizeImportAudioPaths(
    int transcriptId,
    String wavPath,
  ) async {
    final obx = ObjectBox.I;
    final t = obx.transcripts.get(transcriptId);
    if (t == null) return;

    final st = t.sourceType;
    if (st != 2 && st != 3) return;

    final a = (t.audioPath ?? '').trim();
    if (a == wavPath.trim() && (t.processedAudioPath ?? '').trim().isEmpty) {
      return;
    }

    t.audioPath = wavPath.trim().isEmpty
        ? (a.isEmpty ? null : a)
        : wavPath.trim();
    t.processedAudioPath = null;
    t.updatedAt = DateTime.now();
    obx.transcripts.put(t);
  }
}
