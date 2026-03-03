/// DartClaw — Security-hardened AI agent runtime for Dart.
///
/// Wraps the official `claude` CLI binary via JSONL control protocol,
/// providing subprocess harness, guard chain, session management, and
/// multi-channel messaging — all in AOT-compiled Dart with zero npm.
///
/// **Status: Pre-alpha.** API is unstable and will change. This is an early
/// development release. See
/// [repository](https://github.com/tolo/dartclaw) for current status.
///
/// Core abstractions (available in future releases):
///
/// - **AgentHarness** — subprocess lifecycle, turn execution, event streaming
/// - **Guard / GuardChain** — security policy evaluation
/// - **Channel** — messaging interface (WhatsApp, Signal)
/// - **BridgeEvent** — sealed event hierarchy from the JSONL control protocol
library;
