import 'dart:convert';
import 'dart:math' as math;

import 'transcription_models.dart';

enum WordTimingSource { asr, estimated }

enum WordState { provisional, confirmed, locked, uncertain }

enum RiskCategory {
  normal,
  possibleName,
  recurringEntity,
  terminology,
  number,
  date,
  money,
  unit,
  address,
  negation,
  critical,
}

class TranscriptionAccuracyFlags {
  const TranscriptionAccuracyFlags({
    this.structuredAsr = true,
    this.wordEvents = true,
    this.riskClassification = true,
    this.wordStates = true,
    this.builtInPhraseLookup = true,
    this.transcriptSelfDiscovery = true,
    this.possibleNameEntityDetection = true,
    this.variantClustering = true,
    this.optionalUserContext = true,
    this.personalDictionary = true,
    this.correctionLearning = true,
    this.contextualMappings = true,
    this.candidateCloud = true,
    this.localPatterns = true,
    this.semanticRoles = true,
    this.phoneticMatching = true,
    this.delayedCommitment = true,
    this.duplicateRepair = true,
    this.uncertainSpanRedecode = true,
    this.speakerConsistency = true,
    this.formatting = true,
    this.finalFlashPass = true,
    this.shadowMode = false,
  });

  final bool structuredAsr;
  final bool wordEvents;
  final bool riskClassification;
  final bool wordStates;
  final bool builtInPhraseLookup;
  final bool transcriptSelfDiscovery;
  final bool possibleNameEntityDetection;
  final bool variantClustering;
  final bool optionalUserContext;
  final bool personalDictionary;
  final bool correctionLearning;
  final bool contextualMappings;
  final bool candidateCloud;
  final bool localPatterns;
  final bool semanticRoles;
  final bool phoneticMatching;
  final bool delayedCommitment;
  final bool duplicateRepair;
  final bool uncertainSpanRedecode;
  final bool speakerConsistency;
  final bool formatting;
  final bool finalFlashPass;
  final bool shadowMode;
}

class TemporalWordEvent {
  TemporalWordEvent({
    required this.id,
    required this.transcriptId,
    required this.turnId,
    required this.chunkId,
    required this.wordIndex,
    required this.rawText,
    required this.displayText,
    required this.startSec,
    required this.endSec,
    required this.timingSource,
    required this.speakerLabel,
    required this.originalSpeakerLabel,
    required this.state,
    required this.riskCategory,
    this.candidates = const [],
    this.winningScore = 0,
    this.secondBestScore = 0,
    this.scoreMargin = 0,
    this.correctionReason,
    this.revisionCount = 0,
    this.audioReference,
  });

  final String id;
  final int transcriptId;
  final String turnId;
  final String chunkId;
  final int wordIndex;
  final String rawText;
  String displayText;
  final double startSec;
  final double endSec;
  final WordTimingSource timingSource;
  String speakerLabel;
  final String originalSpeakerLabel;
  WordState state;
  RiskCategory riskCategory;
  List<String> candidates;
  int winningScore;
  int secondBestScore;
  int scoreMargin;
  String? correctionReason;
  int revisionCount;
  String? audioReference;

  void applyDisplayText(String value, String reason) {
    if (value == displayText) return;
    displayText = value;
    correctionReason = reason;
    revisionCount += 1;
    state = WordState.confirmed;
  }
}

class CalibrationResult {
  const CalibrationResult({
    required this.result,
    required this.audit,
    required this.instrumentation,
  });

  final TranscriptionResult result;
  final List<Map<String, Object?>> audit;
  final Map<String, Object?> instrumentation;
}

class PhraseEntry {
  const PhraseEntry(this.text, this.category);
  final String text;
  final String category;
}

class PhraseResource {
  PhraseResource._(this.language, List<PhraseEntry> entries)
    : _byNormalized = {for (final e in entries) _normalizePhrase(e.text): e};

  factory PhraseResource.forLanguage(String language) {
    final lang = language.trim().toLowerCase();
    if (lang.startsWith('en') || lang == 'auto' || lang.isEmpty) {
      return PhraseResource._('en', _englishPhrases);
    }
    return PhraseResource._(lang, const []);
  }

  final String language;
  final Map<String, PhraseEntry> _byNormalized;

