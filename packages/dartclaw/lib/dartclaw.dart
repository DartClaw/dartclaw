/// DartClaw — An experimental, security-conscious AI agent runtime built with Dart.
///
/// Wraps the official `claude` CLI binary via JSONL control protocol,
/// providing subprocess harness, guard chain, session management, and
/// multi-channel messaging — all in AOT-compiled Dart with zero npm.
///
/// **Status: Pre-alpha.** API is unstable and will change. This is an early
/// development release. See
/// [repository](https://github.com/tolo/dartclaw) for current status.
///
/// This umbrella package re-exports the full DartClaw SDK surface. For leaner
/// dependency graphs, import individual packages directly.
///
/// Core abstractions:
///
/// - **AgentHarness** — subprocess lifecycle, turn execution, event streaming
/// - **Guard / GuardChain** — security policy evaluation
/// - **Channel** — messaging interface primitives
/// - **BridgeEvent** — sealed event hierarchy from the JSONL control protocol
library;

export 'package:dartclaw_core/dartclaw_core.dart';
export 'package:dartclaw_storage/dartclaw_storage.dart';
export 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
export 'package:dartclaw_signal/dartclaw_signal.dart';
export 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
