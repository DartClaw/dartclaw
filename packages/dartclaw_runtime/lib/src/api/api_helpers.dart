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
/// [maxBytes] caps the read: a larger body returns the shared
/// `413 REQUEST_TOO_LARGE` envelope without buffering the rest. Rejections
/// otherwise answer `400 INVALID_INPUT` with a per-mode default message; a
/// caller that publishes one message for every malformed body passes
/// [invalidMessage] instead. With [requireNonEmpty] an empty JSON object is
/// rejected too. An empty body is a decode failure – a route that gives it a
/// different meaning reads through [readRequestBody] and decides before
/// calling [decodeJsonObject].
Future<({Map<String, dynamic>? value, Response? error})> readJsonObject(
  Request request, {
  int maxBytes = defaultMaxJsonBodyBytes,
  String? invalidMessage,
  bool requireNonEmpty = false,
}) async {
  final bodyResult = await readRequestBody(request, maxBytes: maxBytes);
  if (bodyResult.error != null) {
    return (value: null, error: bodyResult.error);
  }
  return decodeJsonObject(bodyResult.body!, invalidMessage: invalidMessage, requireNonEmpty: requireNonEmpty);
}

/// Decodes [body] as a JSON object.
///
/// The decode half of [readJsonObject], for routes that must inspect the raw
/// body first. [invalidMessage] and [requireNonEmpty] behave as documented
/// there.
({Map<String, dynamic>? value, Response? error}) decodeJsonObject(
  String body, {
  String? invalidMessage,
  bool requireNonEmpty = false,
}) {
  Response reject(String defaultMessage) => errorResponse(400, 'INVALID_INPUT', invalidMessage ?? defaultMessage);
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      return (value: null, error: reject('JSON body must be an object'));
    }
    final value = Map<String, dynamic>.from(decoded);
    if (requireNonEmpty && value.isEmpty) {
      return (value: null, error: reject('JSON body must not be empty'));
    }
    return (value: value, error: null);
  } on FormatException {
    return (value: null, error: reject('Invalid JSON body'));
  } on TypeError {
    return (value: null, error: reject('Invalid JSON structure'));
  }
}

/// Reads the request body as a string, refusing anything past [maxBytes].
///
/// The one raw body read declared in `lib/src/api/`: every JSON route reaches it
/// directly or through [readJsonObject], so a new route cannot inherit an
/// unbounded read. Decodes UTF-8 unconditionally, ignoring any `charset`
/// parameter, and answers `400 INVALID_INPUT` when the bytes are not UTF-8.
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

/// Reads an `application/x-www-form-urlencoded` request within [maxBytes].
///
/// Repeated field names retain every value in submission order. Malformed
/// percent escapes are refused through the shared JSON error envelope.
Future<({Map<String, List<String>> fields, Response? error})> readFormFields(
  Request request, {
  required int maxBytes,
}) async {
  final mediaType = (request.headers['content-type'] ?? '').split(';').first.trim().toLowerCase();
  if (mediaType != 'application/x-www-form-urlencoded') {
    return (
      fields: const <String, List<String>>{},
      error: errorResponse(415, 'UNSUPPORTED_MEDIA_TYPE', 'Unsupported content type'),
    );
  }
  final bodyResult = await readRequestBody(request, maxBytes: maxBytes);
  if (bodyResult.error != null) {
    return (fields: const <String, List<String>>{}, error: bodyResult.error);
  }

  try {
    final fields = <String, List<String>>{};
    for (final pair in bodyResult.body!.split('&')) {
      if (pair.isEmpty) continue;
      final separator = pair.indexOf('=');
      final rawName = separator < 0 ? pair : pair.substring(0, separator);
      final rawValue = separator < 0 ? '' : pair.substring(separator + 1);
      final name = Uri.decodeQueryComponent(rawName.replaceAll('+', ' '));
      final value = Uri.decodeQueryComponent(rawValue.replaceAll('+', ' '));
      (fields[name] ??= []).add(value);
    }
    return (fields: fields, error: null);
  } on ArgumentError {
    return (fields: const <String, List<String>>{}, error: errorResponse(400, 'INVALID_INPUT', 'Invalid form body'));
  }
}

/// Returns the trimmed string value if [value] is a non-null [String],
/// otherwise returns `null`.
String? trimmedStringOrNull(Object? value) {
  if (value is! String) return null;
  return value.trim();
}

/// Percent-decodes a shelf path segment captured by `shelf_router`.
///
/// `shelf_router` exposes the matched `<name>`/`<id>` segment still
/// percent-encoded, so identifiers the client encodes (`&`, `'`, `<`, `>`,
/// space, …) must be decoded before matching against stored job/task names.
/// Falls back to the raw segment when it is not valid percent-encoding.
String decodePathSegment(String value) {
  try {
    return Uri.decodeComponent(value);
  } on ArgumentError {
    return value;
  }
}
