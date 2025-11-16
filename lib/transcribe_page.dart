// lib/transcribe_page.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:transcript/debug/speaker_memory_page.dart';

import 'mic_recorder.dart';
import 'whisper_service.dart';
import 'diarizer_service.dart';
import 'audio_utils.dart';
import 'audio_preprocess.dart';
import 'speaker_embedding.dart';
import 'speaker_memory.dart';
import 'model_bootstrap.dart'; // for ensureDiarizationModels()

import 'main.dart' show whisper, diarizer; // make sure main.dart exports both

class TranscribePage extends StatefulWidget {
  const TranscribePage({super.key});
  @override
  State<TranscribePage> createState() => _TranscribePageState();
}

/// Store one final line per merged speaker block
class TurnResult {
  final String speakerId; // original id, e.g. "S1"
  final double startSec, endSec;
  final String text; // ASR result for that block
  TurnResult({
    required this.speakerId,
    required this.startSec,
    required this.endSec,
    required this.text,
  });
}

class _TranscribePageState extends State<TranscribePage> {
  final _rec = MicRecorder();

  bool _recording = false;
  bool _busy = false;
  bool _translate = false;

  String? _lastAudioPath;       // raw recorded wav
  String? _lastCleanedPath;     // preprocessed wav for diarize+ASR

  /// Merged diarization blocks (continuous runs)
  List<SpeakerTurn> _turns = const [];

  /// Per-merged-block ASR results
  List<TurnResult> _results = const [];

  /// Runtime alias map: "S1" -> "Alex"
  final Map<String, String> _alias = {};

  @override
  void initState() {
    super.initState();
    if (!whisper.isReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _toast(context, 'Whisper not initialized');
      });
    }
  }

  // ---------- Permissions & Recording ----------

  Future<void> _ensureMic() async {
    final status = await Permission.microphone.status;
    if (status.isDenied || status.isPermanentlyDenied) {
      final granted = await Permission.microphone.request();
      if (!granted.isGranted) {
        throw Exception('Microphone permission is required');
      }
    }
  }

  Future<void> _onHoldStart() async {
    try {
      await _ensureMic();
      final path = await _rec.start();
      if (!mounted) return;
      setState(() {
        _recording = true;
        _lastAudioPath = path;
      });
      _toast(context, 'Recording… release to transcribe');
    } catch (e) {
      if (!mounted) return;
      _toast(context, e.toString());
    }
  }

  Future<void> _onHoldEnd() async {
    try {
      final path = await _rec.stop();
      if (!mounted) return;
      setState(() => _recording = false);
      if (path == null) return;
      await _transcribe(path);
    } catch (e) {
      if (!mounted) return;
      _toast(context, e.toString());
    }
  }

  Future<void> _cancelRecording() async {
    await _rec.cancel();
    if (!mounted) return;
    setState(() => _recording = false);
    _toast(context, 'Canceled');
  }

  // ---------- Diarization helpers ----------

  /// Merge continuous blocks for any speaker.
  /// - One line per speaker *run* (S1…S1), even if diarizer split it.
  /// - Non-speech labels (if any) are folded into the time window.
  /// - Never merges across a different speaker in between.
  List<SpeakerTurn> _mergeContinuousBlocksAnySpeaker(
    List<SpeakerTurn> input, {
    Set<String> nonSpeechLabels = const {'', 'NONE', 'NS', 'SIL', 'NON_SPEECH'},
  }) {
    if (input.isEmpty) return const [];
    final segs = [...input]..sort((a, b) => a.startSec.compareTo(b.startSec));

    final out = <SpeakerTurn>[];
    int i = 0;

    bool _isNonSpeech(String s) => nonSpeechLabels.contains(s.toUpperCase());

    while (i < segs.length) {
      if (_isNonSpeech(segs[i].speaker)) {
        i++;
        continue;
      }
      final curSpk = segs[i].speaker;
      double start = segs[i].startSec;
      double end = segs[i].endSec;
      int j = i + 1;

      while (j < segs.length) {
        final s = segs[j];
        if (_isNonSpeech(s.speaker)) {
          end = (s.endSec > end) ? s.endSec : end;
          j++;
          continue;
        }
        if (s.speaker == curSpk) {
          end = s.endSec;
          j++;
          continue;
        }
        break;
      }

      out.add(SpeakerTurn(startSec: start, endSec: end, speaker: curSpk));
      i = j;
    }
    return out;
  }

  /// Merge consecutive segments from the same speaker if the gap is small.
