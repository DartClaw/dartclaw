/// Wire contract for the host-to-container framed stdio bridge.
///
/// A pipe carries exactly one surface for exactly one container authority. The
/// surface is fixed by the host at pipe creation and confirmed in the
/// handshake; frames never select a surface, destination, or credential.
library;

/// Incremented whenever the frame layout or handshake changes.
///
/// Host and bridge ship from the same release, so a mismatch means a
/// mis-provisioned bridge binary — the surface fails closed.
const int bridgeProtocolVersion = 1;

/// The two independent host services a pipe can be bound to.
enum BridgeSurface {
  provider,
  mcp;

  static BridgeSurface? fromWire(String value) {
    for (final surface in BridgeSurface.values) {
      if (surface.name == value) return surface;
    }
    return null;
  }
}

/// Frame kinds. Codes are part of the wire contract — never renumber.
enum BridgeFrameType {
  /// Bridge → host, first frame on every pipe. Carries version and surface.
  handshake(0x01),

  /// Host → bridge, accepts the handshake.
  handshakeAck(0x02),

  /// Bridge → host, sent once the loopback listener is accepting connections.
  ready(0x03),

  /// Bridge → host. Metadata carries method, path, and headers.
  requestStart(0x10),

  /// Bridge → host. Body bytes for an open request.
  requestChunk(0x11),

  /// Bridge → host. No more request body.
  requestEnd(0x12),

  /// Host → bridge. Metadata carries status and headers.
  responseStart(0x20),

  /// Host → bridge. Body bytes for an open response.
  responseChunk(0x21),

  /// Host → bridge. Terminal success for a request ID.
  responseEnd(0x22),

  /// Either direction. Terminal failure; metadata carries `status` and
  /// `message`. Request ID 0 fails the whole pipe.
  failure(0x30),

  /// Either direction. Non-terminal for the peer's bookkeeping: the sender has
  /// abandoned the request ID.
  cancel(0x31);

  const BridgeFrameType(this.code);

  final int code;

  static BridgeFrameType? fromCode(int code) {
    for (final type in BridgeFrameType.values) {
      if (type.code == code) return type;
    }
    return null;
  }
}

/// Bounds applied to every pipe on both sides.
///
/// The frame reader rejects an oversized declared length before allocating, so
/// these caps also bound peak memory per pipe.
final class BridgeLimits {
  const BridgeLimits({
    // The metadata length travels in a uint16 header field, so 0xffff is the
    // hard ceiling: a larger value would wrap on encode and decode as a corrupt
    // frame instead of being rejected.
    this.maxMetadataBytes = 0xffff,
    this.maxBodyChunkBytes = 256 * 1024,
    this.maxRequestBytes = 8 * 1024 * 1024,
    this.maxResponseBytes = 64 * 1024 * 1024,
    this.maxInFlightRequests = 8,
    this.maxQueuedRequests = 16,
    this.idleTimeout = const Duration(minutes: 5),
    this.requestTimeout = const Duration(minutes: 10),
  });

  final int maxMetadataBytes;
  final int maxBodyChunkBytes;
  final int maxRequestBytes;
  final int maxResponseBytes;
  final int maxInFlightRequests;
  final int maxQueuedRequests;
  final Duration idleTimeout;
  final Duration requestTimeout;

  /// Largest payload a peer may declare, header included.
  int get maxPayloadBytes => frameHeaderBytes + maxMetadataBytes + maxBodyChunkBytes;

  static const BridgeLimits defaults = BridgeLimits();
}

/// Bytes preceding the metadata in a frame payload: type, request ID,
/// metadata length.
const int frameHeaderBytes = 1 + 4 + 2;

/// Bytes carrying the payload length that precedes every frame payload.
const int frameLengthPrefixBytes = 4;

/// A protocol violation. Always terminal for the pipe that produced it.
final class BridgeProtocolException implements Exception {
  const BridgeProtocolException(this.message);

  final String message;

  @override
  String toString() => 'BridgeProtocolException: $message';
}

/// Reads an integer frame-metadata value, falling back when the peer omitted or
/// mistyped it. Frame metadata is untrusted on both sides.
int intOrDefault(Object? value, int fallback) => value is int ? value : fallback;

/// Reads a non-empty string frame-metadata value, falling back otherwise.
String stringOrDefault(Object? value, String fallback) => value is String && value.isNotEmpty ? value : fallback;

/// One decoded frame.
final class BridgeFrame {
  const BridgeFrame({required this.type, this.requestId = 0, this.metadata = const {}, this.body = const []});

  final BridgeFrameType type;

  /// Multiplexing key. `0` addresses the pipe itself rather than a request.
  final int requestId;

  final Map<String, Object?> metadata;
  final List<int> body;

  @override
  String toString() => 'BridgeFrame(${type.name}, id=$requestId, meta=${metadata.length}, body=${body.length}B)';
}
