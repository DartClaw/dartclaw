import 'dart:convert';

import 'package:shelf/shelf.dart';

Response jsonResponse(int status, Object body) {
  return Response(status, body: jsonEncode(body), headers: {'content-type': 'application/json; charset=utf-8'});
}

Response errorResponse(int status, String code, String message, [Map<String, dynamic>? details]) {
  final error = <String, dynamic>{'code': code, 'message': message};
  if (details != null) error['details'] = details;
  return jsonResponse(status, {'error': error});
}

/// Reads and parses the request body as a JSON object.
///
/// Returns a record with either a parsed [value] or an [error] response
/// suitable for immediate return from a route handler.
Future<({Map<String, dynamic>? value, Response? error})> readJsonObject(Request request) async {
  try {
    final body = await request.readAsString();
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

/// Returns the trimmed string value if [value] is a non-null [String],
/// otherwise returns `null`.
String? trimmedStringOrNull(Object? value) {
  if (value is! String) return null;
  return value.trim();
}
