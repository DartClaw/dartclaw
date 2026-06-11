# ADR-007: System Prompt Architecture

**Status:** Proposed
**Date:** 2026-02-27
**Deciders:** DartClaw team

## Context

DartClaw's `ClaudeCodeHarness` sends a `system_prompt` field via JSONL per-turn, which **replaces** Claude Code's entire built-in system prompt. Deobfuscating the binary's prompt composition confirms:

```
base = customSystemPrompt || defaultSystemPrompt   // OR, not AND
final = base + appendSystemPrompt
```

Every turn currently loses Claude Code's tool instructions, safety rules, git protocols, and coding conventions. This is a correctness bug.

Additionally, future harnesses (PiHarness, DirectApiHarness) will have no built-in prompt and need DartClaw to compose 100% of the system prompt. The architecture must support both:
1. **Append-mode** (Claude Code) — preserve built-in prompt, inject behavior content alongside
2. **Replace-mode** (Pi, direct API) — compose full prompt from scratch

### Protocol Constraints (Verified)

- `--append-system-prompt` is a **CLI spawn-time flag only**. Not available as a per-turn JSONL field (confirmed via Python Agent SDK source: per-turn stdin payload only accepts `type`, `message`, `parent_tool_use_id`, `session_id`).
- GitHub issue [#4523](https://github.com/anthropics/claude-code/issues/4523) reports `--append-system-prompt` may inject as a user message rather than API-level system prompt. Worth monitoring; content still reaches the model.
- MEMORY.md access already available via MCP tools (`memory_read`, `memory_search`, `memory_save`) registered in `McpToolRegistry`.

### Predecessor Analysis

- **OpenClaw** owns 100% of the prompt (24 sections) via its embedded SDK. 3 modes: `full`, `minimal` (sub-agents: AGENTS+TOOLS only), `none` (identity line). Per-session snapshot cache (v2026.2.23+). Head+tail truncation (20K/file, 150K total).
- **DartClaw** uses the `claude` binary as subprocess — the binary has its own built-in prompt that must be preserved, not replaced.

## Decision

### Part 1: Prompt Injection Strategy (Claude Code)

**We will use Option A — static `--append-system-prompt` at spawn + MCP memory tools.**

Pass all behavior content (SOUL.md, USER.md, TOOLS.md, AGENTS.md) as `--append-system-prompt` CLI flag at process spawn. Stop sending JSONL `system_prompt`. MEMORY.md accessed on-demand via existing MCP tools.

### Part 2: Replace-Mode Prompt Composition (Future Harnesses)

**We will use Option R1 (extend `BehaviorFileService`) as the starting point, with Option R2 (`SystemPromptBuilder` class) as the extraction target.**

When the first replace-mode harness is built, extend `BehaviorFileService.composeSystemPrompt()` with mode, tool, and context parameters. Extract to a separate `SystemPromptBuilder` class when a second harness diverges in prompt structure or when `McpToolRegistry` injection becomes a real dependency.

### Connecting Abstraction: `PromptStrategy`

A `PromptStrategy` enum (`append` / `replace`) on `AgentHarness` is the shared seam:
- `ClaudeCodeHarness` → `PromptStrategy.append` → `TurnManager` returns empty prompt; harness uses `--append-system-prompt`
- `PiHarness` (future) → `PromptStrategy.replace` → `TurnManager` calls full prompt composition

## Consequences

### Positive

- Claude Code's built-in prompt (tool instructions, safety rules, git protocols) preserved by construction — no custom `system_prompt` means no replacement
- Minimal implementation: ~5-line core change + payload field removal. Net code reduction
- MCP memory tools already wired — no new infrastructure for dynamic memory access
- `PromptStrategy` creates a clean architectural seam for future harnesses without over-engineering now
- Phased roadmap: each phase independently shippable

### Negative

- Behavior content (SOUL, USER, TOOLS, AGENTS) is static at spawn time — mid-session changes require process restart
- MEMORY.md no longer in system prompt for Claude Code — agent must proactively call `memory_read` (mitigated by memory hint in append prompt)
- `--append-system-prompt` may inject as user message at API level (GitHub #4523) — monitor for behavioral impact
- Replace-mode prompt composition is deferred — no full prompt builder until first non-Claude-Code harness

### Neutral

- `AgentHarness.turn()` signature still accepts `systemPrompt` parameter (used by replace-mode harnesses; ignored by append-mode)
- Existing `BehaviorFileService.composeSystemPrompt()` preserved unchanged — serves both the current replace-mode path and future harnesses

## Alternatives Considered

### Part 1: Prompt Injection (6 options evaluated)

#### Option B: Workspace CLAUDE.md Write-Through
- **Pros:** Uses Claude Code's native mechanism, theoretically dynamic
- **Cons:** Re-read behavior unverified, container filesystem blocks primary deployment mode, cascade pollution risk
- **Rejected:** Two unverified assumptions; can't ship on unknowns

#### Option C: Keep JSONL `system_prompt` (Current)
- **Pros:** Zero migration, full dynamic content, natural path for replace-mode
- **Cons:** Correctness fundamentally broken — built-in prompt lost every turn
- **Rejected:** Correctness score 2/10 — this is the bug being fixed

#### Option D: Hybrid `--append-system-prompt` + JSONL
- **Pros:** Clean static/dynamic split
- **Cons:** JSONL `system_prompt` still replaces built-in prompt — same correctness bug as C
- **Rejected:** Misleading "hybrid" — gains complexity without fixing the core problem

#### Option E: Spawn Per Turn
- **Pros:** Always-fresh content, correctness by construction
- **Cons:** 2-5s spawn overhead per turn, loses subprocess session state, requires history-replay redesign
- **Rejected:** Latency prohibitive for interactive chat; fundamental architecture change

#### Option F: Process Restart on Content Change
- **Pros:** Fresh content when files change, minimal core change
- **Cons:** Restart disrupts active sessions, mid-turn coordination complexity
- **Not rejected — deferred:** Can be layered on Option A later if mid-session file changes become a real need

### Part 2: Replace-Mode Composition (4 options evaluated)

#### Option R3: Strategy on `AgentHarness`
- **Pros:** Harness owns prompt end-to-end, no shared builder
- **Cons:** DRY violation (file reading duplicated), two mental models for append/replace, harness gains prompt responsibility beyond its scope
- **Rejected:** Consistency score 5/10; architectural asymmetry

#### Option R4: Template-Based Composition
- **Pros:** Section order visually auditable, static sections editable without Dart
- **Cons:** Most sections are dynamic (tools, datetime, channel context) — template half-rendered in Dart is a false abstraction
- **Rejected:** Adds indirection without value; contrary to minimal-moving-parts philosophy

## Addendum: Codex Prompt Injection (0.13)

This addendum records the Codex-side prompt injection decision for 0.13. It aligns with PRD 0.13 and the multi-provider harness decision in [ADR-016](016-multi-provider-harness-architecture.md).

### Injection Point

Codex uses `developer_instructions` in generated `config.toml` at the developer role. DartClaw's Codex environment setup writes that file via `CodexConfigGenerator`, which keeps the injection inside the provider config layer instead of per-turn message payloads.

`model_instructions_file` is not available to DartClaw for GPT-5/Codex models. OpenAI backend validation rejects it for those models, so DartClaw cannot rely on a system-level replacement path.

The practical result is that Codex's built-in base prompt remains intact. Its roughly 8.5K-token prompt is not overridable by DartClaw; the runtime can only layer additional developer instructions on top of it.

### Content and Precedence

DartClaw concatenates SOUL + USER + TOOLS + AGENTS + security constraints into `developer_instructions`. That gives Codex a single injected block for runtime behavior, security policy, and workspace-specific instructions.

This has lower precedence than system prompt content but higher precedence than `AGENTS.md`, which means DartClaw can enforce security and behavior rules without replacing the provider-owned base prompt.

### Strategy Alignment

Both providers still map to `PromptStrategy.append`. Claude Code appends through `--append-system-prompt` at spawn time, while Codex appends through `developer_instructions` in `config.toml`. The injection point differs, but the architectural intent is the same: preserve the provider's base prompt and layer DartClaw instructions alongside it.

## Implementation Notes

### Phase 1 (Now): Option A for Claude Code

1. `agent_harness.dart` — Add `PromptStrategy` enum, default getter → `replace`
2. `harness_config.dart` — Add `appendSystemPrompt` field (spawn-time, not init handshake)
3. `claude_code_harness.dart` — Override `promptStrategy → append`, add `--append-system-prompt` to `_buildClaudeArgs()`, omit `system_prompt` from JSONL payload
4. `behavior_file_service.dart` — Add `composeStaticPrompt()`: SOUL+USER+TOOLS+AGENTS (no MEMORY), include memory hint
5. `turn_manager.dart` — Return `''` for append-strategy harnesses
6. `serve_command.dart` — Wire `BehaviorFileService` before harness, pass composed content to `HarnessConfig`

### Phase 2 (If Needed): Option F Layer

- Hash-check behavior files before each turn
- Restart process on change (reuse existing crash-recovery lifecycle)
- Guard against mid-turn restart

### Phase 3 (New Harness): Replace-Mode Prompt

- Start with R1: extend `BehaviorFileService` with `PromptMode` + context params
- Extract to R2 (`SystemPromptBuilder`) when second harness diverges
- 10-section prompt: Identity → Safety → Tools → Memory instructions → Workspace → User → Channel → Scheduling → DateTime → Memory content
- 3 modes: `full` (main agent), `minimal` (sub-agents: Identity+Safety only), `none` (identity line)

## References

- Original system-prompt analysis and implementation design are archived privately.
- [Python Agent SDK: client.py](https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/client.py) — JSONL protocol confirmation
- [GitHub #4523](https://github.com/anthropics/claude-code/issues/4523) — `--append-system-prompt` behavioral note
- Research sources are summarized in the linked research appendix.
