# DartClaw Security Architecture

Deep-dive reference on DartClaw's defense-in-depth security model: OS-level container isolation, application-level guards, credential management, access control, content classification, and audit logging.

**Current through**: 0.18

---

## Threat Model

DartClaw is a security-conscious AI agent runtime that spawns provider CLI binaries (`claude`, `codex`) and ACP agent binaries with tool execution capabilities (bash, file I/O, networking). The agent can execute arbitrary shell commands and access the filesystem through the active provider boundary. The security architecture addresses the following threat categories:

| Threat | Description | Primary Defense |
|--------|-------------|-----------------|
| **Prompt injection** | Adversarial input via channels (WhatsApp, Signal, Google Chat) attempting to override system instructions or extract sensitive data | InputSanitizer, ContentGuard |
| **Command injection** | Agent executing destructive commands (`rm -rf /`, fork bombs) or shell-escape chains | CommandGuard, container isolation |
| **Data exfiltration** | Agent piping secrets to external servers via curl, base64-encoded POST, or pipe-to-shell patterns | NetworkGuard, container `network:none` |
| **Credential theft** | Agent accessing API keys, SSH keys, cloud credentials from the host filesystem | CredentialProxy, FileGuard, container mount scoping |
| **SSRF** | Agent or MCP tools fetching internal/private network addresses to probe infrastructure | WebFetchTool SSRF hardening, DNS resolution checks |
| **Unauthorized access** | Unauthenticated users accessing the web UI/API, or unauthorized contacts messaging via channels | AuthMiddleware, DmAccessController |
| **Supply chain** | Malicious dependencies in the runtime chain | Zero npm/Node.js architecture, minimal deps |
| **Container escape** | Agent breaking out of Docker isolation to access the host | Capability drops, read-only rootfs, non-root user |
| **Cross-agent contamination** | A compromised sub-agent (e.g. search agent) accessing another agent's filesystem | Per-type container isolation (ADR-012) |
| **Cost overrun** | Runaway agent consuming excessive tokens, unbounded autonomous loops | Daily token budget enforcement (BudgetEnforcer), loop detection (LoopDetector) |
| **Rate abuse** | Flooding via channel messages overwhelming the agent with requests | Per-sender rate limiting, global turn rate limiting (SlidingWindowRateLimiter) |
| **Runaway agent loops** | Agent stuck in repetitive tool-call patterns or unbounded turn chains | LoopDetector (3 mechanisms: turn chain depth, token velocity, tool fingerprinting) |
| **Provider-specific tool bypass** | Provider-native tool names slipping past provider-specific interception or bypassing a guard path entirely | Canonical Tool Taxonomy, fail-closed guard evaluation, provider interception hardening |

---

## Defense-in-Depth Layers

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Layer 6: AUDIT & OBSERVABILITY                  │
│  GuardAuditLogger (NDJSON) · EventBus · ContainerHealthMonitor          │
│  UsageTracker · Agent observer · Guard audit web UI                     │
├─────────────────────────────────────────────────────────────────────────┤
│                       Layer 5: RUNTIME GOVERNANCE                       │
│  Per-sender rate limiting · Global turn rate limiting                   │
│  Daily token budget enforcement · Loop detection (3 mechanisms)         │
│  Emergency controls (/stop, /pause, /resume) · Admin sender model      │
├─────────────────────────────────────────────────────────────────────────┤
│                       Layer 4: CONTENT CLASSIFICATION                   │
│  ContentClassifier (LLM-based) · ContentGuard (agent boundaries)        │
│  MessageRedactor (proportional redaction) · CloudflareDetector          │
├─────────────────────────────────────────────────────────────────────────┤
│                       Layer 3: APPLICATION GUARDS                       │
│  InputSanitizer · CommandGuard · FileGuard · NetworkGuard               │
│  ToolPolicyGuard · TaskFileGuard · GuardChain (pipeline)                │
├─────────────────────────────────────────────────────────────────────────┤
│                       Layer 2: NETWORK CONTROLS                         │
│  Docker network:none · CredentialProxy (Unix socket) · socat bridge     │
│  Domain allowlist · SSRF protection (WebFetchTool)                      │
├─────────────────────────────────────────────────────────────────────────┤
│                     Layer 1: OS / CONTAINER ISOLATION                   │
│  Docker kernel namespaces (pid, net, mount, user)                       │
│  --cap-drop ALL · --read-only · --security-opt no-new-privileges        │
│  Non-root user (uid 1000) · tmpfs /tmp (noexec, nosuid, 100MB cap)      │
│  Per-type containers (workspace / restricted profiles)                  │
└─────────────────────────────────────────────────────────────────────────┘
```

Each layer operates independently. A failure at one layer does not compromise the others. For example, even if a guard is bypassed, the container's `network:none` prevents data exfiltration, and the credential proxy ensures API keys never exist inside the container.

### Pragmatic Mode

When Docker is unavailable (`container.enabled: false`), Layers 1 and 2 are absent. Guards (Layer 3) become the primary security boundary. This mode is suitable for personal use on a trusted machine with a single operator.

---

## Guard Pipeline

### Guard Interface

All guards extend the abstract `Guard` class and return a sealed `GuardVerdict`:

```
Guard
├── name: String          # Guard identifier (e.g. 'command', 'file')
├── category: String      # Guard category (e.g. 'command', 'filesystem')
└── evaluate(GuardContext) -> Future<GuardVerdict>
```

**Verdict types** (sealed class hierarchy):

| Type | Class | Meaning | Pipeline Effect |
|------|-------|---------|-----------------|
| **Pass** | `GuardPass` | Tool/message is safe | Continue to next guard |
| **Warn** | `GuardWarn(message)` | Suspicious but allowed | Log warning, continue; pipeline returns warn if no block |
| **Block** | `GuardBlock(reason)` | Dangerous, denied | **Short-circuit** — immediately stop evaluation, deny tool/message |

**Source**: `packages/dartclaw_security/lib/src/guard_verdict.dart`

### GuardContext

Every guard receives the same context object:

| Field | Type | Description |
|-------|------|-------------|
| `hookPoint` | `String` | `'beforeToolCall'`, `'messageReceived'`, or `'beforeAgentSend'` |
| `toolName` | `String?` | Tool name for `beforeToolCall` (e.g. `'Bash'`, `'web_fetch'`) |
| `toolInput` | `Map?` | Tool input arguments |
| `messageContent` | `String?` | Message text for `messageReceived` / `beforeAgentSend` |
| `agentId` | `String?` | Sub-agent ID (null = main agent) |
| `source` | `String?` | Message origin: `'channel'`, `'web'`, `'cron'`, `'heartbeat'` |
| `sessionId` | `String?` | Active session for audit correlation |
| `peerId` | `String?` | Channel sender identifier |
| `timestamp` | `DateTime` | Evaluation timestamp |

`GuardContext` preserves the raw provider tool name for audit logging while the guard pipeline evaluates the canonical tool name. That keeps incident logs faithful to provider output without expanding the policy surface.

### Execution Model

`GuardChain` evaluates guards sequentially. First block verdict wins (short-circuit). Exceptions are treated as block by default (fail-closed), configurable to fail-open. A 5-second wall-clock timeout is enforced per individual guard evaluation.

```
GuardChain._evaluate(context):
  for each guard in [InputSanitizer, CommandGuard, FileGuard, NetworkGuard, ContentGuard, ToolPolicyGuard]:
    verdict = guard.evaluate(context)    // 5s timeout
    if exception:
      verdict = failOpen ? warn : block  // fail-closed by default
    if verdict is block or warn:
      onVerdict?.call(...)               // optional app-layer callback
    if verdict is block:
      return block                       // short-circuit
    if verdict is warn and result is pass:
      result = warn                      // accumulate worst non-block verdict
  return result
