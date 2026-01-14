import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'transcription_models.dart';
import 'transcription_compute.dart' show transcribeToResult;

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

  // ✅ NEW: stored int where 0 == null/auto
  static const _kTargetSpeakers = 'bg_target_speakers';

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

  static Future<void> start({
    required String wavPath,
    bool translateToEnglish = false,
    String? titleHint,
    int? existingTranscriptId,

    // ✅ NEW
    int? targetSpeakers,
  }) async {
    await FlutterForegroundTask.saveData(key: _kWavPath, value: wavPath);
    await FlutterForegroundTask.saveData(
      key: _kTranslate,
      value: translateToEnglish,
    );
    await FlutterForegroundTask.saveData(key: _kBusyTranscribing, value: true);

    // ✅ store int (0 means null/auto)
    await FlutterForegroundTask.saveData(
      key: _kTargetSpeakers,
      value: targetSpeakers ?? 0,
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

  static StreamSubscription<dynamic> onData(
    void Function(dynamic data) handler,
  ) {
    FlutterForegroundTask.addTaskDataCallback(handler);
    final ctrl = StreamController<dynamic>();
    ctrl.onCancel = () => FlutterForegroundTask.removeTaskDataCallback(handler);
    return ctrl.stream.listen((_) {});
  }
}

class _TranscribeTaskHandler extends TaskHandler {
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

    // ✅ read stored int (0 => null)
    final tsRaw = await FlutterForegroundTask.getData(
      key: BackgroundTranscriber._kTargetSpeakers,
    );
    final tsInt = (tsRaw is int) ? tsRaw : 0;
    final int? targetSpeakers = (tsInt <= 0) ? null : tsInt;

    if (wavPath == null || wavPath.isEmpty) {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Transcription failed',
        notificationText: 'No audio path',
      );
      await FlutterForegroundTask.stopService();
      return;
    }

    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Transcribing…',
        notificationText: 'Preparing Transcript',
      );

      final TranscriptionResult result = await transcribeToResult(
        wavPath: wavPath,
        translateToEnglish: translate,
        titleHint: titleHint,
        targetSpeakers: targetSpeakers, // ✅ pass
      );

      FlutterForegroundTask.sendDataToMain({
        'type': 'transcribe_result',
        'existingId': existingId,
        'wavPath': wavPath,
        'payload': result.toJson(),
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
        notificationTitle: 'Transcription failed',
        notificationText: 'See app',
      );
    } finally {
      await FlutterForegroundTask.saveData(
        key: BackgroundTranscriber._kBusyTranscribing,
        value: false,
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
  }
}
