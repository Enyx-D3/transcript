import '../objectbox.g.dart';
import 'entities.dart';

class ObjectBox {
  static late ObjectBox I;
  static bool _isReady = false;

  late final Store store;

  // Existing boxes
  late final Box<SpeakerProfileEntity> speakers;
  late final Box<SpeakerVectorEntity> vectors;

  // New boxes
  late final Box<TranscriptEntity> transcripts;
  late final Box<TranscriptTurnEntity> turns;
  late final Box<TranscriptionJobEntity> jobs;
  late final Box<TranscriptSummaryEntity> summaries;

  // Existing transcript-related chat messages (keep as-is)
  late final Box<TranscriptChatMessageEntity> chatMessages;

  // ✅ NEW: AI chat tab messages (single-thread)
  late final Box<AiChatMessageEntity> aiChatMessages;

  // ✅ NEW: YouTube transcript boxes
  late final Box<YoutubeTranscriptMetaEntity> ytMeta;
  late final Box<YoutubeTranscriptTextEntity> ytTexts;

  ObjectBox._create(this.store) {
    speakers = Box<SpeakerProfileEntity>(store);
    vectors = Box<SpeakerVectorEntity>(store);

    transcripts = Box<TranscriptEntity>(store);
    turns = Box<TranscriptTurnEntity>(store);
    jobs = Box<TranscriptionJobEntity>(store);
    summaries = Box<TranscriptSummaryEntity>(store);

    chatMessages = Box<TranscriptChatMessageEntity>(store);

    aiChatMessages = Box<AiChatMessageEntity>(store);

    // ✅ init youtube boxes
    ytMeta = Box<YoutubeTranscriptMetaEntity>(store);
    ytTexts = Box<YoutubeTranscriptTextEntity>(store);
  }

  static Future<void> init() async {
    if (_isReady) return;
    final store = await openStore();
    I = ObjectBox._create(store);
    _isReady = true;
  }

  static Future<String> dbPath() async {
    if (!_isReady) await init();
    return I.store.directoryPath;
  }

  Future<void> clearAllData() async {
    store.runInTransaction(TxMode.write, () {
      // ✅ include AI chat too (optional but recommended)
      aiChatMessages.removeAll();

      // ✅ include youtube too (optional)
      ytTexts.removeAll();
      ytMeta.removeAll();

      chatMessages.removeAll();
      summaries.removeAll();
      jobs.removeAll();
      turns.removeAll();
      transcripts.removeAll();
      vectors.removeAll();
      speakers.removeAll();
    });
  }

  // -------------------------
  // ✅ AI CHAT HELPERS
  // -------------------------

  List<AiChatMessageEntity> loadAiChat({int limit = 2000}) {
    final qb = aiChatMessages.query()..order(AiChatMessageEntity_.createdAtMs);
    final q = qb.build();

    q.limit = limit;
    final res = q.find();

    q.close();
    return res;
  }

  int addAiChatMessage({required bool isUser, required String text}) {
    return aiChatMessages.put(AiChatMessageEntity(isUser: isUser, text: text));
  }

  void updateAiChatMessage(int id, String text) {
    final m = aiChatMessages.get(id);
    if (m == null) return;
    m.text = text;
    aiChatMessages.put(m);
  }

  void clearAiChat() {
    aiChatMessages.removeAll();
  }

  // -------------------------
  // ✅ YOUTUBE TRANSCRIPT HELPERS
  // -------------------------

  /// Save/replace transcripts for a videoId.
  /// - Upserts meta by unique videoId
  /// - Deletes old transcript rows for that meta id
  /// - Inserts new transcript rows
  int saveYoutubeTranscripts({
    required String videoId,
    required String inputUrl,
    required List<YoutubeTranscriptTextPayload> manual,
    required List<YoutubeTranscriptTextPayload> auto,
  }) {
    final canonicalUrl = 'https://www.youtube.com/watch?v=$videoId';

    return store.runInTransaction(TxMode.write, () {
      // find existing meta by unique videoId
      final q = ytMeta
          .query(YoutubeTranscriptMetaEntity_.videoId.equals(videoId))
          .build();
      final existing = q.findFirst();
      q.close();

      final meta = existing ??
          YoutubeTranscriptMetaEntity(
            videoId: videoId,
            inputUrl: inputUrl,
            canonicalUrl: canonicalUrl,
          );

      meta
        ..inputUrl = inputUrl
        ..canonicalUrl = canonicalUrl
        ..updatedAtMs = DateTime.now().millisecondsSinceEpoch;

      final metaId = ytMeta.put(meta);

      // remove old texts for this meta
      final tq = ytTexts
          .query(YoutubeTranscriptTextEntity_.meta.equals(metaId))
          .build();
      final oldIds = tq.findIds();
      tq.close();
      if (oldIds.isNotEmpty) ytTexts.removeMany(oldIds);

      // insert new texts
      final all = <YoutubeTranscriptTextPayload>[...manual, ...auto];

      for (final t in all) {
        final e = YoutubeTranscriptTextEntity(
          language: t.language,
          languageCode: t.languageCode,
          isGenerated: t.isGenerated,
          text: t.text,
        );
        e.meta.targetId = metaId;
        ytTexts.put(e);
      }

      return metaId;
    });
  }

  /// Load saved videos (newest first)
  List<YoutubeTranscriptMetaEntity> loadYoutubeMetas({int limit = 200}) {
    final qb = ytMeta.query()
      ..order(YoutubeTranscriptMetaEntity_.updatedAtMs, flags: Order.descending);
    final q = qb.build();
    q.limit = limit;
    final res = q.find();
    q.close();
    return res;
  }

  /// Load transcript texts for a saved video metaId
  List<YoutubeTranscriptTextEntity> loadYoutubeTexts(int metaId) {
    final qb = ytTexts
        .query(YoutubeTranscriptTextEntity_.meta.equals(metaId))
      ..order(YoutubeTranscriptTextEntity_.isGenerated)
      ..order(YoutubeTranscriptTextEntity_.languageCode);
    final q = qb.build();
    final res = q.find();
    q.close();
    return res;
  }

  /// Delete one saved video + all transcripts
  void deleteYoutubeMeta(int metaId) {
    store.runInTransaction(TxMode.write, () {
      final tq = ytTexts
          .query(YoutubeTranscriptTextEntity_.meta.equals(metaId))
          .build();
      final ids = tq.findIds();
      tq.close();
      if (ids.isNotEmpty) ytTexts.removeMany(ids);
      ytMeta.remove(metaId);
    });
  }
}

/// Simple payload class used when saving from UI (not an entity)
class YoutubeTranscriptTextPayload {
  final String? language;
  final String? languageCode;
  final bool isGenerated;
  final String text;

  YoutubeTranscriptTextPayload({
    required this.language,
    required this.languageCode,
    required this.isGenerated,
    required this.text,
  });
}
