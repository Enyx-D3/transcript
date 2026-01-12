// lib/transcript/transcript_detail_page.dart
import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:transcript/common/app_flushbar.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter/services.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../objectbox.g.dart';

import 'background_transcriber.dart';
import 'transcript_summary_page.dart';
import 'transcript_chat_page.dart';
import '../report/report_service.dart';
import '../report/report_dialog.dart';

class _DisplayTurn {
  final String speaker;
  final String text;
  final double? startSec;
  final double? endSec;

  _DisplayTurn(this.speaker, this.text, {this.startSec, this.endSec});
}

class TranscriptDetailPage extends StatefulWidget {
  const TranscriptDetailPage({super.key, required this.transcriptId});
  final int transcriptId;

  @override
  State<TranscriptDetailPage> createState() => _TranscriptDetailPageState();
}

class _TranscriptDetailPageState extends State<TranscriptDetailPage> {
  TranscriptEntity? _t;
  List<TranscriptTurnEntity> _turns = const [];
  TranscriptionJobEntity? _job;

  Timer? _poll;
  StreamSubscription<dynamic>? _bgSub;

  final AudioPlayer _player = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
  bool _isPlaying = false;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  String? _loadedPath;

  static const _kBusyTranscribing = 'busy_transcribing';

  bool _processingFailed = false;
  String? _processingError;
  Timer? _processingWatchdog;

  final ReportService _reportService = const ReportService(
    baseUrl: 'https://enyx.app',
  );

  @override
  void initState() {
    super.initState();
    _wirePlayer();
    _loadOnce();

    _bgSub = BackgroundTranscriber.onData(_onBgData);

    _syncPoller();
    _syncWatchdog();
  }

  @override
  void dispose() {
    _bgSub?.cancel();
    _poll?.cancel();
    _processingWatchdog?.cancel();
    _player.stop();
    _player.dispose();
    super.dispose();
  }

  // ============================================================
  // ✅ Cache helpers (FTS-like)
  // ============================================================

  String _cleanTurnText(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;

    final lines = s
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    if (lines.isEmpty) return '';

    bool looksLikeTimecode(String line) {
      final l = line.trim();
      final reRangeSec = RegExp(
        r'^\d+(\.\d+)?\s*[-–]\s*\d+(\.\d+)?\s*s$',
      ); // 12.3–45.6s
      final reClock = RegExp(
        r'^\[?\d{1,2}:\d{2}(\.\d{1,3})?\]?$',
      ); // [00:12.345] or 00:12
      final reClockLong = RegExp(
        r'^\[?\d{1,2}:\d{2}:\d{2}(\.\d{1,3})?\]?$',
      ); // [01:02:03.4]
      return reRangeSec.hasMatch(l) ||
          reClock.hasMatch(l) ||
          reClockLong.hasMatch(l);
    }

    if (lines.isNotEmpty && looksLikeTimecode(lines.last)) {
      lines.removeLast();
    }

    return lines.join(' ').trim();
  }

  String _buildFullTextCacheFromTurns() {
    final b = StringBuffer();
    for (final u in _turns) {
      final txt = _cleanTurnText(u.text);
      if (txt.isEmpty) continue;
      if (b.isNotEmpty) b.write(' ');
      b.write(txt);
    }
    return b.toString().trim();
  }

  void _updateTranscriptSearchCacheInDb({TranscriptEntity? force}) {
    final obx = ObjectBox.I;
    final t = force ?? _t;
    if (t == null) return;

    final full = _buildFullTextCacheFromTurns();
    final edited = (t.editedText ?? '').trim();
    final search = edited.isNotEmpty ? edited : full;

    t.fullTextCache = full.isEmpty ? null : full;
    t.searchText = search.isEmpty ? null : search;

    obx.transcripts.put(t);

    // keep in-memory updated too
    _t = t;
  }

  // ============================================================
  // Report
  // ============================================================
  String _buildTranscriptSearchTextForReport() {
    // ✅ send the "searchText" field (edited preferred, else cached)
    final s = (_t?.searchText ?? '').trim();
    if (s.isNotEmpty) return s;

    // fallback safety: build from turns if cache not ready yet
    final fallback = _buildTranscriptText(preferEdited: true).trim();
    return fallback;
  }

