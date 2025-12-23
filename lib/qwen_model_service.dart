import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'whisper_service.dart' show ModelProgress;

/// Singleton service to download and track the Qwen GGUF model.
class QwenModelService {
  QwenModelService._internal();
  static final QwenModelService _instance = QwenModelService._internal();
  factory QwenModelService() => _instance;

  static const String _fileName = 'qwen1_5-0_5b-chat-q4_k_m.gguf';
  static const String _url =
      'https://huggingface.co/Qwen/Qwen1.5-0.5B-Chat-GGUF/resolve/main/qwen1_5-0_5b-chat-q4_k_m.gguf?download=true';

  final FileDownloader _bd = FileDownloader();
  final StreamController<ModelProgress> _progressCtrl =
      StreamController<ModelProgress>.broadcast();

  Stream<ModelProgress> get progress => _progressCtrl.stream;

  DownloadTask? _activeTask;

  void _emit(ModelProgress p) {
    if (!_progressCtrl.isClosed) {
      _progressCtrl.add(p);
    }
  }

  /// Path to the Qwen model file:
  ///   <app-docs>/models/Qwen3-0.6B-Q4_K_M.gguf
  Future<String> modelFilePath() async {
    final dir = await getApplicationDocumentsDirectory();
    final modelsDir =
        Directory(p.join(dir.path, 'models'))..createSync(recursive: true);
    return p.join(modelsDir.path, _fileName);
  }

  Future<bool> isModelDownloaded() async {
    final path = await modelFilePath();
    final f = File(path);
    if (!await f.exists()) return false;
    final length = await f.length();
    return length > 10 * 1024 * 1024; // >10MB sanity check
  }

  Future<void> downloadModel() async {
    // Prevent starting multiple tasks
    if (_activeTask != null) {
      // Already downloading: just re-emit current state to any new listeners
      return;
    }

    if (await isModelDownloaded()) {
      _emit(const ModelProgress(downloading: false, received: 1, total: 1));
      return;
    }

    final filePath = await modelFilePath();
    final filename = p.basename(filePath);
    Directory(p.dirname(filePath)).createSync(recursive: true);

    final task = DownloadTask(
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
    _emit(const ModelProgress(downloading: true, received: 0, total: 0));

    final result = await _bd.download(
      task,
      onProgress: (progress) {
        if (progress < 0) return; // error states; will be handled by result

        final fraction = progress.clamp(0.0, 1.0);
        final received = (fraction * 1000).round();
        const total = 1000;

        _emit(
          ModelProgress(
            downloading: true,
            received: received,
            total: total,
          ),
        );
      },
    );

    _activeTask = null;

    switch (result.status) {
      case TaskStatus.complete:
        _emit(const ModelProgress(downloading: false, received: 1, total: 1));
        break;
      case TaskStatus.canceled:
        _emit(ModelProgress.idle);
        break;
      default:
        _emit(
          ModelProgress(
            downloading: false,
            received: 0,
            total: 0,
            error:
                result.exception?.toString() ?? 'Qwen model download failed',
          ),
        );
        break;
    }
  }

  Future<void> cancelDownload() async {
    final task = _activeTask;
    if (task != null) {
      await _bd.cancelTaskWithId(task.taskId);
    }
  }

  // NOTE: don’t call this from a page; treat the service as app-wide.
  void dispose() {
    _progressCtrl.close();
  }
}
