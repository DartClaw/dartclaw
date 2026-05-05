# DartClaw — Product Summary

## Vision

**DartClaw** is an experimental, security-conscious AI agent runtime built with Dart. A single AOT-compiled Dart binary orchestrates multiple agent harnesses (Claude Code, Codex, more planned) via a 2-layer architecture (Dart host → native agent binaries via control protocols), providing persistent memory, real-time streaming, and defense-in-depth isolation — all with zero npm/Node.js at runtime.

## Architecture
Architecture: 2-layer model — Dart host (state/API/security) → agent harness binaries via control protocols. DartClaw is **multi-harness by design** — Claude Code (JSONL over stdin/stdout) and Codex (JSON-RPC) are both first-class primary harnesses; the `HarnessFactory` creates provider-specific harness instances, and the `HarnessPool` manages a heterogeneous pool of runners with different providers and security profiles. Each harness type has its own binary, protocol adapter, and native conventions.

## Development Stage

DartClaw is in **early, experimental development** — soft-published only (pre-alpha placeholder on pub.dev). The architecture is stabilizing but not frozen. **Breaking changes are acceptable** for the time being — correctness, security, and clean design take priority over backward compatibility. Expect API surfaces, config schemas, protocol details, and storage formats to evolve as the project matures. Stability commitments will come later, once the core is battle-tested.

## Core Philosophy

A ground-up agent runtime leveraging Dart's strengths. Guiding principles: security by design, security in depth, developer ergonomics, pragmatic lightweight architecture. DartClaw should not only be secure and efficient but also a joy to use and build upon.

**Single-user personal AI assistant.** DartClaw targets one user, one deployment, daily-driver utility. Inspired by NanoClaw's minimalism — ship what makes it genuinely useful, defer what doesn't. Multi-user, multi-tenant, and enterprise features are explicitly deferred.

**What makes it useful daily:** being able to message your AI from your phone (WhatsApp/Telegram), have it safely search the web for you, remember things across sessions, and run scheduled tasks — all with real security boundaries, not just prompt-level guardrails.

**Guiding principles:**
- **OS boundaries over application boundaries** — containers and process isolation, not just prompt-level policy
- **Minimal viable scope per milestone** — NanoClaw proved 3.9K LOC can be a daily-driver; resist feature creep
- **Claude-native** — leverage Claude Agent SDK, `.claude/skills/`, and the `claude` binary directly; don't re-invent what the SDK provides
- **Auditable** — codebase fits in a context window; dependencies stay minimal
