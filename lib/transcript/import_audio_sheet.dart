import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../audio_converter_service.dart';
import '../audio_utils.dart' show readWavDuration;
import '../common/app_flushbar.dart';
import '../objectbox/entities.dart';
import '../objectbox/objectbox_store.dart';

import 'background_transcriber.dart';
import '../paywall/transcription_premium_gate.dart';
import 'transcript_detail_page.dart';

// ✅ Glass primitives (same as RecordSheet)
import '../ui/glass/liquid_glass.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_button.dart';
import '../ui/glass/glass_divider.dart';

class ImportAudioSheet extends StatefulWidget {
  const ImportAudioSheet({super.key});

  static Future<void> show(BuildContext context) async {
    const kBusyTranscribing = 'busy_transcribing';

    final busyFlag =
        (await FlutterForegroundTask.getData(key: kBusyTranscribing)) == true;
    final running = await FlutterForegroundTask.isRunningService;

    final busy = busyFlag && running;
    if (busyFlag && !running) {
      await FlutterForegroundTask.saveData(
        key: kBusyTranscribing,
        value: false,
      );
    }

    if (busy) {
      if (!context.mounted) return;
      await AppFlushbar.info(
        context,
        message: 'Transcription in progress… Please wait.',
      );
      return;
    }

    if (!context.mounted) return;

    return showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const ImportAudioSheet(),
    );
  }

  @override
  State<ImportAudioSheet> createState() => _ImportAudioSheetState();
}

class _ImportAudioSheetState extends State<ImportAudioSheet> {
  static const String _kPrefDefaultLang = 'pref_default_lang';
  static const String _kPrefDiarizationEnabled = 'pref_diarization_enabled';
  static const String _kBusyTranscribing = 'busy_transcribing';
  static const String _kActiveTranscriptId = 'bg_active_transcript_id';

  static const Map<String, String> _langOptions = {
    'en': 'English',
    'es': 'Spanish',
    'fr': 'French',
    'ar': 'Arabic',
    'pt': 'Portuguese',
    'it': 'Italian',
    'zh': 'Chinese',
    'auto': 'Auto',
  };

  final TextEditingController _targetSpeakersCtrl = TextEditingController(
    text: '0',
  );

  PlatformFile? _picked;
  String? _inputPathTemp;
  bool _working = false;

