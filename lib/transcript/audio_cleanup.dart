// lib/transcript/audio_cleanup.dart
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../objectbox/objectbox_store.dart';

// ✅ Use your existing key (matches Settings page)
const String _kPrefDeleteAudioAfter = 'pref_delete_audio_after_transcription';

Future<void> deleteTranscriptAudioIfUserEnabled(int transcriptId) async {
  final sp = await SharedPreferences.getInstance();
  final enabled = sp.getBool(_kPrefDeleteAudioAfter) ?? false;

  debugPrint('[AUDIO][CLEANUP] enabled=$enabled id=$transcriptId');

  if (!enabled) return;

  final obx = ObjectBox.I;
  final t = obx.transcripts.get(transcriptId);
  if (t == null) {
    debugPrint('[AUDIO][CLEANUP] transcript not found id=$transcriptId');
    return;
  }

  final original = t.audioPath;
  final enhanced = t.processedAudioPath;

  debugPrint('[AUDIO][CLEANUP] original=$original');
  debugPrint('[AUDIO][CLEANUP] enhanced=$enhanced');

  Future<void> safeDelete(String? path, String label) async {
    if (path == null) {
      debugPrint('[AUDIO][CLEANUP] $label: null');
      return;
    }

    final p = path.trim();
    if (p.isEmpty) {
      debugPrint('[AUDIO][CLEANUP] $label: empty');
      return;
    }

    try {
      final f = File(p);
      final exists = await f.exists();
      debugPrint('[AUDIO][CLEANUP] $label exists=$exists path=$p');

      if (exists) {
        await f.delete();
        debugPrint('[AUDIO][CLEANUP] $label deleted path=$p');
      }
    } catch (e) {
      debugPrint('[AUDIO][CLEANUP] $label delete failed path=$p err=$e');
    }
  }

  await safeDelete(original, 'original');
  await safeDelete(enhanced, 'enhanced');

  // ✅ Clear DB paths so UI won't try to play missing files
  t.audioPath = null;
  t.processedAudioPath = null;
  obx.transcripts.put(t);

  debugPrint('[AUDIO][CLEANUP] DB cleared audio paths id=$transcriptId');
}