```

**Source**: `packages/dartclaw_security/lib/src/guard.dart`

**Package attribution**: `dartclaw_security` owns guard execution and remains zero-EventBus; wiring guard verdicts into the EventBus happens in `dartclaw_server`.

Guards evaluate canonical tool names, not provider-native strings. Provider adapters map raw tool names to the canonical taxonomy before `GuardChain.evaluateBeforeToolCall()` runs. The raw provider name is still retained in `GuardContext` for audit logging and incident forensics.

### Guard Summary

| Guard | Hook Point | Scope | What It Does |
|-------|-----------|-------|-------------|
| **InputSanitizer** | `messageReceived` | Channel messages (configurable) | Regex-based prompt injection detection across 4 categories |
| **CommandGuard** | `beforeToolCall` (Bash) | All Bash tool calls | Destructive command, force operation, fork bomb, interpreter escape, pipe target blocking |
| **FileGuard** | `beforeToolCall` (Bash, write_file, edit_file) | File operations | Glob-based path protection with 3 access levels, symlink resolution |
| **NetworkGuard** | `beforeToolCall` (Bash, web_fetch) | Network operations | Domain allowlist, IP blocking, exfiltration pattern detection |
| **ContentGuard** | `beforeAgentSend` | Agent boundary handoff | LLM-based content classification (prompt injection, harmful content, exfiltration) |
| **ToolPolicyGuard** | `beforeToolCall` | Sub-agent tool calls | 3-layer policy cascade: global deny, agent deny, sandbox allow |
| **TaskToolFilterGuard** | `beforeToolCall` | Per-task tool allowlist | Restricts tool use to the current task's allowlist; optional read-only mode blocks mutating file/shell calls |

### Guard Hot-Reload

Security policy can be updated without restarting the process for reloadable guard fields.

- `SecurityWiring` implements `Reconfigurable` for `security.*` (guard config lives in the `security` section)
- A config reload rebuilds the concrete guard list from the latest `SecurityConfig`
- Exact duplicate rules are silently deduplicated during rebuild
- Conflicts or invalid rules preserve the existing in-memory chain instead of weakening protection
- `MessageRedactor` still participates through a small `Reconfigurable` adapter, while `InputSanitizer` is refreshed atomically as part of the rebuilt guard chain

This keeps the package DAG intact: `dartclaw_security` still owns guard execution and compiled rule behavior, while `dartclaw_cli` owns the runtime reconfiguration seam.

## Canonical Tool Taxonomy

Provider adapters normalize tool requests into a DartClaw-canonical taxonomy before guard evaluation. This keeps security policy stable across providers while still preserving provider-native names in audit logs. The canonical mapping is exact for Claude and Codex app-server. Codex exec currently exposes a coarser `file_change -> file_write` mapping, so edit-vs-write parity is not yet available in that mode.

| Canonical tool | Claude Code name(s) | Codex name(s) | Notes |
|----------------|---------------------|---------------|-------|
| `shell` | `Bash` | `command_execution` | Shell or command execution |
| `file_read` | `Read` | `none` | Canonical read category; the current Codex shipped mapping does not expose a first-class read tool |
| `file_write` | `Write` | `file_change` with `kind=create` | Create/write operations; Codex exec currently uses this bucket for all `file_change` events |
| `file_edit` | `Edit` | `file_change` with `kind=update` or `kind=modify` (app-server) | In-place file modification; Codex exec does not currently split this out |
| `web_fetch` | `web_fetch` | `web_search` | HTTP/web retrieval |
| `mcp_call` | MCP tool call | `mcp_tool_call` | Tool calls routed through an MCP server |

ACP reverse-calls map at the handler-level, not in the one-way provider event parser: `fs/read_text_file` -> `file_read`,
`fs/write_text_file` -> `file_write`, and `terminal/create` -> `shell`. ACP terminal lifecycle calls
(`terminal/output`, `terminal/wait_for_exit`, `terminal/kill`, `terminal/release`) preserve their raw ACP method names
for audit but operate only on host-created terminal IDs and do not create a second shell-execution path.

Inference rules:

- Claude and Codex use the canonical mapping table above directly.
- In Codex, `file_change` with `kind=create` maps to `file_write`.
- In Codex, `file_change` with `kind=update` or `kind=modify` maps to `file_edit`.
- `command_execution` maps to `shell`.

Unmapped tools are prefixed with `provider:name` for auditability and explicit policy handling. Example: an unknown Codex item becomes `codex:reasoning`, and an unknown Claude item becomes `claude:some_tool`. DartClaw logs a warning when this fallback is used, and the guard chain remains fail-closed for security-sensitive guards.

**Source**: `packages/dartclaw_core/lib/src/harness/canonical_tool.dart`, `packages/dartclaw_core/lib/src/harness/claude_protocol_adapter.dart`, `packages/dartclaw_core/lib/src/harness/codex_protocol_adapter.dart`, [ADR-016](../adrs/016-multi-provider-harness-architecture.md)

### Guard Chain Interception per Provider

Different providers expose different interception points. DartClaw keeps the guard chain aligned with the provider boundary instead of assuming a single universal hook.

| Provider / mode | Mechanism | DartClaw integration point | Security boundary |
|-----------------|------------|-----------------------------|-------------------|
| Claude Code | `--dangerously-skip-permissions` + hooks | `PreToolUse` hook callback; permission handler is a no-op because native permission prompts are skipped | Guard chain is the active interception point before tool execution |
| Codex (app-server) | Approval requests only | `approval` control request handler in `CodexHarness`; must keep approvals enabled and must not use `--yolo` for provider-approval security mode | Approval response path is the only interception point |
| ACP direct-provider, verified | Host-advertised ACP `fs`/`terminal` capabilities | `AcpReverseCallHandlers` map reverse-calls to canonical tools before host action | Guard-mediated only after verification proves the agent honors host reverse-call mediation |
| ACP relay-provider or unverified | No trustworthy reverse-call mediation claim | Container profile and workspace jail only | Container-isolation-only until per-agent verification proves guard mediation |

For Claude Code, DartClaw starts the binary with `--dangerously-skip-permissions`, then intercepts tool use through hooks. The native permission handler is effectively a no-op in this mode, so guard enforcement must happen in Dart before the provider tool runs.

For Codex app-server, the approval request is the only interception point. DartClaw must preserve approval prompts and must not use `--yolo`, because bypassing the approval request would remove the guard chain from the execution path.

For ACP agents, security classification is topology-scoped. Direct-provider ACP agents such as verified Goose or Vibe targets can be guard-mediated when they use host-advertised `fs` and `terminal` capabilities and startup validation proves the declared provider is not a proxy. Other ACP topologies can still run under container isolation, but DartClaw does not describe them as mediated by guards.

**Source**: `packages/dartclaw_core/lib/src/harness/claude_code_harness.dart`, `packages/dartclaw_core/lib/src/harness/codex_harness.dart`, `packages/dartclaw_core/lib/src/harness/acp_harness.dart`, `packages/dartclaw_core/lib/src/harness/acp_reverse_call_handlers.dart`, [ADR-016](../adrs/016-multi-provider-harness-architecture.md)

---

## InputSanitizer

Scans inbound messages for prompt injection patterns. Channels-only by default — web UI messages bypass because the operator is trusted. Truncates oversized content at 10,000 characters to bound regex backtracking time (GuardChain's 5-second timeout provides the outer safety net).

**Built-in pattern categories** (case-insensitive):

| Category | Example Patterns |
|----------|-----------------|
| **Instruction override** | `ignore all previous`, `disregard above`, `forget your instructions`, `you are now`, `new role:` |
| **Role-play** | `pretend you are`, `act as if`, `roleplay as` |
| **Prompt leak** | `repeat your system prompt`, `show me your instructions`, `what are your rules` |
| **Meta-injection** | `[INST]`, `<\|im_start\|>`, `<system>`, `<tool_result>` |

Extra patterns (regex strings) can be added via `guards.input_sanitizer.extra_patterns` in config, categorized as `'custom'`.

**Source**: `packages/dartclaw_security/lib/src/input_sanitizer.dart`

---

## CommandGuard

Evaluates only on `beforeToolCall` for the `Bash` tool. Strips single-quoted strings to prevent bypass via `'rm' '-rf'`, extracts pipe segments, and matches against configurable regex patterns.

**Pattern categories**:

| Category | What It Catches |
|----------|----------------|
| **Destructive** | `rm -rf`, `rm -fr`, `chmod 777/000/a+rwx`, `mkfs.`, `dd if=`, write to `/dev/sd` |
| **Force operations** | `git push --force`, `git push -f`, `git reset --hard`, `git clean -f` |
| **Fork bombs** | `:() {`, `\| : &` |
| **Interpreter escapes** | `eval`, `bash -c`, `sh -c`, `python -c`, `node -e`, `perl -e`, `ruby -e`, backtick subshells, `xargs sh/bash/python` |
| **Blocked pipe targets** | `sh`, `bash`, `zsh`, `dash`, `python`, `python3`, `perl`, `ruby`, `node`, `sed` |

Safe pipe targets are explicitly allowlisted: `jq`, `grep`, `sort`, `wc`, `head`, `tail`, `cat`, `less`, `tee`, `uniq`, `tr`, `cut`, `awk`, `fmt`, `column`.

**Design note**: `$(...)` subshells are intentionally not blocked because the inner command is still scanned by all pattern categories. Variable expansion bypasses (e.g. `v=rm; $v -rf`) cannot be caught statically — container isolation is the primary defense for that class of attack.

**Source**: `packages/dartclaw_security/lib/src/command_guard.dart`

---

## FileGuard

Glob-based file path protection for Bash, `write_file`, and `edit_file` tools. Resolves symlinks to prevent traversal attacks (e.g. `/var` -> `/private/var` on macOS). Extracts paths from bash commands including redirect targets, `cp`/`mv` sources and destinations, and classifies operations as read, write, or delete.

**Access levels**:

| Level | Read | Write | Delete |
|-------|------|-------|--------|
| `noAccess` | Blocked | Blocked | Blocked |
| `readOnly` | Allowed | Blocked | Blocked |
| `noDelete` | Allowed | Allowed | Blocked |

**Default protection rules**:

| Pattern | Access Level | Rationale |
|---------|-------------|-----------|
| `**/.ssh/**`, `**/.ssh` | `noAccess` | SSH keys and config |
| `**/.gnupg/**`, `**/.gnupg` | `noAccess` | GPG keys |
| `**/.aws/credentials` | `noAccess` | AWS credentials |
| `**/.netrc` | `noAccess` | Network credentials |
| `**/.env`, `**/.env.*` | `readOnly` | Environment variables with secrets |
| `**/*.pem`, `**/*.key` | `readOnly` | TLS certificates and private keys |
| `**/.kube/config` | `readOnly` | Kubernetes config |
| `**/.gitconfig` | `noDelete` | Git configuration |
| `**/.bashrc`, `**/.zshrc`, `**/.profile` | `noDelete` | Shell profiles |

**Self-protection**: `FileGuardConfig.withSelfProtection(configPath)` adds a `readOnly` rule for `dartclaw.yaml` itself, preventing the agent from modifying the config that controls its own security.

Extra rules can be added via `guards.file.extra_rules` in config.

Workflow research/writing/analysis steps run through the coding-task/worktree path and rely on `configJson.readOnly = true` plus a post-turn `git status` check against the task worktree. Restricted-profile isolation still applies to non-workflow research tasks; workflow steps express write policy through `readOnly` instead of a distinct restricted dispatch path.

**Source**: `packages/dartclaw_security/lib/src/file_guard.dart`

---

## NetworkGuard

Domain allowlisting and exfiltration pattern detection. Evaluates Bash tool calls and `web_fetch` tool calls. Blocks all direct IP addresses (IPv4 and IPv6) to prevent SSRF-like bypasses at the guard level.

**Default allowed domains**:

```
github.com, *.github.com, api.anthropic.com, pypi.org, *.pypi.org,
npmjs.com, *.npmjs.com, registry.npmjs.org, pub.dev, *.pub.dev,
*.googleapis.com, dart.dev, *.dart.dev, crates.io, rubygems.org,
stackoverflow.com
```

**Exfiltration patterns blocked**:

| Pattern | Attack Vector |
|---------|--------------|
| `curl ... \| sh/bash` | Pipe-to-shell remote code execution |
| `wget ... -O - \| sh/bash` | Pipe-to-shell via wget |
| `curl ... -d/--data/--form` | POST data exfiltration |
| `\| base64` | Encoding for covert data exfiltration |

**Per-agent overrides**: The `agent_overrides` config section allows granting additional domains to specific sub-agents (e.g. search agent may need broader web access).

**Source**: `packages/dartclaw_security/lib/src/network_guard.dart`

---

## ContentGuard

LLM-based content classification at inter-agent boundaries. Fires only at the `beforeAgentSend` hook point — when a sub-agent (e.g. search agent) returns results to the main agent. This catches prompt injection and harmful content that bypassed regex-based guards by being embedded in web search results.

**Classification categories**: `safe`, `prompt_injection`, `harmful_content`, `exfiltration_attempt`.

**Behavior**:
- Truncates content to 50KB (UTF-8 safe) before classification
- Skips Cloudflare challenge pages (`CloudflareDetector.isCloudflareChallenge`) to avoid false positives
- Configurable fail behavior: fail-closed (default) or fail-open
- 15-second classification timeout

**Source**: `packages/dartclaw_security/lib/src/content_guard.dart`, `packages/dartclaw_security/lib/src/content_classifier.dart`

---

## ToolPolicyGuard

3-layer policy cascade wrapping `ToolPolicyCascade` for integration with the guard chain. Only evaluates when a sub-agent context is present (`context.agentId != null`). Main agent calls pass through.

**Evaluation order** (most restrictive wins):

```
1. Global deny   — always blocked regardless of agent
2. Agent deny    — blocked for this specific agent
3. Sandbox allow — only explicitly listed tools are permitted (closed set)
```

A tool passes only if it is NOT in global deny, NOT in agent deny, AND IS in the agent's allow set (if an allow set is defined).

Example: The search agent's sandbox is `{web_search, web_fetch}` — all other tools (Bash, Read, Write, etc.) are denied at the OS level and policy level, providing defense-in-depth.

**Source**: `packages/dartclaw_core/lib/src/agents/tool_policy_cascade.dart`

---

## Container Isolation

### Architecture

When `container.enabled: true`, the agent runs inside a Docker container. The Dart host spawns a long-lived container via `docker create` + `docker start` with `sleep infinity`, then uses `docker exec` for each turn to avoid per-turn container startup overhead.

### Docker Security Flags

```
docker create \
  --name dartclaw-<hash>-<profile> \
  --network none \                          # No direct internet access
  --cap-drop ALL \                          # Drop all Linux capabilities
  --read-only \                             # Read-only root filesystem
  --tmpfs /tmp:rw,noexec,nosuid,size=100m \ # Writable tmp, no exec, 100MB cap
  --security-opt no-new-privileges \        # Prevent privilege escalation
  -v <workspace>:/workspace:rw \            # Workspace mount (workspace profile only)
  -v <dataDir>/projects/:/projects:ro \     # All project clones (parent-directory mount)
  -v <project>:/project:ro \                # Legacy alias for default project (backward compat)
  -v <proxySocketDir>:/var/run/dartclaw \   # Credential proxy socket
  -e ANTHROPIC_BASE_URL=http://localhost:8080 \  # Redirect API calls to proxy
  dartclaw-agent:latest \
  sleep infinity
```

### Container Image

Minimal Debian Bookworm slim image with only essential packages: `ca-certificates`, `curl`, `git`, `socat`. Runs as non-root user `dartclaw` (uid 1000). Claude CLI installed via official installer script.

**Source**: `docker/Dockerfile`

### Per-Type Container Isolation (ADR-012)

Different security profiles get separate containers. Multiple tasks of the same profile share one container via `docker exec`.

| Profile | Container Name | Mounts | Used By |
|---------|---------------|--------|---------|
| **workspace** | `dartclaw-<hash>-workspace` | `/workspace:rw`, `/projects:ro`, `/project:ro` (legacy alias) | Main chat, coding tasks, cron jobs |
| **restricted** | `dartclaw-<hash>-restricted` | No workspace or project mounts | Search agent, research tasks |

**Container naming**: `dartclaw-<fnv1a8(dataDir)>-<profileId>` — deterministic 8-char FNV-1a digest of the data directory (Docker-safe local identifier, not cryptographic), collision-free across multiple DartClaw installs on the same Docker daemon.

**Dispatch routing**: `ContainerDispatcher` maps task types to security profiles:

```
research  → restricted  (no filesystem access)
coding    → workspace   (full workspace access)
writing   → workspace
analysis  → workspace
automation → workspace
custom    → workspace
```

**Source**: `packages/dartclaw_server/lib/src/container/container_manager.dart`, `packages/dartclaw_server/lib/src/container/security_profile.dart`, `packages/dartclaw_server/lib/src/container/container_dispatcher.dart`

### Multi-Provider Sandbox Interaction

ADR-016 makes provider selection first-class, so sandbox settings need to reflect both deployment boundary and harness mode. This matrix mirrors the PRD sandbox interaction table and uses the same operational rule: when Docker is the boundary, prefer `danger-full-access` for Codex app-server and exec to avoid double-sandboxing conflicts; outside Docker, keep Codex on its own sandbox.

| Deployment | Harness mode | Codex sandbox | Approval | Boundary note |
|-----------|--------------|---------------|----------|---------------|
| Docker container | `app-server` | `danger-full-access` | On | Docker is the primary boundary; Codex permissions stay active for tool approvals. |
| Docker container | `exec` | `danger-full-access` | `--full-auto` | One-shot execution; container isolation is the boundary and no approval chain exists. |
| Bare metal | `app-server` | `workspace-write` | On | Codex sandbox provides defense-in-depth when Docker is absent. |
| Bare metal | `exec` | `workspace-write` | `--full-auto` | Stateless batch execution on trusted hosts; keep Codex sandbox enabled. |
| Task worktree | `app-server` | `workspace-write` + `--cd <worktree>` + `--add-dir <data-dir>` | On | Anchor Codex to the task worktree and let it manage approvals. |
| Task worktree | `exec` | `workspace-write` + `--cd <worktree>` + `--add-dir <data-dir>` | `--full-auto` | Same worktree anchoring, but without approval interception. |

The worktree rows are intentionally narrower than the Docker rows: they assume a trusted host-side task workspace and preserve Codex's own sandboxing instead of widening to `danger-full-access`. That keeps task execution deterministic while still respecting the per-provider boundary described in ADR-016.

### Container Health Monitoring

`ContainerHealthMonitor` runs periodic health checks (every 10 seconds by default) on all managed containers. State transitions (healthy -> unhealthy, unhealthy -> healthy) are surfaced as `ContainerCrashedEvent` and `ContainerStartedEvent` via the EventBus.

**Source**: `packages/dartclaw_server/lib/src/container/container_health_monitor.dart`

---

## Credential Security

### The Problem

The agent needs API access to provider backends, but API keys must never be exposed to the wrong execution boundary. A compromised agent with shell access could trivially read environment variables or files containing credentials if credentials were injected into the wrong place.

### The Solution: Credential Proxy

The Dart host runs a `CredentialProxy` — an HTTP proxy on a Unix socket that injects API credentials into outbound requests. The container connects to this proxy via a `socat` TCP-to-Unix-socket bridge. This remains the boundary for containerized Claude Code deployments.

```
Container (network:none)                     Host
┌──────────────────────────┐           ┌──────────────────────┐
│ claude binary            │           │ CredentialProxy      │
│   ANTHROPIC_BASE_URL=    │           │   socketPath:        │
│   http://localhost:8080  │──socat──▶ │   /run/dartclaw/     │
│                          │  bridge   │   proxy.sock         │
│ socat TCP-LISTEN:8080    │           │                      │
│   → UNIX-CLIENT:         │           │ Injects:             │
│     /var/run/dartclaw/   │           │   x-api-key: <key>   │
│     proxy.sock           │           │   Authorization:     │
└──────────────────────────┘           │     Bearer <key>     │
                                       │                      │
                                       │   → api.anthropic.com│
                                       └──────────────────────┘
```

**Key properties**:
- Unix socket is `chmod 600` (owner-only) to prevent other host processes from injecting credential headers
- Container has no network access except through the proxy
- API keys never exist inside the container environment or filesystem
- Supports both API-key mode (key injected by proxy) and OAuth/setup-token mode (host `~/.claude.json` mounted read-only, proxy forwards existing auth headers unchanged)
- Proxy tracks request/error counts for observability
- The proxy path is unchanged for containerized Claude Code and remains the canonical host-side credential boundary

### Multi-Provider Credential Management

DartClaw resolves credentials per provider family through `CredentialRegistry`, which is keyed by provider ID/family rather than by a single global provider assumption. The registry maps Claude to Anthropic credentials and Codex to OpenAI credentials, with environment-variable fallback when configured secrets are not present.

Credential handling is then adapted to the provider boundary:

- Claude Code in a container keeps using `CredentialProxy`; the host injects credentials into outbound requests and the agent container never receives raw keys in its environment.
- Codex uses direct environment-variable injection at subprocess startup, so the resolved provider credential is passed to the Codex process instead of being proxied through the container bridge.
- Startup validation checks that required provider credentials are available before a harness is started, so a missing provider secret fails fast instead of surfacing as a late request-time error.

This keeps the container/proxy model intact for Claude while allowing Codex to use the simpler direct-env path documented in ADR-016.

**Source**: `packages/dartclaw_config/lib/src/credential_registry.dart`, `packages/dartclaw_core/lib/src/harness/claude_code_harness.dart`, `packages/dartclaw_core/lib/src/harness/codex_harness.dart`, `packages/dartclaw_server/lib/src/container/credential_proxy.dart`

**Diagram**: [Credential Proxy (Excalidraw)](../diagrams/credential-proxy.excalidraw)

### Git Credential Integration

Project management introduces a separate credential path for git operations — clone, fetch, and push — that is distinct from the API credential proxy.

**Reference-based model**: `projects:` config references credentials by name (e.g., `credentials: github-ssh-key`). The credential store holds the actual key; `projects.json` stores only the reference name. This means credential rotation does not require touching project config.

**Injection at operation time**: Credentials are resolved and injected as environment variables immediately before each git subprocess is spawned inside `Isolate.run()`:

| Transport | Injected variable | Effect |
|-----------|------------------|--------|
| SSH | `GIT_SSH_COMMAND=ssh -i /path/to/key -o IdentitiesOnly=yes` | Forces ssh to use only the specified identity file |
| HTTPS | `GIT_ASKPASS=/path/to/askpass-helper` | Helper script echoes the resolved token; never stored in config |

**Security properties**:
- Git credentials never appear in `projects.json`, `dartclaw.yaml`, or any other persisted file — only the reference name is stored
- Credential resolution happens inside the Isolate, not in the main event loop
- `MessageRedactor` covers any credential-adjacent strings that might surface in agent output
- Git operations run on the host, not inside the container — they do not have access to the API credential proxy and do not need it

**Source**: `packages/dartclaw_server/lib/src/task/project_service.dart`

### Subprocess Hygiene

Sensitive workflow and git paths are routed through `SafeProcess` in `dartclaw_security`.

- `SafeProcess.start` / `SafeProcess.run` require an explicit `EnvPolicy`; the wrapper always sets `includeParentEnvironment: false`, so child processes only receive the environment DartClaw constructs intentionally.
- `EnvPolicy.sanitize` applies a pattern-based strip (`*_API_KEY`, `*_SECRET`, `*_TOKEN`, `*_CREDENTIAL`, `*_PASSWORD`) before optionally filtering to an allowlist. The workflow bash-step path uses this together with `SecurityConfig.bashStep.envAllowlist`, so normal shell basics (`PATH`, `HOME`, `LANG`, `LC_*`, `TZ`, `USER`, `SHELL`, `TERM`) survive while provider/API secrets do not.
- The one-shot workflow CLI runner now routes through the same contract instead of relying on a raw `Process.start(... environment: sanitizedMap)` call that silently re-inherited the parent env.

### Git Subprocess Centralization

Every production git subprocess now flows through `SafeProcess.git(... plan: GitCredentialPlan, ...)`.

- `EnvPolicy.credentialPlan` preserves the git-safe baseline env, strips parent secrets, overlays `GitCredentialPlan.environment`, and keeps `includeParentEnvironment: false`.
- Workflow-owned git paths add `GIT_CONFIG_NOSYSTEM=1` so system-level git config cannot inject hooks, filter drivers, or transport helpers into workflow automation, while user-visible CLI git continues to respect normal user/system git configuration.
- `WorktreeManager`'s default git runner always sets `noSystemConfig: true`. `git worktree add` performs a checkout, so system-level filter drivers and hooks would otherwise run inside workflow/task automation. Operators who rely on `/etc/gitconfig` (e.g. `insteadOf`, `core.sshCommand`, `core.hooksPath`) should move those to user-level (`~/.gitconfig`), which remains in effect.
- The malicious-repo regression is now explicit in tests: a fixture repo with `core.sshCommand` cannot read `ANTHROPIC_API_KEY` from the parent process even when the git operation itself is allowed to run. A separate `post-checkout`-hook sentinel test proves workflow-owned worktree creation propagates `GIT_CONFIG_NOSYSTEM=1` to git children.

### Google Chat User OAuth Refresh Tokens

Google Chat Workspace Events user auth and reaction auth share a refresh token store in `$dataDir/google-chat-user-oauth.json`. The file is written with an atomic temp-file rename and is `chmod 600` on Unix so only the DartClaw user can read it.

DartClaw uses a dual-client pattern here: service-account credentials handle bot messages and Pub/Sub pull, while user OAuth handles Google Chat reactions and user-auth Workspace Events subscription management. When `reactions_auth: user` is enabled, the reaction client is loaded from the shared credential store, and reactions appear under the authenticated user's profile rather than the bot identity.

---

## Access Control

### HTTP Authentication (ADR-006)

Token bootstrap + stateless HMAC-signed session cookies. Single-user system — no username/password.

**Auth flow**:

```
shelf Pipeline
  1. logRequests()
  2. securityHeadersMiddleware()
  3. corsMiddleware()
  4. authMiddleware()
     ├── Skip: /health, /login, /static/, /favicon.ico, /webhook/*
     ├── Check: Cookie (HMAC-signed) → valid session → pass
     ├── Check: Authorization: Bearer <token> → pass
     ├── Check: ?token= on GET → validate → set cookie → redirect
     └── Else: browser → redirect /login ; API → 401 JSON
  5. router.call
```

**Token management**:
- Auto-generated: `Random.secure()` -> 32 bytes -> 64 hex chars
- Persisted to `$dataDir/gateway_token` with `chmod 600`
- Printed at startup: `Web UI: http://localhost:<port>/?token=<hex64>`
- Rotation: `dartclaw token rotate` generates new token, invalidates all sessions

**Session cookies**:
- HMAC-SHA256 signed with gateway token as key, stateless (no server-side storage)
- Format: `base64url(payload).base64url(signature)` where payload = `{"iat": unix_ms}`
- Cookie flags: `HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000` (30 days)
- Token rotation auto-invalidates all cookies (new token = new signing key)
- Constant-time string comparison prevents timing attacks on token validation

**Security response headers** (global):

```
Referrer-Policy: no-referrer       # Prevent token leakage via referrer
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Cache-Control: no-store            # Auth-gated pages not cached
```

**Webhook auth**: Excluded from gateway auth middleware. Each webhook integration (WhatsApp GOWA, Signal, Google Chat) implements its own verification (HMAC signatures, JWT, shared secrets) scoped to its routes.

**Additional defenses**:
- `maxWebhookPayloadBytes = 1 MiB` — rejects oversized POST bodies on unauthenticated webhook endpoints to prevent OOM attacks
- `readBounded()` caps stream reads for chunked/missing-header cases
- `AuthRateLimiter` throttles failed auth attempts per source to blunt token-guessing brute force

**Source**: `packages/dartclaw_server/lib/src/auth/auth_middleware.dart`, `packages/dartclaw_server/lib/src/auth/session_token.dart`, `packages/dartclaw_server/lib/src/auth/token_service.dart`, `packages/dartclaw_server/lib/src/auth/auth_utils.dart`

### Channel Access Control

DM access is controlled per-channel via `DmAccessController`:

| Mode | Behavior |
|------|----------|
| `pairing` | Unknown senders receive a pairing code; operator confirms via web UI to add to allowlist |
| `allowlist` | Only pre-configured sender IDs can message the bot |
| `open` | Any sender can message the bot |
| `disabled` | DMs are rejected entirely |

**Pairing flow**:
1. Unknown sender messages the bot
2. `DmAccessController.createPairing()` generates an 8-character code (ambiguity-free charset: no 0/O/1/I)
3. Pairing code sent back to the sender with instructions
4. Operator reviews pending pairings in web UI, confirms or rejects
5. On confirmation, sender JID added to allowlist

**Constraints**: Maximum 3 concurrent pending pairings, 1-hour expiry, expired pairings automatically evicted.

**Source**: `packages/dartclaw_core/lib/src/channel/dm_access.dart`

---

## Audit Chain

### Guard Audit Logger

All guard evaluations are logged with timestamps, verdicts, and context. The `GuardAuditLogger` writes to both stdout (structured log lines) and `audit.ndjson` (append-only file sink).

**Log levels**:
- `INFO` — pass verdicts
- `WARNING` — warn verdicts
- `SEVERE` — block verdicts

**File sink** (`audit.ndjson`):
- Fire-and-forget writes via `unawaited()` — guard verdict latency is never affected by I/O
- Sequential writes chained via `_pendingWrite` future to prevent interleaving
- Rotation: every 100 writes, checks if entries exceed 10,000; keeps newest N entries via atomic temp-file + rename

**AuditEntry fields**: `timestamp`, `guard`, `hook`, `verdict`, `reason`, `sessionId`, `channel`, `peerId`.

**Source**: `packages/dartclaw_security/lib/src/guard_audit.dart`

### EventBus Integration

Guard block/warn events are published to the EventBus only when the application layer wires `GuardChain.onVerdict` to `EventBus.fire(GuardBlockEvent(...))`, enabling decoupled subscribers:

```
GuardChain._evaluate()
  └── onVerdict?.call(...)
        └── ServiceWiring callback
              └── EventBus.fire(GuardBlockEvent)
                    └── GuardAuditSubscriber.subscribe()
                          └── GuardAuditLogger.logVerdict()
```

`GuardAuditSubscriber` lives in `dartclaw_server` and bridges the event bus to the audit logger, preserving identical stdout and NDJSON output. The subscriber pattern replaced the direct `auditLogger` coupling on `GuardChain` in 0.7. The same subscriber also listens for `ToolPermissionDeniedEvent`, so provider-native denials are visible in the audit trail alongside DartClaw guard verdicts.

**EventBus exception safety**: `EventBus.fire()` is wrapped in `runZonedGuarded` — subscriber exceptions are logged but never propagate to the firing code.

### Container and Agent Events

The EventBus also surfaces security-relevant infrastructure events:

| Event | When |
|-------|------|
| `ContainerCrashedEvent` | Container health check detects crash |
| `ContainerStartedEvent` | Container recovered or started |
| `ContainerStoppedEvent` | Container stopped normally |
| `AgentStateChangedEvent` | Agent busy/idle transitions |

**Source**: `packages/dartclaw_core/lib/src/events/dartclaw_event.dart`

---

## Content Classification

### ContentClassifier

Abstract interface for LLM-based content classification at agent boundaries. Returns one of: `safe`, `prompt_injection`, `harmful_content`, `exfiltration_attempt`. Throws on error — the caller decides fail-open vs fail-closed behavior.

**Source**: `packages/dartclaw_security/lib/src/content_classifier.dart`

### MessageRedactor

Regex-based redaction for outbound text across all output paths. Catches secrets that the agent might inadvertently include in responses.

**Built-in patterns** (order: PEM first for multi-line, then specific, then generic):

| Pattern | What It Catches |
|---------|----------------|
| PEM blocks | `-----BEGIN ... -----` through `-----END ... -----` |
| Stripe keys | `sk_live_*`, `pk_test_*` |
| Anthropic keys | `sk-ant-*` |
| AWS Access Key ID | `AKIA` + 16 chars |
| AWS Secret Access Key | `aws_secret_access_key = ...` |
| Bearer tokens | `Bearer <token>` |
| Generic secrets | `api_key: ...`, `secret = ...`, `token: ...`, `password = ...` |

**Redaction strategy**: Proportional reveal — preserves `min(matchLength / 2, 8)` leading characters + `***`. PEM blocks are fully replaced with `[REDACTED]`. The `redact()` method never throws — errors are caught internally and the original text is returned unchanged.

Extra patterns can be added via config (`logging.redact_patterns`).

**Source**: `packages/dartclaw_security/lib/src/message_redactor.dart`

---

## Web Security

### SSRF Hardening (WebFetchTool)

The `web_fetch` MCP tool fetches URLs on behalf of the agent. SSRF protection prevents the agent from probing internal infrastructure.

**Blocked address ranges**:

| Range | Description |
|-------|-------------|
| `127.0.0.0/8` | Loopback |
| `169.254.0.0/16` | Link-local |
| `10.0.0.0/8` | RFC1918 private |
| `172.16.0.0/12` | RFC1918 private |
| `192.168.0.0/16` | RFC1918 private |
| `100.64.0.0/10` | CGNAT (RFC6598) |
| `0.0.0.0/8` | Unspecified |
| `224.0.0.0/4` and above | Multicast/reserved |
| `::1` | IPv6 loopback |
| `fc00::/7` | IPv6 ULA |
| `::ffff:0:0/96` (mapped to private IPv4) | IPv4-mapped IPv6 |

**DNS resolution check**: Hostnames are resolved via `InternetAddress.lookup()` and all resolved addresses are checked against the blocked ranges. This catches DNS rebinding attacks where a hostname resolves to an internal IP.

**Additional protections**:
- Only `http` and `https` schemes allowed
- Content classified via `ContentClassifier` before returning to the agent
- Cloudflare challenge pages detected and skipped
- Response length capped (default 50,000 chars)

**Source**: `packages/dartclaw_server/lib/src/mcp/web_fetch_tool.dart`

### XSS Prevention

The web UI uses Trellis HTML templates with `tl:text` for auto-escaping by default. `tl:utext` is used only for trusted HTML (e.g. pre-rendered markdown). Data attributes use `tl:attr` for proper escaping, preventing attribute injection from user-controlled values (e.g. allowlist entries containing special characters).

### CSRF Protection

DartClaw defends against cross-site request forgery in depth rather than relying on any single control:

- **`SameSite=Strict` session cookies** (primary). The session cookie is not sent on cross-site requests, so a forged cross-origin request arrives unauthenticated. This blocks the common CSRF vector at the browser level without CSRF tokens. It is strong but not absolute — older browsers, some same-site navigation edge cases, and misconfigured intermediaries can weaken the guarantee — so it is backed by an explicit server-side check.
- **Same-origin Origin/Host guard** (`origin_host_guard.dart`, wired in `server.dart` via `originHostGuardMiddleware`). For unsafe methods (POST/PUT/PATCH/DELETE) on cookie-authenticated requests, the middleware compares the request's `Origin` authority — scheme, host, effective port — against the request's own `Host` authority (falling back to `Referer` when `Origin` is absent) and returns **403** on mismatch or when neither header is present. Safe methods (GET/HEAD/OPTIONS), Bearer-token (API-client) requests, and no-auth local-admin sessions are exempt.
- **Security headers / CSP** (`security_headers.dart`, outermost middleware). Every response carries a strict `Content-Security-Policy` (`default-src 'none'`, inline-script hash + explicit CDN allowlist, `form-action 'self'`, `frame-ancestors 'none'`), plus `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, and (when `gateway.hsts` is enabled) HSTS. `form-action 'self'` and `frame-ancestors 'none'` further constrain cross-origin form posting and framing.

---

## Task Security

### TaskFileGuard

Per-task file access registry for coding task worktree isolation. When a coding task's git worktree is created, its path is registered as allowed. File access requests are validated against registered paths using `path.isWithin()` with canonicalized paths.

```
TaskFileGuard (multi-project)
  register(taskId, worktreePath)   # worktree under projects/<projectId>/; on worktree creation
  isAllowed(taskId, filePath)      # path.canonicalize + path.isWithin
  deregister(taskId)               # on worktree cleanup (accept/reject/cancel)
```

**Properties**:
- Uses `p.canonicalize()` on both the registered path and the checked path to prevent traversal attacks
- Returns `false` if no path is registered for the task ID (deny by default)
- Registration is removed on task completion (accept, reject, cancel) but preserved on failure for debugging
- In multi-project mode, worktrees are nested under `<dataDir>/projects/<projectId>/`, so each task is scoped to its assigned project's directory

**Multi-project scoping note**: The parent-directory mount (`/projects:ro`) gives the agent OS-level read access to all project clones. `TaskFileGuard` provides the application-layer write scoping — the agent is constrained to its assigned task's worktree directory and cannot write to other project directories. This application-layer boundary is acceptable for DartClaw's single-user product scope, where the primary security boundary remains Docker container isolation.

This is distinct from `FileGuard` (which protects sensitive system paths globally). `TaskFileGuard` provides per-task path containment — a coding task can only modify files within its own git worktree.

**Source**: `packages/dartclaw_server/lib/src/task/task_file_guard.dart`

---

## Runtime Governance

Runtime governance is a defense-in-depth layer (Layer 5) that protects deployments from cost overruns, abuse, and runaway agent behavior. Unlike guards (Layer 3), which evaluate individual tool calls and messages, governance operates at the session and system level — throttling inbound message rates, capping daily token consumption, and detecting autonomous loop patterns.

All governance features are configured under the `governance:` YAML section and are disabled by default (0 = disabled convention). Missing `governance:` section results in all defaults (all disabled).

### Admin Sender Model

`governance.admin_senders` lists sender IDs exempt from per-sender rate limits. When the list is empty (default), **all senders are treated as admins** — suitable for single-user deployments. When non-empty, only the listed IDs are exempt. Admin status is checked via `GovernanceConfig.isAdmin(senderId)`.

Admin exemptions apply to per-sender rate limiting only. Global turn rate limits and budget enforcement apply to all senders equally, including admins.

**Source**: `packages/dartclaw_config/lib/src/governance_config.dart`

### Per-Sender Rate Limiting

Sliding window rate limit on inbound channel messages, keyed by sender JID. Enforced in `ChannelTaskBridge.tryHandle()` after thread binding checks but before review command or task trigger routing.

**Behavior**:
- Rejects excess messages with a polite "too fast" response and returns `true` (consumed — not enqueued to agent)
- Exempt: admin senders, review commands (`accept`, `reject`, `push back`), reserved commands (`/status`, `/stop`, `/pause`, `/resume`)
- Messages routed via thread binding bypass rate limiting entirely — intentional for shared task threads where many participants may reply in the same conversation

**Configuration**: `governance.rate_limits.per_sender.messages` (max messages) + `governance.rate_limits.per_sender.window_minutes` (sliding window). 0 messages = disabled.

### Global Turn Rate Limiting

Sliding window rate limit on turn reservations across all sessions and senders combined. Enforced in `TurnRunner.reserveTurn()`.

**Behavior**:
- Defers turn reservation (waits for window capacity) rather than rejecting — ensures messages are eventually processed
- Emits SSE `rate_limit_warning` event at 80% usage; resets hysteresis below 60%

**Configuration**: `governance.rate_limits.global.turns` (max turns) + `governance.rate_limits.global.window_minutes` (sliding window). 0 turns = disabled.

### Rate Limiter Design

`SlidingWindowRateLimiter` uses lazy eviction — expired entries are removed on `check()` calls, not on a background timer. `check()` both verifies and records the event atomically: a passing check records; a failing check does not inflate the counter. This makes it safe to use in deferral retry loops without self-inflating. All rate limit state is in-memory — resets on server restart.

**Source**: `packages/dartclaw_core/lib/src/governance/sliding_window_rate_limiter.dart`

### Daily Token Budget Enforcement

Caps daily token consumption (input + output tokens combined) with configurable warn or block behavior. Enforced by `BudgetEnforcer` which reads persisted daily totals from `UsageTracker.dailySummaryForDate()` in the KvService.

**Thresholds**:

| Usage | `warn` mode | `block` mode |
|-------|-------------|-------------|
| < 80% | Allow | Allow |
| >= 80% | Post warning (once per day), then allow | Post warning (once per day), then allow |
| >= 100% | Post warning (once per day), then allow | Block new turns until next budget window |

**Key properties**:
- Warning is posted once per day per threshold crossing — the `budget_warning_posted_at` flag is persisted in the daily usage summary via KvService to survive restarts
- Timezone-aware: uses `BudgetConfig.timezone` to determine "today". Supports `UTC`, `UTC+N`, `UTC-N` formats; named IANA timezones fall back to UTC with a warning
- Budget resets at midnight in the configured timezone (implicit — new date key = new budget window)
- Token totals are read from the existing `UsageTracker` daily aggregation pipeline, not tracked independently

**Configuration**: `governance.budget.daily_tokens` (0 = disabled), `governance.budget.action` (`warn` | `block`), `governance.budget.timezone` (default: `UTC`).

**Source**: `packages/dartclaw_server/lib/src/governance/budget_enforcer.dart`

### Loop Detection

Detects runaway agent behavior using three independent mechanisms. Injected into `TurnRunner`. All state is in-memory — resets on server restart. Each mechanism is independently disableable by setting its threshold to 0.

**Mechanism 1 — Turn chain depth**: Counts consecutive agent-initiated turns per session. Incremented on each autonomous turn, reset when a human-initiated message arrives. Triggers when depth exceeds `max_consecutive_turns`.

**Mechanism 2 — Token velocity**: Tracks token consumption in a rolling time window per session. Triggers when total tokens consumed within `velocity_window_minutes` exceeds `max_tokens_per_minute * velocity_window_minutes`. Uses lazy eviction of expired entries.

**Mechanism 3 — Tool fingerprinting**: Tracks consecutive identical tool calls within a single turn. A tool call fingerprint is computed from the tool name and canonical JSON of its arguments (sorted keys). Triggers when the same fingerprint appears `max_consecutive_identical_tool_calls` or more times consecutively.

**Actions** (configurable via `governance.loop_detection.action`):

| Action | Behavior |
|--------|----------|
| `abort` | Throws `LoopDetectedException`, cancels the turn. `TaskExecutor` catches and transitions the task to `failed`. |
| `warn` | Fires `LoopDetectedEvent` on the EventBus for logging and observability. Turn continues. |

**Source**: `packages/dartclaw_core/lib/src/governance/loop_detector.dart`, `packages/dartclaw_core/lib/src/governance/loop_detection.dart`

### Emergency Controls

Admin-only commands for immediate system-wide intervention, invoked via channel slash commands (Google Chat) or reserved message prefixes.

#### `/stop` — Emergency Stop

Aborts all active turns and cancels all running/queued tasks in a single best-effort sequence:

```
EmergencyStopHandler.execute():
  1. Cancel all active turns across all runners in the harness pool
     (iterates HarnessPool.runners, calls cancelTurn for each active session)
  2. Transition all running and queued tasks to cancelled
     (review/draft/accepted/rejected are left for manual resolution)
  3. Fire EmergencyStopEvent on EventBus
  4. Broadcast emergency_stop SSE event for web UI awareness
```

Individual failures during the sequence are logged but do not halt execution — remaining turns and tasks are still cancelled. Returns `EmergencyStopResult` with counts of cancelled turns and tasks.

**Source**: `packages/dartclaw_server/lib/src/emergency/emergency_stop_handler.dart`

#### `/pause` and `/resume` — Message Queuing

`/pause` suspends all message processing. Inbound messages are queued in-memory (up to 200 messages). `/resume` drains the queue with structured per-sender concatenation — messages from the same sender in the same session are collapsed into a single summary message.

**PauseController behavior**:
- `pause(adminName)`: Sets paused state, records who paused and when. Idempotent — returns `false` if already paused.
- `enqueue(message, channel, sessionKey)`: Buffers messages during pause. Returns `QueueResult.full` at capacity (200 messages).
- `drain()`: Unpauses atomically, groups queued messages by session key, then by sender within each session. Produces `sessionKey -> collapsed text` map. Format: "While paused, N participant(s) sent messages:" followed by "- SenderName: msg1, msg2, ...".

All pause state is in-memory — resets automatically on server restart (no persistence needed — a restart already interrupts message flow).

**Source**: `packages/dartclaw_server/lib/src/governance/pause_controller.dart`

### Thread Binding Security

Thread binding introduces a routing path that bypasses normal session-keying logic for Google Chat task threads. Security considerations:

- **Rate limit bypass**: Messages routed via thread binding bypass per-sender rate limiting. This is intentional for shared task threads that can receive input from many participants; global turn rate limiting still applies.
- **Admin-only binding creation**: Thread bindings are created automatically by `TaskNotificationSubscriber` when a task starts, not by arbitrary senders. Only tasks with a valid `TaskOrigin` (created via an admin-initiated trigger) produce bindings.
- **Binding lifecycle**: Bindings are reconciled on startup (`ThreadBindingStore.reconcile()`) to prune entries for terminal tasks. Expired bindings (by `lastActivity`) can be removed via `removeExpiredBindings()`.
- **Persistence**: `ThreadBindingStore` persists to `<dataDir>/thread-bindings.json` using atomic writes (temp file + rename). Loaded on startup; missing or corrupt file starts empty without error.

### Sender Attribution

Tasks created via channel triggers carry sender identity for audit trails:

- `Task.createdBy`: Stores the sender display name or JID of the user who triggered the task
- `TaskOrigin`: Enriched with channel type, contact ID, recipient ID, source message ID, and sender attribution fields (`senderDisplayName`, `senderId`, `senderAvatarUrl`) — providing full provenance for channel-originated tasks

This attribution chain enables audit logging of who requested what work, independent of the session where the task executes.

### Governance Configuration Reference

```yaml
governance:
  admin_senders: []           # empty = all are admins (backward compat)
  rate_limits:
    per_sender:
      messages: 10            # 0 = disabled
      window_minutes: 5       # sliding window duration
    global:
      turns: 60               # 0 = disabled
      window_minutes: 60      # sliding window duration
  budget:
    daily_tokens: 100000      # 0 = disabled
    action: warn              # warn | block
    timezone: UTC             # UTC, UTC+N, UTC-N
  loop_detection:
    enabled: false
    max_consecutive_turns: 0  # 0 = disabled
    max_tokens_per_minute: 0  # 0 = disabled
    velocity_window_minutes: 5
    max_consecutive_identical_tool_calls: 0  # 0 = disabled
    action: abort             # abort | warn
```

---

## JSONL Control Protocol Security

The Dart host communicates with the `claude` binary via bidirectional JSONL over stdin/stdout. Security-relevant protocol features:

### Hook Callbacks

Guards are integrated with the `claude` binary's hook system. During the `initialize` handshake, the Dart host registers `PreToolUse`, `PostToolUse`, `PermissionDenied`, and `PreCompact` hook callbacks. `PreToolUse` remains the enforcement path; `PostToolUse` is audit-only; `PermissionDenied` surfaces Claude-native denials into the audit/EventBus path; `PreCompact` gives DartClaw a deterministic signal before provider compaction starts.

```json
// Binary → Dart: "Should I run this Bash command?"
{"type": "control_request", "request_id": "X",
 "request": {"subtype": "hook_callback", "callback_id": "hook_bash_pre",
  "input": {"hook_event_name": "PreToolUse", "tool_name": "Bash",
   "tool_input": {"command": "rm -rf /"}}}}

// Dart → Binary: "No."
{"type": "control_response",
 "response": {"subtype": "success", "request_id": "X",
  "response": {"continue": true,
   "hookSpecificOutput": {"hookEventName": "PreToolUse",
    "permissionDecision": "deny"}}}}
```

`PreToolUse` registrations now use Claude's `if:` filtering support where possible, limiting guard callbacks to tools DartClaw actually evaluates (`Bash`, `Write`, `Edit`, `Read`, `MultiEdit`). This reduces subprocess round-trips without changing the security model.

### Tool Approval

With `--permission-prompt-tool stdio`, the binary sends `can_use_tool` control requests for every tool invocation. The Dart host can approve or deny based on tool name, input, and agent context.

### Environment Isolation

The `claude` binary is spawned with `includeParentEnvironment: false` and a filtered copy of `Platform.environment`. Critical environment variables are cleared to prevent nesting detection errors: `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`.

Direct host-side Claude spawns inherit Claude's user, project, and local setting sources by default. This intentionally exposes user-scope plugins and skills to spawned sessions and workflow one-shots. Security-conscious deployments that require project-only settings can set `providers.claude.inherit_user_settings: false`, which adds `--setting-sources project` to direct Claude invocations. Containerized spawns remain unchanged; their isolation comes from container mounts, environment, and network policy rather than the Claude settings-source flag.

**Source**: `packages/dartclaw_core/lib/src/harness/tool_policy.dart`, ADR-001 Addendum

---

## Security Configuration

All security features are configurable via `dartclaw.yaml`:

```yaml
guards:
  enabled: true               # Master switch for all guards
  fail_open: false             # false = fail-closed (default, safer)
  input_sanitizer:
    enabled: true
    channels_only: true        # Only scan channel messages
    extra_patterns: []         # Additional regex patterns
  command:
    extra_blocked_patterns: [] # Additional command patterns
    extra_blocked_pipe_targets: []
  file:
    extra_rules:               # Additional file protection rules
      - pattern: '**/secrets/**'
        level: no_access
  network:
    extra_allowed_domains: []
    extra_exfil_patterns: []
    agent_overrides: {}        # Per-agent domain overrides
  content:
    enabled: true
    model: haiku
    fail_open: false

container:
  enabled: false               # Docker isolation
  image: dartclaw-agent:latest
  mounts: []                   # Extra volume mounts
  extra_args: []               # Extra docker create arguments

gateway:
  auth_mode: token             # token | none
```

---

## Cross-References

### Architecture Decision Records

| ADR | Topic |
|-----|-------|
| [ADR-001](../adrs/001-sdk-integration-and-security-architecture.md) | SDK integration strategy, security architecture, credential proxy pattern, control protocol |
| [ADR-005](../adrs/005-whatsapp-integration.md) | WhatsApp integration, DM access control patterns, outpost pattern |
| [ADR-006](../adrs/006-http-auth-scope.md) | HTTP auth mechanism (token bootstrap + HMAC session cookies), EventSource SSE auth |
| [ADR-012](../adrs/012-per-type-container-isolation.md) | Per-type container isolation, security profiles, dispatch model |

### Related Documents

| Document | Location |
|----------|----------|
| Data Model | `dev/architecture/data-model.md` — `audit.ndjson`, `usage.jsonl` rotation and lifecycle |
| Feature Comparison | `docs/specs/feature-comparison.md` — OpenClaw vs NanoClaw vs DartClaw security models |
| Public Security Guide | `../dartclaw-public/docs/guide/security.md` — user-facing summary |
| Security Hardening PRD | `docs/specs/0.5/prd.md` — InputSanitizer, MessageRedactor, ContentClassifier |
| 0.12 PRD | `docs/specs/0.12/prd.md` — Runtime governance, emergency controls, thread binding, sender attribution |
| System Architecture | `dev/architecture/system-architecture.md` — Inbound Message Pipeline, Runtime Governance, and Emergency Controls |

### Key Source Files

| File | Package | Purpose |
|------|---------|---------|
| `security/guard.dart` | `dartclaw_security` | Guard interface, GuardContext, GuardChain |
| `security/guard_verdict.dart` | `dartclaw_security` | Sealed GuardVerdict hierarchy (pass/warn/block) |
| `security/guard_audit.dart` | `dartclaw_security` | AuditEntry, GuardAuditLogger |
| `security/input_sanitizer.dart` | `dartclaw_security` | Prompt injection detection |
| `security/command_guard.dart` | `dartclaw_security` | Dangerous command blocking |
| `security/file_guard.dart` | `dartclaw_security` | Path protection, symlink resolution |
| `security/network_guard.dart` | `dartclaw_security` | Domain allowlist, exfiltration detection |
| `security/content_guard.dart` | `dartclaw_security` | LLM-based content classification guard |
| `security/content_classifier.dart` | `dartclaw_security` | ContentClassifier interface |
| `security/message_redactor.dart` | `dartclaw_security` | Proportional secret redaction |
| `agents/tool_policy_cascade.dart` | `dartclaw_core` | 3-layer tool policy, ToolPolicyGuard |
| `security/task_tool_filter_guard.dart` | `dartclaw_security` | Per-task tool allowlist + read-only mode |
| `container/container_manager.dart` | `dartclaw_server` | Docker container lifecycle, security flags |
| `container/credential_proxy.dart` | `dartclaw_server` | Unix socket API key injection proxy |
| `container/security_profile.dart` | `dartclaw_server` | Workspace/restricted security profiles |
| `container/container_dispatcher.dart` | `dartclaw_server` | Task type -> security profile routing |
| `container/container_config.dart` | `dartclaw_models` | Container configuration data type |
| `channel/dm_access.dart` | `dartclaw_core` | DmAccessController, pairing flow |
| `auth/auth_middleware.dart` | `dartclaw_server` | shelf auth pipeline |
| `auth/session_token.dart` | `dartclaw_server` | HMAC-signed stateless session tokens |
| `auth/token_service.dart` | `dartclaw_server` | Gateway token generation, rotation, persistence |
| `auth/auth_utils.dart` | `dartclaw_server` | Constant-time comparison, bounded body reads |
| `auth/auth_rate_limiter.dart` | `dartclaw_server` | Throttles failed auth attempts to blunt brute force |
| `auth/security_headers.dart` | `dartclaw_server` | Security response headers middleware |
| `audit/guard_audit_subscriber.dart` | `dartclaw_server` | EventBus -> GuardAuditLogger bridge |
| `mcp/web_fetch_tool.dart` | `dartclaw_server` | SSRF-hardened URL fetcher |
| `task/task_file_guard.dart` | `dartclaw_server` | Per-task worktree path containment |
| `container/container_health_monitor.dart` | `dartclaw_server` | Periodic container health checks |
| `harness/tool_policy.dart` | `dartclaw_core` | Control protocol tool approval/hook responses |
| `governance_config.dart` | `dartclaw_config` | GovernanceConfig, RateLimitsConfig, BudgetConfig, LoopDetectionConfig |
| `governance/sliding_window_rate_limiter.dart` | `dartclaw_core` | In-memory sliding window rate limiter |
| `governance/loop_detector.dart` | `dartclaw_core` | 3-mechanism loop detection (turn chain, velocity, fingerprint) |
| `governance/loop_detection.dart` | `dartclaw_core` | LoopDetection result, LoopMechanism enum, LoopDetectedException |
| `channel/thread_binding.dart` | `dartclaw_core` | ThreadBinding model, ThreadBindingStore persistence |
| `governance/budget_enforcer.dart` | `dartclaw_server` | Daily token budget enforcement, timezone-aware |
| `governance/pause_controller.dart` | `dartclaw_server` | In-memory pause/resume with per-sender message collapsing |
| `emergency/emergency_stop_handler.dart` | `dartclaw_server` | Emergency stop orchestration (cancel turns + tasks) |
| `docker/Dockerfile` | root | Container image definition |
