import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../audio_utils.dart';
import '../asr_service.dart';

class LiveWhisperPreview {
  LiveWhisperPreview._({
    required this.text,
    required this.partial,
    required this.status,
    required this.available,
  });

  final String text;
  final String partial;
  final String status;
  final bool available;

  factory LiveWhisperPreview.idle() => LiveWhisperPreview._(
    text: '',
    partial: '',
    status: 'Listening...',
    available: true,
  );

  factory LiveWhisperPreview.unavailable(String status) => LiveWhisperPreview._(
    text: '',
    partial: '',
    status: status,
    available: false,
  );
}

class LiveWhisperPreviewService {
  static const _sampleRate = 16000;
  static const _bytesPerSample = 2;
  static const _wavHeaderBytes = 44;
  static const _chunkSeconds = 8;
  static const _stableTailSeconds = 1;

  final _updates = StreamController<LiveWhisperPreview>.broadcast();
  final _asr = AsrService();

  Timer? _timer;
  bool _stopped = true;
  bool _acceptingChunks = false;
  bool _decoding = false;
  int _runId = 0;
  int _nextChunkStartBytes = 0;
  String _text = '';
  String? _wavPath;
  String _lang = 'en';
  final _jobs = Queue<_PreviewJob>();

  Stream<LiveWhisperPreview> get updates => _updates.stream;
  String get currentText => _text.trim();

  bool get isSupported => !Platform.isFuchsia;

  Future<void> start(String wavPath, {String lang = 'en'}) async {
    await stop(finalize: false);

    if (!isSupported) {
      _emit(LiveWhisperPreview.unavailable('Live preview unavailable here'));
      return;
    }

    _stopped = false;
    _acceptingChunks = true;
    _wavPath = wavPath;
    _lang = lang;
    _nextChunkStartBytes = 0;
    _text = '';
    _jobs.clear();
    final runId = ++_runId;
    debugPrint('[LiveWhisper] start path=$wavPath lang=$lang run=$runId');
    _emit(LiveWhisperPreview.idle());
    _timer = Timer.periodic(
      const Duration(seconds: 8),
      (_) => _pump(wavPath: wavPath, lang: lang, runId: runId),
    );
    unawaited(_pump(wavPath: wavPath, lang: lang, runId: runId));
  }

  Future<void> pause() async {
    _acceptingChunks = false;
    debugPrint('[LiveWhisper] pause; queued=${_jobs.length}');
    unawaited(_drainJobs(lang: _lang, runId: _runId));
  }

  Future<void> resume() async {
    if (_stopped) return;
    _acceptingChunks = true;
    debugPrint('[LiveWhisper] resume; queued=${_jobs.length}');
    final path = _wavPath;
    if (path != null) {
      unawaited(_pump(wavPath: path, lang: _lang, runId: _runId));
    }
  }

  Future<void> stop({bool finalize = true}) async {
    _stopped = true;
    _acceptingChunks = false;
    _runId++;
    _clearJobs();
    _timer?.cancel();
    _timer = null;
    _wavPath = null;
    debugPrint('[LiveWhisper] stop');
  }

  Future<void> dispose() async {
    await stop(finalize: false);
    _asr.releaseCachedRecognizer();
    await _updates.close();
  }

  Future<void> _pump({
    required String wavPath,
    required String lang,
    required int runId,
  }) async {
    if (_stopped || !_acceptingChunks || runId != _runId) return;
    try {
      final source = File(wavPath);
      if (!source.existsSync()) {
        debugPrint('[LiveWhisper] source missing path=$wavPath');
        return;
      }

      final stableBytes = await _stableAudioBytes(source);
      final chunkBytes = _chunkSeconds * _sampleRate * _bytesPerSample;
      debugPrint(
        '[LiveWhisper] pump stableBytes=$stableBytes next=$_nextChunkStartBytes queued=${_jobs.length} decoding=$_decoding',
      );
      while (stableBytes - _nextChunkStartBytes >= chunkBytes) {
        final path = await _writeSnapshot(
          source,
          startBytes: _nextChunkStartBytes,
          audioBytes: chunkBytes,
        );
        _jobs.add(_PreviewJob(path));
        debugPrint(
          '[LiveWhisper] queued chunk path=$path start=$_nextChunkStartBytes bytes=$chunkBytes queued=${_jobs.length}',
        );
        _nextChunkStartBytes += chunkBytes;
      }
      unawaited(_drainJobs(lang: lang, runId: runId));
    } catch (e, st) {
      debugPrint('[LiveWhisper] pump error: $e\n$st');
    }
  }

  Future<void> _drainJobs({required String lang, required int runId}) async {
    if (_stopped || runId != _runId) return;
    if (_decoding) {
      debugPrint('[LiveWhisper] drain skipped, decode already running');
      return;
    }
    _decoding = true;
    try {
      while (_jobs.isNotEmpty && runId == _runId) {
        final job = _jobs.removeFirst();
        try {
          debugPrint(
            '[LiveWhisper] decode start path=${job.path} remaining=${_jobs.length}',
          );
          final result = await _asr.transcribeWav(
            wavPath: job.path,
            lang: lang,
            diarize: false,
          );
          if (runId != _runId) return;
          final text = result.trim();
          debugPrint('[LiveWhisper] decode done chars=${text.length}');
          if (text.isNotEmpty) {
            _text = [_text, text].where((v) => v.trim().isNotEmpty).join('\n');
            _emit(
              LiveWhisperPreview._(
                text: _text,
                partial: '',
                status: '',
                available: true,
              ),
            );
          } else {
            debugPrint('[LiveWhisper] empty chunk result');
          }
        } catch (e, st) {
          debugPrint('[LiveWhisper] chunk error: $e\n$st');
        } finally {
          try {
            File(job.path).deleteSync();
          } catch (_) {}
        }
      }
    } finally {
      _decoding = false;
      debugPrint('[LiveWhisper] drain idle queued=${_jobs.length}');
    }
  }

  void _clearJobs() {
    while (_jobs.isNotEmpty) {
      final job = _jobs.removeFirst();
      try {
        File(job.path).deleteSync();
      } catch (_) {}
    }
  }

  Future<int> _stableAudioBytes(File source) async {
    final length = await source.length();
    if (length <= _wavHeaderBytes) return 0;

    final tailBytes = _stableTailSeconds * _sampleRate * _bytesPerSample;
    final audioBytes = length - _wavHeaderBytes - tailBytes;
    if (audioBytes <= 0) return 0;
    return audioBytes - (audioBytes % _bytesPerSample);
  }

  Future<String> _writeSnapshot(
    File source, {
    required int startBytes,
    required int audioBytes,
  }) async {
    final out = File(
      '${Directory.systemTemp.path}/live_whisper_${DateTime.now().microsecondsSinceEpoch}.wav',
    );

    final input = await source.open();
    try {
      await input.setPosition(_wavHeaderBytes + startBytes);
      final audio = await input.read(audioBytes);
      final samples = Int16List.view(Uint8List.fromList(audio).buffer);
      await writePcm16MonoWav(
        out.path,
        sampleRate: _sampleRate,
        samples: samples,
      );
      return out.path;
    } finally {
      await input.close();
    }
  }

  void _emit(LiveWhisperPreview preview) {
    if (!_updates.isClosed) _updates.add(preview);
  }
}

class _PreviewJob {
  const _PreviewJob(this.path);

  final String path;
}
