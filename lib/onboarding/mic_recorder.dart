// lib/mic_recorder.dart
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

class MicRecorder {
  final AudioRecorder _rec = AudioRecorder();
  String? _path;

  Future<bool> hasPermission() => _rec.hasPermission();

  Future<void> _ensurePermission() async {
    final ok = await hasPermission();
    if (!ok) {
      throw Exception('Microphone permission is required');
    }
  }

  /// Start recording to a timestamped WAV in app documents.
  Future<String> start() async {
    await _ensurePermission();
    final dir = await getApplicationDocumentsDirectory();
    final path =
        '${dir.path}/capture_${DateTime.now().millisecondsSinceEpoch}.wav';
    await startToPath(path);
    return path;
  }

  /// Start recording to a specific path (16kHz mono WAV).
  Future<void> startToPath(String path) async {
    await _ensurePermission();
    await Directory(File(path).parent.path).create(recursive: true);

    await _rec.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
    _path = path;
  }

  /// Pause recording (no-op if not currently recording).
  Future<void> pause() async {
    if (await _rec.isRecording()) {
      await _rec.pause();
    }
  }

  /// Resume recording (no-op if not paused).
  Future<void> resume() async {
    if (await _rec.isPaused()) {
      await _rec.resume();
    }
  }

  /// Convenience: toggle between pause/resume.
  Future<void> togglePause() async {
    if (await _rec.isPaused()) {
      await _rec.resume();
    } else if (await _rec.isRecording()) {
      await _rec.pause();
    }
  }

  /// Stop and return the recorded file path (falls back to cached _path).
  Future<String?> stop() async {
    final p = await _rec.stop();
    return p ?? _path;
  }

  /// Stop and delete the current recording (if any).
  Future<void> cancel() async {
    final p = await stop();
    if (p != null) {
      try {
        await File(p).delete();
      } catch (_) {}
    }
  }

  // State helpers
  Future<bool> get isRecording => _rec.isRecording();
  Future<bool> get isPaused => _rec.isPaused();
  String? get currentPath => _path;
}
