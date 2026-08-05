import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'transcript/transcription_models.dart';

enum AsrModel {
  sherpaOnnxTiny('sherpa-onnx-whisper-tiny');

  const AsrModel(this.name);
  final String name;
}

class _AsrModelPaths {
  final String encoder;
  final String decoder;
  final String tokens;

  const _AsrModelPaths({
    required this.encoder,
    required this.decoder,
    required this.tokens,
  });
}

class AsrService {
  static const AsrModel _defaultModel = AsrModel.sherpaOnnxTiny;
  static const String _assetModelDir =
      'assets/models/whisper/sherpa-onnx-whisper-tiny';

  static bool _bindingsInitialized = false;
  Isolate? _workerIsolate;
  SendPort? _workerSendPort;
  ReceivePort? _workerReceivePort;
  int _nextRequestId = 0;
  int _numThreads = mathMin(2, Platform.numberOfProcessors);
  final Map<int, Completer<AsrDecodeResult>> _pendingRequests = {};

  AsrModel get currentModel => _defaultModel;

  void configure({int? numThreads}) {
    if (numThreads == null) return;
    final clamped = numThreads
        .clamp(1, mathMin(4, Platform.numberOfProcessors))
        .toInt();
    if (_numThreads == clamped) return;
    _numThreads = clamped;
  }

  Future<String> transcribeWav({
    required String wavPath,
    required String lang,
    bool translateToEnglish = false,
    bool noTimestamps = false,
    bool splitOnWord = true,
    bool diarize = true,
  }) async {
    final result = await transcribeWavStructured(
      wavPath: wavPath,
      lang: lang,
      translateToEnglish: translateToEnglish,
      noTimestamps: noTimestamps,
      splitOnWord: splitOnWord,
      diarize: diarize,
    );
    return result.text;
  }

  Future<AsrDecodeResult> transcribeWavStructured({
    required String wavPath,
    required String lang,
    bool translateToEnglish = false,
    bool noTimestamps = false,
    bool splitOnWord = true,
    bool diarize = true,
  }) async {
    _ensureBindings();
    final modelPaths = await _ensureModelFilesOnDisk();

    final normalizedLang = lang.trim().toLowerCase();
    final whisperLanguage = normalizedLang.isEmpty || normalizedLang == 'auto'
        ? ''
        : normalizedLang;
    final whisperTask = translateToEnglish ? 'translate' : 'transcribe';

    return _decodeWithWorker(
      wavPath: wavPath,
      encoder: modelPaths.encoder,
      decoder: modelPaths.decoder,
      tokens: modelPaths.tokens,
      whisperLanguage: whisperLanguage,
      whisperTask: whisperTask,
      numThreads: _numThreads,
    );
  }

  Future<AsrDecodeResult> _decodeWithWorker({
    required String wavPath,
    required String encoder,
    required String decoder,
    required String tokens,
    required String whisperLanguage,
    required String whisperTask,
    required int numThreads,
  }) async {
    final sendPort = await _ensureWorker();
    final id = _nextRequestId++;
    final completer = Completer<AsrDecodeResult>();
    _pendingRequests[id] = completer;
    sendPort.send({
      'type': 'decode',
      'id': id,
      'wavPath': wavPath,
      'encoder': encoder,
      'decoder': decoder,
      'tokens': tokens,
      'whisperLanguage': whisperLanguage,
      'whisperTask': whisperTask,
      'numThreads': numThreads,
    });
    return completer.future;
  }

  Future<SendPort> _ensureWorker() async {
    final existing = _workerSendPort;
    if (existing != null) return existing;

    final ready = Completer<SendPort>();
    final receivePort = ReceivePort();
    _workerReceivePort = receivePort;
    receivePort.listen((message) {
      if (message is SendPort) {
        _workerSendPort = message;
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is! Map) return;
      final id = message['id'];
      if (id is! int) return;
      final completer = _pendingRequests.remove(id);
      if (completer == null) return;
      final error = message['error'];
      if (error != null) {
        completer.completeError(Exception(error), StackTrace.current);
      } else {
        completer.complete(AsrDecodeResult.fromJson(message['result']));
      }
    });

    _workerIsolate = await Isolate.spawn(
      _asrWorkerMain,
      receivePort.sendPort,
      debugName: 'SherpaAsrWorker',
    );

    return ready.future;
  }

