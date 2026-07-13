import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'transcription_models.dart';

class TranscriptBlockRepository {
  TranscriptBlockRepository._();

  static final TranscriptBlockRepository instance =
      TranscriptBlockRepository._();

  Future<Directory> _rootDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'transcript_blocks'))
      ..createSync(recursive: true);
    return dir;
  }

  Future<File> _fileForTranscript(int transcriptId) async {
    final dir = await _rootDir();
    return File(p.join(dir.path, '$transcriptId.json'));
  }

  Future<List<TranscriptBlockSnapshot>> load(int transcriptId) async {
    try {
      final file = await _fileForTranscript(transcriptId);
      if (!await file.exists()) return const [];

      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return const [];

      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];

      return decoded
          .whereType<Map>()
          .map(
            (e) =>
                TranscriptBlockSnapshot.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(
    int transcriptId,
    List<TranscriptBlockSnapshot> blocks,
  ) async {
    try {
      final file = await _fileForTranscript(transcriptId);
      final payload = blocks.map((b) => b.toJson()).toList();
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
        flush: true,
      );
    } catch (_) {
      // Keep transcript persistence resilient; block cache is best-effort.
    }
  }

  Future<void> upsert(int transcriptId, TranscriptBlockSnapshot block) async {
    final blocks = <TranscriptBlockSnapshot>[...await load(transcriptId)];
    final index = blocks.indexWhere((b) => b.blockId == block.blockId);
    if (index >= 0) {
      blocks[index] = block;
    } else {
      blocks.add(block);
      blocks.sort((a, b) => a.blockId.compareTo(b.blockId));
    }
    await save(transcriptId, blocks);
  }

  Future<void> clear(int transcriptId) async {
    try {
      final file = await _fileForTranscript(transcriptId);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
