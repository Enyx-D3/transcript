// lib/transcript/transcript_detail_page.dart
import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';

import '../common/app_flushbar.dart';
import '../export/document_export_service.dart';
import '../export/document_export_sheet.dart';
import '../objectbox/entities.dart';
import '../objectbox/objectbox_store.dart';
import '../objectbox.g.dart';
import '../report/report_dialog.dart';
import '../report/report_service.dart';
import '../send_transcript/send_transcript_healper.dart';

import '../llm_service.dart' show LLMService, qwenMaxContext;
import '../qwen_model_service.dart';

import 'background_transcriber.dart';
import 'transcript_chat_page.dart';
import 'transcript_editor_page.dart';
import 'transcript_summary_page.dart';

import '../ui/glass/glass_tokens.dart';

class _DisplayTurn {
  final String speaker;
  final String text;
  final double? startSec;
  final double? endSec;
  // final String? badgeText;
  final bool isPlaceholder;

  _DisplayTurn(
    this.speaker,
    this.text, {
    this.startSec,
    this.endSec,
    // this.badgeText,
    this.isPlaceholder = false,
  });
}

class _PartialTurnItem {
  final String key;
  final _DisplayTurn turn;

  const _PartialTurnItem({required this.key, required this.turn});
}

class _PartialTurnsSnapshot {
  final List<_PartialTurnItem> turns;
  final int? total;

  const _PartialTurnsSnapshot({this.turns = const [], this.total});
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
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  final List<GlobalKey> _turnKeys = [];
  bool _searchOpen = false;
  String _searchQuery = '';
  List<int> _searchMatches = const [];
  int _currentSearchMatch = -1;

  final AudioPlayer _player = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
  bool _isPlaying = false;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  double _playbackRate = 1.0;
  String? _loadedPath;

  bool _busyFlag = false;

  static const _kBusyTranscribing = 'busy_transcribing';
  static const _kActiveTranscriptId = 'bg_active_transcript_id'; // ✅ NEW
  static const _kProgressProcessedSec = 'progress_processed_sec';
  static const _kProgressTotalSec = 'progress_total_sec';
  static const _kProgressStage = 'progress_stage';

  double _progressProcessedSec = 0.0;
  double _progressTotalSec = 0.0;
  String _progressStage = 'Processing';

  bool _processingFailed = false;
  String? _processingError;
  Timer? _processingWatchdog;
  List<_PartialTurnItem> _partialTurns = const [];
  int? _partialExpectedTotal;
  final ValueNotifier<_PartialTurnsSnapshot> _partialTurnsNotifier =
      ValueNotifier<_PartialTurnsSnapshot>(const _PartialTurnsSnapshot());
  Timer? _partialFlushTimer;
  List<_PartialTurnItem>? _pendingPartialTurns;
  int? _pendingPartialExpectedTotal;

  final ReportService _reportService = const ReportService(
    baseUrl: 'https://enyx.app',
  );
  final mailer = TranscriptMailService(baseUrl: 'https://enyx.app');

  _AudioVariant _audioVariant = _AudioVariant.original;

  // ============================================================
  // ✅ AUTO SUMMARY (ONLY ONCE)
  // ============================================================

  final QwenModelService _qwenService = QwenModelService();

  String _summaryBusyKey(int id) => 'summary_busy_$id';
  String _autoSummaryOnceKey(int id) => 'auto_summary_once_$id';

  static const _kPrefAutoSummaryEnabled = 'pref_auto_summary_enabled'; // bool

  Future<bool> _isAutoSummaryEnabled() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getBool(_kPrefAutoSummaryEnabled) ?? true;
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

