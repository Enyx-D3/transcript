import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Native audio converter service.
/// 
/// Uses platform-specific implementations to convert audio/video files
/// to 16kHz mono PCM WAV format suitable for Whisper transcription.
class AudioConverterService {
  static const _channel = MethodChannel('com.enyxd.transcript/audio_converter');

  /// Convert audio/video file to 16kHz mono WAV.
  /// 
  /// [inputPath] - Path to input audio or video file
  /// [outputPath] - Optional custom output path. If null, generates one.
  /// 
  /// Returns path to the converted WAV file.
  /// Throws [AudioConversionException] on failure.
  static Future<String> convertToWav16kMono(
    String inputPath, {
    String? outputPath,
  }) async {
    // Generate output path if not provided
    final outPath = outputPath ?? await _generateOutputPath('import');

    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      return _convertNative(inputPath, outPath);
    } else {
      throw AudioConversionException('Platform not supported');
    }
  }

  static Future<String> _convertNative(String inputPath, String outputPath) async {
    try {
      final result = await _channel.invokeMethod<String>('convertToWav16kMono', {
        'inputPath': inputPath,
        'outputPath': outputPath,
      });

      if (result == null) {
        throw AudioConversionException('Conversion returned null');
      }

      if (!File(result).existsSync()) {
        throw AudioConversionException('Output file not created');
      }

      return result;
    } on PlatformException catch (e) {
      throw AudioConversionException('${e.code}: ${e.message}');
    }
  }

  static Future<String> _generateOutputPath(String prefix) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/recordings')
      ..createSync(recursive: true);
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    return '${dir.path}/${prefix}_$ts.wav';
  }
}

/// Exception thrown when audio conversion fails.
class AudioConversionException implements Exception {
  final String message;
  AudioConversionException(this.message);

  @override
  String toString() => 'AudioConversionException: $message';
}