/// This does NOT merge across another speaker.
/// Example: S1 [0–3], gap 0.4s, S1 [3.4–8]  =>  S1 [0–8]
List<SpeakerTurn> _mergeContinuousBlocksAnySpeakerGapAware(
  List<SpeakerTurn> input, {
  double maxInnerGapSec = 0.8, // tune 0.5–1.2s as you like
}) {
  if (input.isEmpty) return const [];

  final segs = [...input]..sort((a, b) => a.startSec.compareTo(b.startSec));
  final out = <SpeakerTurn>[];
  var cur = segs.first;

  for (var i = 1; i < segs.length; i++) {
    final nxt = segs[i];
    if (nxt.speaker == cur.speaker && (nxt.startSec - cur.endSec) <= maxInnerGapSec) {
      // extend current block to include the gap + next segment
      cur = SpeakerTurn(startSec: cur.startSec, endSec: nxt.endSec, speaker: cur.speaker);
    } else {
      out.add(cur);
      cur = nxt;
    }
  }
  out.add(cur);
  return out;
}


  /// Build a name map "S1"->"Alex" by matching embeddings with saved profiles.
//   Future<Map<String, String>> _nameMapForTurns(
//   String wavPath,
//   List<SpeakerTurn> turns, {
//   double maxPerSpeakerSec = 10.0,
//   double matchThreshold = 0.67,
// }) async {
//   final mem = await SpeakerMemory.instance();
//   final mp = await ensureDiarizationModels(); // embOnnx path
//   final emb = await SpeakerEmbedder.instance(mp.embOnnx);

//   final bySpk = <String, List<SpeakerTurn>>{};
//   for (final t in turns) {
//     (bySpk[t.speaker] ??= []).add(t);
//   }

//   final nameMap = <String, String>{};

//   for (final entry in bySpk.entries) {
//     final spkId = entry.key;
//     final spans = entry.value;

//     // ---- Windowed embeddings across several short chunks ----
//     // We’ll sample up to ~10s spread across 2–4 windows (2s each).
//     final parts = <Float32List>[];
//     double remaining = maxPerSpeakerSec;

//     for (final s in spans) {
//       if (remaining <= 0) break;

//       final segDur = (s.endSec - s.startSec);
//       // cut the segment into ~2s windows
//       const win = 2.0;
//       final nWins = (segDur / win).ceil().clamp(1, 4); // up to 4 windows/segment
//       for (var k = 0; k < nWins && remaining > 0; k++) {
//         final st = s.startSec + k * win;
//         if (st >= s.endSec) break;
//         final en = (st + win) > s.endSec ? s.endSec : (st + win);
//         final take = (en - st).clamp(0.5, remaining);
//         if (take <= 0) break;

//         final v = await emb.embedFromWav(wavPath, startSec: st, endSec: st + take);
//         if (v.isNotEmpty) parts.add(v);
//         remaining -= take;
//         if (remaining <= 0) break;
//       }
//     }

//     if (parts.isEmpty) {
//       nameMap[spkId] = spkId.toLowerCase();
//       continue;
//     }

//     // mean-pool the windows -> robust to tone changes in the block
//     final centroid = emb.meanPool(parts);

//     // identify with multi-prototype memory
//     final best = mem.identify(centroid, threshold: matchThreshold);
//     if (best.key != null) {
//       nameMap[spkId] = best.key!;
//       // ---- Online adaptation: if it was a strong match, append this centroid ----
//       if (best.value >= (matchThreshold + 0.08)) {
//         await mem.enrollAppend(name: best.key!, embedding: centroid);
//       }
//     } else {
//       nameMap[spkId] = spkId.toLowerCase();
//     }
//   }

//   return nameMap;
// }

