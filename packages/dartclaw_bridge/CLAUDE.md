# Package Rules — `dartclaw_bridge`

**Role**: The framed stdio bridge contract shared by the DartClaw host and the executable that runs inside a
`network:none` agent container. One package holds both halves so the wire format cannot skew between them.

## Architecture
- `lib/src/bridge_protocol.dart` — the wire contract: `bridgeProtocolVersion`, `BridgeSurface`, `BridgeFrameType`
  (numeric codes are the contract — never renumber), `BridgeFrame`, `BridgeLimits`, `BridgeProtocolException`.
- `lib/src/bridge_codec.dart` — `encodeBridgeFrame` plus `BridgeFrameReader`, an incremental parser tolerant of
  arbitrary chunk boundaries that rejects an over-long declared length before allocating.
- `lib/src/bridge_runner.dart` — `BridgeRunner`, the in-container half: a bounded loopback HTTP/1.1 listener that
  multiplexes over one stdio pipe.
- `bin/dartclaw_bridge.dart` — the executable the host cross-compiles for Linux and delivers into the container.

## Boundaries
- **Zero runtime dependencies, `dart:` libraries only.** The binary is cross-compiled with `dart compile exe`
  (`dev/tools/build_bridge.sh`) and must stay small and hook-free. Adding any dependency — including a workspace
  package — breaks that and is not a judgement call. `dev/fitness/test/bridge_package_deps_test.dart` enforces the
  exact package shape required by [ADR-051](../../dev/adrs/051-container-bridge-binary-packaging.md).
- The host side (`dartclaw_runtime` `lib/src/container/gateway/`) consumes this package's protocol and codec. The
  reverse direction does not exist: nothing here may know about sessions, providers, credentials, or policy.

## Conventions
- The bridge parses HTTP only far enough to produce frames. It never chooses an upstream, injects a credential, or
  interprets a body — the host binds destination and policy to the pipe. Keep it that way; a "small convenience" here
  moves authority into the container.
- Frames are length-prefixed (`uint32` payload length) with a fixed 7-byte header (type, request ID, metadata length),
  JSON metadata, then body bytes. Request ID `0` addresses the pipe itself.
- Every write flushes: the OS pipe is the backpressure boundary.
- Bump `bridgeProtocolVersion` on any layout or handshake change. The handshake fails closed on mismatch, so a stale
  bridge binary surfaces as a refused surface rather than corrupt traffic.

## Testing
- `test/bridge_codec_test.dart` covers framing: fragmented reads, byte-exact round-trips, and every rejected bound.
- `test/bridge_runner_test.dart` drives a real `BridgeRunner` over in-memory pipes with a real loopback HTTP client —
  no Docker. Use `IOSink(controller.sink)` for the host-output side.

## Key files
- `lib/src/bridge_protocol.dart` — the contract both sides compile against.
- `bin/dartclaw_bridge.dart` — container entry point (`--surface=`, `--port=`).
