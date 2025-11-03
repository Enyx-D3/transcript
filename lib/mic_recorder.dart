// lib/mic_recorder.dart
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';

class MicRecorder {
  final _rec = AudioRecorder();

  Future<bool> hasPermission() => _rec.hasPermission();

  Future<String> start() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/capture.wav';

    await _rec.start(
      const RecordConfig(
        encoder: AudioEncoder.wav, // 16-bit PCM WAV
        sampleRate: 16000,         // 16 kHz (fits whisper.cpp)
        numChannels: 1,            // mono
      ),
      path: path,
    );
    return path;
  }

  Future<String?> stop() => _rec.stop();

  Future<void> cancel() => _rec.cancel();
}