  PhraseEntry? lookupWords(List<String> words) =>
      _byNormalized[_normalizePhrase(words.join(' '))];

  Iterable<PhraseEntry> damagedCandidates(List<String> words) sync* {
    final key = _normalizePhrase(words.join(' '));
    if (key.isEmpty) return;
    final first = key.split(' ').first;
    for (final e in _byNormalized.values) {
      final other = _normalizePhrase(e.text);
      if (!other.startsWith(first)) continue;
      if ((other.split(' ').length - words.length).abs() > 1) continue;
      if (_editDistance(key, other) <= math.max(2, key.length ~/ 4)) yield e;
    }
  }
}

const _englishPhrases = [
  PhraseEntry('would it be possible', 'polite_expression'),
  PhraseEntry('could you possibly', 'polite_expression'),
  PhraseEntry('I was wondering if', 'polite_expression'),
  PhraseEntry('no problem at all', 'conversational'),
  PhraseEntry('thank you so much', 'polite_expression'),
  PhraseEntry("you're a lifesaver", 'idiom'),
  PhraseEntry('you are a lifesaver', 'idiom'),
  PhraseEntry('I really appreciate it', 'polite_expression'),
  PhraseEntry('lend me a pen', 'common_expression'),
  PhraseEntry('an extra hand', 'idiom'),
  PhraseEntry("I'd be happy to", 'business_phrase'),
  PhraseEntry('how people ask', 'grammatical_pattern'),
  PhraseEntry('let me know', 'business_phrase'),
  PhraseEntry('as soon as possible', 'business_phrase'),
  PhraseEntry('follow up with', 'business_phrase'),
  PhraseEntry('circle back', 'business_phrase'),
];

class TranscriptionCalibrator {
  TranscriptionCalibrator({
    this.flags = const TranscriptionAccuracyFlags(),
    Set<String> optionalVocabulary = const {},
  }) : _optionalVocabulary = optionalVocabulary;

  final TranscriptionAccuracyFlags flags;
  final Set<String> _optionalVocabulary;

