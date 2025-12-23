// lib/transcript/transcription_models.dart

class LiteTurn {
  final String speaker; // final label: alex / bob / s1 / s2 ...
  final double startSec;
  final double endSec;
  final String text;

  LiteTurn(this.speaker, this.startSec, this.endSec, this.text);

  Map<String, dynamic> toJson() => {
        'speaker': speaker,
        'start': startSec,
        'end': endSec,
        'text': text,
      };

  static LiteTurn fromJson(Map<String, dynamic> j) => LiteTurn(
        j['speaker'] as String,
        (j['start'] as num).toDouble(),
        (j['end'] as num).toDouble(),
        j['text'] as String,
      );
}

class TranscriptionResult {
  final String model;
  final String lang;
  final double durationSec;
  final String? title;
  final List<LiteTurn> turns;

  TranscriptionResult({
    required this.model,
    required this.lang,
    required this.durationSec,
    required this.title,
    required this.turns,
  });

  Map<String, dynamic> toJson() => {
        'model': model,
        'lang': lang,
        'durationSec': durationSec,
        'title': title,
        'turns': turns.map((t) => t.toJson()).toList(),
      };

  static TranscriptionResult fromJson(Map<String, dynamic> j) =>
      TranscriptionResult(
        model: j['model'] as String,
        lang: j['lang'] as String,
        durationSec: (j['durationSec'] as num).toDouble(),
        title: j['title'] as String?,
        turns: (j['turns'] as List)
            .map((e) => LiteTurn.fromJson(
                  Map<String, dynamic>.from(e as Map),
                ))
            .toList(),
      );
}
