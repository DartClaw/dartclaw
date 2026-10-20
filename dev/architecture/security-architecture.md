# DartClaw Security Architecture

How DartClaw contains an agent that can run shell commands: container isolation, the guard chain, credential mediation, access control, audit, content classification, and runtime governance (rate limits, token budgets, loop detection, emergency controls). It is the authority for those concerns. Harness protocols and turn lifecycle live in [control-protocol.md](control-protocol.md), package wiring in [system-architecture.md](system-architecture.md), stores in [data-model.md](data-model.md), and log/metric mechanics in [observability-operations-architecture.md](observability-operations-architecture.md).

**Current through**: 0.28.0

---

## Threat Model

DartClaw spawns provider CLI binaries (`claude`, `codex`) and ACP agent binaries that can run shell commands, edit files, and reach the network. The defenses below are layered so that no single bypass is fatal.

| Threat | Primary defense |
|--------|-----------------|
| **Prompt injection** via channels, web pages, search results, MCP results | `ContentScan`/`ContentGuard` on logical-agent results, search results, `web_fetch` bodies and `public` outbound MCP results. The guard chain and container bound what an injected instruction can do. Inbound channel text is not classified on arrival |
| **Command injection** (`rm -rf /`, fork bombs, shell escapes) | `CommandGuard` (best-effort regex), container isolation |
| **Data exfiltration** (curl POST, base64 pipes) | `NetworkGuard`, container `--network none`, `EgressGuard` for outbound MCP |
| **Credential theft** | Host-owned provider mediation (no credential in the container), `FileGuard`, mount scoping, `SafeProcess` env sanitization, `MessageRedactor` |
| **SSRF** from `web_fetch` or MCP | DNS-pinned address checks in `WebFetchTool`, `network_class: public` transport policy |
| **Unauthorized access** | `authMiddleware`, `/mcp` bearer resolution, channel DM/group gates, webhook signatures |
| **Supply chain** | No Node.js/npm in the host chain, minimal dependencies, pinned Codex binary with sha256 in the image |
| **Container escape** | `--cap-drop ALL`, read-only rootfs, `no-new-privileges`, non-root user |
| **Cross-agent contamination** | One container per execution authority, per-profile mounts |
| **Cost overrun, rate abuse, runaway loops** | Runtime governance: token budget, rate limits, loop detection ([Runtime Governance](#runtime-governance)) |
| **Provider-specific tool bypass** | Canonical tool taxonomy, fail-closed chain evaluation, provider-specific interception |
| **Cross-execution state reuse** | Immutable coordinator composition, exact provider/policy matching on reuse |
| **Overlapping replacement** | Confirmed root-process teardown or capacity quarantine before a replacement starts |

**Host filesystem assumption.** DartClaw trusts the host OS, runtime user, and filesystem. Agent-supplied paths and stable symlinks are validated at security boundaries, but host-side I/O does not resist a process that continuously swaps directory entries mid-operation. Atomic writes and runtime locks give crash consistency and cooperating-writer safety, not a hostile-filesystem sandbox.

---

## Defense-in-Depth Layers

[![Security: defense-in-depth layers](diagrams/security-layers.svg)](diagrams/security-layers.svg)

Layers fail independently: with a guard bypassed, `network:none` still blocks exfiltration and the credential never exists in the container.

### Pragmatic Mode (no container boundary)

When the resolved posture is disabled (`container.enabled: false`, or unset on a host where no runtime answered the startup probe), Layers 1 and 2 are absent and the guards are the only boundary. That suits a single operator on a trusted machine. An unset `container.enabled` means "isolate if this host can": `resolveContainerPosture` probes `docker` then `podman` (5 s per probe), never blocks startup, and downgrades every later refusal to a warning naming why this host is advisory. An explicit `container.enabled: true` keeps every refusal fail-closed ([ADR-055](../adrs/055-container-by-default-posture.md)).

On native Windows, container isolation is unavailable even with Docker installed (`PlatformCapabilities.containerIsolationAvailable`); `container.enabled: true` exits with an `UnsupportedCapabilityError` pointing to POSIX or WSL; an unset posture runs in advisory mode with that warning.

**Source**: `packages/dartclaw_runtime/lib/src/container/container_posture.dart`, `packages/dartclaw_runtime/lib/src/runtime/security_wiring.dart`

---

## Guard Pipeline

### Guard Interface and Verdicts

Every guard extends `Guard` (`name`, `category`, `evaluate(GuardContext) → GuardVerdict`, plus `evaluationBudget`, default 5 s, and an optional `onEvaluationTimeout`). Guards return a sealed `GuardVerdict` and must not throw.

| Verdict | Meaning | Chain effect |
|---------|---------|--------------|
| `GuardPass` | Safe | Continue |
| `GuardWarn(message)` | Suspicious, allowed | Reported, evaluation continues; the first warn is returned if nothing blocks |
| `GuardBlock(reason)` | Denied | Short-circuits, tool call or message is denied |

**Source**: `packages/dartclaw_kernel/lib/src/guard.dart`, `guard_verdict.dart`

### Hook Points and GuardContext

| Hook point | Evaluated | By |
|------------|-----------|----|
| `beforeToolCall` | Before a provider tool runs | Provider interception (see below), ACP reverse calls, inbound `/mcp` dispatch |
| `messageReceived` | Before a turn starts, on the user message | `TurnRunner` via `TurnGuardEvaluator` |
| `beforeAgentSend` | On the accumulated assistant response before persistence | `TurnRunner` via `TurnGuardEvaluator` |

No shipped chain guard acts on `messageReceived` or `beforeAgentSend`; both stay open for custom guards. `ContentGuard` is not in the chain: it is called directly at its sites ([Content Classification](#content-classification-and-redaction)).

`GuardContext` carries `hookPoint`, canonical `toolName`, `rawProviderToolName` (kept for audit), `toolInput`, `messageContent`, `agentId` (null = main agent), `source` (`channel`, `web`, `cron`), `sessionId`, `peerId`, and `timestamp`. Guards judge the canonical name; the raw provider name only reaches the audit record.

### Chain Execution and Composition

[![Security: guard chain and audit](diagrams/security-guard-chain.svg)](diagrams/security-guard-chain.svg)

```
for guard in [base guards (read live), then this chain's own guards]:
  verdict = guard.evaluate(ctx).timeout(guard.evaluationBudget)
  timeout → guard.onEvaluationTimeout(ctx) ?? failure verdict
  throw   → failure verdict            # failOpen ? warn : block (default block)
  warn/block → onVerdict(...)          # → GuardBlockEvent → audit
  block → return immediately
return first warn, else pass
```

`buildGuardsFromConfig` builds the base list `[CommandGuard, FileGuard, NetworkGuard, ToolPolicyGuard]` from `guards.*` (invalid regexes or conflicting file rules fail the build). `SecurityWiring` creates one base `GuardChain` and wires `onVerdict` to the EventBus. A guard registered through `DartclawServer.registerGuard` is appended after these.

Each runner (the fixed primary lane and every coordinator-created worker) evaluates `GuardChain.layered(base, [TaskToolFilterGuard])`. The base list is read live, so a reload reaches every runner while the execution-scoped filter survives. Coordinator construction inputs are immutable and the security profile must match on reuse; turn-scoped policy (allowed tools, read-only) is rebound from the active lease. Workflow workers opt into `denyEmptyAllowlist`: null inherits the harness surface, a nonempty list restricts, an empty list denies ordinary tool calls (also during finalization). With `guards.enabled: false` there is no base chain, but each runner still evaluates `ToolPolicyGuard` and its filter.

A composer that hands the runtime an already-built harness must layer the filter itself and pass the same instance as `taskToolFilterGuard` to `composeServerTurns` (package-local, `server_composition.dart`); a filter outside the evaluated chain is silently inert. Out-of-package hosts call `DartclawRuntime.build`, which does this for every runner.

Provider branching is confined to protocol adapters and composition. Security, scheduling, task, capacity, and observability code consume normalized provider identity and capability contracts.

### Guard Hot-Reload

`SecurityWiring` implements `Reconfigurable` (`watchKeys: security.*`, which covers the `guards:` YAML section). A reload rebuilds the base list from `delta.current.security` and swaps it atomically with `replaceGuards`. A failed rebuild logs and keeps the existing chain; a failed build at startup exits. `guards.enabled` turning false needs a restart. `MessageRedactor` reloads through a small `logging.*` adapter.

Caveat: `replaceGuards` replaces the whole base list, so guards added by `registerGuard` do not survive a reload.

**Source**: `packages/dartclaw_runtime/lib/src/security/guard_builder.dart`, `packages/dartclaw_runtime/lib/src/runtime/harness_wiring_guards.dart`, `packages/dartclaw_runtime/lib/src/server_composition.dart`

### Guard Summary

| Guard | Hook | Called from | Covers |
|-------|------|-------------|--------|
| `CommandGuard` | `beforeToolCall` | base chain | `shell` |
| `FileGuard` | `beforeToolCall` | base chain | `shell` path arguments, `file_read` (with Claude `Grep`/`Glob` search roots), `file_write`, `file_edit` |
| `NetworkGuard` | `beforeToolCall` | base chain | `shell` URLs and exfil patterns, `web_fetch` |
| `ToolPolicyGuard` | `beforeToolCall` | base chain | global deny binds every agent; agent deny/allow bind logical agents |
| `TaskToolFilterGuard` | `beforeToolCall` | per-runner layer | per-execution tool allowlist, read-only mode |
| `EgressGuard` | `outboundMcpToolsCall` | `OutboundMcpPool` | external MCP `tools/call` |
| `ContentGuard` | `beforeAgentSend` | `LogicalAgentSessionService`, search MCP tools | logical-agent results, search results |

[![Security: guard and content-scan call sites](diagrams/security-call-sites.svg)](diagrams/security-call-sites.svg)

Three seams run outside the chain. `OutboundMcpPool` evaluates `EgressGuard`, then per-server governance, then an awaited audit write, and only then dispatches ([Outbound MCP Egress](#outbound-mcp-egress)). `ContentGuard`, `WebFetchTool`, and a `public` outbound MCP result each call the one `ContentScan` ([Content Classification and Redaction](#content-classification-and-redaction)). `TurnRunner` evaluates the runner's chain at `messageReceived` and `beforeAgentSend` through `TurnGuardEvaluator`; a block fails the turn and stores a `[Blocked by guard: ...]` or `[Response blocked by guard: ...]` assistant note, and with no chain both hooks are skipped. `beforeAgentSend` also runs on the provider's error text when a turn fails.

---

## Canonical Tool Taxonomy

Provider adapters map native tool names to `CanonicalTool` before guard evaluation, so policy is provider-neutral. The enum (`canonical_tool.dart`) holds the built-ins and one entry per own-MCP tool.

| Canonical | Claude | Codex app-server |
|-----------|--------|------------------|
| `shell` | `Bash` | `command_execution` |
| `file_read` | `Read`, `Grep`, `Glob` | (no first-class read tool) |
| `file_write` | `Write`, `write_file` | `file_change` kind `create`/`add` or other |
| `file_edit` | `Edit`, `NotebookEdit`, `edit_file` | `file_change` kind `update`/`modify` |
| `web_fetch`, `web_search` | `WebFetch`, `WebSearch` | `web_search` |
| `mcp_call` | `mcp_*` | `mcp_tool_call` |
| own-MCP tools (`memory_*`, `task_*`, `workflow_*`, `wiki_write`, ...) | `mcp__dartclaw__<tool>` | `mcp_tool_call` with server `dartclaw` |

Third-party MCP tools and own tools missing from the registered inventory stay `mcp_call`. An unmapped native tool becomes `claude:<name>` or `codex:<item>` with a warning, and policy treats it as an exact literal. Denying `mcp_call` also denies own-MCP calls; allowing it does not grant them. Claude's `ToolSearch` discovery helper passes a closed allowlist (after deny checks), but discovered tools still need their own entry; the toolless sentinel dominates a mixed list.

ACP reverse calls map in the handler: `fs/read_text_file` to `file_read`, `fs/write_text_file` to `file_write`, bound to the active session and turn workspace. Calls outside an active turn fail closed. ACP terminal reverse calls are neither advertised nor executed.

**Source**: `packages/dartclaw_core/lib/src/harness/canonical_tool.dart`, `claude_protocol_adapter.dart`, `base_protocol_adapter.dart`, [ADR-016](../adrs/016-multi-provider-harness-architecture.md)

### Interception per Provider

Each provider exposes a different interception point; the chain attaches to whichever is trustworthy.

| Provider / mode | Mechanism | Boundary |
|-----------------|-----------|----------|
| Claude host, default | `--dangerously-skip-permissions` + `PreToolUse` hook | Hook runs the chain before every tool. `approval: never` selects `bypassPermissions` instead (refused under the `restricted` container profile) |
| Claude host, `permissionMode: dontAsk` | `--permission-mode dontAsk --permission-prompts none`, subprocess env scrub, hook | Native grants and the chain can each refuse without prompting; a CLI lacking the flag is refused before a turn |
| Claude `restricted` profile | `--permission-prompt-tool stdio`, hook | `can_use_tool` requests answered by the host |
| Codex app-server | `item/commandExecution`, `item/fileChange`, and MCP approval requests handled by `CodexHarness` | Approval response is the only interception point. `on-request` is the intended posture, `unless-allow-listed` (sent as `granular`) omits provider-safe operations, `never` removes the chain from tool execution. An omitted option inherits Codex config and is treated as unverified (serve warns when tool restrictions exist) |
| ACP direct, verified | Host-advertised `fs` reverse calls | Guard-mediated only after target validation proves the agent honors them |
| ACP relay or unverified | None trustworthy | Their only possible boundary is a container DartClaw cannot mediate for ACP, so registration is refused at startup; ACP runs on the host only |

The Claude hook is registered without a matcher so every built-in and dynamically named MCP call reaches the chain; the provider inventory is extensible and a static filter would let excluded names bypass policy. A hook exception denies the call, and an allowed call has `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` stripped from a Bash `env` input. The `initialize` handshake also registers `PostToolUse` (stdout audit only), `PermissionDenied` (feeds `ToolPermissionDeniedEvent`, audited as `guard: PermissionDenied`), and `PreCompact`. Host spawns scrub the environment (`includeParentEnvironment: false`, the three nesting variables removed) and inherit Claude's user/project/local setting sources unless `providers.claude.inherit_user_settings: false` adds `--setting-sources project` ([ADR-027](../adrs/027-claude-harness-setting-sources-default.md)); container spawns are unchanged by it. Protocol detail: [control-protocol.md](control-protocol.md).

### Execution Surfaces

The interception point follows the provider, never the dispatching surface. Interactive and channel turns, tasks, cron and system jobs, logical-agent sessions, and workflow steps all run on a `TurnRunner` with the layered chain, in `dartclaw serve` and in standalone `dartclaw workflow`. Blocked calls are audited identically; `guard_coverage_path_parity_integration_test.dart` proves it for one blocked shell command on the interactive and workflow paths (Claude host `PreToolUse`, container off).

Bounds that carry over: a Codex workflow step under `approval: never` is not host-intercepted, and nothing in `packages/dartclaw_runtime/lib/src` refuses an ACP provider on the workflow surface, so a step naming an ACP agent leases an ACP worker with reverse-call mediation only, not the host tool gate. Two paths sit outside runner surfaces: inbound `/mcp` dispatch (base chain only, no per-runner policy) and the content classifier's own provider spawn (no chain).

**Source**: `packages/dartclaw_core/lib/src/harness/claude_code_harness.dart`, `codex_harness.dart`, `packages/dartclaw_acp/lib/src/acp_reverse_call_handlers.dart`, `acp_container_admission.dart`

---

## Guard Implementations

### CommandGuard

Evaluates canonical `shell` calls. It matches regex categories against the command, a single-quote-stripped form, and a quote-normalized form, and checks each pipe segment's target.

| Category | Examples |
|----------|----------|
| Destructive | `rm -rf`/`-fr`/`--no-preserve-root`, `chmod 777/000/a+rwx`, `mkfs.`, `dd if=`, `> /dev/sd*` |
| Force | `git push --force`/`-f`, `git reset --hard`, `git clean -f` |
| Fork bomb | `:(){`, `\| : &` |
| Interpreter escape | `eval`, `bash/sh/zsh/dash -c`, `python -c`, `node -e`, `perl -e`, `ruby -e`, backticks, `xargs <interpreter>` |
| Blocked pipe target | `sh bash zsh dash python python3 perl ruby node sed` |

`guards.command.extra_blocked_patterns` extends the destructive list; `extra_blocked_pipe_targets` extends the pipe targets. `$(...)` is intentionally not blocked (the inner command is still scanned). Variable-expansion bypasses (`v=rm; $v -rf`), double quotes, and heredocs cannot be caught statically, so container isolation is the primary defense for that class.

**Source**: `packages/dartclaw_kernel/lib/src/command_guard.dart`

### FileGuard

Glob rules over resolved paths (home expansion, `cwd` join, symlink resolution through the longest existing ancestor, so `/var` and `/private/var` agree even for a path not created yet). It extracts paths from `file_read`/`file_write`/`file_edit` inputs and from shell commands (redirect targets, read/write/delete command vocabularies from `command_vocabulary.dart`, `sed -i`, `cp`/`mv` source and destination). A matching `allow` rule exempts the path from every other rule; otherwise the most restrictive matching rule wins.

Claude's `Grep` and `Glob` reach it as `file_read` and run `rg --hidden` under their `path` (the hook's `cwd` when absent; the Claude harness passes the hook `cwd` into the guarded input), so they read everything beneath it. FileGuard checks the root like a read, as Claude's own `Read` deny rules do: a search blocks when its root is, or lies inside, a `no_access` path. A protected file below an allowed root does not block it; Glob's `pattern` and Grep's `glob` and content `pattern` are not read as paths. Search enumeration is left to the harness-native deny rules and OS sandbox, with FileGuard as the harness-neutral floor (ADR-061).

| Level | Read | Write | Delete |
|-------|------|-------|--------|
| `no_access` | blocked | blocked | blocked |
| `read_only` | allowed | blocked | blocked |
| `no_delete` | allowed | allowed | blocked |
| `allow` | allowed | allowed | allowed |

Defaults: `no_access` for `**/.ssh`, `**/.gnupg`, `**/.aws/credentials`, `**/.netrc`, and for the credential files of ADR-061 (`**/.env`, `**/.env.*`, `**/*.pem`, `**/*.p12`, `**/*.pfx`, `**/id_rsa*`, `**/id_dsa*`, `**/id_ecdsa*`, `**/id_ed25519*`), with `allow` for `**/.env.example`, `.sample`, `.template`, `.dist`; `read_only` for `**/*.key`, `**/.kube/config`; `no_delete` for `**/.gitconfig`, `**/.bashrc`, `**/.zshrc`, `**/.profile`. `withDataDirProtection` adds `no_access` rules for `<data_dir>/dartclaw.yaml`, `<data_dir>/gateway_token` and `<data_dir>/credentials/**`, anchored on the symlink-resolved data dir; a config loaded from elsewhere is not covered. `guards.file.extra_rules` adds more (`pattern`, `level`); an `allow` rule there re-admits a default path.

**Source**: `packages/dartclaw_kernel/lib/src/file_guard.dart`

### NetworkGuard

Evaluates `shell` (exfil patterns, then every `http(s)://`, `git@`, and `docker pull` registry host in the command) and `web_fetch` (the `url`). Any literal IPv4 or IPv6 host is blocked; other hosts must match the allowlist (`*.x` matches subdomains only, so list the apex separately).

Default allowlist: `github.com`, `*.github.com`, `api.anthropic.com`, `pypi.org`, `*.pypi.org`, `npmjs.com`, `*.npmjs.com`, `registry.npmjs.org`, `pub.dev`, `*.pub.dev`, `*.googleapis.com`, `dart.dev`, `*.dart.dev`, `crates.io`, `rubygems.org`, `stackoverflow.com`. Default exfil patterns: `curl ... | sh|bash|zsh|dash`, `wget -O - | sh|bash`, `curl` with `-d/--data*/-F/--form`, and `| base64`. `guards.network.extra_allowed_domains` and `extra_exfil_patterns` extend them; `guards.network.agent_overrides.<agent>.extra_domains` grants domains only when `GuardContext.agentId` matches.

**Source**: `packages/dartclaw_kernel/lib/src/network_guard.dart`

### ToolPolicyGuard

Wraps `ToolPolicyCascade`; most restrictive wins:

1. Global deny (`agent.disallowed_tools`): blocked for every agent, the main agent included.
2. Agent deny: blocked for that logical agent.
3. Agent allow (sandbox): when non-empty, a closed set.

The main agent has no identity, so only layer 1 binds it. Provider-native names in policy entries are canonicalized at construction (`Bash` to `shell`); unknown entries stay literal. `TurnRunner` passes the logical-agent identity through `AgentHarness.turn`; Claude hooks, Codex approvals, ACP bindings, and the `/mcp` seam attach it to `GuardContext`. The search agent's sandbox is `{web_search, web_fetch}` on the provider-independent `restricted` worker profile with an exact provider capacity lease. Where container profiles are unavailable, this policy is the only host boundary (Codex `on-request` interception is the broadest; ACP covers only host reverse file calls and permission requests).

**Source**: `packages/dartclaw_core/lib/src/agents/tool_policy_cascade.dart`

### TaskToolFilterGuard

Per-execution tool allowlist and read-only mode, rebound each turn by the lease. `null` allowlist is unrestricted; an empty list is closed only under `denyEmptyAllowlist`; session-local overrides win over the runner-wide list. Claude's `Skill`, `ToolSearch`, and (with an active output schema) `StructuredOutput` helpers pass.

Read-only mode blocks `file_write`, `file_edit`, `memory_apply`, `memory_observe`, and every shell command not proven read-only: shell admission is an allowlist (`readOnlyShellCommands` and read-only git subcommands in `command_vocabulary.dart`), and a redirect, command substitution, env-assignment prefix, `sudo`, or unreadable command blocks. Workflow agent steps use `configJson.readOnly = true` plus a post-turn `git status` check against the task worktree (`TaskReadOnlyGuard`); ordinary restricted tasks need an authenticated operator declaration.

**Source**: `packages/dartclaw_kernel/lib/src/task_tool_filter_guard.dart`, `packages/dartclaw_runtime/lib/src/task/task_read_only_guard.dart`

---

## MCP Trust Boundaries

### Outbound MCP Egress

The outbound MCP client consumes configured external servers over stdio or HTTP. Dispatch is default-deny ([ADR-039](../adrs/039-outbound-mcp-trust-boundary-and-transport.md)). `OutboundMcpPool.callTool`:

1. Builds an `OutboundMcpGuardRequest` (server, tool, arguments, caller).
2. `EgressGuard` (`hookPoint: outboundMcpToolsCall`) checks the per-server `allow_tools` list; unknown server or tool blocks. `surface_tools` only controls harness-facing tool visibility.
3. Per-server governance: `rate_limit.calls`/`window_seconds`, `token_budget.tokens`/`window_seconds`.
4. A guard audit entry is written before dispatch, and denials are audited too. A throwing guard or audit write fails the call closed (`Egress denied: guard/audit failure`).
5. For `network_class: public`, the result passes through `ContentScan`. Usage is charged first (the server served the call; a budget counting only delivered content would never bound a blocked server). Text over `guards.content.max_bytes` is denied before any classifier call, since prefix-scan-and-pass would leave the bulk unscanned. `local`/`private` servers and failed calls are not scanned; a null `ContentScan` means classification is not configured.

Content denials share the egress path on purpose: `guard: EgressGuard`, `hook: outbound_mcp_tools_call`, `error.code: egress_denied`; the reason string discriminates (`Content blocked: classified as <label>`, `Content classification failed (fail-closed)`, `Content blocked: result exceeds guards.content.max_bytes (<cap> bytes)`, the configured cap, never the attacker-influenced length). A blocked call writes one pass entry (egress) and one block entry (content). Outbound entries add `server`, `tool`, `decision`, `principal` (falls back to the caller's `sessionId` when no principal is set), `sessionId`, `credentialRef`.

Known limitation: tools reached through the live `/mcp` adapter use system attribution (`sessionId: system`, `principal: system`, `_systemOutboundMcpCaller` in `service_wiring_mcp_tools.dart`); treat those rows as runtime-owned outbound activity, not a per-session trace.

**Transport rules.** HTTP requires HTTPS; plain HTTP is accepted only for literal loopback (`localhost`, `127.0.0.1`, `::1`, via the kernel `isLoopbackHost`, no DNS resolution). A plain-HTTP loopback endpoint is unauthenticated: a configured credential travels in cleartext and another local user could bind the port first, so the runtime warns and a stdio server is preferable. `network_class: public` applies the `web_fetch` blocked-range/DNS policy to the configured target before sending a body and refuses redirects. Stdio servers are external code started only from configured entries. Their credential is injected through `SafeProcess`/`EnvPolicy` under the variable names the credential declares, never argv, inherited env, logs, or audit (which keep only the reference); a credential without a declared variable name fails closed.

**Source**: `packages/dartclaw_runtime/lib/src/mcp/outbound/outbound_mcp_pool.dart`, `packages/dartclaw_kernel/lib/src/egress_guard.dart`

### Inbound MCP Dispatch

`McpProtocolHandler` evaluates the composition root's base chain at `beforeToolCall` for every `tools/call` and writes one `AuditEntry` per dispatch on both verdicts (`hook: mcp_tool_call`), after caller-policy authorization and schema validation and before the tool runs. One interception covers every registered tool, so a new tool cannot be forgotten. The entry carries tool, decision, the tool's read/write class, and the principal: the authenticated client's authority id, or `system` (`mcpStewardPrincipal`) when the transport authenticates the deployment rather than a caller. Nothing in the request payload participates. The guard sees the canonical name (a scoped view carries the registered-name to canonical map its policy authorizes by), with the registered name on `rawProviderToolName`.

Fail-closed: a block returns a tool error (`isError: true`, not a JSON-RPC error); a throwing evaluator or failed audit write refuses the call without running the tool. Policy denial, unknown tool, and schema rejection answer earlier and are not recorded twice. Coverage is the base chain only: `TaskToolFilterGuard` is per runner and MCP dispatch has no runner, so session read-only mode and per-task allowlists do not apply here. `kg_invalidate` keeps its own fact-ownership check on top.

**Source**: `packages/dartclaw_runtime/lib/src/mcp/mcp_server.dart`

---

## Container Isolation

### Lifecycle and Flags

With the resolved posture enabled, every container execution gets its own container, created per authority (`<runtime> create` + `start`, `sleep infinity`) and entered with `<runtime> exec` per turn. The binary is whichever of `docker`/`podman` answered the probe, carried on `ContainerConfig.runtimeBinary`. A temporary conversation uses `run --rm -i -a stdin ... cat` with a tmpfs generated-state mount instead, so nothing lands on disk.

```
docker create --name dartclaw-<fnv1a8(dataDir)>-<profile>-<epoch><n> \
  --label dartclaw.data-dir=<data dir> \
  --network none --cap-drop ALL --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=100m --security-opt no-new-privileges \
  -v <workspace>:/workspace:rw          # workspace profile
  -v <project>:/project:ro  -v <clones dir>:/projects:ro   # workspace profile; local-path projects mount /projects/<id>:ro
  -v <bridge binary>:/opt/dartclaw/dartclaw-bridge:ro
  -v <data dir>/containers/<name>:/home/dartclaw/.dartclaw:rw   # per-authority generated state
  -v <artifacts dir>:/artifacts:rw      # only with an artifacts contract
  -e ANTHROPIC_BASE_URL=http://127.0.0.1:<provider bridge port>
  dartclaw-agent:latest sleep infinity
```

`start()` is single-use: a lost container is not recreated (its bridges died with it), the execution must acquire a new authority (`ContainerAuthorityLostException`).

**Image** (`docker/Dockerfile`): `debian:bookworm-slim` with `ca-certificates`, `curl`, `git`, non-root `dartclaw` (uid 1000). Claude CLI comes from the official installer; Codex from a pinned release archive whose per-architecture sha256 is verified, with `codex --version` run at build. The image ships no provider home; containerized Codex always gets a generated, auth-clean one.

**Source**: `packages/dartclaw_runtime/lib/src/container/container_manager.dart`, `container_posture.dart`

### Profiles and Authorities

A profile ([ADR-012](../adrs/012-per-type-container-isolation.md)) is a template of mounts, network, and capabilities. Each execution owner receives its own container, so concurrent owners never share a PID, `/tmp`, or generated-home namespace.

| Profile | Mounts | Used by |
|---------|--------|---------|
| `workspace` | `/workspace:rw`, `/project:ro`, `/projects:ro` (configured named agents: their workspace and the admitted directory at `/project:ro` only) | Owner and named-agent chats, default tasks, cron |
| `restricted` | none, working dir `/tmp` | Search agent, explicitly declared tasks |

Lifetimes: a logical-agent container spans that owner's turns; an ordinary task container spans its turn; a workflow worker holds one authority for the whole step. A container authority is granted only to a provider whose container execution DartClaw mediates, which excludes every ACP registration. Task dispatch defaults to `workspace`; the authenticated HTTP task API may declare `workspace` or `restricted`; channel and model-facing task creation cannot declare a profile, and the `research` category is refused so the restricted boundary cannot be widened silently.

Names use a deterministic FNV-1a digest of the exact data-dir string plus a per-process epoch and counter. The digest only disambiguates names, never ownership (the label carries the data dir verbatim); each data dir must have one server. The primary harness starts after server composition and MCP registration, and task polling and scheduling activate only after it and the post-MCP hook succeed.

**Source**: `packages/dartclaw_runtime/lib/src/container/security_profile.dart`, `packages/dartclaw_runtime/lib/src/execution_policy_resolver.dart`

### Execution Capacity

Governance admission runs inside `ExecutionCoordinator.acquire` before lane selection ([Runtime Governance](#admission-sequence)). The coordinator alone chooses the fixed primary lane (main-agent user and channel turns) or a provider worker lease (cron, tasks, logical agents, workflow steps).

`providers.<id>.pool_size` (0 or unset means 2) bounds concurrent worker executions per provider, excluding the primary lane; it is not a count of trusted processes. A request carries the normalized provider and one complete execution policy (host, or container plus profile), and workflow requests also carry the artifacts directory and spawn variables fixed at worker construction. Reuse order: exact session for that provider and policy, then any healthy host worker with the same provider and policy, else fresh. Any workflow-surface request, and any request carrying `allowedTools`, `artifactsDir` or spawn variables, gets a single-use worker that is never cached (`hasExecutionScopedConstructionInputs`: a harness's tool grants, mounts and environment are fixed at construction, and workflow workers get default provider-native tools even when no policy is set); a logical-agent container additionally needs the exact agent principal. Host and container workers, and workers of different profiles, are never interchangeable. A mismatch or unknown health means fresh. `WorkerCapacityGate` tracks `quarantinedCount` (slots withheld after an unconfirmed teardown) and admits against `effectiveCapacity = configuredCapacity - quarantinedCount`.

Unhealthy released workers are stopped and disposed, and no replacement starts until teardown of the managed root process is confirmed; otherwise the slot is quarantined and effective capacity drops ([ADR-058](../adrs/058-report-quarantined-workers-truthfully.md)). That keeps a failed termination from turning one slot into several live security principals. Task containers end with the turn, a containerized workflow step's authority ends with the step, and destruction confirms root-process termination, revokes authority-scoped resources, then removes the container and deletes its generated state (even when removal fails; release then stays retryable). Lease state, not retained process presence, is authoritative for active execution and emergency cancellation.

**Source**: `packages/dartclaw_runtime/lib/src/execution_coordinator.dart`, `worker_capacity_gate.dart`

### Provider Sandbox Interaction

When Docker is the boundary, Codex app-server uses `danger-full-access` (enforced in code for containerized spawns) to avoid double-sandboxing, with approvals still on. On the host DartClaw sends a sandbox mode only when `providers.codex.sandbox` sets one, and that mode replaces the operator's Codex permission profile and its read denies for the thread; unset, Codex applies the profile its loaded config selects. The DartClaw-dedicated subscription home carries the operator's `default_permissions` selector and `[permissions.*]` tables over with the plugin mirror; the `use_system_codex_home: false` temp home and the container home carry none. With `sandbox: workspace-write`, task worktrees add `writable_roots` anchored to the worktree plus the agent's workspace grant. Read-only policy stays enforced by the task guard path. Claude's native sandbox is unavailable and restrictive Codex sandbox modes are unverified on native Windows; use POSIX or WSL.

### Managed Workspaces and Temporary Conversations

A named agent's managed workspace is `data_dir/agents/<id>/workspace`; the host validates the exact id-only `identity.json` in its parent home before wiring storage or execution. Workspace-profile containers mount only the workspace child at `/workspace` (the parent home and marker are absent) plus the admitted execution directory at `/project`, with no checkout, clones-root, or unrelated project mounts. Cached workers must match that directory, and the same directory supplies Claude's additional-directory skill root and Codex's `.agents/skills` root. Required container confinement refuses execution when the profile is unavailable. On unrestricted host execution, declared writable roots and tool grants are not OS isolation: the same-user provider process may reach neighboring host paths.

A process-retained temporary conversation gets a dedicated temporary authority only when the capability inventory matches the mediated container provider and workspace policy. Its session, messages, attachments, usage context, generated provider home, browser draft, and replay state stay out of durable stores; projection observers exclude it from lexical and vector indexes; contextual memory, wiki, and KG write tools refuse it; daily-log capture and knowledge-inbox intake omit it; audit and process logs keep only opaque metadata. Ending marks the session ending, confirms turn and root-process termination, destroys the container, clears process state, then revokes the link; failed confirmation leaves an auditable retryable state. Provider-side processing and authorized external tool effects are outside this guarantee.

Research source scope is authenticated independently of placement: owner calls get owner personal memory, named agents only their pinned personal-memory principal (when `context_research` is policy-allowed), named MCP clients shared-only; all see the published wiki and temporal KG, never the knowledge inbox or other principals.

### Health and Reclamation

`ContainerManager.ownedContainers` lists all states with `ps -a --filter label=dartclaw.data-dir=<data dir>`; `reclaimOwnedContainers` removes each and its generated state with a warning. `SecurityWiring` runs it after the boot probe (before image checks) and after lease cleanup on shutdown. Runtime calls time out at 5 s and failures warn without failing wiring. `serve` forces exit when shutdown exceeds 10 s, which can interrupt the shutdown reclaim; the next boot's reclaim removes what remains. There is no periodic or prefix sweep, and unlabelled pre-release leaks need manual removal.

`ContainerHealthMonitor` polls every watched authority container (10 s, 5 s per check). `docker inspect` failures yield `unknown`, which holds the last state rather than reading as a crash. Transitions fire `ContainerCrashedEvent` and `ContainerStartedEvent`, attributed to the execution's task. An authority is unwatched before teardown so a normal release is never reported as a crash.

**Source**: `packages/dartclaw_runtime/lib/src/container/container_health_monitor.dart`, `runtime/security_wiring.dart`

---

## Credential Security

### Host-Owned Provider Mediation

The agent needs provider API access but must never hold the credential. The host runs a `HostGateway`; every live container authority registers with it and receives one bridge pipe per surface (`provider`, plus `mcp` when it was granted host MCP tools). The pipe, not any frame the container sends, determines principal, upstream, credential, and tool policy.

[![Security: host-owned credential mediation](diagrams/security-host-gateway.svg)](diagrams/security-host-gateway.svg)

- The only host objects mediation adds are the read-only bridge binary, the per-authority generated-state directory (the container home), and a host-owned `/artifacts` for executions with an artifacts contract. There is no socket mount, published port, or network attachment.
- Provider credentials never exist in the container's environment, filesystem, arguments, or generated configuration. The Claude container env carries only a placeholder key.
- Each adapter pins its upstream origin and request paths (`/v1/messages`, `/v1/messages/count_tokens`; `/v1/responses`), and there is no knob to retarget a credentialed adapter.
- Authority is execution-scoped. Release revokes the pipes, deletes generated state, and destroys the container; revocation is permanent, so a captured pipe cannot be revived. Release order: unwatch, revoke while the container still exists, destroy.
- Host-side refusals fire a `GuardBlockEvent` (`guard: host-gateway`, `hook: bridge`) into the normal audit trail. A container execution whose adapter has no host credential is refused at registration, before any container exists; a credential that turns unusable mid-turn tears the authority down.
- Provider-side network tools (web search/fetch, remote MCP connectors) are refused host-side for every containerized execution, because they run at the provider where `network:none` cannot contain them. Each adapter counts them in its protocol shape; an undecodable request body is refused ([ADR-052](../adrs/052-native-provider-web-tools-denied-all-container-profiles.md)).

[![Security: container authority lifecycle](diagrams/security-authority-lifecycle.svg)](diagrams/security-authority-lifecycle.svg)

Acquisition is `SecurityWiring.acquireContainerAuthority`: `authority.ready` must complete within 30 s of the bridges starting or the authority is released, since startup is local process work and a turn never runs on a partial boundary. Release runs identically on success, failure, cancellation, and quarantine: a failed revoke is logged and destroy still runs, and a destroy whose removal cannot be confirmed rethrows so release stays retryable. `ContainerStoppedEvent` fires only after removal is confirmed.

The boundary is POSIX-only; there is no weaker native-Windows credential transport.

**Source**: `packages/dartclaw_runtime/lib/src/container/gateway/` (`host_gateway.dart`, `provider_adapter.dart`), [ADR-051](../adrs/051-container-bridge-binary-packaging.md)

### Provider Authentication

Subscription authentication is the default on both boundaries; an API key is the alternative. `providers.<id>.auth` is `auto` (default: subscription when stored, else API key), `subscription`, or `api_key` ([ADR-053](../adrs/053-subscription-default-provider-authentication.md)). `CredentialRegistry.resolve` yields exactly one `CredentialResolution` per authority and never falls back across modes.

| Provider | Host | Container |
|----------|------|-----------|
| Claude, subscription | Stored `setup-token` as `CLAUDE_CODE_OAUTH_TOKEN` in the sanitized spawn env | Adapter sets `authorization: Bearer <setup-token>` and `anthropic-beta: oauth-2025-04-20` |
| Codex, subscription | Dedicated `CODEX_HOME` under `<data_dir>/credentials/codex`; the vendor CLI refreshes it | Adapter re-pins upstream to `https://chatgpt.com/backend-api/codex` (`/v1/responses` mapped to `/responses`), sets `authorization: Bearer`, `chatgpt-account-id`, `originator: codex_cli_rs` |
| Either, API key | Injected into the harness subprocess env | Claude `x-api-key` at `api.anthropic.com`; Codex `authorization: Bearer` at `api.openai.com` |

The Anthropic adapter picks its header from `CredentialResolution.mode` alone, so an upstream refusal of the raw Bearer fails the turn and never downgrades to a key.

Resolution details: an alias with no `auth` inherits its family's value, an explicit per-alias value (including `auto`) wins, so code rebuilding a `ProviderEntry` copies `auth` verbatim. An unrecognized value parses to `ProviderAuth.unrecognized`, is a blocking load warning, and presents no credential; `ProviderValidator` turns that into a `serve` exit for the default provider and a warning for a secondary, and a hot reload introducing it is rejected. Env fallback is `ANTHROPIC_API_KEY` (Claude) and `CODEX_API_KEY`/`OPENAI_API_KEY` (Codex). `credentialRemediationFor` is the single author of refusal text for container admission, the validator gate, and workflow worker admission. ACP registrations resolve no credential: `harness.acp.agents.<id>.credential` names a `credentials.<name>` API-key entry injected under the env var names it captured, and `SafeProcess.sanitize` still strips the agent's inherited `*_API_KEY`/`*_TOKEN`.

**Stores.** `SubscriptionCredentialStore.open` is the only construction seam: `0700` directories, Claude token written `0600` via `secureWriteFileSync`, and a refusal at open when a dedicated path resolves onto an operator login store (`~/.claude`, `~/.codex`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME`). The dedicated Codex host home mirrors `[plugins.*]` config, `plugins/cache`, and `skills` from the operator home via `completeDedicatedCodexHome` (also used by probe lanes) and never copies `auth.json`; payload symlinks are skipped and every source, destination, staging, and swap path must stay within its home. Container Codex homes get neither mirror nor auth: they are created fresh per execution in the authority's generated-state directory and deleted on stop, crash, cancellation, and failed startup. That is load-bearing, since a logged-in Codex forwards its saved bearer to a custom provider even with client auth disabled. `NamedCredentialStore` (`<data_dir>/credentials/named/<name>.json`) holds named API keys and GitHub tokens with the same `0700`/`0600`, collision-refusal, and atomic-replace boundary, overlaying a same-named YAML credential on every load. It is not an encrypted vault. `dartclaw secrets audit` is network- and value-free and reports literals, unresolved references, shadowed entries, orphans, and loose modes.

**Rejection classification (Codex only).** `classifyCodexRejection` separates `authExpired` (401), `usageLimit` (429 or usage marker), `contractBreak` (auth-scheme marker under any other status), and `modelUnsupported`. Status is read first and outranks body text, since a plan limit must never tell an operator to log in again; `usageLimit` and `modelUnsupported` map to no credential health. There is no Anthropic equivalent.

**Refresh.** `CodexRefreshAuthority` is the single-flight, per-store refresher: concurrent callers join one in-flight pass, which drives `codex app-server` (`codex_vendor_refresh.dart`) and then re-reads the store to judge the outcome. DartClaw never builds a token request itself.

**Health.** `CredentialHealthMonitor` probes once at wiring and hourly (built-in `credential-health` job), emitting transition-only `CredentialHealthChangedEvent`s consumed by `AlertRouter` and shown on `/settings` and `GET /api/providers`. Renewal deadlines are derived: Claude is ingestion time plus the 365-day `setup-token` lifetime; Codex is the store's last write plus an 8-day staleness window (not the access token's minutes-scale `exp`). A Claude provider on the vendor CLI's own login classifies `unknown` (`probeAuthStatus` can prove it is live); Codex's probe only proves `auth.json` parses, so that position classifies `reauthRequired`.

**Source**: `packages/dartclaw_kernel/lib/src/credential_registry.dart`, `packages/dartclaw_core/lib/src/storage/subscription_credential_store.dart`, `named_credential_store.dart`, `packages/dartclaw_runtime/lib/src/alerts/credential_health_monitor.dart`, `codex_rejection.dart`

### Database Connection Egress

A PostgreSQL connection is trusted host-side egress like a git operation: the storage layer opens it from operator configuration, agent tools cannot choose its destination or run queries through it, so it sits outside `EgressGuard`.

An active configuration accepts exactly one reference: `database.url` with an environment-substituted DSN (normally `${DARTCLAW_DATABASE_URL}`), or `database.credential` naming an existing generic API-key credential whose secret is the DSN. An inline password in a persisted URL, both references, or neither is refused at load; an unset variable or an absent, empty, or wrong-typed credential fails by reference name before any connection. The resolved DSN stays in memory, `/api/config` and `dartclaw config show` render a URL as `***`, typed storage exceptions and audit entries are built from allow-listed safe fields, and `MessageRedactor` covers DSN forms as defense in depth.

Posture is evaluated before a pool or socket exists. Only `postgres`/`postgresql` URIs are accepted. For a non-loopback host, omitted `sslmode`, `verify-full`, and `verify-ca` all verify certificate and hostname (`verify-ca` is upgraded because the driver has no separate mode); `sslmode=disable` is refused; `sslmode=require` is an accepted operator choice that encrypts without verification, so `verify-full` stays the recommendation. Loopback uses the kernel literal-only predicate (`localhost`, `127.0.0.1`, `::1`): with no `sslmode` the driver's encrypted `require` default applies and an explicit `disable` is allowed for a local server without TLS. Chain-trust and hostname/validity failures surface as separate safe errors; raw driver text is discarded.

Lifecycle records go through `GuardAuditLogger`: `guard: DatabaseEgress`, `hook: connection`, with `verdict`/`decision` `allow`/`open`, `allow`/`close`, or `deny`/`auth_failure`. Each carries only `host:port/database` and `credentialRef`; an audit-write failure while opening aborts the open.

Use two PostgreSQL roles: an administrator provisions the database, runtime role, and DartClaw-owned schema, and one least-privilege runtime role connects. DartClaw does not switch roles; startup warns once when the runtime role is a superuser. This is guidance, not enforcement ([ADR-060](../adrs/060-postgresql-only-storage.md)).

**Source**: `packages/dartclaw_kernel/lib/src/database_config.dart`, `packages/dartclaw_core/lib/src/storage/postgres_connection_posture.dart`, `postgres_backend.dart`

### Git Credentials

`projects:` config references credentials by name; the credential store holds the secret and `projects.json` keeps only the reference, so rotation never touches project config. `resolveGitCredentialPlan` builds a per-command `GitCredentialPlan` (non-interactive baseline: `GIT_TERMINAL_PROMPT=0`, the credential helper disabled) and clone, fetch, and push run on the host in `Isolate.run`, outside the container and the mediated provider path.

| Transport | Injected |
|-----------|----------|
| SSH | `GIT_SSH_COMMAND=ssh -i <key> -o BatchMode=yes -o StrictHostKeyChecking=accept-new` |
| HTTPS (GitHub token) | Remote rewritten to canonical HTTPS; `GIT_ASKPASS` script answers `x-access-token` and the token |
| HTTPS (other) | `GIT_ASKPASS` script that prints the secret |

Known limitation: the askpass scripts read the secret from a helper file in `<data_dir>/projects/` (`.git-askpass-<ref>.key|.token`) written with the process's default permissions. The project service and push service delete these files at `dispose()` (shutdown), the workflow git port after each operation. Protect the data directory accordingly.

**Source**: `packages/dartclaw_runtime/lib/src/task/git_credential_env.dart`, `project/project_service_impl.dart`, `task/remote_push_service.dart`

### Subprocess Hygiene and Git Runner

Sensitive workflow and git paths run through `SafeProcess` (`dartclaw_kernel`). `start`/`run` require an explicit `EnvPolicy` and always set `includeParentEnvironment: false`. `EnvPolicy.sanitize` strips `*_API_KEY`, `*_SECRET`, `*_TOKEN`, `*_CREDENTIAL(S)`, `*_PASSWORD` before an optional allowlist; workflow bash steps use it with `security.bash_step.env_allowlist` (default: `PATH`, `HOME`, `LANG`, `LC_*`, `TZ`, `USER`, `SHELL`, `TERM`) and `extra_strip_patterns`. Workflow harness workers receive an explicit sanitized spawn environment through the same contract.

Every production git subprocess goes through `runGit(...)` (`packages/dartclaw_kernel/lib/src/process/git_runner.dart`), the only production caller of `SafeProcess.git`; `dev/fitness/test/safe_process_usage_test.dart` fails the build on a direct call anywhere under `packages/*/lib` or `apps/*/lib`. `EnvPolicy.credentialPlan` keeps the git-safe baseline, strips parent secrets, and overlays the caller's `ProcessEnvironmentPlan`. `noSystemConfig: true` is the default (`GIT_CONFIG_NOSYSTEM=1`), so a new call site cannot inherit the unsafe posture by omission: worktree setup/cleanup, the task-accept commit path, the workflow git port, workflow-orchestrated checkouts, and CLI workflow git calls take it, because system-level filter drivers or hooks would otherwise run inside DartClaw's automation.

The opt-outs are explicit at the call site: `DiffGenerator` (review diffs must match the operator's own git), `ProjectServiceImpl` clone/fetch and `RemotePushService` push (remote transport needs `insteadOf`, proxy, and `sshCommand`), `WorkflowWorktreeBinder`'s non-workflow checkout, `TaskReadOnlyGuard`'s status check, and `WorkspaceGitSync`. The last two sit on automation-owned directories and keep their prior posture; flipping them is a behavior change on the security-defect track. Operators relying on `/etc/gitconfig` for automation-owned paths should move that config to `~/.gitconfig`. A fixture repo with `core.sshCommand` cannot read `ANTHROPIC_API_KEY` from the parent process even when git is allowed to run (`git_runner_test.dart` covers the default posture).

### Google Chat OAuth Store

Reaction auth and Workspace Events user auth share a refresh-token store at `<data_dir>/google-chat-user-oauth.json` (atomic rename, `chmod 600` on Unix). Service-account credentials handle bot messages and Pub/Sub pull; with `reactions_auth: user`, reactions appear under the authenticated user.

---

## Access Control

### HTTP Authentication

Token bootstrap plus stateless HMAC-signed session cookies; no usernames ([ADR-006](../adrs/006-http-auth-scope.md)).

[![Security: HTTP request pipeline and authentication](diagrams/security-http-pipeline.svg)](diagrams/security-http-pipeline.svg)

The pipeline is built in `Server._buildPipeline`. `auth_mode: none` installs `localAdminMiddleware` in place of `authMiddleware`. CORS answers only `http://localhost` and `http://127.0.0.1` origins.

- **Gateway token**: 32 `Random.secure()` bytes as 64 hex chars, persisted to `<data_dir>/gateway_token` (atomic write, `chmod 600`), compared in constant time; a blank token is rejected. `dartclaw token rotate` generates a new one and invalidates every cookie and source link.
- **Startup banner**: when stderr is a terminal, `serve` prints `http://<host>:<port>/?token=<token>`, so the token lands in terminal scrollback and any captured session. Rotate it after sharing one.
- **Session cookie**: `base64url({"iat": unix_ms}).base64url(HMAC-SHA256(payload, gateway token))`, 30-day TTL, `dart_session; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000` plus `Secure` when `auth.cookie_secure`. No server-side state.
- **Failed auth**: `recordFailedAuth` fires `FailedAuthEvent` and counts on `AuthRateLimiter` (5 failures per minute per remote key by default; `auth.trusted_proxies` governs which `X-Forwarded-For` is honored). Success resets the window.
- **`auth_mode: none`** grants every request local-admin context; `originHostGuardMiddleware` then requires loopback `server.host` and `Host` for writes.

**Source**: `packages/dartclaw_runtime/lib/src/auth/` (`auth_middleware.dart`, `session_token.dart`, `token_service.dart`, `auth_rate_limiter.dart`, `request_auth_context.dart`)

### Inbound MCP Authentication

`/mcp` authenticates its own callers and is exempt from the gateway middleware (a client bearer is not the gateway token). `mcpRoute` resolves the bearer without short-circuiting, in constant time, against:

| Bearer | Reaches |
|--------|---------|
| `gateway.token` | the unscoped handler: every tool, principal `system`; it authenticates the deployment, not a person |
| a `gateway.mcp_clients` token | a handler scoped by `ContextEngineCallerPolicy` (deny-by-default over the context-engine read tools), identity `mcp-client:<name>`, shared-knowledge scope only. Discovery and dispatch both filter, and a denied and an unregistered name answer identically so a client cannot enumerate. The policy audits refusals, the dispatch seam audits permitted calls |
| a host-minted harness bearer (`HarnessMcpBearers`) | a handler bound to that harness's active turn, valid only while the harness lives |

Failures count on the same `AuthRateLimiter` as the gateway (`FailedAuthEvent` source `mcp`, 429 past budget); only a gateway-token success resets the window, so the least-trusted credential cannot disable the control protecting the gateway token. `GET` answers 405; the body is capped at 1 MiB; a browser `Origin` must be an exact loopback host.

Client tokens are `${VAR}` references only; the config load refuses literals, duplicates, an empty resolution, a token equal to the gateway token, and `auth_mode: none` (`config_parser.dart`). A client token is confined to `/mcp`: it never reaches `TokenService`, mints no cookie, and does not satisfy `?token=`. The client list is read at mount, so removal takes effect at restart; there is no live revocation. With authentication disabled, `/mcp` mounts bearerless only when `server.host` is a literal loopback host and requests carry an exact loopback `Host`; otherwise it is not mounted.

**Source**: `packages/dartclaw_runtime/lib/src/mcp/mcp_router.dart`, `harness_mcp_bearers.dart`

### Source Links

`GET /knowledge/source?t=<token>` is an exact auth-exempt path. The token `{layer, locator, issued}` is HMAC-signed with the gateway token under a fixed `source-link` domain prefix, so rotation revokes every link, a link never verifies as a session cookie (or the reverse), and it expires at the cookie age limit. The route verifies before any file or database read, serves only `wiki` pages (through the same contained read as the authenticated view) and graph facts (entity, predicate, value, validity window; never the private `source`), and answers every refusal with the wiki view's single 404. A missing or invalid token is a failed auth (`FailedAuthEvent` source `source_link`, counted on the shared limiter, 429 past budget); a valid link never counts or resets. The page renders standalone (no command palette, Stimulus, HTMX, or SSE), so a reader with no session triggers no authenticated call. Under `auth_mode: none` the token is unsigned. Links are minted only when `base_url` is set, only for references the citation resolver confirmed, never from model output.

**Source**: `packages/dartclaw_runtime/lib/src/auth/source_link_token.dart`, `hmac_signature.dart`

### Privileged Chat Actions

Three gates decide whether a chat sender may change shared state. All use `GovernanceConfig.isAdmin` ([admin model](#admin-sender-model)) and audit their decisions with `AuditEntry`. A channel turn that names no sender (a task push-back feedback turn) is an admin only where every sender is. Senders come from the host's turn record (`McpCallerContext.turn`) or button click, never from model arguments.

**Shared-write gate** (`KnowledgeWriteGate`): `wiki_write`, `kg_add`, and `kg_invalidate` run behind it after the temporary-conversation refusal. A turn whose provenance names a chat channel changes shared knowledge only for an admin; each call writes an entry (guard `KnowledgeWriteGate`, hook `mcp_tool_call`, channel, sender in `peerId`/`principal`, tool, `allow`/`deny`). A task or workflow-step turn delegated by a chat requester carries that requester's channel and sender (from the stored `TaskOrigin` or `WorkflowRunOrigin`, `task/delegated_turn_provenance.dart`), so delegating a write does not leave the gate. Web chat, scheduled turns, the gateway token, and named clients carry no channel provenance and are not gated.

**Run approval gate** (`WorkflowRunControl`, `task/workflow_run_control.dart`): the only reader of `isAdmin` for run resolution, the only chat/tool/HTTP caller of `WorkflowService.resume`/`cancel`/`requestChanges`, and the only writer of run-resolution entries.

- *Admin gate.* Chat and tool callers must be admins; a refused call changes nothing. A tool call from a turn with no chat channel (gateway token, scheduled, web chat) is refused whatever the list holds, as is one from a delegated turn (`TurnProvenance.delegated`): an approval needs a human, so the refusal is the same `needsChatTurn` deny entry whoever asked for the work.
- *Nonce.* A button resolves only while the run still waits at the step the post was issued for and with the run's single-use nonce (128 bits, `Random.secure()`, constant-time compare) from the post bound to it; stale, copied, forged, or replayed clicks are refused. The nonce lives in the run's private context ([workflow-architecture.md](workflow-architecture.md#82-approval)), readable by an authenticated run-detail API caller, who can already resume over HTTP. No tool result, audit entry, or log line carries it.
- *Request changes.* The first click is a check (is there a revise step with rounds left, is the sender an admin): it writes no entry when it passes and one deny entry when it fails, then the adapter opens its form, so a refused sender never loses typed text. The submission is the resolution (admin check, live nonce, revise step, bound, non-empty feedback) and writes one allow entry with reason `revision n/max`. The feedback text appears in no entry, log, or event.
- *Tools.* `workflow_resume`, `workflow_cancel`, `workflow_request_changes` are write tools; `workflow_status` is read-only and never returns the interaction. Bound agents get them only through `allowedTools`, the primary agent gets all four, named MCP clients none.
- *HTTP.* `POST /api/workflows/runs/<id>/resume|cancel|request-changes` go through the control's web entry: already authenticated, so audited as principal `owner` but not admin-gated.
- *Audit.* Guard `RunApprovalGate`; hook `button`, `tool`, or `web`; verdict `pass`/`block`; decision `allow`, `deny`, or `error`; `channel`; sender in `peerId`/`principal`; `tool` `resume`, `cancel`, `requestChanges` (`checkRequestChanges` for a refused check); `reason` on refusal, failure, or an allowed revision; `runId`, `stepId`.

**Task review gate**: a chat review card (Google Chat's `task_accept`/`task_reject`; Slack renders no review buttons) is gated by `adminGatedReviewHandler` (`task/channel_review_gate.dart`, applied by `ChannelWiring`): non-admin clicks are refused and leave the task in review. Entries use guard `TaskReviewGate`, hook `button` or `tool`, the task ID in `reason`; no nonce. The `task_review` tool (also `push_back`) admits a chat turn through the same rule (`admitTaskReview`) and refuses delegated turns; `task_bind`/`task_unbind` do the same for `/bind` and `/unbind`, with refusals audited under guard `ReservedCommand`, hook `tool`. HTTP review routes are unchanged. Web turns and callers with no turn are not gated.

### Webhooks

Webhook routes sit outside the gateway middleware (exact public paths plus the `/webhook/` prefix) and each verifies itself, so a new route there must bring its own check. WhatsApp GOWA (`/webhook/whatsapp`) uses a shared secret in the URL query, compared in constant time; Google Chat verifies a JWT (`GoogleJwtVerifier`); GitHub verifies `X-Hub-Signature-256` and requires an `x-github-delivery` id; Slack is below. The Slack path is public only when the Events handler exists (`channels.slack.mode: events`), as an exact path. Signal uses a local sidecar, not a webhook.

**Slack Events signature**: Slack signs every delivery with `X-Slack-Signature: v0=<hex>`, HMAC-SHA256 under the signing secret over `v0:<X-Slack-Request-Timestamp>:<raw body>`. `SlackEventsHandler` (framework-neutral, `dartclaw_slack`) refuses a timestamp more than 300 s from now in either direction and compares the HMAC (`crypto` `Digest` equality) over the exact received bytes; nothing decodes the body first and an empty signing secret verifies nothing. A refusal is `401` with `missing_slack_signature`, `stale_slack_timestamp`, or `invalid_slack_signature`; the route fires `FailedAuthEvent` (`source: webhook`) and writes one audit entry (guard `slack_signature`, hook `webhook`, verdict `block`, channel `slack`, remote key as peer). No other webhook audits a failed verification, and no throttle applies. The signing secret, bot token, and app token are registered with `MessageRedactor` as literals.

**Shared helpers** (`dartclaw_core`, `auth/webhook_http.dart`): `readBoundedBytes` (checks the declared length and every chunk, stops at the first chunk over the limit), `resolveRemoteKey` (first `X-Forwarded-For` entry only when the peer is a trusted proxy), `publishFailedAuthEvent`, and `maxWebhookPayloadBytes` (1 MiB), which every unauthenticated POST endpoint applies.

**Source**: `packages/dartclaw_core/lib/src/auth/webhook_http.dart`, `packages/dartclaw_slack/lib/src/slack_events_handler.dart`, `packages/dartclaw_runtime/lib/src/api/slack_webhook.dart`, `webhook_routes.dart`, `github_webhook.dart`

### Channel Access Control

`ChannelInboundGate` decides admission for every channel: DM access, then group access (`allowlist`, `open`, `disabled`), then mention gating. `DmAccessController` modes: `pairing` (unknown senders get a code; the operator confirms in the web UI), `allowlist`, `open`, `disabled`. Pairing codes are 8 characters from an ambiguity-free charset, at most 3 pending, 1-hour expiry with eviction on access. Channel adapters and delivery: [channel-messaging-architecture.md](channel-messaging-architecture.md).

**Source**: `packages/dartclaw_core/lib/src/channel/inbound_gate.dart`, `dm_access.dart`

---

## Web Security

**SSRF (`WebFetchTool`).** The `web_fetch` MCP tool fetches http/https URLs only (30 s timeout) and blocks loopback (`127/8`, `::1`, `localhost`), link-local (`169.254/16`, IPv6 link-local), RFC1918 (`10/8`, `172.16/12`, `192.168/16`), CGNAT (`100.64/10`), unspecified (`0/8`, `::`), multicast/reserved (`224/4` and above), IPv6 ULA (`fc00::/7`), and IPv4-mapped IPv6 that maps into those. Hostnames are resolved and every address checked; the protected client's connection factory repeats the check and connects to the checked address while keeping the hostname for TLS, so policy and connection cannot see different DNS answers. Proxies are unavailable, redirects are returned as local errors, non-success bodies are never returned, successful bodies are bounded while streaming (before decode) and capped at 50,000 characters, and only HTML, plain text, markdown, and JSON are converted. The result is then classified through `ContentScan` and returns exactly the scanned span.

**XSS.** Trellis templates escape with `tl:text` by default; `tl:utext` is for trusted pre-rendered HTML only, and data attributes use `tl:attr`.

**CSRF.** Defense in depth, no CSRF tokens:

- `SameSite=Strict` session cookies (primary; weakened by old browsers and misconfigured intermediaries, hence the next control).
- `originHostGuardMiddleware`: for POST/PUT/PATCH/DELETE on cookie-authenticated requests it compares the `Origin` authority (scheme, host, effective port) to the request's own `Host`, falling back to `Referer`, and returns 403 on mismatch or when both are absent. No-auth local-admin writes additionally need literal-loopback `server.host` and `Host`, which defeats DNS rebinding where attacker-controlled `Origin` and `Host` agree; origin-less loopback API clients stay supported. Safe methods and Bearer requests are exempt.
- `securityHeadersMiddleware` (directly inside `logRequests`) sets on every response: `Content-Security-Policy` (`default-src 'none'`; `script-src 'self'` plus the inline theme-script hash; `style-src 'self' 'unsafe-inline'`; `font-src 'self'`; `img-src 'self' data:`; `connect-src 'self'`; `base-uri 'self'`; `form-action 'self'`; `frame-ancestors 'none'`), `Referrer-Policy: same-origin`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Cache-Control: no-store` unless already set, `Vary: HX-Request`, and HSTS when `gateway.hsts` is on. Every runtime script and style is vendored; no external origin.

**Source**: `packages/dartclaw_runtime/lib/src/mcp/web_fetch_tool.dart`, `auth/origin_host_guard.dart`, `auth/security_headers.dart`

---

## Content Classification and Redaction

**`ContentClassifier`** (`claude_binary` default, or `anthropic_api` with `ANTHROPIC_API_KEY`) returns `safe`, `prompt_injection`, `harmful_content`, or `exfiltration_attempt`, and throws on error.

**`ContentScan`** is the one place a classification and its fail policy are decided, for every scanning site: `ContentGuard`, `web_fetch`, and `public` outbound MCP results. `SecurityWiring` builds it once from `guards.content.*` and injects it at all three; null means classification is not configured, never an implicit block. It truncates to `guards.content.max_bytes` (50 KiB, UTF-8 safe) and classifies exactly that span, times out at 15 s, passes empty input without a classifier call, and returns a verdict as data (blocked, label, failure reason, scanned span) so each site formats its own message. `guards.content.fail_open` is the only fail-policy input (constructor default fail-closed); `exceedsCap` answers the over-cap question without a classifier call.

**`ContentGuard`** adds only the `beforeAgentSend` gate and its `enabled` check. It is called directly (not via the chain) by `LogicalAgentSessionService` on a logical agent's result before it returns to the main agent, and by the search MCP tools on concatenated result titles and snippets. At the handoff it prefix-scans `max_bytes` and passes the whole result: that content is an agent's own output, the opposite of the two third-party paths (`web_fetch` returns only the scanned span; an over-cap `public` MCP result is denied). `LogicalAgentSessionService` logs every verdict through the audit logger; the search tools return the block error and write no audit entry. A block at the logical-agent site also discards a failed spawn. The call sites are drawn in the [call sites figure](#guard-summary).

**Output schema validation** is a second, independent check at the same boundary for agents declaring `agent.agents.<id>.output_schema`: the result must be exactly one JSON value conforming to a deep-closed schema (`additionalProperties: false` at every object level). `ContentGuard` classifies text up to its cap; the schema bounds its shape; neither substitutes for the other. Order in `LogicalAgentSessionService._run`: guard, schema validation, then the size decision; a schema-bound result over `max_response_bytes` fails rather than truncates, since a truncated value is not the declared contract. A schema failure is not a guard verdict and writes no audit entry.

**`MessageRedactor`** redacts outbound text on all output paths; best-effort pattern matching, not confidential-data classification, so persistence surfaces using it must document their own retention and trust boundary. Mechanisms, applied in order:

1. Exact secrets: literals registered with `registerLiterals` (Slack tokens, signing secret) and call-time `sensitiveValues`, masked as `[REDACTED]`, longest first.
2. `Authorization`/`Proxy-Authorization` header values.
3. Assignments whose key is secret-shaped (`isSecretKey`: `password`, `secret`, `token`, `credential`, `authorization`, `cookie`, `api_key`, `database url`, and similar; measurement prefixes like `max_tokens` excluded): label kept, value replaced by `***`, by `=`, `:` and quoted-JSON forms. A secret-shaped key redacts its value unconditionally, so same-line prose after it is over-redacted by design.
4. Token shapes with proportional reveal (`min(len/2, 8)` leading characters plus `***`): Stripe, `sk-ant-`, Slack `xox*`/`xapp-`/Socket Mode URLs, JWTs, AWS `AKIA` ids, `Bearer` tokens; PEM blocks (also truncated) become `[REDACTED]`; PostgreSQL userinfo is masked, keeping scheme and host.
5. `logging.redact_patterns` extras.

`redact()` never throws; on internal error it returns `[REDACTED]` when literals were supplied, otherwise the input unchanged.

**Source**: `packages/dartclaw_kernel/lib/src/content_scan.dart`, `content_guard.dart`, `content_classifier.dart`, `output_schema.dart`, `message_redactor.dart`, `packages/dartclaw_core/lib/src/agents/logical_agent_session_service.dart`

---

## Task Security

`TaskFileGuard` (`task/task_file_guard.dart`) is a per-task registry, not a `Guard`: `TaskExecutor` registers the canonical worktree path when a declared worktree is created and cleanup (accept, reject, cancel) deregisters it. Its `isAllowed(taskId, path)` check (`canonicalize` plus `isWithin`, deny when unregistered) has no production caller today, so the registry enforces nothing by itself. Effective containment of a task comes from its execution directory being the worktree, provider-native writable roots where the provider honors them, container mounts, `FileGuard` for sensitive paths, and `TaskToolFilterGuard` for tool surface and read-only mode. Legacy owner profiles still mount `/projects:ro`, giving OS-level read access to every project clone; managed-workspace agents see only their workspace and admitted directory. That application-layer gap is acceptable within DartClaw's single-admin product scope, where Docker remains the primary boundary. Wiring the registry into an enforcement point, or removing it, needs an owner decision.

---

## Audit Chain

Every guard decision that matters ends up as an `AuditEntry` in date-partitioned NDJSON (`audit-YYYY-MM-DD.ndjson` in the data dir; retention `guard_audit.max_retention_days`, default 30, 0 keeps all). Log mechanics and the audit UI: [observability-operations-architecture.md](observability-operations-architecture.md).

**Entry fields**: `timestamp`, `guard`, `hook`, `verdict`, `reason`, `rawProviderToolName`, `agentId`, `sessionId`, `channel`, `peerId`, `server`, `tool`, `decision`, `principal`, `credentialRef`, `runId`, `stepId`; null fields are omitted and older lines still parse. Guard events keep both the canonical `tool` and the raw provider name.

**Two write paths with different guarantees**:

Chain verdicts (warn and block only; pass is not recorded) flow `GuardChain.onVerdict`, `GuardBlockEvent`, `GuardAuditSubscriber`, `GuardAuditLogger.logVerdict`, fire-and-forget (see the [guard chain figure](diagrams/security-guard-chain.svg)). Explicit decisions (egress, `/mcp` dispatch, run, task and knowledge gates, DB egress, Slack signature) call `GuardAuditLogger.writeEntry`, which is awaited.

- `logVerdict` logs at INFO/WARNING/SEVERE for pass/warn/block, appends to the file via a chained `_pendingWrite` future (no interleaving), and never delays the verdict. `GuardAuditSubscriber` (`dartclaw_runtime`) also records `ToolPermissionDeniedEvent` as `guard: PermissionDenied`. `PostToolUse` is stdout-only.
- `writeEntry` is awaited so callers can fail closed: outbound MCP, `/mcp` dispatch, `KnowledgeWriteGate`, `WorkflowRunControl`, and DB egress refuse the action when the write fails. Refusal-only writers (`auditRefusal` for reserved commands and `task_*` tools, the Slack signature route) log a failed write and never change the refusal. A failed append resets the shared chain so one error cannot silence the trail.
- `EventBus.fire` wraps delivery in `runZonedGuarded`: subscriber exceptions are logged and never reach the firing code.
- Shutdown awaits `flush()` so queued appends are not lost.

Entries are not hash-chained or signed; integrity rests on file permissions and the host-trust assumption above.

**Source**: `packages/dartclaw_kernel/lib/src/guard_audit.dart`, `packages/dartclaw_runtime/lib/src/audit/guard_audit_subscriber.dart`, `packages/dartclaw_core/lib/src/events/event_bus.dart`

---

## Runtime Governance

Layer 5 protects a deployment from cost overruns, flooding, and runaway agents, and gives operators emergency controls. Guards judge single tool calls and messages; governance works at the session and deployment level. Everything is configured under `governance:` and off by default (0 or `false` disables) except turn limits. Governance state (`SlidingWindowRateLimiter`, `BudgetEnforcer`, `LoopDetector`) is built once in `HarnessWiring` and shared by every runner, so limits are deployment-wide, not per runner. All counters except the token totals are in-memory and reset on restart.

| Control | Enforced at | Scope | State | On breach |
|---------|-------------|-------|-------|-----------|
| Per-sender rate limit | `ChannelTaskBridge.tryHandle` | channel messages by sender JID | memory | Replies "Rate limit reached (N messages per W)", message consumed |
| Per-sender queue caps | `MessageQueue` (`max_queued`), `PauseController` (`max_pause_queued`) | per session queue, pause queue | memory | Rejected with a queue-full reply |
| Global turn rate | `TurnRunner.admitTurn` | every turn, all surfaces | memory | Turn reservation waits for window capacity |
| Daily token budget | `TurnRunner.admitTurn` | every turn, all surfaces | persisted usage aggregate | `warn`: continue; `block`: `BudgetExhaustedException` |
| Loop detection | pre-turn, mid-turn, post-turn | per session / per turn | memory | `abort` or `warn` |
| Turn limits | turn monitor in `TurnRunner` | per provider turn | timers | Cancel (or warn/ignore) on stall; cancel at wall-clock limit |
| Pause | `ChannelManager` | inbound channel messages | memory | Queued, replayed on `/resume` |
| Emergency stop | `EmergencyStopHandler` | all turns and running/queued tasks | none | Cancelled |

[![Security: runtime governance](diagrams/security-governance.svg)](diagrams/security-governance.svg)

### Admin Sender Model

`governance.admin_senders` lists admin sender IDs, checked by `GovernanceConfig.isAdmin(senderId)`. **An empty list (default) makes every sender an admin.** That suits a single-user deployment; in a group channel it lets every member run the emergency commands, change shared knowledge, resolve workflow approvals, and review tasks, so list the admins wherever a channel has more than one person.

Admin status: exempts a sender from the per-sender rate limit and the `max_queued`/`max_pause_queued` caps (so with the default empty list those limits never fire); gates `/stop`, `/pause`, `/resume`, `/bind`, `/unbind`, the shared-write gate, the run approval gate, and chat task review ([Privileged Chat Actions](#privileged-chat-actions)). It does not exempt anyone from the global turn limit or the token budget.

### Admission Sequence

All governance except the channel-level limits runs in `TurnRunner.admitTurn`, called from `ExecutionCoordinator.acquire` before the coordinator picks a lane or leases a worker, so no surface can start a provider process without it:

1. **Budget** (read-only): `BudgetEnforcer.check`; may throw `BudgetExhaustedException`.
2. **Session lock**: `SessionLockManager.acquire` (warns after 30 s waiting, flags stuck at 120 s).
3. **Loop pre-checks** (turn chain depth, token velocity): `LoopDetectedException` under `abort`.
4. **Global rate window**: waits.

Steps 3 and 4 record state, so they run after the lock: an attempt the global cap rejects must not have counted. For polled fail-fast requests (tasks, workflow steps) the worker permit is taken before admission for the same reason, since the poller retries every cycle. Provider `pool_size` is the later hard execution bound, not a substitute for governance. A `BudgetExhaustedException` or `LoopDetectedException` at task admission fails the task non-retryably (`budgetExceeded`, `loopDetected`); a channel turn gets a polite budget-exhausted reply and no retry.

Inbound channel order, before any turn exists: pause intercept (reserved commands excepted) → reserved commands → thread-binding lookup → per-sender rate limit → bound-thread routing → `MessageQueue` (debounce, `max_queue_depth`, `max_queued`, `queue_strategy`) → admission above.

### Rate Limiting

`SlidingWindowRateLimiter` is an in-memory, per-key window with lazy eviction on access (no timer). `check()` verifies and records atomically, and a failing check records nothing, so deferral retry loops do not inflate the counter. `limit <= 0` means unlimited.

- **Per sender** (`governance.rate_limits.per_sender.messages` per `window`, default 0 and 5 min): enforced in `ChannelTaskBridge.tryHandle` after the thread-binding lookup, so a message in a bound thread is limited like any other. Admins and reserved commands are exempt; review requests are ordinary model turns and are not. Excess messages get the rejection reply and are consumed. `max_queued` and `max_pause_queued` (default 0, off) cap one sender's queued entries per session queue and in the pause queue.
- **Global** (`governance.rate_limits.global.turns` per `window`, default 0 and 60 min): `awaitRateLimitWindow` defers, polling once a second, rather than rejecting, so messages are eventually processed. It broadcasts SSE `rate_limit_warning` at 80% usage and re-arms below 60%.

`window` accepts a duration string (`5m`, `1h`) or a bare number of minutes.

**Source**: `packages/dartclaw_kernel/lib/src/sliding_window_rate_limiter.dart`, `packages/dartclaw_core/lib/src/channel/channel_task_bridge_support.dart`, `message_queue.dart`, `packages/dartclaw_runtime/lib/src/turn_governance_enforcer.dart`

### Daily Token Budget

`BudgetEnforcer` is the daily scope over `BudgetEngine`, the one implementation of threshold arithmetic and warn-once gating (per-task token caps use the same engine with their own scope; see [task-execution-architecture.md](task-execution-architecture.md)). It reads today's input + output tokens from `UsageTracker.dailySummaryForDate` (key `usage_daily:YYYY-MM-DD`), so totals come from the existing usage aggregation, not a second counter. A storage failure surfaces to the caller rather than silently allowing an over-budget turn.

| Usage | `warn` | `block` |
|-------|--------|---------|
| below 80% | allow | allow |
| 80% to 100% | allow, warn once per day | allow, warn once per day |
| at or above 100% | allow, warn if none yet today | throw `BudgetExhaustedException` |

The warn-once marker (`budget_warning_posted_at` in the daily summary) is persisted and shared by both thresholds: a day warned at 80% does not warn again at 100%. A new warning is logged, broadcast as SSE `budget_warning` (`tokens_used`, `budget`, `percentage`, `action`), and posted to the originating channel when there is one (best-effort; text appended with "New turns will be blocked" when blocking).

"Today" is the date in `governance.budget.timezone` (default `UTC`): `UTC`/`GMT`, `UTC+N`/`UTC-N` (whole hours), or an IANA name such as `America/New_York`; an unrecognized value warns and uses UTC. The budget resets when the date key changes.

**Source**: `packages/dartclaw_runtime/lib/src/governance/budget_enforcer.dart`, `budget_engine.dart`

### Loop Detection

`LoopDetector` runs three independent mechanisms, each disabled by a 0 threshold; the master switch is `loop_detection.enabled`. The detector returns results and `TurnGovernanceEnforcer` decides the action.

| Mechanism | Counts | Triggers when | Checked |
|-----------|--------|---------------|---------|
| Turn chain depth | consecutive non-human-initiated turns per session; reset by a human message | depth exceeds `max_consecutive_turns` | pre-turn |
| Token velocity | tokens in a rolling `velocity_window_minutes` per session | total exceeds `max_tokens_per_minute * velocity_window_minutes` | pre-turn; recorded post-turn |
| Tool fingerprint | consecutive identical tool calls (tool name + key-sorted canonical JSON arguments) within one turn | count reaches `max_consecutive_identical_tool_calls` | mid-turn, on each tool call |

`governance.loop_detection.action`: `abort` or `warn`. Every detection fires `LoopDetectedEvent` (alert `loop_detected`, SSE `loop_detected`, best-effort notice to the originating channel). Under `abort`, a pre-turn detection throws `LoopDetectedException` at reservation, which fails a task as `loopDetected`; a mid-turn tool-fingerprint detection cancels the running turn (reason `automationCancel`) and records `[Loop detected: ...]` as the assistant message. The post-turn velocity record only warns, since the tokens are already spent; the next pre-turn check aborts if the window is still over. Per-turn fingerprint state is cleaned in the turn's `finally`.

**Source**: `packages/dartclaw_kernel/lib/src/loop_detector.dart`, `loop_detection.dart`, `packages/dartclaw_runtime/lib/src/turn_guard_evaluator.dart`, `turn_runner_execution_loop.dart`

### Turn Limits

`governance.turn_limits` bounds one provider turn: `stall_timeout` (default 5 m of no progress events; 0 disables), `stall_action` (`cancel` default, `warn`, `ignore`), and `turn_timeout` (30 m wall clock; per-turn overrides apply; 0 disables). A breach cancels through the same path as a user cancel. Turn lifecycle: [control-protocol.md](control-protocol.md).

### Emergency Controls

Admin-only controls for immediate intervention. They bypass rate limiting and pause queueing so they work during a flood.

[![Security: emergency controls](diagrams/security-emergency-controls.svg)](diagrams/security-emergency-controls.svg)

**Stop.** `/stop` (or `stop!`) as a channel message, a Google Chat slash command, `dartclaw stop`, and `POST /api/emergency-stop` (operator/admin access, so an install with every channel disabled still has a way out; the audited caller is derived from how the request authenticated) all run `EmergencyStopHandler.execute`, best-effort and non-halting:

1. Cancel every active turn on every runner the coordinator tracks (primary lane, active worker leases, cached workers).
2. Transition running and queued tasks to `cancelled` (`trigger: emergency_stop`); review, draft, accepted, and rejected tasks are left for manual resolution. A task modified concurrently is skipped with a warning.
3. Fire `EmergencyStopEvent` (alert `emergency_stop`, critical) and broadcast SSE `emergency_stop`.

It returns `EmergencyStopResult` with turn and task counts. Cancellation retains each lease until the managed root process has exited or the slot is quarantined; releasing capacity on the request alone would allow an overlapping replacement.

**Pause and resume.** `/pause` suspends inbound channel message processing; it does not stop turns already running, web chat, tasks, or scheduled jobs. `PauseController` (in-memory, resets on restart) queues inbound messages up to 200 in total (and `max_pause_queued` per non-admin sender), answering each sender that their message is queued or that the queue is full. `pause()` is idempotent. `/resume` drains and unpauses atomically, collapsing messages per conversation route (session key, channel, group or sender) and per sender, as "While paused, N participant(s) sent messages:" followed by `- Sender: msg1, msg2`, then re-enqueues each collapsed message into `MessageQueue`, bypassing the per-sender rate limit. Replies for `/stop`, `/pause`, and `/resume` go to the issuing thread.

A non-admin reserved command is refused with "Only admin senders can use this command." and audited (guard `ReservedCommand`, hook `channel_command`).

**Source**: `packages/dartclaw_runtime/lib/src/emergency/emergency_stop_handler.dart`, `governance/pause_controller.dart`, `runtime/reserved_command_handler.dart`, `api/emergency_stop_routes.dart`, `api/slash_command_handler.dart`

### Thread Binding and Attribution

Thread binding routes a task thread past normal session keying, so the per-sender rate limit is checked before bound routing and `/bind` and `/unbind` are admin-only. Run bindings (created only for `workflow.chat_notifications`) route nothing, because `ThreadBindingRouter` answers task bindings only; the explicit binding writers refuse a thread held by a run binding. Channel-created tasks carry `TaskOrigin` and `Task.createdBy`, so who requested work stays auditable independent of the executing session. Binding lifecycle and persistence: [channel-messaging-architecture.md](channel-messaging-architecture.md); task provenance: [task-execution-architecture.md](task-execution-architecture.md).

### Governance Configuration

Defaults shown; `0` disables a numeric limit.

```yaml
governance:
  admin_senders: []              # empty = every sender is an admin
  rate_limits:
    per_sender:
      messages: 0                # per window; admins exempt
      window: 5m
      max_queued: 0              # per sender per session queue
      max_pause_queued: 0        # per sender while paused
    global:
      turns: 0
      window: 60m
  budget:
    daily_tokens: 0
    action: warn                 # warn | block
    timezone: UTC                # UTC, UTC+N, UTC-N, or IANA name
  loop_detection:
    enabled: false
    max_consecutive_turns: 0
    max_tokens_per_minute: 0
    velocity_window_minutes: 5
    max_consecutive_identical_tool_calls: 0
    action: abort                # abort | warn
  turn_limits:
    stall_timeout: 5m            # accepts durations; 0 disables
    stall_action: cancel         # cancel | warn | ignore
    turn_timeout: 30m
  queue_strategy: fifo           # fifo | fair   (channel queue, see channel-messaging-architecture.md)
```

`governance.crowd_coding.*` (model and effort defaults for group sessions) belongs to [channel-messaging-architecture.md](channel-messaging-architecture.md). The full key reference is in [configuration-architecture.md](configuration-architecture.md). Governance metrics and the `/status` view: [observability-operations-architecture.md](observability-operations-architecture.md).

**Source**: `packages/dartclaw_kernel/lib/src/governance_config.dart` (parts `budget_config.dart`, `rate_limits_config.dart`, `loop_detection_config.dart`, `turn_limits_config.dart`), `config_parser_governance.dart`

---

## Security Configuration

Security keys (full reference: [configuration-architecture.md](configuration-architecture.md)). Defaults shown.

```yaml
guards:
  enabled: true                  # master switch; false needs a restart
  fail_open: false               # guard exception/timeout: false = block, true = warn
  command: { extra_blocked_patterns: [], extra_blocked_pipe_targets: [] }
  file:    { extra_rules: [] }   # {pattern, level: no_access | read_only | no_delete | allow}
  network: { extra_allowed_domains: [], extra_exfil_patterns: [], agent_overrides: {} }
  content:
    enabled: true
    classifier: claude_binary    # claude_binary | anthropic_api
    model: haiku
    fail_open: false
    max_bytes: 51200
guard_audit:
  max_retention_days: 30         # 0 keeps all
security:
  bash_step: { env_allowlist: [...], extra_strip_patterns: [] }
container:
  enabled: ~                     # unset = isolate if a runtime answers the probe
  image: dartclaw-agent:latest
gateway:
  auth_mode: token               # token | none
```

---

## Cross-References

| Document | Why |
|----------|-----|
| [ADR-001](../adrs/001-sdk-integration-and-security-architecture.md) | SDK integration and the original security architecture |
| [ADR-006](../adrs/006-http-auth-scope.md) | HTTP auth mechanism |
| [ADR-012](../adrs/012-per-type-container-isolation.md), [ADR-015](../adrs/015-container-isolation-strategy.md), [ADR-055](../adrs/055-container-by-default-posture.md) | Container profiles, strategy, default posture |
| [ADR-016](../adrs/016-multi-provider-harness-architecture.md), [ADR-035](../adrs/035-cross-harness-task-capability-trust-mapping.md) | Provider abstraction and cross-harness tool trust |
| [ADR-039](../adrs/039-outbound-mcp-trust-boundary-and-transport.md), [ADR-052](../adrs/052-native-provider-web-tools-denied-all-container-profiles.md), [ADR-053](../adrs/053-subscription-default-provider-authentication.md) | Outbound MCP, provider-side web tools, subscription auth |
| [ADR-054](../adrs/054-model-first-delegation-and-one-authority-per-concern.md) | One authority per concern (deterministic invariants stay in code) |
| `docs/guide/security.md` | User-facing summary |