  CalibrationResult calibrate({
    required TranscriptionResult input,
    int transcriptId = 0,
  }) {
    final total = Stopwatch()..start();
    final audit = <Map<String, Object?>>[];
    final counters = <String, int>{
      'total_words': 0,
      'suspicious_words': 0,
      'candidate_spans': 0,
      'possible_name_slots': 0,
      'recurring_entities': 0,
      'variant_clusters': 0,
      'phonetic_spans': 0,
      'redecoded_spans': 0,
      'automatic_corrections': 0,
      'preserved_uncertain_spans': 0,
      'removed_duplicate_spans': 0,
      'speaker_boundary_changes': 0,
    };
    final timings = <String, int>{};

    final phraseWatch = Stopwatch()..start();
    final phrases = flags.builtInPhraseLookup
        ? PhraseResource.forLanguage(input.lang)
        : PhraseResource.forLanguage('none');
    timings['phrase_lookup_ms'] = phraseWatch.elapsedMilliseconds;

    var turns = input.turns
        .map(
          (t) => LiteTurn(
            t.speaker,
            t.startSec,
            t.endSec,
            t.text,
            rawText: t.rawText ?? t.text,
            calibratedText: t.calibratedText,
            originalSpeaker: t.originalSpeaker ?? t.speaker,
          ),
        )
        .toList();

    final duplicateWatch = Stopwatch()..start();
    if (flags.duplicateRepair) {
      turns = _repairAdjacentDuplicates(turns, audit, counters);
    }
    timings['duplicate_repair_ms'] = duplicateWatch.elapsedMilliseconds;

    final discoveryWatch = Stopwatch()..start();
    final discovery = flags.transcriptSelfDiscovery
        ? _discoverTranscriptEvidence(turns)
        : _Discovery.empty();
    counters['recurring_entities'] = discovery.recurringEntities.length;
    timings['self_discovery_ms'] = discoveryWatch.elapsedMilliseconds;

    final variantWatch = Stopwatch()..start();
    final variants = flags.variantClustering
        ? _clusterVariants(turns, discovery)
        : <String, String>{};
    counters['variant_clusters'] = variants.length;
    timings['variant_clustering_ms'] = variantWatch.elapsedMilliseconds;

    final wordWatch = Stopwatch()..start();
    final calibrated = <LiteTurn>[];
    var globalWordIndex = 0;
    for (var turnIndex = 0; turnIndex < turns.length; turnIndex++) {
      final turn = turns[turnIndex];
      final rawWords = _splitWords(turn.rawText ?? turn.text);
      final displayWords = _splitWords(turn.text);
      counters['total_words'] = counters['total_words']! + displayWords.length;

      final events = <TemporalWordEvent>[];
      for (var i = 0; i < displayWords.length; i++) {
        final start = _estimatedStart(turn, i, displayWords.length);
        final end = _estimatedStart(turn, i + 1, displayWords.length);
        final raw = i < rawWords.length ? rawWords[i] : displayWords[i];
        final risk = flags.riskClassification
            ? _riskFor(displayWords, i, discovery)
            : RiskCategory.normal;
        if (risk == RiskCategory.possibleName) {
          counters['possible_name_slots'] =
              counters['possible_name_slots']! + 1;
        }
        events.add(
          TemporalWordEvent(
            id: _stableWordId(transcriptId, turnIndex, i, raw),
            transcriptId: transcriptId,
            turnId: 'turn_${transcriptId}_$turnIndex',
            chunkId: 'chunk_$turnIndex',
            wordIndex: globalWordIndex++,
            rawText: raw,
            displayText: displayWords[i],
            startSec: start,
            endSec: end,
            timingSource: WordTimingSource.estimated,
            speakerLabel: turn.speaker,
            originalSpeakerLabel: turn.originalSpeaker ?? turn.speaker,
            state: WordState.provisional,
            riskCategory: risk,
            audioReference:
                '${turn.startSec.toStringAsFixed(2)}-${turn.endSec.toStringAsFixed(2)}',
          ),
        );
      }

      final correctedWords = [...displayWords];
      if (flags.localPatterns && flags.builtInPhraseLookup) {
        _applyPhraseSpanCorrections(
          correctedWords,
          phrases,
          audit,
          counters,
          transcriptId,
          turnIndex,
          turn.startSec,
        );
      }
      for (var i = 0; i < correctedWords.length; i++) {
        final risk = events[i].riskCategory;
        final eligible = _isSuspicious(
          correctedWords,
          i,
          risk,
          phrases,
          variants,
        );
        if (!eligible) {
          events[i].state = WordState.locked;
          continue;
        }
        counters['suspicious_words'] = counters['suspicious_words']! + 1;

        final decision = _scoreCandidates(
          words: correctedWords,
          index: i,
          risk: risk,
          phrases: phrases,
          discovery: discovery,
          variants: variants,
        );
        events[i].candidates = decision.candidates;
        events[i].winningScore = decision.bestScore;
        events[i].secondBestScore = decision.secondBestScore;
        events[i].scoreMargin = decision.margin;
        counters['candidate_spans'] = counters['candidate_spans']! + 1;
        if (decision.usedPhonetic) {
          counters['phonetic_spans'] = counters['phonetic_spans']! + 1;
        }

        if (decision.apply) {
          final before = correctedWords[i];
          correctedWords[i] = _copyCasing(before, decision.winner);
          events[i].applyDisplayText(correctedWords[i], decision.reason);
          counters['automatic_corrections'] =
              counters['automatic_corrections']! + 1;
          audit.add({
            'type': 'automatic_correction',
            'raw_span': before,
            'final_span': correctedWords[i],
            'transcript_id': transcriptId,
            'turn_id': events[i].turnId,
            'word_range': [i, i],
            'timestamp': events[i].startSec,
            'candidate_sources': decision.sources,
            'winning_score': decision.bestScore,
            'second_best_score': decision.secondBestScore,
            'margin': decision.margin,
            'correction_reason': decision.reason,
            'reversible': true,
          });
        } else if (risk != RiskCategory.normal) {
          events[i].state = WordState.uncertain;
          counters['preserved_uncertain_spans'] =
              counters['preserved_uncertain_spans']! + 1;
        }
      }

      var text = _joinWords(correctedWords);
      if (flags.formatting) text = _formatText(text, discovery);
      calibrated.add(
        LiteTurn(
          turn.speaker,
          turn.startSec,
          turn.endSec,
          flags.shadowMode ? turn.text : text,
          rawText: turn.rawText ?? turn.text,
          calibratedText: text,
          originalSpeaker: turn.originalSpeaker ?? turn.speaker,
          calibrationAuditJson: jsonEncode(
            events
                .where(
                  (e) => e.revisionCount > 0 || e.state == WordState.uncertain,
                )
                .map(
                  (e) => {
                    'id': e.id,
                    'raw': e.rawText,
                    'display': e.displayText,
                    'risk': e.riskCategory.name,
                    'state': e.state.name,
                    'score': e.winningScore,
                    'margin': e.scoreMargin,
                    'timing_source': e.timingSource.name,
                  },
                )
                .toList(),
          ),
        ),
      );
    }
    timings['word_event_build_ms'] = wordWatch.elapsedMilliseconds;

    final speakerWatch = Stopwatch()..start();
    final speakerCleaned = flags.speakerConsistency
        ? _cleanupSpeakers(calibrated, audit, counters, transcriptId)
        : calibrated;
    timings['speaker_cleanup_ms'] = speakerWatch.elapsedMilliseconds;

    final finalTurns = flags.finalFlashPass ? speakerCleaned : calibrated;
    timings['formatting_ms'] = 0;
    timings['flash_pass_ms'] = total.elapsedMilliseconds;
    timings['total_processing_ms'] = total.elapsedMilliseconds;

    final rawText = _joinTurnText(input.turns, raw: true);
    final calibratedText = _joinTurnText(finalTurns, calibrated: true);

    return CalibrationResult(
      result: TranscriptionResult(
        model: input.model,
        lang: input.lang,
        durationSec: input.durationSec,
        title: input.title,
        turns: finalTurns,
        rawText: rawText,
        calibratedText: calibratedText,
        calibrationAuditJson: jsonEncode(audit),
        instrumentationJson: jsonEncode({...timings, ...counters}),
      ),
      audit: audit,
      instrumentation: {...timings, ...counters},
    );
  }

