# DartClaw — Product Summary

## Vision

**DartClaw** is an experimental, security-conscious AI agent runtime built with Dart. A single AOT-compiled Dart binary orchestrates multiple agent harnesses (Claude Code, Codex, more planned) via a 2-layer architecture (Dart host → native agent binaries via control protocols), providing persistent memory, real-time streaming, and defense-in-depth isolation — all with zero npm/Node.js at runtime.

## Architecture
Architecture: 2-layer model — Dart host (state/API/security) → agent harness binaries via control protocols. DartClaw is **multi-harness by design** — Claude Code (JSONL over stdin/stdout), Codex (JSON-RPC), and ACP adapters share one host-owned execution contract. An execution coordinator serializes the primary interactive lane, enforces per-provider worker capacity, and opportunistically reuses only compatible healthy harnesses. Each harness type retains its own binary, protocol adapter, and native conventions.

## Development Stage

DartClaw is in **early, experimental development** — soft-published only (pre-alpha placeholder on pub.dev). The architecture is stabilizing but not frozen. **Breaking changes are acceptable** for the time being — correctness, security, and clean design take priority over backward compatibility. Expect API surfaces, config schemas, protocol details, and storage formats to evolve as the project matures. Stability commitments will come later, once the core is battle-tested.

## Core Philosophy

A ground-up agent runtime leveraging Dart's strengths. Guiding principles: security by design, security in depth, developer ergonomics, pragmatic lightweight architecture. DartClaw should not only be secure and efficient but also a joy to use and build upon.

**Four pillars.** DartClaw is (1) a **personal daily-driver assistant** — message it from your phone, have it safely search the web, remember things across sessions, run scheduled jobs; (2) an **agentic work runtime** — background code changes and a workflow engine whose definitions DartClaw's own agents can compose dynamically (validated data, never model-authored code); (3) a **glass-box knowledge system** — memory corpus, wiki, and temporal knowledge graph with a steward loop, **shareable as a context engine to other users, agents, and tools over MCP**; (4) **real security boundaries** — OS isolation, guard chain, audit — not prompt-level policy.

**Single-owner, multi-client.** One person owns the assistant, its chat identity, and its writes. Its knowledge surface may serve many clients read-only over MCP. Multi-tenant deployment, per-sender arbitration in chat, and team/crowd features are explicitly out of scope (group-chat use is a recipe, not a product pillar).

**Guiding principles:**
- **OS boundaries over application boundaries** — containers and process isolation are the default posture where a runtime exists; guards are defence in depth, not the boundary
- **Model-first** — judgment belongs to the model behind a schema/tool contract; Dart validates once, bounds, persists, enforces. Never re-derive, repair, default, or overrule a model-supplied value
- **One authority per concern** — one composition root, one execution stack, one workflow runtime, one config schema source, one process-ownership primitive. A second implementation of an existing seam is a defect unless an ADR names why
- **Minimal viable scope per milestone** — resist feature creep; cut scope before adding abstraction
- **Claude-native** — leverage the harness (Claude Code, Codex, ACP agents), `.claude/skills/`, and the native binaries directly; don't re-invent what they provide
- **Auditable, enforced** — per-package lib LOC ceilings that only go down; every subsystem has one owner; prompt-surface inventory tracked; dependencies stay minimal
