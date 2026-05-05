import 'package:flutter/material.dart';

import '../ui/glass/glass_button.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_tokens.dart';
import 'document_export_service.dart';

Future<void> showDocumentExportSheet({
  required BuildContext context,
  required String title,
  required Future<void> Function(DocumentExportFormat format) onExport,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      var selected = DocumentExportFormat.txt;
      var busy = false;

      return StatefulBuilder(
        builder: (context, setState) {
          final fg = GlassTokens.fg(context, alpha: 0.92);
          final muted = GlassTokens.muted(context, alpha: 0.74);

          Future<void> handleExport() async {
            if (busy) return;
            setState(() => busy = true);
            try {
              await onExport(selected);
              if (sheetContext.mounted) {
                Navigator.of(sheetContext).pop();
              }
            } finally {
              if (sheetContext.mounted) {
                setState(() => busy = false);
              }
            }
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: GlassCard(
              variant: GlassCardVariant.panel,
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Choose a format and export the file.',
                    style: TextStyle(
                      color: muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: DocumentExportFormat.values.map((format) {
                      final active = selected == format;
                      return ChoiceChip(
                        selected: active,
                        label: Text(format.label),
                        onSelected: busy
                            ? null
                            : (_) => setState(() => selected = format),
                        selectedColor: Colors.white,
                        backgroundColor: Colors.white.withValues(alpha: 0.08),
                        labelStyle: TextStyle(
                          color: active ? Colors.black : fg,
                          fontWeight: FontWeight.w800,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: active ? 0 : 0.14),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: GlassButton(
                          kind: GlassButtonKind.secondary,
                          label: 'Cancel',
                          onPressed: busy ? null : () => Navigator.of(sheetContext).pop(),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: GlassButton(
                          kind: GlassButtonKind.primary,
                          label: busy ? 'Exporting…' : 'Export',
                          icon: Icons.download_rounded,
                          loading: busy,
                          onPressed: busy ? null : handleExport,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