  String _selectedLang = 'en';
  bool _diarizationEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  @override
  void dispose() {
    _targetSpeakersCtrl.dispose();
    _cleanupTempInput();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final lang = (sp.getString(_kPrefDefaultLang) ?? 'en').trim();
      final safeLang = _langOptions.containsKey(lang) ? lang : 'en';
      final diar = sp.getBool(_kPrefDiarizationEnabled) ?? true;

      if (!mounted) return;
      setState(() {
        _selectedLang = safeLang;
        _diarizationEnabled = diar;
      });
    } catch (_) {}
  }

  Future<void> _cleanupTempInput() async {
    final p = _inputPathTemp;
    _inputPathTemp = null;
    if (p == null) return;
    try {
      final f = File(p);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  int? _parseTargetSpeakers() {
    if (!_diarizationEnabled) return null;

    final raw = _targetSpeakersCtrl.text.trim();
    if (raw.isEmpty) return null;

    final n = int.tryParse(raw);
    if (n == null) return null;

    if (n <= 0) return null;
    return n.clamp(1, 12);
  }

  Future<void> _pickFile() async {
    if (_working) return;
    await _cleanupTempInput();

    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'wav',
          'mp3',
          'm4a',
          'aac',
          'ogg',
          'flac',
          'mp4',
        ],
        withReadStream: true,
        withData: false,
      );

      if (res == null || res.files.isEmpty) return;
      final f = res.files.single;

      if (!mounted) return;
      setState(() => _picked = f);

      await AppFlushbar.success(context, message: 'Selected: ${f.name}');
    } on PlatformException catch (e) {
      if (e.code == 'already_active') return;
      rethrow;
    }
  }

  Future<String> _ensureReadableLocalPath(PlatformFile f) async {
    final p = f.path;
    if (p != null) {
      final file = File(p);
      if (file.existsSync()) return p;
    }

    final rs = f.readStream;
    if (rs == null) throw Exception('Could not access file path or stream.');

    final tmpDir = await getTemporaryDirectory();
    final ext = (f.extension ?? 'audio').toLowerCase();
    final safeExt = ext.length <= 6 ? ext : 'audio';
    final outPath =
        '${tmpDir.path}/import_in_${DateTime.now().millisecondsSinceEpoch}.$safeExt';

    final outFile = File(outPath);
    final sink = outFile.openWrite();
    try {
      await rs.pipe(sink);
    } finally {
      await sink.flush();
      await sink.close();
    }

    _inputPathTemp = outPath;
    return outPath;
  }

  Future<String> _convertToWav16kMono(String inputPath) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/recordings')
      ..createSync(recursive: true);

    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    final outPath = '${dir.path}/import_$ts.wav';

    try {
      return await AudioConverterService.convertToWav16kMono(
        inputPath,
        outputPath: outPath,
      );
    } on AudioConversionException catch (e) {
      throw Exception('Audio conversion failed: ${e.message}');
    }
  }

  Future<void> _start() async {
    if (_working) return;
    final f = _picked;
    if (f == null) {
      await AppFlushbar.info(context, message: 'Select an audio file first.');
      return;
    }

    final allowed = await ensureIosPremiumForTranscription(context);
    if (!allowed) return;
    if (!mounted) return;

    setState(() => _working = true);

    try {
      await AppFlushbar.info(context, message: 'Preparing audio…');

      final inputPath = await _ensureReadableLocalPath(f);
      final wavPath = await _convertToWav16kMono(inputPath);

      await _cleanupTempInput();

      double durationSec = 0.0;
      try {
        durationSec = await readWavDuration(wavPath);
      } catch (_) {}

      final lang = (_selectedLang.trim().isEmpty)
          ? 'auto'
          : _selectedLang.trim();
      final targetSpeakers = _parseTargetSpeakers();

      final obx = ObjectBox.I;

      final tId = obx.transcripts.put(
        TranscriptEntity(
          title: '',
          model: 'whisper',
          sourceType: 2,
          lang: lang,
          audioPath: wavPath,
          durationSec: durationSec,
          createdAt: DateTime.now(),
        ),
      );

      final jobId = obx.jobs.put(
        TranscriptionJobEntity(
          wavPath: wavPath,
          translateToEnglish: false,
          titleHint: null,
          transcriptId: tId,
          status: 'PENDING',
          createdAt: DateTime.now(),
        ),
      );

      await FlutterForegroundTask.saveData(
        key: _kBusyTranscribing,
        value: true,
      );
      await FlutterForegroundTask.saveData(
        key: _kActiveTranscriptId,
        value: tId,
      );

      if (!mounted) return;

      Navigator.of(context).pop();
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TranscriptDetailPage(transcriptId: tId),
        ),
      );

      try {
        await BackgroundTranscriber.start(
          wavPath: wavPath,
          translateToEnglish: false,
          titleHint: null,
          existingTranscriptId: tId,
          targetSpeakers: targetSpeakers,
          lang: lang,
        );

        final job = obx.jobs.get(jobId);
        if (job != null && job.status == 'PENDING') {
          job.status = 'RUNNING';
          obx.jobs.put(job);
        }
      } catch (e) {
        final job = obx.jobs.get(jobId);
        if (job != null) {
          job.status = 'ERROR';
          job.error = 'Failed to start transcription.';
          obx.jobs.put(job);
        }
        await FlutterForegroundTask.saveData(
          key: _kBusyTranscribing,
          value: false,
        );
        await FlutterForegroundTask.saveData(
          key: _kActiveTranscriptId,
          value: 0,
        );

        if (!mounted) return;
        await AppFlushbar.error(context, message: 'Processing failed!');
      }
    } catch (_) {
      await FlutterForegroundTask.saveData(
        key: _kBusyTranscribing,
        value: false,
      );
      await FlutterForegroundTask.saveData(key: _kActiveTranscriptId, value: 0);
      if (mounted) {
        await AppFlushbar.error(context, message: 'Processing failed!');
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height * 0.70;

    final fg = Colors.white.withValues(alpha: 0.92);
    final selectedName = _picked?.name;

    // ✅ close pill: tint-only
    Widget closePill() {
      return LiquidGlass(
        borderRadius: BorderRadius.circular(999),
        padding: const EdgeInsets.all(8),
        shadow: false,
        blurX: 0,
        blurY: 0,
        grain: false,
        tintOpacityDark: 0.070,
        tintOpacityLight: 0.055,
        borderOpacityDark: 0.16,
        borderOpacityLight: 0.20,
        onTap: () => Navigator.of(context).pop(),
        child: Icon(Icons.close, color: fg, size: 20),
      );
    }

    return SizedBox(
      height: h,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        child: Stack(
          children: [
            // ✅ PERF: sheet backdrop is tint-only (global blur should exist behind)
            LiquidGlass(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(22),
              ),
              padding: EdgeInsets.zero,
              shadow: false,
              blurX: 9.0,
              blurY: 9.0,
              grain: false,
              tintOpacityDark: 0.10,
              tintOpacityLight: 0.08,
              borderOpacityDark: 0.18,
              borderOpacityLight: 0.22,
              child: const SizedBox.expand(),
            ),

            Column(
              children: [
                // ---------- Header ----------
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Icon(Icons.audio_file, color: fg),
                            const SizedBox(width: 8),
                            Text(
                              'Audio Transcribe',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: fg,
                              ),
                            ),
                            if (_working) ...[
                              const SizedBox(width: 10),
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white.withValues(alpha: 0.75),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      closePill(),
                    ],
                  ),
                ),

                const GlassDivider(),

                // ---------- Body ----------
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // File panel
                        GlassCard(
                          variant: GlassCardVariant.tile,
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                selectedName ?? 'No file selected',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: fg,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: GlassButton(
                                      kind: GlassButtonKind.secondary,
                                      label: 'Choose file',
                                      icon: Icons.upload_file,
                                      onPressed: _working ? null : _pickFile,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: GlassButton(
                                      kind: GlassButtonKind.primary,
                                      label: 'Transcribe',
                                      icon: Icons.play_arrow_rounded,
                                      loading: false,
                                      onPressed: (_working || _picked == null)
                                          ? null
                                          : _start,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Do not close this while intial processing',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.70),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 12),

                        // Options panel
                        GlassCard(
                          variant: GlassCardVariant.tile,
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Options',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: fg,
                                ),
                              ),
                              const SizedBox(height: 12),

                              // Language row
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Language',
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.72,
                                        ),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 180,
                                    child: _GlassField(
                                      enabled: !_working,
                                      child: DropdownButtonFormField<String>(
                                        initialValue: _selectedLang,
                                        isDense: true,
                                        iconEnabledColor: Colors.white
                                            .withValues(alpha: 0.80),
                                        dropdownColor: const Color(0xFF0B0C10),
                                        items: _langOptions.entries
                                            .map(
                                              (e) => DropdownMenuItem<String>(
                                                value: e.key,
                                                child: Text(
                                                  e.value,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: Colors.white
                                                        .withValues(
                                                          alpha: 0.92,
                                                        ),
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                            )
                                            .toList(),
                                        onChanged: _working
                                            ? null
                                            : (v) {
                                                if (v == null) return;
                                                setState(
                                                  () => _selectedLang = v,
                                                );
                                              },
                                        decoration: const InputDecoration(
                                          isDense: true,
                                          border: InputBorder.none,
                                          contentPadding: EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 10,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),

                              const SizedBox(height: 12),

                              // Diarization
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Speaker diarization',
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.72,
                                        ),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Switch(
                                    value: _diarizationEnabled,
                                    onChanged: _working
                                        ? null
                                        : (v) => setState(
                                            () => _diarizationEnabled = v,
                                          ),
                                    activeThumbColor: Colors.black,
                                    activeTrackColor: Colors.white.withValues(
                                      alpha: 0.55,
                                    ),
                                    inactiveThumbColor: Colors.white.withValues(
                                      alpha: 0.70,
                                    ),
                                    inactiveTrackColor: Colors.white.withValues(
                                      alpha: 0.18,
                                    ),
                                  ),
                                ],
                              ),

                              if (_diarizationEnabled) ...[
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        'Target speakers',
                                        style: TextStyle(
                                          color: Colors.white.withValues(
                                            alpha: 0.72,
                                          ),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 120,
                                      child: Theme(
                                        data: Theme.of(context).copyWith(
                                          textSelectionTheme:
                                              TextSelectionThemeData(
                                                selectionHandleColor: Colors
                                                    .white
                                                    .withValues(alpha: 0.90),
                                                cursorColor: Colors.white
                                                    .withValues(alpha: 0.90),
                                                selectionColor: Colors.white
                                                    .withValues(alpha: 0.18),
                                              ),
                                        ),
                                        child: _GlassField(
                                          enabled: !_working,
                                          child: TextField(
                                            controller: _targetSpeakersCtrl,
                                            enabled: !_working,
                                            keyboardType: TextInputType.number,
                                            inputFormatters: [
                                              FilteringTextInputFormatter
                                                  .digitsOnly,
                                            ],
                                            style: TextStyle(
                                              color: Colors.white.withValues(
                                                alpha: 0.92,
                                              ),
                                              fontWeight: FontWeight.w600,
                                            ),
                                            cursorColor: Colors.white
                                                .withValues(alpha: 0.90),
                                            decoration: InputDecoration(
                                              hintText: '0',
                                              hintStyle: TextStyle(
                                                color: Colors.white.withValues(
                                                  alpha: 0.45,
                                                ),
                                                fontWeight: FontWeight.w600,
                                              ),
                                              isDense: true,
                                              border: InputBorder.none,
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 10,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Use 0 for auto-detect.',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.55),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// ✅ optimized helper: tint-only field
class _GlassField extends StatelessWidget {
  const _GlassField({required this.child, required this.enabled});

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    Widget field = LiquidGlass(
      borderRadius: BorderRadius.circular(14),
      padding: EdgeInsets.zero,
      shadow: false,

      // ✅ PERF: fields are interactive => tint-only
      blurX: 0,
      blurY: 0,
      grain: false,

      tintOpacityDark: 0.075,
      tintOpacityLight: 0.060,
      borderOpacityDark: 0.16,
      borderOpacityLight: 0.20,
      child: child,
    );

    if (!enabled) field = Opacity(opacity: 0.55, child: field);
    return field;
  }
}
