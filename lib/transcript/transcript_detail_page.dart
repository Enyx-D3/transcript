// lib/transcript/transcript_detail_page.dart
import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:transcript/common/app_flushbar.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../objectbox.g.dart';

import 'background_transcriber.dart'; // only for listening to BG events
import 'transcript_summary_page.dart';   // <-- NEW
import 'transcript_chat_page.dart';      // <-- NEW
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class TranscriptDetailPage extends StatefulWidget {
  const TranscriptDetailPage({super.key, required this.transcriptId});
  final int transcriptId;

  @override
  State<TranscriptDetailPage> createState() => _TranscriptDetailPageState();
}

class _TranscriptDetailPageState extends State<TranscriptDetailPage> {
  TranscriptEntity? _t;
  List<TranscriptTurnEntity> _turns = const [];
  Timer? _poll;
  StreamSubscription<dynamic>? _bgSub;

  // --- Audio player state ---
  final AudioPlayer _player = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
  bool _isPlaying = false;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  String? _loadedPath;
  static const _kBusyTranscribing = 'busy_transcribing';
  @override
  void initState() {
    super.initState();
    _wirePlayer();
    _loadOnce();
    _startPoller();

    // Listen to BG worker results ONLY to react (no ObjectBox writes here).
    _bgSub = BackgroundTranscriber.onData(_onBgData);
  }

  @override
  void dispose() {
    _bgSub?.cancel();
    _poll?.cancel();
    _player.stop();
    _player.dispose();
    super.dispose();
  }

  // --- Player wiring ---
  void _wirePlayer() {
    _player.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      setState(() => _isPlaying = (s == PlayerState.playing));
    });
    _player.onDurationChanged.listen((d) {
      if (!mounted) return;
      setState(() => _dur = d);
    });
    _player.onPositionChanged.listen((p) {
      if (!mounted) return;
      setState(() => _pos = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _isPlaying = false;
        _pos = Duration.zero;
      });
    });
  }

  Future<bool> _ensureSourceLoaded() async {
    final path = _t?.audioPath;
    if (path == null || path.isEmpty) return false;
    final f = File(path);
    if (!f.existsSync()) return false;

    if (_loadedPath != path) {
      await _player.setSource(DeviceFileSource(path));
      _loadedPath = path;
    }
    return true;
  }

  Future<void> _togglePlayPause() async {
    if (!await _ensureSourceLoaded()) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Audio file not available for playback.');
      return;
    }
    if (_isPlaying) {
      await _player.pause();
    } else {
      if (_dur > Duration.zero &&
          _pos >= _dur - const Duration(milliseconds: 300)) {
        await _player.seek(Duration.zero);
      }
      await _player.resume();
    }
  }

  Future<void> _seekTo(double v) async {
    final to = Duration(milliseconds: v.round());
    await _player.seek(to);
  }

  // --- Data loading ---
  void _loadOnce() {
    _t = ObjectBox.I.transcripts.get(widget.transcriptId);
    _refreshTurns();
  }

  void _startPoller() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _refreshTurns();
    });
  }

  void _refreshTurns() {
    final obx = ObjectBox.I;
    _t = obx.transcripts.get(widget.transcriptId);

    final qb = obx.turns
        .query(TranscriptTurnEntity_.transcript.equals(widget.transcriptId))
      ..order(TranscriptTurnEntity_.startSec);
    final q = qb.build();
    final rows = q.find();
    q.close();

    if (!mounted) return;
    setState(() => _turns = rows);
  }

  // --- React to BG events (no ObjectBox writes here) ---
