import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

import '../audio_utils.dart';
import 'model_download_state.dart';

class SherpaSecondaryAsrService {
  SherpaSecondaryAsrService._internal();

  static final SherpaSecondaryAsrService _instance =
      SherpaSecondaryAsrService._internal();
  factory SherpaSecondaryAsrService() => _instance;

  static const String _archiveName =
      'sherpa-onnx-whisper-tiny.en.tar.bz2';
  static const String _downloadUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-tiny.en.tar.bz2';
  static const String _extractDirName =
      'sherpa-onnx-whisper-tiny.en';
  static const List<String> _legacyArtifacts = [
    'sherpa-onnx-paraformer-zh-small-2024-03-09',
    'sherpa-onnx-paraformer-zh-small-2024-03-09.tar.bz2',
    'sherpa-onnx-paraformer-zh-2024-03-09',
    'sherpa-onnx-paraformer-zh-2024-03-09.tar.bz2',
  ];

  OfflineRecognizer? _recognizer;
  String? _modelRoot;
  final StreamController<ModelDownloadState> _progress =
      StreamController<ModelDownloadState>.broadcast();
  Future<bool>? _downloadFuture;

  Stream<ModelDownloadState> get progress => _progress.stream;

  void _emit(ModelDownloadState state) {
    if (_progress.isClosed) return;
    _progress.add(state);
  }

