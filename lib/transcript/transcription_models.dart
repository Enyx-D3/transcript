// lib/transcript/transcription_models.dart

class LiteTurn {
  final String speaker; // final label: alex / bob / s1 / s2 ...
  final double startSec;
  final double endSec;
  final String text;
  final String? rawText;
  final String? calibratedText;
  final String? originalSpeaker;
  final String? calibrationAuditJson;

  LiteTurn(
    this.speaker,
    this.startSec,
    this.endSec,
    this.text, {
    this.rawText,
    this.calibratedText,
    this.originalSpeaker,
    this.calibrationAuditJson,
  });

  Map<String, dynamic> toJson() => {
    'speaker': speaker,
    'start': startSec,
    'end': endSec,
    'text': text,
    if (rawText != null) 'rawText': rawText,
    if (calibratedText != null) 'calibratedText': calibratedText,
    if (originalSpeaker != null) 'originalSpeaker': originalSpeaker,
    if (calibrationAuditJson != null)
      'calibrationAuditJson': calibrationAuditJson,
  };

  static LiteTurn fromJson(Map<String, dynamic> j) => LiteTurn(
    j['speaker'] as String,
    (j['start'] as num).toDouble(),
    (j['end'] as num).toDouble(),
    j['text'] as String,
    rawText: j['rawText'] as String?,
    calibratedText: j['calibratedText'] as String?,
    originalSpeaker: j['originalSpeaker'] as String?,
    calibrationAuditJson: j['calibrationAuditJson'] as String?,
  );
}

class TranscriptionResult {
  final String model;
  final String lang;
  final double durationSec;
  final String? title;
  final List<LiteTurn> turns;
  final String? rawText;
  final String? calibratedText;
  final String? calibrationAuditJson;
  final String? instrumentationJson;

  TranscriptionResult({
    required this.model,
    required this.lang,
    required this.durationSec,
    required this.title,
    required this.turns,
    this.rawText,
    this.calibratedText,
    this.calibrationAuditJson,
    this.instrumentationJson,
  });

  Map<String, dynamic> toJson() => {
    'model': model,
    'lang': lang,
    'durationSec': durationSec,
    'title': title,
    'turns': turns.map((t) => t.toJson()).toList(),
    if (rawText != null) 'rawText': rawText,
    if (calibratedText != null) 'calibratedText': calibratedText,
    if (calibrationAuditJson != null)
      'calibrationAuditJson': calibrationAuditJson,
    if (instrumentationJson != null) 'instrumentationJson': instrumentationJson,
  };

  static TranscriptionResult fromJson(Map<String, dynamic> j) =>
      TranscriptionResult(
        model: j['model'] as String,
        lang: j['lang'] as String,
        durationSec: (j['durationSec'] as num).toDouble(),
        title: j['title'] as String?,
        turns: (j['turns'] as List)
            .map((e) => LiteTurn.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        rawText: j['rawText'] as String?,
        calibratedText: j['calibratedText'] as String?,
        calibrationAuditJson: j['calibrationAuditJson'] as String?,
        instrumentationJson: j['instrumentationJson'] as String?,
      );
}

class AsrDecodeResult {
  const AsrDecodeResult({
    required this.text,
    this.tokens = const [],
    this.timestamps = const [],
  });

  final String text;
  final List<String> tokens;
  final List<double> timestamps;

  Map<String, dynamic> toJson() => {
    'text': text,
    'tokens': tokens,
    'timestamps': timestamps,
  };

  static AsrDecodeResult fromJson(Object? value) {
    if (value is String) return AsrDecodeResult(text: value);
    if (value is! Map) return const AsrDecodeResult(text: '');
    final map = Map<String, dynamic>.from(value);
    return AsrDecodeResult(
      text: (map['text'] ?? '').toString(),
      tokens: (map['tokens'] is List)
          ? (map['tokens'] as List).map((e) => e.toString()).toList()
          : const [],
      timestamps: (map['timestamps'] is List)
          ? (map['timestamps'] as List)
                .whereType<num>()
                .map((e) => e.toDouble())
                .toList()
          : const [],
    );
  }
}
