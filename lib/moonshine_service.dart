import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'audio_utils.dart';

class ModelProgress {
  final bool downloading;
  final int received;
  final int total;
  final String? error;
  final String stage;

  const ModelProgress({
    required this.downloading,
    required this.received,
    required this.total,
    this.error,
    this.stage = 'idle',
  });

  double get percent =>
      total <= 0 ? 0.0 : (received / total).clamp(0, 1).toDouble();

  static const idle = ModelProgress(
    downloading: false,
    received: 0,
    total: 0,
    stage: 'idle',
  );
}

class MoonshineService {
  MoonshineService._internal();

  static final MoonshineService _instance = MoonshineService._internal();
  factory MoonshineService() => _instance;

  static const String _archiveName =
      'sherpa-onnx-moonshine-tiny-en-int8.tar.bz2';
  static const String _downloadUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-moonshine-tiny-en-int8.tar.bz2';
  static const String _extractDirName = 'sherpa-onnx-moonshine-tiny-en-int8';

  OfflineRecognizer? _recognizer;
  String? _modelRoot;
  final StreamController<ModelProgress> _progress =
      StreamController<ModelProgress>.broadcast();
  Future<String>? _downloadFuture;

  String get modelName => 'moonshine-tiny-en';
  Stream<ModelProgress> get progress => _progress.stream;

  void _emit(ModelProgress progress) {
    if (_progress.isClosed) return;
    _progress.add(progress);
  }

