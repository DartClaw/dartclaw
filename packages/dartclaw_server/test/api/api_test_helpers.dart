import 'dart:convert';

import 'package:shelf/shelf.dart';

/// Extracts the `error.code` field from a JSON error response.
Future<String> errorCode(Response res) async {
  final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
  return (body['error'] as Map<String, dynamic>)['code'] as String;
}

/// Decodes a JSON string as a [Map].
Map<String, dynamic> decodeObject(String body) {
  return jsonDecode(body) as Map<String, dynamic>;
}

/// Decodes a JSON string as a [List].
List<dynamic> decodeList(String body) {
  return jsonDecode(body) as List<dynamic>;
}

/// Creates a [Request] with a JSON body and content-type header.
Request jsonRequest(String method, String path, [Map<String, dynamic>? body]) {
  return Request(
    method,
    Uri.parse('http://localhost$path'),
    body: body == null ? null : jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );
}
