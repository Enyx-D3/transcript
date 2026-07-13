class TranscriptAlignmentResult {
  final String alignedText;
  final double confidence;
  final List<Map<String, dynamic>> disagreementSpans;
  final List<String> uncertainWords;

  const TranscriptAlignmentResult({
    required this.alignedText,
    required this.confidence,
    this.disagreementSpans = const [],
    this.uncertainWords = const [],
  });

  Map<String, dynamic> toJson() => {
    'alignedText': alignedText,
    'confidence': confidence,
    'disagreementSpans': disagreementSpans,
    'uncertainWords': uncertainWords,
  };
}

class TranscriptAlignmentService {
  const TranscriptAlignmentService();

  TranscriptAlignmentResult alignBlock({
    required String language,
    required int blockId,
    required String moonshineText,
    required String sherpaText,
    required String speakerHint,
    required List<String> knownNames,
    required List<String> knownTerms,
  }) {
    final moon = moonshineText.trim();
    final sherpa = sherpaText.trim();

    if (moon.isEmpty && sherpa.isEmpty) {
      return const TranscriptAlignmentResult(alignedText: '', confidence: 0.0);
    }

    if (moon.isEmpty) {
      return TranscriptAlignmentResult(
        alignedText: sherpa,
        confidence: 0.72,
        disagreementSpans: const [],
        uncertainWords: const [],
      );
    }

    if (sherpa.isEmpty) {
      return TranscriptAlignmentResult(
        alignedText: moon,
        confidence: 0.80,
        disagreementSpans: const [],
        uncertainWords: const [],
      );
    }

    if (_normalize(moon) == _normalize(sherpa)) {
      return TranscriptAlignmentResult(
        alignedText: _capitalizeKnownTerms(moon, knownNames, knownTerms),
        confidence: 0.96,
        disagreementSpans: const [],
        uncertainWords: const [],
      );
    }

    final moonWords = moon.split(RegExp(r'\s+'));
    final sherpaWords = sherpa.split(RegExp(r'\s+'));
    final out = <String>[];
    final maxLen = moonWords.length > sherpaWords.length
        ? moonWords.length
        : sherpaWords.length;

    final disagreements = <Map<String, dynamic>>[];
    final uncertain = <String>[];

    for (var i = 0; i < maxLen; i++) {
      final m = i < moonWords.length ? moonWords[i] : '';
      final s = i < sherpaWords.length ? sherpaWords[i] : '';

      if (m.isEmpty && s.isNotEmpty) {
        out.add(s);
        uncertain.add(s);
        disagreements.add({
          'index': i,
          'moonshine': '',
          'sherpa': s,
          'preferred': s,
          'reason': 'moonshine_missing',
        });
        continue;
      }

      if (s.isEmpty && m.isNotEmpty) {
        out.add(m);
        uncertain.add(m);
        disagreements.add({
          'index': i,
          'moonshine': m,
          'sherpa': '',
          'preferred': m,
          'reason': 'sherpa_missing',
        });
        continue;
      }

      if (_normalize(m) == _normalize(s)) {
        out.add(_preferKnownForms(m, s, knownNames, knownTerms));
        continue;
      }

      final mKnown = _isKnownToken(m, knownNames, knownTerms);
      final sKnown = _isKnownToken(s, knownNames, knownTerms);

      final preferred = mKnown && !sKnown
          ? m
          : sKnown && !mKnown
          ? s
          : (s.length >= m.length ? s : m);

      out.add(preferred);
      uncertain.add(preferred);
      disagreements.add({
        'index': i,
        'moonshine': m,
        'sherpa': s,
        'preferred': preferred,
        'reason': mKnown || sKnown ? 'known_vocabulary' : 'literal_length',
      });
    }

    final aligned = _cleanup(out.join(' '));
    final confidence = _confidenceScore(
      moon: moon,
      sherpa: sherpa,
      aligned: aligned,
      knownNames: knownNames,
      knownTerms: knownTerms,
    );

    return TranscriptAlignmentResult(
      alignedText: _capitalizeKnownTerms(aligned, knownNames, knownTerms),
      confidence: confidence,
      disagreementSpans: disagreements,
      uncertainWords: uncertain,
    );
  }

  String _normalize(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  String _cleanup(String s) {
    var out = s.trim();
    out = out.replaceAll(RegExp(r'\s+([,.!?;:])'), r'$1');
    out = out.replaceAll(RegExp(r'\s+'), ' ');
    return out.trim();
  }

  bool _isKnownToken(
    String token,
    List<String> knownNames,
    List<String> knownTerms,
  ) {
    final t = token.toLowerCase();
    return knownNames.any((e) => e.toLowerCase() == t) ||
        knownTerms.any((e) => e.toLowerCase() == t);
  }

  String _preferKnownForms(
    String moon,
    String sherpa,
    List<String> knownNames,
    List<String> knownTerms,
  ) {
    for (final known in [...knownNames, ...knownTerms]) {
      if (known.toLowerCase() == moon.toLowerCase() ||
          known.toLowerCase() == sherpa.toLowerCase()) {
        return known;
      }
    }
    return moon;
  }

  String _capitalizeKnownTerms(
    String text,
    List<String> knownNames,
    List<String> knownTerms,
  ) {
    var out = text;
    for (final known in [...knownNames, ...knownTerms]) {
      if (known.trim().isEmpty) continue;
      final pattern = RegExp(
        r'\b' + RegExp.escape(known.trim()) + r'\b',
        caseSensitive: false,
      );
      out = out.replaceAllMapped(pattern, (_) => known.trim());
    }
    return out;
  }

  double _confidenceScore({
    required String moon,
    required String sherpa,
    required String aligned,
    required List<String> knownNames,
    required List<String> knownTerms,
  }) {
    var score = 0.6;
    if (_normalize(moon) == _normalize(sherpa)) score += 0.25;
    if (aligned.isNotEmpty) score += 0.05;

    final knownHits = [...knownNames, ...knownTerms]
        .where(
          (k) =>
              k.isNotEmpty && aligned.toLowerCase().contains(k.toLowerCase()),
        )
        .length;
    score += (knownHits * 0.02).clamp(0.0, 0.1);

    return score.clamp(0.0, 0.99);
  }
}
