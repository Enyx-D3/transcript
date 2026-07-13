import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'moonshine_service.dart' show ModelProgress;

class QwenModelService {
  QwenModelService._internal() {
    _attachGlobalUpdatesListener();
    _restoreFromDatabase(); // ✅ key: restore after restart
  }
  static final QwenModelService _instance = QwenModelService._internal();
  factory QwenModelService() => _instance;

  static const String _fileName = 'qwen2.5-0.5b-instruct-q4_k_m.gguf';
  static const String _url =
      'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf?download=true';

  // ✅ stable identity so we can look it up after restart
  static const String _taskId = 'enyx_model_download';
  static const String _group = 'models';

  final FileDownloader _bd = FileDownloader();

  final StreamController<ModelProgress> _progressCtrl =
      StreamController<ModelProgress>.broadcast();
  Stream<ModelProgress> get progress => _progressCtrl.stream;

  StreamSubscription<TaskUpdate>? _updatesSub;

  DownloadTask? _activeTask;
  Completer<bool>? _downloadCompleter;

  void _emit(ModelProgress p) {
    if (!_progressCtrl.isClosed) _progressCtrl.add(p);
  }

  void _completeDownload(bool ok) {
    final completer = _downloadCompleter;
    if (completer == null || completer.isCompleted) return;
    completer.complete(ok);
    _downloadCompleter = null;
  }

  Future<String> modelFilePath() async {
    final dir = await getApplicationDocumentsDirectory();
    final modelsDir = Directory(p.join(dir.path, 'models'))
      ..createSync(recursive: true);
    return p.join(modelsDir.path, _fileName);
  }

  Future<bool> isModelDownloaded() async {
    final path = await modelFilePath();
    final f = File(path);
    if (!await f.exists()) return false;
    final length = await f.length();
    return length > 10 * 1024 * 1024; // >10MB sanity check
  }

  // ==========================================================
  // ✅ 1) Attach global updates listener (works across restarts)
  // ==========================================================
  void _attachGlobalUpdatesListener() {
    _updatesSub?.cancel();
    _updatesSub = _bd.updates.listen((update) async {
      // Only care about our model task
      if (update.task.taskId != _taskId) return;

      if (update is TaskProgressUpdate) {
        final progress = update.progress; // 0.0..1.0
        if (progress < 0) return;

        final fraction = progress.clamp(0.0, 1.0);
        final received = (fraction * 1000).round();
        const total = 1000;

        _emit(
          ModelProgress(downloading: true, received: received, total: total),
        );
        return;
      }

      if (update is TaskStatusUpdate) {
        switch (update.status) {
          case TaskStatus.complete:
            _activeTask = null;
            _emit(
              const ModelProgress(downloading: false, received: 1, total: 1),
            );
            _completeDownload(true);
            break;
          case TaskStatus.canceled:
            _activeTask = null;
            _emit(ModelProgress.idle);
            _completeDownload(false);
            break;
          case TaskStatus.failed:
            _activeTask = null;
            _emit(
              ModelProgress(
                downloading: false,
                received: 0,
                total: 0,
                error: update.exception?.toString() ?? 'Model download failed',
              ),
            );
            _completeDownload(false);
            break;
          default:
            // running/paused/enqueued/etc — progress updates will drive UI
            break;
        }
      }
    });
  }

  // ==========================================================
  // ✅ 2) Restore last known state from database after restart
  // ==========================================================
Future<void> _restoreFromDatabase() async {
  try {
    if (await isModelDownloaded()) {
      _emit(const ModelProgress(downloading: false, received: 1, total: 1));
      _completeDownload(true);
      return;
    }

    final record = await _bd.database.recordForId(_taskId);
    if (record == null) return; // ✅ FIX

    final status = record.status;
    final progress = record.progress;

    final isActive = status == TaskStatus.running ||
        status == TaskStatus.enqueued ||
        status == TaskStatus.waitingToRetry ||
        status == TaskStatus.paused;

    if (isActive && progress >= 0) {
      final fraction = progress.clamp(0.0, 1.0);
      final received = (fraction * 1000).round();
      const total = 1000;

      _emit(ModelProgress(
        downloading: true,
        received: received,
        total: total,
      ));
    }

    if (status == TaskStatus.complete) {
      _emit(const ModelProgress(downloading: false, received: 1, total: 1));
      _completeDownload(true);
    }

    if (status == TaskStatus.failed) {
      _emit(ModelProgress(
        downloading: false,
        received: 0,
        total: 0,
        error: 'Model download failed',
      ));
      _completeDownload(false);
    }
  } catch (_) {
    // ignore
  }
}


  // ==========================================================
  // Download / cancel
  // ==========================================================
  Future<void> downloadModel() async {
    // Prevent starting multiple tasks
    if (_activeTask != null) return;

    if (await isModelDownloaded()) {
      _emit(const ModelProgress(downloading: false, received: 1, total: 1));
      return;
    }

    final filePath = await modelFilePath();
    final filename = p.basename(filePath);
    Directory(p.dirname(filePath)).createSync(recursive: true);

    final task = DownloadTask(
      taskId: _taskId, // ✅ stable across restarts
      group: _group, // ✅ optional
      url: _url,
      filename: filename,
      baseDirectory: BaseDirectory.applicationDocuments,
      directory: 'models',
      updates: Updates.statusAndProgress,
      retries: 3,
      requiresWiFi: false,
      allowPause: true,
    );

    _activeTask = task;

    // Emit initial
    _emit(const ModelProgress(downloading: true, received: 0, total: 1000));

    // Enqueue (or download). Enqueue is often preferred for background behavior.
    final ok = await _bd.enqueue(task);
    if (!ok) {
      _activeTask = null;
      _emit(
        ModelProgress(
          downloading: false,
          received: 0,
          total: 0,
          error: 'Failed to enqueue model download',
        ),
      );
      _completeDownload(false);
    }
  }

  Future<bool> ensureModelDownloaded({bool autoDownload = true}) async {
    if (await isModelDownloaded()) {
      _emit(const ModelProgress(downloading: false, received: 1, total: 1));
      return true;
    }

    final existing = _downloadCompleter;
    if (existing != null) {
      return existing.future;
    }

    if (!autoDownload) return false;

    _downloadCompleter = Completer<bool>();
    try {
      await downloadModel();
    } catch (_) {
      _completeDownload(false);
    }

    final completer = _downloadCompleter;
    return completer?.future ?? false;
  }

  Future<void> cancelDownload() async {
    await _bd.cancelTaskWithId(_taskId); // ✅ stable id
    _completeDownload(false);
  }

  void dispose() {
    _updatesSub?.cancel();
    _progressCtrl.close();
  }
}