  Future<bool> _didAutoSummaryRunOnce() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getBool(_autoSummaryOnceKey(widget.transcriptId)) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _markAutoSummaryRanOnce() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_autoSummaryOnceKey(widget.transcriptId), true);
    } catch (_) {}
  }

  bool _summaryExistsInDb() {
    final obx = ObjectBox.I;
    final qb = obx.summaries.query(
      TranscriptSummaryEntity_.transcriptId.equals(widget.transcriptId),
    );
    final q = qb.build();
    final existing = q.findFirst();
    q.close();
    return existing != null && existing.summary.trim().isNotEmpty;
  }

  Future<void> _maybeStartAutoSummaryOnce() async {
    if (_isProcessingNow || _processingFailed) return;
    if (_summaryExistsInDb()) return;
    if (!await _isAutoSummaryEnabled()) return;
    if (await _isSummaryBusy()) return;
    if (await _didAutoSummaryRunOnce()) return;
    if (_turns.isEmpty) return;

    final exists = await _qwenService.isModelDownloaded();
    if (!exists) return;
    final modelPath = await _qwenService.modelFilePath();
    if (modelPath.trim().isEmpty) return;

    await _markAutoSummaryRanOnce();
    await _setSummaryBusy(true);

    unawaited(_runAutoSummaryBalanced(modelPath));
  }

  Future<void> _runAutoSummaryBalanced(String modelPath) async {
    try {
      final obx = ObjectBox.I;

      final buf = StringBuffer();
      for (final u in _turns) {
        final txt = u.text.trim();
        if (txt.isEmpty) continue;
        buf.writeln('${u.speakerLabel}: $txt');
      }
      final transcriptText = buf.toString().trim();
      if (transcriptText.isEmpty) {
        await _setSummaryBusy(false);
        return;
      }

      const maxTokens = 650;
      String latestFullText = '';

      final stream = LLMService.summarizeTranscript(
        transcript: transcriptText,
        modelPath: modelPath,
        maxTokens: maxTokens,
        temperature: 0.3,
        contextSize: qwenMaxContext,
      );

      stream.listen(
        (evt) {
          final full = (evt['full_text'] ?? '') as String;
          if (full.isNotEmpty) latestFullText = full;
        },
        onError: (_) async {
          await _setSummaryBusy(false);
        },
        onDone: () async {
          try {
            final qb2 = obx.summaries.query(
              TranscriptSummaryEntity_.transcriptId.equals(widget.transcriptId),
            );
            final q2 = qb2.build();
            final existing = q2.findFirst();
            q2.close();

            final entity = TranscriptSummaryEntity(
              id: existing?.id ?? 0,
              transcriptId: widget.transcriptId,
              summary: latestFullText.trim(),
              updatedAt: DateTime.now(),
            );
            obx.summaries.put(entity);
          } catch (_) {}

          await _setSummaryBusy(false);
        },
      );
    } catch (_) {
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
    _partialFlushTimer?.cancel();
    _partialTurnsNotifier.dispose();
    _searchCtrl.dispose();
    _scrollController.dispose();
    _player.stop();
    _player.dispose();
    super.dispose();
  }

  // ============================================================
  // ✅ Busy flag (FIXED: per-transcript, not global)
  // ============================================================

  Future<bool> _readBusyFlag() async {
    try {
      final busyRaw = await FlutterForegroundTask.getData(
        key: _kBusyTranscribing,
      );
      final activeRaw = await FlutterForegroundTask.getData(
        key: _kActiveTranscriptId,
      );

      final bool busy = (busyRaw == true);

      int activeId = 0;
      if (activeRaw is int) {
        activeId = activeRaw;
      } else {
        activeId = int.tryParse('$activeRaw') ?? 0;
      }

      final jobLooksActive =
          _job != null &&
          _job!.transcriptId == widget.transcriptId &&
          (_job!.status == 'PENDING' || _job!.status == 'RUNNING');

      // Prefer the explicit active-transcript id. If the foreground service
      // hasn't published it yet, fall back to the local job state so the
      // detail page can still show processing UI immediately after navigation.
      return busy &&
          (activeId == widget.transcriptId ||
              (activeId == 0 && jobLooksActive));
    } catch (_) {
      return false;
    }
  }

  bool get _isProcessingNow => _busyFlag && !_processingFailed;
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
      _loadedPath = null;
    });
  }

  // ============================================================
  // ✅ Progress (FIXED: only update on active transcript page)
  // ============================================================

  Future<void> _pullProgressFromFgStorage() async {
    try {
      final activeRaw = await FlutterForegroundTask.getData(
        key: _kActiveTranscriptId,
      );
      final activeId = (activeRaw is int)
          ? activeRaw
          : int.tryParse('$activeRaw') ?? 0;

      // ✅ Ignore progress for other transcripts
      if (activeId != widget.transcriptId) return;

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
  // ✅ Audio helpers
  // ============================================================

  String? _getOriginalPath() =>
      _t?.audioPath?.trim().isEmpty ?? true ? null : _t!.audioPath!.trim();

  String? _getEnhancedPath() => _t?.processedAudioPath?.trim().isEmpty ?? true
      ? null
      : _t!.processedAudioPath!.trim();

  bool _fileExists(String? path) {
    if (path == null || path.trim().isEmpty) return false;
    return File(path).existsSync();
  }

  _AudioVariant _effectiveVariant({
    required bool origExists,
    required bool enhExists,
  }) {
    if (_audioVariant == _AudioVariant.enhanced && !enhExists && origExists) {
      return _AudioVariant.original;
    }
    if (_audioVariant == _AudioVariant.original && !origExists && enhExists) {
      return _AudioVariant.enhanced;
    }
    return _audioVariant;
  }

  String? _getSelectedPath(_AudioVariant v) {
    final orig = _getOriginalPath();
    final enh = _getEnhancedPath();
    if (v == _AudioVariant.enhanced) return enh ?? orig;
    return orig ?? enh;
  }

  void _debugPrintAudioPaths() {
    final orig = _getOriginalPath();
    final enh = _getEnhancedPath();
    debugPrint('[AUDIO][DB] original: $orig');
    debugPrint('[AUDIO][DB] enhanced: $enh');
    debugPrint('[AUDIO][DB] original exists: ${_fileExists(orig)}');
    debugPrint('[AUDIO][DB] enhanced exists: ${_fileExists(enh)}');
    debugPrint('[AUDIO][DB] selected variant: $_audioVariant');
    debugPrint('[AUDIO][DB] selected path: ${_getSelectedPath(_audioVariant)}');
  }

  // ============================================================
  // Cache helpers
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

            final mergedMeta = <String, dynamic>{...?meta, ...localMeta};

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

  Future<void> _togglePlaybackRate() async {
    final next = switch (_playbackRate) {
      1.0 => 1.25,
      1.25 => 1.5,
      1.5 => 2.0,
      2.0 => 0.75,
      _ => 1.0,
    };
    setState(() => _playbackRate = next);
    try {
      await _player.setPlaybackRate(next);
    } catch (_) {}
  }

  Future<bool> _ensureSourceLoaded(_AudioVariant v) async {
    if (_isTranscribingNow) return false;

    final path = _getSelectedPath(v);
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

  Future<void> _togglePlayPause(_AudioVariant effectiveV) async {
    if (_isTranscribingNow) {
      if (!mounted) return;
      await AppFlushbar.info(
        context,
        message: 'Audio playback is disabled while transcription is running.',
      );
      return;
    }

    if (!await _ensureSourceLoaded(effectiveV)) {
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

  int _currentPlaybackTurnIndex(List<_DisplayTurn> displayTurns) {
    if (!_isPlaying) return -1;

    final posMs = _pos.inMilliseconds;
    for (var i = 0; i < displayTurns.length; i++) {
      final turn = displayTurns[i];
      final startSec = turn.startSec;
      final endSec = turn.endSec;
      if (startSec == null || endSec == null) continue;

      final startMs = (startSec * 1000).round();
      final endMs = (endSec * 1000).round();
      if (endMs <= startMs) continue;

      final isLastSegment = i == displayTurns.length - 1;
      final inSegment =
          posMs >= startMs &&
          (posMs < endMs || (isLastSegment && posMs <= endMs));
      if (inSegment) return i;
    }

    return -1;
  }

  Future<void> _playFromSegment(
    _DisplayTurn turn,
    _AudioVariant effectiveV,
  ) async {
    if (_isTranscribingNow) {
      if (!mounted) return;
      await AppFlushbar.info(
        context,
        message: 'Audio playback is disabled while transcription is running.',
      );
      return;
    }

    final startSec = turn.startSec;
    if (startSec == null) return;

    if (!await _ensureSourceLoaded(effectiveV)) {
      if (!mounted) return;
      await AppFlushbar.error(
        context,
        message: 'Audio file not available for playback.',
      );
      return;
    }

    final target = Duration(milliseconds: (startSec * 1000).round());
    await _player.seek(target);
    if (mounted) setState(() => _pos = target);
    await _player.resume();
  }

  Future<void> _seekTo(double v) async {
    if (_isTranscribingNow) return;
    await _player.seek(Duration(milliseconds: v.round()));
  }

  Future<void> _switchVariant(_AudioVariant v) async {
    if (_isTranscribingNow) return;
    if (v == _audioVariant) return;

    try {
      await _player.stop();
    } catch (_) {}

    setState(() {
      _audioVariant = v;
      _isPlaying = false;
      _pos = Duration.zero;
      _dur = Duration.zero;
      _loadedPath = null;
    });

    await _ensureSourceLoaded(v);
    _debugPrintAudioPaths();
  }

  // ============================================================
  // Job helpers
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
    final displayTurns = _buildDisplayTurnsFor(t, rows);
    _recomputeSearchMatches(displayTurns);

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
  // ✅ Core refresh loop
  // ============================================================

  Future<void> _refreshTick() async {
    _loadOnce();
    await _pullProgressFromFgStorage();

    final newBusy = await _readBusyFlag();
    final busyChanged = newBusy != _busyFlag;
    _busyFlag = newBusy;

    if (_busyFlag && !_processingFailed) {
      _persistJobRunningIfNeeded();
    }

    if (!_busyFlag && !_processingFailed) {
      if (_job != null && _job!.status != 'DONE') _persistJobDone();
      _updateTranscriptSearchCacheInDb();
    }

    await _maybeStartAutoSummaryOnce();

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

    _syncPoller();
    _syncWatchdog();

    if (busyChanged && mounted) setState(() {});
  }

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

  Future<bool> _isFgServiceRunningSafe() async {
    try {
      return await FlutterForegroundTask.isRunningService;
    } catch (_) {
      return false;
    }
  }

  void _syncWatchdog() {
    final shouldArm =
        _busyFlag &&
        _turns.isEmpty &&
        _partialTurns.isEmpty &&
        !_processingFailed;

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
      if (_turns.isNotEmpty || _partialTurns.isNotEmpty) return;

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
        await FlutterForegroundTask.saveData(
          key: _kActiveTranscriptId,
          value: 0,
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
  // ✅ BG events
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
        await FlutterForegroundTask.saveData(
          key: _kActiveTranscriptId,
          value: 0,
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

    if (type == 'transcribe_partial') {
      final existingId = data['existingId'] as int?;
      if (existingId != widget.transcriptId) return;

      final turnRaw = data['turn'];
      if (turnRaw is! Map) return;
      final turn = turnRaw.cast<String, dynamic>();
      final text = (turn['text'] ?? '').toString().trim();
      if (text.isEmpty) return;

      final speaker = (turn['speaker'] ?? 'S1').toString();
      final startSec = (turn['startSec'] is num)
          ? (turn['startSec'] as num).toDouble()
          : double.tryParse('${turn['startSec']}');
      final endSec = (turn['endSec'] is num)
          ? (turn['endSec'] as num).toDouble()
          : double.tryParse('${turn['endSec']}');
      final index = (data['index'] is int)
          ? data['index'] as int
          : int.tryParse('${data['index']}') ?? 0;
      final total = (data['total'] is int)
          ? data['total'] as int
          : int.tryParse('${data['total']}');

      _processingWatchdog?.cancel();
      _processingWatchdog = null;

      _upsertPartialTurn(
        key: 'chunk_$index',
        total: total,
        turn: _DisplayTurn(
          speaker,
          text,
          startSec: startSec,
          endSec: endSec,
          // badgeText: total != null && total > 0
          //     ? 'Chunk ${index + 1}/$total'
          //     : 'Chunk ${index + 1}',
        ),
      );

      if (!mounted) return;
      if (!_busyFlag || _processingFailed || _processingError != null) {
        setState(() {
          _busyFlag = true;
          _processingFailed = false;
          _processingError = null;
        });
      }
      return;
    }

    if (type == 'transcribe_segments_ready') {
      final existingId = data['existingId'] as int?;
      if (existingId != widget.transcriptId) return;

      final rawTurns = data['turns'];
      if (rawTurns is! List) return;
      final total = (data['total'] is int)
          ? data['total'] as int
          : int.tryParse('${data['total']}') ?? rawTurns.length;

      for (var i = 0; i < rawTurns.length; i++) {
        final raw = rawTurns[i];
        if (raw is! Map) continue;
        final turn = raw.cast<String, dynamic>();
        final speaker = (turn['speaker'] ?? 'S1').toString();
        final startSec = (turn['startSec'] is num)
            ? (turn['startSec'] as num).toDouble()
            : double.tryParse('${turn['startSec']}');
        final endSec = (turn['endSec'] is num)
            ? (turn['endSec'] as num).toDouble()
            : double.tryParse('${turn['endSec']}');

        _upsertPartialTurn(
          key: 'chunk_$i',
          total: total,
          turn: _DisplayTurn(
            speaker,
            '',
            startSec: startSec,
            endSec: endSec,
            isPlaceholder: true,
          ),
        );
      }

      if (!mounted) return;
      if (!_busyFlag || _processingFailed || _processingError != null) {
        setState(() {
          _busyFlag = true;
          _processingFailed = false;
          _processingError = null;
        });
      }
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
      await FlutterForegroundTask.saveData(key: _kActiveTranscriptId, value: 0);
    } catch (_) {}

    _processingWatchdog?.cancel();
    _processingWatchdog = null;

    _persistJobDone();

    // reload turns and update caches
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await _refreshTick();

    if (mounted) {
      setState(() {
        _busyFlag = false;
        _processingFailed = false;
        _processingError = null;
        _partialTurns = const [];
        _partialExpectedTotal = null;
        _partialTurnsNotifier.value = const _PartialTurnsSnapshot();
      });
    }

    _poll?.cancel();
    _poll = null;
  }

  // ============================================================
  // Edit title / rename speaker / copy / share / edit transcript
  // (UNCHANGED from your file below this point)
  // ============================================================

  // ---------- Edit title ----------
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

  // ---------- Rename speaker ----------
  Future<void> _renameSpeaker(String oldLabel) async {
    final ctrl = TextEditingController(text: oldLabel);
    final newLabel = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final isDark = GlassTokens.isDark(ctx);
        final fg = GlassTokens.fg(ctx);
        final muted = GlassTokens.muted(ctx);
        const accent = Color(0xFF007AFF);

        return AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1E1E26) : Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Text(
            'Rename speaker',
            style: TextStyle(color: fg, fontWeight: FontWeight.w700),
          ),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: TextStyle(color: fg),
            cursorColor: accent,
            decoration: InputDecoration(
              labelText: 'Name',
              labelStyle: TextStyle(color: muted),
              hintText: 'e.g. Alex',
              hintStyle: TextStyle(color: muted),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: muted, width: 1.5),
              ),
              focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: accent, width: 2),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                'Cancel',
                style: TextStyle(color: muted),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text(
                'Save',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ],
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

  // ---------- Build transcript text ----------
  String _buildTranscriptText({bool preferEdited = true}) {
    final t = _t;
    if (preferEdited && (t?.editedText?.trim().isNotEmpty ?? false)) {
      return t!.editedText!.trim();
    }

    final b = StringBuffer();
    if (_turns.isNotEmpty) {
      for (final u in _turns) {
        b.writeln('${u.speakerLabel}: ${u.text}');
      }
    } else {
      for (final u in _partialTurns) {
        b.writeln('${u.turn.speaker}: ${u.turn.text}');
      }
    }
    return b.toString().trim();
  }

  List<_DisplayTurn> _buildDisplayTurns() {
    return _buildDisplayTurnsFor(_t, _turns);
  }

  List<_DisplayTurn> _buildDisplayTurnsFor(
    TranscriptEntity? t,
    List<TranscriptTurnEntity> turns,
  ) {
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

        final ts = (i < turns.length) ? turns[i] : null;

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

    return turns
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

  String? _subtitleForTurn(_DisplayTurn u) {
    if (u.startSec == null || u.endSec == null) return null;
    return '${u.startSec!.toStringAsFixed(2)}–${u.endSec!.toStringAsFixed(2)}s';
  }

  List<_DisplayTurn> _displayTurnsForRender(bool isProcessing) {
    if (_turns.isNotEmpty) return _buildDisplayTurns();
    final items = _partialTurns.map((e) => e.turn).toList();
    if (isProcessing && !_processingFailed) {
      items.add(
        _DisplayTurn(
          'Processing next segment',
          '',
          // badgeText: 'Live',
          isPlaceholder: true,
        ),
      );
    }
    return items;
  }

  List<_DisplayTurn> _displayTurnsFromPartialSnapshot(
    _PartialTurnsSnapshot snapshot,
    bool isProcessing,
  ) {
    final items = snapshot.turns.map((e) => e.turn).toList();
    if (isProcessing && !_processingFailed) {
      items.add(
        _DisplayTurn(
          'Processing next segment',
          '',
          // badgeText: 'Live',
          isPlaceholder: true,
        ),
      );
    }
    return items;
  }

  Widget _buildPeopleSection({required ThemeData theme, required Color fg}) {
    return ValueListenableBuilder<_PartialTurnsSnapshot>(
      valueListenable: _partialTurnsNotifier,
      builder: (context, snapshot, _) {
        final isDark = GlassTokens.isDark(context);
        final muted = GlassTokens.muted(context);
        final counts = <String, int>{};
        if (_turns.isNotEmpty) {
          for (final u in _turns) {
            final speaker = u.speakerLabel.trim();
            if (speaker.isEmpty) continue;
            counts[speaker] = (counts[speaker] ?? 0) + 1;
          }
        } else {
          for (final u in snapshot.turns) {
            final speaker = u.turn.speaker.trim();
            if (speaker.isEmpty || speaker == 'Processing next segment') {
              continue;
            }
            counts[speaker] = (counts[speaker] ?? 0) + 1;
          }
        }

        final labels = counts.keys.toList()..sort();
        if (labels.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.people_alt_rounded,
                  size: 18,
                  color: isDark ? const Color(0xFF007AFF) : const Color(0xFF007AFF),
                ),
                const SizedBox(width: 8),
                Text(
                  'Speakers',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: fg,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${labels.length}',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: muted,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  'Tap to rename',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: muted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: labels.map((name) {
                final count = counts[name]!;
                return _ModernPersonChip(
                  label: name,
                  count: count,
                  enabled: !_isTranscribingNow,
                  onEdit: () => _renameSpeaker(name),
                );
              }).toList(),
            ),
            const SizedBox(height: 18),
          ],
        );
      },
    );
  }

  void _upsertPartialTurn({
    required String key,
    required _DisplayTurn turn,
    int? total,
  }) {
    final next = [...(_pendingPartialTurns ?? _partialTurns)];
    final i = next.indexWhere((e) => e.key == key);
    final item = _PartialTurnItem(key: key, turn: turn);
    if (i >= 0) {
      next[i] = item;
    } else {
      next.add(item);
    }
    next.sort((a, b) {
      final sa = a.turn.startSec ?? double.infinity;
      final sb = b.turn.startSec ?? double.infinity;
      return sa.compareTo(sb);
    });

    _pendingPartialTurns = next;
    if (total != null && total > 0) {
      _pendingPartialExpectedTotal = total;
    }

    _partialFlushTimer ??= Timer(const Duration(milliseconds: 350), () {
      _partialFlushTimer = null;
      final pending = _pendingPartialTurns;
      if (pending == null || !mounted) return;
      final pendingTotal = _pendingPartialExpectedTotal;
      _pendingPartialTurns = null;
      _pendingPartialExpectedTotal = null;
      _partialTurns = pending;
      if (pendingTotal != null) {
        _partialExpectedTotal = pendingTotal;
      }
      _partialTurnsNotifier.value = _PartialTurnsSnapshot(
        turns: pending,
        total: _partialExpectedTotal,
      );
    });
  }

  void _syncTurnKeys(int length) {
    if (_turnKeys.length == length) return;
    if (_turnKeys.length < length) {
      final add = length - _turnKeys.length;
      for (var i = 0; i < add; i++) {
        _turnKeys.add(GlobalKey());
      }
    } else {
      _turnKeys.removeRange(length, _turnKeys.length);
    }
  }

  void _recomputeSearchMatches(
    List<_DisplayTurn> displayTurns, {
    bool notify = false,
  }) {
    final query = _searchQuery.trim().toLowerCase();
    _syncTurnKeys(displayTurns.length);

    if (query.isEmpty) {
      final changed = _searchMatches.isNotEmpty || _currentSearchMatch != -1;
      _searchMatches = const [];
      _currentSearchMatch = -1;
      if (notify && changed && mounted) setState(() {});
      return;
    }

    final matches = <int>[];
    for (var i = 0; i < displayTurns.length; i++) {
      final turn = displayTurns[i];
      final haystack = [
        turn.speaker,
        turn.text,
        _subtitleForTurn(turn) ?? '',
      ].join('\n').toLowerCase();
      if (haystack.contains(query)) {
        matches.add(i);
      }
    }

    final oldTurnIndex =
        (_currentSearchMatch >= 0 &&
            _currentSearchMatch < _searchMatches.length)
        ? _searchMatches[_currentSearchMatch]
        : null;

    _searchMatches = matches;

    if (matches.isEmpty) {
      _currentSearchMatch = -1;
    } else if (oldTurnIndex != null && matches.contains(oldTurnIndex)) {
      _currentSearchMatch = matches.indexOf(oldTurnIndex);
    } else {
      _currentSearchMatch = 0;
    }

    if (notify && mounted) setState(() {});
  }

  void _handleSearchChanged(String value) {
    _searchQuery = value.trim();
    final displayTurns = _displayTurnsForRender(_isProcessingNow);
    _recomputeSearchMatches(displayTurns, notify: true);
    if (_searchMatches.isNotEmpty) {
      _scrollToMatchedTurn(_searchMatches[_currentSearchMatch]);
    }
  }

  void _clearSearch() {
    _searchCtrl.clear();
    _searchQuery = '';
    _recomputeSearchMatches(_buildDisplayTurns(), notify: true);
  }

  void _openSearch() {
    if (_searchOpen) return;
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).requestFocus(FocusNode());
    });
  }

  void _closeSearch() {
    _clearSearch();
    if (!mounted) return;
    setState(() => _searchOpen = false);
  }

  void _goToNextSearchMatch() {
    if (_searchMatches.isEmpty) return;
    setState(() {
      _currentSearchMatch = (_currentSearchMatch + 1) % _searchMatches.length;
    });
    _scrollToMatchedTurn(_searchMatches[_currentSearchMatch]);
  }

  void _goToPreviousSearchMatch() {
    if (_searchMatches.isEmpty) return;
    setState(() {
      _currentSearchMatch =
          (_currentSearchMatch - 1 + _searchMatches.length) %
          _searchMatches.length;
    });
    _scrollToMatchedTurn(_searchMatches[_currentSearchMatch]);
  }

  void _scrollToMatchedTurn(int turnIndex) {
    if (turnIndex < 0 || turnIndex >= _turnKeys.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _turnKeys[turnIndex].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          alignment: 0.15,
        );
      }
    });
  }

  TextSpan _buildHighlightedSpan(
    String source, {
    required TextStyle normalStyle,
    required TextStyle highlightStyle,
  }) {
    final query = _searchQuery.trim();
    if (query.isEmpty) {
      return TextSpan(text: source, style: normalStyle);
    }

    final lowerSource = source.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;

    while (true) {
      final index = lowerSource.indexOf(lowerQuery, start);
      if (index < 0) break;
      if (index > start) {
        spans.add(
          TextSpan(text: source.substring(start, index), style: normalStyle),
        );
      }
      spans.add(
        TextSpan(
          text: source.substring(index, index + query.length),
          style: highlightStyle,
        ),
      );
      start = index + query.length;
    }

    if (start < source.length) {
      spans.add(TextSpan(text: source.substring(start), style: normalStyle));
    }

    if (spans.isEmpty) {
      return TextSpan(text: source, style: normalStyle);
    }
    return TextSpan(children: spans, style: normalStyle);
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

  String _exportTitle() {
    final raw = (_t?.title ?? 'transcript').trim();
    return raw.isEmpty ? 'transcript' : raw;
  }

  Future<void> _exportWholeTranscript(DocumentExportFormat format) async {
    final text = _buildTranscriptText(preferEdited: true).trim();
    if (text.isEmpty) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Nothing to export yet.');
      return;
    }

    try {
      await DocumentExportService.shareDocument(
        title: _exportTitle(),
        content: text,
        documentLabel: 'Full transcript',
        format: format,
      );
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: e.toString());
    }
  }

  Future<void> _openTranscriptExportSheet() async {
    final text = _buildTranscriptText(preferEdited: true).trim();
    if (text.isEmpty) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Nothing to export yet.');
      return;
    }

    await showDocumentExportSheet(
      context: context,
      title: 'Export transcript',
      onExport: _exportWholeTranscript,
    );
  }

  Future<void> _shareWholeTranscript() async {
    final text = _buildTranscriptText(preferEdited: true).trim();
    if (text.isEmpty) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Nothing to share yet.');
      return;
    }

    try {
      final title = _exportTitle();
      await SharePlus.instance.share(
        ShareParams(
          subject: title,
          text: '$title\n\n$text',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: e.toString());
    }
  }

  Future<void> _editWholeTranscript() async {
    final t = _t;
    if (t == null) return;

    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TranscriptEditorPage(
          transcriptId: widget.transcriptId,
          title: (t.title?.trim().isNotEmpty ?? false)
              ? t.title!.trim()
              : 'Transcript',
          initialText: _buildTranscriptText(preferEdited: true),
          fallbackFullTextCache: _buildFullTextCacheFromTurns(),
        ),
      ),
    );

    if (changed != true) return;
    await _refreshTick();
    if (!mounted) return;
    await AppFlushbar.success(context, message: 'Transcript updated.');
  }

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
    final isDark = GlassTokens.isDark(context);
    await showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF191922) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        final fg = GlassTokens.fg(ctx);
        final muted = GlassTokens.muted(ctx);

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 38,
                  height: 4.5,
                  decoration: BoxDecoration(
                    color: muted.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 14),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF007AFF).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.edit_note_rounded,
                      color: Color(0xFF007AFF),
                      size: 20,
                    ),
                  ),
                  title: Text(
                    'Edit segment',
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  subtitle: Text(
                    'Fix wording for this segment only',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _editSingleTurn(turn);
                  },
                ),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.copy_rounded,
                      color: fg,
                      size: 19,
                    ),
                  ),
                  title: Text(
                    'Copy segment',
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  subtitle: Text(
                    'Copy speaker and segment text',
                    style: TextStyle(color: muted, fontSize: 12),
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
        );
      },
    );
  }

  Future<void> _editSingleTurn(TranscriptTurnEntity turn) async {
    final ctrl = TextEditingController(text: turn.text);

    final newText = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final isDark = GlassTokens.isDark(ctx);
        final fg = GlassTokens.fg(ctx);
        final muted = GlassTokens.muted(ctx);
        const accent = Color(0xFF007AFF);

        return AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1E1E26) : Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Text(
            'Edit segment',
            style: TextStyle(color: fg, fontWeight: FontWeight.bold),
          ),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
            style: TextStyle(color: fg),
            decoration: InputDecoration(
              hintText: 'Edit what was said…',
              hintStyle: TextStyle(color: muted),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: isDark ? const Color(0xFF33333E) : const Color(0xFFE2E2EA)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: accent, width: 1.5),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                'Cancel',
                style: TextStyle(color: muted),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('Save', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
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

  Widget _buildTurnsSection({
    required ThemeData theme,
    required Color fg,
    required bool isProcessing,
    required bool canPlayAudio,
    required _AudioVariant effectiveV,
    required bool showingEdited,
    required int searchCount,
  }) {
    return ValueListenableBuilder<_PartialTurnsSnapshot>(
      valueListenable: _partialTurnsNotifier,
      builder: (context, partialSnapshot, _) {
        final isDark = GlassTokens.isDark(context);
        final muted = GlassTokens.muted(context);
        final displayTurns = _turns.isEmpty
            ? _displayTurnsFromPartialSnapshot(partialSnapshot, isProcessing)
            : _displayTurnsForRender(isProcessing);
        _syncTurnKeys(displayTurns.length);
        final currentPlaybackTurnIndex = _currentPlaybackTurnIndex(
          displayTurns,
        );
        final countText =
            partialSnapshot.total != null && isProcessing && _turns.isEmpty
            ? '${partialSnapshot.turns.length}/${partialSnapshot.total!}'
            : '${displayTurns.where((e) => !e.isPlaceholder).length}';

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Transcript',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: fg,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    countText,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: muted,
                    ),
                  ),
                ),
                const Spacer(),
                if (!isProcessing)
                  Text(
                    canPlayAudio ? 'Tap to play audio' : 'Long-press to edit',
                    style: TextStyle(
                      color: muted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (isProcessing && displayTurns.isEmpty)
              const _InlineHint(
                text: 'No segments yet. Transcribing in real time…',
              ),
            if (_processingFailed && displayTurns.isEmpty)
              const _InlineHint(text: 'No segments were generated.'),
            if (displayTurns.isNotEmpty)
              ...List.generate(displayTurns.length, (i) {
                final u = displayTurns[i];
                if (u.isPlaceholder) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _TurnPlaceholderCard(
                      speaker: u.speaker,
                      subtitle: _subtitleForTurn(u),
                    ),
                  );
                }

                final subtitle = (u.startSec != null && u.endSec != null)
                    ? '${_fmtClock(Duration(seconds: u.startSec!.round()))} - ${_fmtClock(Duration(seconds: u.endSec!.round()))}'
                    : null;
                final turnId = (!showingEdited && i < _turns.length)
                    ? _turns[i].id
                    : null;
                final isActiveSearchMatch =
                    searchCount > 0 &&
                    _currentSearchMatch >= 0 &&
                    _searchMatches[_currentSearchMatch] == i;
                final isCurrentPlaybackSegment = currentPlaybackTurnIndex == i;
                final speakerColor = _speakerPaletteColor(u.speaker);

                final baseSpeakerStyle = TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13.5,
                  letterSpacing: -0.1,
                  color: speakerColor,
                );
                final baseTextStyle = TextStyle(
                  height: 1.4,
                  fontSize: 14.5,
                  color: fg,
                  fontWeight: FontWeight.w500,
                );
                final highlightColor = isActiveSearchMatch
                    ? const Color(0xFFFFD54F)
                    : const Color(0xFFFFF176);

                final speakerSpan = _buildHighlightedSpan(
                  u.speaker,
                  normalStyle: baseSpeakerStyle,
                  highlightStyle: baseSpeakerStyle.copyWith(
                    backgroundColor: highlightColor,
                    color: Colors.black,
                  ),
                );
                final textSpan = _buildHighlightedSpan(
                  u.text,
                  normalStyle: baseTextStyle,
                  highlightStyle: baseTextStyle.copyWith(
                    backgroundColor: highlightColor,
                    color: Colors.black,
                  ),
                );

                return Padding(
                  key: _turnKeys[i],
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ModernTurnCard(
                    speaker: u.speaker,
                    text: u.text,
                    speakerSpan: speakerSpan,
                    textSpan: textSpan,
                    subtitle: subtitle,
                    speakerColor: speakerColor,
                    canPlayAudio: canPlayAudio && u.startSec != null,
                    isActiveSearchMatch: isActiveSearchMatch,
                    isCurrentPlaybackSegment: isCurrentPlaybackSegment,
                    onTap: (canPlayAudio && u.startSec != null)
                        ? () => _playFromSegment(u, effectiveV)
                        : null,
                    onLongPress: turnId == null
                        ? null
                        : () => _showTurnActions(turnId),
                    onOptions: turnId == null
                        ? null
                        : () => _showTurnActions(turnId),
                  ),
                );
              }),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    final t = _t;
    if (t == null) {
      return const Scaffold(body: Center(child: Text('Not found')));
    }

    final title = (t.title?.trim().isNotEmpty ?? false)
        ? t.title!.trim()
        : 'Transcript';

    final isProcessing = _isProcessingNow;

    final origPath = _getOriginalPath();
    final enhPath = _getEnhancedPath();
    final origExists = _fileExists(origPath);
    final enhExists = _fileExists(enhPath);

    final effectiveV = _effectiveVariant(
      origExists: origExists,
      enhExists: enhExists,
    );

    final hasAnyAudio = origExists || enhExists;
    final canPlayAudio = hasAnyAudio && !_isTranscribingNow;

    final showingEdited =
        (t.editedText != null && t.editedText!.trim().isNotEmpty);
    final hasSearch = _searchQuery.trim().isNotEmpty;
    final searchCount = _searchMatches.length;
    final currentMatchDisplay = (searchCount > 0 && _currentSearchMatch >= 0)
        ? '${_currentSearchMatch + 1}/$searchCount'
        : (hasSearch ? '0/0' : '');

    return Scaffold(
      backgroundColor: GlassTokens.backgroundColor(context),
      body: SafeArea(
        child: Stack(
          children: [
            ListView(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
              children: [
                // Top Header Bar
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _IconCircleButton(
                      icon: Icons.arrow_back_rounded,
                      tooltip: 'Back',
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: InkWell(
                        onTap: _isTranscribingNow ? null : _editTitle,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 17.5,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: -0.3,
                                        color: fg,
                                      ),
                                    ),
                                  ),
                                  if (!_isTranscribingNow) ...[
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.edit_rounded,
                                      size: 14,
                                      color: muted.withValues(alpha: 0.6),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _IconCircleButton(
                      icon: Icons.search_rounded,
                      tooltip: 'Search transcript',
                      onTap: _searchOpen ? null : _openSearch,
                    ),
                    const SizedBox(width: 6),
                    PopupMenuButton<String>(
                      icon: Container(
                        padding: const EdgeInsets.all(7.5),
                        decoration: BoxDecoration(
                          color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.05),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.08),
                          ),
                        ),
                        child: Icon(
                          Icons.more_vert_rounded,
                          size: 19,
                          color: fg,
                        ),
                      ),
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      color: isDark ? const Color(0xFF191922) : Colors.white,
                      elevation: 8,
                      onSelected: (val) async {
                        if (val == 'title') {
                          _editTitle();
                        } else if (val == 'edit') {
                          _editWholeTranscript();
                        } else if (val == 'share') {
                          _shareWholeTranscript();
                        } else if (val == 'report') {
                          _reportTranscript();
                        }
                      },
                      itemBuilder: (ctx) => [
                        PopupMenuItem(
                          value: 'title',
                          child: Row(
                            children: [
                              Icon(Icons.edit_note_rounded, size: 18, color: fg),
                              const SizedBox(width: 10),
                              Text(
                                'Edit Title',
                                style: TextStyle(
                                  color: fg,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'edit',
                          child: Row(
                            children: [
                              Icon(Icons.edit_document, size: 18, color: fg),
                              const SizedBox(width: 10),
                              Text(
                                'Edit Transcript',
                                style: TextStyle(
                                  color: fg,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'share',
                          child: Row(
                            children: [
                              Icon(Icons.ios_share_rounded, size: 18, color: fg),
                              const SizedBox(width: 10),
                              Text(
                                'Share',
                                style: TextStyle(
                                  color: fg,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const PopupMenuDivider(height: 8),
                        const PopupMenuItem(
                          value: 'report',
                          child: Row(
                            children: [
                              Icon(Icons.flag_rounded, size: 18, color: Color(0xFFFF3B30)),
                              SizedBox(width: 10),
                              Text(
                                'Report Issue',
                                style: TextStyle(
                                  color: Color(0xFFFF3B30),
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 10),

                // Metadata Chips Row
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _ModernMetaChip(
                      icon: Icons.language_rounded,
                      label: 'Lang • ${t.lang.toUpperCase()}',
                    ),
                    _ModernMetaChip(
                      icon: Icons.calendar_today_rounded,
                      label: _fmtMetaShort(t),
                    ),
                    if (t.durationSec.isFinite && t.durationSec > 0)
                      _ModernMetaChip(
                        icon: Icons.timer_outlined,
                        label: _fmtClock(Duration(seconds: t.durationSec.round())),
                      ),
                    if (showingEdited)
                      const _ModernMetaChip(
                        icon: Icons.edit_rounded,
                        label: 'Edited',
                        accent: Color(0xFFFF9500),
                      ),
                  ],
                ),

                const SizedBox(height: 14),

                if (_searchOpen) const SizedBox(height: 86),

                // Audio Player Hero Card + Quick Action Buttons
                _ModernAudioHeroCard(
                  isDark: isDark,
                  fg: fg,
                  muted: muted,
                  isTranscribingNow: _isTranscribingNow,
                  hasAnyAudio: hasAnyAudio,
                  canPlayAudio: canPlayAudio,
                  isPlaying: _isPlaying,
                  audioVariant: effectiveV,
                  origExists: origExists,
                  enhExists: enhExists,
                  pos: _pos,
                  dur: _dur,
                  playbackRate: _playbackRate,
                  onToggleSpeed: _togglePlaybackRate,
                  fmt: _fmtClock,
                  onToggle: () => _togglePlayPause(effectiveV),
                  onSwitch: _switchVariant,
                  onSeek: _seekTo,
                  onSummary: _isTranscribingNow
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
                  onAskAi: _isTranscribingNow
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
                  onCopy: _isTranscribingNow ? null : _copyWholeTranscript,
                  onExport: _isTranscribingNow ? null : _openTranscriptExportSheet,
                ),

                const SizedBox(height: 16),

                // Real-time Processing Card
                if (isProcessing)
                  Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1B2332) : const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFF007AFF).withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF007AFF)),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Processing audio… Keep app open',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                  color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF007AFF),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            _ModernMetaChip(
                              icon: Icons.sync_rounded,
                              label: 'Stage • $_progressStage',
                            ),
                            _ModernMetaChip(
                              icon: Icons.timer_outlined,
                              label:
                                  '${_fmtClock(Duration(milliseconds: (_progressProcessedSec * 1000).round()))}'
                                  ' / ${_fmtClock(Duration(milliseconds: ((_progressTotalSec > 0 ? _progressTotalSec : (t.durationSec)) * 1000).round()))}',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                if (_processingFailed)
                  Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF2C1619) : const Color(0xFFFFECEF),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.redAccent.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline_rounded,
                          color: Colors.redAccent,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _processingError ?? 'Transcription failed. Please try again.',
                            style: const TextStyle(
                              color: Colors.redAccent,
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                // People / Speakers Section
                if (!_processingFailed)
                  _buildPeopleSection(theme: Theme.of(context), fg: fg),

                // Transcript Turns Section
                _buildTurnsSection(
                  theme: Theme.of(context),
                  fg: fg,
                  isProcessing: isProcessing,
                  canPlayAudio: canPlayAudio,
                  effectiveV: effectiveV,
                  showingEdited: showingEdited,
                  searchCount: searchCount,
                ),
              ],
            ),

            // Floating Search Bar Overlay
            if (_searchOpen)
              Positioned(
                left: 14,
                right: 14,
                top: 56,
                child: _FloatingSearchBar(
                  controller: _searchCtrl,
                  hasSearch: hasSearch,
                  searchCount: searchCount,
                  currentMatchDisplay: currentMatchDisplay,
                  onChanged: _handleSearchChanged,
                  onClear: _clearSearch,
                  onClose: _closeSearch,
                  onPrevious: searchCount > 0 ? _goToPreviousSearchMatch : null,
                  onNext: searchCount > 0 ? _goToNextSearchMatch : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ===================== HELPER FUNCTIONS =====================

Color _speakerPaletteColor(String name) {
  final clean = name.trim().toLowerCase();
  final hash = clean.codeUnits.fold(0, (prev, elem) => prev + elem);
  const palette = [
    Color(0xFF007AFF), // Blue
    Color(0xFF8E52FF), // Purple
    Color(0xFF00BFA5), // Teal
    Color(0xFFFF9500), // Amber
    Color(0xFFFF2D55), // Pink
    Color(0xFF5856D6), // Indigo
    Color(0xFF34C759), // Green
  ];
  return palette[hash % palette.length];
}

// ===================== MODERN UI WIDGETS =====================

class _ModernMetaChip extends StatelessWidget {
  const _ModernMetaChip({
    required this.label,
    this.icon,
    this.accent,
  });

  final String label;
  final IconData? icon;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final muted = GlassTokens.muted(context);
    final color = accent ?? muted;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
      decoration: BoxDecoration(
        color: (accent ?? (isDark ? Colors.white : Colors.black)).withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: (accent ?? (isDark ? Colors.white : Colors.black)).withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12.5, color: color),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _IconCircleButton extends StatelessWidget {
  const _IconCircleButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final disabled = onTap == null;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(7.5),
          decoration: BoxDecoration(
            color: (isDark ? Colors.white : Colors.black).withValues(
              alpha: disabled ? 0.02 : 0.05,
            ),
            shape: BoxShape.circle,
            border: Border.all(
              color: (isDark ? Colors.white : Colors.black).withValues(
                alpha: disabled ? 0.04 : 0.08,
              ),
            ),
          ),
          child: Icon(
            icon,
            size: 19,
            color: disabled ? fg.withValues(alpha: 0.3) : fg,
          ),
        ),
      ),
    );
  }
}

class _ModernPersonChip extends StatelessWidget {
  const _ModernPersonChip({
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
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);
    final speakerColor = _speakerPaletteColor(label);

    final initial = label.trim().isNotEmpty
        ? label.trim().substring(0, label.trim().length >= 2 ? 2 : 1).toUpperCase()
        : 'S';

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: enabled ? onEdit : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF191922) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark ? const Color(0xFF282834) : const Color(0xFFEEF0F6),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.15)
                  : Colors.black.withValues(alpha: 0.02),
              blurRadius: 4,
              offset: const Offset(0, 1.5),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Speaker Avatar Circle
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: speakerColor.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  initial,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: speakerColor,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 7),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: 7),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
              decoration: BoxDecoration(
                color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (enabled) ...[
              const SizedBox(width: 5),
              Icon(
                Icons.edit_rounded,
                size: 13,
                color: muted.withValues(alpha: 0.7),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModernAudioHeroCard extends StatelessWidget {
  const _ModernAudioHeroCard({
    required this.isDark,
    required this.fg,
    required this.muted,
    required this.isTranscribingNow,
    required this.hasAnyAudio,
    required this.canPlayAudio,
    required this.isPlaying,
    required this.audioVariant,
    required this.origExists,
    required this.enhExists,
    required this.pos,
    required this.dur,
    required this.playbackRate,
    required this.onToggleSpeed,
    required this.fmt,
    required this.onToggle,
    required this.onSwitch,
    required this.onSeek,
    required this.onSummary,
    required this.onAskAi,
    required this.onCopy,
    required this.onExport,
  });

  final bool isDark;
  final Color fg;
  final Color muted;
  final bool isTranscribingNow;
  final bool hasAnyAudio;
  final bool canPlayAudio;
  final bool isPlaying;
  final _AudioVariant audioVariant;
  final bool origExists;
  final bool enhExists;
  final Duration pos;
  final Duration dur;
  final double playbackRate;
  final VoidCallback onToggleSpeed;
  final String Function(Duration) fmt;
  final Future<void> Function() onToggle;
  final Future<void> Function(_AudioVariant) onSwitch;
  final Future<void> Function(double) onSeek;
  final VoidCallback? onSummary;
  final VoidCallback? onAskAi;
  final VoidCallback? onCopy;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    const primaryColor = Color(0xFF007AFF);

    final statusTitle = isTranscribingNow
        ? 'Processing Recording…'
        : (hasAnyAudio ? 'Audio Playback' : 'Audio Unavailable');

    final speedText = playbackRate == 1.0
        ? '1x'
        : (playbackRate == 1.25
            ? '1.25x'
            : (playbackRate == 1.5
                ? '1.5x'
                : (playbackRate == 2.0 ? '2x' : '${playbackRate}x')));

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF191922) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark ? const Color(0xFF282834) : const Color(0xFFEEF0F6),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: 0.22)
                : Colors.black.withValues(alpha: 0.035),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Audio Player Header Row
          Row(
            children: [
              Icon(
                Icons.audiotrack_rounded,
                size: 17,
                color: primaryColor,
              ),
              const SizedBox(width: 7),
              Text(
                statusTitle,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: fg,
                  letterSpacing: -0.1,
                ),
              ),
              const Spacer(),
              if (!isTranscribingNow && (origExists || enhExists))
                _VariantDropdown(
                  value: audioVariant,
                  origEnabled: origExists,
                  enhEnabled: enhExists,
                  onChanged: (v) => onSwitch(v),
                ),
            ],
          ),

          const SizedBox(height: 12),

          // Waveform Player Bar (Matching screenshot)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF121218)
                  : const Color(0xFFF3F4F8),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isDark
                    ? const Color(0xFF22222E)
                    : const Color(0xFFE5E7EB),
                width: 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Play / Pause Circle Button
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: canPlayAudio ? onToggle : null,
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: canPlayAudio
                          ? (isDark ? const Color(0xFF2A2A38) : const Color(0xFFE2E4EB))
                          : (isDark ? const Color(0xFF1F1F2A) : const Color(0xFFEEEEF2)),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 20,
                      color: canPlayAudio ? fg : muted,
                    ),
                  ),
                ),

                const SizedBox(width: 8),

                // Current timestamp
                Text(
                  fmt(pos),
                  style: TextStyle(
                    color: fg,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),

                const SizedBox(width: 8),

                // Audio Waveform
                Expanded(
                  child: _WaveformSeekBar(
                    pos: pos,
                    dur: dur,
                    onSeek: onSeek,
                    primaryColor: primaryColor,
                  ),
                ),

                const SizedBox(width: 8),

                // Total duration timestamp
                Text(
                  fmt(dur),
                  style: TextStyle(
                    color: muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),

                const SizedBox(width: 8),

                // Speed button (1x / 1.5x)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: canPlayAudio ? onToggleSpeed : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      speedText,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: canPlayAudio ? fg : muted,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),
          Divider(
            height: 1,
            color: isDark ? const Color(0xFF282834) : const Color(0xFFEEF0F6),
          ),
          const SizedBox(height: 12),

          // 2x2 Quick Actions Grid
          Row(
            children: [
              Expanded(
                child: _QuickActionButton(
                  icon: Icons.summarize_rounded,
                  label: 'Summary',
                  isPrimary: true,
                  onTap: onSummary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _QuickActionButton(
                  icon: Icons.auto_awesome_rounded,
                  label: 'Ask AI',
                  isPrimary: true,
                  onTap: onAskAi,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _QuickActionButton(
                  icon: Icons.copy_rounded,
                  label: 'Copy',
                  isPrimary: false,
                  onTap: onCopy,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _QuickActionButton(
                  icon: Icons.ios_share_rounded,
                  label: 'Export',
                  isPrimary: false,
                  onTap: onExport,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WaveformSeekBar extends StatelessWidget {
  const _WaveformSeekBar({
    required this.pos,
    required this.dur,
    required this.onSeek,
    required this.primaryColor,
  });

  final Duration pos;
  final Duration dur;
  final Future<void> Function(double) onSeek;
  final Color primaryColor;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final inactive = isDark
        ? Colors.white.withValues(alpha: 0.16)
        : Colors.black.withValues(alpha: 0.12);

    final totalMs = dur.inMilliseconds <= 0 ? 1 : dur.inMilliseconds;
    final currentMs = pos.inMilliseconds.clamp(0, totalMs);
    final progress = (currentMs / totalMs).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        void handleSeek(Offset localPosition) {
          final ratio = (localPosition.dx / width).clamp(0.0, 1.0);
          onSeek(ratio * totalMs);
        }

        final count = (width / 5.2).clamp(24.0, 48.0).toInt();

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (details) => handleSeek(details.localPosition),
          onTapDown: (details) => handleSeek(details.localPosition),
          child: Container(
            height: 32,
            width: double.infinity,
            alignment: Alignment.center,
            child: CustomPaint(
              size: Size(width, 24),
              painter: _WaveformPainter(
                progress: progress,
                barCount: count,
                activeColor: primaryColor,
                inactiveColor: inactive,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.progress,
    required this.barCount,
    required this.activeColor,
    required this.inactiveColor,
  });

  final double progress;
  final int barCount;
  final Color activeColor;
  final Color inactiveColor;

  // Normalized heights with realistic audio voice wave dynamics
  static final List<double> _baseHeights = [
    0.20, 0.28, 0.35, 0.50, 0.42, 0.65, 0.78, 0.55, 0.88, 0.95,
    0.72, 0.60, 0.82, 1.00, 0.85, 0.68, 0.92, 0.75, 0.58, 0.80,
    0.65, 0.48, 0.70, 0.85, 0.90, 0.78, 0.62, 0.84, 0.96, 0.74,
    0.52, 0.68, 0.82, 0.60, 0.45, 0.58, 0.40, 0.32, 0.25, 0.20,
    0.30, 0.22,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final count = barCount;
    final totalWidth = size.width;
    final maxHeight = size.height;
    final centerY = maxHeight / 2;

    const barWidth = 2.4;
    final spacing = (totalWidth - (count * barWidth)) / (count - 1);

    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.fill;

    final inactivePaint = Paint()
      ..color = inactiveColor
      ..style = PaintingStyle.fill;

    for (var i = 0; i < count; i++) {
      final x = i * (barWidth + spacing);
      final barProgress = i / (count - 1);
      final isPlayed = barProgress <= progress;

      final heightFactor = _baseHeights[i % _baseHeights.length];
      final barH = (maxHeight * heightFactor).clamp(3.5, maxHeight);
      final top = centerY - (barH / 2);

      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, top, barWidth, barH),
        const Radius.circular(2.0),
      );

      canvas.drawRRect(rrect, isPlayed ? activePaint : inactivePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor ||
        oldDelegate.barCount != barCount;
  }
}

class _QuickActionButton extends StatelessWidget {
  const _QuickActionButton({
    required this.icon,
    required this.label,
    required this.isPrimary,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isPrimary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    const primaryColor = Color(0xFF007AFF);
    final disabled = onTap == null;

    final bg = isPrimary
        ? (disabled
            ? primaryColor.withValues(alpha: 0.4)
            : primaryColor)
        : (isDark ? const Color(0xFF22222E) : const Color(0xFFF4F5F9));

    final textFg = isPrimary
        ? Colors.white
        : (disabled ? fg.withValues(alpha: 0.35) : fg);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: isPrimary
                ? null
                : Border.all(
                    color: isDark ? const Color(0xFF333344) : const Color(0xFFE2E4EB),
                    width: 1,
                  ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: textFg),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: textFg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModernTurnCard extends StatelessWidget {
  const _ModernTurnCard({
    required this.speaker,
    required this.text,
    required this.speakerColor,
    this.subtitle,
    this.speakerSpan,
    this.textSpan,
    this.canPlayAudio = false,
    this.isActiveSearchMatch = false,
    this.isCurrentPlaybackSegment = false,
    this.onTap,
    this.onLongPress,
    this.onOptions,
  });

  final String speaker;
  final String text;
  final Color speakerColor;
  final String? subtitle;
  final InlineSpan? speakerSpan;
  final InlineSpan? textSpan;
  final bool canPlayAudio;
  final bool isActiveSearchMatch;
  final bool isCurrentPlaybackSegment;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onOptions;

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);
    final isDark = GlassTokens.isDark(context);

    final initial = speaker.trim().isNotEmpty
        ? speaker.trim().substring(0, speaker.trim().length >= 2 ? 2 : 1).toUpperCase()
        : 'S';

    return Container(
      decoration: BoxDecoration(
        color: isCurrentPlaybackSegment
            ? (isDark ? const Color(0xFF1B2433) : const Color(0xFFF0F6FF))
            : (isDark ? const Color(0xFF191922) : Colors.white),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: isCurrentPlaybackSegment
              ? const Color(0xFF007AFF)
              : (isDark ? const Color(0xFF282834) : const Color(0xFFEEF0F6)),
          width: isCurrentPlaybackSegment ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: 0.16)
                : Colors.black.withValues(alpha: 0.025),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(15),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header Row: Speaker avatar + Name + Time badge + Equalizer/Menu
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Speaker Avatar Badge
                    Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: speakerColor.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          initial,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: speakerColor,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(width: 8),

                    // Speaker Name
                    Expanded(
                      child: Text.rich(
                        speakerSpan ??
                            TextSpan(
                              text: speaker,
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 13.5,
                                letterSpacing: -0.1,
                                color: speakerColor,
                              ),
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),

                    const SizedBox(width: 6),

                    // Timestamp Badge
                    if (subtitle != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                        decoration: BoxDecoration(
                          color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (canPlayAudio) ...[
                              Icon(
                                isCurrentPlaybackSegment
                                    ? Icons.graphic_eq_rounded
                                    : Icons.play_arrow_rounded,
                                size: 12,
                                color: isCurrentPlaybackSegment
                                    ? const Color(0xFF007AFF)
                                    : muted,
                              ),
                              const SizedBox(width: 3),
                            ],
                            Text(
                              subtitle!,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isCurrentPlaybackSegment
                                    ? const Color(0xFF007AFF)
                                    : muted,
                              ),
                            ),
                          ],
                        ),
                      ),

                    if (onOptions != null) ...[
                      const SizedBox(width: 4),
                      InkWell(
                        onTap: onOptions,
                        borderRadius: BorderRadius.circular(999),
                        child: Padding(
                          padding: const EdgeInsets.all(3),
                          child: Icon(
                            Icons.more_horiz_rounded,
                            size: 16,
                            color: muted,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),

                const SizedBox(height: 8),

                // Text Content
                Text.rich(
                  textSpan ??
                      TextSpan(
                        text: text,
                        style: TextStyle(
                          height: 1.4,
                          fontSize: 14.5,
                          color: fg,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  style: TextStyle(
                    height: 1.4,
                    fontSize: 14.5,
                    color: fg,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TurnPlaceholderCard extends StatefulWidget {
  const _TurnPlaceholderCard({this.speaker, this.subtitle});

  final String? speaker;
  final String? subtitle;

  @override
  State<_TurnPlaceholderCard> createState() => _TurnPlaceholderCardState();
}

class _TurnPlaceholderCardState extends State<_TurnPlaceholderCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);
    final isDark = GlassTokens.isDark(context);

    return FadeTransition(
      opacity: Tween<double>(begin: 0.55, end: 0.9).animate(_controller),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF191922) : Colors.white,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: isDark ? const Color(0xFF282834) : const Color(0xFFEEF0F6),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (widget.speaker?.trim().isNotEmpty ?? false)
                  Text(
                    widget.speaker!.trim(),
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.1,
                      color: fg,
                      fontSize: 13.5,
                    ),
                  )
                else
                  const _ShimmerBlock(width: 72, height: 12),
                const Spacer(),
                if (widget.subtitle?.trim().isNotEmpty ?? false)
                  Text(
                    widget.subtitle!.trim(),
                    style: TextStyle(
                      color: muted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                else
                  const _ShimmerBlock(width: 42, height: 18, radius: 6),
              ],
            ),
            const SizedBox(height: 10),
            const _ShimmerBlock(width: double.infinity, height: 12),
            const SizedBox(height: 6),
            const _ShimmerBlock(width: double.infinity, height: 12),
            const SizedBox(height: 6),
            const _ShimmerBlock(width: 180, height: 12),
          ],
        ),
      ),
    );
  }
}

class _ShimmerBlock extends StatelessWidget {
  const _ShimmerBlock({
    required this.width,
    required this.height,
    this.radius = 6,
  });

  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.08),
      ),
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
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.05),
        border: Border.all(
          color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.08),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<_AudioVariant>(
          value: value,
          dropdownColor: isDark ? const Color(0xFF191922) : Colors.white,
          style: TextStyle(
            color: fg,
            fontWeight: FontWeight.w700,
            fontSize: 12,
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

class _InlineHint extends StatelessWidget {
  const _InlineHint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final muted = GlassTokens.muted(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          color: muted,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _FloatingSearchBar extends StatelessWidget {
  const _FloatingSearchBar({
    required this.controller,
    required this.hasSearch,
    required this.searchCount,
    required this.currentMatchDisplay,
    required this.onChanged,
    required this.onClear,
    required this.onClose,
    required this.onPrevious,
    required this.onNext,
  });

  final TextEditingController controller;
  final bool hasSearch;
  final int searchCount;
  final String currentMatchDisplay;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final VoidCallback onClose;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF191922) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? const Color(0xFF282834) : const Color(0xFFE2E4EB),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.12),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.search_rounded,
                size: 19,
                color: const Color(0xFF007AFF),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  onChanged: onChanged,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Search keyword…',
                    hintStyle: TextStyle(
                      color: muted,
                      fontWeight: FontWeight.w500,
                    ),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              if (hasSearch)
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: onClear,
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: Icon(
                      Icons.close_rounded,
                      size: 17,
                      color: muted,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Divider(
            height: 1,
            color: isDark ? const Color(0xFF282834) : const Color(0xFFEEF0F6),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  hasSearch
                      ? (searchCount > 0
                            ? 'Matches: $currentMatchDisplay'
                            : 'No matches found')
                      : 'Type to search in transcript',
                  style: TextStyle(
                    color: muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _IconCircleButton(
                tooltip: 'Previous match',
                icon: Icons.keyboard_arrow_up_rounded,
                onTap: onPrevious,
              ),
              const SizedBox(width: 6),
              _IconCircleButton(
                tooltip: 'Next match',
                icon: Icons.keyboard_arrow_down_rounded,
                onTap: onNext,
              ),
              const SizedBox(width: 6),
              _IconCircleButton(
                tooltip: 'Close search',
                icon: Icons.close_rounded,
                onTap: onClose,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

