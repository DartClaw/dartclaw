# OpenClaw vs NanoClaw vs DartClaw — Feature Comparison

> Lineage: OpenClaw → NanoClaw → DartClaw
> Last updated: 2026-09-15 (DartClaw 0.27 working-tree implementation sync; focused producer evidence only, with joined browser/device/owner/provider/CI/container/Windows/release and clean-candidate qualification pending; competitor rows not re-verified) · 2026-09-13 (DartClaw 0.26 tagged; competitor rows not re-verified) · 2026-09-09 (DartClaw 0.26 hybrid memory/conversation search sync; competitor rows not re-verified) · 2026-08-27 (DartClaw 0.24.3 trust-boundary and credential-delivery release-prep sync) · 2026-08-13 (DartClaw 0.24 canonical-memory and provider-neutral execution-isolation release-prep sync) · 2026-08-10 (logical-agent sessions, worker capacity, memory journal, on-demand jobs) · 2026-08-08 (memory-hygiene rows: OpenClaw dreaming, NanoClaw v2 OKF memory, DartClaw 0.27 planned entries; behavior-file corrections — TOOLS.md retirement, ONBOARDING.md; from [memory-hygiene-2026-08](../research/memory-hygiene-2026-08/research.md)) · 2026-07-25 (CLI-section correction: stale `dartclaw chat` / `/compact` / `dartclaw doctor` claims verified against code and fixed) · 2026-07-14 (0.21 native Windows qualification sync; broader competitor rows last verified 2026-07-10)
> Chat-only refresh: 2026-09-15. Selected DartClaw UI rows now describe the 0.27 working-tree implementation and keep every unrun qualification row pending; [research evidence and limits](../research/chat-session-experience-2026-09/research.md). Competitor rows retain their earlier verification dates.
> OpenClaw version: **2026.8.1 "OpenClaw 2.0"** (Aug 30 2026) · [Changelog](https://github.com/openclaw/openclaw/blob/main/CHANGELOG.md) · ⚠️ OpenClaw cells below are verified through 2026.6.11 (Jun 30) — 2.0 deltas (SQLite session storage, cloud workers/Fleet, Active Memory + default-on dreaming, conversation branching/search, masked credential intake, team operator roles, security audit ~25 categories, optional Codex harness) are catalogued in [openclaw-2.0-2026-08](../research/openclaw-2.0-2026-08/research.md); row-by-row re-verify due at next milestone completion
> NanoClaw version: 2.1.17 (Jun 17 2026; main at 2.1.42 untagged) · repo renamed to [nanocoai/nanoclaw](https://github.com/nanocoai/nanoclaw) · **v2 architecture rewrite** (OneCLI gateway, multi-provider, skills split across branches) – NanoClaw cells not explicitly re-verified below may carry the 1.2.x baseline
> DartClaw: published baseline `v0.26.1` (`ef24b330`); 0.27 is implemented on a working tree but not release-qualified
>
> See also: [competitor-analysis.md](competitor-analysis.md) — broader landscape (Hermes Agent, Letta, PAI, Khoj, PocketPaw, Praktor, OpenLegion, Proma, etc.)

> Adjacent-project check, 2026-09-21: [Fa and its factory](../research/fa-harness-2026-09/research.md) add implementation/test references for bounded history I/O, trace inspection and complexity/coverage analysis. DartClaw already has working-tree branching, pre-compaction persistence and null for unavailable session cost. This note does not re-verify OpenClaw/NanoClaw rows or qualify 0.27 for release.

## Project Overview

| | OpenClaw | NanoClaw | DartClaw |
|---|---|---|---|
| **Runtime** | Node.js 24+ (22.16+ min) | Node.js/TypeScript | Dart (AOT) + native Claude/Codex/ACP provider CLIs |
| **Stars** | ~382,400 | ~30,200 | Private |
| **LOC** | ~434,000–500,000 (TS-dominant monorepo + Swift/Kotlin apps) | v2 rewrite: ~224k tokens (112% of a context window); LOC unverified | ~146,000 lib (~329,000 incl. tests) |
| **Source files** | 3,680 | — (v2: trunk + `channels`/`providers` branches) | ~1,494 Dart files (source + test) |
| **Dependencies** | 56 runtime + 31 dev (monorepo root) | 7 core (`@onecli-sh/sdk`, `chat`, `better-sqlite3`, `cron-parser`, `@clack/core`, `@clack/prompts`, `kleur`) | ~15 Dart packages |
| **Config files** | 53 | Minimal (`.env`, `versions.json`, `.mcp.json`, optional per-group `container.json`; behavior config in SQLite via `ncl` CLI) | 1 (`dartclaw.yaml`) |
| **Audit time** | 1-2 weeks | No longer trivial (224k tokens post-v2; former ~10 min claim obsolete) | Hours (no longer single-context at ~146k lib LOC) |
| **Install** | `npm install -g openclaw` | Fork + `claude` CLI + OneCLI gateway container (install script, native uninstaller, group templates) | Self-contained AOT release bundle + provider CLI; Homebrew on macOS/Linux; checksum-verifying PowerShell installer and Scoop manifest on Windows x64 (0.21); `dartclaw init` guided setup (0.16.2) |
| **Architecture** | Single-process gateway (1 port multiplexes HTTP/WS/UI/webhooks) | Host orchestrator + per-group containers + OneCLI local gateway (credential vault + egress proxy); Docker Sandboxes micro VM option (`channels` branch docs) | Dart host → native Claude/Codex adapters + provider-neutral ACP adapter (JSONL/JSON-RPC control protocols) |
| **LLM Agent** | Custom LLM wrapper (multi-provider) | Claude Agent SDK in container (default); per-group providers: Codex, OpenCode, Ollama (v2) | Native `claude`/`codex` binaries + ACP agents (JSONL / JSON-RPC control protocols) |
| **IPC** | In-process | Filesystem (JSON files, host polls + validates) | Bidirectional JSONL or JSON-RPC over stdin/stdout |
| **Extension model** | Plugin system (TypeScript, jiti-loaded) + ClawHub marketplace | Skills-as-branches v2 (trunk = registry/infra; 48 skills on `main`, 44 on `channels`; `/add-<name>` installs) | Guard extensions (YAML, UI-editable 0.17) + MCP (host + outbound 0.19) + runtime-provisioned skills |
| **Release cadence** | Daily (1-2 stable releases/day) | Continuous (v2 line; main ahead of tagged releases) | Phased (published `v0.26.1`; 0.27 working-tree implementation awaiting integrated and external qualification) |
| **Philosophy** | Feature-maximalist | Radical minimalism + AI-native everything | Structured minimalism with phased growth |

---

## Core Agent Runtime

| Feature | OpenClaw | NanoClaw | DartClaw Phase |
|---|---|---|---|
| Long-lived worker process | N/A (single process) | Per-invocation containers | **0.2** ✅ (harness stays alive between turns) |
| Auto-restart on crash | Process-level | Container re-spawn | **P1** ✅ (exponential backoff, max 5 retries) |
| Turn timeout | Configurable | Container timeout | **P1** ✅ (600s default, configurable) |
| Claude Agent SDK | ✗ (custom wrapper) | ✅ (native `claude` binary in container) | **P1** ✅ (native `claude` binary via JSONL) |
| `.claude/` workspace ecosystem | ✗ | ✅ (via `claude` CLI in container) | **P1** ✅ (`settingSources: ['project']`) |
| Multi-provider LLM | ✅ 35+ providers: Anthropic, OpenAI (GPT-5.4 default), Gemini, OpenRouter, xAI/Groq, Mistral, Kilo Gateway, Vercel AI Gateway, Moonshot/Kimi, OpenCode Go, Alibaba ModelStudio/Qwen, Anthropic Vertex AI (v2026.3.22), Chutes (v2026.3.22), Xiaomi MiMo V2 (v2026.3.22), MiniMax M2.7 (v2026.3.22), GitHub Copilot (agent runtime v2026.5.28); v2026.5–7.x adds Opus 4.8, Fable 5, Haiku 4.5, GPT-5.6 family, GLM-5.2, Kimi K2.7 Code, StepFun, OpenRouter OAuth, ClawRouter bundled provider plugin (v2026.7.1: dynamic model discovery, budget reporting) | ✅ v2: pluggable per-group agent providers – Claude (default), Codex (`/add-codex`, v2.1.17), OpenCode, Ollama; plus any Anthropic-compatible API via `ANTHROPIC_BASE_URL` | **0.13** ✅ Claude + OpenAI (Codex); **0.18** ✅ ACP harness – any ACP-compliant agent via config alone (Goose + Mistral Vibe verified). Heterogeneous HarnessPool, per-task provider selection. Pi (20+ providers) evaluated for future milestone |
| Universal agent harness (ACP client) | ✅ (ACP runtime: `sessions_spawn` with `runtime: "acp"`, ACPX/Codex; `acp.fallbacks` backup backends v2026.4.x) | ✗ | **0.18** ✅ (first-party ACP JSON-RPC/stdio harness in `dartclaw_core`; new agents usable via config alone, zero code changes; Goose + Mistral Vibe validated; reverse calls guard-mediated) |
| Claude Opus 4.6 / Sonnet 4.6 | ✅ (2026.2.17/2026.2.23) | ✅ (via SDK) | ✅ (via SDK) |
| 1M context | ✅ (via model string `[1m]` suffix; now standard for Max/Team/Enterprise) | ✗ | ✅ (via model string `[1m]` suffix, e.g. `opus[1m]`; default model is `opus[1m]`) |
| AOT-compiled binary | ✗ | ✗ | **P1** ✅ (`dart compile exe`) |
| Zero npm in runtime | ✗ (Node.js) | ✗ (Node.js) | **P1** ✅ |
| Concurrent sessions | ✅ (multi-agent) | ✅ (per-group containers + global concurrency cap) | **0.2** ✅ per-session locks; **0.24** fixed serialized primary lane plus hard per-provider worker capacity for background execution |
| Schema-bound logical-agent output | ✅ (provider/tool schemas vary by surface) | ✗ | **0.24.3** ✅ strict bare-JSON parsing plus host-side validation against a deep-closed JSON Schema subset; invalid or oversize output fails the turn without repair or truncation |
| Model selection per turn | ✅ (per-agent config + per-agent `params` overrides) | ✗ | **0.2** ✅ (`model` passthrough via harness config) |
| Model fallback chains | ✅ (full chain traversal, 2026.2.24) | ✗ | ✗ |
| Auto-updater | ✅ (`update.auto.*`, 2026.2.22) | ✅ (`/update-nanoclaw` skill pulls upstream) | ✗ |
| Agent Swarms / Teams | ✅ (Agent Teams experimental, `TeammateIdle`/`TaskCompleted` hooks) | ✅ (Anthropic SDK native, experimental `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) | ✗ (multi-agent in P4 but different model) |
| Parallel task execution | ✗ | ✅ (3 concurrent scheduled tasks, v0.2.0) | **0.8** ✅ per-task harnesses; **0.24** `ExecutionCoordinator` with provider `pool_size`, fail-fast nested acquisition, and opportunistic compatible-worker reuse |
| Task orchestrator | ⚠️ Partial (Workboard agent-coordination tool v2026.5.28; unified SQLite background-task ledger — no review lifecycle) | ✗ | **0.8** ✅ (9-state lifecycle, SQLite persistence, sequential + parallel execution, review flows) |
| `sessions_yield` (orchestration) | ✅ (v2026.3.12: end turn + carry hidden follow-up payload) | ✗ | ✗ |
| Context Engine plugin slot | ✅ (v2026.3.22: 7-hook lifecycle — `bootstrap`/`ingest`/`assemble`/`compact`/`afterTurn`/`prepareSubagentSpawn`/`onSubagentEnded`; slot-based registry; `AsyncLocalStorage` isolation; `lossless-claw` reference impl; `delegateCompactionToRuntime()` helper; `modelId` passed to `assemble()`; transcript maintenance rewrites for overflow recovery; contract hardened fail-closed through v2026.6.x) | ✗ | ✗ per-turn assembly slot (compaction lives in `TurnManager`). Note: DartClaw's 0.19 "Context Engine" is knowledge *synthesis* (`context_research`) – a different concept, see Memory System |
| Fast Mode | ✅ (v2026.3.12: per-session `/fast` toggle, provider-mapped; v2026.6.x `/fast auto` speed tiers) | ✗ | ✗ |
| Remote host control | ✗ | ✗ (v1.2.14 `/remote-control` skill removed in v2 – absent from `main` and `channels`) | ✗ |
| PDF tool (native) | ✅ (v2026.3.2: Anthropic + Google PDF providers, extraction fallback) | ✗ | ✗ (tools run inside claude CLI) |
| MCP Elicitation | ✅ (v2.1.76: structured mid-task input via `Elicitation`/`ElicitationResult` hooks) | ✗ | ✗ |
| Native worktree support | ✅ (v2.1.x: `--worktree` flag) | ✗ | **0.8** ✅ (DartClaw-managed `WorktreeManager`) |
| `CLAUDE_CODE_SIMPLE` mode | ✅ (disables MCP/hooks/CLAUDE.md for minimal subprocess invocations) | ✗ | **0.10** ✅ (`CLAUDE_CODE_SIMPLE=1` in restricted container sessions) |
| Multi-project / external repo | ✗ | ✗ | **0.14** ✅ (`ProjectService`: config-seeded + API-managed registry, auto-clone, per-project credentials, task `projectId` binding, implicit `_local` backward compat); **0.16.4** local-path projects (bind existing checkout, allowlist-controlled); **0.19** portable relative `localPath` + `allowApiLocalPath` fail-closed |
| Auto-fetch before worktree | ✗ | ✗ | **0.14** ✅ (`ensureFresh()`: 5-min cooldown + per-project lock, tasks always branch from fresh state) |
| Push-to-remote + PR creation | ✗ | ✗ | **0.14** ✅ (`RemotePushService`: push branch to remote, `gh pr create` via outpost pattern, PR URL as task artifact, graceful degradation if `gh` unavailable) |
| `/btw` side-channel query | ✅ (v2026.3.22: non-context-mutating inline question, dismissible TUI answer, explicit BTW reply on channels) | ✗ | ✗ |
| Subagent partial progress on timeout | ✅ (v2026.3.22: timeout preserves + reports partial progress instead of discarding) | ✗ | ✗ |
| Agent default timeout | ✅ (v2026.3.22: 48h default — up from 600s; configurable) | Container timeout | **P1** ✅ (600s default, configurable) |
| `before_dispatch` hook | ✅ (v2026.3.24: canonical inbound metadata, routed replies through final-delivery path) | ✗ | ✗ |
| Lobster workflow engine | ✅ (separate repo `openclaw/lobster`: YAML pipelines, approval gates, resume tokens, sub-lobsters) | ✗ | **0.15** ✅ (YAML workflow platform: data model, executor, API routes, management UI, auto-retry with loop detection). **0.16.1** hybrid steps (bash, approval, session continuity, built-in packs). **0.16.4** connected-by-default CLI execution, `story-pipeline` + `foreach` sub-pipelines with per-story worktrees, agent-resolved merge (`gitStrategy.merge_resolve`), file-based artifact transport with auto-commit, runtime-provisioned skill catalog, GitHub PR webhook trigger, real-Codex E2E release gate. **0.17** engine reliability (stall detection, `foreach` resume, unified step-retry authority). **0.19** framework-agnostic engine (ADR-041), standalone lifecycle control (`--standalone` resume/pause/cancel/retry, cwd-local `.dartclaw/` auto-discovery), `--inline` git-strategy override, non-interactive approvals policy, provider auth preflight. **0.20** hardening: one-shot timeout backstops (stall guard + wall-clock ceiling), live CLI progress spinner with per-step token ticks, blocked-outcome semantics + settle-time digest, strict unknown-field YAML validation, consolidated registry tiers, connected/standalone promotion + publish reconciled under per-project transaction lock |

---

## Security Model

| Feature | OpenClaw | NanoClaw | DartClaw Phase |
|---|---|---|---|
| **Primary boundary** | Application-level (8-layer policy) | OS-level (Docker Sandboxes micro VM + container per group) | **0.2** ✅ OS-level (Docker containers, `network:none`) |
| API key env stripping | ✅ | ✅ (only `CLAUDE_CODE_OAUTH_TOKEN` + `ANTHROPIC_API_KEY` passed to container; env sanitized from bash subprocesses, #171/#213) | **0.2** ✅ (`PreToolUse` bash hook + container env isolation) |
| System prompt safety rules | ✅ (SOUL.md, AGENTS.md) | ✅ (CLAUDE.md per group) | **P1** ✅ (hardcoded rules injected every turn) |
| Docker container isolation | ✅ (opt-in, configurable scope) | ✅ (always-on, per-group; Docker default since 2026-02-20) | **0.2** ✅ (kernel namespaces, `--cap-drop=ALL`, `network:none`); **0.25** default-on where a Docker or Podman runtime is detected — an unset `container.enabled` means "isolate if this host can", and a host without a runtime starts in advisory mode with a loud startup warning naming its reason (ADR-055) |
| Hypervisor-level isolation | ✅ (Lume macOS VM) | ✅ Docker Sandboxes (micro VM: Host→Sandbox VM→NanoClaw→Docker-in-Docker→agent containers, Mar 13); Apple Container (opt-in) | **P5** (Lume/Multipass) |
| Container namespace join blocking | ✅ (`network: "container:<id>"` blocked by default, 2026.2.24) | N/A | **0.2** ✅ |
| `network:none` + proxy | ✅ (hardened mode) | Implicit (container networking) | **0.24** ✅ per-authority framed `docker exec -i` mediation for provider and scoped host-MCP traffic; no reusable credential or network relay in containers |
| Command-guard (regex) | ✅ (plugin, 17 categories) | ✗ (container = boundary) | **0.2** ✅ (regex + pipe analysis + quote stripping) |
| File-guard (glob) | ✅ (plugin, 3 levels) | ✗ (container mounts = boundary) | **0.2** ✅ (3 levels: `no_access/read_only/no_delete`, symlink resolution) |
| Network-guard (allowlist + SSRF) | ✅ (plugin; IPv6 transition/NAT64/6to4/Teredo blocking added 2026.2.19) | ✅ v2: opt-in per-group egress lockdown (network allowlisting) | **0.2** ✅ (domain allowlist + exfil detection + IPv6 transition blocking) |
| Channel-guard (ML injection) | ✅ (DeBERTa ONNX, ~370MB) | ✗ | **P3** (same DeBERTa model, 3-tier scoring) |
| Content-guard (LLM boundary) | ✅ (claude-haiku, inter-agent) | ✗ | **0.2** ✅ (Haiku at `sessions_send` boundary, fail-closed); **0.24.3** one `ContentScan` authority across logical-agent, built-in fetch, and public outbound-MCP result paths |
| Guard fail mode | Configurable (`failOpen`) | N/A | **0.2** ✅ (`failOpen: false` — fail-closed default) |
| Security audit CLI | ✅ (`openclaw security audit`) | ✗ | **P5** (`dartclaw security audit --deep --fix`) |
| Multi-user trust heuristic | ✅ (`security.trust_model.multi_user_heuristic`, 2026.2.24) | ✗ | ✗ |
| Credential proxy (network-layer) | ✅ (2026.2.19: secrets pass via SDK env + temp file delete) | ✅ (v2: OneCLI Agent Vault – local gateway at `127.0.0.1:10254` holds secrets, per-request injection via `HTTPS_PROXY` as traffic leaves the container; container never sees raw values. Replaces the v1.2.12 host-proxy/placeholder model; `use-native-credential-proxy` skill is the env-threading opt-out) | **0.24** ✅ host-owned per-authority provider adapter; containers receive no reusable provider credential |
| IPC namespace isolation | ✗ (in-process) | ✅ (per-group IPC namespaces prevent privilege escalation) | **0.2** ✅ (per-group workspace isolation) |
| Symlink traversal protection | ✅ (workspace path sanitization, 2026.2.16; plugin/hook realpath checks, 2026.2.19) | ✅ (critical fix #367: skills path-remap root escape + symlink; #387: group folder escape; #392: read-only project root mount) | **0.2** ✅ (file-guard symlink resolution) |
| Per-agent auth profiles | ✅ | ✗ | **0.2** ✅ (via tool policy cascade) |
| Tool policy cascade | ✅ (8 layers) | ✗ | **0.24** ✅ live identity-threaded global/agent cascade, exact own-MCP canonical mapping, and provider-interception limits surfaced explicitly |
| Egress firewall rules | ✅ (custom Docker network + pf/nftables) | ✗ | **0.2** ✅ (pf/nftables + `network:none` container) |
| Config `get` secret redaction | ✅ (`env.*` and `skills.entries.*.env.*` redacted, 2026.2.23) | N/A (no config system) | **0.2** ✅ (redactPatterns in logging config) |
| Browser SSRF policy | ✅ (`browser.ssrfPolicy`, 2026.2.23) | N/A | ✗ (no browser; tools run inside claude CLI) |
| VM hypervisor boundary | ✅ (Lume, macOS only) | ✅ (Docker Sandboxes micro VM + Apple Container opt-in) | **P5** (Lume/Multipass) |
| Mount allowlist | ✅ | ✅ (`~/.config/nanoclaw/mount-allowlist.json`; project root mounted read-only, #392) | **0.2** ✅ |
| `web_fetch` response size cap | ✅ (`maxResponseBytes: 5MB`, 2026.2.16) | N/A (no web tools in host) | **0.2** ✅ (search agent: `maxResponseBytes: 5MB`) |
| Dangerous Docker config rejection | ✅ (rejects sensitive bind mounts, `--network host`, unconfined seccomp at startup, 2026.2.16) | N/A (fixed container config) | **0.2** ✅ |
| Gateway auth auto-generation | ✅ (`gateway.auth` auto-generated if missing; `mode: "none"` required for open, 2026.2.19) | N/A (no gateway) | **0.2** ✅ (64-hex token, auto-generated) |
| Inbound message sanitization | ✅ (plugin hooks) | ✗ | **0.5** ✅ → **0.25** ✗ (`InputSanitizer` deleted: injection judgment has one owner, the `ContentGuard` classifier at agent boundaries and on fetched content). No shipped guard evaluates `messageReceived`, so **inbound channel text is not scanned on arrival** |
| Outbound secret/PII redaction | ✅ (`logging.redactSensitive`) | ✗ | **0.5** ✅ (`MessageRedactor`: pattern-based redaction of secrets and PII in logged output) |
| LLM-based content classification | ✅ (channel-guard DeBERTa ONNX) | ✗ | **0.5** ✅ (`ContentClassifier`: pluggable backends — `ClaudeBinaryClassifier` + `AnthropicApiClassifier`) |
| Per-session token/cost tracking | ✅ (per-agent `cacheRetention` params) | ✗ | **0.5** ✅ (`UsageTracker`: input/output/cache tokens + estimated cost per session) |
| Per-type container isolation | ✅ (configurable scope) | ✅ (per-group) | **0.8** ✅ (`workspace` + `restricted` profiles, collision-free naming via SHA256); **0.25** the profile is **declared, not inferred** — task categories were retired, so no `type` value selects a profile and every profile-carrying input is refused rather than defaulted |
| SSRF-hardened web_fetch | ✅ (v2026.3.13: Telegram media SSRF policy; unreleased: URL-credential bypass + redirect-to-internal tests) | N/A | **0.7** ✅ (DNS resolution + address range validation before fetch). ⚠️ Missing: URL-credential bypass + redirect vector coverage |
| Config fail-closed on validation errors | ✅ (v2026.3.7: no silent fallback to permissive defaults; v2026.6.6: transcript/sandbox/MCP/browser/channel/exec-approval paths fail closed on unsafe or malformed input) | ✗ | ⚠️ Partial (**0.19**: `projects.allowApiLocalPath` forced off without an allowlist – fail-closed; general `ConfigValidator` behavior still unverified) |
| External-agent reverse-call guard mediation | ✅ (ACP approval hardening: canonical tool identity, fail-closed on conflicting identity hints – v2026.3.22) | ✗ | **0.18** ✅ (ACP `fs/read_text_file`/`fs/write_text_file`/`terminal/create` routed through `GuardChain`: canonical tool mapping with raw ACP audit names, workspace-jailed `cwd`, `EnvPolicy`-sanitized env overlays, host-side output caps, fail-closed on unknown terminal IDs) |
| Provider approval/sandbox config axes | N/A (own tool loop) | ✗ (container = boundary) | **0.20** ✅ (Claude gains `approval` + `sandbox` axes mirroring Codex; full access is explicit opt-in with loud startup warning) |
| Skill/plugin install policy (fail-closed) | ✅ (v2026.3.31→6.2: installs with `critical` dangerous-code findings fail closed by default; governed operator install policy across doctor/CLI/ClawHub) | ✗ | N/A (no marketplace; skills runtime-provisioned from pinned git ref) |
| Bootstrap-token-only pairing | ✅ (v2026.3.22: short-lived tokens in QR, no shared credentials) | ✗ | ✗ (constraint for future Flutter mobile app) |
| Build-tool env injection blocking | ✅ (v2026.3.22: blocks MAVEN_OPTS, SBT_OPTS, GRADLE_OPTS, ANT_OPTS, GLIB_TUNABLES, DOTNET_ADDITIONAL_DEPS from host exec env) | ✗ | ✗ |
| Media URL escape fix | ✅ (v2026.3.24: `mediaUrl`/`fileUrl` alias bypass closed; Windows SMB credential leak blocked via file:// + UNC path rejection) | N/A | N/A |
| Pluggable sandbox backends | ✅ (v2026.3.22: SSH backend + OpenShell with `mirror` and `remote` workspace modes; sandbox list/recreate/prune backend-aware) | ✗ | ✗ |
| `Permissions-Policy` HTTP header | ✅ (v2026.3.7: camera, mic, geolocation restricted) | N/A | ✗ |
| Cron file permission hardening | ✅ (v2026.3.7: owner-only 0600, including pre-existing files) | ✗ | ✗ |
| `--password-file` credential input | ✅ (v2026.3.7: avoids process listing leak; `--password` warns) | N/A | ✗ |
| Host env override hardening | ✅ (v2026.3.22: fail-closed on bad overrides, Windows key casing) | ✗ | ✗ |
| External secrets management | ✅ (v2026.2.26: `openclaw secrets audit/configure/apply/reload`, SecretRef 64 targets) | ✗ | **0.24.3** partial – owner-only named credential store, stdin-only set/list/rm, search-provider references, and read-only location/permissions audit; no external vault or encryption at rest |
| Exec approval hardening | ✅ (v2026.3.12: Unicode spoofing, shell-flag escapes, interpreter unwrapping, `pnpm exec`/`npx` runner detection) | ✗ | ✗ (DartClaw command-guard covers regex + pipe analysis) |
| Plugin auto-load security | ✅ (v2026.3.12: workspace plugins no longer auto-load without explicit trust, GHSA-99qw-6mr3-36qr) | N/A | N/A |
| Sender allowlist (per-group) | ✅ | ✅ (v1.2.3: per-group permitted sender list) | **0.2** ✅ (DM + group allowlists) |
| Security advisories (total) | 288 (major batch in v2026.3.12: 16+ GHSAs across exec, auth, session, channel, gateway) | N/A | N/A |
| Rate limiting (inbound) | ⚠️ Partial (gateway auth-failure rate limiter default-on, node-pairing + Google Chat webhook limits added v2026.4–6.x; still no per-sender message limits. [#13615](https://github.com/openclaw/openclaw/issues/13615) – outbound API throttling – still open as of 2026-07) | ✗ | **0.12** ✅ (`SlidingWindowRateLimiter`: per-sender + global, admin exempt, configurable window) |
| Hard spend cap / budget enforcement | ✗ (no native cap — 3 third-party tools fill gap: ClaWatch, ClawMetry, OpenClaw Watch) | ✗ | **0.12** ✅ (`GovernanceEnforcer`: daily token budget, warn/block modes, midnight reset, admin exempt) |
| Emergency stop from channels | ✗ | ✗ | **0.12** ✅ (`/stop` abort all + `/pause`/`/resume` queue management, admin-only) |
| API keys leak to LLM context | ⚠️ Yes — [#11829](https://github.com/openclaw/openclaw/issues/11829): model catalog with resolved keys serialized into prompt on every turn; 5+ leak vectors. Still open as of 2026-07 (point fixes only: SecretRef auth profiles, key redaction, web-search key audits) | ✗ (container boundary + OneCLI vault) | ✗ (0.24 host-owned per-authority provider adapter – no reusable credential in containers) |
| Agent-writable identity files | ⚠️ Yes — SOUL.md/AGENTS.md agent-writable by design; "soul-evil" hook shipped bundled ([#8776](https://github.com/openclaw/openclaw/issues/8776)); enables persistence attacks | ✗ (per-group CLAUDE.md in container) | ✗ (behavior files are host-managed, not agent-writable. Immutable system prompt architecture) |

---

## Storage & Persistence

| Feature | OpenClaw | NanoClaw | DartClaw Phase |
|---|---|---|---|
| Session metadata | `sessions.json` | SQLite (`better-sqlite3`) | **P1** ✅ (`meta.json` per session dir) |
| Message transcripts | JSONL (append-only, tree structure) | SQLite (messages table) | **P1** ✅ (NDJSON, line# = cursor) |
| Cursor-based crash recovery | ✅ | ✅ (message cursor, only advances on successful processing) | **P1** ✅ (line number as monotonic cursor) |
| KV store | In-memory/config | SQLite | **P1** ✅ (`kv.json` with atomic writes) |
| Search index | Hybrid BM25 + vector; multi-language FTS (ES/PT/JA/KO/AR, 2026.2.22); Unicode-aware CJK tokenization (2026.2.16); Ollama embeddings (v2026.3.2) | ✗ | **0.26** ✅ SQLite FTS5 or PostgreSQL language-aware FTS plus built-in hybrid memory/conversation search; **0.27 working tree** uses PostgreSQL, scopes agent projections to the authenticated managed-workspace principal and adds authorized current/global conversation navigation |
| Atomic writes | ✅ | ✅ (SQLite transactions + atomic file IPC) | **P1** ✅ (NDJSON append + temp-file rename for JSON) |
| Session disk budget | ✅ (`session.maintenance.maxDiskBytes` / `highWaterBytes`; `openclaw sessions cleanup`, 2026.2.23) | ✗ | **0.7** ✅ (`max_disk_mb` + `max_sessions` + `prune_after_days` + CLI `sessions cleanup`) |
| Cascade delete | Manual | SQL cascade | **P1** ✅ (`Directory.deleteSync(recursive: true)`) |
| Index rebuild | ✅ | N/A | **P1** ✅ (`dartclaw rebuild-index`) |
| Conversation archiving | ✅ | ✅ (PreCompact hook for archiving) | **0.2** ✅ archive-as-type-change with Resume; **0.27 working tree** keeps reversible inbox Settle separate, so settled conversations remain readable and writable |
| Bootstrap file caching | ✅ (per-session key cache for `AGENTS.md`/`MEMORY.md`, 2026.2.23) | N/A | ✗ |
| Task persistence (SQLite) | ✅ (v2026.4–6.x: unified SQLite ledger for ACP/subagent/cron/background-CLI runs) | ✗ | **0.8** ✅ (`tasks.db`: tasks, goals, artifacts — separate from session NDJSON); **0.16.4** `agent_executions` + `workflow_step_executions` decomposition (ADR-021) |
| CLI backup & restore | ✅ (v2026.3.8: `openclaw backup create/verify`, manifest validation) | ✗ | ✗ |
| Config validation CLI | ✅ (v2026.3.2: `openclaw config validate --json`) | ✗ | ✗ |

---

## Memory System

Scoped verification 2026-09-21: OpenClaw ordinary memory is per-agent; additional Markdown paths enable intentional shared retrieval, while its Memory Wiki plugin defaults to a global vault with optional per-agent scope. This separates shared reference knowledge from private agent memory. [Sources and Hermes comparison](../research/persona-memory-boundaries-2026-09/research.md). Other rows retain their earlier verification dates.

| Feature | OpenClaw | NanoClaw | DartClaw Phase |
|---|---|---|---|
| Long-term memory file | Layer 2: `MEMORY.md` (curated) | v2: `memory/index.md` per group (16k cap, always loaded) + on-demand concept files with OKF v0.1 frontmatter ("a convention, not a gate"); no DB, no embeddings | **0.24** ✅ revisioned canonical Markdown index + topic/archive/observation/learning/audit corpus; databases and QMD are derived |
| Daily memory files | Layer 1: `workspace/memory/YYYY-MM-DD.md`; timezone-aware dates (2026.2.16) | ✗ | **P1** ✅ auto-logged per turn; **0.27 working tree** writes only grant-eligible turns to the authenticated owner or managed-agent workspace, with no owner fallback |
| Scheduled memory journal | Dream cycle periodically curates daily logs into durable memory | ✗ | **0.24** ✅ opt-in `memory.journal`; **0.27 working tree** runs the existing journal/curation flow independently for each eligible managed corpus; removed and ungranted agents do not acquire jobs |
| Memory MCP tools | ✗ (built-in tools) | ✅ (Claude's native memory management, since 2026-02-09) | **0.24** ✅ host-attributed observe/search/read/apply; **0.27 working tree** derives personal read/write scope from authenticated execution plus explicit grants and refuses missing or forged scope instead of falling back to owner |
| Semantic/vector search | ✅ (local GGUF, OpenAI, Gemini, Voyage; Ollama embeddings v2026.3.2) | ✗ | **0.26** ✅ verified local EmbeddingGemma or explicit OpenAI-compatible HTTP embeddings over SQLite or PostgreSQL; **0.27 working tree** retains per-principal projection ownership on PostgreSQL lexical and optional pgvector paths |
| Hybrid search (BM25 + vector) | ✅ (configurable weights) | ✗ | **0.26** ✅ built-in weighted RRF for memory and conversations, lexical fallback and retained vectors; **0.27 working tree** keeps managed-workspace scope through PostgreSQL lexical and optional pgvector paths |
| Multi-language FTS | ✅ (ES/PT/JA/KO/AR stop-words + query expansion, 2026.2.22) | ✗ | ✗ (not yet planned; FTS5 only) |
| MMR re-ranking | ✅ (lambda 0.7) | ✗ | **P4** |
| Temporal decay | ✅ (halfLifeDays: 30) | ✗ | **P4** (configurable half-life) |
| Pre-compaction memory flush | ✅ | ✗ | **0.16** ✅ (silent agentic turn before SDK compaction, SHA-256 dedup, heuristic suppression when deterministic compaction signal exists) |
| Post-compaction sync | ✅ (v2026.3.12: mode-aware session reindexing after compaction) | ✗ | ✗ |
| Cross-agent shared memory | ✅ (`extraPaths`) | ✗ (per-group isolation by design) | **0.27 working tree** keeps canonical memory private to each managed workspace. Granted agents research their own memory plus the shared owner wiki/KG; deliberate publication uses existing shared write authorities rather than shared personal-memory writes |
| Per-agent QMD scoping | ✅ (prevents cross-agent contamination, 2026.2.16) | N/A (per-group containers) | **P4** (separate agent session stores) |
| Memory size management | Manual curation | Manual | **P1** ✅ (`memoryMaxBytes` truncation, oldest first) |
| Knowledge graph | ✗ | ✗ | **0.17** ✅ (temporal knowledge graph: SQLite-backed, MCP tools, as-of/supersession semantics; **0.19** timeline UI + synthesis input) |
| LLM-maintained wiki | ✅ (Memory Wiki + "Stale Pages" report, refined through v2026.6.x) | ✗ | **0.17** ✅ (wiki with provenance, search ranking, lint categories; `wiki/README.md` scaffolded in fresh workspaces) |
| Knowledge inbox ingestion | ✗ | ✗ | **0.17** ✅ (filesystem inbox → curated wiki/KG ingestion – durable knowledge loop) |
| Cross-layer knowledge synthesis | ✗ | ✗ | **0.19** ✅ (`context_research` citation-backed synthesis); **0.27 working tree** supplies an authenticated agent's private memory separately from shared wiki/KG, while named clients receive shared wiki/KG only; citations, direct KG reads and provenance follow the same boundary |
| QMD backend (neural reranking) | ✅ (experimental sidecar) | ✗ | Working opt-in QMD backend with structured query depths; deprecated in **0.26**, removed in the following milestone |
| Post-compaction section injection | ✅ (v2026.3.7: configurable `AGENTS.md` sections re-injected after compaction) | ✗ | ✗ |
| Compaction lifecycle events | ✅ (v2026.3.22: `session:compact:before`/`after` with session + token metadata; user notifications when auto-compaction starts/finishes) | ✗ | **0.16** ✅ (`CompactionStartingEvent` / `CompactionCompletedEvent`, Claude `PreCompact`, Codex `contextCompaction` parsing, task timeline compaction events for running task sessions) |
| Ollama embeddings for memory | ✅ (v2026.3.2: configurable fallback) | ✗ | **0.26** ✅ explicit OpenAI-compatible HTTP endpoint/model for memory and conversations; raw input, no Ollama-specific adapter or automatic fallback |
| QMD per-agent config isolation | ✅ (v2026.3.7: `QMD_CONFIG_DIR` set per-agent) | N/A (per-group containers) | ✗ ⚠️ (shared config dir — correctness bug) |
| Idle-time memory consolidation ("dreaming") | ✅ (default-on, cron 3AM: light/REM/deep phases, deterministic weighted promotion gates incl. recall-count + query diversity, structural taints block untrusted candidates, ≥75% prior-entry preservation floor, rewrite history recorded; `DREAMS.md` diary excluded from default recall) | ✗ | Planned in Knowledge Interop & Steward (Dreaming phase: cross-corpus curation, **propose-mode memory diff + operator approval** — glass-box differentiator vs. OpenClaw's auto-apply; [brief](0.next-knowledge-interop/dreaming-brief.md)) |
| Write-time state/event classification | partial (`USER.md` dated `active`/`superseded` directives — convention, that file only) | ✗ | Planned in Knowledge Interop & Steward (FR12: extend the canonical `memory_observe`/`memory_apply` boundary with an explicit state-vs-event route; `state` routes to KG with contradiction screening + supersession; exact tool seam is a PRD-time decision; [brief](0.next-knowledge-interop/prd-brief.md)) |
| Memory contradiction detection | ✗ (wiki "Stale Pages" report only) | ✗ | **0.17** ✅ KG insert-time contradiction check + `kg_contradictions` MCP tool; wiki lint (stale + open contradictions, scheduled) |

---

## Behavior Files / System Prompt

| File | OpenClaw | NanoClaw | DartClaw Phase |
|---|---|---|---|
| `SOUL.md` (identity/values) | ✅ (all sessions) | ✗ (uses CLAUDE.md) | **P1** ✅ (global + project level) |
| `CLAUDE.md` (workspace config) | ✗ | ✅ (per-group, agent-maintained) | **P1** ✅ (via SDK `settingSources`) |
| `MEMORY.md` | ✅ (main sessions) | ✗ | **P1** ✅ (all sessions) |
| `USER.md` (user profile) | ✅ (DM sessions) | ✗ | **0.2** ✅; **0.17** structured scaffold + personalization onboarding (web prompt, `onboarding_complete`, `dartclaw init --personalize` / `--apply-drafts`) |
| `TOOLS.md` (env-specific notes) | retired (folded into `AGENTS.md` `## Tools`; `openclaw doctor --fix` migrates — third-party guides still list it as live) | ✗ | **0.2** ✅ |
| `BOOTSTRAP.md` (first-run) | ✅ (self-deleting ritual) | ✗ | **0.17** ✅ (`ONBOARDING.md` sentinel — draft-mode + review, expires; stronger equivalent) |
| `DREAMS.md` (consolidation audit trail) | ✅ (excluded from default recall) | ✗ | Planned in Knowledge Interop & Steward (per-run dream report; [brief](0.next-knowledge-interop/dreaming-brief.md)) |
| `BOOT.md` (per-start) | ✅ | ✗ | ✗ (not planned) |
| `HEARTBEAT.md` (periodic tasks) | ✅ | ✗ | **0.2** ✅ |
| `AGENTS.md` (safety rules) | ✅ | ✗ | ✗ (hardcoded safety rules instead) |
| `IDENTITY.md` (detailed identity) | ✅ | ✗ | ✗ (covered by SOUL.md) |
| Live reload (no restart) | ✅ | N/A (per-invocation) | **0.16** ✅ (behavior files re-read every turn + `ConfigNotifier`/`Reconfigurable` hot-reload for reloadable YAML sections) |
| Resolution cascade | ✅ (per-file rules) | Single file per group | **P1** ✅ (global → project, concatenated) |

---

## Session Management

| Feature | OpenClaw | NanoClaw | DartClaw Phase |
|---|---|---|---|
| Session CRUD | ✅ | ✅ (SQLite) | **P1** ✅ (REST API) |
| Session scoping | ✅ (6 scope levels) | Per-group (implicit) | **0.7** ✅ (configurable DM/group scope, per-channel overrides, 5 DM + 3 group scope modes) |
| Session reset policies | ✅ (daily + idle + per-type) | ✗ | **0.2** ✅ (daily + idle, per-type: main/channel/cron only; user sessions preserved) |
| Identity links (cross-channel) | ✅ | ✗ | ✗ (not in 0.2; extensible via channel interface) |
| Context compaction | ✅ (summarize/safeguard modes; configurable post-compaction section injection) | ✅ (SDK built-in + PreCompact hook; `/compact` skill) | **0.2** ✅ (SDK built-in + pre-compaction flush, trimming, reserve floor) |
| SDK session resumption | ✅ | ✅ (container restart) | **0.2** ✅ (`options.resume: sessionId`) |
| Pruning (cache-TTL, soft/hard) | ✅ (3 modes) | ✗ | **0.2** ✅ (transient result trimming) |
| Subagent context guard | ✅ (preemptive context guarding before model calls, 2026.2.21) | ✗ | ✗ |
| Auto-title | ✗ | ✗ | **P1** ✅ (first ~50 chars of user message) |
| Session maintenance (pruning) | ✅ (3 modes) | ✗ | **0.7** ✅ (archive >prune_after_days, count cap, disk budget, cron retention, CLI cleanup) |
| Session type routing | ✅ | Per-group | **0.7** ✅ (main/channel/cron/user/task/archive — type-aware lifecycle) |
| Task lifecycle management | ✗ | ✗ | **0.8** ✅ (draft→queued→running→review→accepted/rejected/cancelled/failed, review queue) |
| Stuck-turn visibility + early cancel | ✗ | ✗ | **0.18** ✅ (operator-visible wait/stuck state on active turns, task SSE signal, authorized early-cancel endpoint releasing a wedged turn before the global timeout) |
| ACP thread-bound agents | ✅ (v2026.2.26: first-class runtime with full lifecycle, reconciliation, cleanup; v2026.3.22: Feishu ACP binding, approval hardening, error-state recovery, Discord abort forwarding, Codex hidden-thinking replay fix; v2026.3.28–31: current-conversation binds for Discord/BlueBubbles/iMessage/LINE) | ✗ | ✗ (0.18 runs ACP agents as first-class harnesses instead; task thread binding exists since 0.12) |
| ACP session resumption | ✅ (v2026.3.11: `sessions_spawn` with `runtime: "acp"` can resume existing ACPX/Codex conversations) | ✗ | ✗ |
| ACP security hardening | ✅ (v2026.3.22: admin scope for mutations, canonical tool identity for approvals, fail-closed on conflicting identity hints) | ✗ | ✗ |
| Thread-bound sessions | ✅ (v2026.2.21: `sessions_spawn` with `thread: true` binds subagent/ACP session to platform thread; `/focus`/`/unfocus` commands; `idleHours`/`maxAgeHours` lifecycle; Discord complete, Telegram partial, Matrix wiring) | ✗ | **0.12** ✅ (`ThreadBinding`: channel-agnostic `(channelType, threadId) → (taskId, sessionKey)` routing, auto-unbind on terminal states, idle timeout cleanup) |

---

## Web UI & Native Apps

| Feature | OpenClaw | NanoClaw | DartClaw Phase |
|---|---|---|---|
| Web-based UI | ✅ (Control UI v2: modular dashboard, command palette, search, slash commands, pinned messages — v2026.3.12; v2026.7.1 nav overhaul: session-first sidebar, context meter, reasoning-effort slider, slash-command picker) | ✗ (AI-native: no dashboard by design) | **P1** ✅ (HTMX + SSE); **0.16.6** Stimulus-on-HTMX interaction layer (vendored, zero-Node); **0.19** Afterglow design system across all pages |
| Session sidebar | ✅ | ✗ | **P1** ✅ create/switch/delete; **0.27 working tree** stable active inbox, orthogonal filters, attention counts, browser-local draft overlay, reversible settle/restore, paginated settled tail, lineage and responsive resize/drawer |
| Real-time streaming | ✅ (WebSocket) | ✗ | **P1** ✅ SSE; **0.27 working tree** editable composer with Queue/Steer/Stop, authoritative snapshot recovery, multi-viewer invalidation and jump-to-latest |
| Markdown rendering | ✅ | ✗ | **P1** ✅ (marked.js + highlight.js) |
| Tool activity indicators | ✗ | ✗ | **P1** ✅ (pending/success/error inline) |
| Dark/light theme | ✅ | ✗ | **P1** ✅ (toggle, persisted in localStorage) |
| Responsive mobile layout | ✅ | ✗ | **P1** ✅ (<768px sidebar overlay); **0.27 working tree** adds focus-contained conversation inbox, controls and dialogs; physical iOS/Android keyboard, safe-area, paste and screen-reader evidence remains pending |
| Inline session rename | ✗ | ✗ | **P1** ✅ |
| XSS prevention | ✅ (CSP enforcement, 2026.2.16) | N/A | **P1** ✅ (server-side HTML escaping) |
| CSP + SRI | ✅ (2026.2.16) | N/A | **0.2** ✅ (CSP header + SRI on CDN scripts) |
| Canvas (visual presentations) | ✅ (2026.2.2) | ✗ | **0.14.2** ✅ (shareable canvas, share-token auth, workshop task board/stats templates) |
| Settings/admin pages | ✅ (tag-aware config UI, 2026.2.22) | ✗ | **0.16** ✅ (config form editing, scheduling jobs, guard audit, guard config viewer, graceful restart + immediate apply for reloadable fields); **0.17** guard-extension editor (YAML-backed CRUD, validation, tester verdicts, pending-restart status, admin-gated server-side) |
| System alert routing | ✅ (notifications and operator-facing system events across multiple surfaces) | ✗ | **0.16** ✅ (`AlertsConfig`, explicit channel targets, severity-aware formatting, per-target throttling + burst summaries) |
| Token/cost display | ✅ | ✗ | **0.2** ✅ (per-session counters in metadata) |
| Android native app | ✅ (5-tab shell; node commands: camera, contacts, calendar, motion, notifications — v2026.3.1; Google Code Scanner QR — v2026.3.13) | ✗ | ✗ |
| iOS app features | ✅ (Home Canvas: live agent overview with docked toolbar — v2026.3.11; model picker with persistent thinking; gateway foreground recovery) | ✗ | ✗ |
| Flutter native app | ✗ | ✗ | **P5** (desktop + mobile) |
| Memory dashboard | ✗ | ✗ | **0.6** ✅ (`/memory`: overview, search config, file browser, daily logs, pruner history) |
| Task dashboard | ✗ | ✗ | **0.8** ✅ (`/tasks`: filterable list, SSE updates, detail page with chat + artifacts + review controls) |
| Dashboard extensibility | ✅ (plugins) | ✗ | **0.8** ✅ (`PageRegistry` + `registerDashboardPage()` SDK API) |
| Sidebar archive separation | ✗ | N/A | **0.7** ✅ (collapsible archive, DM/Group channel subsections) |
| Command palette | ✅ (current session/action search; [Control UI](https://docs.openclaw.ai/web/control-ui/chat), checked 2026-09-13) | ✗ | **0.27 working tree** one typed `/` + Cmd/Ctrl+K catalog with nine built-ins, context-sensitive disabled reasons, authorized provider-native skills and unchanged unknown-slash delivery; focused contracts pass, actual browser evidence pending |
| Rich chat composer | ✅ (Control UI chat) | ✗ | **0.17** ✅ rich-input metadata; **0.27 working tree** IndexedDB text/file/reference drafts, save/conflict recovery, editable streaming composer and explicit Queue/Steer/Stop; temporary drafts are page-only |
| Conversation search to message | ✅ ([Control UI](https://docs.openclaw.ai/web/control-ui/chat), checked 2026-09-13) | Not re-verified | **0.27 working tree** current/global authorized server search with lifecycle/project filters, exact totals, escaped snippets and bounded exact-message navigation; PostgreSQL and browser qualification pending |
| Edit/fork conversation | ✅ (provider/session limits; no external-effect undo; [Control UI](https://docs.openclaw.ai/web/control-ui/chat)) | Not re-verified | **0.27 working tree** preserved-history edit/fork and explicit failed/cancelled-attempt retry create linked work without rewriting source history or undoing external effects |
| Durable composer drafts | Current docs describe loading continuity; cross-device semantics not compared | Not re-verified | **0.27 working tree** ordinary browser-local IndexedDB drafts retain accepted file bytes, references and stable revision/submission identity across reload; no cross-device claim |
| Effective conversation context | Context inspector and model controls | Not re-verified | **0.27 working tree** shows immutable workspace owner separately from current/next project, directory, provider, model and effort; revisioned changes apply at the next admission and provider-native state does not cross provider changes |
| Conversation attention center | Notification/activity surfaces | Not re-verified | **0.27 working tree** durable unread/dismiss state, exact-target links, current-request approval actions and deterministic machine triage; owner ten-item triage remains pending |
| Temporary conversations | Provider-dependent ephemeral sessions | Not re-verified | **0.27 working tree, provider-limited** process/page/container-only state, explicit end and durable redacted Markdown export; real Codex/container destruction and cleanup-before-startup qualification remains pending |
| Knowledge UI | ✗ | ✗ | **0.19** ✅ (read-only: Knowledge Hub `/knowledge` with wiki/KG/memory/inbox fan-out + layer filters, research-packet view with citation markers + provenance popovers + unverified flags, temporal KG timeline with as-of/category filters) |
| Fast mode toggle | ✅ (v2026.3.12: per-session `/fast` command) | ✗ | ✗ |
| Skills management UI | ✅ (v2026.3.24: status-filter tabs, click-to-detail dialog, requirements display, toggle switch, install action, API key entry) | ✗ | ✗ |
| Agent tools visibility | ✅ (v2026.3.24: live "Available Right Now" tool list in Control UI, compact/detailed modes) | ✗ | ✗ |
| Expand chat to canvas | ✅ (v2026.3.22: expand button on assistant chat bubbles) | ✗ | ✗ |
| Roundness/theme customization | ✅ (v2026.3.22: Roundness slider, discrete border-radius stops across themes) | ✗ | ✗ |

---

## HTTP API

| Feature | OpenClaw | NanoClaw | DartClaw Phase |
|---|---|---|---|
| REST API | ✅ (full programmatic) | ✗ | **P1** ✅ session CRUD/send/SSE; **0.27 working tree** adds conversation snapshot/queue/steer, inbox/attention/settle, search/target, catalog/action, effective-context, and temporary lifecycle/export routes with current-identity authorization |
| OpenAI-compatible `/v1/chat/completions` | ✅ (v2026.3.24: added `/v1/models`, `/v1/embeddings`, `/v1/responses`; Gateway acts as OpenAI-compatible proxy for RAG clients) | ✗ | ✗ (not planned) |
| WebSocket protocol | ✅ (v3 JSON RPC) | ✗ | ✗ (SSE instead) |
| Token-based auth | ✅ (auto-generated if missing, 2026.2.19) | ✗ | **0.2** ✅ (64-hex gateway token) |
| HSTS header | ✅ (`gateway.http.securityHeaders.strictTransportSecurity`, 2026.2.23) | N/A | ✗ |
| Health endpoint | ✅ (v2026.3.1: `/health`, `/healthz`, `/ready`, `/readyz` for K8s) | ✗ | **0.2** ✅ (`/health` with uptime, worker state, DB size) |
| CORS | ✅ | N/A | **P1** ✅ (localhost regex) |
| K8s deployment support | ✅ (v2026.3.12: raw manifests, Kind setup, deployment docs) | ✗ | ✗ |

---

## CLI

| Feature | OpenClaw | NanoClaw | DartClaw Phase |
|---|---|---|---|
| Gateway start | ✅ (`openclaw start`) | Manual (`node src/index.ts`) | **P1** ✅ (`dartclaw serve`) |
| Status check | ✅ (`openclaw models status --agent <name>`) | ✗ | **P1** ✅ (`dartclaw status`) |
| Index rebuild | ✗ | ✗ | **P1** ✅ (`dartclaw rebuild-index`) |
| Interactive chat REPL | ✅ (chat commands) | ✗ | ✗ (no `dartclaw chat`; `dartclaw sessions list/show/messages` is read-only inspection — interactive chat is the web UI) |
| Chat slash commands | ✅ (`/reset`, `/compact`, `/status`, `/subagents spawn`, etc.) | ✅ (`/compact` skill, v1.2.12) | Not a CLI surface. Google Chat channel **0.9** ✅ (`/new`, `/reset`, `/status`, `/stop`, `/pause`, `/resume`). **0.27 working tree** restores the web `/` palette with nine typed built-ins and authorized provider-native skills; unknown slash text remains ordinary provider input. No built-in `/compact` claim |
| `/subagents spawn` | ✅ (deterministic subagent activation from chat, 2026.2.21) | ✗ | ✗ |
| Dependency doctor | ✗ | ✗ | Partial — no `dartclaw doctor`; provider/port/instance-dir checks run as `dartclaw init` preflight (`SetupPreflight`), not as a standalone repairable command |
| Security audit | ✅ (`openclaw security audit`) | ✗ | **P5** (`dartclaw security audit --deep --fix`) |
| Sandbox management | ✅ (`openclaw sandbox recreate`) | ✗ | **0.2** ✅ (via Docker management) |
| Shell completion | ✅ (Zsh/Bash/PowerShell/Fish, 2026.1.30) | ✗ | ✗ |
| `update --dry-run` | ✅ (2026.2.22) | ✗ | ✗ |
| Stop keywords (multilingual) | ✅ (ES/FR/ZH/HI/AR/JP/DE/PT/RU, 2026.2.24) | ✗ | ✗ |
| Backup & restore | ✅ (v2026.3.8: `openclaw backup create/verify`, manifest validation, `--only-config`) | ✗ | ✗ |
| Config validation | ✅ (v2026.3.2: `openclaw config validate --json`, `openclaw config file`; v2026.3.28 `openclaw config schema`) | ✗ | **0.16.2** ✅ (preflight checks during `dartclaw init`: config parse, binary presence, writable paths, port availability) |
| Standalone workflow CLI (zero-server) | ✗ (Lobster is a separate CLI tool) | ✗ | **0.17** ✅ (`dartclaw init --workflow` minimal config); **0.19** full standalone lifecycle (`run/resume/pause/cancel/retry --standalone`, cwd-local `.dartclaw/` auto-discovery, git-trackable config); **0.20** live progress spinner + `workflow validate --skills` probe |
| Attach to running session | ✅ (v2026.7.1: `openclaw attach` — external harness attachment to an existing Gateway session) | ✗ | ✗ |
| Guided setup wizard | ✗ (NanoClaw: AI-native "describe problems to Claude") | ✗ (Docker Sandbox install script) | **0.16.2** ✅ (`dartclaw init` TUI wizard: Quick-track + Full-track, interactive + `--non-interactive`, safe rerun, `ONBOARDING.md` seeding) |
| Service management | ✅ (`launchctl` / `systemctl`) | ✗ | **0.16.2** ✅ (`dartclaw service install\|start\|stop\|status\|uninstall`, user-scoped, instance-scoped units) |
| External secrets workflow | ✅ (v2026.2.26: `openclaw secrets audit/configure/apply/reload`) | ✗ | **0.24.3** ✅ named store with `dartclaw secrets set/list/rm/audit`; store-backed search-provider references reload without service-unit secrets |
| `config set` expansion | ✅ (v2026.3.22: SecretRef + provider builder modes, JSON/batch assignment, `--dry-run` validation with structured JSON output) | ✗ | ✗ |
| Agent bindings CLI | ✅ (v2026.2.26: `openclaw agents bindings/bind/unbind`, channel-to-account routing) | ✗ | ✗ |
| Remote control | ✗ | ✗ (v1.2.14 `/remote-control` removed in v2) | ✗ |

---

## Messaging Channels

| Channel | OpenClaw | NanoClaw | DartClaw Phase |
|---|---|---|---|
| WhatsApp | ✅ (QR pairing, multi-account) | ✅ (skill: `/add-whatsapp`, on `channels` branch in v2; dedicated phone number; emoji reactions skill; `baileys` no longer a trunk dependency) | **0.2** ✅ (whatsmeow/GOWA sidecar, ADR-005). ⚠️ Ban risk accepted |
| Telegram | ✅ (inline buttons, DM streaming, ACP topic bindings v2026.3.7; `custom apiRoot` for self-hosted Bot API v2026.3.13; forum topic agent routing with per-topic `agentId` isolation v2026.3.7; polls support; `--force-document` uncompressed uploads v2026.3.13) | ✅ (skill: `/add-telegram`; swarm variant `/add-telegram-swarm`) | **Post-0.2** (Grammy) |
| Discord | ✅ (thread support, auto-archive, idle lifecycle — v2026.3.11) | ✅ (skill: `/add-discord`) | Not planned (extensible via channel interface) |
| Slack | ✅ (Block Kit replies, typing for Socket Mode DMs — v2026.3.12) | ✅ (skill: `/add-slack`, merged Feb 25) | **Post-0.2** (Dart-native shelf adapter, HTTP Events API + streaming). Priority 2 for multi-user |
| Signal | ✅ (target aliases v2026.7.1) | ✅ (`add-signal` skill + `signal-cli` integration in current tree; the earlier PR #1057 was closed unmerged — shipped via another path) | **0.4** ✅ (signal-cli daemon, SSE events, DM/group access control, mention gating). E2E verified **0.6** |
| Google Chat | ✅ (GCP service account) | ✗ | **0.8** ✅ (pure REST, GCP service account JWT, typing indicator, DM/group access control, config UI) |
| Feishu/Lark | ✅ (v2026.3.1: docx tables, image/file uploads, inbound reactions, `feishu_chat` tool, `encryptKey` enforcement) | ✗ | Not planned |
| Microsoft Teams | ✅ (v2026.3.24: official Teams SDK, streaming 1:1 replies, welcome cards, prompt starters, feedback/reflection, typing indicators, native AI labeling, message edit/delete) | ✗ | Not planned |
| Synology Chat | ✅ (native plugin, 2026.2.22) | ✗ | Not planned |
| Zalo | ✅ (v2026.3.2: rebuilt with native `zca-js` in-process, QR/login) | ✗ | Not planned |
| X (Twitter) | ✗ | ✗ (`/x-integration` retired v2.1.17 — broken on v2 architecture) | Not planned |
| Gmail | ✗ | ✅ (skill: `/add-gmail`, refactored) | Not planned |
| Voice transcription | ✅ (Talk/TTS, ElevenLabs, configurable silence timeout — v2026.3.8) | ✅ (skill: `/add-voice-transcription`; `/use-local-whisper` for local whisper.cpp) | Not planned |
| iMessage/macOS | ✅ (native `imessage`/`imsg`; BlueBubbles channel removed v2026.6.2; native polls v2026.7.1) | ✗ | Not planned |
| DM access control | ✅ (pairing/allowlist/disabled) | ✅ (sender allowlist per group, v1.2.3) | **0.2** ✅ (pairing + allowlist + open + disabled) |
| Group policies | ✅ (allowlist/open/disabled) | Per-group isolation (trigger-word based) | **0.2** ✅ (allowlist/open/disabled) |
| Per-group model/effort override | ✅ (per-agent config) | ✅ (implicit — per-group containers have separate configs) | **0.14.5** ✅ (structured `group_allowlist` entries with `model`/`effort` fields; highest precedence in resolution chain) |
| Per-group project binding | ✗ | ✅ (implicit — per-group containers create tasks in their own context) | **0.14.5** ✅ (`group_allowlist` entries with `project` field; tasks created with that `projectId`) |
| Mention gating | ✅ (known bug: #11758 WhatsApp LID) | ✗ | **0.2** ✅ (native `mentionedJids` + regex fallback) |
| Message debouncing | ✅ | ✗ | **0.2** ✅ (1000ms default) |
| Queue modes | ✅ (steer/followup/collect) | FIFO per-group (global concurrency cap, default 3) | **0.2** ✅ (per-session FIFO + global concurrency cap) |
| Text chunking | ✅ (per-channel limits) | ✗ | **0.2** ✅ (4K default, all 3 channels — smart paragraph/sentence/word break points) |
| Binding-based routing | ✅ (6-level precedence; account-scoped agent bindings — v2026.2.26) | ✗ (simple trigger-word routing) | **Post-0.2** (channel interface extensible) |

---

## Multi-Agent

| Feature | OpenClaw | NanoClaw | DartClaw Phase |
|---|---|---|---|
| Multi-agent orchestration | ✅ (2-agent standard, 3-agent hardened) | ✅ (Agent Swarms via Anthropic SDK native, 2026-02-09) | **0.24** ✅ configured named logical agents with durable provider-pinned sessions; search remains the closed default specialist |
| Per-agent workspace isolation | ✅ (per-agent QMD scoping, 2026.2.16) | ✅ (per-group containers + per-swarm-agent memory) | **0.27 working tree** derives each named workspace from its stable agent id, admits only its exact host identity marker and pins session/storage identity independently of mutable project context; retired explicit paths, unsafe ids, unmarked content and stale bindings refuse without reassignment |
| Inter-agent communication | ✅ (`sessions_send`, `sessions_spawn`, `agentToAgent`; forked-context `sessions_spawn` v2026.5.x) | ✅ (swarm coordination via SDK) | **0.24** ✅ `sessions_spawn` creates a logical-agent session; handle-based `sessions_send` continues persisted history and identity |
| Delegation to external agents | ✅ (ACP spawn + channel binds) | ✗ | **0.24** ✅ unified agent definitions route Claude, Codex, or ACP providers through `sessions_spawn`/`sessions_send`; preview `delegate_to_agent` removed |
| Search agent pattern | ✅ (dedicated, no filesystem) | ✗ | **0.2** ✅ (web_search + web_fetch only, tool policy cascade) |
| Subagent limits | ✅ (`maxPingPongTurns`, `maxSpawnDepth`, `maxChildrenPerAgent`, 2026.2.16) | ✗ | **0.24** ✅ hard shared `providers.<id>.pool_size` capacity with fail-fast nested acquisition; no separate depth or child quotas |
| Delegation patterns | ✅ (channel→main→search→computer) | Swarm-based (per-swarm agent behavioral config) | **0.2** ✅ (main→search delegation via AgentDefinition) |
| Background worker capacity | ✅ (configurable scope) | ✗ | **0.24** ✅ one `ExecutionCoordinator` owns per-provider `pool_size`; compatible host harnesses are an opportunistic cache, while owner-scoped containers may be reused only across that owner's turns |
| Container dispatch routing | ✅ | ✅ (per-group) | **0.8** ✅ → **0.25** the task-type → profile mapping is gone with the category enum; a task declares its security profile and its `needsWorktree` flag explicitly |
| `sessions_yield` | ✅ (v2026.3.12: end turn + skip queued tool work + hidden follow-up payload to next turn) | ✗ | ✗ |
| Subagent inline attachments | ✅ (v2026.3.2: `sessions_spawn` base64/utf8 file attachments) | ✗ | ✗ |
| Subagent authority scope | ✅ (v2026.3.12: leaf vs orchestrator scope persisted at spawn, leaf cannot regain orchestration after restore) | ✗ | ✗ |

---

## Automation & Scheduling

| Feature | OpenClaw | NanoClaw | DartClaw Phase |
|---|---|---|---|
| Cron scheduling | ✅ (cron/interval; heartbeat DM delivery blocked by default, 2026.2.24; SQLite-backed status + transient rate-limit retries v2026.6.x; `on-exit` schedule kind + detachable session-targeted runs v2026.7.1) | ✅ (cron/interval/one-shot via `cron-parser`; `context_mode` option; atomic task-claim prevents double-execution v1.2.2) | **0.2** ✅ (cron/interval/once) |
| On-demand scheduled runs | ✅ (`cron run`; detachable runs v2026.7.1) | ✗ | **0.24** ✅ CLI, API, and Scheduling UI execution that preserves cadence/pause state and rejects busy jobs |
| Heartbeat pattern | ✅ (HEARTBEAT.md driven) | ✗ | **0.2** ✅ (HEARTBEAT.md, configurable interval) |
| Workspace git sync | ✅ (agent-driven or cron) | ✗ | **0.2** ✅ (auto-commit on heartbeat, push if remote configured) |
| Webhooks (external triggers) | ✅ | ✗ | **0.2** ✅ (webhook delivery mode for cron jobs) |
| Workflow recording/replay | ✅ (2026.2.3) | ✗ | ✗ |
| Task-type scheduled jobs | ✗ | ✗ | **0.8** ✅ (cron job type `task` → creates reviewable task instead of direct turn) |
| Timezone-aware scheduling | ✅ (v2026.3.13: `OPENCLAW_TZ` env for gateway/CLI timezone) | ✅ (v1.2.9: host timezone injected into agent context, UTC-suffixed timestamps rejected) | **0.2** ✅ (system timezone) |
| Cron named persistent sessions | ✅ (`sessionTarget: "session:custom-id"` maintains context across cron runs) | ✗ | ✗ (cron sessions are ephemeral; `session_id` option not yet supported) |
| Parallel scheduled tasks | ✗ | ✅ (v0.2.0: up to 3 concurrent independent sessions) | **0.8** ✅ (via HarnessPool) |

---

## Extension Model

| Feature | OpenClaw | NanoClaw | DartClaw Phase |
|---|---|---|---|
| Plugin system | ✅ (v2026.3.22: new `openclaw/plugin-sdk/*` surface replacing `openclaw/extension-api`; hooks+tools+RPC+HTTP+CLI+background services; Context Engine plugin slot; `llm_input`/`llm_output` hooks; plugin auto-load disabled for security; `prependSystemContext`/`appendSystemContext` for provider-cacheable guidance; `requestHeartbeatNow()` for agent wakeup; `onAgentEvent`/`onSessionTranscriptUpdate` subscriptions; memory plugin self-registration of system-prompt sections; `delegateCompactionToRuntime()` for context engines; `modelId` in `assemble()`; transcript maintenance rewrites; Codex/Claude/Cursor bundle compatibility; v2026.6.2 governed install policy; v2026.6.9 external provider packages as first-class npm releases) | ✗ | ✗ (guard extensions + MCP + SDK extension points, but no general plugin system) |
| Skills / Extension mechanism | ✗ | ✅ Skills-as-branches, matured in v2: trunk ships registry/infra only; channel adapters live on the `channels` branch (44 skills), alternative providers on `providers`; **48 skill dirs** on `main`, installed via `/add-<name>`; some v1 skills retired in v2.1.17 (`claw`, `x-integration`, `add-parallel`, `convert-to-apple-container`); "Flavors" concept unverified in v2 | **0.16.3/0.16.4** ✅ (built-in skill library embedded in the binary; **0.17** replaced runtime provisioning with canonical-name resolution (ADR-040) — DartClaw no longer clones AndThen or rebrands its skills, the operator installs the `andthen` plugin and DartClaw resolves `andthen:<skill>` to the provider-native name; four DartClaw-native skills still ship in the binary; `.claude/skills/` via SDK) |
| ClawHub / Skill marketplace | ✅ (2026.2.3; bundled skills moved to ClawHub-only, 2026.2.22; 820+ malicious skills found — security incident; installs retain verified source provenance v2026.6.9) | ✅ (`qwibitai/nanoclaw-skills` marketplace plugin, Qodo partnership, 2026-02-23; org renamed to `nanocoai` — marketplace repo location unverified post-v2) | ✗ |
| Custom tools registration | ✅ (via plugins) | ✗ | **0.2** ✅ (Dart-backed MCP tools via `mcp_message` routing) |
| MCP server hosting | ✗ | ✗ | **0.5** ✅ (`/mcp` SSE endpoint, `registerTool()` SDK API). **0.6** ✅ (`web_fetch` + Brave/Tavily search tools, harness auto-config) |
| Outbound MCP client | ✗ (plugin tools instead) | ⚠️ (agent-side via Agent SDK `.mcp.json` in container) | **0.19** ✅ (guard-mediated external-server registry: connection lifecycle, egress allowlist + per-call trust-boundary audit, per-server rate limits/token budgets/selective tool surfacing, namespaced tools on live `/mcp`) |
| Inbound read-only MCP clients (context-engine mode) | ✗ | ✗ | **0.25** ✅ named client tokens and guarded read-only dispatch; **0.27 working tree** advertises and permits exactly `context_research`, `kg_query` and `kg_timeline` over shared wiki/KG, refuses private memory and every write tool, and audits under `mcp-client:<name>` |
| Image generation | ✅ (plugin, 7 models via OpenRouter) | ✗ | **P4** (OpenRouter, FLUX/Gemini/GPT models) |
| Video provider | ✅ (Moonshot native video, 2026.2.23) | ✗ | ✗ |
| Image/PDF tools (channel) | ✗ | ✅ (`/add-image-vision`, `/add-pdf-reader` for WhatsApp — v1.2.6) | ✗ (tools run inside claude CLI) |
| Local model inference | ✗ | ✅ (`/add-ollama-tool`: Ollama MCP server for local inference) | ✗ |

---

## Web Search

| Feature | OpenClaw | NanoClaw | DartClaw Phase |
|---|---|---|---|
| Search providers | Brave (LLM Context mode), Perplexity (Search API, language/region/time filters), xAI/Grok, Moonshot/Kimi, Firecrawl (v2026.3.22: bundled plugin with `firecrawl_search` + `firecrawl_scrape` tools), Exa (v2026.3.22: bundled with date filters + search-mode selection + content extraction), Tavily (v2026.3.22: bundled with dedicated `tavily_search` + `tavily_extract` tools); provider derived from plugin contracts | ✗ (web tools inside container via SDK) | **0.2** ✅ (via dedicated search agent) |
| `unbrowse` visual browser | ✅ (visual element detection, 2026.2.6) | ✗ | ✗ |
| Browser automation | ✅ (Playwright, headless; Chrome DevTools MCP attach mode for signed-in sessions — v2026.3.13-beta.1) | ✗ | ✗ (tools run inside claude CLI) |

---

## Observability & Logging

| Feature | OpenClaw | NanoClaw | DartClaw Phase |
|---|---|---|---|
| Structured logging | ✅ | Minimal (`pino` + `pino-pretty`) | **0.2** ✅ (4 levels, session+turn correlation, JSON mode) |
| Sensitive data redaction | ✅ (`logging.redactSensitive`; `config.get` secret redaction, 2026.2.23) | ✅ (message content removed from info logs) | **0.2** ✅ (configurable `redactPatterns`) |
| `llm_input`/`llm_output` hooks | ✅ (2026.2.16) | ✗ | **P3** (for OTel + LangFuse) |
| PostToolUse audit hooks | ✅ | ✗ | **0.2** ✅ (name, duration, success/failure) |
| Health endpoint | ✅ (v2026.3.1: K8s-compatible liveness + readiness probes) | ✗ | **P2** (`/health`) |
| Per-session token/cost | ✅ (per-agent `cacheRetention` params, 2026.2.23; built-in per-turn usage footers v2026.7.1) | ✗ | **0.2** ✅ (input/output/total tokens + estimated cost); **0.16.4** canonical cross-harness `session_cost:*` schema (cache-weighted `effective_tokens`) |
| ObservabilitySink abstraction | ✗ | ✗ | **0.2** ✅ (abstract class with pluggable sinks) |
| OpenTelemetry export | ✗ | ✗ | **P3** (spans per turn, OTLP/gRPC + OTLP/HTTP) |
| LangFuse/LangSmith | ✗ | ✗ | **P3** (trace per turn) |
| Log rotation | ✅ (logrotate/newsyslog) | ✗ | **0.2** ✅ (newsyslog.d / logrotate configs) |
| Telegram token auto-redaction | ✅ (v2026.3.14: GHSA fix for token exposure in logged file URLs) | N/A | ✗ |
| Codebase token tracking | ✗ | ✅ (CI badge via `repo-tokens`: now 224k tokens, 112% of a context window — over-budget post-v2) | ✗ |
| Guard audit log (persistent) | ✅ (plugin hooks) | ✗ | **0.6** ✅ (`audit.ndjson` + web UI viewer on health dashboard, filterable + paginated) |
| Event bus (internal decoupling) | ✗ | ✗ | **0.7** ✅ (sealed class hierarchy, guard/config/session/task/agent events, `runZonedGuarded` error isolation) |
| Agent observability | ✗ | ✗ | **0.8** ✅ (`AgentObserver`: per-agent metrics, `GET /api/agents`, pool status, SSE state events) |
| Turn trace persistence | ✗ | ✗ | **0.14** ✅ (SQLite `turns` table: per-turn duration, token breakdown incl. cache read/write, tool call records, model/provider columns; `GET /api/traces` query API) |
| Task event sourcing | ✗ | ✗ | **0.14** ✅ (6-kind sealed `TaskEvent` enum, append-only `task_events` SQLite table, task timeline UI, live activity indicator, SSE `task_progress` events) |
| Per-session/channel cost attribution | ✗ (no native attribution — third-party ClaWatch/ClawMetry fill gap) | ✗ | **0.14** ✅ (per-turn cost via `TurnTraceService`; per-channel attribution not yet planned) |
| Behavioral drift detection | ✗ (no baseline mechanism — model updates cause undetectable behavioral changes; [Fiddler.ai analysis](https://www.fiddler.ai/blog/openclaw-ai-observability-gap)) | ✗ | ✗ (planned: [inspiration backlog](../INSPIRATION-BACKLOG.md)) |
| Per-channel behavioral monitoring | ✗ (same agent logic behaves differently per channel; no per-channel consistency tracking) | ✗ | ✗ (planned: [inspiration backlog](../INSPIRATION-BACKLOG.md)) |
| Context management intelligence | ✅ (ContextEngine plugin slot, v2026.3.7) | ✗ | **0.10** ✅ (compact instructions, `ExplorationSummarizer`, `ContextMonitor`) |

---

## Deployment

| Feature | OpenClaw | NanoClaw | DartClaw Phase |
|---|---|---|---|
| Single binary deployment | ✗ (npm global) | ✗ (clone + npm install + OneCLI gateway container) | **0.2** ✅ (AOT binary + `claude` CLI); **0.18** versioned checksummed macOS/Linux assets + Homebrew; **0.20.1** ✅ embedded text assets; **0.21** ✅ native Windows x64 zip with bundled FTS5 SQLite plus PowerShell/Scoop install paths |
| DigitalOcean 1-click | ✅ (2026.2.1) | ✗ | ✗ |
| Docker containerized gateway | ✅ | ✗ (host orchestrator) | **0.2** ✅ |
| Per-agent containers | ✅ (configurable scope; dangerous Docker config rejected, 2026.2.16) | ✅ (per-group, always-on; Docker default since 2026-02-20; Docker Sandboxes micro VM since 2026-03-13) | **0.2** ✅ on POSIX; **0.21** native Windows unavailable (fails closed; use POSIX/WSL); **0.25** default posture on POSIX where a runtime exists (auto-detection never runs on native Windows) |
| Custom sandbox images | ✅ (Dockerfile, base images; SHA-256 hashing, 2026.2.16) | ✗ | **0.2** ✅ (pre-built images) |
| Network egress control | ✅ (Docker network + pf/nftables) | ✗ | **0.2** ✅ (pf/nftables + `network:none`) |
| Multi-gateway profiles | ✅ (`--profile`, port spacing) | ✗ | **0.2** ✅ (profiles + port spacing) |
| Multi-user (OS users) | ✅ (separate OS users) | ✗ | **P5** (UID-enforced boundaries) |
| LaunchAgent/systemd | ✅ | ✗ | **0.16.2** ✅ (`dartclaw service install/start/stop/status/uninstall` — user-scoped LaunchAgent on macOS, `systemd --user` on Linux, no root required, instance-scoped units) |
| Tailscale integration | ✅ (Serve/Funnel) | ✗ | **P5** |
| VM isolation (Lume/Multipass) | ✅ (macOS only) | ✅ (Docker Sandboxes = hypervisor micro VM, docs now on `channels` branch, validated macOS + WhatsApp only; Apple Container retired v2.1.17 — broken on v2) | **P5** |
| OrbStack support | ✗ | ✗ | **0.2** ✅ (macOS Docker alternative) |
| Build system | npm (`tsdown` + `tsgo`, 2026.1.30) | Node.js 22 (`.nvmrc`); cross-platform setup scripts | Native `dart build cli` (AOT + native assets) for macOS arm64/x64, Linux x64/arm64, and Windows x64 |
| Startup time | ✅ (improved ~40%, 2026.2.1) | N/A | N/A (AOT binary = fast startup) |
| Multi-language support | ✅ (12 languages, 2026.2.1; multilingual stop words, 2026.2.24) | ✅ (Chinese README) | ✗ |
| Kubernetes support | ✅ (v2026.3.12: raw manifests, Kind setup, deployment docs, health probes) | ✗ | ✗ |
| Docker Sandbox micro VM | ✗ | ✅ (v1.2.14: Host→Sandbox VM→NanoClaw→Docker-in-Docker→agent containers; in v2 documented as manual setup on the `channels` branch, validated macOS Apple Silicon + WhatsApp only) | ✗ |
| CLI container targeting | ✅ (v2026.3.24: `--container` / `OPENCLAW_CONTAINER` to run commands inside Docker/Podman container) | ✗ | ✗ |

---

## Computer Use

| Feature | OpenClaw | NanoClaw | DartClaw Phase |
|---|---|---|---|
| VM tools (screenshot, click, type, etc.) | ✅ (7 `vm_*` tools via Lume) | ✗ | **P5** (same 7 tools via Lume WebSocket) |
| Shared directory VM ↔ host | ✅ | ✗ | **P5** |
| Browser automation (Playwright) | ✅ (headless, managed profile; `unbrowse` visual, 2026.2.6; Chrome DevTools MCP attach mode v2026.3.13; 3 profile types: openclaw-managed/remote CDP/existing-session; stable ref-ID system from accessibility snapshots) | ✗ | ✗ (tools run inside claude CLI) |

---

## Third-Party Integrations

| Feature | OpenClaw | NanoClaw | DartClaw Phase |
|---|---|---|---|
| Calendar integration | ✅ (recurring events, 2026.2.3) | ✗ | ✗ |
| Home Assistant | ✅ (2026.2.1) | ✗ | ✗ |
| Gmail | ✗ | ✅ (skill: `/add-gmail`, refactored) | ✗ |
| Qodo (code intelligence + PR review) | ✗ | ✅ (`/get-qodo-rules`, `/qodo-pr-resolver`, 2026-02-23) | ✗ |
| Parallel AI | ✗ | ✗ (`/add-parallel` retired v2.1.17) | ✗ |
| Ollama (local models) | ✅ (v2026.3.12: provider-plugin, local/cloud+local modes, browser sign-in) | ✅ (tool skill `/add-ollama-tool` v1.2.4; v2 also as per-group agent provider) | ✗ |

---

## Unique to Each Project (Updated)

### OpenClaw Only
- Multi-provider LLM support (35+ providers including Anthropic Vertex AI, Chutes, Xiaomi MiMo, MiniMax M2.7, GPT-5.4/5.4-mini/5.4-nano, Ollama first-class)
- OpenAI-compatible API (`/v1/chat/completions`)
- Full plugin system (hooks, tools, RPC, HTTP, CLI, background services; Context Engine plugin slot)
- ClawHub skill marketplace (820+ malicious skills found — security incident, auto-load disabled)
- 16+ messaging channels (including Microsoft Teams via official SDK, Feishu/Lark with docx/reactions, Zalo rebuilt, iMessage, Matrix via official SDK)
- Browser automation (Playwright + `unbrowse` + Chrome DevTools MCP attach mode)
- Canvas visual presentations
- WebSocket protocol v3
- 8-layer tool policy cascade
- 1M context (now standard for Max/Team/Enterprise)
- Model fallback chain traversal
- Android native app (node commands: camera, contacts, calendar, motion, notifications)
- iOS Home Canvas (live agent overview, docked toolbar, model picker, gateway recovery)
- DigitalOcean 1-click deployment + Kubernetes support
- Multi-language FTS (5 additional languages) + Ollama embeddings
- Session disk budget controls
- Workflow recording/replay
- QMD backend (experimental neural reranking)
- Video provider support (Moonshot)
- Auto-updater (`update.auto.*`)
- Shell completion (4 shells)
- Multilingual stop/abort keywords (9 languages)
- Multi-user trust heuristic detection
- Bootstrap file caching (per-session key)
- Subagent context guard (preemptive)
- Calendar + Home Assistant integrations
- `sessions_yield` orchestration primitive (end turn + hidden follow-up)
- External secrets management (`openclaw secrets audit/configure/apply/reload`)
- Fast Mode per-session toggle
- Control UI v2 (modular dashboard, command palette, search, slash commands, pinned messages)
- CLI backup & restore with manifest validation
- ACP thread-bound agents and session resumption
- Exec approval hardening (Unicode spoofing, shell-flag escapes, interpreter unwrapping)
- 288 security advisories (largest coordinated security release batch in the project's history)
- PDF tool (native Anthropic + Google PDF providers)
- Diffs tool (read-only diff rendering with canvas/PNG output)
- `/btw` side-channel query (non-context-mutating inline question, v2026.3.22)
- Lobster workflow engine (YAML pipelines, approval gates, resume tokens, sub-lobsters)
- Compaction lifecycle events (`session:compact:before`/`after` with metadata)
- Ollama embeddings for memory search (v2026.3.2)
- Bootstrap-token-only QR pairing (short-lived, no shared credentials, v2026.3.22)
- Plugin `prependSystemContext`/`appendSystemContext` for provider-cacheable static guidance
- `requestHeartbeatNow()` plugin API for immediate agent wakeup
- Firecrawl, Exa, Tavily as bundled web-search plugins with dedicated tools
- Audio transcription API for plugins (`api.runtime.stt.transcribeAudioFile()`)
- Anthropic Vertex AI provider (`anthropic-vertex`)
- Microsoft Teams channel (official SDK, AI-agent UX best practices, streaming replies, welcome cards)
- Plugin SDK overhaul (`openclaw/plugin-sdk/*` with testing surface; bundle compatibility: Codex/Claude/Cursor)
- Pluggable sandbox backends (SSH + OpenShell `mirror`/`remote` modes — beyond Docker-only)
- Agent default timeout 48h (up from 600s)
- Skills management UI (status tabs, install recipes, requirements display, API key entry)
- `config set` expansion (SecretRef/provider builder, JSON/batch, `--dry-run`)
- CLI container targeting (`--container` for Docker/Podman)
- Discord auto-thread naming (LLM-generated titles)
- Health monitor per-channel overrides (stale-event thresholds, restart limits)
- Memory plugin self-registration of system-prompt sections
- Build-tool JVM/env injection blocking (MAVEN_OPTS, SBT_OPTS, GLIBC_TUNABLES, etc.)
- Nostr DM channel with pre-crypto rate guards
- OpenAI-compatible API layer (Gateway as drop-in proxy for RAG clients, v2026.3.24)
- Cron named persistent sessions (`session:custom-id` maintains context across cron runs)
- Formal security verification documentation
- .NET community port (`openclaw.net`, NativeAOT-friendly)
- Workboard agent-coordination tool (track/hand off active agent work, v2026.5.28)
- `openclaw attach` (external harness attachment to a running Gateway session, v2026.7.1)
- ClawRouter bundled provider plugin (credential-scoped dynamic model discovery, budget reporting, v2026.7.1)
- Unified SQLite background-task ledger (ACP/subagent/cron/background CLI runs, v2026.4–6.x)
- Governed skill/plugin install policy (fail-closed on critical dangerous-code findings, v2026.3.31→6.2)
- `on-exit` cron schedule kind + detachable session-targeted cron runs (v2026.7.1)
- Per-turn usage footers for cost accounting (v2026.7.1)
- GitHub Copilot agent runtime (v2026.5.28)

### NanoClaw Only
- Minimal-config philosophy retained in v2 (`.env` + `versions.json` + optional per-group `container.json`; behavior config in SQLite via `ncl` CLI — no longer literally zero config files)
- AI-native setup/debug flow (no wizards, no dashboards — "describe problems to Claude")
- Skills-as-branches model, matured in v2 (trunk = registry/infra; `channels` + `providers` branches; `/add-<name>` installs; community marketplaces; "Flavors" concept unverified in v2)
- **48 skill dirs** on `main` + **44** on `channels` (counting basis changed with v2 — many are provider/tool-add skills like `add-codex`, `add-rtk`, `add-mnemon`)
- OneCLI local gateway (credential vault + egress proxy at `127.0.0.1:10254`, per-request secret injection — container never sees raw keys; replaces the v1.2.12 host credential proxy)
- Per-group multi-provider selection (Claude default; Codex, OpenCode, Ollama providers — provider is a per-group DB property)
- Opt-in per-group egress lockdown (network allowlisting)
- Channel instances as a first-class dimension (multiple credentialed instances of one channel kind)
- Agent templates (`ncl groups create --template`, public `nanoclaw-templates` library)
- Native uninstaller (`uninstall.sh` / `--uninstall`) + raw-route webhook registry
- Docker Sandboxes (hypervisor-level micro VM: Host→Sandbox VM→NanoClaw→Docker-in-Docker→agent containers; v2: manual-setup docs on `channels` branch, validated macOS + WhatsApp only)
- Agent Swarms via Anthropic SDK native support
- Per-group IPC namespace isolation (prevents privilege escalation)
- Dedicated phone number support for WhatsApp
- Qodo AI partnership (first third-party skills ecosystem)
- Codebase token tracking CI badge (`repo-tokens`: 224k tokens, 112% of context — over-budget post-v2)
- Gmail integration skill (X/Twitter skill retired v2.1.17)
- Sender allowlist (per-group permitted sender list, v1.2.3)
- Timezone-aware context injection (host timezone in agent context, UTC rejection, v1.2.9)
- WhatsApp emoji reactions skill, image vision skill, PDF reader skill
- Local Whisper transcription (whisper.cpp, no OpenAI API needed)
- 30,180 GitHub stars (+31% since Mar 2026)

### DartClaw Only
- AOT-compiled Dart binary (zero npm, zero Node.js at runtime)
- 2-layer architecture: Dart host → native `claude` binary (bidirectional JSONL control protocol)
- MCP memory server (agent uses standard MCP tools for memory operations)
- Built-in HTMX + SSE web UI (zero JS build toolchain, no separate dashboard process)
- **0.26** built-in hybrid memory/conversation search using SQLite FTS5 plus Dart cosine ranking or PostgreSQL text search plus pgvector
- Daily auto-logs (turn summaries written automatically after each turn)
- Behavior file cascade (global → project level, concatenated)
- `dartclaw doctor --fix` dependency validation
- `dartclaw rebuild-index` search maintenance
- Planned Flutter desktop/mobile app (P5)
- ObservabilitySink abstraction (pluggable sinks)
- Planned native OpenTelemetry + LangFuse integration (P3)
- Configuration via single `dartclaw.yaml` with env var substitution
- Task orchestrator with structured review flows (9-state lifecycle, parallel execution, coding worktrees)
- HarnessPool for concurrent agent execution (configurable `maxConcurrent`, ACP-compatible interface)
- Per-security-profile container dispatch (workspace vs restricted, collision-free naming)
- PageRegistry + `registerDashboardPage()` SDK extensibility
- Lightweight typed event bus (~15 LOC, sealed class hierarchy, zero deps)
- Configurable session scoping (5 DM + 3 group modes, per-channel overrides)
- Session maintenance (pruning, count cap, disk budget, CLI cleanup)
- 3 messaging channels with unified access control (WhatsApp, Signal, Google Chat)
- Cross-compilation to linux/arm64 via Dart 3.9 `--target-os`/`--target-arch`
- Channel-to-task integration ("fix the login bug" from WhatsApp → full task with review → accept from phone, 0.9)
- Package decomposition (~12 composable packages, SDK publish-ready, 0.9)
- Design system implementation (7-level surface ladder, hue-aware shadows, container taxonomy, 0.10)
- Context management intelligence (compact instructions, ExplorationSummarizer, ContextMonitor, 0.10)
- `CLAUDE_CODE_SIMPLE` restricted session hardening (disables MCP/hooks/CLAUDE.md in restricted containers, 0.10)
- Immutable system prompt architecture (behavior files host-managed, not agent-writable — eliminates SOUL.md persistence attack class)
- Google Chat Cards v2 (structured task notifications, interactive Accept/Reject buttons, 0.9)
- Crowd coding governance (per-sender + global rate limiting, daily token budgets with warn/block, loop detection with 3 heuristics, emergency /stop /pause /resume — 0.12)
- Thread binding (channel-agnostic `(channelType, threadId) → (taskId, sessionKey)` routing with auto-unbind and idle timeout — 0.12)
- Multi-provider heterogeneous HarnessPool (Claude + Codex, per-task provider selection, canonical tool taxonomy — 0.13)
- Multi-project support (config-seeded + API-managed project registry, auto-clone, auto-fetch before worktree, push-to-remote + PR creation, per-project credentials, implicit `_local` backward compat — 0.14)
- Turn trace persistence (per-turn duration, token breakdown incl. cache, tool call records, model/provider columns, query API — 0.14)
- Task event sourcing (7-kind sealed events after 0.16 compaction events, timeline UI, live activity + progress indicators, SSE streaming — 0.14/0.16)
- Crowd-coding model routing (crowd-coding defaults + scope/channel/task override chain — 0.14.3)
- Queue fairness (sender-aware debounce, per-sender queue caps, fair drain order — 0.14.3)
- Cross-channel task binding (multiple channel conversations bound to one task session — 0.14.3)
- ~~Advisor observer (structured canvas/channel insights from an EventBus-driven meta-agent — 0.14.3)~~ — **removed in 0.25**; the Workflow Orchestration Agent (ADR-044, `0.next-workflow-track` slice 1) is the designed successor for run supervision
- Compaction observability (provider compaction events, task timeline compaction markers, identifier-preserving compaction instructions — 0.16)
- Live config Tier 3 (ConfigNotifier + Reconfigurable services, SIGUSR1/file-watch reload triggers, immediate apply for reloadable config fields — 0.16)
- System alert-routing primitives (explicit alert targets, severity formatting, per-target cooldown + burst summary logic — 0.16)
- Guard hot-reload (atomic guard-chain rebuild on `guards.*` changes, invalid config preserves existing chain — 0.16)
- Harness hardening refresh (Claude `PermissionDenied` / `PreCompact` hooks, `if:` hook filtering, Codex v0.118.0 compatibility audit, Anthropic SDK 1.4.2 schema audit — 0.16)
- Workflow engine hybrid steps (bash host execution, approval gates, session continuity, built-in workflow packs, progressive disclosure — 0.16.1)
- CLI onboarding wizard (`dartclaw init` Quick-track + Full-track, interactive TUI + `--non-interactive`, unified instance directory, `DARTCLAW_HOME`, safe rerun with current-value defaults — 0.16.2)
- Background service management (`dartclaw service install|start|stop|status|uninstall`, user-scoped LaunchAgent/systemd --user, instance-scoped units, no root — 0.16.2)
- Setup verification and launch handoff (local + network verification, `--skip-verify` for air-gapped, `--launch foreground|background|service|skip` — 0.16.2)
- Architecture hygiene + standalone binary build system (unified `dartclaw_workflow` package, workflow workspace isolation, built-in skill library with materialization + FNV-1a fingerprinting, `tool/build.sh` AOT build, architecture fitness functions in `tool/arch_check.dart` — 0.16.3; the 0.16.3 external asset archives were replaced by fully embedded binary assets in 0.20.1, ADR-047)
- Connected-by-default CLI workflow execution (`DartclawApiClient` foundation, server-backed `workflow run/status/pause/resume/cancel` with SSE lifecycle, `--standalone` fallback with safety guard against running server, structured `--json` lifecycle events for CI — 0.16.4)
- Operational CLI command groups (`agents`, `config`, `jobs`, `projects`, `tasks`, `traces`, expanded `sessions` for remote inspection and lifecycle operations — 0.16.4)
- Workflow trigger surfaces (web launch forms on `/workflows`, `/workflow` chat commands, GitHub PR webhooks that start `code-review` — 0.16.4)
- Local-path projects (`projects.<id>.localPath` binds to existing on-disk checkout, `projects.allowApiLocalPath` + `projects.localPathAllowlist` access control, dirty/branch-mismatch preflight, optional `branch:` with HEAD inference — 0.16.4)
- Workflow control structures + per-story sub-pipelines (first-class `foreach` and `story-pipeline` with item-level crash recovery and per-item resume fidelity, dependency-aware fan-out via `id` + `dependencies` — 0.16.4)
- Workflow worktree + publish pipeline (per-story worktrees, deterministic branch promotion/merge semantics, explicit project auth + GitHub token delivery, workflow-owned publish path producing `publish.pr_url` — 0.16.4)
- File-based artifact transport with auto-commit (`dartclaw-prd`/`dartclaw-plan`/`dartclaw-spec` skills write to disk and emit paths, `gitStrategy.artifacts.commit: true` lands artifacts on the workflow branch before per-map-item worktrees, `gitStrategy.worktree.externalArtifactMount` for cross-clone visibility — 0.16.4)
- Generalized step-level `entryGate` (skip-on-false semantic with `StepSkippedEvent` available on all step kinds, previously loop-only — 0.16.4)
- Auto-framed context inputs (engine wraps unreferenced `inputs` / variables in XML tags during prompt assembly, `auto_frame_context: false` opts out — 0.16.4)
- Skill frontmatter `workflow:` defaults (`workflow.default_prompt` and `workflow.default_outputs` on SKILL.md replace per-skill `agents/openai.yaml` files — 0.16.4)
- `workflow show [--resolved] [--step <id>]` (CLI + server endpoint emitting fully merged workflow as round-trippable YAML for debugging — 0.16.4)
- Closed workflow step-type vocabulary (`agent|bash|approval|foreach|loop`; omitted `type:` defaults to `agent`; semantic values + per-step `project:` / `review:` removed — 0.16.4 ADR-024)
- Canonical `inputs:` / `outputs:` step-IO declaration (replaces `contextInputs:` / `contextOutputs:`; `outputs:` map keys are the only context-write declaration; `OutputConfig.setValue` literal slot with sentinel-backed null vs unset round-trip — 0.16.4)
- Workflow structured outputs default to native mode (`format: json` + `schema` resolves to provider-enforced output by default; inline-first happy path promotes valid `<workflow-context>` payloads without an extra extraction turn — 0.16.4)
- AndThen as runtime prerequisite (ADR-025/S81: AndThen-derived skills cloned and provisioned at `dartclaw serve` startup under `dartclaw-` namespace by `SkillProvisioner` via native user-tier harness installs: `install-skills.sh --prefix dartclaw- --display-brand DartClaw --claude-user`; configurable `andthen.git_url`/`ref`/`network`; replaces in-tree skill porting and the retired data-dir/install-scope model — 0.16.4; **the clone/install mechanism itself was retired in 0.17 by ADR-040**, and its residual `andthen:` config keys were deprecated in 0.25)
- Agent-resolved-merge bundle (`gitStrategy.merge_resolve` block + `dartclaw-merge-resolve` skill: LLM-driven semantic conflict resolution loop with all-or-nothing commit, retry/cleanup/`fail` and `serialize-remaining` escalation, structured per-attempt artifact persistence, lock-spanning resolver attempts via `runResolverAttemptUnderLock`, cross-harness via the `!` bang operator — 0.16.4)
- `AgentExecution` primitive decomposition (ADR-021: shared session/provider/model/token-budget metadata extracted into `agent_executions` + `workflow_step_executions` tables; atomic AE+WSE+Task creation; five CI-enforced fitness functions; new `GET /api/agent-executions/events` SSE stream — 0.16.4)
- Engine-managed runtime artifacts (`{{workflow.runtime_artifacts_dir}}` resolves to `<data_dir>/workflows/runs/<runId>/runtime-artifacts/`; built-in `dartclaw-review` steps pin reports to `<runtime_artifacts_dir>/reviews`; foreach merge-resolve attempts also unified under this namespace — 0.16.4)
- Token-tracking cross-harness consistency (canonical `session_cost:*` schema across interactive and workflow turns; `input_tokens` means fresh input everywhere; cache-weighted `effective_tokens` exposed as the cross-harness cost signal; Codex session info labels metric as `Input (fresh)` and shows cached separately — 0.16.4)
- Workflow E2E Dart integration test (real Codex harness drives `plan-and-implement` and `spec-and-implement` end-to-end with real git; asserts `publish.pr_url` resolves via `gh pr view` — 0.16.4)
- `WorkflowGitPort` + `RepoLock` + safe-process hardening (HIGH gap closure: pre-merge invariants, repo-level lock, `SafeProcess` wrapper for bash steps, centralized git subprocess env — 0.16.4)
- Filesystem-first structured-output extraction (path outputs resolve from `WorkflowGitPort.diffNameOnly`, mapped story specs preflight before agent launch — 0.16.4)
- Stimulus-on-HTMX interaction layer (14 `dc-*` controllers, vendored single-file runtime, zero-Node toolchain preserved — 0.16.6)
- Personalization onboarding (structured `USER.md` scaffold, web onboarding prompt, `dartclaw init --personalize` / `--apply-drafts` — 0.17)
- Durable knowledge loop (filesystem inbox ingestion → LLM wiki with provenance/search ranking/lint → temporal knowledge graph with MCP tools — 0.17)
- Guard-extension editor UI (YAML-backed CRUD, validation, tester verdicts, pending-restart status, admin-gated — 0.17)
- Rich chat composer (streaming stop/retry recovery, command-palette discovery, attachment + reference chips, durable rich-input metadata — 0.17)
- ACP universal agent harness (config-only agent onboarding, guard-mediated reverse calls through `GuardChain`, Goose + Mistral Vibe validated — 0.18)
- `delegate_to_agent` MCP delegation (allowlisted ACP/Codex, `guard_mediated`/`provider_approval` modes, strict vs post-run token budgets — 0.18)
- Provider-scoped harness pools + stuck-turn visibility with authorized early cancel (0.18)
- Versioned checksummed release assets + automated Homebrew tap publication (0.18)
- `context_research` cross-layer knowledge synthesis (citation-backed packets over memory + temporal KG + wiki, per-call freshness, ADR-042 – 0.19); the 0.27 working tree separates caller-private memory from shared wiki/KG and limits named clients to the shared component
- Guard-mediated outbound MCP client (egress allowlist, per-call trust-boundary audit, per-server rate/token governance, selective tool surfacing — 0.19)
- Read-only Knowledge UI (Knowledge Hub, research packets with source attribution, temporal KG timeline — 0.19)
- Afterglow design system (ambient ground, glass tiers, chart ramp, display type scale — 0.19)
- Framework-agnostic workflow engine with CI fitness gate (ADR-041 — 0.19)
- Zero-server standalone workflow CLI (cwd-local `.dartclaw/` auto-discovery, full lifecycle control, `--inline` git-strategy override, non-interactive approvals policy, provider auth preflight — 0.17/0.19)
- Workflow hardening (one-shot timeout backstops, live progress spinner with per-step token ticks, blocked-outcome semantics + settle-time digest, strict unknown-field YAML validation, reconciled promotion/publish under per-project lock — 0.20)
- Claude provider `approval`/`sandbox` config axes with explicit full-access opt-in (Codex parity — 0.20)
- Fully embedded binary assets — truly single-file agent runtime, no asset sidecar/download, CI drift gate (ADR-047 — 0.20.1)
- Agent-invocable interaction surface replacing chat grammars (`task_create`, `task_review`, `task_bind`/`task_unbind`, `workflow_run`, `schedule_upsert`, `attach_media`, `wiki_write` plus their listings, all on one guarded MCP dispatch seam with read/write classification and audit; the `task:` prefix parser, the accept/reject review grammar, the `/bind` and `/workflow` dialogs, the web-chat command intercept and the `MEDIA:` sentinel are deleted — 0.25)
- Context-engine mode: read-only MCP access for named non-owner clients over their own principal, refused at the same guarded seam that authorises the owner's writes (0.25)
- Container-by-default posture with an inferred/declared distinction — an inferred posture downgrades to advisory mode naming this host's reason while an explicit `true` keeps every fail-closed exit (ADR-055 — 0.25)
- Single config schema source: one field registry drives the parser, the validator, a published `dartclaw.schema.json` with a drift gate, the settings form and a generated 278-row configuration reference; an unregistered key refuses the boot (0.25)

---

## Phase Coverage Summary

DartClaw 0.21 implementation and current-version native Windows x64 candidate qualification are complete; version pin
and release/tag remain pending. The platform adds a native Windows core runtime and artifact with bundled FTS5 SQLite,
PowerShell/Scoop distribution paths, file-watch reload, hard-terminate lifecycle handling, Git Bash workflow steps, and
explicit unsupported/unverified boundaries for POSIX-coupled isolation, sidecars, and provider sandboxes.

| Phase | Focus | Key Additions | Competitive Position |
|---|---|---|---|
| **MVP** ✅ | Core runtime + storage + web UI | Agent runtime, NDJSON bridge, file storage, FTS5 search, memory MCP, HTMX web UI, REST API, CLI, AOT binary | Exceeds NanoClaw (web UI, search, MCP memory); partial OpenClaw |
| **0.2** ✅ | Security + infrastructure | Docker isolation, credential proxy, 3 guard plugins, WhatsApp, search agent, hybrid memory, cron, auth | Reaches OpenClaw parity on security model |
| **0.3** ✅ | Consolidation + quality | Template DX cleanup, crash recovery, SessionKey routing, WhatsApp E2E verification | Quality hardening milestone |
| **0.4** ✅ | Navigation + channels | Trellis templates, HTMX SPA navigation, search integration, Signal channel | Two messaging channels |
| **0.5** ✅ | Security hardening + intelligence | InputSanitizer (deleted in 0.25), MessageRedactor, ContentClassifier, self-improvement files, memory pruning, MCP foundation, cookbook | Exceeds NanoClaw on security depth |
| **0.6** ✅ | Config + observability | Config editing UI, graceful restart, guard audit log + UI, memory dashboard, MCP tools (web_fetch, search), package split | Full config editing parity |
| **0.7** ✅ | Session management + decoupling | Configurable session scoping, session maintenance, channel access UI, lightweight event bus | Exceeds OpenClaw on session scoping configurability |
| **0.8** ✅ | Task orchestration + parallelism | Task model, harness pool, container dispatch, coding worktrees, task dashboard, Google Chat | Unique: parallel task execution + structured review flows |
| **0.9** ✅ | SDK decomposition + channel-to-task | Package decomposition (6→~12 packages), SDK publish prep, SDK docs, channel-to-task integration, Google Chat cards | Unique: "fix from phone" channel-to-task bridge |
| **0.9.1** ✅ | Config consistency | Unified scheduling config, per-job model overrides, session scope enum fixes | Quality patch |
| **0.10** ✅ | Design system + context intelligence | Design system CSS implementation, compact instructions, ExplorationSummarizer, ContextMonitor, CLAUDE_CODE_SIMPLE restricted sessions | Addresses OpenClaw's context/token waste (#9157) at architecture level |
| **0.10.1** ✅ | Implementation polish | Polish and bug fixes | — |
| **0.11** ✅ | Google Chat Space full participation | Pub/Sub pull client, Workspace Events subscriptions, message deduplication | Competitive differentiator: OpenClaw declined to implement this |
| **0.12** ✅ | Crowd coding (multi-user) | Thread binding, governance (rate limiting, token budgets, loop detection), emergency controls (/stop, /pause, /resume), sender attribution | Unique: multi-user collaborative AI steering via channel Spaces |
| **0.13** ✅ | Multi-provider harness | Codex app-server + exec harnesses, ProtocolAdapter abstraction, canonical tool taxonomy, heterogeneous HarnessPool, per-task provider override | No longer Claude-only; 2-provider architecture validated |
| **0.14** ✅ | Multi-project + task observability | Project registry (config-seeded + API-managed), auto-fetch before worktree, push-to-remote + PR creation, turn trace persistence, task event sourcing, task timeline UI, live progress indicators | Unique: formal project registry with auto-fetch — no competitor has per-project git config management |
| **0.14.3** ✅ | Crowd-coding intelligence | Model routing, sender-fair queueing, cross-channel task binding, advisor observer (removed in 0.25), crowd-coding docs refresh | Unique: facilitator-oriented multi-user steering with model control and structured observer feedback |
| **0.15** ✅ | Workflow platform | YAML workflow data model + parsing, workflow executor, API routes, management UI (sidebar + detail), auto-retry with loop detection | Unique: integrated YAML workflow engine — OpenClaw's Lobster is a separate repo; no competitor has built-in workflow orchestration with loop detection |
| **0.16** ✅ | Always-on foundation | Compaction observability, live config Tier 3, alert-routing infrastructure, guard-chain hot-reload, Claude hook hardening, Codex compatibility audit | Unique: compiled runtime with reloadable config, provider compaction signals, and explicit channel alert targets without introducing a separate control plane |
| **0.16.1** ✅ | Workflow engine hybrid steps | Bash host execution, approval gates, session continuity, built-in workflow packs (adversarial-dev, idea-to-pr, workflow-builder, comprehensive-pr-review), progressive disclosure | Extends workflow platform lead: hybrid steps enable deterministic host-side operations inside agent pipelines |
| **0.16.2** ✅ | CLI onboarding wizard | `dartclaw init` TUI wizard, unified instance directory, `DARTCLAW_HOME`, `dartclaw service` (LaunchAgent/systemd --user), verification + launch handoff, Full-track channel/security config | Closes first-run UX gap: guided setup comparable to NanoClaw's Docker Sandbox script but with interactive TUI + non-interactive parity |
| **0.16.3** ✅ | Architecture hygiene + standalone build | Unified `dartclaw_workflow` package, workflow workspace isolation with built-in `AGENTS.md` guardrails, built-in skill library (10 markdown skills with materialization + FNV-1a fingerprinting + `.dartclaw-managed` provenance), workflow architecture deep-dive doc, `tool/build.sh` AOT build with external asset archives + SHA256 checksums, architecture fitness functions in `tool/arch_check.dart`, CLI reference doc | Internal: package boundary cleanup unlocks the 0.16.4 workflow surface refactor |
| **0.16.4** ✅ | CLI Operations, Connected Workflows & Workflow Platform Hardening | Connected-by-default CLI workflow execution (`DartclawApiClient` + SSE), operational command groups (`agents`/`config`/`jobs`/`projects`/`tasks`/`traces`/expanded `sessions`), workflow trigger surfaces (web launch forms, `/workflow` chat, GitHub PR webhooks), redesigned `plan-and-implement` (per-story `story-pipeline` + `foreach` with worktree isolation and publish-step PR), file-based artifact transport with auto-commit + cross-clone mount, AndThen-as-runtime-prerequisite skill provisioning under `dartclaw-` namespace, agent-resolved-merge (`gitStrategy.merge_resolve` + `dartclaw-merge-resolve` skill), `AgentExecution` primitive decomposition, closed `agent|bash|approval|foreach|loop` step types, `inputs:`/`outputs:` rename, engine-managed runtime artifacts, local-path projects, token-tracking cross-harness consistency. 81 stories | Workflow platform now beats Lobster on integration depth: connected-by-default CLI, per-story worktrees, agent-resolved merge with deterministic retry/escalation, runtime-provisioned skill catalog, and a real-Codex E2E release gate. Closes the 2026-04-22 framework debt (`workflow_executor.dart` decomposition, `WorkflowGitPort`, repo-level `RepoLock`, `SafeProcess`, filesystem-first structured-output extraction) |
| **0.16.5** ✅ | Stabilisation & hardening | Zero new user-facing features: alert-classifier safety gap closed via compiler-enforced exhaustive switch over `sealed DartclawEvent`, 7 orphan sealed events wired to SSE + alerts, 13 CI governance checks (7 Level-1 + 6 Level-2), package-boundary extractions to canonical packages, `dartclaw_models` shrunk to a true shared kernel, Effective Dart renames, 13 tech-debt closures; ADR-023 workflow↔task boundary | Internal quality gate: compiler-enforced event exhaustiveness + CI fitness functions – engineering-maturity counterpoint to competitors' daily-release churn |
| **0.16.6** ✅ | Web UI Stimulus adoption | Stimulus-on-HTMX interaction layer: 14 `dc-*` controllers replace page-global IIFEs, HTMX swap re-init via `connect()`/`disconnect()`, vendored single-file Stimulus 3.2.1, CSP unchanged (no `unsafe-eval`), six legacy page scripts deleted | Maintainable browser interaction layer with zero-Node toolchain intact – no SPA build chain, unlike OpenClaw Control UI / ZeroClaw React |
| **0.17** ✅ | Personal AI & developer experience | Personalization onboarding (structured `USER.md` scaffold, `dartclaw init --personalize`), durable knowledge loop (filesystem inbox → wiki with provenance/ranking/lint → temporal KG MCP tools), guard-extension editor UI, SDK docs phase 2 + runnable examples, rich chat composer, zero-friction standalone workflow CLI (`init --workflow`), workflow engine reliability (stall detection, `foreach` resume, unified step retry) | Unique: provenance-backed wiki + temporal KG knowledge substrate – OpenClaw has a Memory Wiki but no temporal KG; NanoClaw has neither |
| **0.18** ✅ | Universal agent harness | First-party ACP harness (any ACP-compliant agent via config alone; Goose + Mistral Vibe verified), guard-mediated ACP reverse calls, `delegate_to_agent` MCP tool (security modes, token budgets), provider-scoped pools, stuck-turn status + early cancel, versioned release assets + automated Homebrew tap | Repositions DartClaw as universal agent orchestrator: guard-pipeline-mediated reverse calls have no competitor equivalent (OpenClaw ACP mediation is approval-based) |
| **0.19** ✅ | Context engine + outbound MCP + knowledge UI | `context_research` MCP synthesis over memory + temporal KG + wiki (citation-backed packets, ADR-042), guard-mediated outbound MCP client (egress allowlist, per-server governance, selective surfacing), read-only Knowledge UI on Afterglow design system, framework-agnostic workflow engine (ADR-041), standalone workflow lifecycle control + `--inline` override + approvals policy + provider auth preflight | Unique: citation-backed cross-layer knowledge synthesis; outbound MCP passes the runtime trust boundary (guards + audit) instead of agent-side MCP config |
| **0.20** ✅ | Workflow hardening, simplification & polish | One-shot timeout backstops, live CLI progress spinner with per-step token ticks, blocked-outcome semantics + settle-time digests, strict unknown-field YAML validation, registry-tier consolidation, reconciled connected/standalone promotion + publish under per-project lock, Claude `approval`/`sandbox` axes (Codex parity), YAGNI trim of inert workflow knobs | Workflow platform maturity: honest failure semantics + deterministic validation – deepens the integration lead over Lobster (separate repo, no engine-integrated worktree/merge pipeline) |
| **0.20.1** ✅ | Embedded binary assets | Built-in templates, static assets, skills, and workflow definitions compiled into the AOT binary (checked-in generated libraries, CI drift gate); asset resolution collapsed to explicit → source tree → embedded; `dartclaw assets` command, asset cache, and release assets tarball deleted (ADR-047) | Unique among lineage: truly single-file agent runtime — OpenClaw/NanoClaw both require npm/clone installs; also removes install-time network dependency and binary/asset version skew |
| **0.21** ✅ | Windows support and cross-platform hardening | Native Windows x64 release bundle with FTS5-enabled SQLite; typed platform capabilities; hard-terminate process lifecycle; file-watch reload; PowerShell/Scoop install paths; Git Bash workflow execution; current-version candidate native-x64 runtime/lifecycle qualification plus matching both-provider evidence; fail-closed container-isolation degradation | Native Windows core-runtime support with explicit, documented capability boundaries instead of silent POSIX assumptions |
| **0.24.3** ✅ | Trust boundaries and credential delivery | Strict schema-bound logical-agent output; one content-scan authority including public outbound-MCP results; owner-only named credential store; stdin-only `dartclaw secrets` commands; search-provider credential references; secret-location and permissions audit | Makes the quarantined-agent handoff enforceable while adding service-safe credential delivery without a vault dependency |
| **0.27 working tree** | Agent workspaces and chat/session experience | Derived identity-marked agent workspaces; principal-scoped memory; caller-private plus shared research; shared-only named MCP; durable drafts/submissions/history; effective context; stable inbox/attention/settle; conversation search, commands, temporary conversations and export | Focused managed-workspace, PostgreSQL, integration and served-browser checks exist on the dirty candidate. Physical device, owner, real-provider, named CI, Linux Docker, Windows artifact, release-check and exact clean-candidate qualification retain their holds, so this is not a shipped-release claim |

---

## Features DartClaw Does NOT Plan to Implement

| Feature | Why Not |
|---|---|
| ~~Multi-provider LLM~~ | ~~Claude-only by design~~ — **Shipped in 0.13**: Claude + OpenAI (Codex app-server + exec). Canonical tool taxonomy, heterogeneous pool, abstract ProtocolAdapter. Pi evaluated for future milestone (20+ providers via single integration) |
| OpenAI-compatible API | Not needed; native REST API sufficient |
| Plugin marketplace (ClawHub) | Skills via SDK + MCP servers instead (ClawHub security incident validates this) |
| General plugin system | Guard plugins + SDK extension points sufficient |
| Browser automation (Playwright) | Tools run inside `claude` CLI which handles its own tool execution |
| ~~Canvas / visual presentations~~ | ~~Not in scope~~ — **Shipped in 0.14.2**: shareable canvas, share-token auth, workshop templates (kanban + stats), admin panel |
| Android/iOS native app | Flutter covers both platforms in P5 |
| Video provider | Not in scope |
| Workflow recording/replay | Not in scope |
| QMD neural reranking | Built-in weighted-RRF hybrid search in 0.26; QMD remains deprecated during the transition |
| Apple Container | Docker only (simpler, cross-platform); Docker Sandboxes micro VM is the alternative hypervisor path |
| 15+ messaging channels | Core 3 (WhatsApp/Signal/Google Chat) + extensible channel interface; Telegram via channel interface |
| Multi-language FTS | **0.26**: PostgreSQL language-aware text search; SQLite retains unicode61 token matching |
| 1M context opt-in | Planned as SDK passthrough (now standard in Agent SDK for eligible plans) |

---

## Broader Landscape Comparison

> Detailed analysis: [competitor-analysis.md](competitor-analysis.md)

### Personal AI Agent Runtimes (Direct Competitors)

| | NanoClaw | ZeroClaw | PocketPaw | Praktor | OpenLegion | DartClaw |
|---|---|---|---|---|---|---|
| **Runtime** | Node.js/TS + OneCLI gateway (v2) | Rust (~8.8MB binary) | Python + Tauri desktop | Go + NATS | Python + LiteLLM | Dart (AOT) |
| **Stars** | 30.2k | ~29k | 618 | 13 | 69 | — |
| **Container isolation** | Per-group Docker + Docker Sandboxes micro VM option (Apple Container retired in v2) | None (Landlock/Bubblewrap) | None (app-layer Guardian AI) | Docker per agent | Docker or Sandbox microVM | Docker `network:none` |
| **Credential isolation** | OneCLI Agent Vault (per-request injection, v2) | ChaCha20 encrypted at rest | AES encrypted | AES vault, env inject | Mesh proxy (host-only) | Per-authority host adapter; no reusable container credential |
| **WhatsApp** | Yes (skill) | Yes (feature-gated) | Yes | No | Yes | Yes |
| **Memory** | Per-group CLAUDE.md | SQLite vector + FTS5 hybrid | Mem0 vector | SQLite + MCP | Per-agent | PostgreSQL lexical + optional pgvector hybrid for memory and conversations; managed workspace-local ownership on the 0.27 working tree |
| **Web UI** | None | React 19 SPA | Dashboard + Tauri desktop | Admin SPA | Dashboard | HTMX chat |
| **Multi-agent** | SDK Swarms | Hands (autonomous swarms) + SOPs | Multi-backend | NATS swarms | Multi-provider fleet | Multi-provider harness pool (Claude + Codex) |
| **Scheduling** | Cron (parallel) | Cron + SOP triggers (MQTT, webhook, peripheral) | NL scheduling | Cron/interval | Cron | Cron/interval/once |
| **LLM providers** | Claude default; Codex/OpenCode/Ollama per group (v2) | 28+ (Claude, OpenAI, Gemini, etc.) | 6 backends | Claude Agent SDK | 100+ (LiteLLM) | Claude + Codex + any ACP agent (0.18) |

### Adjacent Projects (Partial Overlap)

**Component-level reference, 2026-09-21:** [TypeSafe Jev](../research/typesafe-jev/research.md) supplies hosted typed semantic decisions and probabilities. Potential DartClaw uses are optional passage reranking, content classification and semantic watchlists; it does not replace memory, generative synthesis or orchestration. No integration or measured benefit is claimed.

| | Khoj | PAI | Open WebUI | OpenHands | Alfred | Proma |
|---|---|---|---|---|---|---|
| **Category** | Knowledge assistant | Claude Code config layer | Chat UI | Coding agent | Agentic infrastructure | Desktop AI + Agent Teams |
| **Stars** | 33.4k | 9.9k | 127k | 69.1k | 181 | 297 |
| **WhatsApp** | Yes | No | No | No | No | No (Feishu/Lark) |
| **Container isolation** | No | No | No | Docker (coding-scoped) | No | No |
| **Memory** | pgvector RAG (bi-encoder + reranker) + semantic long-term (v2.0.0-beta.25) | 3-tier markdown + TELOS v4.0 (12 categories, context halved) | Experimental KV | Session-only | Obsidian vault + Temporal workflows | Cross-session local |
| **Scheduling** | Cron + email | None | None | None | Temporal durable workflows | None |
| **Self-host stack** | Postgres + pgvector | `~/.claude/` files | Docker + SQLite/Postgres | Docker | Python + Temporal + OpenClaw/Zo backend | Local-first `~/.proma/` |
| **Notable new (Mar 2026)** | Pipali spinoff (desktop AI co-worker, 42 stars) | v4.0 "Lean and Mean" (context halved, 12 categories) | Open Terminal (file browser, Jupyter in chat) | Planning agent + task list UI | Pivot to "personal agentic infrastructure" + Temporal workflows | Agent Teams (auto-assembled), Feishu channel |

### Compiled-Language Security-Focused Entrants (Post-OpenClaw Crisis)

| | ZeroClaw | IronClaw | PicoClaw | NullClaw | Moltis |
|---|---|---|---|---|---|
| **Runtime** | Rust, ~8.8MB binary, Tokio async | Rust + WASM | Go, ~8MB binary | Zig, 678KB binary | Rust, 150k LOC |
| **Stars** | ~29k (v0.6.5, Mar 27) | — | 13k+ | — | — |
| **Cold start** | <10ms | — | Fast | Fast | — |
| **RAM (idle)** | <5MB (release); ~15MB (production) | — | <10MB | — | — |
| **Channels** | 25+ (Telegram, Discord, Slack, WhatsApp, Signal, iMessage, Matrix, IRC, Email, Bluesky, MQTT, DingTalk, Lark, QQ, Reddit, LinkedIn, X, Mattermost, Nextcloud, Nostr, WeChat Work, WATI, Notion, WebSocket) | — | Telegram (edge-focused) | — | 27 workspace crates |
| **LLM providers** | 28+ (Claude, OpenAI, Gemini, OpenRouter, Groq, DeepSeek, Bedrock, Ollama, vLLM, etc.) | — | Multi-provider | — | — |
| **Security** | 5-layer app-level: workspace-scoped FS, command allowlists, Landlock/Bubblewrap, ChaCha20-Poly1305 encrypted secrets, 6-digit OTP pairing, rate limiting | WASM sandbox per tool, zero-trust, TEE-backed execution, encrypted credential vault | Minimal | Minimal | Zero unsafe code, Prometheus/OTEL |
| **Memory** | SQLite vector + FTS5 hybrid (70/30 cosine/BM25), 10k LRU embedding cache | — | — | — | — |
| **Web UI** | React 19 + Vite 6 SPA (dashboard, chat, memory, config, cron, cost, logs, tools) | — | — | — | — |
| **Multi-agent** | Hands (autonomous swarms), delegate tool, SOPs (event-driven workflows) | — | — | — | — |
| **Identity** | AIEOS (psychology, linguistics, motivations) | — | — | — | — |
| **IoT/Hardware** | ESP32, STM32, Arduino firmware targets; MQTT | — | RISC-V/ARM/x86 | — | — |
| **Notable** | $5/month VPS; OpenClaw migration tool; marketplace templates; 129+ security CI tests | WebAssembly + Trusted Execution Environments | $10 edge hardware | Extreme minimalism | Voice I/O (8 TTS + 7 STT) |
| **DartClaw comparison** | Broader channel/LLM/IoT coverage, much lighter weight; no container isolation, no credential proxy, no structured task orchestration, no review flows, low test maturity (3 integration tests) | Strongest isolation model (WASM + TEE); no channels or memory | Edge deployment story DartClaw lacks; minimal security | Irrelevant | Voice is a differentiator DartClaw lacks |

### Other Emerging Entrants (Since Feb 2026)

| | GoGogot | FastClaw | OSA | Kai |
|---|---|---|---|---|
| **Runtime** | Go single binary | Go single binary | Elixir/OTP + Rust TUI | Kotlin (Android) |
| **Stars** | 136 | 3 | 20 | 189 |
| **Channel** | Telegram | Telegram (more coming) | Unspecified | Mobile-native |
| **Isolation** | None | None | Unknown | N/A (mobile app) |
| **Notable** | "OpenClaw alt in Go", no Docker | Mirrors DartClaw architecture in Go | Signal Theory classifier, 154k LOC | Native Android, multi-backend |

### DartClaw's Unique Position

No other surveyed project combines all of:
1. **OS-level container isolation** (Docker `network:none`, `--cap-drop=ALL`)
2. **Credential proxy** (API keys never in container env — Unix socket injection)
3. **WhatsApp messaging** with DM access control
4. **Persistent searchable memory** (FTS5 + hybrid opt-in)
5. **Cron scheduling** with isolated sessions
6. **AOT-compiled binary** (zero npm/Node.js — auditable supply chain)
7. **Parallel task execution** with structured review flows (no other surveyed project combines task orchestration with container-isolated security profiles)
8. **Multi-project support** with formal project registry, auto-fetch before worktree, and push-to-remote PR creation (no competitor has per-project git config management)
9. **Runtime governance** (per-sender rate limiting, daily token budgets, loop detection — neither OpenClaw nor NanoClaw has native inbound rate limiting)

**Competitive shifts since last update:**
- NanoClaw now has a credential proxy (v1.2.12) and Docker Sandboxes micro VMs — the isolation gap is narrowing. DartClaw's per-authority host mediation and guard pipeline remain differentiators, but NanoClaw's two-hypervisor-boundary model (Host→Sandbox VM→Docker-in-Docker) is now arguably stronger at the isolation layer
- OpenClaw's CVE cluster (Feb 2026: WebSocket token exfil, RCE, 820+ malicious ClawHub skills, 135k exposed instances) validates DartClaw's architecture — no WebSocket auth, no npm supply chain, no skill marketplace with untrusted code. Academic study: 83% sandbox escape success rate at baseline ([arxiv.org/abs/2603.10387](https://arxiv.org/abs/2603.10387))
- **ZeroClaw is the fastest-growing entrant** — 29k stars in ~6 weeks (Rust, <10ms cold start, <5MB RAM). Now the 2nd-largest personal AI assistant project by stars after OpenClaw. 25+ channels, 28+ LLM providers, React 19 web dashboard, AIEOS identity system, SOP event-driven workflows, IoT hardware peripherals (ESP32/STM32/Arduino), local Whisper STT + Piper TTS, ACP server mode, Tauri desktop app. $5/month VPS viable. Application-level security only (no container isolation, no credential proxy) — does not compete in DartClaw's security-hardened niche. Full analysis: `docs/research/zeroclaw-analysis/research.md`
- **Compiled-language runtimes are now a tier.** ZeroClaw (Rust, 29k) and IronClaw (Rust + WASM + TEE) demonstrate demand for non-Node.js runtimes. IronClaw's WASM per-tool sandboxing is the strongest isolation model surveyed
- OpenLegion is the most direct new competitor: container-isolated, credential vault, multi-channel, explicitly positioning against OpenClaw
- Go is emerging as the preferred language for new compiled-language entrants (GoGogot, FastClaw, PicoClaw) — but none have DartClaw's security depth
- Desktop clients are now a competitive front (PocketPaw Tauri, Proma, OSA) — DartClaw's Flutter app (P5) is well-positioned but not yet built
- **Claude Code Channels** launched as Anthropic's official response: MCP-based channel bridging, Telegram + Discord initially. Validates the "Claude CLI + messaging channels" product category
- **OpenClaw's observability gap** is a documented weakness ([Fiddler.ai analysis](https://www.fiddler.ai/blog/openclaw-ai-observability-gap)): no behavioral drift detection, no per-channel monitoring, no cost attribution. DartClaw's `AgentObserver` (0.8) and planned turn traces (0.next-projects) address this but behavioral baselines remain unbuilt
- **Market moment:** "OpenClaw alternative" is now a search attractor — 10+ repos self-describe this way. The Feb 2026 security crisis created active demand for hardened alternatives. Kaspersky called OpenClaw "the biggest insider threat of 2026"
- **2026-07 re-verification:** OpenClaw stable is now v2026.6.11 (382k stars, +12.8%); #13615 (rate limiting) and #11829 (API-key leak) both still open. NanoClaw underwent a **v2 architecture rewrite** (repo renamed to `nanocoai/nanoclaw`, v2.1.17): OneCLI gateway (credential vault + egress proxy), per-group multi-provider (Claude/Codex/OpenCode/Ollama), egress lockdown, skills split across `main`/`channels`/`providers` branches — and the codebase grew to 224k tokens, abandoning the fits-in-one-context claim. NanoClaw's "radical minimalism" framing is now largely historical; its multi-provider + gateway direction converges on DartClaw's 0.13/0.18 architecture
- **OpenClaw v2026.3.22–3.24 wave** (Mar 23–25): Massive release batch. Microsoft Teams channel (official SDK), pluggable sandbox backends shipped (SSH + OpenShell), `/btw` side-channel shipped, Plugin SDK overhaul (`openclaw/plugin-sdk/*`), 3 new bundled web search plugins (Exa, Tavily, Firecrawl), Anthropic Vertex AI provider, agent timeout raised to 48h, memory plugin self-registration, CLI `config set` expansion. OpenClaw's provider count now at 35+, channel count at 16+. The sandbox backend shipping is notable — it was previously unreleased and is now production. DartClaw's security model remains deeper (guard pipeline + credential-free per-authority host mediation), but the isolation options gap is widening
