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

  ObjectBox._create(this.store) {
    speakers = Box<SpeakerProfileEntity>(store);
    vectors = Box<SpeakerVectorEntity>(store);

    transcripts = Box<TranscriptEntity>(store);
    turns = Box<TranscriptTurnEntity>(store);
    jobs = Box<TranscriptionJobEntity>(store);
    summaries = Box<TranscriptSummaryEntity>(store);

    chatMessages = Box<TranscriptChatMessageEntity>(store);

    // ✅ new box init
    aiChatMessages = Box<AiChatMessageEntity>(store);
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

  q.limit = limit; // ✅ correct way (no named parameter)
  final res = q.find();

  q.close();
  return res;
}

  int addAiChatMessage({required bool isUser, required String text}) {
    return aiChatMessages.put(
      AiChatMessageEntity(isUser: isUser, text: text),
    );
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
}