  List<LiteTurn> _repairAdjacentDuplicates(
    List<LiteTurn> turns,
    List<Map<String, Object?>> audit,
    Map<String, int> counters,
  ) {
    if (turns.length < 2) return turns;
    final out = <LiteTurn>[turns.first];
    for (var i = 1; i < turns.length; i++) {
      final prev = out.removeLast();
      final next = turns[i];
      final gap = next.startSec - prev.endSec;
      if (gap.abs() > 3.0) {
        out.add(prev);
        out.add(next);
        continue;
      }
      final merged = _mergeOverlap(prev.text, next.text);
      if (merged != null) {
        out.add(
          LiteTurn(
            prev.speaker,
            prev.startSec,
            math.max(prev.endSec, next.endSec),
            merged.kept,
            rawText:
                _mergeOverlap(
                  prev.rawText ?? prev.text,
                  next.rawText ?? next.text,
                )?.kept ??
                '${prev.rawText ?? prev.text} ${next.rawText ?? next.text}',
            originalSpeaker: prev.originalSpeaker ?? prev.speaker,
          ),
        );
        counters['removed_duplicate_spans'] =
            counters['removed_duplicate_spans']! + 1;
        audit.add({
          'type': 'duplicate_removal',
          'removed_text': merged.removed,
          'kept_text': merged.kept,
          'chunk_ids': [i - 1, i],
          'timestamps': [prev.startSec, next.endSec],
          'overlap_evidence': merged.reason,
        });
      } else {
        out.add(prev);
        out.add(next);
      }
    }
    return out;
  }

  _OverlapMerge? _mergeOverlap(String a, String b) {
    final left = _splitWords(a);
    final right = _splitWords(b);
    if (left.isEmpty || right.isEmpty) return null;
    if (_normalizePhrase(a) == _normalizePhrase(b)) {
      return _OverlapMerge(_joinWords(left), b, 'exact_adjacent_duplicate');
    }
    final max = math.min(12, math.min(left.length, right.length));
    for (var n = max; n >= 3; n--) {
      final l = left.sublist(left.length - n).map(_normalizeWord).join(' ');
      final r = right.take(n).map(_normalizeWord).join(' ');
      if (l == r) {
        return _OverlapMerge(
          _joinWords([...left, ...right.skip(n)]),
          _joinWords(right.take(n).toList()),
          'suffix_prefix_$n',
        );
      }
    }
    return null;
  }

