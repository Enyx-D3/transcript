import 'package:flutter/material.dart';

Future<bool> showConfirmDeleteDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmText = 'Delete',
  String cancelText = 'Cancel',
}) async {
  final res = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(cancelText),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
          ),
          child: Text(confirmText),
        ),
      ],
    ),
  );

  return res ?? false;
}
