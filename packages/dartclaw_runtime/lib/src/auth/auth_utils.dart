import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:shelf/shelf.dart';

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
