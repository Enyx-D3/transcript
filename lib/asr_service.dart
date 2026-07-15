import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

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

  AsrModel get currentModel => _defaultModel;

  Future<String> transcribeWav({
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

    return Isolate.run(
      () => _decodeWavInWorker(
        wavPath: wavPath,
        encoder: modelPaths.encoder,
        decoder: modelPaths.decoder,
        tokens: modelPaths.tokens,
        whisperLanguage: whisperLanguage,
        whisperTask: whisperTask,
      ),
    );
  }

  void releaseCachedRecognizer() {}

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

String _decodeWavInWorker({
  required String wavPath,
  required String encoder,
  required String decoder,
  required String tokens,
  required String whisperLanguage,
  required String whisperTask,
}) {
  initBindings();

  final wave = readWave(wavPath);
  if (wave.sampleRate != 16000) {
    throw StateError(
      'Expected 16 kHz WAV for sherpa-onnx transcription, got ${wave.sampleRate} Hz.',
    );
  }

  final recognizer = OfflineRecognizer(
    OfflineRecognizerConfig(
      model: OfflineModelConfig(
        tokens: tokens,
        // Keep native ASR from starving Android's UI thread on mid-range phones.
        numThreads: mathMin(2, Platform.numberOfProcessors),
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

  final stream = recognizer.createStream();
  try {
    stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
    recognizer.decode(stream);
    final result = recognizer.getResult(stream);
    return result.text.trim();
  } finally {
    stream.free();
    recognizer.free();
  }
}
