import 'package:flutter_test/flutter_test.dart';
import 'package:transcript/transcript/transcription_models.dart';

void main() {
  test('TranscriptionResult preserves raw, calibrated, and visible text', () {
    final result = TranscriptionResult(
      model: 'test',
      lang: 'en',
      durationSec: 1,
      title: 'Sample',
      rawText: 'raw',
      calibratedText: 'calibrated',
      turns: [
        LiteTurn(
          'S1',
          0,
          1,
          'visible',
          rawText: 'raw',
          calibratedText: 'calibrated',
        ),
      ],
    );

    final decoded = TranscriptionResult.fromJson(result.toJson());

    expect(decoded.rawText, 'raw');
    expect(decoded.calibratedText, 'calibrated');
    expect(decoded.turns.single.text, 'visible');
  });
}
