import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

enum DocumentExportFormat { txt, doc, pdf }

extension DocumentExportFormatX on DocumentExportFormat {
  String get label => switch (this) {
    DocumentExportFormat.txt => 'TXT',
    DocumentExportFormat.doc => 'DOC',
    DocumentExportFormat.pdf => 'PDF',
  };

  String get extension => switch (this) {
    DocumentExportFormat.txt => 'txt',
    DocumentExportFormat.doc => 'doc',
    DocumentExportFormat.pdf => 'pdf',
  };

  String get mimeType => switch (this) {
    DocumentExportFormat.txt => 'text/plain',
    DocumentExportFormat.doc => 'application/msword',
    DocumentExportFormat.pdf => 'application/pdf',
  };
}

class DocumentExportService {
  DocumentExportService._();

  static pw.Font? _regularFont;
  static pw.Font? _boldFont;

  static Future<void> shareDocument({
    required String title,
    required String content,
    required String documentLabel,
    required DocumentExportFormat format,
  }) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      throw const DocumentExportException('Nothing to export yet.');
    }

    final file = await _createDocument(
      title: title,
      content: trimmed,
      documentLabel: documentLabel,
      format: format,
    );

    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(
            file.path,
            mimeType: format.mimeType,
            name: file.uri.pathSegments.last,
          ),
        ],
        subject: title,
        text: '$documentLabel attached.',
      ),
    );
  }

  static Future<File> _createDocument({
    required String title,
    required String content,
    required String documentLabel,
    required DocumentExportFormat format,
  }) async {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final safeName = _sanitizeFileName(title);
    final file = File('${dir.path}/$safeName-$stamp.${format.extension}');

    switch (format) {
      case DocumentExportFormat.txt:
        await file.writeAsString(
          _buildPlainText(
            title: title,
            content: content,
            documentLabel: documentLabel,
          ),
          flush: true,
        );
        return file;
      case DocumentExportFormat.doc:
        await file.writeAsString(
          _buildDocHtml(
            title: title,
            content: content,
            documentLabel: documentLabel,
          ),
          flush: true,
        );
        return file;
      case DocumentExportFormat.pdf:
        final regularFont = await _loadRegularFont();
        final boldFont = await _loadBoldFont();
        final doc = pw.Document();
        doc.addPage(
          pw.MultiPage(
            pageFormat: PdfPageFormat.a4,
            margin: const pw.EdgeInsets.all(32),
            theme: pw.ThemeData.withFont(
              base: regularFont,
              bold: boldFont,
              icons: regularFont,
            ),
            build: (_) => [
              pw.Text(title, style: pw.TextStyle(fontSize: 22, font: boldFont)),
              pw.SizedBox(height: 8),
              pw.Text(
                documentLabel,
                style: pw.TextStyle(
                  fontSize: 11,
                  color: PdfColors.grey700,
                  font: regularFont,
                ),
              ),
              pw.SizedBox(height: 18),
              ..._buildPdfContentWidgets(
                content: content,
                regularFont: regularFont,
              ),
            ],
          ),
        );
        await file.writeAsBytes(await doc.save(), flush: true);
        return file;
    }
  }

  static String _buildPlainText({
    required String title,
    required String content,
    required String documentLabel,
  }) {
    final buf = StringBuffer()
      ..writeln(title)
      ..writeln(documentLabel)
      ..writeln()
      ..write(content);
    return buf.toString();
  }

  static String _buildDocHtml({
    required String title,
    required String content,
    required String documentLabel,
  }) {
    final escapedTitle = const HtmlEscape().convert(title);
    final escapedLabel = const HtmlEscape().convert(documentLabel);
    final escapedBody = const HtmlEscape()
        .convert(content)
        .replaceAll('\n', '<br>');

    return '''
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <title>$escapedTitle</title>
  </head>
  <body style="font-family: Arial, sans-serif; padding: 24px;">
    <h1 style="margin: 0 0 8px;">$escapedTitle</h1>
    <p style="margin: 0 0 18px; color: #666666;">$escapedLabel</p>
    <div style="font-size: 14px; line-height: 1.5;">$escapedBody</div>
  </body>
</html>
''';
  }

  static String _sanitizeFileName(String raw) {
    final normalized = raw.trim().isEmpty ? 'transcript-export' : raw.trim();
    return normalized
        .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static List<pw.Widget> _buildPdfContentWidgets({
    required String content,
    required pw.Font regularFont,
  }) {
    final lines = content.replaceAll('\r\n', '\n').split('\n');
    final widgets = <pw.Widget>[];

    for (final line in lines) {
      if (line.trim().isEmpty) {
        widgets.add(pw.SizedBox(height: 10));
        continue;
      }

      widgets.add(
        pw.Text(
          line,
          style: pw.TextStyle(fontSize: 12, lineSpacing: 3, font: regularFont),
        ),
      );
      widgets.add(pw.SizedBox(height: 6));
    }

    if (widgets.isEmpty) {
      widgets.add(
        pw.Text(
          content,
          style: pw.TextStyle(fontSize: 12, lineSpacing: 3, font: regularFont),
        ),
      );
    }

    return widgets;
  }

  static Future<pw.Font> _loadRegularFont() async {
    final existing = _regularFont;
    if (existing != null) return existing;

    final data = await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
    final font = pw.Font.ttf(data);
    _regularFont = font;
    return font;
  }

  static Future<pw.Font> _loadBoldFont() async {
    final existing = _boldFont;
    if (existing != null) return existing;

    final data = await rootBundle.load('assets/fonts/NotoSans-Bold.ttf');
    final font = pw.Font.ttf(data);
    _boldFont = font;
    return font;
  }
}

class DocumentExportException implements Exception {
  final String message;
  const DocumentExportException(this.message);

  @override
  String toString() => message;
}
