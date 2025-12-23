import 'dart:async';

import 'package:flutter/material.dart';

import 'qwen_model_service.dart';
import 'whisper_service.dart';

class ModelPickerPage extends StatefulWidget {
  const ModelPickerPage({super.key});

  @override
  State<ModelPickerPage> createState() => _ModelPickerPageState();
}

class _ModelPickerPageState extends State<ModelPickerPage> {
  String? _error;

  // Qwen state
  final QwenModelService _qwenService = QwenModelService();
  ModelProgress _qwenProgress = ModelProgress.idle;
  bool _qwenDownloaded = false;
  StreamSubscription<ModelProgress>? _qwenSub;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _qwenSub?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() => _error = null);
    try {
      _qwenDownloaded = await _qwenService.isModelDownloaded();
      _qwenProgress = ModelProgress.idle;

      _qwenSub = _qwenService.progress.listen((p) async {
        if (!mounted) return;
        setState(() => _qwenProgress = p);

        final finishedOk =
            !p.downloading && p.error == null && p.total == 1 && p.received == 1;
        if (finishedOk) {
          final ok2 = await _qwenService.isModelDownloaded();
          if (!mounted) return;
          setState(() => _qwenDownloaded = ok2);
        }
      });

      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = 'Init failed: $e');
    }
  }

  Future<void> _downloadQwen() async {
    setState(() => _error = null);
    try {
      await _qwenService.downloadModel();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Download failed: $e');
    }
  }

  Future<void> _cancelQwen() async {
    setState(() => _error = null);
    try {
      await _qwenService.cancelDownload();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Cancel failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _qwenProgress;
    final isDl = p.downloading;
    final isReady = _qwenDownloaded;

    Widget trailing;
    if (isDl) {
      final pct = (p.percent * 100).toStringAsFixed(0);
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: p.total == 0 ? null : p.percent,
            ),
          ),
          const SizedBox(width: 8),
          Text('$pct%'),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _cancelQwen,
            child: const Text('Cancel'),
          ),
        ],
      );
    } else if (isReady) {
      trailing = const Padding(
        padding: EdgeInsets.only(right: 6),
        child: Chip(label: Text('Downloaded')),
      );
    } else {
      trailing = FilledButton(
        onPressed: _downloadQwen,
        child: const Text('Download'),
      );
    }

    final statusText = isDl
        ? (p.error != null ? 'Error: ${p.error}' : 'Downloading…')
        : (isReady ? 'Downloaded' : 'Not downloaded');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Model Download'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            elevation: 0.6,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.all(14),
              leading: const CircleAvatar(
                child: Icon(Icons.smart_toy_outlined),
              ),
              title: const Text('Qwen3-0.6B  •  Q4_K_M'),
              subtitle: Text(
                'Local LLM used for AI Chat\n$statusText',
              ),
              isThreeLine: true,
              trailing: trailing,
            ),
          ),
        ],
      ),
      bottomNavigationBar: _error == null
          ? null
          : Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
    );
  }
}
