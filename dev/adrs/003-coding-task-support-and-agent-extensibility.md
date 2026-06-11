# ADR-003: Coding Task Support and Agent Extensibility

**Status:** Accepted — partially superseded by Phase 0 Direct Bridge Migration (2026-02-25). Mechanism changed from SDK JS options to JSONL control protocol. Core decisions (layered extensibility, `.claude/` ecosystem, security options via bridge) remain valid.
**Date:** 2026-02-23 (addendum: 2026-02-27)
**Deciders:** DartClaw team

## Context

DartClaw's Deno worker invokes the Claude Agent SDK's `query()` function, which spawns a `claude` binary process. Investigation of SDK capabilities revealed several gaps and misconceptions in the current implementation:

1. **Built-in coding tools already available** — `tools` option not set = all built-ins (Bash, Read, Write, Edit, Glob, Grep) available. The `allowedTools` list was mistakenly thought to restrict availability but only controls permission auto-approval; with `bypassPermissions` or `permissionMode: 'bypassPermissions'` already set, `allowedTools` has no effect.

2. **`.claude/` ecosystem currently bypassed** — `settingSources` not set = SDK isolation mode. No `.claude/agents/`, `.claude/skills/`, `CLAUDE.md`, or `settings.json` loaded from the workspace `cwd`. Users have no way to configure agent behavior through familiar Claude Code patterns.

3. **SDK supports rich extensibility** — programmatic `agents` option, `plugins` option, `disallowedTools`, `maxTurns`, `maxBudgetUsd`, `thinking`, `effort`, and `model` are all available per-invocation but currently not wired through the bridge protocol.

4. **Three bundling strategies identified**:
   - A: Programmatic `agents` via bridge (no filesystem, session-scoped)
   - B: Workspace `.claude/` directory (requires `settingSources: ['project']`)
   - C: Local plugin marketplace (extends existing `dartclaw-local` pattern)

## Decision Drivers

- **Coding capability** — the agent must be able to effectively work on code (edit files, run tests, search code)
- **Security control** — DartClaw host must maintain control over what the agent can do
- **Extensibility** — users should be able to add custom skills, agents, and tools
- **Minimal complexity** — avoid over-engineering; leverage existing SDK capabilities
- **Composability** — strategies should layer, not be mutually exclusive

## Decision

Adopt a layered approach, delivering value incrementally without over-engineering.

### Layer 1: Enable `.claude/` ecosystem (immediate)

Make the following targeted changes to the SDK options passed by the Deno worker:

- Add `settingSources: ['project']` — loads `CLAUDE.md`, `.claude/agents/`, `.claude/skills/`, `.mcp.json`, and `settings.json` from the workspace `cwd`
- Switch `systemPrompt` to `{ type: 'preset', preset: 'claude_code' }` and move DartClaw's custom system prompt content to `appendSystemPrompt` (preserves CLAUDE.md loading; `systemPrompt` with a string value overrides the preset and suppresses CLAUDE.md)
- Remove redundant `allowedTools` (already bypassed by `permissionMode`)
- Add `persistSession: false` (addresses TD-010; prevents session state leaking between turns)

This unlocks the full `.claude/` ecosystem — all loaded from the workspace's `cwd`.

### Layer 2: Wire key SDK options through bridge (near-term)

Extend the `agent.turn` bridge protocol (Dart → Deno `AgentTurnParams`) to pass through SDK options that the Dart host can control per-turn.

**Priority 1 — immediate value:**

| Option | Purpose |
|---|---|
| `agents` | Programmatic sub-agent definitions from Dart host |
| `disallowedTools` | Security blocklist controlled by Dart host |
| `maxTurns` | Safety cap on agentic loops |
| `model` | Per-turn model selection |

**Priority 2 — coding workflow support:**

| Option | Purpose |
|---|---|
| `plugins` | Load plugins programmatically (path or name) |
| `appendSystemPrompt` | Additional per-turn context from Dart host |
| `maxBudgetUsd` | Cost control per task |
| `thinking` | Extended thinking for complex reasoning tasks |
| `effort` | Quality/speed tradeoff for the turn |

### Layer 3: Plugin bundling (future)

Extend the existing `dartclaw-local` marketplace with a `dartclaw-workflows` plugin containing coding-specific skills and agents. Users can add their own extensions via:

- Project-scoped `.claude/` files in their workspace (enabled by Layer 1)
- Installing Claude Code plugins (`claude plugin install`)
- Session-scoped via `--plugin-dir` passed through bridge

### What we explicitly choose NOT to do

- **Custom tool execution in Dart** — the `claude` binary handles all tool execution (Bash, Read, Write, Edit, Glob, Grep). DartClaw does not re-implement these.
- **Separate Deno worker for coding** — the existing worker and SDK sub-agent delegation handle coding tasks. No second worker process.
- **Custom orchestration logic** — Claude's built-in Task tool handles sub-agent spawning and delegation. DartClaw provides the definitions; Claude does the orchestration.

## Consequences

### Positive