Future<Map<String, String>> _nameMapForTurns(
  String wavPath,
  List<SpeakerTurn> turns, {
  double perSpeakerBudgetSec = 10.0,
  double windowSec = 2.0,
  double matchThreshold = 0.67,
}) async {
  final mem = await SpeakerMemory.instance();
  final mp  = await ensureDiarizationModels();         // embOnnx path
  final emb = await SpeakerEmbedder.instance(mp.embOnnx);

  final spansById = <String, List<SpeakerTurn>>{};
  for (final t in turns) {
    (spansById[t.speaker] ??= []).add(t);
  }

  final nameMap = <String, String>{};

  for (final entry in spansById.entries) {
    final spkId = entry.key;
    final spans = entry.value..sort((a, b) => a.startSec.compareTo(b.startSec));

    // total duration for this speaker
    final totalDur = spans.fold<double>(0.0, (s, t) => s + (t.endSec - t.startSec));
    if (totalDur <= 0.5) {
      nameMap[spkId] = spkId.toLowerCase();
      continue;
    }

    // number of windows: ~budget/windowSec, but cap to avoid too many calls
    final maxWins = (perSpeakerBudgetSec / windowSec).floor().clamp(1, 8);
    final windows = _evenlySpacedWindows(spans, maxWins, windowSec);

    final parts = <Float32List>[];
    for (final w in windows) {
      final v = await emb.embedFromWav(wavPath, startSec: w.$1, endSec: w.$2);
      if (v.isNotEmpty) parts.add(v);
    }

    if (parts.isEmpty) {
      nameMap[spkId] = spkId.toLowerCase();
      continue;
    }

    final centroid = emb.meanPool(parts);                // L2-norm inside
    final best = mem.identify(centroid, threshold: matchThreshold);

    if (best.key != null) {
      nameMap[spkId] = best.key!;
      // optional online adaptation when very confident
      if (best.value >= matchThreshold + 0.08) {
        await mem.enrollAppend(name: best.key!, embedding: centroid);
      }
    } else {
      nameMap[spkId] = spkId.toLowerCase();
    }
  }

  return nameMap;
}

