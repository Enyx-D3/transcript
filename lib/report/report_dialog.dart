import 'package:flutter/material.dart';

import '../common/app_flushbar.dart';

Future<bool?> showReportDialog({
  required BuildContext outerContext,
  required String responseText,
  required Future<void> Function({
    required String reason,
    required String note,
    required String response,
    Map<String, dynamic>? meta,
  })
  sendReport,
  Map<String, dynamic>? meta,
}) {
  final reasons = <String>[
    'Incorrect / misleading',
    'Offensive / unsafe',
    'Spam / irrelevant',
    'Other',
  ];

  String selected = reasons.first;
  final noteController = TextEditingController();
  bool sending = false;

  return showDialog<bool>(
    context: outerContext,
    barrierDismissible: !sending,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            backgroundColor: Colors.black87,
            title: const Text('Report response',style: TextStyle(color: Colors.white,fontSize: 16),),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...reasons.map(
                    (r) => RadioListTile<String>(
                      activeColor: Color(0xFFff8143),
                      dense: true,
                      title: Text(r),
                      value: r,
                      groupValue: selected,
                      onChanged: (v) {
                        if (sending) return;
                        setState(() => selected = v ?? selected);
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: noteController,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: 'Additional details (optional)',
                      border: const OutlineInputBorder(),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                          color: Colors.white,
                          width: 2.0,
                        ),
                      ),
                    ),
                    enabled: !sending,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: sending ? null : () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel',style: TextStyle(color: Colors.white),),
              ),
              FilledButton.icon(
                onPressed: sending
                    ? null
                    : () async {
                        setState(() => sending = true);
                        try {
                          await sendReport(
                            reason: selected,
                            note: noteController.text.trim(),
                            response: responseText,
                            meta: meta,
                          );

                          if (!ctx.mounted) return;
                          Navigator.of(ctx).pop(true);

                          await AppFlushbar.success(
                            outerContext,
                            message: 'We have received your complaint',
                          );
                        } catch (e) {
                          debugPrint(e.toString());
                          setState(() => sending = false);
                          if (!ctx.mounted) return;

                          await AppFlushbar.error(
                            outerContext,
                            message: 'Failed to report',
                          );
                        }
                      },
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                ),
                icon: const Icon(Icons.flag_outlined),
                label: const Text('Send'),
              ),
            ],
          );
        },
      );
    },
  );
}