- Coding tasks work immediately after Layer 1 (one SDK options change, no architectural work)
- Full Claude Code plugin ecosystem accessible to DartClaw agents
- Security maintained — Dart host controls `disallowedTools`, `maxTurns`, and `maxBudgetUsd` via bridge
- Users get familiar `.claude/` patterns (agents, skills, CLAUDE.md) without learning DartClaw-specific APIs
- Composable — layers are independent and can be adopted incrementally

### Negative

- `settingSources: ['project']` means workspace `.claude/` files can influence agent behavior — potential concern if workspace is untrusted. Mitigated by DartClaw's container isolation (Phase 2); for MVP single-user context, acceptable risk.
- Bridge protocol grows as more params are added — validation surface increases
- Plugin loading via Layer 3 adds startup latency per turn

### Neutral

- `bypassPermissions` + `settingSources: ['project']` means workspace `settings.json` hooks cannot add permission gates — all tools are auto-approved regardless of what workspace settings specify. This is consistent with DartClaw's existing model.

## Alternatives Considered

### Don't change SDK options; gate coding tools in Dart

Intercept tool calls in the bridge and proxy them to Dart-native implementations. Rejected: duplicates the `claude` binary's existing, well-tested tool implementations. Adds significant complexity for no security or capability gain.

### Separate Deno worker for coding tasks

Run a second Deno worker configured for coding (different `cwd`, different permissions). Rejected: increases operational complexity (two processes to manage, two bridge channels) when the SDK's `agents` option and per-turn `cwd` already provide the necessary isolation.

### Full `.claude/` ecosystem only, no programmatic bridge options

Rely entirely on workspace `.claude/` files, skip Layer 2. Rejected: Dart host loses the ability to enforce security constraints (`disallowedTools`, `maxTurns`) programmatically. Workspace files are user-controlled; Dart host must retain override capability.

### All three layers simultaneously

Implement all layers at once. Rejected: Layer 1 is a trivial change that unblocks coding immediately. Bundling it with Layer 2 and Layer 3 delays the coding fix unnecessarily.

## Addendum: Phase 0 Direct Bridge Migration (2026-02-27)

Phase 0 eliminated the Deno worker layer. Dart now spawns the native `claude` binary directly via bidirectional JSONL over stdin/stdout (`ClaudeCodeHarness`). This changes the _mechanism_ for each layer but not the _decisions_.

### What changed

| Original mechanism | Current mechanism |
|---|---|
| SDK `query()` via Deno worker | `ClaudeCodeHarness` spawns `claude` binary directly |
| `settingSources: ['project']` JS option | `claude` binary natively reads `.claude/` from process `cwd` |
| `systemPrompt` preset vs `appendSystemPrompt` | `system_prompt` string field in JSONL `initialize` message |
| `persistSession: false` JS option | No `--resume` flag = no session persistence (default) |
| `agent.turn` Dart→Deno `AgentTurnParams` | JSONL `initialize` handshake + `user_message` protocol |

### Layer status (as of 0.2 Phase 1)

**Layer 1 — `.claude/` ecosystem: Delivered (different mechanism).** The `claude` binary loads `.claude/` from its `cwd` by default — no `settingSources` toggle needed. DartClaw sets `cwd` to the workspace directory when spawning the process.

**Layer 2 Priority 1 — Key options: Delivered.** `HarnessConfig` passes these fields in the JSONL `initialize` handshake:

| Option | `HarnessConfig` field | Status |
|---|---|---|
| `disallowedTools` | `disallowedTools` | Implemented |
| `maxTurns` | `maxTurns` | Implemented |
| `model` | `model` | Implemented |
| `agents` | `agents` | Implemented |

**Layer 2 Priority 2 — Extended options: Not yet wired.** `maxBudgetUsd`, `thinking`, `effort` are available as `claude` CLI flags but not in `HarnessConfig`. `plugins` deferred to post-0.2. `appendSystemPrompt` replaced by the single `system_prompt` field (DartClaw composes the full prompt in Dart before sending).

**Layer 3 — Workflow/plugin bundling: Scheduled for 0.15 (Workflow Platform).** DartClaw 0.15 ships five built-in YAML workflow definitions (spec-and-implement, research-and-evaluate, fix-bug, refactor, review-and-remediate) that provide the same pipeline capabilities as external skill systems (e.g., [AndThen](https://github.com/IT-HUSET/andthen) plugin's plan → spec → exec-spec → review-gap pipeline) but with deterministic Dart orchestration instead of LLM-driven prompts. Custom workflows discoverable from `<workspace>/workflows/`. See 0.15 PRD.

### Stale "what we don't do" entries

- "Separate Deno worker for coding" — moot, no Deno workers exist. Reframe as: **no separate `claude` process for coding** — single harness instance handles all task types.
- Other two ("no custom tool execution in Dart", "no custom orchestration logic") remain valid.

## References

- SDK agent-capabilities research is archived privately.
- ADR-001: SDK integration and security architecture (superseded by Phase 0)
- Phase 0 implementation details were consolidated into the 0.2 PRD.
- 0.2 PRD — Layer 2 P2 options relevant to Phase 4 search agent.
- Product backlog — Layer 3 plugin bundling.
- Tech debt: TD-010 (`persistSession`), TD-012, TD-013 (items identified from this investigation)
