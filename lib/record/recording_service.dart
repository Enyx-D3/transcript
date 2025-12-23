// lib/record/recording_service.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// ===== Public control surface you call from UI =====
class RecordingService {
  static const _serviceId = 431; // any unique int
  static const _kFilePath = 'rec_file_path';
  static const _kCmd = 'cmd';
  static const _cmdStop = 'stop';

  /// Must be called once (e.g. app start or before first start()).
  static Future<void> ensureInitialized() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'rec_channel',
        channelName: 'Recording',
        channelDescription: 'Capturing microphone audio',
        channelImportance: NotificationChannelImportance.DEFAULT,
        priority: NotificationPriority.DEFAULT,

        // lock-screen behavior
        visibility: NotificationVisibility.VISIBILITY_PUBLIC,
        showWhen: true,
        onlyAlertOnce: true,
        playSound: false,
        enableVibration: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // TICK EVERY 1 SECOND
        eventAction: ForegroundTaskEventAction.repeat(1000),
        allowWakeLock: true,
        allowWifiLock: true,
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: true,
      ),
    );

    // REQUIRED for sendDataToMain / addTaskDataCallback
    FlutterForegroundTask.initCommunicationPort();
  }

  /// Start service + begin recording. Returns file path if started, else null.
  static Future<String?> start() async {
    await ensureInitialized(); // <-- make initialization idempotent & guaranteed
    final already = await FlutterForegroundTask.isRunningService;
    if (!already) {
      final filePath = await _newWavPath();

      // Persist data for the TaskHandler
      await FlutterForegroundTask.saveData(key: _kFilePath, value: filePath);
      await FlutterForegroundTask.saveData(
        key: _kStartEpochMs,
        value: DateTime.now().millisecondsSinceEpoch,
      );
      await FlutterForegroundTask.saveData(key: _kPaused, value: false);

      final result = await FlutterForegroundTask.startService(
        serviceId: _serviceId,
        notificationTitle: 'Recording…',
        notificationText: '00:00',
        // optional:
        notificationIcon: null,
        notificationButtons: const [
          // NotificationButton(id: _btnPause, text: 'Pause'),
          // NotificationButton(id: _btnStop, text: 'Stop'),
        ],
        callback: recordingStartCallback, // your top-level entrypoint
      );

      if (result is ServiceRequestSuccess) {
        return filePath;
      } else if (result is ServiceRequestFailure) {
        // Optionally log: result.error
        return null;
      } else {
        return null;
      }
    } else {
      // Already running → return stored path
      final v = await FlutterForegroundTask.getData(key: _kFilePath);
      return v is String ? v : null;
    }
  }

  static void pause() =>
      FlutterForegroundTask.sendDataToTask(const {_kCmd: _cmdPause});

  static void resume() =>
      FlutterForegroundTask.sendDataToTask(const {_kCmd: _cmdResume});

  static Future<String?> stop() async {
    final completer = Completer<void>();
    void onData(Object data) {
      if (data is Map && data['type'] == 'stopped') {
        // (Optionally: capture filePath from the event)
        completer.complete();
      }
    }

    // Listen for task → UI signal that the recorder has fully stopped.
    FlutterForegroundTask.addTaskDataCallback(onData);

    // Ask the TaskHandler to stop the recorder & flush the file.
    FlutterForegroundTask.sendDataToTask(const {_kCmd: _cmdStop});

    // Wait (with timeout) for the confirmation message.
    try {
      await completer.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      // If it times out, we’ll still attempt to stop the service gracefully.
    } finally {
      FlutterForegroundTask.removeTaskDataCallback(onData);
    }

    // Read the path while the service is still alive.
    final v = await FlutterForegroundTask.getData(key: _kFilePath);
    final path = v is String ? v : null;

    // Now stop the foreground service.
    final result = await FlutterForegroundTask.stopService();

    return (result is ServiceRequestSuccess) ? path : null;
  }

  /// Subscribe in UI to get ticks & state from the TaskHandler (optional).
  /// Call removeTaskDataCallback on dispose.
  static void addListener(void Function(Object data) onData) {
    FlutterForegroundTask.addTaskDataCallback(onData);
  }

  static void removeListener(void Function(Object data) onData) {
    FlutterForegroundTask.removeTaskDataCallback(onData);
  }

  static Future<String> _newWavPath() async {
    final dir = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/recordings',
    )..createSync(recursive: true);
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    return '${dir.path}/rec_$ts.wav';
  }
}

/// ====== TaskHandler + constants ======

// keys for plugin key-value storage
const _kFilePath = 'rec_file_path';
const _kStartEpochMs = 'rec_start_epoch_ms';
const _kPaused = 'rec_paused';

// messages between UI <-> Task
const _kCmd = 'cmd';
const _cmdPause = 'pause';
const _cmdResume = 'resume';
const _cmdStop = 'stop';

