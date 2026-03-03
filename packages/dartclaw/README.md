# DartClaw

Security-hardened AI agent runtime for Dart. A single AOT-compiled Dart binary
orchestrates Claude via a 2-layer architecture: **Dart host** (state, API,
security) spawns the native **`claude` CLI binary** as a subprocess,
communicating via bidirectional JSONL over stdin/stdout.

> **Status: Pre-alpha** — API is unstable and will change. This is an early
> development release to establish pub.dev presence. Real release planned for
> 0.4.

## Architecture

```
┌─────────────────────────────┐
│  Dart Host (AOT-compiled)   │
│  ┌───────────┐ ┌──────────┐ │
│  │ GuardChain│ │ Sessions │ │
│  └─────┬─────┘ └──────────┘ │
│        │ JSONL stdin/stdout │
│  ┌─────▼─────────────────┐  │
│  │  claude CLI (Bun bin) │  │
│  └───────────────────────┘  │
└─────────────────────────────┘
```

**Zero npm/Node.js at runtime.** The `claude` binary is a self-contained Bun
standalone executable. Dart handles orchestration, security policy, session
persistence, and multi-channel messaging.

## Core abstractions

- **`AgentHarness`** — subprocess lifecycle, turn execution, event streaming
- **`Guard` / `GuardChain`** — security policy evaluation (command, file,
  network, content guards)
- **`Channel`** — messaging interface (WhatsApp, Signal)
- **`BridgeEvent`** — sealed event hierarchy from the JSONL control protocol
- **`DartclawConfig`** — YAML-based configuration

## What this enables

- Custom agent CLI/server apps using DartClaw's harness and guard chain
- Embedding agent capabilities into existing Dart applications
- Building alternative UIs (Flutter, CLI REPL) on top of core services
- Reusing guard infrastructure for other agent runtimes

## Current status

This package re-exports the core interfaces from the internal `dartclaw_core`
package. The API surface is intentionally narrow for this pre-alpha release —
only stable abstractions and models are exposed.

See the [repository](https://github.com/tolo/dartclaw) for development
progress, roadmap, and documentation.

## License

MIT
