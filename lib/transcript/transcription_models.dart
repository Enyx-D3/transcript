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

  static LiteTurn fromJson(Map<String, dynamic> j) {
    final rawStart = j['startSec'] ?? j['start_sec'] ?? j['start'] ?? 0.0;
    final rawEnd = j['endSec'] ?? j['end_sec'] ?? j['end'] ?? 0.0;

    final start = rawStart is num
        ? rawStart.toDouble()
        : double.tryParse('$rawStart') ?? 0.0;
    final end = rawEnd is num
        ? rawEnd.toDouble()
        : double.tryParse('$rawEnd') ?? 0.0;

    return LiteTurn(
      (j['speaker'] ?? 'Speaker').toString(),
      start,
      end,
      (j['text'] ?? '').toString(),
    );
  }
}

class SpeakerTurnDetail {
  final String speakerId;
  final String speakerLabel;
  final double startSec;
  final double endSec;
  final double confidence;
  final String matchSource;
  final String? matchedName;
  final String? note;

  const SpeakerTurnDetail({
    required this.speakerId,
    required this.speakerLabel,
    required this.startSec,
    required this.endSec,
    required this.confidence,
    required this.matchSource,
    this.matchedName,
    this.note,
  });

  Map<String, dynamic> toJson() => {
    'speakerId': speakerId,
    'speakerLabel': speakerLabel,
    'startSec': startSec,
    'endSec': endSec,
    'confidence': confidence,
    'matchSource': matchSource,
    if (matchedName != null) 'matchedName': matchedName,
    if (note != null) 'note': note,
  };

  static SpeakerTurnDetail fromJson(Map<String, dynamic> j) =>
      SpeakerTurnDetail(
        speakerId: (j['speakerId'] ?? j['speaker'] ?? '').toString(),
        speakerLabel: (j['speakerLabel'] ?? j['speaker'] ?? '').toString(),
        startSec: (j['startSec'] as num).toDouble(),
        endSec: (j['endSec'] as num).toDouble(),
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0.0,
        matchSource: (j['matchSource'] ?? 'heuristic').toString(),
        matchedName: (j['matchedName'] as String?)?.trim().isEmpty ?? true
            ? null
            : (j['matchedName'] as String).trim(),
        note: (j['note'] as String?)?.trim().isEmpty ?? true
            ? null
            : (j['note'] as String).trim(),
      );
}

class TranscriptBlockSnapshot {
  final String meetingId;
  final int blockId;
  final String language;
  final double startSec;
  final double endSec;
  final String speakerId;
  final String speakerLabel;
  final String rawText;
  final String? alignedText;
  final String? finalText;
  final String status;
  final double confidence;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<SpeakerTurnDetail> speakerDetails;
  final Map<String, dynamic> metadata;

  const TranscriptBlockSnapshot({
    required this.meetingId,
    required this.blockId,
    required this.language,
    required this.startSec,
    required this.endSec,
    required this.speakerId,
    required this.speakerLabel,
    required this.rawText,
    required this.status,
    required this.confidence,
    required this.createdAt,
    required this.updatedAt,
    this.alignedText,
    this.finalText,
    this.speakerDetails = const [],
    this.metadata = const {},
  });

  String get displayText => (finalText ?? alignedText ?? rawText).trim();

  TranscriptBlockSnapshot copyWith({
    String? meetingId,
    int? blockId,
    String? language,
    double? startSec,
    double? endSec,
    String? speakerId,
    String? speakerLabel,
    String? rawText,
    String? alignedText,
    String? finalText,
    String? status,
    double? confidence,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<SpeakerTurnDetail>? speakerDetails,
    Map<String, dynamic>? metadata,
  }) {
    return TranscriptBlockSnapshot(
      meetingId: meetingId ?? this.meetingId,
      blockId: blockId ?? this.blockId,
      language: language ?? this.language,
      startSec: startSec ?? this.startSec,
      endSec: endSec ?? this.endSec,
      speakerId: speakerId ?? this.speakerId,
      speakerLabel: speakerLabel ?? this.speakerLabel,
      rawText: rawText ?? this.rawText,
      alignedText: alignedText ?? this.alignedText,
      finalText: finalText ?? this.finalText,
      status: status ?? this.status,
      confidence: confidence ?? this.confidence,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      speakerDetails: speakerDetails ?? this.speakerDetails,
      metadata: metadata ?? this.metadata,
    );
  }

