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
  String? processedAudioPath; // ✅ add

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

  /// 0 = voice, 1 = youtube (future: add more sources)
@Index()
int sourceType;

/// If sourceType==1 (youtube), this links to YoutubeTranscriptMetaEntity.id
@Index()
int? youtubeMetaId;

@Index()
bool isFavourite; // ✅ default false

/// Optional convenience for sorting/recency for youtube items too
@Property(type: PropertyType.date)
DateTime updatedAt;

@Index()
bool isDeleted; // soft delete flag

@Property(type: PropertyType.date)
DateTime? deletedAt; // when moved to trash



TranscriptEntity({
  this.id = 0,
  this.title,
  required this.model,
  required this.lang,
  this.sourceType = 0,      // ✅ default voice
  this.youtubeMetaId,
  this.audioPath,
  this.processedAudioPath,
  required this.durationSec,
  this.editedText,
  this.fullTextCache,
  this.searchText,
  DateTime? createdAt,
  DateTime? updatedAt,
  this.isFavourite = false,
  this.isDeleted = false,
  this.deletedAt,
})  : createdAt = createdAt ?? DateTime.now(),
      updatedAt = updatedAt ?? DateTime.now();
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

@Entity()
class YoutubeTranscriptMetaEntity {
  @Id()
  int id = 0;

  /// Unique so we can upsert by videoId
  @Unique()
  String videoId;

  /// what user pasted
  String inputUrl;

  /// normalized url
  String canonicalUrl;

  /// optional fields (use later if you fetch video info)
  String? title;
  String? channel;

  int createdAtMs;
  int updatedAtMs;

  @Backlink()
  final transcripts = ToMany<YoutubeTranscriptTextEntity>();

  YoutubeTranscriptMetaEntity({
    required this.videoId,
    required this.inputUrl,
    required this.canonicalUrl,
    this.title,
    this.channel,
    int? createdAtMs,
    int? updatedAtMs,
  })  : createdAtMs = createdAtMs ?? DateTime.now().millisecondsSinceEpoch,
        updatedAtMs = updatedAtMs ?? DateTime.now().millisecondsSinceEpoch;
}

@Entity()
class YoutubeTranscriptTextEntity {
  @Id()
  int id = 0;

  /// link back to meta
  final meta = ToOne<YoutubeTranscriptMetaEntity>();

  String? language;
  String? languageCode;

  /// true = auto generated, false = manual
  bool isGenerated;

  /// transcript text
  String text;

  int fetchedAtMs;

  YoutubeTranscriptTextEntity({
    this.language,
    this.languageCode,
    required this.isGenerated,
    required this.text,
    int? fetchedAtMs,
  }) : fetchedAtMs = fetchedAtMs ?? DateTime.now().millisecondsSinceEpoch;
}