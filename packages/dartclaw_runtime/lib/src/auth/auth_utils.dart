import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:shelf/shelf.dart';

import 'auth_rate_limiter.dart';

/// Reads a request body up to [limit] bytes exactly as received, returning `null` if exceeded.
Future<Uint8List?> readBoundedRequestBytes(Request request, int limit) =>
    readBoundedBytes(request.read(), contentLength: request.contentLength, limit: limit);

/// Reads a request body up to [limit] bytes as UTF-8, returning `null` if exceeded.
Future<String?> readBounded(Request request, int limit) async {
  final bytes = await readBoundedRequestBytes(request, limit);
  return bytes == null ? null : utf8.decode(bytes);
}

/// Resolves the remote IP key for [request], honoring trusted-proxy `X-Forwarded-For` chains.
String? requestRemoteKey(Request request, {List<String> trustedProxies = const []}) {
  final connectionInfo = request.context['shelf.io.connection_info'];
  return resolveRemoteKey(
    peerAddress: connectionInfo is HttpConnectionInfo ? connectionInfo.remoteAddress.address : null,
    forwardedFor: request.headers['x-forwarded-for'],
    trustedProxies: trustedProxies,
  );
}

/// Counts a failed authentication of [request] against [rateLimiter], publishes the failed-auth event, and
/// answers the `429` the caller returns once the remote address has spent its budget, else `null`.
///
/// A request refused while already over budget is not counted again. [source] and [reason] name the surface and
/// the failure in the event.
Response? recordFailedAuth(
  Request request, {
  required String source,
  required String reason,
  AuthRateLimiter? rateLimiter,
  EventBus? eventBus,
  List<String> trustedProxies = const [],
}) {
  final remoteKey = requestRemoteKey(request, trustedProxies: trustedProxies) ?? 'unknown';
  final limited = rateLimiter?.shouldLimit(remoteKey) ?? false;
  if (!limited) rateLimiter?.recordFailure(remoteKey);
  fireFailedAuthEvent(
    eventBus,
    request,
    source: source,
    reason: reason,
    limited: limited,
    trustedProxies: trustedProxies,
  );
  if (!limited) return null;
  return Response(
    429,
    body: jsonEncode({'error': 'Too Many Requests', 'message': 'Too many failed authentication attempts'}),
    headers: {'content-type': 'application/json'},
  );
}

/// Publishes a `FailedAuthEvent` to [eventBus] describing [reason] and the originating request.
void fireFailedAuthEvent(
  EventBus? eventBus,
  Request request, {
  required String source,
  required String reason,
  bool limited = false,
  List<String> trustedProxies = const [],
}) {
  publishFailedAuthEvent(
    eventBus,
    source: source,
    path: '/${request.url.path}',
    reason: reason,
    remoteKey: requestRemoteKey(request, trustedProxies: trustedProxies),
    limited: limited,
  );
}
