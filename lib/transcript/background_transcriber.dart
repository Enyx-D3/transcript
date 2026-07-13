// lib/transcript/background_transcriber.dart
import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'transcription_models.dart';
import 'transcription_compute.dart' show transcribeToResult;
import 'transcript_block_repository.dart';

@pragma('vm:entry-point')
void transcribeStartCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(_TranscribeTaskHandler());
}

class BackgroundTranscriber {
  static const _serviceId = 741;

  static const _kWavPath = 'bg_wav_path';
  static const _kTranslate = 'bg_translate';
  static const _kTitleHint = 'bg_title_hint';
  static const _kExistingId = 'bg_existing_id';
  static const _kResultId = 'bg_result_id';
  static const _kBusyTranscribing = 'busy_transcribing';

  // ✅ IMPORTANT: which transcript is currently being processed (0 == none)
  static const _kActiveTranscriptId = 'bg_active_transcript_id';

  // ✅ target speakers stored int where 0 == null/auto
  static const _kTargetSpeakers = 'bg_target_speakers';

  // ✅ language (always stored as non-null String; default 'auto')
  static const _kLang = 'bg_lang';

  static const _kProgressProcessedSec = 'progress_processed_sec';
  static const _kProgressTotalSec = 'progress_total_sec';
  static const _kProgressStage = 'progress_stage';

  // ✅ typo fix toggle passed into task isolate (STORE AS INT: 1/0)
  static const _kTypoFixEnabled = 'bg_typo_fix_enabled_int';

  // ✅ SharedPreferences key (must match SettingsPage)
  static const _kPrefTypoFixEnabled = 'pref_typo_fix_enabled';

  static Future<void> init() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'transcribe_channel',
        channelName: 'Transcription',
        channelDescription: 'Background transcription service',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.once(),
        allowWakeLock: true,
        allowWifiLock: false,
        autoRunOnBoot: false,
      ),
    );

    FlutterForegroundTask.initCommunicationPort();
  }

  /// ✅ Use this everywhere.
  /// Reads latest settings RIGHT NOW, so toggle changes apply to the next start.
  static Future<void> startFromPrefs({
    required String wavPath,
    bool translateToEnglish = false,
    String? titleHint,
    int? existingTranscriptId,
    int? targetSpeakers,
    String lang = 'auto',
  }) async {
    final sp = await SharedPreferences.getInstance();
    final typoFix = sp.getBool(_kPrefTypoFixEnabled) ?? false;

    await start(
      wavPath: wavPath,
      translateToEnglish: translateToEnglish,
      titleHint: titleHint,
      existingTranscriptId: existingTranscriptId,
      targetSpeakers: targetSpeakers,
      lang: lang,
      typoFixEnabled: typoFix,
    );
  }

  /// ✅ Deterministic start (no prefs read here).
  static Future<void> start({
    required String wavPath,
    bool translateToEnglish = false,
    String? titleHint,
    int? existingTranscriptId,
    int? targetSpeakers,
    String lang = 'auto',

    // ✅ MUST be passed (call startFromPrefs from UI)
    required bool typoFixEnabled,
  }) async {
    await FlutterForegroundTask.saveData(key: _kWavPath, value: wavPath);
    await FlutterForegroundTask.saveData(
      key: _kTranslate,
      value: translateToEnglish,
    );
    await FlutterForegroundTask.saveData(key: _kBusyTranscribing, value: true);

    // ✅ mark which transcript is active (0 if unknown)
    await FlutterForegroundTask.saveData(
      key: _kActiveTranscriptId,
      value: existingTranscriptId ?? 0,
    );

    await FlutterForegroundTask.saveData(
      key: _kProgressProcessedSec,
      value: 0.0,
    );
    await FlutterForegroundTask.saveData(key: _kProgressTotalSec, value: 0.0);
    await FlutterForegroundTask.saveData(
      key: _kProgressStage,
      value: 'Preparing',
    );

    // ✅ store int (0 means null/auto)
    await FlutterForegroundTask.saveData(
      key: _kTargetSpeakers,
      value: targetSpeakers ?? 0,
    );

    // ✅ store language (must be non-null Object)
    await FlutterForegroundTask.saveData(
      key: _kLang,
      value: (lang.trim().isEmpty) ? 'auto' : lang.trim(),
    );

    // ✅ IMPORTANT: store typo-fix as INT (1/0) to avoid bool deserialization issues
    await FlutterForegroundTask.saveData(
      key: _kTypoFixEnabled,
      value: typoFixEnabled ? 1 : 0,
    );

    if (titleHint != null) {
      await FlutterForegroundTask.saveData(key: _kTitleHint, value: titleHint);
    }
    if (existingTranscriptId != null) {
      await FlutterForegroundTask.saveData(
        key: _kExistingId,
        value: existingTranscriptId,
      );
    }

    await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      notificationTitle: 'Transcribing…',
      notificationText: 'Preparing Transcript',
      callback: transcribeStartCallback,
    );
  }

  static Future<int?> getLastResultId() async {
    final v = await FlutterForegroundTask.getData<int>(key: _kResultId);
    return v;
  }

  /// ✅ returns a cancelable subscription that actually removes callback.
  static StreamSubscription<dynamic> onData(
    void Function(dynamic data) handler,
  ) {
    FlutterForegroundTask.addTaskDataCallback(handler);
    return _TaskDataSubscription(
      onCancel: () {
        FlutterForegroundTask.removeTaskDataCallback(handler);
      },
    );
  }
}

