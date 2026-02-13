import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../audio_converter_service.dart';

import '../common/app_flushbar.dart';
import '../objectbox/entities.dart';
import '../objectbox/objectbox_store.dart';
import '../audio_utils.dart' show readWavDuration;

import 'background_transcriber.dart';
import 'transcript_detail_page.dart';

class ImportVideoSheet extends StatefulWidget {
  const ImportVideoSheet({super.key});

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
      builder: (_) => const ImportVideoSheet(),
    );
  }

  @override
  State<ImportVideoSheet> createState() => _ImportVideoSheetState();
}

class _ImportVideoSheetState extends State<ImportVideoSheet> {
  // must match SettingsPage keys
  static const String _kPrefDefaultLang = 'pref_default_lang';
  static const String _kPrefDiarizationEnabled = 'pref_diarization_enabled';

  static const String _kBusyTranscribing = 'busy_transcribing';

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
  String?
  _inputPathTemp; // temp input copy if needed (deleted after conversion)
  bool _working = false;

  // loaded from prefs
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

    // 0 => auto (null)
    if (n <= 0) return null;

    return n.clamp(1, 12);
  }

  Future<void> _pickFile() async {
    if (_working) return;

    await _cleanupTempInput();

    try {
      // Video extensions
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'mp4',
          'mkv',
          'mov',
          'webm',
          'm4v',
          '3gp',
          'avi',
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

    // content:// fallback
    final rs = f.readStream;
    if (rs == null) throw Exception('Could not access file path or stream.');

    final tmpDir = await getTemporaryDirectory();
    final ext = (f.extension ?? 'mp4').toLowerCase();
    final safeExt = ext.length <= 6 ? ext : 'mp4';
    final outPath =
        '${tmpDir.path}/import_vid_${DateTime.now().millisecondsSinceEpoch}.$safeExt';

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

  Future<String> _extractAudioToWav16kMono(String inputVideoPath) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/recordings')
      ..createSync(recursive: true);

    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    final outPath = '${dir.path}/import_video_$ts.wav';

    // Use native audio converter (MediaCodec on Android, AVFoundation on iOS)
    // This extracts audio from video and converts to 16kHz mono WAV
    try {
      return await AudioConverterService.convertToWav16kMono(
        inputVideoPath,
        outputPath: outPath,
      );
    } on AudioConversionException catch (e) {
      throw Exception('Audio extraction failed: ${e.message}');
    }
  }

  Future<void> _start() async {
    if (_working) return;
    final f = _picked;
    if (f == null) {
      await AppFlushbar.info(context, message: 'Select a video file first.');
      return;
    }

    setState(() => _working = true);

    try {
      await AppFlushbar.info(context, message: 'Extracting audio…');

      final inputPath = await _ensureReadableLocalPath(f);

      // ✅ Extract -> WAV (this is what you will save)
      final wavPath = await _extractAudioToWav16kMono(inputPath);

      // ✅ requirement: only save converted audio
      await _cleanupTempInput();

      double durationSec = 0.0;
      try {
        durationSec = await readWavDuration(wavPath);
      } catch (_) {
        durationSec = 0.0;
      }

      final lang = (_selectedLang.trim().isEmpty)
          ? 'auto'
          : _selectedLang.trim();
      final targetSpeakers = _parseTargetSpeakers();

      final obx = ObjectBox.I;

      final tId = obx.transcripts.put(
        TranscriptEntity(
          title: '',
          model: 'whisper',
          sourceType: 3,
          lang: lang,
          audioPath: wavPath, // ✅ save extracted WAV only
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

        if (!mounted) return;
        await AppFlushbar.error(context, message: 'Processing failed!');
      }
    } catch (e) {
      await FlutterForegroundTask.saveData(
        key: _kBusyTranscribing,
        value: false,
      );
      if (mounted) {
        await AppFlushbar.error(context, message: 'Processing failed!');
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final h = MediaQuery.of(context).size.height * 0.70;

    final surface = cs.surface;
    final border = cs.outlineVariant.withOpacity(0.35);
    final titleColor = cs.onSurface;
    final subtle = cs.onSurfaceVariant;

    final selectedName = _picked?.name;

    return SizedBox(
      height: h,
      child: Container(
        decoration: BoxDecoration(
          color: surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          border: Border.all(color: border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        // Center(
                        //   child: Container(
                        //     width: 44,
                        //     height: 5,
                        //     margin: const EdgeInsets.only(bottom: 10),
                        //     decoration: BoxDecoration(
                        //       borderRadius: BorderRadius.circular(99),
                        //       color: subtle.withOpacity(0.35),
                        //     ),
                        //   ),
                        // ),
                        Row(
                          children: [
                            Icon(Icons.video_file, color: Colors.white),
                            const SizedBox(width: 8),
                            Text(
                              'Video Transcribe',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                            if (_working) ...[
                              const SizedBox(width: 10),
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  backgroundColor: Colors.black,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: titleColor),
                    onPressed: _working
                        ? null
                        : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            selectedName == null
                                ? 'No video selected'
                                : selectedName,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: titleColor,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _working ? null : _pickFile,
                                  icon: const Icon(
                                    Icons.upload_file,
                                    color: Colors.white,
                                  ),
                                  label: const Text(
                                    'Choose video',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: (_working || _picked == null)
                                      ? null
                                      : _start,
                                  icon: const Icon(
                                    Icons.play_arrow_rounded,
                                    color: Colors.black,
                                  ),
                                  label: const Text(
                                    'Transcribe',
                                    style: TextStyle(color: Colors.black),
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    backgroundColor:
                                        (_working || _picked == null)
                                        ? null
                                        : Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Only the extracted WAV is saved in the app.',
                            style: TextStyle(color: subtle, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    _Panel(
                      title: 'Options',
                      subtitle: 'Set before starting',
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Language',
                                  style: TextStyle(
                                    color: subtle,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 190,
                                child: DropdownButtonFormField<String>(
                                  value: _selectedLang,
                                  items: _langOptions.entries
                                      .map(
                                        (e) => DropdownMenuItem<String>(
                                          value: e.key,
                                          child: Text(e.value),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: _working
                                      ? null
                                      : (v) {
                                          if (v == null) return;
                                          setState(() => _selectedLang = v);
                                        },
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                    enabledBorder: OutlineInputBorder(
                                      borderSide: BorderSide(
                                        color: Color(0xFFff8143),
                                        width: 1,
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderSide: BorderSide(
                                        color: Color(0xFFff8143),
                                        width: 1,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Speaker diarization',
                                  style: TextStyle(
                                    color: subtle,
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
                                activeColor: Colors.black, // thumb
                                activeTrackColor: const Color(
                                  0xFFff8143,
                                ), // track
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
                                      color: subtle,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 120,
                                  child: Theme(
                                    data: Theme.of(context).copyWith(
                                      textSelectionTheme:
                                          const TextSelectionThemeData(
                                            selectionHandleColor:
                                                Colors.white, // ✅ bubble color
                                            cursorColor: Colors.white,
                                            selectionColor: Color.fromARGB(
                                              128,
                                              255,
                                              130,
                                              67,
                                            ),
                                          ),
                                    ),
                                    child: TextField(
                                      cursorColor: Colors.white,
                                      controller: _targetSpeakersCtrl,
                                      enabled: !_working,
                                      keyboardType: TextInputType.number,
                                      inputFormatters: [
                                        FilteringTextInputFormatter.digitsOnly,
                                      ],
                                      decoration: const InputDecoration(
                                        hintText: '0',
                                        isDense: true,
                                        border: OutlineInputBorder(),
                                        enabledBorder: OutlineInputBorder(
                                          borderSide: BorderSide(
                                            color: Color(0xFFff8143),
                                            width: 1,
                                          ),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderSide: BorderSide(
                                            color: Color(0xFFff8143),
                                            width: 1,
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
                              style: TextStyle(color: subtle, fontSize: 12),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Tip: If your video has multiple speakers, diarization helps a lot.',
                      style: TextStyle(color: subtle, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.title, this.subtitle});

  final Widget child;
  final String? title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final bg = cs.surfaceContainerHighest;
    final border = cs.outlineVariant.withOpacity(0.35);
    final titleColor = cs.onSurface;
    final subtle = cs.onSurfaceVariant;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            color: Colors.black.withOpacity(
              theme.brightness == Brightness.dark ? 0.20 : 0.08,
            ),
            offset: const Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(
              title!,
              style: TextStyle(fontWeight: FontWeight.w800, color: titleColor),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(subtitle!, style: TextStyle(color: subtle, fontSize: 12)),
            ],
            const SizedBox(height: 12),
          ],
          child,
        ],
      ),
    );
  }
}
