// lib/speaker_enroll_sheet.dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'speaker_embedding.dart';
import 'speaker_memory.dart';

/// Opens a bottom sheet to rename/enroll a speaker id (e.g. "S1") to a friendly name.
/// It extracts an embedding from [wavPath] between [startSec]..[endSec] and stores it.
/// Returns the chosen display name (e.g. "Alex") or null if cancelled.
Future<String?> showSpeakerEnrollSheet({
  required BuildContext context,
  required String speakerId,
  required String wavPath,
  required double startSec,
  required double endSec,
  required String embeddingOnnxPath, // path to nemo_en_titanet_small.onnx you already download at boot
}) async {
  final controller = TextEditingController(text: '');
  final formKey = GlobalKey<FormState>();
  bool enrolling = false;

  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF16161D),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (ctx) {
      Future<void> onSave() async {
        if (!formKey.currentState!.validate()) return;
        enrolling = true;
        (ctx as Element).markNeedsBuild();

        try {
          final embedder = await SpeakerEmbedder.instance(embeddingOnnxPath);
          final v = await embedder.embedFromWav(wavPath, startSec: startSec, endSec: endSec);
          final memory = await SpeakerMemory.instance();
          await  memory.enrollAppend(name: controller.text.trim(), embedding: v);
          Navigator.of(ctx).pop(controller.text.trim());
        } catch (e) {
          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Enroll failed: $e')));
        } finally {
          enrolling = false;
          (ctx).markNeedsBuild();
        }
      }

      final bottom = MediaQuery.of(ctx).viewInsets.bottom;
      return Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.person_add_alt_1_rounded),
                const SizedBox(width: 8),
                Text('Rename $speakerId', style: Theme.of(ctx).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Form(
              key: formKey,
              child: TextFormField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'Display name',
                  hintText: 'e.g. Alex',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Please enter a name' : null,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  onPressed: enrolling ? null : onSave,
                  child: enrolling ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                   : const Text('Save'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: enrolling ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
