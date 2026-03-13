import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:shelf/shelf.dart';

/// Maximum webhook payload size (1 MiB). Rejects oversized POST bodies
/// on unauthenticated webhook endpoints to prevent OOM attacks.
const maxWebhookPayloadBytes = 1024 * 1024;

/// Constant-time string comparison to prevent timing attacks on secrets.
///
/// Returns true only if [a] and [b] are equal, but takes the same amount
/// of time regardless of where (or whether) they differ — preventing
/// attackers from inferring correct characters via response-time analysis.
bool constantTimeEquals(String a, String b) {
  final aBytes = utf8.encode(a);
  final bBytes = utf8.encode(b);
  final maxLength = aBytes.length > bBytes.length ? aBytes.length : bBytes.length;
  final paddedA = List<int>.filled(maxLength, 0)..setRange(0, aBytes.length, aBytes);
  final paddedB = List<int>.filled(maxLength, 0)..setRange(0, bBytes.length, bBytes);

  var result = aBytes.length ^ bBytes.length;
  for (var i = 0; i < maxLength; i++) {
    result |= paddedA[i] ^ paddedB[i];
  }
  return result == 0;
}

/// Reads a request body up to [limit] bytes, returning `null` if exceeded.
///
/// Checks `Content-Length` header first for a fast 413 rejection path,
/// then caps the stream read for chunked/missing-header cases.
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