Future<void> _onBgData(dynamic data) async {
  if (data is! Map) return;
  final type = data['type'];

  if (type == 'transcribe_error') {
    // ✅ transcription ended (failed)
    await FlutterForegroundTask.saveData(key: _kBusyTranscribing, value: false);

    final err = data['error'];
     if (!mounted) return;
      await AppFlushbar.error(context, message: 'Transcription Failed');
    return;
  }

  if (type != 'transcribe_result') return;

  final existingId = data['existingId'] as int?;
  if (existingId != widget.transcriptId) return;

  // ✅ transcription ended (success)
  await FlutterForegroundTask.saveData(key: _kBusyTranscribing, value: false);

  // main.dart already persisted to ObjectBox, just refresh our view
  _refreshTurns();
}

  // --- Edit title ---
  Future<void> _editTitle() async {
    final t = _t;
    if (t == null) return;

    final ctrl = TextEditingController(text: t.title ?? '');
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit title'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Title',
            hintText: 'e.g. Team meeting',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newTitle == null) return;

    final obx = ObjectBox.I;
    obx.transcripts.put(
      TranscriptEntity(
        id: t.id,
        title: newTitle.isEmpty ? null : newTitle,
        model: t.model,
        lang: t.lang,
        audioPath: t.audioPath,
        durationSec: t.durationSec,
        createdAt: t.createdAt,
      ),
    );

    _refreshTurns();
  }

  // --- Rename a speaker within this transcript ---
  Future<void> _renameSpeaker(String oldLabel) async {
    final ctrl = TextEditingController(text: oldLabel);
    final newLabel = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename speaker'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'e.g. Alex',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newLabel == null || newLabel.isEmpty || newLabel == oldLabel) return;

    final obx = ObjectBox.I;
    final qb = obx.turns
        .query(
          TranscriptTurnEntity_.transcript
              .equals(widget.transcriptId)
              .and(TranscriptTurnEntity_.speakerLabel.equals(oldLabel)),
        )
      ..order(TranscriptTurnEntity_.startSec);
    final q = qb.build();
    final items = q.find();
    q.close();

    for (final u in items) {
      obx.turns.put(
        TranscriptTurnEntity(
          id: u.id,
          speakerLabel: newLabel,
          startSec: u.startSec,
          endSec: u.endSec,
          text: u.text,
        )..transcript.targetId = widget.transcriptId,
      );
    }
    _refreshTurns();
  }

  // --- Helpers ---
  String _fmtMeta(TranscriptEntity t) {
    final when = t.createdAt.toLocal();
    final y = when.year.toString().padLeft(4, '0');
    final m = when.month.toString().padLeft(2, '0');
    final d = when.day.toString().padLeft(2, '0');
    final hh = when.hour.toString().padLeft(2, '0');
    final mm = when.minute.toString().padLeft(2, '0');
    final dur = _fmtDuration(t.durationSec);
    return '$y-$m-$d $hh:$mm • $dur';
  }

  String _fmtDuration(double seconds) {
    final safe = seconds.isFinite && seconds >= 0 ? seconds : 0.0;
    final total = safe.round();
    final m = (total ~/ 60).toString();
    final ss = (total % 60).toString().padLeft(2, '0');
    return '${m}m${ss}s';
  }

  String _fmtClock(Duration d) {
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final title = (t?.title?.trim().isNotEmpty ?? false)
        ? t!.title!.trim()
        : 'Transcript';

    final counts = <String, int>{};
    for (final u in _turns) {
      counts[u.speakerLabel] = (counts[u.speakerLabel] ?? 0) + 1;
    }
    final labels = counts.keys.toList()..sort();

    final isProcessing = (t != null && _turns.isEmpty);

    final hasAudio = (t?.audioPath != null &&
        t!.audioPath!.isNotEmpty &&
        File(t.audioPath!).existsSync());

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: 'Edit title',
            icon: const Icon(Icons.edit_note),
            onPressed: _t == null ? null : _editTitle,
          ),
        ],
      ),
      body: t == null
          ? const Center(child: Text('Not found'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
              children: [
                // --- Playback + meta card ---
                Card(
                  elevation: 0.6,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            IconButton.filled(
                              onPressed: hasAudio ? _togglePlayPause : null,
                              icon: Icon(
                                _isPlaying
                                    ? Icons.pause
                                    : Icons.play_arrow,
                                size: 28,
                              ),
                              tooltip: _isPlaying ? 'Pause' : 'Play',
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('${t.model} • ${t.lang}'),
                                  const SizedBox(height: 4),
                                  Text(
                                    _fmtMeta(t),
                                    style: const TextStyle(
                                      color: Colors.white70,
                                    ),
                                  ),
                                  if (!hasAudio)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 6),
                                      child: Text(
                                        'No recorded audio attached.',
                                        style: TextStyle(
                                          color: Colors.white54,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (hasAudio) ...[
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Text(_fmtClock(_pos)),
                              Expanded(
                                child: Slider(
                                  value: _pos.inMilliseconds.clamp(
                                    0,
                                    _dur.inMilliseconds == 0
                                        ? 1
                                        : _dur.inMilliseconds,
                                  ).toDouble(),
                                  min: 0,
                                  max: (_dur.inMilliseconds == 0
                                          ? 1
                                          : _dur.inMilliseconds)
                                      .toDouble(),
                                  onChanged: (v) => _seekTo(v),
                                ),
                              ),
                              Text(_fmtClock(_dur)),
                            ],
                          ),
                        ],
                        const SizedBox(height: 12),
                        // --- NEW: Summary + Ask AI buttons ---
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.summarize_outlined),
                                label: const Text('Summary'),
                                onPressed: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => TranscriptSummaryPage(
                                        transcriptId: widget.transcriptId,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton.icon(
                                icon: const Icon(Icons.chat_bubble_outline),
                                label: const Text('Ask AI'),
                                onPressed: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => TranscriptChatPage(
                                        transcriptId: widget.transcriptId,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                if (isProcessing)
                  Card(
                    elevation: 0.6,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(16),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Processing audio… you can keep browsing.',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                if (!isProcessing && labels.isNotEmpty) ...[
                  Text(
                    'People',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: labels.map((name) {
                      final count = counts[name]!;
                      return InputChip(
                        label: Text('$name  •  $count'),
                        avatar: const Icon(Icons.person, size: 18),
                        onDeleted: () => _renameSpeaker(name),
                        deleteIcon: const Icon(Icons.edit, size: 18),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                ],

                Text(
                  'Turns',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),

                if (isProcessing)
                  const Text(
                    'No segments yet. We’ll list them here when ready.',
                    style: TextStyle(color: Colors.white70),
                  ),

                if (!isProcessing)
                  ..._turns.map(
                    (u) => Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: 4),
                      child: Card(
                        elevation: 0.3,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ListTile(
                          title: Text('${u.speakerLabel}: ${u.text}'),
                          subtitle: Text(
                            '${u.startSec.toStringAsFixed(2)}–'
                            '${u.endSec.toStringAsFixed(2)}s',
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

//   void _snack(String msg) {
//     if (!mounted) return;
//     ScaffoldMessenger.of(context).hideCurrentSnackBar();
//     ScaffoldMessenger.of(context).showSnackBar(
//       SnackBar(
//         content: Text(msg),
//         behavior: SnackBarBehavior.floating,
//       ),
//     );
//   }

 }
