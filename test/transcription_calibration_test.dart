import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:transcript/transcript/transcription_calibration.dart';
import 'package:transcript/transcript/transcription_models.dart';

void main() {
  group('AsrDecodeResult', () {
    test('round trips map data', () {
      const result = AsrDecodeResult(
        text: 'hello world',
        tokens: ['hello', 'world'],
        timestamps: [0.1, 0.4],
      );

      final decoded = AsrDecodeResult.fromJson(result.toJson());

      expect(decoded.text, 'hello world');
      expect(decoded.tokens, ['hello', 'world']);
      expect(decoded.timestamps, [0.1, 0.4]);
    });

    test('supports legacy string and missing token data', () {
      expect(AsrDecodeResult.fromJson('plain text').text, 'plain text');

      final decoded = AsrDecodeResult.fromJson({'text': 'no timing'});
      expect(decoded.tokens, isEmpty);
      expect(decoded.timestamps, isEmpty);
    });

    test('does not turn subword tokens into word events', () {
      final decoded = AsrDecodeResult.fromJson({
        'text': 'possible',
        'tokens': ['pos', 'sible'],
        'timestamps': [0.1, 0.2],
      });

      final calibrated = TranscriptionCalibrator().calibrate(
        input: TranscriptionResult(
          model: 'test',
          lang: 'en',
          durationSec: 1,
          title: null,
          turns: [LiteTurn('S1', 0, 1, decoded.text)],
        ),
      );

      expect(calibrated.instrumentation['total_words'], 1);
    });
  });

  group('TranscriptionCalibrator', () {
    test('preserves raw and writes calibrated text', () {
      final result = _calibrate('would it be priceable');

      expect(result.result.rawText, 'would it be priceable');
      expect(result.result.calibratedText, 'Would it be possible');
      expect(result.result.turns.single.rawText, 'would it be priceable');
      expect(result.result.turns.single.calibratedText, 'Would it be possible');
    });

    test('repairs adjacent suffix prefix duplicate and audits it', () {
      final result = TranscriptionCalibrator().calibrate(
        input: TranscriptionResult(
          model: 'test',
          lang: 'en',
          durationSec: 4,
          title: null,
          turns: [
            LiteTurn(
              'S1',
              0,
              2,
              "I need to call my mom. She's waiting for me.",
            ),
            LiteTurn('S1', 1.9, 4, "She's waiting for me. I will be late."),
          ],
        ),
      );

      expect(result.result.turns, hasLength(1));
      expect(
        result.result.turns.single.text,
        "I need to call my mom. She's waiting for me. I will be late.",
      );
      expect(result.audit.single['type'], 'duplicate_removal');
    });

    test('keeps possible names when there is no candidate evidence', () {
      final result = _calibrate('Science will join tomorrow');

      expect(result.result.calibratedText, 'Science will join tomorrow');
      expect(result.instrumentation['possible_name_slots'], 1);
      expect(result.instrumentation['preserved_uncertain_spans'], 1);
    });

    test('allows possible-name correction only from supplied context', () {
      final result = _calibrate(
        'Tonight said no. Tom said yes.',
        vocabulary: {'Tom'},
      );

      expect(result.result.calibratedText, 'Tom said no. Tom said yes.');
    });

    test('does not corrupt sensitive negations', () {
      final result = _calibrate('I can not approve this');

      expect(result.result.calibratedText, 'I can not approve this');
    });

    test('limits candidate cloud and records scores', () {
      final result = _calibrate('you are a safe saver');
      final audit = jsonDecode(result.result.calibrationAuditJson!) as List;

      expect(result.result.calibratedText, 'You are a lifesaver');
      expect(audit.first['winning_score'], isA<int>());
      expect(audit.first['margin'], isA<int>());
    });
  });
}

CalibrationResult _calibrate(String text, {Set<String> vocabulary = const {}}) {
  return TranscriptionCalibrator(optionalVocabulary: vocabulary).calibrate(
    input: TranscriptionResult(
      model: 'test',
      lang: 'en',
      durationSec: 10,
      title: null,
      turns: [LiteTurn('S1', 0, 10, text)],
    ),
  );
}
