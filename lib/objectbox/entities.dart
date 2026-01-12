// lib/objectbox/entities.dart
import 'dart:typed_data';
import 'package:objectbox/objectbox.dart';

/// Simple normalizer for case-insensitive matching & uniqueness.
String normalizeName(String s) => s.trim().toLowerCase();

// -------------------- Speaker entities --------------------

@Entity()
class SpeakerProfileEntity {
  int id;

  /// Display name (preserve original casing)
  String name;

  /// Normalized (lowercased/trimmed) name used for lookups & uniqueness.
  @Index()
  @Unique()
  String nameKey;

  @Backlink('speaker')
  final vectors = ToMany<SpeakerVectorEntity>();

  @Property(type: PropertyType.date)
  DateTime createdAt;

  @Property(type: PropertyType.date)
  DateTime updatedAt;

  SpeakerProfileEntity({
    this.id = 0,
    required this.name,
    required this.nameKey,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();
}

@Entity()
class SpeakerVectorEntity {
  int id;

  final speaker = ToOne<SpeakerProfileEntity>();

  /// L2-normalized embedding stored as raw Float32 bytes.
  @Property(type: PropertyType.byteVector)
  Uint8List embedding;

  @Property(type: PropertyType.date)
  DateTime createdAt;

  SpeakerVectorEntity({
    this.id = 0,
    required this.embedding,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
}

// -------------------- Transcript entities (for completeness) --------------------


@Entity()
class TranscriptEntity {
  int id;

  /// Optional title shown in lists.
  @Index()
  String? title;

  /// Whisper/model name and language tag used.
  String model;
  String lang;

  /// Optional original audio file (local path) if you keep it.
  String? audioPath;

  /// Duration in seconds.
  double durationSec;

  /// Optional user-edited transcript text
  String? editedText;

  /// ✅ Cached concatenated transcript text from turns (cleaned)
  String? fullTextCache;

  /// ✅ Search field:
  /// - if editedText exists -> editedText
  /// - else -> fullTextCache
  @Index()
  String? searchText;

  @Backlink('transcript')
  final turns = ToMany<TranscriptTurnEntity>();

  @Property(type: PropertyType.date)
  DateTime createdAt;

  TranscriptEntity({
    this.id = 0,
    this.title,
    required this.model,
    required this.lang,
    this.audioPath,
    required this.durationSec,
    this.editedText,
    this.fullTextCache,
    this.searchText,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
}

@Entity()
class TranscriptTurnEntity {
  int id;

  final transcript = ToOne<TranscriptEntity>();

  String speakerLabel; // snapshot label shown in UI at save time
  double startSec;
  double endSec;
  String text;

  TranscriptTurnEntity({
    this.id = 0,
    required this.speakerLabel,
    required this.startSec,
    required this.endSec,
    required this.text,
  });
}

@Entity()
class TranscriptionJobEntity {
  int id;

  String wavPath;
  bool translateToEnglish;
  String? titleHint;

  /// 'PENDING' | 'RUNNING' | 'DONE' | 'ERROR'
  String status;

  /// Link the job to the placeholder Transcript
  int transcriptId;

  String? error;

  @Property(type: PropertyType.date)
  DateTime createdAt;

  TranscriptionJobEntity({
    this.id = 0,
    required this.wavPath,
    required this.translateToEnglish,
    required this.transcriptId,
    this.titleHint,
    this.status = 'PENDING',
    this.error,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
}

// One summary per transcript. We simply reuse transcriptId as the entity id.
@Entity()
class TranscriptSummaryEntity {
  int id;

  @Index() // helpful when querying by transcriptId
  int transcriptId;

  String summary;
  DateTime updatedAt;

  TranscriptSummaryEntity({
    this.id = 0,
    required this.transcriptId,
    required this.summary,
    required this.updatedAt,
  });
}

// Chat messages for "Ask AI" per transcript.
@Entity()
class TranscriptChatMessageEntity {
  @Id()
  int id;

  @Index()
  int transcriptId;

  bool isUser; // true = user message, false = AI
  String text;
  DateTime createdAt;

  TranscriptChatMessageEntity({
    this.id = 0,
    required this.transcriptId,
    required this.isUser,
    required this.text,
    required this.createdAt,
  });
}

@Entity()
class AiChatMessageEntity {
  @Id()
  int id;

  bool isUser; // true=user, false=assistant
  String text;

  int createdAtMs; // sort key

  AiChatMessageEntity({
    this.id = 0,
    required this.isUser,
    required this.text,
    int? createdAtMs,
  }) : createdAtMs = createdAtMs ?? DateTime.now().millisecondsSinceEpoch;
}