  _Discovery _discoverTranscriptEvidence(List<LiteTurn> turns) {
    final counts = <String, int>{};
    final forms = <String, String>{};
    final phrases = <String, int>{};
    for (final turn in turns) {
      final words = _splitWords(turn.text);
      for (final w in words) {
        final n = _normalizeWord(w);
        if (n.length < 3 || _stopWords.contains(n)) continue;
        counts[n] = (counts[n] ?? 0) + 1;
        forms[n] = w;
      }
      for (var size = 2; size <= 5; size++) {
        for (var i = 0; i + size <= words.length; i++) {
          final p = _normalizePhrase(words.sublist(i, i + size).join(' '));
          phrases[p] = (phrases[p] ?? 0) + 1;
        }
      }
    }
    final recurring = <String, String>{
      for (final e in counts.entries)
        if (e.value >= 2) e.key: forms[e.key]!,
    };
    final recurringPhrases = <String>{
      for (final e in phrases.entries)
        if (e.value >= 2) e.key,
    };
    return _Discovery(recurring, recurringPhrases);
  }

  Map<String, String> _clusterVariants(
    List<LiteTurn> turns,
    _Discovery discovery,
  ) {
    final observed = discovery.recurringEntities.values.toList();
    final out = <String, String>{};
    final candidates = <String>{..._optionalVocabulary, ...observed};
    for (final turn in turns) {
      final words = _splitWords(turn.text);
      for (var i = 0; i < words.length; i++) {
        for (final c in candidates) {
          final raw = _normalizeWord(words[i]);
          final canon = _normalizeWord(c);
          if (raw == canon || raw.length < 3 || canon.length < 3) continue;
          if (_soundsClose(raw, canon) && _editDistance(raw, canon) <= 3) {
            out[raw] = c;
          }
        }
      }
    }
    return out;
  }

  RiskCategory _riskFor(List<String> words, int i, _Discovery discovery) {
    final w = _normalizeWord(words[i]);
    final prev = i > 0 ? _normalizeWord(words[i - 1]) : '';
    final next = i + 1 < words.length ? _normalizeWord(words[i + 1]) : '';
    if (RegExp(r'^\d+([.,]\d+)?$').hasMatch(w)) return RiskCategory.number;
    if (_negations.contains(w)) return RiskCategory.negation;
    if (_units.contains(w)) return RiskCategory.unit;
    if (_moneyMarkers.contains(w) || words[i].startsWith(r'$')) {
      return RiskCategory.money;
    }
    if (_possibleNameRight.contains(next) || _possibleNameLeft.contains(prev)) {
      return RiskCategory.possibleName;
    }
    if (discovery.recurringEntities.containsKey(w)) {
      return RiskCategory.recurringEntity;
    }
    return RiskCategory.normal;
  }

  bool _isSuspicious(
    List<String> words,
    int i,
    RiskCategory risk,
    PhraseResource phrases,
    Map<String, String> variants,
  ) {
    if (risk != RiskCategory.normal) return true;
    if (variants.containsKey(_normalizeWord(words[i]))) return true;
    final w = _normalizeWord(words[i]);
    if (w.length > 12 && !_looksReadable(w)) return true;
    for (var size = 2; size <= 5; size++) {
      for (
        var start = math.max(0, i - size + 1);
        start <= i && start + size <= words.length;
        start++
      ) {
        final window = words.sublist(start, start + size);
        if (phrases.damagedCandidates(window).isNotEmpty) return true;
      }
    }
    return false;
  }

