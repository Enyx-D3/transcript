// lib/whisper_service.dart
import 'dart:io';
import 'package:whisper_flutter_new/whisper_flutter_new.dart';

class WhisperService {
  Whisper? _whisper;

  Future<void> init({model}) async {
    // You can swap downloadHost to your own mirror / cache
    _whisper = Whisper(
      model: model,
      downloadHost: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main',
    );
    await _whisper!.getVersion(); // warms up / ensures bridge is ready
  }

  bool get isReady => _whisper != null;

  Future<String> transcribeWav({
    required String wavPath,
    bool translateToEnglish = false,
    bool noTimestamps = false,
    bool splitOnWord = true,
    bool diarize = true
  }) async {
    final f = File(wavPath);
    if (!f.existsSync()) {
      throw Exception('Audio file missing at $wavPath');
    }
    final transcript = await _whisper!.transcribe(
      transcribeRequest: TranscribeRequest(
        audio: wavPath,
        isTranslate: translateToEnglish,
        isNoTimestamps: noTimestamps,
        splitOnWord: splitOnWord,
        diarize: diarize
      ),
    );
    return transcript.text;
  }
}