/// Minimal StreamSubscription that only supports cancel()
class _TaskDataSubscription implements StreamSubscription<dynamic> {
  _TaskDataSubscription({required this.onCancel});

  final VoidCallback onCancel;
  bool _canceled = false;

  @override
  Future<void> cancel() async {
    if (_canceled) return;
    _canceled = true;
    onCancel();
  }

  // no-ops
  @override
  void onData(void Function(dynamic data)? handleData) {}
  @override
  void onError(Function? handleError) {}
  @override
  void onDone(void Function()? handleDone) {}
  @override
  void pause([Future<void>? resumeSignal]) {}
  @override
  void resume() {}
  @override
  bool get isPaused => false;

  @override
  Future<E> asFuture<E>([E? futureValue]) => Future<E>.value(futureValue as E);
}

class _TranscribeTaskHandler extends TaskHandler {
  String _fmtMmSs(double sec) {
    final s = (sec.isFinite && sec > 0) ? sec : 0.0;
    final total = s.round();
    final m = total ~/ 60;
    final ss = (total % 60).toString().padLeft(2, '0');
    return '$m:$ss';
  }

  List<TranscriptBlockSnapshot> _buildInitialBlocks({
    required int transcriptId,
    required String lang,
    required TranscriptionResult result,
  }) {
    final blocks = <TranscriptBlockSnapshot>[];

    for (var i = 0; i < result.turns.length; i++) {
      final turn = result.turns[i];
      final speakerDetail = i < result.speakerDetails.length
          ? result.speakerDetails[i]
          : null;
      final raw = turn.text.trim();

      blocks.add(
        TranscriptBlockSnapshot(
          meetingId: transcriptId.toString(),
          blockId: i,
          language: lang,
          startSec: turn.startSec,
          endSec: turn.endSec,
          speakerId: speakerDetail?.speakerId ?? turn.speaker,
          speakerLabel: speakerDetail?.speakerLabel ?? turn.speaker,
          rawText: raw,
          alignedText: raw,
          finalText: null,
          status: 'raw',
          confidence: speakerDetail?.confidence ?? 0.72,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          speakerDetails: speakerDetail == null ? const [] : [speakerDetail],
          metadata: {
            'turnIndex': i,
            'speakerMatchSource': speakerDetail?.matchSource ?? 'heuristic',
            if (speakerDetail?.matchedName != null)
              'matchedName': speakerDetail!.matchedName,
          },
        ),
      );
    }

    return blocks;
  }
  bool _readTypoFixEnabled(dynamic v) {
    // ✅ robust decoding across platforms
    if (v is bool) return v;
    if (v is int) return v != 0;
    if (v is num) return v.toInt() != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      if (s == 'true' || s == '1' || s == 'yes' || s == 'on') return true;
      if (s == 'false' || s == '0' || s == 'no' || s == 'off') return false;
    }
    return false;
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final wavPath = await FlutterForegroundTask.getData<String>(
      key: BackgroundTranscriber._kWavPath,
    );

    final translate =
        await FlutterForegroundTask.getData<bool>(
          key: BackgroundTranscriber._kTranslate,
        ) ??
        false;

    final titleHint = await FlutterForegroundTask.getData<String>(
      key: BackgroundTranscriber._kTitleHint,
    );
    final existingId = await FlutterForegroundTask.getData<int>(
      key: BackgroundTranscriber._kExistingId,
    );

    final tsRaw = await FlutterForegroundTask.getData(
      key: BackgroundTranscriber._kTargetSpeakers,
    );
    final tsInt = (tsRaw is int) ? tsRaw : int.tryParse('$tsRaw') ?? 0;
    final int? targetSpeakers = (tsInt <= 0) ? null : tsInt;

    final langRaw = await FlutterForegroundTask.getData(
      key: BackgroundTranscriber._kLang,
    );
    final String lang = (langRaw is String && langRaw.trim().isNotEmpty)
        ? langRaw.trim()
        : 'auto';

    // ✅ ONLY source of truth inside task isolate (stored as int)
    final rawTypo = await FlutterForegroundTask.getData(
      key: BackgroundTranscriber._kTypoFixEnabled,
    );
    final typoFixEnabled = _readTypoFixEnabled(rawTypo);