  Future<void> _reportTranscript() async {
  final responseText = _buildTranscriptSearchTextForReport();
  if (responseText.isEmpty) {
    if (!mounted) return;
    await AppFlushbar.error(context, message: 'Nothing to report yet.');
    return;
  }

  await showReportDialog(
    outerContext: context,
    responseText: responseText,
    sendReport: ({
      Map<String, dynamic>? meta, // ✅ accept meta to match signature
      required String reason,
      required String note,
      required String response,
    }) async {
      // Build meta for this page (and merge if caller provided some)
      final localMeta = <String, dynamic>{
        'page': 'transcript_detail',
        'transcriptId': widget.transcriptId,
        'title': (_t?.title ?? '').trim(),
        'hasEditedText': (_t?.editedText ?? '').trim().isNotEmpty,
        'turnCount': _turns.length,
      };

      final mergedMeta = <String, dynamic>{
        if (meta != null) ...meta,
        ...localMeta,
      };

      // Keep backend unchanged: embed meta inside the note
      final combinedNote = ('[meta] $mergedMeta\n${note.trim()}').trim();

      await _reportService.sendReport(
        reason: reason,
        note: combinedNote,
        response: response, // ✅ this is searchText
      );
    },
  );
}

  // ============================================================
  // Player wiring
  // ============================================================

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
      await AppFlushbar.error(
        context,
        message: 'Audio file not available for playback.',
      );
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
    await _player.seek(Duration(milliseconds: v.round()));
  }

  // ============================================================
  // Job helpers
  // ============================================================

  bool _isJobActive(TranscriptionJobEntity? j) {
    final s = j?.status;
    return s == 'PENDING' || s == 'RUNNING';
  }

  TranscriptionJobEntity? _getLatestJob() {
    final obx = ObjectBox.I;
    final qb = obx.jobs.query(
      TranscriptionJobEntity_.transcriptId.equals(widget.transcriptId),
    )..order(TranscriptionJobEntity_.createdAt, flags: Order.descending);
    final q = qb.build();
    final rows = q.find();
    q.close();
    return rows.isEmpty ? null : rows.first;
  }

  void _persistJobError(String message) {
    final obx = ObjectBox.I;
    final job = _getLatestJob();
    if (job == null) return;

    if (job.status == 'ERROR' && (job.error ?? '') == message) {
      _job = job;
      return;
    }

    job.status = 'ERROR';
    job.error = message;
    obx.jobs.put(job);
    _job = job;
  }

  void _persistJobDone() {
    final obx = ObjectBox.I;
    final job = _getLatestJob();
    if (job == null) return;

    if (job.status == 'DONE') {
      _job = job;
      return;
    }

    job.status = 'DONE';
    job.error = null;
    obx.jobs.put(job);
    _job = job;
  }

  // ============================================================
  // Data loading
  // ============================================================

  void _loadOnce() {
    final obx = ObjectBox.I;

    final t = obx.transcripts.get(widget.transcriptId);

    final qb = obx.turns.query(
      TranscriptTurnEntity_.transcript.equals(widget.transcriptId),
    )..order(TranscriptTurnEntity_.startSec);
    final q = qb.build();
    final rows = q.find();
    q.close();

    final job = _getLatestJob();

    if (!mounted) return;
    setState(() {
      _t = t;
      _turns = rows;
      _job = job;

      if (job?.status == 'ERROR') {
        _processingFailed = true;
        _processingError =
            job?.error ?? 'Transcription failed. Please try again.';
      } else {
        if (!_processingFailed) {
          _processingError = null;
        }
      }
    });
  }

  void _refreshTick() {
    _loadOnce();
    _syncPoller();
    _syncWatchdog();

    // ✅ If we got turns, mark DONE and cache full text
    if (_turns.isNotEmpty && _job?.status != 'DONE') {
      _processingWatchdog?.cancel();
      _processingWatchdog = null;

      _persistJobDone();

      // ✅ build cache + searchText (editedText preferred)
      _updateTranscriptSearchCacheInDb();

      FlutterForegroundTask.saveData(key: _kBusyTranscribing, value: false);

      if (!mounted) return;
      setState(() {
        _processingFailed = false;
        _processingError = null;
      });

      _syncPoller();
      _syncWatchdog();
      return;
    }

    if (_job?.status == 'ERROR') {
      _poll?.cancel();
      _poll = null;
      _processingWatchdog?.cancel();
      _processingWatchdog = null;

      if (!mounted) return;
      setState(() {
        _processingFailed = true;
        _processingError =
            _job?.error ?? 'Transcription failed. Please try again.';
      });
      return;
    }
  }

  // ============================================================
  // Poller: only while PENDING/RUNNING
  // ============================================================

  void _syncPoller() {
    final active = _isJobActive(_job);

    if (active) {
      if (_poll != null) return;
      _poll = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        _refreshTick();
      });
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  // ============================================================
  // Watchdog
  // ============================================================

  Future<bool> _isFgServiceRunningSafe() async {
    try {
      return await FlutterForegroundTask.isRunningService;
    } catch (_) {
      return false;
    }
  }

  void _syncWatchdog() {
    final shouldArm =
        _isJobActive(_job) && _turns.isEmpty && !_processingFailed;

    if (!shouldArm) {
      _processingWatchdog?.cancel();
      _processingWatchdog = null;
      return;
    }

    if (_processingWatchdog != null) return;

    _processingWatchdog = Timer(const Duration(seconds: 3), () async {
      _processingWatchdog?.cancel();
      _processingWatchdog = null;

      if (!mounted) return;

      if (_turns.isNotEmpty) return;
      if (_job?.status == 'ERROR') return;

      final running = await _isFgServiceRunningSafe();
      if (running) {
        _syncWatchdog();
        return;
      }

      const msg =
          'Transcription stopped (app may have been closed). Please try again.';

      _persistJobError(msg);

      await FlutterForegroundTask.saveData(
        key: _kBusyTranscribing,
        value: false,
      );

      if (!mounted) return;
      setState(() {
        _processingFailed = true;
        _processingError = msg;
      });

      _poll?.cancel();
      _poll = null;
    });
  }

  // ============================================================
  // BG events
  // ============================================================

  Future<void> _onBgData(dynamic data) async {
    if (data is! Map) return;
    final type = data['type'];

    if (type == 'transcribe_error') {
      await FlutterForegroundTask.saveData(
        key: _kBusyTranscribing,
        value: false,
      );

      _processingWatchdog?.cancel();
      _processingWatchdog = null;

      _persistJobError('Transcription failed.');

      if (!mounted) return;
      setState(() {
        _processingFailed = true;
        _processingError = _job?.error ?? 'Transcription failed.';
      });

      _poll?.cancel();
      _poll = null;

      await AppFlushbar.error(context, message: 'Transcription Failed');
      return;
    }

    if (type != 'transcribe_result') return;

    final existingId = data['existingId'] as int?;
    if (existingId != widget.transcriptId) return;

    await FlutterForegroundTask.saveData(key: _kBusyTranscribing, value: false);

    _processingWatchdog?.cancel();
    _processingWatchdog = null;

    _persistJobDone();

    if (mounted) {
      setState(() {
        _processingFailed = false;
        _processingError = null;
      });
    }

    _refreshTick();

    _poll?.cancel();
    _poll = null;
  }

  // ============================================================
  // Edit title (✅ FIX: do not recreate entity!)
  // ============================================================

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
    final latest = obx.transcripts.get(t.id);
    if (latest == null) return;

    latest.title = newTitle.isEmpty ? null : newTitle;
    obx.transcripts.put(latest);

    _refreshTick();
  }

  // ============================================================
  // Rename speaker within transcript
  // ============================================================

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
    final qb = obx.turns.query(
      TranscriptTurnEntity_.transcript
          .equals(widget.transcriptId)
          .and(TranscriptTurnEntity_.speakerLabel.equals(oldLabel)),
    )..order(TranscriptTurnEntity_.startSec);
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
    _refreshTick();
  }

  // ============================================================
  // Edited transcript: edit/save + copy + display turns
  // ============================================================

  String _buildTranscriptText({bool preferEdited = true}) {
    final t = _t;
    if (preferEdited && (t?.editedText?.trim().isNotEmpty ?? false)) {
      return t!.editedText!.trim();
    }

    final b = StringBuffer();
    for (final u in _turns) {
      b.writeln('${u.speakerLabel}: ${u.text}');
    }
    return b.toString().trim();
  }

  List<_DisplayTurn> _buildDisplayTurns() {
    final t = _t;

    if (t?.editedText != null && t!.editedText!.trim().isNotEmpty) {
      final lines = t.editedText!.split('\n');
      final result = <_DisplayTurn>[];

      int i = 0;
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;

        final idx = trimmed.indexOf(':');
        final speaker = (idx > 0)
            ? trimmed.substring(0, idx).trim()
            : 'Speaker';
        final text = (idx > 0) ? trimmed.substring(idx + 1).trim() : trimmed;

        final ts = (i < _turns.length) ? _turns[i] : null;

        result.add(
          _DisplayTurn(
            speaker,
            text,
            startSec: ts?.startSec,
            endSec: ts?.endSec,
          ),
        );
        i++;
      }
      return result;
    }

    return _turns
        .map(
          (u) => _DisplayTurn(
            u.speakerLabel,
            u.text,
            startSec: u.startSec,
            endSec: u.endSec,
          ),
        )
        .toList();
  }

  Future<void> _copyWholeTranscript() async {
    final text = _buildTranscriptText(preferEdited: true);
    if (text.isEmpty) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Nothing to copy yet.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    await AppFlushbar.success(context, message: 'Transcript copied.');
  }

  // ✅ FIX: do not recreate entity, also update searchText
  Future<void> _editWholeTranscript() async {
    final t = _t;
    if (t == null) return;

    final initial = _buildTranscriptText(preferEdited: true);
    final ctrl = TextEditingController(text: initial);

    final newText = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit transcript'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            minLines: 10,
            maxLines: 20,
            decoration: const InputDecoration(
              hintText: 'Format: Speaker: text (one per line)',
            ),
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

    if (newText == null) return;

    final obx = ObjectBox.I;
    final latest = obx.transcripts.get(t.id);
    if (latest == null) return;

    latest.editedText = newText.isEmpty ? null : newText;

    // ✅ searchText prefers editedText, else fallback to cached full text
    final edited = (latest.editedText ?? '').trim();
    if (edited.isNotEmpty) {
      latest.searchText = edited;
    } else {
      final cached = (latest.fullTextCache ?? '').trim();
      final full = cached.isNotEmpty ? cached : _buildFullTextCacheFromTurns();
      latest.fullTextCache = full.isEmpty ? null : full;
      latest.searchText = full.isEmpty ? null : full;
    }

    obx.transcripts.put(latest);

    _refreshTick();
    if (!mounted) return;
    await AppFlushbar.success(context, message: 'Transcript saved.');
  }

  // ============================================================
  // Formatting helpers
  // ============================================================

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

  // ============================================================
  // UI
  // ============================================================

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

    final isProcessing =
        (t != null &&
        _turns.isEmpty &&
        !_processingFailed &&
        (_job?.status == 'PENDING' || _job?.status == 'RUNNING'));

    final hasAudio =
        (t?.audioPath != null &&
        t!.audioPath!.isNotEmpty &&
        File(t.audioPath!).existsSync());

    final displayTurns = _buildDisplayTurns();
    final showingEdited =
        (t?.editedText != null && t!.editedText!.trim().isNotEmpty);

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: 'Edit title',
            icon: const Icon(Icons.edit_note),
            onPressed: _t == null ? null : _editTitle,
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) {
              if (v == 'edit_transcript') _editWholeTranscript();
              if (v == 'copy_transcript') _copyWholeTranscript();
              if (v == 'report_transcript') _reportTranscript();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'edit_transcript',
                child: Text('Edit & save transcript'),
              ),
              PopupMenuItem(
                value: 'copy_transcript',
                child: Text('Copy transcript as text'),
              ),
              PopupMenuItem(
                value: 'report_transcript',
                child: Text('Report transcript'),
              ),
            ],
          ),
        ],
      ),
      body: t == null
          ? const Center(child: Text('Not found'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
              children: [
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
                                _isPlaying ? Icons.pause : Icons.play_arrow,
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
                                  value: _pos.inMilliseconds
                                      .clamp(
                                        0,
                                        _dur.inMilliseconds == 0
                                            ? 1
                                            : _dur.inMilliseconds,
                                      )
                                      .toDouble(),
                                  min: 0,
                                  max:
                                      (_dur.inMilliseconds == 0
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
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Processing audio… Do not close the app.',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                if (_processingFailed)
                  Card(
                    elevation: 0.6,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.error_outline,
                            color: Colors.redAccent,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _processingError ??
                                  'Transcription stopped. Please try again.',
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                if (!isProcessing &&
                    !_processingFailed &&
                    labels.isNotEmpty) ...[
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

                Text('Turns', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),

                if (!isProcessing && !_processingFailed && showingEdited)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Showing edited transcript',
                      style: TextStyle(
                        color: Colors.orangeAccent,
                        fontSize: 12,
                      ),
                    ),
                  ),

                if (isProcessing)
                  const Text(
                    'No segments yet. We’ll list them here when ready.',
                    style: TextStyle(color: Colors.white70),
                  ),

                if (_processingFailed)
                  const Text(
                    'No segments were generated.',
                    style: TextStyle(color: Colors.white70),
                  ),

                if (!isProcessing && !_processingFailed)
                  ...displayTurns.map(
                    (u) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Card(
                        elevation: 0.3,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ListTile(
                          title: Text('${u.speaker}: ${u.text}'),
                          subtitle: (u.startSec != null && u.endSec != null)
                              ? Text(
                                  '${u.startSec!.toStringAsFixed(2)}–'
                                  '${u.endSec!.toStringAsFixed(2)}s',
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
