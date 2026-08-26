import 'dart:convert';
import 'package:http/http.dart' as http;
import '../auth/user_identity_helper.dart';

class TranscriptMailService {
  final String baseUrl;
  final String? authToken; // optional

  const TranscriptMailService({required this.baseUrl, this.authToken});

  Future<void> sendTxtAttachment({
    required String txt, // attachment content (whatever you want)
    String? filename, // attachment filename
    Map<String, dynamic>? meta,
  }) async {
    final uri = Uri.parse('$baseUrl/.netlify/functions/send-transcript-txt');

    final ident = UserIdentityHelper.getCurrent();
    final toEmail = ident.email;

    if (toEmail == null || toEmail.trim().isEmpty) {
      throw Exception('No signed-in email found.');
    }

    final body = <String, dynamic>{
      'to_email': toEmail,
      'txt': txt,
      if (filename != null) 'filename': filename,
      if (meta != null) 'meta': meta,
    };

    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (authToken != null) 'X-Auth': authToken!,
    };

    final res = await http.post(uri, headers: headers, body: jsonEncode(body));

    if (res.statusCode != 200) {
      throw Exception('Send failed ${res.statusCode}: ${res.body}');
    }
  }
}
