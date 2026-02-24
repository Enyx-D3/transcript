import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper_flutter_new/whisper_flutter_new.dart';

import 'package:flutter/services.dart' show rootBundle;
import 'dart:typed_data';

/// Simple progress value for model downloads.
/// Use .percent for 0..1 UI progress.
class ModelProgress {
  final bool downloading;
  final int received;
  final int total;
  final String? error;

  const ModelProgress({
    required this.downloading,
    required this.received,
    required this.total,
    this.error,
  });

  double get percent =>
      total <= 0 ? 0.0 : (received / total).clamp(0, 1).toDouble();

  static const idle = ModelProgress(downloading: false, received: 0, total: 0);
}

class WhisperService {
  Whisper? _whisper;
  WhisperModel? _currentModel;

  static const _kPrefModel = 'selected_whisper_model';
  static const String _assetTinyModel = 'assets/models/whisper/ggml-tiny.bin';
static const String _tinyFileName = 'ggml-tiny.bin';
  WhisperModel? get currentModel => _currentModel;
  bool get isReady => _whisper != null;

  WhisperService() {
    _initDownloader();
  }

  // -------------------- Persistence --------------------

  static Future<WhisperModel?> loadSavedModel() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_kPrefModel);
    switch (s) {
      case 'tiny':
        return WhisperModel.tiny;
      case 'base':
        return WhisperModel.base;
      case 'small':
        return WhisperModel.small;
      case 'medium':
        return WhisperModel.medium;
      default:
        return null;
    }
  }

  static Future<void> saveModel(WhisperModel m) async {
    final prefs = await SharedPreferences.getInstance();
    final v = switch (m) {
      WhisperModel.tiny => 'tiny',
      WhisperModel.base => 'base',
      WhisperModel.small => 'small',
      WhisperModel.medium => 'medium',
      _ => 'base',
    };
    await prefs.setString(_kPrefModel, v);
  }

  // -------------------- Progress streams --------------------

  final Map<WhisperModel, StreamController<ModelProgress>> _progressCtrls = {};
  final Map<WhisperModel, String> _taskIds = {};
  final FileDownloader _bd = FileDownloader();

  Stream<ModelProgress> progressOf(WhisperModel m) =>
      (_progressCtrls[m] ??= StreamController<ModelProgress>.broadcast()).stream;

  void _emit(WhisperModel m, ModelProgress p) {
    (_progressCtrls[m] ??= StreamController<ModelProgress>.broadcast()).add(p);
  }

  void _initDownloader() {
    try {
    // Listen to global updates and map them back to the model using our taskId map.
    _bd.updates.listen((update) {
      if (update is TaskProgressUpdate) {
        final model = _modelForTaskId(update.task.taskId);
        if (model == null) return;

        // update.progress is a double fraction 0..1 in v8
        // Convert to 0..1000 int scale so ModelProgress.percent works.
        final fraction = update.progress.clamp(0.0, 1.0);
        final received = (fraction * 1000).round();
        const total = 1000;

        _emit(
          model,
          ModelProgress(
            downloading: true,
            received: received,
            total: total,
          ),
        );
      } else if (update is TaskStatusUpdate) {
        final model = _modelForTaskId(update.task.taskId);
        if (model == null) return;

        switch (update.status) {
          case TaskStatus.complete:
            _emit(model, const ModelProgress(downloading: false, received: 1, total: 1));
            _taskIds.remove(model);
            break;
          case TaskStatus.failed:
            _emit(
              model,
              ModelProgress(
                downloading: false,
                received: 0,
                total: 0,
                error: update.exception?.toString() ?? 'Download failed',
              ),
            );
            _taskIds.remove(model);
            break;
          case TaskStatus.canceled:
            _emit(model, ModelProgress.idle);
            _taskIds.remove(model);
            break;
          default:
            // ignore other statuses
            break;
        }
      }
    });
    } catch (e) {
      // background_downloader can fail in release mode; non-fatal
      debugPrint('[WhisperService] _initDownloader error (non-fatal): $e');
    }
  }

  WhisperModel? _modelForTaskId(String id) {
    for (final e in _taskIds.entries) {
      if (e.value == id) return e.key;
    }
    return null;
  }

  // -------------------- Public API (kept signatures) --------------------

  Future<void> selectModel(WhisperModel model) async {
    if (!await isModelDownloaded(model)) {
      await downloadModel(model); // enqueue in background; UI can watch progressOf(model)
      return;
    }

    _currentModel = model;
    _whisper = Whisper(
      model: model,
      downloadHost: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main',
    );

    await _whisper!.getVersion();
    await saveModel(model);
  }