  Map<String, dynamic> toJson() => {
    'meetingId': meetingId,
    'blockId': blockId,
    'language': language,
    'startSec': startSec,
    'endSec': endSec,
    'speakerId': speakerId,
    'speakerLabel': speakerLabel,
    'rawText': rawText,
    'alignedText': alignedText,
    'finalText': finalText,
    'status': status,
    'confidence': confidence,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'speakerDetails': speakerDetails.map((e) => e.toJson()).toList(),
    'metadata': metadata,
  };

  static TranscriptBlockSnapshot fromJson(
    Map<String, dynamic> j,
  ) => TranscriptBlockSnapshot(
    meetingId: (j['meetingId'] ?? '').toString(),
    blockId: (j['blockId'] as num?)?.toInt() ?? 0,
    language: (j['language'] ?? 'en').toString(),
    startSec: (j['startSec'] as num?)?.toDouble() ?? 0.0,
    endSec: (j['endSec'] as num?)?.toDouble() ?? 0.0,
    speakerId: (j['speakerId'] ?? '').toString(),
    speakerLabel: (j['speakerLabel'] ?? '').toString(),
    rawText: (j['rawText'] ?? '').toString(),
    alignedText: (j['alignedText'] as String?)?.trim().isEmpty ?? true
        ? null
        : (j['alignedText'] as String).trim(),
    finalText: (j['finalText'] as String?)?.trim().isEmpty ?? true
        ? null
        : (j['finalText'] as String).trim(),
    status: (j['status'] ?? 'raw').toString(),
    confidence: (j['confidence'] as num?)?.toDouble() ?? 0.0,
    createdAt:
        DateTime.tryParse((j['createdAt'] ?? '').toString()) ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse((j['updatedAt'] ?? '').toString()) ?? DateTime.now(),
    speakerDetails:
        (j['speakerDetails'] as List<dynamic>?)
            ?.whereType<Map>()
            .map(
              (e) => SpeakerTurnDetail.fromJson(Map<String, dynamic>.from(e)),
            )
            .toList() ??
        const [],
    metadata: (j['metadata'] as Map<String, dynamic>?) ?? const {},
  );
}

class TranscriptionResult {
  final String model;
  final String lang;
  final double durationSec;
  final String? title;
  final List<LiteTurn> turns;
  final List<SpeakerTurnDetail> speakerDetails;
  final List<TranscriptBlockSnapshot> blocks;

  TranscriptionResult({
    required this.model,
    required this.lang,
    required this.durationSec,
    required this.title,
    required this.turns,
    this.speakerDetails = const [],
    this.blocks = const [],
  });

  Map<String, dynamic> toJson() => {
    'model': model,
    'lang': lang,
    'durationSec': durationSec,
    'title': title,
    'turns': turns.map((t) => t.toJson()).toList(),
    'speakerDetails': speakerDetails.map((t) => t.toJson()).toList(),
    'blocks': blocks.map((t) => t.toJson()).toList(),
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
        speakerDetails:
            (j['speakerDetails'] as List<dynamic>?)
                ?.whereType<Map>()
                .map(
                  (e) =>
                      SpeakerTurnDetail.fromJson(Map<String, dynamic>.from(e)),
                )
                .toList() ??
            const [],
        blocks: (j['blocks'] as List<dynamic>?)
                ?.whereType<Map>()
                .map((e) => TranscriptBlockSnapshot.fromJson(
                      Map<String, dynamic>.from(e),
                    ))
                .toList() ??
            const [],
      );
}
