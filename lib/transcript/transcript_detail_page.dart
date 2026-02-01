// lib/transcript/transcript_detail_page.dart
import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:transcript/common/app_flushbar.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter/services.dart';
import 'package:transcript/send_transcript/send_transcript_healper.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../objectbox.g.dart';

import 'background_transcriber.dart';
import 'transcript_summary_page.dart';
import 'transcript_chat_page.dart';
import '../report/report_service.dart';
import '../report/report_dialog.dart';
import 'package:share_plus/share_plus.dart';

class _DisplayTurn {
  final String speaker;
  final String text;
  final double? startSec;
  final double? endSec;

  _DisplayTurn(this.speaker, this.text, {this.startSec, this.endSec});
}

enum _AudioVariant { original, enhanced }

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
  final mailer = TranscriptMailService(baseUrl: 'https://enyx.app');

  _AudioVariant _audioVariant = _AudioVariant.original;

  // ============================================================
  // Lifecycle
  // ============================================================

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
  // Playback gating (✅ disable until transcription ends)
  // ============================================================

  bool get _isTranscribingNow {
    final s = _job?.status;
    return s == 'PENDING' || s == 'RUNNING';
  }

  Future<void> _stopPlaybackIfNeeded() async {
    if (!_isTranscribingNow) return;

    try {
      await _player.stop();
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _isPlaying = false;
      _pos = Duration.zero;
      _loadedPath = null; // force reload when allowed again
    });
  }

  // ============================================================
  // ✅ Audio source selection (Original / Enhanced)
  // ============================================================

  String? _getOriginalPath() =>
      _t?.audioPath?.trim().isEmpty ?? true ? null : _t!.audioPath!.trim();

  String? _getEnhancedPath() => _t?.processedAudioPath?.trim().isEmpty ?? true
      ? null
      : _t!.processedAudioPath!.trim();

  String? _getSelectedPath() {
    final orig = _getOriginalPath();
    final enh = _getEnhancedPath();

    if (_audioVariant == _AudioVariant.enhanced) {
      return enh ?? orig;
    }
    return orig ?? enh;
  }

  bool _fileExists(String? path) {
    if (path == null || path.trim().isEmpty) return false;
    return File(path).existsSync();
  }

  void _debugPrintAudioPaths() {
    final orig = _getOriginalPath();
    final enh = _getEnhancedPath();
    debugPrint('[AUDIO][DB] original: $orig');
    debugPrint('[AUDIO][DB] enhanced: $enh');
    debugPrint('[AUDIO][DB] original exists: ${_fileExists(orig)}');
    debugPrint('[AUDIO][DB] enhanced exists: ${_fileExists(enh)}');
    debugPrint('[AUDIO][DB] selected variant: $_audioVariant');
    debugPrint('[AUDIO][DB] selected path: ${_getSelectedPath()}');
  }

  // ============================================================
  // Cache helpers (FTS-like)
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
      final reRangeSec = RegExp(r'^\d+(\.\d+)?\s*[-–]\s*\d+(\.\d+)?\s*s$');
      final reClock = RegExp(r'^\[?\d{1,2}:\d{2}(\.\d{1,3})?\]?$');
      final reClockLong = RegExp(r'^\[?\d{1,2}:\d{2}:\d{2}(\.\d{1,3})?\]?$');
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
    _t = t;
  }

  // ============================================================
  // Report
  // ============================================================

  String _buildTranscriptSearchTextForReport() {
    final s = (_t?.searchText ?? '').trim();
    if (s.isNotEmpty) return s;
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
      sendReport:
          ({
            Map<String, dynamic>? meta,
            required String reason,
            required String note,
            required String response,
          }) async {
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

            final combinedNote = ('[meta] $mergedMeta\n${note.trim()}').trim();

            await _reportService.sendReport(
              reason: reason,
              note: combinedNote,
              response: response,
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
    if (_isTranscribingNow) return false;

    final path = _getSelectedPath();
    if (path == null || path.isEmpty) return false;

    final f = File(path);
    if (!f.existsSync()) {
      _debugPrintAudioPaths();
      return false;
    }

    if (_loadedPath != path) {
      await _player.setSource(DeviceFileSource(path));
      _loadedPath = path;

      // ✅ Try to fetch duration immediately
      try {
        final d = await _player.getDuration();
        if (d != null && mounted) setState(() => _dur = d);
      } catch (_) {}
    }

    return true;
  }

  Future<void> _togglePlayPause() async {
    if (_isTranscribingNow) {
      if (!mounted) return;
      await AppFlushbar.info(
        context,
        message: 'Audio playback is disabled while transcription is running.',
      );
      return;
    }

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
    if (_isTranscribingNow) return;
    await _player.seek(Duration(milliseconds: v.round()));
  }

  Future<void> _switchVariant(_AudioVariant v) async {
    if (_isTranscribingNow) return;

    if (v == _audioVariant) return;

    // stop playback before switching sources
    try {
      await _player.stop();
    } catch (_) {}

    setState(() {
      _audioVariant = v;
      _isPlaying = false;
      _pos = Duration.zero;
      _dur = Duration.zero;
      _loadedPath = null; // force reload
    });
    await _ensureSourceLoaded();
    _debugPrintAudioPaths();
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

    // ✅ log + enforce "no playback while transcribing"
    _debugPrintAudioPaths();
    _stopPlaybackIfNeeded();
  }

  void _refreshTick() {
    _loadOnce();
    _syncPoller();
    _syncWatchdog();

    if (_turns.isNotEmpty && _job?.status != 'DONE') {
      _processingWatchdog?.cancel();
      _processingWatchdog = null;

      _persistJobDone();
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
  // Edit title
  // ============================================================

  Future<void> _editTitle() async {
  final t = _t;
  if (t == null) return;

  final ctrl = TextEditingController(text: t.title ?? '');

  final newTitle = await showDialog<String>(
    context: context,
    builder: (ctx) {
      const accent = Colors.white; // 👈 change if you want

      return Theme(
        data: Theme.of(ctx).copyWith(
          textSelectionTheme: const TextSelectionThemeData(
            selectionHandleColor: Colors.white, // ✅ droplet = white
            cursorColor: accent,                // cursor color
            selectionColor: Color(0x337C4DFF),  // selection highlight
          ),
        ),
        child: AlertDialog(
          title: const Text('Edit title'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            cursorColor: accent,
            decoration: const InputDecoration(
              labelText: 'Title',
              labelStyle: TextStyle(color: Colors.white),
              hintText: 'e.g. Team meeting',
              hintStyle: TextStyle(color: Colors.white54),

              // ✅ underline when not focused
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: accent, width: 1.5),
              ),

              // ✅ underline when focused
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: accent, width: 2),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: Colors.white)),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              style: OutlinedButton.styleFrom(backgroundColor: Colors.white),
              child: const Text('Save', style: TextStyle(color: Colors.black)),
            ),
          ],
        ),
      );
    },
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

  Future<void> _shareWholeTranscript() async {
    final text = _buildTranscriptText(preferEdited: true).trim();
    if (text.isEmpty) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Nothing to share yet.');
      return;
    }

    try {
      final dir = await getTemporaryDirectory();

      final safeTitle =
          ((_t?.title ?? 'transcript').trim().isEmpty
                  ? 'transcript'
                  : _t!.title!)
              .trim()
              .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();

      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final file = File('${dir.path}/$safeTitle-$stamp.txt');

      await file.writeAsString(text, flush: true);

      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(
              file.path,
              mimeType: 'text/plain',
              name: file.uri.pathSegments.last,
            ),
          ],
          subject: safeTitle,
          text: 'Transcript attached.',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Could not share file.');
    }
  }

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
  // ✅ Turn long-press actions (discoverable editing)
  // ============================================================

  Future<void> _showTurnActions(int turnId) async {
    final t = _t;
    if (t == null) return;

    final showingEdited = (t.editedText ?? '').trim().isNotEmpty;
    if (showingEdited) {
      if (!mounted) return;
      await AppFlushbar.info(
        context,
        message:
            'You are viewing the edited transcript. Use “Edit & save transcript” to edit.',
      );
      return;
    }

    final obx = ObjectBox.I;
    final turn = obx.turns.get(turnId);
    if (turn == null) return;

    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF101018),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withOpacity(0.10)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 10),
                ListTile(
                  leading: const Icon(Icons.edit_outlined, color: Colors.white),
                  title: const Text(
                    'Edit segment',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  subtitle: const Text(
                    'Fix wording for this segment only',
                    style: TextStyle(color: Colors.white70),
                  ),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _editSingleTurn(turn);
                  },
                ),
                // ListTile(
                //   leading: const Icon(
                //     Icons.person_outline,
                //     color: Colors.white,
                //   ),
                //   title: const Text(
                //     'Rename speaker',
                //     style: TextStyle(
                //       color: Colors.white,
                //       fontWeight: FontWeight.w800,
                //     ),
                //   ),
                //   subtitle: Text(
                //     turn.speakerLabel,
                //     style: const TextStyle(color: Colors.white70),
                //   ),
                //   onTap: () {
                //     Navigator.pop(ctx);
                //     _renameSpeaker(turn.speakerLabel);
                //   },
                // ),
                ListTile(
                  leading: const Icon(Icons.copy_rounded, color: Colors.white),
                  title: const Text(
                    'Copy segment',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await Clipboard.setData(
                      ClipboardData(text: '${turn.speakerLabel}: ${turn.text}'),
                    );
                    if (!mounted) return;
                    await AppFlushbar.success(
                      context,
                      message: 'Segment copied.',
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _editSingleTurn(TranscriptTurnEntity turn) async {
    final ctrl = TextEditingController(text: turn.text);

    final newText = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit segment'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(hintText: 'Edit what was said…'),
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
    final latest = obx.turns.get(turn.id);
    if (latest == null) return;

    latest.text = newText;
    obx.turns.put(latest);

    _refreshTick();
    _updateTranscriptSearchCacheInDb();

    if (!mounted) return;
    await AppFlushbar.success(context, message: 'Segment updated.');
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

  String _fmtMetaShort(TranscriptEntity t) {
    final d = t.createdAt.toLocal();
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  String _fmtDuration(double seconds) {
    final safe = seconds.isFinite && seconds >= 0 ? seconds : 0.0;
    final total = safe.round();
    final m = (total ~/ 60).toString();
    final ss = (total % 60).toString().padLeft(2, '0');
    return '${m}m${ss}s';
  }

  String _fmtClock(Duration d) {
    final totalSeconds = d.inSeconds;
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;

    if (h > 0) {
      return '${h.toString()}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // ============================================================
  // UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final t = _t;
    if (t == null) {
      return const Scaffold(body: Center(child: Text('Not found')));
    }

    final title = (t.title?.trim().isNotEmpty ?? false)
        ? t.title!.trim()
        : 'Transcript';

    // speaker counts
    final counts = <String, int>{};
    for (final u in _turns) {
      counts[u.speakerLabel] = (counts[u.speakerLabel] ?? 0) + 1;
    }
    final labels = counts.keys.toList()..sort();

    final isProcessing =
        (_turns.isEmpty &&
        !_processingFailed &&
        (_job?.status == 'PENDING' || _job?.status == 'RUNNING'));

    final origPath = _getOriginalPath();
    final enhPath = _getEnhancedPath();
    final origExists = _fileExists(origPath);
    final enhExists = _fileExists(enhPath);

    // gently fall back (same behavior)
    if (_audioVariant == _AudioVariant.enhanced && !enhExists && origExists) {
      _audioVariant = _AudioVariant.original;
    }

    final hasAnyAudio = origExists || enhExists;
    final canPlayAudio = hasAnyAudio && !_isTranscribingNow;

    final displayTurns = _buildDisplayTurns();
    final showingEdited =
        (t.editedText != null && t.editedText!.trim().isNotEmpty);

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
          children: [
            // ================= HEADER =================
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _IconPillButton(
                  tooltip: 'Back',
                  icon: Icons.arrow_back,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(child: _MetaPill(text: 'Lang • ${t.lang}')),
                          const SizedBox(width: 8),
                          Expanded(child: _MetaPill(text: _fmtMetaShort(t))),
                        ],
                      ),
                      if (showingEdited) ...[
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: _MetaPill(
                            text: 'Edited',
                            accent: Colors.orangeAccent,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _IconPillButton(
                  tooltip: 'Edit title',
                  icon: Icons.edit_note,
                  onTap: _editTitle,
                ),
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  onSelected: (v) {
                    if (v == 'edit_transcript') _editWholeTranscript();
                    if (v == 'copy_transcript') _copyWholeTranscript();
                    if (v == 'report_transcript') _reportTranscript();
                  },
                  itemBuilder: (_) => const [
                    // PopupMenuItem(
                    //   value: 'edit_transcript',
                    //   child: Text('Edit & save transcript'),
                    // ),
                    // PopupMenuItem(
                    //   value: 'copy_transcript',
                    //   child: Text('Copy transcript as text'),
                    // ),
                    PopupMenuItem(
                      value: 'report_transcript',
                      child: Text('Report transcript'),
                    ),
                  ],
                  child: const _IconPillButton(
                    tooltip: 'More',
                    icon: Icons.more_horiz,
                    onTap: null,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 14),

            // ================= AUDIO + ACTIONS (COMPACT) =================
            _Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _CompactAudioBar(
                    isDark: isDark,
                    isTranscribingNow: _isTranscribingNow,
                    hasAnyAudio: hasAnyAudio,
                    canPlayAudio: canPlayAudio,
                    isPlaying: _isPlaying,
                    audioVariant: _audioVariant,
                    origExists: origExists,
                    enhExists: enhExists,
                    onToggle: _togglePlayPause,
                    onSwitch: _switchVariant,
                  ),
                  if (canPlayAudio) ...[
                    const SizedBox(height: 8),
                    _CompactSeekRow(
                      pos: _pos,
                      dur: _dur,
                      fmt: _fmtClock,
                      onSeek: _seekTo,
                    ),
                  ],
                  const SizedBox(height: 10),
                  Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              icon: const Icon(
                                Icons.summarize_outlined,
                                color: Colors.black,
                              ),
                              label: const Text(
                                'Summary',
                                style: TextStyle(color: Colors.black),
                              ),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 40),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                visualDensity: VisualDensity.compact,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                backgroundColor: Colors.white,
                              ),
                              onPressed: _isTranscribingNow
                                  ? null
                                  : () {
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
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.icon(
                              icon: const Icon(
                                Icons.chat_bubble_outline,
                                color: Colors.black,
                              ),
                              label: const Text(
                                'Ask AI',
                                style: TextStyle(color: Colors.black),
                              ),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 40),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                visualDensity: VisualDensity.compact,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                backgroundColor: Colors.white,
                              ),
                              onPressed: _isTranscribingNow
                                  ? null
                                  : () {
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
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(
                                Icons.copy_rounded,
                                color: Colors.white,
                              ),
                              label: const Text(
                                'Copy',
                                style: TextStyle(color: Colors.white),
                              ),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 40),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                visualDensity: VisualDensity.compact,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: _isTranscribingNow
                                  ? null
                                  : _copyWholeTranscript,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(
                                Icons.ios_share_rounded,
                                color: Colors.white,
                              ),
                              label: const Text(
                                'Share',
                                style: TextStyle(color: Colors.white),
                              ),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 40),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                visualDensity: VisualDensity.compact,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: _isTranscribingNow
                                  ? null
                                  : _shareWholeTranscript,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ================= STATUS (PROCESSING / ERROR) =================
            if (isProcessing)
              _Panel(
                child: Row(
                  children: const [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        backgroundColor: Colors.white12,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Processing audio… Do not close the app.',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
              ),

            if (_processingFailed)
              _Panel(
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _processingError ??
                            'Transcription failed. Please try again.',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            if (isProcessing || _processingFailed) const SizedBox(height: 12),

            // ================= PEOPLE =================
            if (!isProcessing && !_processingFailed && labels.isNotEmpty) ...[
              Row(
                children: [
                  Text(
                    'People',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Spacer(),
                  _MetaPill(text: '${labels.length}'),
                ],
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
              const SizedBox(height: 14),
            ],

            // ================= TURNS =================
            Row(
              children: [
                Text(
                  'Turns',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (!isProcessing) ...[
                  const SizedBox(width: 8),
                  Text(
                    'Long-press for options',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const Spacer(),
                _MetaPill(text: '${displayTurns.length}'),
              ],
            ),
            const SizedBox(height: 8),

            // if (!isProcessing && !_processingFailed && showingEdited)
            //   const Padding(
            //     padding: EdgeInsets.only(bottom: 8),
            //     child: Text(
            //       'Showing edited transcript',
            //       style: TextStyle(
            //         color: Colors.orangeAccent,
            //         fontSize: 12,
            //         fontWeight: FontWeight.w800,
            //       ),
            //     ),
            //   ),
            if (isProcessing)
              const _InlineHint(
                text: 'No segments yet. We’ll list them here when ready.',
              ),
            if (_processingFailed)
              const _InlineHint(text: 'No segments were generated.'),

            if (!isProcessing && !_processingFailed)
              ...List.generate(displayTurns.length, (i) {
                final u = displayTurns[i];

                final subtitle = (u.startSec != null && u.endSec != null)
                    ? '${u.startSec!.toStringAsFixed(2)}–${u.endSec!.toStringAsFixed(2)}s'
                    : null;

                // real turn id when NOT showing edited
                final turnId = (!showingEdited && i < _turns.length)
                    ? _turns[i].id
                    : null;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: GestureDetector(
                    onLongPress: turnId == null
                        ? null
                        : () => _showTurnActions(turnId),
                    child: _TurnCard(
                      speaker: u.speaker,
                      text: u.text,
                      subtitle: subtitle,
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg = isDark ? const Color(0xFF101018) : theme.colorScheme.surface;
    final border = isDark
        ? Colors.white.withOpacity(0.10)
        : Colors.black.withOpacity(0.08);

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            color: Colors.black.withOpacity(isDark ? 0.25 : 0.08),
            offset: const Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: child,
    );
  }
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.text, this.accent});
  final String text;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final c = accent;

    return Container(
      height: 32,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: (c ?? Colors.white).withOpacity(0.06),
        border: Border.all(color: (c ?? Colors.white).withOpacity(0.12)),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: c != null ? c.withOpacity(0.95) : Colors.white70,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _IconPillButton extends StatelessWidget {
  const _IconPillButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: (isDark ? Colors.white : Colors.black).withOpacity(0.06),
            border: Border.all(
              color: (isDark ? Colors.white : Colors.black).withOpacity(0.10),
            ),
          ),
          child: Icon(icon, size: 20),
        ),
      ),
    );
  }
}

class _InlineHint extends StatelessWidget {
  const _InlineHint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white70,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ✅ Professional turn card:
// top row: timestamp • speaker
// bottom: text
class _TurnCard extends StatelessWidget {
  const _TurnCard({required this.speaker, required this.text, this.subtitle});

  final String speaker;
  final String text;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              if (subtitle != null) ...[
                const SizedBox(width: 8),
                Text(
                  '•',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.25),
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  speaker,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.1,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: Colors.white.withOpacity(0.06),
                  border: Border.all(color: Colors.white.withOpacity(0.10)),
                ),
                child: const Icon(Icons.record_voice_over_outlined, size: 16),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            text,
            style: const TextStyle(
              height: 1.35,
              fontSize: 14.5,
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

// ===================== COMPACT AUDIO UI HELPERS =====================

class _CompactAudioBar extends StatelessWidget {
  const _CompactAudioBar({
    required this.isDark,
    required this.isTranscribingNow,
    required this.hasAnyAudio,
    required this.canPlayAudio,
    required this.isPlaying,
    required this.audioVariant,
    required this.origExists,
    required this.enhExists,
    required this.onToggle,
    required this.onSwitch,
  });

  final bool isDark;
  final bool isTranscribingNow;
  final bool hasAnyAudio;
  final bool canPlayAudio;
  final bool isPlaying;
  final _AudioVariant audioVariant;
  final bool origExists;
  final bool enhExists;
  final Future<void> Function() onToggle;
  final Future<void> Function(_AudioVariant) onSwitch;

  @override
  Widget build(BuildContext context) {
    final title = isTranscribingNow
        ? 'Processing…'
        : (hasAnyAudio ? 'Audio' : 'No audio');

    final subtitle = isTranscribingNow
        ? 'Playback disabled'
        : (hasAnyAudio
              ? (audioVariant == _AudioVariant.enhanced
                    ? 'Enhanced'
                    : 'Original')
              : 'Missing file');

    return Row(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: canPlayAudio ? onToggle : null,
          child: Ink(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: (isDark ? Colors.white : Colors.black).withOpacity(0.06),
              border: Border.all(
                color: (isDark ? Colors.white : Colors.black).withOpacity(0.10),
              ),
            ),
            child: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 22,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
        if (!isTranscribingNow && (origExists || enhExists))
          _VariantDropdown(
            value: audioVariant,
            origEnabled: origExists,
            enhEnabled: enhExists,
            onChanged: (v) => onSwitch(v),
          ),
      ],
    );
  }
}

class _VariantDropdown extends StatelessWidget {
  const _VariantDropdown({
    required this.value,
    required this.origEnabled,
    required this.enhEnabled,
    required this.onChanged,
  });

  final _AudioVariant value;
  final bool origEnabled;
  final bool enhEnabled;
  final ValueChanged<_AudioVariant> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.white.withOpacity(0.06),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<_AudioVariant>(
          value: value,
          dropdownColor: const Color(0xFF101018),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
          items: [
            DropdownMenuItem(
              value: _AudioVariant.original,
              enabled: origEnabled,
              child: Text(origEnabled ? 'Original' : 'Original (missing)'),
            ),
            DropdownMenuItem(
              value: _AudioVariant.enhanced,
              enabled: enhEnabled,
              child: Text(enhEnabled ? 'Enhanced' : 'Enhanced (missing)'),
            ),
          ],
          onChanged: (v) {
            if (v == null) return;
            onChanged(v);
          },
        ),
      ),
    );
  }
}

class _CompactSeekRow extends StatelessWidget {
  const _CompactSeekRow({
    required this.pos,
    required this.dur,
    required this.fmt,
    required this.onSeek,
  });

  final Duration pos;
  final Duration dur;
  final String Function(Duration) fmt;
  final Future<void> Function(double) onSeek;

  @override
  Widget build(BuildContext context) {
    final maxMs = (dur.inMilliseconds == 0 ? 1 : dur.inMilliseconds).toDouble();
    final v = pos.inMilliseconds.clamp(0, maxMs.toInt()).toDouble();

    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            fmt(pos),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Colors.white, // left / played
              inactiveTrackColor: Colors.white12, // right / remaining
              thumbColor: Colors.white, // knob
              overlayColor: Colors.white12, // press glow (optional)
              trackHeight: 3, // thickness (optional)
            ),
            child: Slider(
              value: v,
              min: 0,
              max: maxMs,
              onChanged: (x) => onSeek(x),
            ),
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            fmt(dur),
            textAlign: TextAlign.right,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      ],
    );
  }
}
