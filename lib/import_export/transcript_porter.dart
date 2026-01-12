import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../objectbox.g.dart';

class TranscriptPorter {
  // ==========================
  // Public API
  // ==========================

  /// Export everything to ZIP (manifest.json + audio files).
  /// Returns created ZIP path.
  static Future<String> exportAllToZipFile({bool includeAudio = true}) async {
    final obx = ObjectBox.I;
    final transcriptsBox = obx.store.box<TranscriptEntity>();

    final qb = transcriptsBox.query()
      ..order(TranscriptEntity_.createdAt, flags: Order.descending);
    final q = qb.build();
    final transcripts = q.find();
    q.close();

    final manifest = <String, dynamic>{
      "version": 2, // ✅ ZIP version
      "exportedAt": DateTime.now().toUtc().toIso8601String(),
      "app": "transcript",
      "transcripts": <Map<String, dynamic>>[],
    };

    final archive = Archive();

    for (final t in transcripts) {
      final uid = _uidForTranscript(t);

      String? audioRelPath;
      if (includeAudio) {
        audioRelPath = await _maybeAddAudioToArchive(archive, uid, t.audioPath);
      }

      manifest["transcripts"].add(
        _toManifestMap(t, uid: uid, audioRelPath: audioRelPath),
      );
    }

    // Add manifest.json
    final manifestBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(manifest),
    );
    archive.addFile(
      ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
    );