// notification button ids
const _btnPause = 'btn_pause';
const _btnResume = 'btn_resume';
const _btnStop = 'btn_stop';

@pragma('vm:entry-point')
void recordingStartCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(_RecordingTaskHandler());
}

class _RecordingTaskHandler extends TaskHandler {
  late final AudioRecorder _rec; // ✅
  bool _paused = false;
  int _startEpochMs = DateTime.now().millisecondsSinceEpoch;
  String? _path;
  bool _stopped = false; // ✅ add
  // Called when the service starts.
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _rec = AudioRecorder();
    // Load config saved by UI
    final p = await FlutterForegroundTask.getData(key: _kFilePath);
    final s = await FlutterForegroundTask.getData(key: _kStartEpochMs);
    final pa = await FlutterForegroundTask.getData(key: _kPaused);

    _path = (p is String) ? p : null;
    _startEpochMs = (s is int) ? s : DateTime.now().millisecondsSinceEpoch;
    _paused = (pa is bool) ? pa : false;

    if (_path == null) {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/recordings')
        ..createSync(recursive: true);
      final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
      _path = '${dir.path}/rec_$ts.wav';
    }

    // Start recording to that path if not started yet.
    if (!await _rec.isRecording()) {
      await _rec.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: _path!,
      );
    }

    // If we booted into paused state, pause now.
    if (_paused && await _rec.isRecording()) {
      await _rec.pause();
    }
  }

  // Tick comes from ForegroundTaskOptions.eventAction (repeat(1000))
  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_stopped) return; // ✅ add
  _tickAndNotify(timestamp);
  }

  @override
  void onReceiveData(Object data) async {
    if (data is Map && data[_kCmd] is String) {
      final cmd = data[_kCmd] as String;
      switch (cmd) {
        case _cmdPause:
          await _pauseInternal();
          break;
        case _cmdResume:
          await _resumeInternal();
          break;
        case _cmdStop:
          await _stopInternal();
          break;
      }
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    switch (id) {
      case _btnPause:
        _pauseInternal();
        break;
      case _btnResume:
        _resumeInternal();
        break;
      case _btnStop:
        _stopInternal();
        break;
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    // Make sure the recorder is stopped and flushed.
    if (await _rec.isRecording()) {
      await _rec.stop();
    } else {
      // If paused, calling stop() is still okay in record 5.x
      await _rec.stop();
    }
  }

  // ---- internals ----
  Future<void> _pauseInternal() async {
    if (_stopped) return;
    if (await _rec.isRecording()) {
      await _rec.pause();
      _paused = true;
      await FlutterForegroundTask.saveData(key: _kPaused, value: true);
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Paused',
        notificationButtons: const [
          NotificationButton(id: _btnResume, text: 'Resume'),
          NotificationButton(id: _btnStop, text: 'Stop'),
        ],
      );
    }
  }

  Future<void> _resumeInternal() async {
    if (_stopped) return;
    if (await _rec.isPaused()) {
      await _rec.resume();
      _paused = false;
      await FlutterForegroundTask.saveData(key: _kPaused, value: false);
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Recording…',
        notificationButtons: const [
          NotificationButton(id: _btnPause, text: 'Pause'),
          NotificationButton(id: _btnStop, text: 'Stop'),
        ],
      );
    }
  }

  Future<void> _stopInternal() async {
  if (_stopped) return;
  _stopped = true; // ✅ add

  await _rec.stop();

  FlutterForegroundTask.sendDataToMain({
    'type': 'stopped',
    'filePath': _path,
  });
}

  void _tickAndNotify(DateTime ts) async {
    final elapsed = _elapsedSeconds(ts.millisecondsSinceEpoch);

    double level = 0.0;
    try {
      final amp = await _rec.getAmplitude(); // record package
      final db = amp.current; // ~ -160..0
      final clamped = db.clamp(-20.0, 0.0);
      level = (clamped + 20.0) / 20.0;
    } catch (_) {
      level = 0.0;
    }
    debugPrint('LEVEL ${DateTime.now().toIso8601String()} -> $level');
    FlutterForegroundTask.sendDataToMain({
      'type': 'tick',
      'elapsedSec': elapsed,
      'paused': _paused,
      'level': level, // <-- critical: include this field
    });

    final mm = (elapsed ~/ 60).toString().padLeft(2, '0');
    final ss = (elapsed % 60).toString().padLeft(2, '0');
    await FlutterForegroundTask.updateService(notificationText: '$mm:$ss');
  }

  int _elapsedSeconds(int nowMs) {
    // When paused we still show the frozen elapsed time; for simplicity we
    // just stop increasing the clock when paused.
    if (_paused) {
      // Compute last elapsed based on last timestamp we sent (notification holds it).
      // Here we just cap it at current computed value and don't increment while paused.
    }
    final base = Duration(milliseconds: nowMs - _startEpochMs).inSeconds;
    return base < 0 ? 0 : base;
  }
}