/// Build up to [maxWins] windows of length [winSec] spread evenly
/// across the provided [spans] (sorted, non-overlapping).
/// Returns a list of (start, end) tuples in seconds.
List<(double,double)> _evenlySpacedWindows(
  List<SpeakerTurn> spans,
  int maxWins,
  double winSec,
) {
  // Flatten spans into a timeline for sampling
  final timeline = <(double,double)>[];
  for (final s in spans) {
    timeline.add((s.startSec, s.endSec));
  }
  final total = timeline.fold<double>(0.0, (acc, r) => acc + (r.$2 - r.$1));
  if (total <= 0) return const [];

  final out = <(double,double)>[];
  final step = total / maxWins;

  double acc = 0.0;
  int idx = 0;
  double curStart = timeline.first.$1;
  double curEnd   = timeline.first.$2;

  for (int w = 0; w < maxWins; w++) {
    final target = w * step + (step * 0.5); // middle of each bucket
    // advance until we hit the span containing 'target'
    while (idx < timeline.length) {
      final len = curEnd - curStart;
      if (target <= acc + len) break;
      acc += len;
      idx++;
      if (idx < timeline.length) {
        curStart = timeline[idx].$1;
        curEnd   = timeline[idx].$2;
      }
    }
    if (idx >= timeline.length) break;

    // center window at curStart + (target - acc), clamp to span
    final offsetInSpan = (target - acc).clamp(0.0, curEnd - curStart);
    var wStart = curStart + offsetInSpan - winSec / 2;
    var wEnd   = wStart + winSec;
    if (wStart < curStart) { wStart = curStart; wEnd = (wStart + winSec).clamp(wStart, curEnd); }
    if (wEnd   > curEnd)   { wEnd   = curEnd;   wStart = (wEnd - winSec).clamp(curStart, wEnd); }

    if ((wEnd - wStart) >= 0.5) {
      out.add((wStart, wEnd));
    }
  }
  return out;
}
  // ---------- Transcribe pipeline ----------

  Future<void> _transcribe(String wavPath) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _turns = const [];
      _results = const [];
      _alias.clear();
    });

    try {
      // 0) Clean up audio (denoise, DC offset, clip guard, etc.)
      final cleaned = await preprocessWav16kMono(wavPath);
      _lastCleanedPath = cleaned;

      // 1) Diarize
      final diarized = diarizer.isReady
          ? await diarizer.diarizeFile(
              cleaned,
              minSegDur: 0.40,
              minorMinSec: 1.00,
              minorMaxShare: 0.08,
            )
          : const <SpeakerTurn>[];

      // 2) Merge continuous runs
      final turns = _mergeContinuousBlocksAnySpeakerGapAware(diarized);

      // 3) Fallback: entire file as S1 if diarization yields nothing
      if (turns.isEmpty) {
        final text = await whisper.transcribeWav(
          wavPath: cleaned,
          translateToEnglish: _translate,
          noTimestamps: false,
          splitOnWord: true,
          diarize: false,
        );
        final dur = await readWavDuration(cleaned);
        setState(() {
          _turns = const [];
          _results = [
            TurnResult(
              speakerId: 'S1',
              startSec: 0.0,
              endSec: dur,
              text: text.trim(),
            )
          ];
          _alias['S1'] = 's1';
        });
        return;
      }

      // 4) Auto-identify speakers from memory & set initial aliases
      final nameMap = await _nameMapForTurns(cleaned, turns);
      _alias
        ..clear()
        ..addAll(nameMap);

      // 5) Slice & ASR per merged block
      final tmp = await getTemporaryDirectory();
      final out = <TurnResult>[];

      for (int i = 0; i < turns.length; i++) {
        final t = turns[i];
        final slicePath = '${tmp.path}/slice_$i.wav';

        await trimWav16kMonoPcm(
          inputPath: cleaned,
          startSec: t.startSec,
          endSec: t.endSec,
          outputPath: slicePath,
        );

        final text = await whisper.transcribeWav(
          wavPath: slicePath,
          translateToEnglish: _translate,
          noTimestamps: false,
          splitOnWord: true,
          diarize: false,
        );

        out.add(TurnResult(
          speakerId: t.speaker,
          startSec: t.startSec,
          endSec: t.endSec,
          text: text.trim(),
        ));

        // try to delete slice
        try {
          File(slicePath).deleteSync();
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _turns = turns;
        _results = out;
      });
    } catch (e) {
      if (!mounted) return;
      _toast(context, 'Transcription failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- Naming / Enrollment ----------

  /// Display label for a speaker id using current alias map.
  String _labelFor(String speakerId) => _alias[speakerId] ?? speakerId.toLowerCase();

  /// Render the big multiline transcript string from _results + _alias.
  String _renderTranscript() {
    final buf = StringBuffer();
    for (final r in _results) {
      final label = _labelFor(r.speakerId);
      buf.writeln(
        '$label: ${r.text} : '
        '${r.startSec.toStringAsFixed(2)}–${r.endSec.toStringAsFixed(2)}s',
      );
    }
    return buf.toString().trim();
  }

  /// Rename/enroll one speaker (S1 -> "Alex") using that speaker’s audio spans.
  Future<void> _renameAndEnroll(String speakerId) async {
    if (_lastCleanedPath == null || _turns.isEmpty) return;

    final controller = TextEditingController(text: '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Rename $speakerId'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Display name',
            hintText: 'e.g. Alex',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );

    if (name == null || name.isEmpty) return;

    try {
      final mp = await ensureDiarizationModels(); // embOnnx path
      final embedder = await SpeakerEmbedder.instance(mp.embOnnx);
      final memory = await SpeakerMemory.instance();

      // use up to ~15s total audio across this speaker’s runs
      final spans = _turns.where((t) => t.speaker == speakerId).toList()
        ..sort((a, b) => a.startSec.compareTo(b.startSec));

      double remaining = 15.0;
      final parts = <Float32List>[];

      for (final s in spans) {
        if (remaining <= 0) break;
        final segDur = s.endSec - s.startSec;
        final take = segDur.clamp(0.5, remaining);
        final v = await embedder.embedFromWav(
          _lastCleanedPath!,
          startSec: s.startSec,
          endSec: s.startSec + take,
        );
        if (v.isNotEmpty) parts.add(v);
        remaining -= take;
      }

      if (parts.isEmpty) {
        if (!mounted) return;
        _toast(context, 'No audio to enroll for $speakerId');
        return;
      }

      final centroid = embedder.meanPool(parts);
      await memory.enrollAppend(name: name, embedding: centroid);

      // update alias + refresh UI text
      setState(() => _alias[speakerId] = name);
    } catch (e) {
      if (!mounted) return;
      _toast(context, 'Enroll failed: $e');
    }
  }

  // ---------- UI ----------

  Future<void> _clearTranscript() async {
    setState(() {
      _turns = const [];
      _results = const [];
      _alias.clear();
    });
  }

  Future<void> _openFolder() async {
    final dir = await getApplicationDocumentsDirectory();
    if (!mounted) return;
    _toast(context, 'Audio folder: ${dir.path}');
  }

  @override
  Widget build(BuildContext context) {
    final micGlow = _recording ? 1.0 : 0.0;
    final transcriptStr = _renderTranscript();

    final distinctSpeakers = <String>{
      ..._results.map((e) => e.speakerId),
      ..._turns.map((e) => e.speaker),
    }.toList()
      ..sort();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Speech → Text (whisper.cpp + diarization)'),
        actions: [
          Row(
            children: [
              const Text('Translate to English'),
              Switch(
                value: _translate,
                onChanged: _busy ? null : (v) => setState(() => _translate = v),
              ),
              const SizedBox(width: 8),
              IconButton(
  tooltip: 'SpeakerMemory',
  icon: const Icon(Icons.person_search),
  onPressed: () {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SpeakerMemoryPage()),
    );
  },
),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Transcript card
            Padding(
              padding: const EdgeInsets.all(12),
              child: _card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header('Output'),
                    const SizedBox(height: 8),
                    if (_busy) const LinearProgressIndicator(minHeight: 3),
                    if (!_busy && transcriptStr.isEmpty)
                      const Text(
                        'No transcript yet. Hold the mic to speak.',
                        style: TextStyle(color: Colors.white70),
                      ),
                    if (transcriptStr.isNotEmpty)
                      SelectableText(
                        transcriptStr,
                        style: const TextStyle(fontSize: 16, height: 1.35),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed:
                              transcriptStr.isEmpty && _turns.isEmpty ? null : _clearTranscript,
                          icon: const Icon(Icons.clear),
                          label: const Text('Clear'),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: _openFolder,
                          icon: const Icon(Icons.folder_open),
                          label: const Text('Audio folder'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // People / rename section (only when we have blocks)
            if (distinctSpeakers.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _header('People'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: distinctSpeakers.map((sid) {
                          final label = _labelFor(sid);
                          return InputChip(
                            label: Text(label),
                            avatar: const Icon(Icons.person, size: 18),
                            onPressed: null,
                            onDeleted: _busy ? null : () => _renameAndEnroll(sid),
                            deleteIcon: const Icon(Icons.edit, size: 18),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ),

            const Spacer(),

            // Press-and-hold mic
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: GestureDetector(
                onLongPressStart: (_) => _onHoldStart(),
                onLongPressEnd: (_) => _onHoldEnd(),
                onLongPressCancel: _cancelRecording,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  height: 72,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A22),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: micGlow > 0
                        ? [
                            BoxShadow(
                              color: const Color(0xFF8E7CFF).withValues(alpha: 0.45),
                              blurRadius: 24,
                              spreadRadius: 1,
                            )
                          ]
                        : [],
                    border: Border.all(
                      color: const Color(0xFF8E7CFF).withValues(alpha: _recording ? 0.9 : 0.3),
                      width: 1.4,
                    ),
                  ),
                  child: Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _recording ? Icons.mic_rounded : Icons.mic_none_rounded,
                          size: 28,
                          color: const Color(0xFF8E7CFF),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _recording
                              ? 'Listening… release to transcribe'
                              : 'Hold to speak',
                          style: const TextStyle(fontSize: 16),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- Small UI helpers ----------

  Widget _card({required Widget child}) => Card(
        elevation: 0.6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      );

  Widget _header(String text) => Text(
        text,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14,
          color: Colors.white70,
          letterSpacing: 0.2,
        ),
      );
}

void _toast(BuildContext ctx, String msg) {
  ScaffoldMessenger.of(ctx).hideCurrentSnackBar();
  ScaffoldMessenger.of(ctx).showSnackBar(
    SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
  );
}