  Future<Directory> _rootDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'sherpa_models'))
      ..createSync(recursive: true);
    return dir;
  }

  Future<String> _archivePath() async {
    final dir = await _rootDir();
    return p.join(dir.path, _archiveName);
  }

  Future<String> _extractRoot() async {
    final dir = await _rootDir();
    return p.join(dir.path, _extractDirName);
  }

  List<FileSystemEntity> _listFiles(String root) {
    final dir = Directory(root);
    if (!dir.existsSync()) return const [];
    return dir.listSync(recursive: true, followLinks: false);
  }

  String? _findEncoderPath(String root) {
    final files = _listFiles(root);
    for (final entity in files) {
      if (entity is! File) continue;
      final path = entity.path;
      if (!path.toLowerCase().endsWith('.onnx')) continue;
      final name = p.basename(path).toLowerCase();
      if (name.contains('encoder') && name.contains('int8')) {
        return path;
      }
    }
    return null;
  }

  String? _findDecoderPath(String root) {
    final files = _listFiles(root);
    for (final entity in files) {
      if (entity is! File) continue;
      final name = p.basename(entity.path).toLowerCase();
      if (name.contains('decoder') && name.contains('int8')) {
        return entity.path;
      }
    }
    return null;
  }

  String? _findTokensPath(String root) {
    final files = _listFiles(root);
    for (final entity in files) {
      if (entity is! File) continue;
      final name = p.basename(entity.path).toLowerCase();
      if (name.endsWith('tokens.txt') || name == 'tokens.txt' || name == 'tokens') {
        return entity.path;
      }
    }
    return null;
  }

  Future<bool> isModelReady() async {
    final root = await _extractRoot();
    return _findEncoderPath(root) != null &&
        _findDecoderPath(root) != null &&
        _findTokensPath(root) != null;
  }

  Future<String> ensureModelDownloaded() async {
    final inFlight = _downloadFuture;
    if (inFlight != null) {
      final ok = await inFlight;
      if (ok) return _extractRoot();
    }

    if (await isModelReady()) {
      _emit(const ModelDownloadState.ready());
      return _extractRoot();
    }

    _downloadFuture = _downloadAndExtract();
    try {
      final ok = await _downloadFuture!;
      if (!ok) {
        throw StateError('Whisper model download failed.');
      }
      _emit(const ModelDownloadState.ready());
      return _extractRoot();
    } finally {
      _downloadFuture = null;
    }
  }

  Future<bool> _downloadAndExtract() async {
    try {
      await _cleanupLegacyArtifacts();
      _emit(
        const ModelDownloadState(
          downloading: true,
          stage: 'downloading',
          received: 0,
          total: 0,
        ),
      );

      final archivePath = await _archivePath();
      final archiveFile = File(archivePath);

      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(_downloadUrl));
        final resp = await client.send(req);
        if (resp.statusCode != 200) {
          throw HttpException(
            'HTTP ${resp.statusCode} while downloading Whisper model',
          );
        }

        final total = resp.contentLength ?? 0;
        int received = 0;
        final sink = archiveFile.openWrite();
        try {
          await for (final chunk in resp.stream) {
            received += chunk.length;
            sink.add(chunk);
            _emit(
              ModelDownloadState(
                downloading: true,
                stage: 'downloading',
                received: received,
                total: total,
              ),
            );
          }
        } finally {
          await sink.flush();
          await sink.close();
        }
      } finally {
        client.close();
      }

      final root = await _extractRoot();
      _emit(
        const ModelDownloadState(
          downloading: true,
          stage: 'extracting',
          received: 1,
          total: 1,
        ),
      );

      await _extractArchiveInBackground(
        archivePath: archivePath,
        root: root,
      );

      if (_findEncoderPath(root) == null ||
          _findDecoderPath(root) == null ||
          _findTokensPath(root) == null) {
        throw StateError(
          'Whisper tiny.en model files were not found after extraction at $root',
        );
      }

      return true;
    } catch (e) {
      _emit(
        ModelDownloadState(
          downloading: false,
          stage: 'error',
          received: 0,
          total: 0,
          error: e.toString(),
        ),
      );
      return false;
    }
  }

  Future<OfflineRecognizer> _loadRecognizer() async {
    initBindings();
    final root = await ensureModelDownloaded();
    if (_recognizer != null && _modelRoot == root) return _recognizer!;

    _recognizer?.free();

    final encoderPath = _findEncoderPath(root);
    final decoderPath = _findDecoderPath(root);
    final tokensPath = _findTokensPath(root);
    if (encoderPath == null || decoderPath == null || tokensPath == null) {
      throw StateError(
        'Whisper tiny.en model files were not found after extraction at $root',
      );
    }

    final config = OfflineRecognizerConfig(
      feat: const FeatureConfig(sampleRate: 16000, featureDim: 80),
      model: OfflineModelConfig(
        whisper: OfflineWhisperModelConfig(
          encoder: encoderPath,
          decoder: decoderPath,
        ),
        tokens: tokensPath,
        bpeVocab: tokensPath,
        numThreads: 1,
        debug: false,
        provider: 'cpu',
        modelType: 'whisper',
        modelingUnit: 'bpe',
      ),
      decodingMethod: 'greedy_search',
      maxActivePaths: 4,
      blankPenalty: 0.0,
    );

    _recognizer = OfflineRecognizer(config);
    _modelRoot = root;
    return _recognizer!;
  }

  static Future<void> _extractArchiveInBackground({
    required String archivePath,
    required String root,
  }) async {
    await Isolate.run(() {
      final archiveFile = File(archivePath);
      final tarBytes = BZip2Decoder().decodeBytes(archiveFile.readAsBytesSync());
      final archive = TarDecoder().decodeBytes(tarBytes);
      Directory(root).createSync(recursive: true);

      for (final file in archive.files) {
        final name = file.name;
        if (name.trim().isEmpty) continue;
        final entryPath = p.join(root, name);
        if (file.isFile) {
          final outFile = File(entryPath);
          outFile.parent.createSync(recursive: true);
          outFile.writeAsBytesSync(file.content as List<int>, flush: true);
        } else {
          Directory(entryPath).createSync(recursive: true);
        }
      }
    });
  }

  Future<void> _cleanupLegacyArtifacts() async {
    final dir = await _rootDir();
    for (final name in _legacyArtifacts) {
      final path = p.join(dir.path, name);
      try {
        final type = FileSystemEntity.typeSync(path, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          await Directory(path).delete(recursive: true);
        } else if (type == FileSystemEntityType.file) {
          await File(path).delete();
        }
      } catch (_) {
        // Ignore cleanup failures; current download should still continue.
      }
    }
  }

  Future<String> transcribeWav({
    required String wavPath,
    required String lang,
    bool translateToEnglish = false,
    bool noTimestamps = false,
  }) async {
    final recognizer = await _loadRecognizer();
    final wave = readWaveSimple(wavPath);
    if (wave.sampleRate != 16000) {
      throw UnsupportedError('Whisper ASR expects 16k WAV input.');
    }

    final stream = recognizer.createStream();
    stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
    recognizer.decode(stream);
    final result = recognizer.getResult(stream);
    stream.free();

    final text = result.text.trim();
    if (text.isEmpty) return '';
    return text;
  }

  void dispose() {
    _recognizer?.free();
    _recognizer = null;
    _modelRoot = null;
    _progress.close();
  }
}