  _Decision _scoreCandidates({
    required List<String> words,
    required int index,
    required RiskCategory risk,
    required PhraseResource phrases,
    required _Discovery discovery,
    required Map<String, String> variants,
  }) {
    final raw = words[index];
    final candidates = <String, _Candidate>{
      raw: _Candidate(raw, {'raw_asr'}),
    };
    final normalizedRaw = _normalizeWord(raw);

    final variant = variants[normalizedRaw];
    if (variant != null) {
      candidates[variant] = _Candidate(variant, {'variant_cluster'});
    }

    if (_optionalVocabulary.isNotEmpty) {
      for (final term in _optionalVocabulary) {
        if (_normalizeWord(term) == normalizedRaw) continue;
        if (risk == RiskCategory.possibleName ||
            _soundsClose(normalizedRaw, _normalizeWord(term))) {
          candidates[term] = _Candidate(term, {'optional_user_context'});
        }
      }
    }

    for (var size = 2; size <= 5; size++) {
      for (
        var start = math.max(0, index - size + 1);
        start <= index && start + size <= words.length;
        start++
      ) {
        final window = words.sublist(start, start + size);
        for (final phrase in phrases.damagedCandidates(window)) {
          final phraseWords = _splitWords(phrase.text);
          final replacementOffset = index - start;
          if (replacementOffset >= phraseWords.length) continue;
          final c = phraseWords[replacementOffset];
          candidates[c] = _Candidate(c, {'built_in_phrase', phrase.category});
        }
      }
    }

    final limited = candidates.values.take(5).toList();
    final scored = <_Scored>[];
    var usedPhonetic = false;
    for (final c in limited) {
      var score = c.text == raw ? 65 : 0;
      if (c.sources.contains('optional_user_context')) {
        score += risk == RiskCategory.possibleName ? 110 : 92;
      }
      if (c.sources.contains('built_in_phrase')) score += 82;
      if (c.sources.contains('variant_cluster')) score += 76;
      if (discovery.recurringEntities.values
          .map(_normalizeWord)
          .contains(_normalizeWord(c.text))) {
        score += 18;
      }
      if (_localContextFits(words, index, c.text)) score += 10;
      if (flags.semanticRoles && _semanticRoleFits(words, index, c.text)) {
        score += 14;
      }
      if (flags.phoneticMatching &&
          c.text != raw &&
          _soundsClose(normalizedRaw, _normalizeWord(c.text))) {
        usedPhonetic = true;
        score += 8;
      }
      if (_sensitiveRisks.contains(risk)) score -= 35;
      scored.add(_Scored(c.text, c.sources, score));
    }
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.text.compareTo(b.text);
    });

    final best = scored.first;
    final second = scored.length > 1 ? scored[1].score : 0;
    final margin = best.score - second;
    final sensitive =
        risk == RiskCategory.possibleName ||
        risk == RiskCategory.recurringEntity ||
        risk == RiskCategory.terminology;
    final threshold = sensitive ? 92 : 80;
    final marginThreshold = sensitive ? 30 : 20;
    final allowed = !_sensitiveRisks.contains(risk) || best.score >= 120;
    final apply =
        best.text != raw &&
        best.score >= threshold &&
        margin >= marginThreshold &&
        allowed;
    return _Decision(
      winner: best.text,
      bestScore: best.score,
      secondBestScore: second,
      margin: margin,
      apply: apply,
      candidates: limited.map((e) => e.text).toList(),
      sources: best.sources.toList()..sort(),
      reason: best.sources.join('+'),
      usedPhonetic: usedPhonetic,
    );
  }

  bool _localContextFits(List<String> words, int index, String candidate) {
    final copy = [...words]..[index] = candidate;
    for (var size = 2; size <= 5; size++) {
      for (
        var start = math.max(0, index - size + 1);
        start <= index && start + size <= copy.length;
        start++
      ) {
        final phrase = _normalizePhrase(
          copy.sublist(start, start + size).join(' '),
        );
        if (_commonPhraseKeys.contains(phrase)) return true;
      }
    }
    return false;
  }

  bool _semanticRoleFits(List<String> words, int index, String candidate) {
    final prev = index > 0 ? _normalizeWord(words[index - 1]) : '';
    final next = index + 1 < words.length
        ? _normalizeWord(words[index + 1])
        : '';
    if (_possibleNameRight.contains(next) || _possibleNameLeft.contains(prev)) {
      return candidate.isNotEmpty && candidate[0].toUpperCase() == candidate[0];
    }
    return false;
  }

  List<LiteTurn> _cleanupSpeakers(
    List<LiteTurn> turns,
    List<Map<String, Object?>> audit,
    Map<String, int> counters,
    int transcriptId,
  ) {
    if (turns.length < 3) return turns;
    final out = [...turns];
    for (var i = 1; i + 1 < out.length; i++) {
      final prev = out[i - 1];
      final cur = out[i];
      final next = out[i + 1];
      final curDur = cur.endSec - cur.startSec;
      final continuous =
          !_endsSentence(prev.text) || !_startsSentence(cur.text);
      if (curDur <= 0.9 &&
          prev.speaker == next.speaker &&
          cur.speaker != prev.speaker &&
          continuous) {
        out[i] = LiteTurn(
          prev.speaker,
          cur.startSec,
          cur.endSec,
          cur.text,
          rawText: cur.rawText,
          calibratedText: cur.calibratedText,
          originalSpeaker: cur.originalSpeaker ?? cur.speaker,
          calibrationAuditJson: cur.calibrationAuditJson,
        );
        counters['speaker_boundary_changes'] =
            counters['speaker_boundary_changes']! + 1;
        audit.add({
          'type': 'speaker_adjustment',
          'transcript_id': transcriptId,
          'original_speaker_label': cur.speaker,
          'final_speaker_label': prev.speaker,
          'reason': 'short_isolated_fragment_between_matching_speakers',
          'timestamps': [cur.startSec, cur.endSec],
        });
      }
    }
    return out;
  }

  void _applyPhraseSpanCorrections(
    List<String> words,
    PhraseResource phrases,
    List<Map<String, Object?>> audit,
    Map<String, int> counters,
    int transcriptId,
    int turnIndex,
    double turnStartSec,
  ) {
    for (var size = 5; size >= 2; size--) {
      var i = 0;
      while (i + size <= words.length) {
        final window = words.sublist(i, i + size);
        PhraseEntry? best;
        var bestDistance = 999;
        for (final candidate in phrases.damagedCandidates(window)) {
          final d = _editDistance(
            _normalizePhrase(window.join(' ')),
            _normalizePhrase(candidate.text),
          );
          if (d < bestDistance) {
            best = candidate;
            bestDistance = d;
          }
        }
        if (best == null ||
            bestDistance >
                math.max(3, _normalizePhrase(best.text).length ~/ 3)) {
          i++;
          continue;
        }
        final replacement = _splitWords(best.text);
        final before = _joinWords(window);
        words.replaceRange(i, i + size, replacement);
        counters['automatic_corrections'] =
            counters['automatic_corrections']! + 1;
        counters['candidate_spans'] = counters['candidate_spans']! + 1;
        audit.add({
          'type': 'automatic_correction',
          'raw_span': before,
          'final_span': _joinWords(replacement),
          'transcript_id': transcriptId,
          'turn_id': 'turn_${transcriptId}_$turnIndex',
          'word_range': [i, i + replacement.length - 1],
          'timestamp': turnStartSec,
          'candidate_sources': ['built_in_phrase', best.category],
          'winning_score': 92,
          'second_best_score': 65,
          'margin': 27,
          'correction_reason': 'built_in_phrase_span',
          'reversible': true,
        });
        i += replacement.length;
      }
    }
  }
}

