// lib/transcript/transcript_porter.dart
//
// ✅ Updated to export+import BOTH voice + YouTube transcripts.
//
// What changes:
// - Manifest version bumped to 3
// - For each TranscriptEntity we now export:
//   - sourceType, youtubeMetaId, updatedAt (if you added them)
// - For YouTube transcripts (sourceType==1) we ALSO export:
//   - youtubeMeta: { videoId, inputUrl, canonicalUrl, title, channel, createdAtMs, updatedAtMs }
//   - youtubeTracks: [{language, languageCode, isGenerated, text, fetchedAtMs}, ...]
//
// Import:
// - Supports version 2 (old voice-only ZIP) and version 3 (voice+youtube ZIP)
// - For youtube items: creates YoutubeTranscriptMetaEntity + YoutubeTranscriptTextEntity,
//   then creates TranscriptEntity row pointing to youtubeMetaId.
//
// Notes:
// - This file uses store.box<T>() so it works even if ObjectBox.I doesn't expose ytMeta/ytTexts directly.
// - Requires you added to TranscriptEntity:
//   - int sourceType (0 voice, 1 youtube)  // default 0
//   - int? youtubeMetaId
//   - DateTime updatedAt
//
// If you didn't add updatedAt yet, remove those lines in _toManifestMap/_fromManifestMap accordingly.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
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

  /// Export everything to ZIP (manifest.json + audio files for voice).
  /// Returns created ZIP path.
  static Future<String> exportAllToZipFile({bool includeAudio = true}) async {
    final obx = ObjectBox.I;
    final store = obx.store;

    final transcriptsBox = store.box<TranscriptEntity>();
    final ytMetaBox = store.box<YoutubeTranscriptMetaEntity>();
    final ytTextBox = store.box<YoutubeTranscriptTextEntity>();

    final qb = transcriptsBox.query()
      ..order(TranscriptEntity_.createdAt, flags: Order.descending);
    final q = qb.build();
    final transcripts = q.find();
    q.close();

    final manifest = <String, dynamic>{
      "version": 3, // ✅ ZIP version (v3 includes YouTube)
      "exportedAt": DateTime.now().toUtc().toIso8601String(),
      "app": "transcript",
      "transcripts": <Map<String, dynamic>>[],
    };

    final archive = Archive();

    for (final t in transcripts) {
      final uid = _uidForTranscript(t);

      final isYoutube = (t.sourceType == 1);

      String? audioRelPath; // original
      String? processedAudioRelPath; // enhanced

      if (includeAudio && !isYoutube) {
        audioRelPath = await _maybeAddAudioToArchive(
          archive,
          uid,
          t.audioPath,
          suffix: '_orig',
        );

        processedAudioRelPath = await _maybeAddAudioToArchive(
          archive,
          uid,
          t.processedAudioPath,
          suffix: '_enh',
        );
      }

      // ✅ YouTube extra payload
      Map<String, dynamic>? youtubeMeta;
      List<Map<String, dynamic>> youtubeTracks = const [];

      if (isYoutube && t.youtubeMetaId != null) {
        final meta = ytMetaBox.get(t.youtubeMetaId!);
        if (meta != null) {
          youtubeMeta = {
            "videoId": meta.videoId,
            "inputUrl": meta.inputUrl,
            "canonicalUrl": meta.canonicalUrl,
            "title": meta.title,
            "channel": meta.channel,
            "createdAtMs": meta.createdAtMs,
            "updatedAtMs": meta.updatedAtMs,
          };

          final tq = ytTextBox
              .query(YoutubeTranscriptTextEntity_.meta.equals(meta.id))
              .build();
          try {
            final tracks = tq.find();
            youtubeTracks = tracks
                .map(
                  (x) => <String, dynamic>{
                    "language": x.language,
                    "languageCode": x.languageCode,
                    "isGenerated": x.isGenerated,
                    "text": x.text,
                    "fetchedAtMs": x.fetchedAtMs,
                  },
                )
                .toList();
          } finally {
            tq.close();
          }
        }
      }

      manifest["transcripts"].add(
        _toManifestMap(
          t,
          uid: uid,
          audioRelPath: audioRelPath,
          processedAudioRelPath: processedAudioRelPath,
          youtubeMeta: youtubeMeta,
          youtubeTracks: youtubeTracks,
        ),
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
  /// Returns number of imported TranscriptEntity rows.
  static Future<int> importFromZipBytes(Uint8List zipBytes) async {
    final obx = ObjectBox.I;
    final store = obx.store;

    final transcriptsBox = store.box<TranscriptEntity>();
    final turnsBox = store.box<TranscriptTurnEntity>();
    final ytMetaBox = store.box<YoutubeTranscriptMetaEntity>();
    final ytTextBox = store.box<YoutubeTranscriptTextEntity>();

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
    if (version != 2 && version != 3) {
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

    // 3) Map: archive path -> file
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

        final sourceType = (m['sourceType'] as num?)?.toInt() ?? 0;

        if (sourceType == 1) {
          // ==========================
          // ✅ YouTube transcript import
          // ==========================

          final ytMetaMap = (m['youtubeMeta'] is Map)
              ? (m['youtubeMeta'] as Map).cast<String, dynamic>()
              : null;
          final ytTracksList = (m['youtubeTracks'] is List)
              ? (m['youtubeTracks'] as List)
              : const [];

          if (ytMetaMap == null) {
            // If missing, skip (corrupt entry)
            continue;
          }

          final videoId = (ytMetaMap['videoId'] ?? '').toString().trim();
          if (videoId.isEmpty) continue;

          // Upsert meta by videoId (Unique on entity)
          int metaId;
          {
            final existingQ = ytMetaBox
                .query(YoutubeTranscriptMetaEntity_.videoId.equals(videoId))
                .build();
            YoutubeTranscriptMetaEntity? existing;
            try {
              existing = existingQ.findFirst();
            } finally {
              existingQ.close();
            }

            if (existing != null) {
              existing
                ..inputUrl = (ytMetaMap['inputUrl'] ?? existing.inputUrl).toString()
                ..canonicalUrl =
                    (ytMetaMap['canonicalUrl'] ?? existing.canonicalUrl).toString()
                ..title = (ytMetaMap['title'] as String?) ?? existing.title
                ..channel = (ytMetaMap['channel'] as String?) ?? existing.channel
                ..updatedAtMs =
                    (ytMetaMap['updatedAtMs'] as num?)?.toInt() ??
                        DateTime.now().millisecondsSinceEpoch;

              metaId = ytMetaBox.put(existing);
            } else {
              final meta = YoutubeTranscriptMetaEntity(
                videoId: videoId,
                inputUrl: (ytMetaMap['inputUrl'] ?? '').toString(),
                canonicalUrl: (ytMetaMap['canonicalUrl'] ?? '').toString(),
                title: (ytMetaMap['title'] as String?),
                channel: (ytMetaMap['channel'] as String?),
                createdAtMs: (ytMetaMap['createdAtMs'] as num?)?.toInt(),
                updatedAtMs: (ytMetaMap['updatedAtMs'] as num?)?.toInt(),
              );
              metaId = ytMetaBox.put(meta);
            }
          }

          // Remove existing tracks for this meta (replace-all)
          final rmQ = ytTextBox
              .query(YoutubeTranscriptTextEntity_.meta.equals(metaId))
              .build();
          try {
            final ids = rmQ.findIds();
            if (ids.isNotEmpty) ytTextBox.removeMany(ids);
          } finally {
            rmQ.close();
          }

          // Insert tracks
          for (final tr in ytTracksList) {
            if (tr is! Map) continue;
            final tm = tr.cast<String, dynamic>();

            final textEntity = YoutubeTranscriptTextEntity(
              language: (tm['language'] as String?),
              languageCode: (tm['languageCode'] as String?),
              isGenerated: (tm['isGenerated'] as bool?) ?? true,
              text: (tm['text'] ?? '').toString(),
              fetchedAtMs: (tm['fetchedAtMs'] as num?)?.toInt(),
            )..meta.targetId = metaId;

            ytTextBox.put(textEntity);
          }

          // Create TranscriptEntity "list row"
          final t = _fromManifestMap(
            m,
            restoredAudioPath: null,
            restoredProcessedAudioPath: null,
          );

          // Force youtube fields
          t
            ..sourceType = 1
            ..youtubeMetaId = metaId
            ..audioPath = null
            ..processedAudioPath = null
            ..durationSec = 0
            ..model = (t.model.trim().isEmpty) ? 'youtube' : t.model
            ..lang = (t.lang.trim().isEmpty) ? 'multi' : t.lang;

          transcriptsBox.put(t);
          importedCount++;
          continue;
        }

        // ==========================
        // ✅ Voice transcript import (v2/v3)
        // ==========================

        // Restore original audio (if present)
        String? restoredAudioPath;
        final audioRel = (m['audioRelPath'] ?? '').toString().trim();
        if (audioRel.isNotEmpty) {
          restoredAudioPath = _restoreAudioFile(
            fileByName: fileByName,
            audioRel: audioRel,
            audioDir: audioDir,
            outBaseName: '${uid}_orig',
          );
        }

        // Restore processed/enhanced audio (if present)
        String? restoredProcessedPath;
        final procRel = (m['processedAudioRelPath'] ?? '').toString().trim();
        if (procRel.isNotEmpty) {
          restoredProcessedPath = _restoreAudioFile(
            fileByName: fileByName,
            audioRel: procRel,
            audioDir: audioDir,
            outBaseName: '${uid}_enh',
          );
        }

        // Create transcript (new id)
        final t = _fromManifestMap(
          m,
          restoredAudioPath: restoredAudioPath,
          restoredProcessedAudioPath: restoredProcessedPath,
        );

        // Ensure voice defaults
        t
          ..sourceType = 0
          ..youtubeMetaId = null;

        final newId = transcriptsBox.put(t);

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

          turnsBox.put(u);
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
    final ms = t.createdAt.toUtc().millisecondsSinceEpoch;
    final dur = (t.durationSec * 1000).round();
    final id = t.id;
    return 't_${ms}_${dur}_$id';
  }

  static Map<String, dynamic> _toManifestMap(
    TranscriptEntity t, {
    required String uid,
    required String? audioRelPath,
    required String? processedAudioRelPath,
    required Map<String, dynamic>? youtubeMeta,
    required List<Map<String, dynamic>> youtubeTracks,
  }) {
    final turns = t.turns; // lazy load

    final isYoutube = (t.sourceType == 1);

    return <String, dynamic>{
      "uid": uid,

      // ✅ common fields
      "title": t.title,
      "model": t.model,
      "lang": t.lang,
      "durationSec": t.durationSec,
      "editedText": t.editedText,
      "fullTextCache": t.fullTextCache,
      "searchText": t.searchText,
      "createdAt": t.createdAt.toUtc().toIso8601String(),

      // ✅ new in v3
      "updatedAt": t.updatedAt.toUtc().toIso8601String(),
      "sourceType": t.sourceType,
      "youtubeMetaId": t.youtubeMetaId,

      // ✅ audio pointers in ZIP (voice only)
      "audioRelPath": isYoutube ? null : audioRelPath,
      "processedAudioRelPath": isYoutube ? null : processedAudioRelPath,

      // ✅ turns (voice only)
      "turns": isYoutube
          ? const []
          : turns
              .map(
                (u) => {
                  "speakerLabel": u.speakerLabel,
                  "startSec": u.startSec,
                  "endSec": u.endSec,
                  "text": u.text,
                },
              )
              .toList(),

      // ✅ youtube payload (youtube only)
      "youtubeMeta": isYoutube ? youtubeMeta : null,
      "youtubeTracks": isYoutube ? youtubeTracks : const [],
    };
  }

  static TranscriptEntity _fromManifestMap(
    Map<String, dynamic> m, {
    required String? restoredAudioPath,
    required String? restoredProcessedAudioPath,
  }) {
    final createdRaw = m['createdAt']?.toString();
    final createdAt =
        DateTime.tryParse(createdRaw ?? '')?.toLocal() ?? DateTime.now();

    final updatedRaw = m['updatedAt']?.toString();
    final updatedAt =
        DateTime.tryParse(updatedRaw ?? '')?.toLocal() ?? createdAt;

    final edited = (m['editedText']?.toString() ?? '').trim();
    final full = (m['fullTextCache']?.toString() ?? '').trim();
    final computedSearch = edited.isNotEmpty ? edited : full;

    final sourceType = (m['sourceType'] as num?)?.toInt() ?? 0;
    final youtubeMetaId = (m['youtubeMetaId'] as num?)?.toInt();

    return TranscriptEntity(
      id: 0,
      title: ((m['title'] as String?)?.trim().isEmpty ?? true)
          ? null
          : (m['title'] as String?)?.trim(),
      model: (m['model'] ?? 'unknown').toString(),
      lang: (m['lang'] ?? 'unknown').toString(),

      // audio (voice only)
      audioPath: restoredAudioPath,
      processedAudioPath: restoredProcessedAudioPath,

      durationSec: (m['durationSec'] as num?)?.toDouble() ?? 0.0,
      editedText: edited.isEmpty ? null : edited,
      fullTextCache: full.isEmpty ? null : full,
      searchText: computedSearch.isEmpty ? null : computedSearch,

      createdAt: createdAt,

      // ✅ new fields
      updatedAt: updatedAt,
      sourceType: sourceType,
      youtubeMetaId: youtubeMetaId,
    );
  }

  // ==========================
  // Audio packing
  // ==========================

  static Future<String?> _maybeAddAudioToArchive(
    Archive archive,
    String uid,
    String? audioPath, {
    required String suffix, // '_orig' or '_enh'
  }) async {
    if (audioPath == null) return null;
    final path = audioPath.trim();
    if (path.isEmpty) return null;

    final f = File(path);
    if (!await f.exists()) return null;

    final ext = p.extension(path).toLowerCase();
    final safeExt = ext.isEmpty ? '.wav' : ext;

    final bytes = await f.readAsBytes();

    // ✅ unique name inside zip so both can coexist
    final rel = 'audio/$uid$suffix$safeExt';

    archive.addFile(ArchiveFile(rel, bytes.length, bytes));
    return rel;
  }

  static String? _restoreAudioFile({
    required Map<String, ArchiveFile> fileByName,
    required String audioRel,
    required Directory audioDir,
    required String outBaseName, // e.g. '${uid}_orig' or '${uid}_enh'
  }) {
    final af = fileByName[audioRel];
    if (af == null) return null;
    if (af.content is! List<int>) return null;

    final bytes = af.content as List<int>;
    final ext = p.extension(audioRel);
    final safeExt = ext.isEmpty ? '.wav' : ext;

    final outPath = p.join(audioDir.path, '$outBaseName$safeExt');

    File(outPath).writeAsBytesSync(bytes, flush: true);
    return outPath;
  }
}
