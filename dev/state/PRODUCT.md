# DartClaw — Product Summary

## Vision

**DartClaw** is an experimental, security-conscious AI agent runtime built with Dart. A single AOT-compiled Dart binary orchestrates multiple agent harnesses (Claude Code, Codex, more planned) via a 2-layer architecture (Dart host → native agent binaries via control protocols), providing persistent memory, real-time streaming, and defense-in-depth isolation — all with zero npm/Node.js at runtime.

Lineage: OpenClaw → NanoClaw → DartClaw.

## Development Stage

Early, experimental — soft-published only. Architecture is stabilizing but not frozen. **Breaking changes are acceptable** — correctness, security, and clean design take priority over backward compatibility. Stability commitments will come once the core is battle-tested.

## Core Philosophy

**Single-user personal AI assistant.** One user, one deployment, daily-driver utility. Multi-user, multi-tenant, and enterprise features are explicitly deferred.

**Daily-driver use cases:** message your AI from your phone (WhatsApp/Signal/Google Chat), have it safely search the web, remember things across sessions, and run scheduled tasks — all with real OS-level security boundaries, not just prompt-level guardrails.

## Guiding Principles

- **OS boundaries over application boundaries** — containers and process isolation, not just prompt-level policy
- **Minimal viable scope per milestone** — resist feature creep
- **Multi-harness by design** — `HarnessFactory` + `HarnessPool` support heterogeneous providers; each harness reads its native instruction file (`CLAUDE.md` for Claude Code, `AGENTS.md` for everything else)
- **Auditable** — codebase fits in a context window; dependencies stay minimal
