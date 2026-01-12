import 'dart:convert';
import 'package:http/http.dart' as http;

class ReportService {
  final String baseUrl;
  final String? authToken; // optional

  const ReportService({
    required this.baseUrl,
    this.authToken,
  });

  Future<void> sendReport({
    required String reason,
    required String note,
    required String response, // text (for now)
    String? responseMime,
    String? responseFilename,
    Map<String, dynamic>? meta, // ✅ add context
  }) async {
    final uri = Uri.parse('$baseUrl/.netlify/functions/send-report-transcript');

    final body = <String, dynamic>{
      'reason': reason,
      'note': note,
      'response': response,
      if (responseMime != null) 'responseMime': responseMime,
      if (responseFilename != null) 'responseFilename': responseFilename,
      if (meta != null) 'meta': meta, // ✅ include meta
    };

    final headers = {
      'Content-Type': 'application/json',
      if (authToken != null) 'X-Auth': authToken!,
    };

    final res = await http.post(
      uri,
      headers: headers,
      body: jsonEncode(body),
    );

    if (res.statusCode != 200) {
      throw Exception('Send failed ${res.statusCode}: ${res.body}');
    }
  }
}
