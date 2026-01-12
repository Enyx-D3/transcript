import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RecordingService {
  static const _serviceId = 431;

  static Future<void> ensureInitialized() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'rec_channel',
        channelName: 'Recording',
        channelDescription: 'Capturing microphone audio',
        channelImportance: NotificationChannelImportance.DEFAULT,
        priority: NotificationPriority.DEFAULT,
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
        eventAction: ForegroundTaskEventAction.repeat(200),
        allowWakeLock: true,
        allowWifiLock: false,
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: true,
      ),
    );

    FlutterForegroundTask.initCommunicationPort();
  }

  static Future<String?> start() async {
    await ensureInitialized();

    final already = await FlutterForegroundTask.isRunningService;
    if (!already) {
      final filePath = await _newWavPath();

      // ✅ Read SharedPreferences HERE (UI isolate) and pass value to task storage
      final prefs = await SharedPreferences.getInstance();
      final allowLong = prefs.getBool(_kAllowLongRecordingPref) ?? false;

      await FlutterForegroundTask.saveData(key: _kFilePath, value: filePath);
      await FlutterForegroundTask.saveData(
        key: _kStartEpochMs,
        value: DateTime.now().millisecondsSinceEpoch,
      );
      await FlutterForegroundTask.saveData(key: _kPaused, value: false);

      // ✅ runtime config for the task
      await FlutterForegroundTask.saveData(
        key: _kAllowLongRecordingRuntime,
        value: allowLong,
      );

      final result = await FlutterForegroundTask.startService(
        serviceId: _serviceId,
        notificationTitle: 'Recording…',
        notificationText: '00:00',
        callback: recordingStartCallback,
      );

      return (result is ServiceRequestSuccess) ? filePath : null;
    } else {
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
        if (!completer.isCompleted) completer.complete();
      }
    }

    FlutterForegroundTask.addTaskDataCallback(onData);
    FlutterForegroundTask.sendDataToTask(const {_kCmd: _cmdStop});

    try {
      await completer.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      // ignore timeout
    } finally {
      FlutterForegroundTask.removeTaskDataCallback(onData);
    }

    final v = await FlutterForegroundTask.getData(key: _kFilePath);
    final path = v is String ? v : null;

    final result = await FlutterForegroundTask.stopService();
    return (result is ServiceRequestSuccess) ? path : null;
  }

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

// keys for plugin key-value storage
const _kFilePath = 'rec_file_path';
const _kStartEpochMs = 'rec_start_epoch_ms';
const _kPaused = 'rec_paused';

// messages between UI <-> Task
const _kCmd = 'cmd';
const _cmdPause = 'pause';
const _cmdResume = 'resume';
const _cmdStop = 'stop';

// notification button ids (optional)
const _btnPause = 'btn_pause';
const _btnResume = 'btn_resume';
const _btnStop = 'btn_stop';

// ✅ SharedPreferences key
const String _kAllowLongRecordingPref = 'allow_long_recording';

// ✅ runtime value passed into the task (read via FlutterForegroundTask.getData)
const String _kAllowLongRecordingRuntime = 'allow_long_recording_runtime';

// ✅ default limit (you said currently you want 30s; change later)
const int _kDefaultMaxSeconds = (30*60)+1; // 30 min

@pragma('vm:entry-point')
void recordingStartCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(_RecordingTaskHandler());
}

class _RecordingTaskHandler extends TaskHandler {
  late final AudioRecorder _rec;

  bool _paused = false;
  bool _stopped = false;

  int _startEpochMs = DateTime.now().millisecondsSinceEpoch;

  int _pausedAccumMs = 0;
  int? _pauseStartedMs;

  String? _path;

  int _lastNotifSec = -1;

  // ✅ config loaded from task storage
  bool _allowLongRecording = false;

  // ✅ prevent overlapping async tick calls
  bool _ticking = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _rec = AudioRecorder();

    final p = await FlutterForegroundTask.getData(key: _kFilePath);
    final s = await FlutterForegroundTask.getData(key: _kStartEpochMs);
    final pa = await FlutterForegroundTask.getData(key: _kPaused);
    final allow = await FlutterForegroundTask.getData(key: _kAllowLongRecordingRuntime);

    _path = (p is String) ? p : null;
    _startEpochMs = (s is int) ? s : DateTime.now().millisecondsSinceEpoch;
    _paused = (pa is bool) ? pa : false;
    _allowLongRecording = (allow is bool) ? allow : false;