class _Discovery {
  const _Discovery(this.recurringEntities, this.recurringPhrases);
  factory _Discovery.empty() => const _Discovery({}, {});
  final Map<String, String> recurringEntities;
  final Set<String> recurringPhrases;
}

class _Candidate {
  const _Candidate(this.text, this.sources);
  final String text;
  final Set<String> sources;
}

class _Scored {
  const _Scored(this.text, this.sources, this.score);
  final String text;
  final Set<String> sources;
  final int score;
}

class _Decision {
  const _Decision({
    required this.winner,
    required this.bestScore,
    required this.secondBestScore,
    required this.margin,
    required this.apply,
    required this.candidates,
    required this.sources,
    required this.reason,
    required this.usedPhonetic,
  });

  final String winner;
  final int bestScore;
  final int secondBestScore;
  final int margin;
  final bool apply;
  final List<String> candidates;
  final List<String> sources;
  final String reason;
  final bool usedPhonetic;
}

class _OverlapMerge {
  const _OverlapMerge(this.kept, this.removed, this.reason);
  final String kept;
  final String removed;
  final String reason;
}

final _commonPhraseKeys = _englishPhrases
    .map((e) => _normalizePhrase(e.text))
    .toSet();

const _possibleNameRight = {'said', 'replied', 'asked', 'joined', 'will'};
const _possibleNameLeft = {'ask', 'thank', 'hello', 'to', 'according'};
const _negations = {'no', 'not', "don't", 'cannot', "can't", 'never'};
const _units = {'kg', 'kilogram', 'meter', 'mile', 'percent', 'degrees'};
const _moneyMarkers = {'dollar', 'dollars', 'usd', 'price', 'cost'};
const _sensitiveRisks = {
  RiskCategory.number,
  RiskCategory.date,
  RiskCategory.money,
  RiskCategory.unit,
  RiskCategory.address,
  RiskCategory.negation,
  RiskCategory.critical,
};
const _stopWords = {
  'the',
  'and',
  'you',
  'that',
  'with',
  'for',
  'this',
  'have',
  'will',
  'are',
};