    // Write ZIP into app documents
    final dir = await getApplicationDocumentsDirectory();
    final fileName =
        'transcripts_export_${DateTime.now().toIso8601String().replaceAll(':', '-')}.zip';
    final zipPath = p.join(dir.path, fileName);

    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null) {
      throw Exception('Failed to create ZIP.');
    }
    await File(zipPath).writeAsBytes(zipBytes, flush: true);

    return zipPath;
  }

  /// Export ZIP then open share sheet (Drive / Gmail / etc).
  static Future<void> exportZipAndShare({bool includeAudio = true}) async {
    final path = await exportAllToZipFile(includeAudio: includeAudio);
    await Share.shareXFiles([XFile(path)], text: 'Transcripts export (ZIP)');
  }

  /// Pick a ZIP file (device or cloud provider) and import everything into DB.
  /// Returns number of imported transcripts.
  static Future<int> pickAndImportZip() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      withData: true, // cloud providers may return bytes
    );

    if (result == null || result.files.isEmpty) return 0;

    final f = result.files.first;

    Uint8List bytes;
    if (f.bytes != null) {
      bytes = f.bytes!;
    } else if (f.path != null) {
      bytes = await File(f.path!).readAsBytes();
    } else {
      return 0;
    }

    return importFromZipBytes(bytes);
  }

  /// Import from ZIP bytes. Inserts transcripts+turns and restores audio files.
  static Future<int> importFromZipBytes(Uint8List zipBytes) async {
    final obx = ObjectBox.I;
    final store = obx.store;

    final archive = ZipDecoder().decodeBytes(zipBytes);

    // 1) Read manifest.json
    final manifestFile = archive.files.firstWhere(
      (f) => f.name == 'manifest.json',
      orElse: () =>
          throw const FormatException('manifest.json not found in ZIP'),
    );

    final manifestStr = utf8.decode(manifestFile.content as List<int>);
    final decoded = json.decode(manifestStr);

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid manifest format.');
    }

    final version = decoded['version'];
    if (version != 2) {
      throw FormatException('Unsupported ZIP version: $version');
    }

    final list = decoded['transcripts'];
    if (list is! List) {
      throw const FormatException('Missing transcripts array.');
    }

    // 2) Prepare import audio dir
    final docs = await getApplicationDocumentsDirectory();
    final audioDir = Directory(p.join(docs.path, 'imports', 'audio'));
    if (!audioDir.existsSync()) audioDir.createSync(recursive: true);

    // 3) Build a map: archive path -> bytes (for audio files)
    final Map<String, ArchiveFile> fileByName = {
      for (final f in archive.files) f.name: f,
    };

    int importedCount = 0;

    store.runInTransaction(TxMode.write, () {
      for (final item in list) {
        if (item is! Map) continue;
        final m = item.cast<String, dynamic>();

        final uid = (m['uid'] ?? '').toString();
        if (uid.isEmpty) continue;

        // Restore audio (if present)
        String? restoredAudioPath;
        final audioRel = (m['audioRelPath'] ?? '').toString().trim();
        if (audioRel.isNotEmpty) {
          final af = fileByName[audioRel];
          if (af != null && af.content is List<int>) {
            final bytes = af.content as List<int>;
            final ext = p.extension(audioRel);
            final outPath = p.join(audioDir.path, '$uid$ext');

            // write file (overwrite if exists)
            File(outPath).writeAsBytesSync(bytes, flush: true);
            restoredAudioPath = outPath;
          }
        }

        // Create transcript (new id)
        final t = _fromManifestMap(m, restoredAudioPath: restoredAudioPath);
        final newId = store.box<TranscriptEntity>().put(t);

        // Create turns
        final turns = (m['turns'] is List) ? (m['turns'] as List) : const [];
        for (final turnObj in turns) {
          if (turnObj is! Map) continue;
          final u = TranscriptTurnEntity(
            speakerLabel: (turnObj['speakerLabel'] ?? 'Speaker').toString(),
            startSec: (turnObj['startSec'] as num?)?.toDouble() ?? 0.0,
            endSec: (turnObj['endSec'] as num?)?.toDouble() ?? 0.0,
            text: (turnObj['text'] ?? '').toString(),
          )..transcript.targetId = newId;

          store.box<TranscriptTurnEntity>().put(u);
        }

        importedCount++;
      }
    });

    return importedCount;
  }

  // ==========================
  // Manifest helpers
  // ==========================

  static String _uidForTranscript(TranscriptEntity t) {
    // Stable enough, avoids collisions:
    // createdAt millis + duration + id (if present)
    final ms = t.createdAt.toUtc().millisecondsSinceEpoch;
    final dur = (t.durationSec * 1000).round();
    final id = t.id;
    return 't_${ms}_${dur}_$id';
  }

  static Map<String, dynamic> _toManifestMap(
    TranscriptEntity t, {
    required String uid,
    required String? audioRelPath,
  }) {
    final turns = t.turns; // lazy load
    return <String, dynamic>{
      "uid": uid,
      "title": t.title,
      "model": t.model,
      "lang": t.lang,
      "durationSec": t.durationSec,
      "editedText": t.editedText,
      "fullTextCache": t.fullTextCache,
      "searchText": t.searchText,
      "createdAt": t.createdAt.toUtc().toIso8601String(),
      "audioRelPath": audioRelPath, // e.g. audio/t_xxx.m4a
      "turns": turns
          .map(
            (u) => {
              "speakerLabel": u.speakerLabel,
              "startSec": u.startSec,
              "endSec": u.endSec,
              "text": u.text,
            },
          )
          .toList(),
    };
  }

  static TranscriptEntity _fromManifestMap(
    Map<String, dynamic> m, {
    required String? restoredAudioPath,
  }) {
    final createdRaw = m['createdAt']?.toString();
    final createdAt =
        DateTime.tryParse(createdRaw ?? '')?.toLocal() ?? DateTime.now();

    final edited = (m['editedText']?.toString() ?? '').trim();
    final full = (m['fullTextCache']?.toString() ?? '').trim();
    final computedSearch = edited.isNotEmpty ? edited : full;

    return TranscriptEntity(
      id: 0,
      title: ((m['title'] as String?)?.trim().isEmpty ?? true)
          ? null
          : (m['title'] as String?)?.trim(),
      model: (m['model'] ?? 'unknown').toString(),
      lang: (m['lang'] ?? 'unknown').toString(),
      audioPath: restoredAudioPath, // ✅ restored file path
      durationSec: (m['durationSec'] as num?)?.toDouble() ?? 0.0,
      editedText: edited.isEmpty ? null : edited,
      fullTextCache: full.isEmpty ? null : full,
      searchText: computedSearch.isEmpty ? null : computedSearch,
      createdAt: createdAt,
    );
  }

  // ==========================
  // Audio packing
  // ==========================

  static Future<String?> _maybeAddAudioToArchive(
    Archive archive,
    String uid,
    String? audioPath,
  ) async {
    if (audioPath == null) return null;
    final path = audioPath.trim();
    if (path.isEmpty) return null;

    final f = File(path);
    if (!await f.exists()) return null;

    final ext = p.extension(path).toLowerCase();
    // if no extension, default
    final safeExt = ext.isEmpty ? '.m4a' : ext;

    final bytes = await f.readAsBytes();
    final rel = 'audio/$uid$safeExt';

    archive.addFile(ArchiveFile(rel, bytes.length, bytes));
    return rel;
  }
}
