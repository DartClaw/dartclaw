import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:shelf/shelf.dart';

// These shelf-typed helpers cannot live in the lower tiers without adding an HTTP framework dependency there.
const maxWebhookPayloadBytes = 1024 * 1024;
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
  final contentLength = request.contentLength;
  if (contentLength != null && contentLength > maxBytes) {
    return (value: null, error: errorResponse(413, 'REQUEST_TOO_LARGE', 'request body is too large'));
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in request.read()) {
    if (bytes.length + chunk.length > maxBytes) {
      return (value: null, error: errorResponse(413, 'REQUEST_TOO_LARGE', 'request body is too large'));
    }
    bytes.add(chunk);
  }
  final String body;
  try {
    body = utf8.decode(bytes.takeBytes());
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
  final contentLength = request.contentLength;
  if (contentLength != null && contentLength > limit) return null;

  final bytes = <int>[];
  await for (final chunk in request.read()) {
    bytes.addAll(chunk);
    if (bytes.length > limit) return null;
  }
  return utf8.decode(bytes);
}

String? requestRemoteKey(Request request, {List<String> trustedProxies = const []}) {
  final connectionInfo = request.context['shelf.io.connection_info'];
  if (connectionInfo is HttpConnectionInfo) {
    final socketAddress = connectionInfo.remoteAddress.address;
    if (trustedProxies.isNotEmpty && trustedProxies.contains(socketAddress)) {
      final forwardedFor = request.headers['x-forwarded-for'];
      final forwardedClient = forwardedFor?.split(',').first.trim();
      if (forwardedClient != null && forwardedClient.isNotEmpty) {
        return forwardedClient;
      }
    }
    return socketAddress;
  }

  return null;
}

void fireFailedAuthEvent(
  EventBus? eventBus,
  Request request, {
  required String source,
  required String reason,
  bool limited = false,
  List<String> trustedProxies = const [],
}) {
  eventBus?.fire(
    FailedAuthEvent(
      source: source,
      path: '/${request.url.path}',
      reason: reason,
      remoteKey: requestRemoteKey(request, trustedProxies: trustedProxies),
      limited: limited,
      timestamp: DateTime.now(),
    ),
  );
}