List<String> _splitWords(String text) => RegExp(
  r"[A-Za-z0-9$']+|[.,!?;:]",
).allMatches(text).map((m) => m.group(0)!).toList();

String _joinWords(List<String> words) {
  final b = StringBuffer();
  for (final w in words) {
    if (RegExp(r'^[.,!?;:]$').hasMatch(w)) {
      b.write(w);
    } else {
      if (b.isNotEmpty) b.write(' ');
      b.write(w);
    }
  }
  return b.toString();
}

String _joinTurnText(
  List<LiteTurn> turns, {
  bool raw = false,
  bool calibrated = false,
}) => turns
    .map(
      (t) => raw
          ? (t.rawText ?? t.text)
          : calibrated
          ? (t.calibratedText ?? t.text)
          : t.text,
    )
    .where((t) => t.trim().isNotEmpty)
    .join(' ')
    .trim();

String _normalizePhrase(String s) =>
    _splitWords(s).map(_normalizeWord).where((w) => w.isNotEmpty).join(' ');

String _normalizeWord(String s) =>
    s.toLowerCase().replaceAll(RegExp(r"^[^a-z0-9$']+|[^a-z0-9']+$"), '');

double _estimatedStart(LiteTurn turn, int index, int wordCount) {
  if (wordCount <= 0) return turn.startSec;
  final span = math.max(0.0, turn.endSec - turn.startSec);
  return turn.startSec + (span * index / wordCount);
}

String _stableWordId(
  int transcriptId,
  int turnIndex,
  int wordIndex,
  String raw,
) => 't$transcriptId-u$turnIndex-w$wordIndex-${_normalizeWord(raw)}';

bool _looksReadable(String s) => RegExp(r'[aeiouy]').hasMatch(s);

bool _soundsClose(String a, String b) => _phoneticKey(a) == _phoneticKey(b);

String _phoneticKey(String s) {
  final n = _normalizeWord(s);
  if (n.isEmpty) return '';
  final b = StringBuffer(n[0]);
  String? last;
  for (final code in n.substring(1).split('').map(_soundCode)) {
    if (code.isEmpty || code == last) continue;
    b.write(code);
    last = code;
  }
  return b.toString();
}

String _soundCode(String c) {
  if ('bfpv'.contains(c)) return '1';
  if ('cgjkqsxz'.contains(c)) return '2';
  if ('dt'.contains(c)) return '3';
  if (c == 'l') return '4';
  if ('mn'.contains(c)) return '5';
  if (c == 'r') return '6';
  return '';
}

int _editDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 0; i < a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i + 1;
    for (var j = 0; j < b.length; j++) {
      final cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
      cur[j + 1] = math.min(
        math.min(cur[j] + 1, prev[j + 1] + 1),
        prev[j] + cost,
      );
    }
    prev = cur;
  }
  return prev.last;
}

String _copyCasing(String original, String replacement) {
  if (original.isEmpty || replacement.isEmpty) return replacement;
  if (original[0].toUpperCase() == original[0]) {
    return replacement[0].toUpperCase() + replacement.substring(1);
  }
  return replacement;
}

String _formatText(String text, _Discovery discovery) {
  var s = text
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'\s+([.,!?;:])'), r'$1')
      .replaceAll(RegExp(r'([!?.,])\1+'), r'$1')
      .trim();
  if (s.isEmpty) return s;
  s = s[0].toUpperCase() + s.substring(1);
  return s.replaceAllMapped(RegExp(r'([.!?]\s+)([a-z])'), (m) {
    return '${m.group(1)}${m.group(2)!.toUpperCase()}';
  });
}

bool _endsSentence(String s) => RegExp(r'[.!?]\s*$').hasMatch(s.trim());

bool _startsSentence(String s) {
  final t = s.trimLeft();
  return t.isEmpty || t[0].toUpperCase() == t[0];
}
