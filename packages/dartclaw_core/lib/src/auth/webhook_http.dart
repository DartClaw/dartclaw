import 'dart:typed_data';

import '../events/dartclaw_event.dart';
import '../events/event_bus.dart';

/// Maximum webhook payload size (1 MiB). Rejects oversized POST bodies on
/// unauthenticated webhook endpoints to prevent OOM attacks.
const maxWebhookPayloadBytes = 1024 * 1024;

/// Reads [body] into memory, returning `null` once more than [limit] bytes
/// are declared or received.
///
/// A [contentLength] over [limit] is refused before the stream is listened to;
/// otherwise the stream is cancelled at the first chunk that crosses [limit],
/// so a body with a missing or understated length is still bounded. The bytes
/// are returned exactly as received: decoding is the caller's concern.
Future<Uint8List?> readBoundedBytes(Stream<List<int>> body, {int? contentLength, required int limit}) async {
  if (contentLength != null && contentLength > limit) return null;

  final bytes = BytesBuilder(copy: false);
  await for (final chunk in body) {
    if (bytes.length + chunk.length > limit) return null;
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

/// Resolves the remote key for a request from its transport [peerAddress].
///
/// The first `X-Forwarded-For` entry in [forwardedFor] is used only when the
/// peer is one of [trustedProxies] and the entry is non-blank; otherwise the
/// peer itself is the key. Returns `null` when there is no peer.
String? resolveRemoteKey({String? peerAddress, String? forwardedFor, List<String> trustedProxies = const []}) {
  if (peerAddress == null) return null;
  if (trustedProxies.contains(peerAddress)) {
    final forwardedClient = forwardedFor?.split(',').first.trim();
    if (forwardedClient != null && forwardedClient.isNotEmpty) return forwardedClient;
  }
  return peerAddress;
}

/// Publishes a [FailedAuthEvent] to [eventBus]; a `null` bus drops it.
void publishFailedAuthEvent(
  EventBus? eventBus, {
  required String source,
  required String path,
  required String reason,
  String? remoteKey,
  bool limited = false,
}) {
  eventBus?.fire(
    FailedAuthEvent(
      source: source,
      path: path,
      reason: reason,
      remoteKey: remoteKey,
      limited: limited,
      timestamp: DateTime.now(),
    ),
  );
}
