import '../objectbox/entities.dart';
import '../objectbox/objectbox_store.dart';
import '../objectbox.g.dart';

class CorrectionLearningService {
  const CorrectionLearningService();

  void captureTranscriptEdit({
    required int transcriptId,
    required String previousText,
    required String editedText,
    String language = 'en',
  }) {
    final previous = _words(previousText);
    final edited = _words(editedText);
    if (previous.isEmpty || edited.isEmpty) return;

    final change = _singleSpanChange(previous, edited);
    if (change == null) return;

    final observed = previous.sublist(change.oldStart, change.oldEnd).join(' ');
    final replacement = edited
        .sublist(change.newStart, change.newEnd)
        .join(' ');
    if (observed.trim().isEmpty || replacement.trim().isEmpty) return;

    final risky = _isRisky(
      observed,
      replacement,
      previous.length,
      edited.length,
    );
    final obx = ObjectBox.I;
    final box = obx.store.box<CorrectionMappingEntity>();
    final qb = box
        .query(
          CorrectionMappingEntity_.transcriptId
              .equals(transcriptId)
              .and(CorrectionMappingEntity_.observed.equals(observed))
              .and(CorrectionMappingEntity_.replacement.equals(replacement)),
        )
        .build();
    final existing = qb.findFirst();
    qb.close();

    final entity =
        existing ??
        CorrectionMappingEntity(
          transcriptId: transcriptId,
          observed: observed,
          replacement: replacement,
          language: language,
        );
    entity.leftContext = previous
        .sublist(0, change.oldStart)
        .reversed
        .take(4)
        .toList()
        .reversed
        .join(' ');
    entity.rightContext = previous.sublist(change.oldEnd).take(4).join(' ');
    entity.requiresExplicitRemember = risky;
    entity.enabled = !risky;
    entity.confirmationCount += existing == null ? 0 : 1;
    entity.updatedAt = DateTime.now();
    box.put(entity);
  }
}

class _SpanChange {
  const _SpanChange(this.oldStart, this.oldEnd, this.newStart, this.newEnd);
  final int oldStart;
  final int oldEnd;
  final int newStart;
  final int newEnd;
}

_SpanChange? _singleSpanChange(List<String> oldWords, List<String> newWords) {
  var prefix = 0;
  while (prefix < oldWords.length &&
      prefix < newWords.length &&
      oldWords[prefix] == newWords[prefix]) {
    prefix++;
  }
  var oldSuffix = oldWords.length;
  var newSuffix = newWords.length;
  while (oldSuffix > prefix &&
      newSuffix > prefix &&
      oldWords[oldSuffix - 1] == newWords[newSuffix - 1]) {
    oldSuffix--;
    newSuffix--;
  }
  if (oldSuffix == prefix && newSuffix == prefix) return null;
  return _SpanChange(prefix, oldSuffix, prefix, newSuffix);
}

bool _isRisky(String observed, String replacement, int oldLen, int newLen) {
  if ((oldLen - newLen).abs() > 3) return true;
  if (_words(observed).length > 4 || _words(replacement).length > 4) {
    return true;
  }
  final a = observed.toLowerCase();
  final b = replacement.toLowerCase();
  final number = RegExp(r'\d');
  if (number.hasMatch(a) || number.hasMatch(b)) return true;
  const sensitive = {
    'can',
    'cannot',
    "can't",
    'monday',
    'tuesday',
    'no',
    'not',
  };
  return sensitive.contains(a) || sensitive.contains(b);
}

List<String> _words(String text) => RegExp(
  r"[A-Za-z0-9']+",
).allMatches(text.toLowerCase()).map((m) => m.group(0)!).toList();
