import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:shelf/shelf.dart';

// These shelf-typed helpers cannot live in the lower tiers without adding an HTTP framework dependency there.
const defaultMaxJsonBodyBytes = 256 * 1024;

Response jsonResponse(int status, Object body) {
  return Response(status, body: jsonEncode(body), headers: {'content-type': 'application/json; charset=utf-8'});
}

Response errorResponse(int status, String code, String message, [Map<String, dynamic>? details]) {
  final error = <String, dynamic>{'code': code, 'message': message};
  if (details != null) error['details'] = details;
  return jsonResponse(status, {'error': error});
}

Future<({Map<String, dynamic>? value, Response? error})> readJsonObject(
  Request request, {
  int maxBytes = defaultMaxJsonBodyBytes,
  String? invalidMessage,
}) async {
  Response reject(String message) => errorResponse(400, 'INVALID_INPUT', invalidMessage ?? message);
  final bytes = await readBoundedBytes(request.read(), contentLength: request.contentLength, limit: maxBytes);
  if (bytes == null) {
    return (value: null, error: errorResponse(413, 'REQUEST_TOO_LARGE', 'request body is too large'));
  }
  final String body;
  try {
    body = utf8.decode(bytes);
  } on FormatException {
    return (value: null, error: errorResponse(400, 'INVALID_INPUT', 'request body must be valid UTF-8'));
  }
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return (value: null, error: reject('JSON body must be an object'));
    return (value: Map<String, dynamic>.from(decoded), error: null);
  } on FormatException {
    return (value: null, error: reject('Invalid JSON body'));
  } on TypeError {
    return (value: null, error: reject('Invalid JSON structure'));
  }
}

Future<String?> readBounded(Request request, int limit) async {
  final bytes = await readBoundedBytes(request.read(), contentLength: request.contentLength, limit: limit);
  return bytes == null ? null : utf8.decode(bytes);
}

void fireFailedAuthEvent(
  EventBus? eventBus,
  Request request, {
  required String source,
  required String reason,
  bool limited = false,
  List<String> trustedProxies = const [],
}) {
  final connectionInfo = request.context['shelf.io.connection_info'];
  publishFailedAuthEvent(
    eventBus,
    source: source,
    path: '/${request.url.path}',
    reason: reason,
    remoteKey: resolveRemoteKey(
      peerAddress: connectionInfo is HttpConnectionInfo ? connectionInfo.remoteAddress.address : null,
      forwardedFor: request.headers['x-forwarded-for'],
      trustedProxies: trustedProxies,
    ),
    limited: limited,
  );
}
