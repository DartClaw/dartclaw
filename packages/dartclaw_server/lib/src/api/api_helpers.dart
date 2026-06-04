import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

const defaultMaxJsonBodyBytes = 256 * 1024;

/// Builds a shelf [Response] with JSON-encoded [body] and the JSON content type.
Response jsonResponse(int status, Object body) {
  return Response(status, body: jsonEncode(body), headers: {'content-type': 'application/json; charset=utf-8'});
}

/// Builds a shelf error [Response] with a structured error envelope.
Response errorResponse(int status, String code, String message, [Map<String, dynamic>? details]) {
  final error = <String, dynamic>{'code': code, 'message': message};
  if (details != null) error['details'] = details;
  return jsonResponse(status, {'error': error});
}

/// Reads and parses the request body as a JSON object.
///
/// Returns a record with either a parsed [value] or an [error] response
/// suitable for immediate return from a route handler.
Future<({Map<String, dynamic>? value, Response? error})> readJsonObject(
  Request request, {
  int maxBytes = defaultMaxJsonBodyBytes,
}) async {
  try {
    final bodyResult = await readRequestBody(request, maxBytes: maxBytes);
    if (bodyResult.error != null) {
      return (value: null, error: bodyResult.error);
    }
    final body = bodyResult.body!;
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      return (value: null, error: errorResponse(400, 'INVALID_INPUT', 'JSON body must be an object'));
    }
    return (value: Map<String, dynamic>.from(decoded), error: null);
  } on FormatException {
    return (value: null, error: errorResponse(400, 'INVALID_INPUT', 'Invalid JSON body'));
  } on TypeError {
    return (value: null, error: errorResponse(400, 'INVALID_INPUT', 'Invalid JSON structure'));
  }
}

Future<({String? body, Response? error})> readRequestBody(Request request, {required int maxBytes}) async {
  final contentLength = request.contentLength;
  if (contentLength != null && contentLength > maxBytes) {
    return (body: null, error: errorResponse(413, 'REQUEST_TOO_LARGE', 'request body is too large'));
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in request.read()) {
    if (bytes.length + chunk.length > maxBytes) {
      return (body: null, error: errorResponse(413, 'REQUEST_TOO_LARGE', 'request body is too large'));
    }
    bytes.add(chunk);
  }
  try {
    return (body: utf8.decode(bytes.takeBytes()), error: null);
  } on FormatException {
    return (body: null, error: errorResponse(400, 'INVALID_INPUT', 'request body must be valid UTF-8'));
  }
}

/// Returns the trimmed string value if [value] is a non-null [String],
/// otherwise returns `null`.
String? trimmedStringOrNull(Object? value) {
  if (value is! String) return null;
  return value.trim();
}