    if (_path == null) {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/recordings')..createSync(recursive: true);
      final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
      _path = '${dir.path}/rec_$ts.wav';
    }

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

    if (_paused && await _rec.isRecording()) {
      await _rec.pause();
      _pauseStartedMs = DateTime.now().millisecondsSinceEpoch;
    }

    _tickAndNotify(DateTime.now());
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_stopped) return;
    if (_ticking) return;
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
          await _stopInternal(stopServiceToo: true);
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
        _stopInternal(stopServiceToo: true);
        break;
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    try {
      await _rec.stop();
    } catch (_) {}
  }

  Future<void> _pauseInternal() async {
    if (_stopped) return;
    if (!_paused && await _rec.isRecording()) {
      await _rec.pause();
      _paused = true;
      _pauseStartedMs = DateTime.now().millisecondsSinceEpoch;

      await FlutterForegroundTask.saveData(key: _kPaused, value: true);
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Paused',
        notificationButtons: const [
          NotificationButton(id: _btnResume, text: 'Resume'),
          NotificationButton(id: _btnStop, text: 'Stop'),
        ],
      );

      _tickAndNotify(DateTime.now());
    }
  }

  Future<void> _resumeInternal() async {
    if (_stopped) return;
    if (_paused && await _rec.isPaused()) {
      await _rec.resume();

      final now = DateTime.now().millisecondsSinceEpoch;
      if (_pauseStartedMs != null) {
        _pausedAccumMs += (now - _pauseStartedMs!);
        _pauseStartedMs = null;
      }

      _paused = false;

      await FlutterForegroundTask.saveData(key: _kPaused, value: false);
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Recording…',
        notificationButtons: const [
          NotificationButton(id: _btnPause, text: 'Pause'),
          NotificationButton(id: _btnStop, text: 'Stop'),
        ],
      );

      _tickAndNotify(DateTime.now());
    }
  }

  Future<void> _stopInternal({bool stopServiceToo = false}) async {
    if (_stopped) return;
    _stopped = true;

    try {
      await _rec.stop();
    } catch (_) {}

    FlutterForegroundTask.sendDataToMain({
      'type': 'stopped',
      'filePath': _path,
    });

    if (stopServiceToo) {
      try {
        await FlutterForegroundTask.stopService();
      } catch (_) {}
    }
  }

  void _tickAndNotify(DateTime ts) async {
    _ticking = true;
    try {
      final elapsed = _elapsedSeconds(ts.millisecondsSinceEpoch);

      // ✅ enforce limit here
      if (!_allowLongRecording && elapsed >= _kDefaultMaxSeconds) {
        FlutterForegroundTask.sendDataToMain({
          'type': 'limit_reached',
          'elapsedSec': elapsed,
          'maxSec': _kDefaultMaxSeconds,
        });

        try {
          await FlutterForegroundTask.updateService(
            notificationTitle: 'Limit reached',
            notificationText: 'Stopping…',
          );
        } catch (_) {}

        await _stopInternal(stopServiceToo: true);
        return;
      }

      double level = 0.0;
      try {
        final amp = await _rec.getAmplitude();
        final db = amp.current; // -160..0
        final clamped = db.clamp(-60.0, 0.0);
        level = (clamped + 60.0) / 60.0; // 0..1
      } catch (_) {
        level = 0.0;
      }

      FlutterForegroundTask.sendDataToMain({
        'type': 'tick',
        'elapsedSec': elapsed,
        'paused': _paused,
        'level': level,
      });

      if (elapsed != _lastNotifSec) {
        _lastNotifSec = elapsed;
        final mm = (elapsed ~/ 60).toString().padLeft(2, '0');
        final ss = (elapsed % 60).toString().padLeft(2, '0');
        await FlutterForegroundTask.updateService(notificationText: '$mm:$ss');
      }
    } finally {
      _ticking = false;
    }
  }

  int _elapsedSeconds(int nowMs) {
    final pausedExtra = (_pauseStartedMs == null) ? 0 : (nowMs - _pauseStartedMs!);
    final effectiveMs = (nowMs - _startEpochMs) - _pausedAccumMs - pausedExtra;

    final sec = Duration(milliseconds: effectiveMs).inSeconds;
    return sec < 0 ? 0 : sec;
  }
}
