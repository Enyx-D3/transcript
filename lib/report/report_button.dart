import 'package:flutter/material.dart';

import 'report_dialog.dart';
import 'report_service.dart';

class ReportButton extends StatelessWidget {
  const ReportButton({
    super.key,
    required this.reportService,
    required this.responseText,
    this.meta,
    this.iconSize = 18,
    this.tooltip = 'Report',
  });

  final ReportService reportService;
  final String responseText;
  final Map<String, dynamic>? meta;

  final double iconSize;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      iconSize: iconSize,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      icon: const Icon(Icons.flag_outlined),
      onPressed: () async {
        await showReportDialog(
          outerContext: context,
          responseText: responseText,
          meta: meta,
          sendReport:
              ({
                required String reason,
                required String note,
                required String response,
                Map<String, dynamic>? meta,
              }) {
                return reportService.sendReport(
                  reason: reason,
                  note: note,
                  response: response,
                  meta: meta,
                );
              },
        );
      },
    );
  }
}
