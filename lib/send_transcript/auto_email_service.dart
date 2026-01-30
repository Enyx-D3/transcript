import 'package:shared_preferences/shared_preferences.dart';
import '../objectbox/objectbox_store.dart';
import '../send_transcript/send_transcript_healper.dart';
import '../objectbox/entities.dart';
import '../objectbox.g.dart';

class AutoEmailService {
  // Must match Settings key
  static const String kPrefAutoEmailTranscript = 'pref_auto_email_transcript';

  static const String _kAutoEmailSentPrefix = 'auto_email_sent_';

  static Future<bool> _enabled() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(kPrefAutoEmailTranscript) ?? false;
  }

  static Future<bool> _alreadySent(int transcriptId) async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool('$_kAutoEmailSentPrefix$transcriptId') ?? false;
  }

  static Future<void> _markSent(int transcriptId) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('$_kAutoEmailSentPrefix$transcriptId', true);
  }

  static String _buildTxtFromTurns(int transcriptId) {
    final obx = ObjectBox.I;

    final qb = obx.turns.query(
      TranscriptTurnEntity_.transcript.equals(transcriptId),
    )..order(TranscriptTurnEntity_.startSec);

    final q = qb.build();
    final rows = q.find();
    q.close();

    final b = StringBuffer();
    for (final u in rows) {
      final speaker = u.speakerLabel.trim();
      final text = u.text.trim();
      if (text.isEmpty) continue;
      b.writeln('$speaker: $text');
    }
    return b.toString().trim();
  }


  /// Call this right after persistence when transcription completes.
  /// Works even if UI is not open.
  static Future<void> sendIfEnabled({
    required int transcriptId,
    required TranscriptMailService mailer,
  }) async {
    // setting gate
    if (!await _enabled()) return;

    // sent-once gate
    if (await _alreadySent(transcriptId)) return;

    final obx = ObjectBox.I;
    final t = obx.transcripts.get(transcriptId);
    final title = (t?.title ?? 'transcript').trim();
    final safeTitle = title.isEmpty ? 'transcript' : title;

    final txt = _buildTxtFromTurns(transcriptId);
    if (txt.isEmpty) return;

    // attach file name
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final filename = '$safeTitle-$stamp.txt';

    // Send -> this becomes a REAL txt attachment in your Netlify function
    await mailer.sendTxtAttachment(
      txt: txt,
      filename: filename,
      meta: {
        'source': 'auto_email_bg_completion',
        'transcriptId': transcriptId,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'title': safeTitle,
      },
    );

    await _markSent(transcriptId);
  }
}