  Future<Directory> _rootDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'moonshine_models'))
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

  String? _findPath(
    List<FileSystemEntity> files,
    List<String> keywords, {
    bool mustBeOnnx = false,
  }) {
    for (final entity in files) {
      if (entity is! File) continue;
      final path = entity.path.toLowerCase();
      final fileName = p.basename(path);
      final words = fileName
          .split(RegExp(r'[^a-z0-9]+'))
          .where((part) => part.isNotEmpty)
          .toSet();
      if (mustBeOnnx && !path.endsWith('.onnx')) continue;
      if (keywords.every((k) => words.contains(k.toLowerCase()))) {
        return entity.path;
      }
    }
    return null;
  }

  Map<String, String> _discoverMoonshineFiles(String root) {
    final files = _listFiles(root);
    final preprocessor =
        _findPath(files, ['preprocess'], mustBeOnnx: true) ??
        _findPath(files, ['preprocessor'], mustBeOnnx: true) ??
        '';
    final encoder =
        _findPath(files, ['encoder'], mustBeOnnx: true) ??
        _findPath(files, ['encode'], mustBeOnnx: true) ??
        '';
    final uncachedDecoder =
        _findPath(files, ['uncached', 'decode'], mustBeOnnx: true) ??
        _findPath(files, ['uncached', 'decoder'], mustBeOnnx: true) ??
        '';
    final cachedDecoder =
        _findPath(files, ['cached', 'decode'], mustBeOnnx: true) ??
        _findPath(files, ['cached', 'decoder'], mustBeOnnx: true) ??
        '';
    final tokens =
        _findPath(files, ['tokens']) ?? _findPath(files, ['vocab']) ?? '';

    return {
      'preprocessor': preprocessor,
      'encoder': encoder,
      'uncachedDecoder': uncachedDecoder,
      'cachedDecoder': cachedDecoder,
      'tokens': tokens,
    };
  }

  Future<bool> isModelDownloaded() async {
    final root = await _extractRoot();
    final files = _discoverMoonshineFiles(root);
    final hasV1 = files['preprocessor']!.isNotEmpty &&
        files['encoder']!.isNotEmpty &&
        files['uncachedDecoder']!.isNotEmpty &&
        files['cachedDecoder']!.isNotEmpty;
    return hasV1;
  }

  Future<String> ensureModelDownloaded() async {
    final inFlight = _downloadFuture;
    if (inFlight != null) {
      return inFlight;
    }

    if (await isModelDownloaded()) {
      _emit(
        const ModelProgress(
          downloading: false,
          received: 1,
          total: 1,
          stage: 'ready',
        ),
      );
      return _extractRoot();
    }

    final future = _downloadAndExtract();
    _downloadFuture = future;
    try {
      final root = await future;
      _emit(
        const ModelProgress(
          downloading: false,
          received: 1,
          total: 1,
          stage: 'ready',
        ),
      );
      return root;
    } finally {
      _downloadFuture = null;
    }
  }

  Future<String> _downloadAndExtract() async {
    try {
      _emit(
        const ModelProgress(
          downloading: true,
          received: 0,
          total: 0,
          stage: 'downloading',
        ),
      );

      final archivePath = await _archivePath();
      final archiveFile = File(archivePath);
      if (!archiveFile.existsSync() || archiveFile.lengthSync() < 1024) {
        final client = http.Client();
        try {
          final req = http.Request('GET', Uri.parse(_downloadUrl));
          final resp = await client.send(req);
          if (resp.statusCode != 200) {
            throw HttpException(
              'HTTP ${resp.statusCode} while downloading Moonshine model',
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
                ModelProgress(
                  downloading: true,
                  received: received,
                  total: total,
                  stage: 'downloading',
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
      }

      final root = await _extractRoot();
      _emit(
        const ModelProgress(
          downloading: true,
          received: 1,
          total: 1,
          stage: 'extracting',
        ),
      );
      await _extractArchiveInBackground(archivePath: archivePath, root: root);
      return root;
    } catch (e) {
      _emit(
        ModelProgress(
          downloading: false,
          received: 0,
          total: 0,
          error: e.toString(),
          stage: 'error',
        ),
      );
      rethrow;
    }
  }

  Future<OfflineRecognizer> _loadRecognizer() async {
    initBindings();
    final root = await ensureModelDownloaded();
    if (_recognizer != null && _modelRoot == root) return _recognizer!;

    _recognizer?.free();

    final files = _discoverMoonshineFiles(root);
    final hasV1 =
        files['preprocessor']!.isNotEmpty &&
        files['encoder']!.isNotEmpty &&
        files['uncachedDecoder']!.isNotEmpty &&
        files['cachedDecoder']!.isNotEmpty;

    if (!hasV1) {
      throw StateError(
        'Moonshine model files were not found after extraction at $root',
      );
    }

    final moonshineConfig = OfflineMoonshineModelConfig(
      preprocessor: files['preprocessor'] ?? '',
      encoder: files['encoder'] ?? '',
      uncachedDecoder: files['uncachedDecoder'] ?? '',
      cachedDecoder: files['cachedDecoder'] ?? '',
    );

    final config = OfflineRecognizerConfig(
      feat: const FeatureConfig(sampleRate: 16000, featureDim: 80),
      model: OfflineModelConfig(
        moonshine: moonshineConfig,
        tokens: files['tokens'] ?? '',
        numThreads: 2,
        debug: false,
        provider: 'cpu',
        modelType: 'moonshine',
        modelingUnit: 'bpe',
        bpeVocab: files['tokens'] ?? '',
      ),
      decodingMethod: 'greedy_search',
      maxActivePaths: 4,
      blankPenalty: 0.0,
    );

    _recognizer = OfflineRecognizer(config);
    _modelRoot = root;
    return _recognizer!;
  }

  Future<String> transcribeWav({
    required String wavPath,
    required String lang,
    bool translateToEnglish = false,
    bool noTimestamps = false,
    bool splitOnWord = true,
    bool diarize = false,
  }) async {
    final recognizer = await _loadRecognizer();
    final wave = readWaveSimple(wavPath);
    if (wave.sampleRate != 16000) {
      throw UnsupportedError('Moonshine expects 16k WAV input.');
    }

    final stream = recognizer.createStream();
    stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
    recognizer.decode(stream);
    final result = recognizer.getResult(stream);
    stream.free();

    return result.text.trim();
  }

  void dispose() {
    _recognizer?.free();
    _recognizer = null;
    _modelRoot = null;
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
}