    if (wavPath == null || wavPath.isEmpty) {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Transcription failed',
        notificationText: 'No audio path',
      );
      await FlutterForegroundTask.stopService();
      return;
    }

    try {
      if (existingId != null) {
        await TranscriptBlockRepository.instance.clear(existingId);
      }

      await FlutterForegroundTask.updateService(
        notificationTitle: 'Transcribing…',
        notificationText: 'Preparing Transcript',
      );

      final TranscriptionResult result = await transcribeToResult(
        wavPath: wavPath,
        titleHint: titleHint,
        targetSpeakers: targetSpeakers,
        lang: lang,
        onBlockUpdated: (block) async {
          if (existingId == null) return;
          final normalized = block.copyWith(meetingId: existingId.toString());
          await TranscriptBlockRepository.instance.upsert(existingId, normalized);
          FlutterForegroundTask.sendDataToMain({
            'type': 'transcribe_block_update',
            'existingId': existingId,
            'wavPath': wavPath,
            'block': normalized.toJson(),
          });
        },
        onStageCompleted: (stage) async {
          FlutterForegroundTask.sendDataToMain({
            'type': 'transcribe_stage_update',
            'existingId': existingId,
            'wavPath': wavPath,
            'stage': stage,
          });
        },
        onProgress:
            ({
              required String stage,
              required double processedSec,
              required double totalSec,
            }) async {
              final pct = (totalSec > 0)
                  ? (processedSec / totalSec * 100).round()
                  : 0;

              await FlutterForegroundTask.saveData(
                key: BackgroundTranscriber._kProgressProcessedSec,
                value: processedSec,
              );
              await FlutterForegroundTask.saveData(
                key: BackgroundTranscriber._kProgressTotalSec,
                value: totalSec,
              );
              await FlutterForegroundTask.saveData(
                key: BackgroundTranscriber._kProgressStage,
                value: stage,
              );

              await FlutterForegroundTask.updateService(
                notificationTitle: '$stage…',
                notificationText:
                    '${_fmtMmSs(processedSec)} / ${_fmtMmSs(totalSec)}  ($pct%)',
              );
            },
      );

      final transcriptId = existingId ?? 0;
      final finalBlocks = result.blocks.isNotEmpty
          ? result.blocks
                .map(
                  (block) => block.copyWith(meetingId: transcriptId.toString()),
                )
                .toList()
          : _buildInitialBlocks(
              transcriptId: transcriptId,
              lang: lang,
              result: result,
            );

      if (existingId != null) {
        await TranscriptBlockRepository.instance.save(existingId, finalBlocks);
      }

      final payload = result.toJson();
      payload['blocks'] = finalBlocks.map((b) => b.toJson()).toList();
      payload['turns'] = finalBlocks
          .map(
            (b) => {
              'speaker': b.speakerLabel,
              'startSec': b.startSec,
              'endSec': b.endSec,
              'text': b.displayText,
              'status': b.status,
              'confidence': b.confidence,
            },
          )
          .toList();
      payload['speakerDetails'] = result.speakerDetails
          .map((e) => e.toJson())
          .toList();
      payload['pipeline'] = {
        'language': result.lang,
        'rawBlockCount': finalBlocks.length,
        'finalBlockCount': finalBlocks.length,
        'moonshineUsed':
            result.blocks.any((b) => b.metadata['moonshineText'] != null),
        'whisperUsed':
            result.blocks.any((b) => b.metadata['whisperText'] != null),
        'qwenUsed':
            result.blocks.any((b) => b.metadata['qwenText'] != null),
        'speakerDetails': result.speakerDetails.map((e) => e.toJson()).toList(),
      };

      FlutterForegroundTask.sendDataToMain({
        'type': 'transcribe_result',
        'existingId': existingId,
        'wavPath': wavPath,
        'payload': payload,
        'translate': translate,
        'typoFixEnabled': typoFixEnabled, // optional debug
      });

      if (existingId != null) {
        await FlutterForegroundTask.saveData(
          key: BackgroundTranscriber._kResultId,
          value: existingId,
        );
      }

      await FlutterForegroundTask.updateService(
        notificationTitle: 'Transcription complete',
        notificationText: 'Transcript is ready',
      );
    } catch (e) {
      FlutterForegroundTask.sendDataToMain({
        'type': 'transcribe_error',
        'error': e.toString(),
      });
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Error!',
        notificationText: 'See app',
      );
    } finally {
      // ✅ clear busy + active transcript id so other pages don't show loading
      await FlutterForegroundTask.saveData(
        key: BackgroundTranscriber._kBusyTranscribing,
        value: false,
      );
      await FlutterForegroundTask.saveData(
        key: BackgroundTranscriber._kActiveTranscriptId,
        value: 0,
      );

      await FlutterForegroundTask.stopService();
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool bySystem) async {
    await FlutterForegroundTask.saveData(
      key: BackgroundTranscriber._kBusyTranscribing,
      value: false,
    );
    await FlutterForegroundTask.saveData(
      key: BackgroundTranscriber._kActiveTranscriptId,
      value: 0,
    );
  }
}
