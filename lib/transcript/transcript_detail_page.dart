// lib/transcript/transcript_detail_page.dart
import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

// ✅ NEW: auto-summary preference + model access
import 'package:shared_preferences/shared_preferences.dart';
import '../llm_service.dart' show LLMService, qwenMaxContext;
import '../qwen_model_service.dart';

import '../common/app_flushbar.dart';
import '../objectbox/entities.dart';
import '../objectbox/objectbox_store.dart';
import '../objectbox.g.dart';
import '../report/report_dialog.dart';
import '../report/report_service.dart';
import '../send_transcript/send_transcript_healper.dart';

import 'background_transcriber.dart';
import 'transcript_chat_page.dart';
import 'transcript_summary_page.dart';

// ✅ Glass primitives
import '../ui/glass/glass_background.dart';
import '../ui/glass/glass_button.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/glass_tokens.dart';
import '../ui/glass/liquid_glass.dart';

// ✅ Use this for pill icon buttons (same as Enrollment reference)
import '../widgets/icon_pill_button.dart';

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

  // ✅ Coordinator-driven global busy flag
  bool _busyFlag = false;

  static const _kBusyTranscribing = 'busy_transcribing';
  static const _kProgressProcessedSec = 'progress_processed_sec';
  static const _kProgressTotalSec = 'progress_total_sec';
  static const _kProgressStage = 'progress_stage';

  double _progressProcessedSec = 0.0;
  double _progressTotalSec = 0.0;
  String _progressStage = 'Processing';

  bool _processingFailed = false;
  String? _processingError;
  Timer? _processingWatchdog;

  final ReportService _reportService = const ReportService(
    baseUrl: 'https://enyx.app',
  );
  final mailer = TranscriptMailService(baseUrl: 'https://enyx.app');

  // ============================================================
  // ✅ Auto-summary (Balanced)
  // ============================================================

  static const String _kPrefAutoSummaryEnabled = 'pref_auto_summary_enabled';
  static const int _balancedSummaryMaxTokens = 650; // ✅ Balanced fixed
  String _summaryBusyKey(int id) => 'summary_busy_$id';
  bool _autoSummaryKickoffTried = false;

  Future<bool> _isAutoSummaryEnabled() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getBool(_kPrefAutoSummaryEnabled) ?? true; // ✅ default ON
    } catch (_) {
      return true;
    }
  }

  Future<bool> _isSummaryBusy() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getBool(_summaryBusyKey(widget.transcriptId)) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _setSummaryBusy(bool v) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_summaryBusyKey(widget.transcriptId), v);
    } catch (_) {}
  }

  /// ✅ Silent auto summary (Balanced). Does NOTHING if:
  /// - setting OFF
  /// - still busy
  /// - error
  /// - no turns
  /// - summary already exists
  /// - model not downloaded
  Future<void> _maybeAutoGenerateSummaryBalanced() async {
    if (_autoSummaryKickoffTried) return;
    _autoSummaryKickoffTried = true;

    // Only after transcription ended successfully
    if (_busyFlag) return;
    if (_processingFailed) return;

    // Setting gate
    final enabled = await _isAutoSummaryEnabled();
    if (!enabled) return;

    // Avoid duplicates across pages
    if (await _isSummaryBusy()) return;

    final obx = ObjectBox.I;

    // If already have summary -> skip
    final qb = obx.summaries.query(
      TranscriptSummaryEntity_.transcriptId.equals(widget.transcriptId),
    );
    final q = qb.build();
    final existing = q.findFirst();
    q.close();
    if (existing != null && existing.summary.trim().isNotEmpty) return;

    // Model must exist; if not, skip silently
    final qwen = QwenModelService();
    final ok = await qwen.isModelDownloaded();
    if (!ok) return;
    final modelPath = await qwen.modelFilePath();

    // Build transcript text from turns
    if (_turns.isEmpty) return;
    final buf = StringBuffer();
    for (final u in _turns) {
      final txt = u.text.trim();
      if (txt.isEmpty) continue;
      buf.writeln('${u.speakerLabel}: $txt');
    }
    final transcriptText = buf.toString().trim();
    if (transcriptText.isEmpty) return;

    // ✅ mark busy when auto summary starts
    await _setSummaryBusy(true);

    String latestFullText = '';
    StreamSubscription<Map<String, dynamic>>? sub;
    final done = Completer<void>();

    try {
      final stream = LLMService.summarizeTranscript(
        transcript: transcriptText,
        modelPath: modelPath,
        maxTokens: _balancedSummaryMaxTokens,
        temperature: 0.3,
        contextSize: qwenMaxContext,
      );

      sub = stream.listen(
        (evt) {
          final full = (evt['full_text'] ?? '') as String;
          if (full.isNotEmpty) latestFullText = full;
        },
        onError: (_, _) {
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );

      await done.future;

      final finalText = latestFullText.trim();
      if (finalText.isNotEmpty) {
        final entity = TranscriptSummaryEntity(
          id: existing?.id ?? 0,
          transcriptId: widget.transcriptId,
          summary: finalText,
          updatedAt: DateTime.now(),
        );
        obx.summaries.put(entity);
      }
    } catch (_) {
      // silent
    } finally {
      await sub?.cancel();
      await _setSummaryBusy(false);
    }
  }

  // ============================================================
  // Lifecycle
  // ============================================================

  @override
  void initState() {
    super.initState();
    _wirePlayer();
    _bgSub = BackgroundTranscriber.onData(_onBgData);

    // ✅ do one async refresh immediately so loading shows correctly
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _refreshTick();
    });
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
  // ✅ Busy flag (coordinator is the truth)
  // ============================================================

  Future<bool> _readBusyFlag() async {
    try {
      final v = await FlutterForegroundTask.getData(key: _kBusyTranscribing);
      return v == true;
    } catch (_) {
      return false;
    }
  }

  // Coordinator-based “processing right now”
  bool get _isProcessingNow => _busyFlag && !_processingFailed;

  // ✅ Playback gating should follow busy flag (not job status)
  bool get _isTranscribingNow => _isProcessingNow;

  // ============================================================
  // Playback gating
  // ============================================================

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
  // ✅ Progress
  // ============================================================

  Future<void> _pullProgressFromFgStorage() async {
    try {
      final processedRaw = await FlutterForegroundTask.getData(
        key: _kProgressProcessedSec,
      );
      final totalRaw = await FlutterForegroundTask.getData(
        key: _kProgressTotalSec,
      );
      final stageRaw = await FlutterForegroundTask.getData(
        key: _kProgressStage,
      );

      final processed = (processedRaw is num) ? processedRaw.toDouble() : null;
      final total = (totalRaw is num) ? totalRaw.toDouble() : null;
      final stage = (stageRaw is String) ? stageRaw : null;

      if (!mounted) return;
      setState(() {
        if (processed != null) _progressProcessedSec = processed;
        if (total != null) _progressTotalSec = total;
        if (stage != null && stage.trim().isNotEmpty) {
          _progressStage = stage.trim();
        }
      });
    } catch (_) {}
  }

  // ============================================================
  // ✅ Audio source (only original)
  // ============================================================

  String? _getOriginalPath() =>
      _t?.audioPath?.trim().isEmpty ?? true ? null : _t!.audioPath!.trim();

  bool _fileExists(String? path) {
    if (path == null || path.trim().isEmpty) return false;
    return File(path).existsSync();
  }

  void _debugPrintAudioPaths() {
    final orig = _getOriginalPath();
    debugPrint('[AUDIO][DB] original: $orig');
    debugPrint('[AUDIO][DB] original exists: ${_fileExists(orig)}');
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

    final full = _buildFullTextCacheFromTurns().trim();
    final edited = (t.editedText ?? '').trim();
    final search = edited.isNotEmpty ? edited : full;

    // ---------- Auto-title only if empty ----------
    final existingTitle = (t.title ?? '').trim();

    if (existingTitle.isEmpty && full.isNotEmpty) {
      final words = full
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .toList();

      final firstFive = words.take(5).join(' ');
      final autoTitle = words.length > 5 ? '$firstFive…' : firstFive;

      t.title = autoTitle;
    }

    // ---------- Caches ----------
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
      sendReport: ({
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

    final path = _getOriginalPath();
    if (path == null || path.isEmpty) return false;

    final f = File(path);
    if (!f.existsSync()) {
      _debugPrintAudioPaths();
      return false;
    }

    if (_loadedPath != path) {
      await _player.setSource(DeviceFileSource(path));
      _loadedPath = path;

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

  // ============================================================
  // Job helpers (kept for history + error persistence)
  // ============================================================

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

  void _persistJobRunningIfNeeded() {
    final obx = ObjectBox.I;
    final job = _getLatestJob();
    if (job == null) return;

    if (job.status == 'RUNNING' || job.status == 'PENDING') {
      _job = job;
      return;
    }

    job.status = 'RUNNING';
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
        if (!_processingFailed) _processingError = null;
      }
    });

    _debugPrintAudioPaths();
    _stopPlaybackIfNeeded();
  }

  // ============================================================
  // ✅ Core refresh loop (busy flag drives UI)
  // ============================================================

  Future<void> _refreshTick() async {
    _loadOnce();
    await _pullProgressFromFgStorage();

    final newBusy = await _readBusyFlag();

    final busyChanged = newBusy != _busyFlag;
    _busyFlag = newBusy;

    // Keep job status consistent for anything still reading it
    if (_busyFlag && !_processingFailed) {
      _persistJobRunningIfNeeded();
    }

    // If busy ended, mark done (but only if no error)
    if (!_busyFlag && !_processingFailed) {
      if (_job != null && _job!.status != 'DONE') {
        _persistJobDone();
      }
      _updateTranscriptSearchCacheInDb();

      // ✅ auto-generate summary (Balanced) after finish
      unawaited(_maybeAutoGenerateSummaryBalanced());
    }

    // If job is error, stop everything
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

    // Resync timers
    _syncPoller();
    _syncWatchdog();

    // Force rebuild when busy flips even if DB state didn’t change yet
    if (busyChanged && mounted) setState(() {});
  }

  // ============================================================
  // Poller: driven by busy flag
  // ============================================================

  void _syncPoller() {
    final active = _busyFlag && !_processingFailed;

    if (active) {
      if (_poll != null) return;
      _poll = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (!mounted) return;
        await _refreshTick();
      });
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  // ============================================================
  // Watchdog (still valid: detects service died before first chunk)
  // ============================================================

  Future<bool> _isFgServiceRunningSafe() async {
    try {
      return await FlutterForegroundTask.isRunningService;
    } catch (_) {
      return false;
    }
  }

  void _syncWatchdog() {
    // ✅ Arm only when busy, no turns yet, and no error
    final shouldArm = _busyFlag && _turns.isEmpty && !_processingFailed;

    if (!shouldArm) {
      _processingWatchdog?.cancel();
      _processingWatchdog = null;
      return;
    }

    if (_processingWatchdog != null) return;

    _processingWatchdog = Timer(const Duration(seconds: 5), () async {
      _processingWatchdog?.cancel();
      _processingWatchdog = null;

      if (!mounted) return;

      // If turns arrived, no problem.
      if (_turns.isNotEmpty) return;

      // If service still running, re-arm.
      final running = await _isFgServiceRunningSafe();
      if (running) {
        _syncWatchdog();
        return;
      }

      const msg =
          'Transcription stopped (app may have been closed). Please try again.';

      _persistJobError(msg);

      try {
        await FlutterForegroundTask.saveData(
          key: _kBusyTranscribing,
          value: false,
        );
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _busyFlag = false;
        _processingFailed = true;
        _processingError = msg;
      });

      _poll?.cancel();
      _poll = null;
    });
  }

  // ============================================================
  // BG events (optional – chunk pipeline may not emit these)
  // ============================================================

  Future<void> _onBgData(dynamic data) async {
    if (data is! Map) return;
    final type = data['type'];

    if (type == 'transcribe_error') {
      try {
        await FlutterForegroundTask.saveData(
          key: _kBusyTranscribing,
          value: false,
        );
      } catch (_) {}

      _processingWatchdog?.cancel();
      _processingWatchdog = null;

      _persistJobError('Transcription failed.');

      if (!mounted) return;
      setState(() {
        _busyFlag = false;
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

    try {
      await FlutterForegroundTask.saveData(
        key: _kBusyTranscribing,
        value: false,
      );
    } catch (_) {}

    _processingWatchdog?.cancel();
    _processingWatchdog = null;

    _persistJobDone();
    _updateTranscriptSearchCacheInDb();

    // NOTE: _refreshTick() will also trigger auto-summary after busy flips false.
    if (mounted) {
      setState(() {
        _busyFlag = false;
        _processingFailed = false;
        _processingError = null;
      });
    }

    await _refreshTick();
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
        const accent = Colors.white;

        return Theme(
          data: Theme.of(ctx).copyWith(
            textSelectionTheme: const TextSelectionThemeData(
              selectionHandleColor: Colors.white,
              cursorColor: accent,
              selectionColor: Color.fromARGB(128, 255, 130, 67),
            ),
          ),
          child: AlertDialog(
            backgroundColor: Colors.black87,
            surfaceTintColor: Colors.transparent,
            title: const Text(
              'Edit title',
              style: TextStyle(color: Colors.white),
            ),
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
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: accent, width: 1.5),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: accent, width: 2),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Colors.white),
                ),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                style: OutlinedButton.styleFrom(backgroundColor: Colors.white),
                child: const Text(
                  'Save',
                  style: TextStyle(color: Colors.black),
                ),
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

    await _refreshTick();
  }

  // ============================================================
  // Rename speaker
  // ============================================================

  Future<void> _renameSpeaker(String oldLabel) async {
    final ctrl = TextEditingController(text: oldLabel);
    final newLabel = await showDialog<String>(
      context: context,
      builder: (ctx) {
        const accent = Colors.white;

        return Theme(
          data: Theme.of(ctx).copyWith(
            textSelectionTheme: const TextSelectionThemeData(
              selectionHandleColor: Colors.white,
              cursorColor: accent,
              selectionColor: Color.fromARGB(128, 255, 130, 67),
            ),
          ),
          child: AlertDialog(
            backgroundColor: Colors.black87,
            surfaceTintColor: Colors.transparent,
            title: const Text(
              'Rename speaker',
              style: TextStyle(color: Colors.white),
            ),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              cursorColor: accent,
              decoration: const InputDecoration(
                labelText: 'Name',
                labelStyle: TextStyle(color: Colors.white),
                hintText: 'e.g. Alex',
                hintStyle: TextStyle(color: Colors.white54),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: accent, width: 1.5),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: accent, width: 2),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Colors.white),
                ),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                style: OutlinedButton.styleFrom(backgroundColor: Colors.white),
                child: const Text(
                  'Save',
                  style: TextStyle(color: Colors.black),
                ),
              ),
            ],
          ),
        );
      },
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

    await _refreshTick();
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
        final speaker =
            (idx > 0) ? trimmed.substring(0, idx).trim() : 'Speaker';
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
          ((_t?.title ?? 'transcript').trim().isEmpty ? 'transcript' : _t!.title!)
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
    } catch (_) {
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
      builder: (ctx) => Theme(
        data: Theme.of(ctx),
        child: AlertDialog(
          backgroundColor: Colors.black87,
          surfaceTintColor: Colors.transparent,
          title: const Text(
            'Edit transcript',
            style: TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: TextField(
              controller: ctrl,
              autofocus: true,
              minLines: 10,
              maxLines: 20,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Format: Speaker: text (one per line)',
                hintStyle: TextStyle(color: Colors.white54),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              style: OutlinedButton.styleFrom(backgroundColor: Colors.white),
              child: const Text('Save', style: TextStyle(color: Colors.black)),
            ),
          ],
        ),
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

    await _refreshTick();
    if (!mounted) return;
    await AppFlushbar.success(context, message: 'Transcript saved.');
  }

  // ============================================================
  // ✅ Turn long-press actions (unchanged)
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
            'You are viewing the edited transcript. Use “Edit transcript” to edit.',
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
        final isDark = GlassTokens.isDark(ctx);
        final fg = Colors.white.withValues(alpha: 0.92);

        return SafeArea(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Stack(
                children: [
                  LiquidGlass(
                    borderRadius: BorderRadius.circular(18),
                    padding: EdgeInsets.zero,
                    shadow: false,
                    blurX: isDark ? 22 : 18,
                    blurY: isDark ? 22 : 18,
                    tintOpacityDark: 0.040,
                    tintOpacityLight: 0.032,
                    borderOpacityDark: 0.14,
                    borderOpacityLight: 0.18,
                    child: const SizedBox.expand(),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 42,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        const SizedBox(height: 10),
                        ListTile(
                          leading: Icon(Icons.edit_outlined, color: fg),
                          title: Text(
                            'Edit segment',
                            style: TextStyle(
                              color: fg,
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
                        ListTile(
                          leading: Icon(Icons.copy_rounded, color: fg),
                          title: Text(
                            'Copy segment',
                            style: TextStyle(
                              color: fg,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          onTap: () async {
                            Navigator.pop(ctx);
                            await Clipboard.setData(
                              ClipboardData(
                                text: '${turn.speakerLabel}: ${turn.text}',
                              ),
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
                ],
              ),
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
      builder: (ctx) => Theme(
        data: Theme.of(ctx),
        child: AlertDialog(
          backgroundColor: Colors.black87,
          surfaceTintColor: Colors.transparent,
          title: const Text(
            'Edit segment',
            style: TextStyle(color: Colors.white),
          ),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: 'Edit what was said…',
              hintStyle: TextStyle(color: Colors.white54),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              style: OutlinedButton.styleFrom(backgroundColor: Colors.white),
              child: const Text('Save', style: TextStyle(color: Colors.black)),
            ),
          ],
        ),
      ),
    );

    if (newText == null) return;

    final obx = ObjectBox.I;
    final latest = obx.turns.get(turn.id);
    if (latest == null) return;

    latest.text = newText;
    obx.turns.put(latest);

    await _refreshTick();
    _updateTranscriptSearchCacheInDb();

    if (!mounted) return;
    await AppFlushbar.success(context, message: 'Segment updated.');
  }

  // ============================================================
  // Formatting helpers
  // ============================================================

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
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context, alpha: 0.92);

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

    // ✅ Processing is coordinator busy flag
    final isProcessing = _isProcessingNow;

    final origPath = _getOriginalPath();
    final origExists = _fileExists(origPath);

    final hasAnyAudio = origExists;
    final canPlayAudio = hasAnyAudio && !_isTranscribingNow;

    final displayTurns = _buildDisplayTurns();
    final showingEdited =
        (t.editedText != null && t.editedText!.trim().isNotEmpty);

    return Scaffold(
      body: GlassBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
            children: [
              // ================= HEADER =================
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconPillButton(
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
                            color: fg,
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
                  IconPillButton(
                    tooltip: 'Edit title',
                    icon: Icons.edit_note,
                    onTap: _isTranscribingNow ? null : _editTitle,
                  ),
                  const SizedBox(width: 8),
                  IconPillButton(
                    tooltip: 'Report transcript',
                    icon: Icons.flag,
                    onTap: () async => _reportTranscript(),
                  ),
                ],
              ),

              const SizedBox(height: 14),

              // ================= AUDIO + ACTIONS =================
              _GlassPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _CompactAudioBar(
                      isDark: isDark,
                      isTranscribingNow: _isTranscribingNow,
                      hasAnyAudio: hasAnyAudio,
                      canPlayAudio: canPlayAudio,
                      isPlaying: _isPlaying,
                      onToggle: _togglePlayPause,
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
                    const SizedBox(height: 12),
                    const GlassDivider(),
                    const SizedBox(height: 12),

                    Row(
                      children: [
                        Expanded(
                          child: GlassButton(
                            kind: GlassButtonKind.primary,
                            label: 'Summary',
                            icon: Icons.summarize_outlined,
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
                            innerChrome: false,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: GlassButton(
                            kind: GlassButtonKind.primary,
                            label: 'Ask AI',
                            icon: Icons.chat_bubble_outline,
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
                            innerChrome: false,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: GlassButton(
                            kind: GlassButtonKind.secondary,
                            label: 'Copy',
                            icon: Icons.copy_rounded,
                            onPressed:
                                _isTranscribingNow ? null : _copyWholeTranscript,
                            innerChrome: false,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: GlassButton(
                            kind: GlassButtonKind.secondary,
                            label: 'Share',
                            icon: Icons.ios_share_rounded,
                            onPressed:
                                _isTranscribingNow ? null : _shareWholeTranscript,
                            innerChrome: false,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // ================= STATUS (PROCESSING / ERROR) =================
              if (isProcessing)
                _GlassPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                GlassTokens.fg(context, alpha: 0.92),
                              ),
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.12),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Processing audio… Do not close the app.',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: fg,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      LinearProgressIndicator(
                        value: (_progressTotalSec > 0)
                            ? (_progressProcessedSec / _progressTotalSec).clamp(
                                0.0,
                                0.98,
                              )
                            : null,
                        minHeight: 4,
                        backgroundColor: Colors.white.withValues(alpha: 0.12),
                        color: GlassTokens.fg(context, alpha: 0.92),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _MetaPill(text: 'Stage • $_progressStage'),
                          // _MetaPill(
                          //   text:
                          //       'Time • ${_fmtClock(Duration(milliseconds: (_progressProcessedSec * 1000).round()))}'
                          //       ' / ${_fmtClock(Duration(milliseconds: ((_progressTotalSec > 0 ? _progressTotalSec : (t.durationSec)) * 1000).round()))}',
                          // ),
                          // _MetaPill(text: 'Segments • ${_turns.length}'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Keep the app open to finish faster.',
                        style: TextStyle(
                          color: GlassTokens.muted(context),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),

              if (_processingFailed)
                _GlassPanel(
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.redAccent),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _processingError ??
                              'Transcription failed. Please try again.',
                          style: TextStyle(
                            color: GlassTokens.muted(context, alpha: 0.85),
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
                        color: fg,
                      ),
                    ),
                    const Spacer(),
                    _MetaPill(text: '${labels.length}'),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: labels.map((name) {
                    final count = counts[name]!;
                    return _GlassPersonChip(
                      label: name,
                      count: count,
                      enabled: !_isTranscribingNow,
                      onEdit: () => _renameSpeaker(name),
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
                      color: fg,
                    ),
                  ),
                  if (!isProcessing) ...[
                    const SizedBox(width: 8),
                    Text(
                      'Long-press for options',
                      style: TextStyle(
                        color: GlassTokens.muted(context, alpha: 0.55),
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

              if (isProcessing && displayTurns.isEmpty)
                const _InlineHint(
                  text: 'No segments yet. We’ll list them here when ready.',
                ),
              if (_processingFailed && displayTurns.isEmpty)
                const _InlineHint(text: 'No segments were generated.'),

              if (!isProcessing && !_processingFailed)
                ...List.generate(displayTurns.length, (i) {
                  final u = displayTurns[i];

                  final subtitle = (u.startSec != null && u.endSec != null)
                      ? '${u.startSec!.toStringAsFixed(2)}–${u.endSec!.toStringAsFixed(2)}s'
                      : null;

                  final turnId = (!showingEdited && i < _turns.length)
                      ? _turns[i].id
                      : null;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: GestureDetector(
                      onLongPress:
                          turnId == null ? null : () => _showTurnActions(turnId),
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
      ),
    );
  }
}

// ===================== GLASS PANELS =====================

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      variant: GlassCardVariant.panel,
      padding: const EdgeInsets.all(14),
      child: child,
    );
  }
}

/// ✅ Updated to use Glass primitives (crisp pill, no extra blur).
class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.text, this.accent});
  final String text;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final muted = GlassTokens.muted(context, alpha: 0.70);

    final c = accent;
    final tl = c != null ? 0.055 : 0.050;
    final td = c != null ? 0.075 : 0.070;
    final bl = c != null ? 0.24 : 0.20;
    final bd = c != null ? 0.20 : 0.16;

    final radius = BorderRadius.circular(999);

    return ClipRRect(
      borderRadius: radius,
      child: LiquidGlass(
        borderRadius: radius,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shadow: false,
        blurX: 0,
        blurY: 0,
        grain: false,
        tintOpacityLight: tl,
        tintOpacityDark: td,
        borderOpacityLight: bl,
        borderOpacityDark: bd,
        child: SizedBox(
          height: 32, // ✅ force perfect capsule
          child: Center(
            child: Text(
              text,
              textAlign: TextAlign.center,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c != null ? c.withValues(alpha: 0.95) : muted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
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
        style: TextStyle(
          color: GlassTokens.muted(context),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _TurnCard extends StatelessWidget {
  const _TurnCard({required this.speaker, required this.text, this.subtitle});

  final String speaker;
  final String text;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      variant: GlassCardVariant.panel,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: TextStyle(
                    color: GlassTokens.muted(context, alpha: 0.72),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              if (subtitle != null) ...[
                const SizedBox(width: 8),
                Text(
                  '•',
                  style: TextStyle(
                    color: GlassTokens.muted(context, alpha: 0.30),
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
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.1,
                    color: GlassTokens.fg(context),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              LiquidGlass(
                borderRadius: BorderRadius.circular(10),
                padding: const EdgeInsets.all(6),
                shadow: false,
                blurX: 0,
                blurY: 0,
                grain: false,
                tintOpacityLight: 0.050,
                tintOpacityDark: 0.070,
                borderOpacityLight: 0.20,
                borderOpacityDark: 0.16,
                child: Icon(
                  Icons.record_voice_over_outlined,
                  size: 16,
                  color: GlassTokens.muted(context, alpha: 0.85),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            text,
            style: TextStyle(
              height: 1.35,
              fontSize: 14.5,
              color: GlassTokens.fg(context),
              fontWeight: FontWeight.w500,
            ),
          ),
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
    required this.onToggle,
  });

  final bool isDark;
  final bool isTranscribingNow;
  final bool hasAnyAudio;
  final bool canPlayAudio;
  final bool isPlaying;
  final Future<void> Function() onToggle;

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context, alpha: 0.92);

    final title = isTranscribingNow
        ? 'Processing…'
        : (hasAnyAudio ? 'Audio' : 'No audio');
    final subtitle = isTranscribingNow
        ? 'Playback disabled'
        : (hasAnyAudio ? 'Original' : 'Missing file');

    return Row(
      children: [
        // ✅ Swap manual Ink styling -> LiquidGlass button surface (same look)
        GestureDetector(
          onTap: canPlayAudio ? () => onToggle() : null,
          child: Opacity(
            opacity: canPlayAudio ? 1.0 : 0.55,
            child: LiquidGlass(
              borderRadius: BorderRadius.circular(14),
              padding: const EdgeInsets.all(10),
              shadow: false,
              blurX: 0,
              blurY: 0,
              grain: false,
              tintOpacityLight: 0.050,
              tintOpacityDark: 0.070,
              borderOpacityLight: 0.20,
              borderOpacityDark: 0.16,
              child: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: 22,
                color: fg,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(fontWeight: FontWeight.w900, color: fg),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  color: GlassTokens.muted(context, alpha: 0.70),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
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
            style: TextStyle(
              color: GlassTokens.muted(context, alpha: 0.70),
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: GlassTokens.fg(context, alpha: 0.92),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.12),
              thumbColor: GlassTokens.fg(context, alpha: 0.92),
              overlayColor: Colors.white.withValues(alpha: 0.12),
              trackHeight: 3,
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
            style: TextStyle(
              color: GlassTokens.muted(context, alpha: 0.70),
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }
}

class _GlassPersonChip extends StatelessWidget {
  const _GlassPersonChip({
    required this.label,
    required this.count,
    required this.onEdit,
    required this.enabled,
  });

  final String label;
  final int count;
  final VoidCallback onEdit;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context, alpha: 0.92);

    Widget chip = LiquidGlass(
      borderRadius: BorderRadius.circular(999),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      shadow: false,
      blurX: isDark ? 14 : 12,
      blurY: isDark ? 14 : 12,
      tintOpacityDark: 0.045,
      tintOpacityLight: 0.036,
      borderOpacityDark: 0.14,
      borderOpacityLight: 0.18,
      onTap: enabled ? onEdit : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person, size: 16, color: fg.withValues(alpha: 0.85)),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: fg, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 8),
          LiquidGlass(
            borderRadius: BorderRadius.circular(999),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            shadow: false,
            blurX: 0,
            blurY: 0,
            grain: false,
            tintOpacityLight: 0.050,
            tintOpacityDark: 0.070,
            borderOpacityLight: 0.20,
            borderOpacityDark: 0.16,
            child: Text(
              '$count',
              style: TextStyle(
                color: GlassTokens.muted(context, alpha: 0.80),
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.edit,
            size: 16,
            color: GlassTokens.muted(context, alpha: 0.70),
          ),
        ],
      ),
    );

    if (!enabled) chip = Opacity(opacity: 0.55, child: chip);
    return chip;
  }
}