Future<String> _ensureTinyModelDirOnDisk() async {
  final supportDir = await getApplicationSupportDirectory();
  final modelsDir = Directory(p.join(supportDir.path, 'models'))
    ..createSync(recursive: true);

  final outFile = File(p.join(modelsDir.path, _tinyFileName));

  // If already present and non-trivial size, reuse it
  if (outFile.existsSync() && outFile.lengthSync() > 10 * 1024 * 1024) {
    return modelsDir.path;
  }

  final ByteData bd = await rootBundle.load(_assetTinyModel);
  final Uint8List bytes =
      bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);

  await outFile.writeAsBytes(bytes, flush: true);
  return modelsDir.path;
}


Future<String> transcribeWav({
  required String wavPath,
  required String lang,
  bool translateToEnglish = false,
  bool noTimestamps = false,
  bool splitOnWord = true,
  bool diarize = true,
}) async {
  if (_whisper == null) {
    _currentModel = WhisperModel.tiny;

    final modelDirOnDisk = await _ensureTinyModelDirOnDisk();

    _whisper = Whisper(
      model: WhisperModel.tiny,
      modelDir: modelDirOnDisk, // ✅ real directory on disk
      downloadHost: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main',
    );

    await _whisper!.getVersion();
  }

  final transcript = await _whisper!.transcribe(
    transcribeRequest: TranscribeRequest(
      audio: wavPath,
      language: lang,
      isTranslate: translateToEnglish,
      isNoTimestamps: noTimestamps,
      splitOnWord: splitOnWord,
      diarize: diarize,
    ),
  );

  return transcript.text;
}

  // -------------------- Download Management --------------------

  Future<bool> isModelDownloaded(WhisperModel model) async {
    final f = File(await _modelFilePath(model));
    return f.existsSync() && f.lengthSync() > 10 * 1024 * 1024; // >10MB
  }

  Future<void> cancelDownload(WhisperModel model) async {
    final id = _taskIds[model];
    if (id != null) {
      await _bd.cancelTaskWithId(id);
    }
  }

  Future<void> downloadModel(WhisperModel model) async {
    if (await isModelDownloaded(model)) {
      _emit(model, const ModelProgress(downloading: false, received: 1, total: 1));
      return;
    }

    final filePath = await _modelFilePath(model);
    final filename = p.basename(filePath);

    final task = DownloadTask(
      url: _modelUrl(model),
      filename: filename,
      baseDirectory: BaseDirectory.applicationSupport,
      directory: 'models',
      updates: Updates.statusAndProgress, // we listen to both
      retries: 3,
      requiresWiFi: false,
      allowPause: true,
    );

    Directory(p.dirname(filePath)).createSync(recursive: true);

    _taskIds[model] = task.taskId;
    _emit(model, const ModelProgress(downloading: true, received: 0, total: 0));

    await _bd.enqueue(task); // enqueues to run in true background
  }

  // -------------------- Paths / URLs --------------------

  String _fileName(WhisperModel m) {
    switch (m) {
      case WhisperModel.tiny:
        return 'ggml-tiny.bin';
      case WhisperModel.base:
        return 'ggml-base.bin';
      case WhisperModel.small:
        return 'ggml-small.bin';
      case WhisperModel.medium:
        return 'ggml-medium.bin';
      default:
        return 'ggml-base.bin';
    }
  }

  String _modelUrl(WhisperModel m) =>
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${_fileName(m)}';

  Future<String> _modelFilePath(WhisperModel m) async {
    final dir = await getApplicationSupportDirectory();
    final modelsDir = Directory(p.join(dir.path, 'models'))..createSync(recursive: true);
    return p.join(modelsDir.path, _fileName(m));
  }
}
