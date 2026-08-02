import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:vosk_flutter/vosk_flutter.dart';

class LiveVoskPreview {
  LiveVoskPreview._({
    required this.text,
    required this.partial,
    required this.status,
    required this.available,
  });

  final String text;
  final String partial;
  final String status;
  final bool available;

  factory LiveVoskPreview.idle() => LiveVoskPreview._(
    text: '',
    partial: '',
    status: 'Listening...',
    available: true,
  );

  factory LiveVoskPreview.unavailable(String status) => LiveVoskPreview._(
    text: '',
    partial: '',
    status: status,
    available: false,
  );
}

class LiveVoskPreviewService {
  static const _sampleRate = 16000;
  static const _wavHeaderBytes = 44;
  static const _modelAsset =
      'assets/models/vosk/vosk-model-small-en-us-0.15.zip';

  final _updates = StreamController<LiveVoskPreview>.broadcast();
  final _modelLoader = ModelLoader();
  final _vosk = VoskFlutterPlugin.instance();

  Timer? _timer;
  Recognizer? _recognizer;
  Model? _model;
  String _text = '';
  int _offset = _wavHeaderBytes;
  bool _running = false;

  Stream<LiveVoskPreview> get updates => _updates.stream;

  bool get isSupported =>
      Platform.isAndroid || Platform.isLinux || Platform.isWindows;

  Future<void> start(String wavPath) async {
    await stop(finalize: false);

    if (!isSupported) {
      _emit(LiveVoskPreview.unavailable('Live preview unavailable here'));
      return;
    }

    if (!await _hasBundledModel()) {
      _emit(
        LiveVoskPreview.unavailable('Add Vosk model to enable live preview'),
      );
      return;
    }

    try {
      final modelPath = await _modelLoader.loadFromAssets(_modelAsset);
      _model = await _vosk.createModel(modelPath);
      _recognizer = await _vosk.createRecognizer(
        model: _model!,
        sampleRate: _sampleRate,
      );
      _running = true;
      _offset = _wavHeaderBytes;
      _text = '';
      _emit(LiveVoskPreview.idle());
      _timer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _pump(wavPath),
      );
    } catch (_) {
      await stop(finalize: false);
      _emit(LiveVoskPreview.unavailable('Live preview failed to start'));
    }
  }

  Future<void> pause() async {
    _running = false;
  }

  Future<void> resume() async {
    if (_recognizer != null) _running = true;
  }

  Future<void> stop({bool finalize = true}) async {
    _running = false;
    _timer?.cancel();
    _timer = null;

    if (finalize) {
      try {
        final result = await _recognizer?.getFinalResult();
        final text = _extract(result, 'text');
        if (text.isNotEmpty) _append(text);
      } catch (_) {}
    }

    try {
      await _recognizer?.dispose();
    } catch (_) {}
    try {
      _model?.dispose();
    } catch (_) {}

    _recognizer = null;
    _model = null;
  }

  Future<void> dispose() async {
    await stop(finalize: false);
    await _updates.close();
  }

  Future<bool> _hasBundledModel() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      return manifest.listAssets().contains(_modelAsset);
    } catch (_) {
      return false;
    }
  }

  Future<void> _pump(String wavPath) async {
    if (!_running) return;
    final recognizer = _recognizer;
    if (recognizer == null) return;

    try {
      final file = File(wavPath);
      if (!file.existsSync()) return;

      final length = await file.length();
      if (length <= _offset) return;

      final raf = await file.open();
      try {
        await raf.setPosition(_offset);
        final bytes = await raf.read(length - _offset);
        _offset = length;
        if (bytes.isEmpty) return;

        final ready = await recognizer.acceptWaveformBytes(
          Uint8List.fromList(bytes),
        );
        if (ready) {
          final result = await recognizer.getResult();
          final text = _extract(result, 'text');
          if (text.isNotEmpty) _append(text);
          _emitState('');
        } else {
          final partial = _extract(
            await recognizer.getPartialResult(),
            'partial',
          );
          _emitState(partial);
        }
      } finally {
        await raf.close();
      }
    } catch (_) {}
  }

  void _append(String value) {
    _text = [_text, value].where((v) => v.trim().isNotEmpty).join('\n');
  }

  void _emitState(String partial) {
    _emit(
      LiveVoskPreview._(
        text: _text,
        partial: partial,
        status: _text.isEmpty && partial.isEmpty ? 'Listening...' : '',
        available: true,
      ),
    );
  }

  void _emit(LiveVoskPreview preview) {
    if (!_updates.isClosed) _updates.add(preview);
  }

  static String _extract(String? jsonText, String key) {
    if (jsonText == null || jsonText.trim().isEmpty) return '';
    try {
      final decoded = jsonDecode(jsonText);
      final value = decoded is Map ? decoded[key] : null;
      return value is String ? value.trim() : '';
    } catch (_) {
      return '';
    }
  }
}
