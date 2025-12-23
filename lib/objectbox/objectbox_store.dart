// lib/objectbox/objectbox_store.dart
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
  late final Box<TranscriptChatMessageEntity> chatMessages;
  ObjectBox._create(this.store) {
    speakers = Box<SpeakerProfileEntity>(store);
    vectors = Box<SpeakerVectorEntity>(store);
    transcripts = Box<TranscriptEntity>(store);
    turns = Box<TranscriptTurnEntity>(store);
    jobs = Box<TranscriptionJobEntity>(store); 
    summaries =  Box<TranscriptSummaryEntity>(store);
    chatMessages = Box<TranscriptChatMessageEntity>(store);
  }

  static Future<void> init() async {
    if (_isReady) return;
    final store = await openStore(); // from generated objectbox.g.dart
    I = ObjectBox._create(store);
    _isReady = true;
  }

  /// Returns the absolute directory path where ObjectBox stores its data.
  static Future<String> dbPath() async {
    if (!_isReady) await init();
    return I.store.directoryPath; // <-- use Store.directoryPath
  }

 Future<void> clearAllData() async {
  store.runInTransaction(TxMode.write, () {
    chatMessages.removeAll();
    summaries.removeAll();
    jobs.removeAll();
    turns.removeAll();
    transcripts.removeAll();
    vectors.removeAll();
    speakers.removeAll();
  });
}
}