  void releaseCachedRecognizer() {
    _workerSendPort?.send({'type': 'release'});
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('ASR worker released.'));
      }
    }
    _pendingRequests.clear();
    _workerReceivePort?.close();
    _workerReceivePort = null;
    _workerSendPort = null;
    _workerIsolate?.kill(priority: Isolate.immediate);
    _workerIsolate = null;
  }

  void _ensureBindings() {
    if (_bindingsInitialized) return;
    initBindings();
    _bindingsInitialized = true;
  }

  Future<_AsrModelPaths> _ensureModelFilesOnDisk() async {
    final supportDir = await getApplicationSupportDirectory();
    final modelDir = Directory(
      p.join(supportDir.path, 'models', currentModel.name),
    )..createSync(recursive: true);

    final encoder = await _copyAssetIfMissing(
      assetPath: '$_assetModelDir/tiny-encoder.onnx',
      outputPath: p.join(modelDir.path, 'tiny-encoder.onnx'),
      fallbackAssetPath: '$_assetModelDir/tiny-encoder.int8.onnx',
      fallbackOutputPath: p.join(modelDir.path, 'tiny-encoder.int8.onnx'),
    );
    final decoder = await _copyAssetIfMissing(
      assetPath: '$_assetModelDir/tiny-decoder.onnx',
      outputPath: p.join(modelDir.path, 'tiny-decoder.onnx'),
      fallbackAssetPath: '$_assetModelDir/tiny-decoder.int8.onnx',
      fallbackOutputPath: p.join(modelDir.path, 'tiny-decoder.int8.onnx'),
    );
    final tokens = await _copyRequiredAsset(
      assetPath: '$_assetModelDir/tiny-tokens.txt',
      outputPath: p.join(modelDir.path, 'tiny-tokens.txt'),
    );

    return _AsrModelPaths(encoder: encoder, decoder: decoder, tokens: tokens);
  }

  Future<String> _copyAssetIfMissing({
    required String assetPath,
    required String outputPath,
    String? fallbackAssetPath,
    String? fallbackOutputPath,
  }) async {
    final outFile = File(outputPath);
    if (outFile.existsSync() && outFile.lengthSync() > 0) {
      return outFile.path;
    }

    try {
      return await _copyRequiredAsset(
        assetPath: assetPath,
        outputPath: outputPath,
      );
    } catch (_) {
      if (fallbackAssetPath == null || fallbackOutputPath == null) rethrow;
      return _copyRequiredAsset(
        assetPath: fallbackAssetPath,
        outputPath: fallbackOutputPath,
      );
    }
  }

  Future<String> _copyRequiredAsset({
    required String assetPath,
    required String outputPath,
  }) async {
    final outFile = File(outputPath);
    if (outFile.existsSync() && outFile.lengthSync() > 0) {
      return outFile.path;
    }

    final data = await rootBundle.load(assetPath);
    await outFile.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    return outFile.path;
  }
}

int mathMin(int a, int b) => a < b ? a : b;

void _asrWorkerMain(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  initBindings();
  OfflineRecognizer? recognizer;
  String? recognizerKey;

  OfflineRecognizer recognizerFor({
    required String encoder,
    required String decoder,
    required String tokens,
    required String whisperLanguage,
    required String whisperTask,
    required int numThreads,
  }) {
    final key = [
      encoder,
      decoder,
      tokens,
      whisperLanguage,
      whisperTask,
      numThreads,
    ].join('|');

    final cached = recognizer;
    if (cached != null && recognizerKey == key) return cached;

    recognizer?.free();
    recognizer = OfflineRecognizer(
      OfflineRecognizerConfig(
        model: OfflineModelConfig(
          tokens: tokens,
          // Keep native ASR from starving Android's UI thread on mid-range phones.
          numThreads: numThreads.clamp(1, Platform.numberOfProcessors).toInt(),
          debug: false,
          provider: 'cpu',
          whisper: OfflineWhisperModelConfig(
            encoder: encoder,
            decoder: decoder,
            language: whisperLanguage,
            task: whisperTask,
          ),
        ),
      ),
    );
    recognizerKey = key;
    return recognizer!;
  }

  Map<String, dynamic> decode({
    required String wavPath,
    required String encoder,
    required String decoder,
    required String tokens,
    required String whisperLanguage,
    required String whisperTask,
    required int numThreads,
  }) {
    final wave = readWave(wavPath);
    if (wave.sampleRate != 16000) {
      throw StateError(
        'Expected 16 kHz WAV for sherpa-onnx transcription, got ${wave.sampleRate} Hz.',
      );
    }

    final activeRecognizer = recognizerFor(
      encoder: encoder,
      decoder: decoder,
      tokens: tokens,
      whisperLanguage: whisperLanguage,
      whisperTask: whisperTask,
      numThreads: numThreads,
    );

    final stream = activeRecognizer.createStream();
    try {
      stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
      activeRecognizer.decode(stream);
      final result = activeRecognizer.getResult(stream);
      return {
        'text': result.text.trim(),
        'tokens': result.tokens,
        'timestamps': result.timestamps,
      };
    } finally {
      stream.free();
    }
  }

  receivePort.listen((message) {
    if (message is! Map) return;
    final type = message['type'];
    if (type == 'release') {
      recognizer?.free();
      recognizer = null;
      recognizerKey = null;
      receivePort.close();
      Isolate.exit();
    }
    if (type != 'decode') return;
    final id = message['id'];
    if (id is! int) return;
    try {
      final text = decode(
        wavPath: (message['wavPath'] ?? '').toString(),
        encoder: (message['encoder'] ?? '').toString(),
        decoder: (message['decoder'] ?? '').toString(),
        tokens: (message['tokens'] ?? '').toString(),
        whisperLanguage: (message['whisperLanguage'] ?? '').toString(),
        whisperTask: (message['whisperTask'] ?? '').toString(),
        numThreads: (message['numThreads'] is int)
            ? message['numThreads'] as int
            : 1,
      );
      mainSendPort.send({'id': id, 'result': text});
    } catch (e, st) {
      mainSendPort.send({'id': id, 'error': '$e\n$st'});
    }
  });
}
