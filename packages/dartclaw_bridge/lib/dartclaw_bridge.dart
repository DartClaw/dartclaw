/// Framed stdio bridge protocol shared by the DartClaw host and the
/// in-container bridge executable.
///
/// Both sides are compiled from this package, so the wire contract cannot skew
/// between them within a release. The handshake still verifies
/// [bridgeProtocolVersion] so a mismatched pair fails closed instead of
/// misinterpreting frames.
library;

export 'src/bridge_codec.dart' show BridgeFrameReader, encodeBridgeFrame;
export 'src/bridge_protocol.dart'
    show
        BridgeFrame,
        BridgeFrameType,
        BridgeLimits,
        BridgeProtocolException,
        BridgeSurface,
        bridgeProtocolVersion,
        frameHeaderBytes,
        frameLengthPrefixBytes,
        intOrDefault,
        stringOrDefault;
export 'src/bridge_runner.dart' show BridgeRunner;
