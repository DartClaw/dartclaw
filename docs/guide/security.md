# Security

DartClaw uses defense-in-depth: multiple independent layers so that no single compromise breaks all boundaries.

## Architecture

```
User ──→ HTTP Auth ──→ Dart Host ──→ Guards ──→ Provider Boundary
                           │                        │
                     Guard Chain              Claude/Codex container path:
                     Audit Logger              network:none
                     Content Guard             Host Gateway
                                               Mount Allowlist
                                              Codex: provider approval
                                              ACP: host execution only
```

## Guard System

Guards evaluate tool calls, messages, and agent responses. First block wins. Exceptions = block (fail-closed).

### Built-in Guards

| Guard | Category | What It Blocks |
|-------|----------|---------------|
| **InputSanitizer** | input | Prompt injection patterns (instruction override, role-play, prompt leak, meta-injection) |
| **CommandGuard** | command | Shell injection, dangerous commands (rm -rf, curl to untrusted hosts) |
| **FileGuard** | filesystem | Access to `.ssh/`, `.aws/`, credentials files, symlink escape |
| **NetworkGuard** | network | Connections to non-allowlisted hosts/ports |
| **ContentGuard** | content | Prompt injection, harmful content at agent boundaries |
| **TaskToolFilterGuard** | tool | Tools not in the task's allowlist; mutating tools while a task is read-only |

### Configuration

```yaml
guards:
  input_sanitizer:
    enabled: true               # default: true
    channels_only: true          # default: true — only scan channel messages, web UI bypasses
    extra_patterns:              # optional additional regex patterns (case-insensitive)
      - 'custom\s+injection'
  command:
    extra_blocked_patterns:      # regex patterns added to defaults
      - 'curl.*--upload'
  file:
    extra_rules:                 # added to default protections
      - pattern: '*.secret'
        level: no_access
  network:
    extra_allowed_domains:       # added to default allowlist
      - api.example.com
  content:
    enabled: true
    model: haiku
```

The **InputSanitizer** ships with built-in patterns for 4 injection categories and requires no configuration for baseline protection. Set `channels_only: false` to also scan web UI messages.

### Guard Editor (Web UI)

Admins can manage guard extensions from the **Settings** page instead of hand-editing YAML. The editor groups the command, file, network, and input-sanitizer guards and lets you list, add, edit, delete, and test their **extension** fields:

| Guard | Editable extension field |
|-------|--------------------------|
| Command | `extra_blocked_patterns` |
| File | `extra_rules` |
| Network | `extra_allowed_domains` |
| Input sanitizer | `extra_patterns` |

Built-in default rules are shown as read-only context — the editor manages extension surfaces only, not the built-in defaults.

How it behaves:

- **Validation is fail-closed.** Malformed regex or conflicting entries are rejected at save time; the previously active guard chain stays in force until a valid change is applied. Saving never weakens the running chain.
- **The tester mirrors the runtime.** Enter a sample command, file path, or URL and the tester evaluates it through the same guard semantics the runtime uses, returning the same verdict class and reason — no approximate preview.
- **Activation is explicit.** A save response separates what became active immediately (hot-reloaded) from what is **pending restart**, and the UI surfaces the distinction so you know when a restart is still required.
- **Admin-gated (fail closed).** Add, edit, delete, and test actions require admin access, enforced server-side. With gateway auth enabled every authenticated session has admin access and unauthenticated requests never reach these routes; with `gateway.auth_mode: none` the local instance acts as the single admin. Requests without admin context are rejected.

Changes persist to the same YAML-backed config (`guards:` block above) that the file-based workflow uses — the editor is a safer authoring front end, not a separate store. Equivalent JSON endpoints back the UI for scripted use:

| Endpoint | Purpose |
|----------|---------|
| `GET /api/config/guards` | Editable extension state plus read-only built-in summary and pending-restart status |
| `POST /api/config/guards/<guard>/<field>` | Append an extension entry |
| `PUT /api/config/guards/<guard>/<field>/<index>` | Replace an entry |
| `DELETE /api/config/guards/<guard>/<field>/<index>` | Remove an entry |
| `POST /api/config/guards/test` | Evaluate a sample input through real guard semantics |

Mutation and test endpoints return `403` for requests without admin access.

## Container Isolation

On supported POSIX hosts, when Docker is available, DartClaw runs the packaged `claude` or `codex` binary inside a container with:
- `network:none` -- no direct internet access
- Capability drops (`--cap-drop ALL`)
- Read-only root filesystem
- Host-mediated provider access over framed `docker exec` pipes (see below) -- no credential in the container
- Mount allowlist for workspace files

ACP agents have no container execution: DartClaw mediates no provider credential or host capability for an ACP client,
so ACP registrations run on the host only and a container-requiring registration is rejected at startup.

Container isolation is unavailable on native Windows even when Docker is installed. Its per-authority pipes and
owner-only generated state require POSIX facilities, so `container.enabled: true` fails closed and directs the operator
to a POSIX host or WSL. See the [Windows capability matrix](windows.md#capability-matrix).

### Pragmatic Mode

Without container isolation, guards serve as the primary security boundary. This is suitable for personal use on a
trusted machine, but it is not isolation parity.

## HTTP Authentication

The web UI and API support token-based and cookie-based authentication:

```yaml
gateway:
  auth_mode: token    # token | none
  token: ${DARTCLAW_TOKEN}
```

### CSRF and same-origin protection

Cookie-authenticated browser sessions are defended against cross-site request forgery in depth, not by a single control:

- **`SameSite=Strict` session cookies** keep the cookie off cross-site requests, so a forged cross-origin request arrives unauthenticated. This is the primary defense and needs no CSRF tokens — strong, but not treated as absolute.
- **Same-origin Origin/Host check.** For unsafe methods (POST/PUT/PATCH/DELETE) on cookie-authenticated requests, the server compares the request's `Origin` (or `Referer`) authority against its own `Host` and returns **403** on mismatch or when neither header is present. No-auth local-admin writes additionally require both the configured server host and request `Host` to be literal loopback hosts; matching non-local `Origin` and `Host` values are rejected. Origin-less loopback API clients remain supported. API clients using a Bearer token are exempt.
- **Security headers.** Every response carries a strict `Content-Security-Policy` (including `form-action 'self'` and `frame-ancestors 'none'`), plus `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, and HSTS when `gateway.hsts` is enabled.

## Host-Mediated Provider Credentials

Provider credentials stay on the host. A containerized agent never receives an API key, a login file, or a reusable
token – it is given a loopback endpoint, and the host decides what that endpoint reaches and what authentication it
carries. The container keeps `network:none`, so this mediated path is its **only** way to a provider.

### How It Works

```
Container (network:none)                          Host
┌────────────────────────────┐             ┌───────────────────────┐
│                            │             │                       │
│  claude / codex binary     │             │  HostGateway          │
│    endpoint:               │             │    one authority per   │
│    http://127.0.0.1:8080   │             │    live execution      │
│          │                 │             │          │            │
│          ▼                 │             │          ▼            │
│  dartclaw-bridge           │ docker exec │  Provider adapter     │
│    (read-only, host-owned) ├──── -i ────►│    pins the upstream  │
│                            │  stdio pipe │    injects the key    │
│                            │             │          │            │
└────────────────────────────┘             │          ▼            │
                                           │  api.anthropic.com /  │
                                           │  api.openai.com       │
                                           └───────────────────────┘
```

1. Each live container authority gets its own container and its own bridge processes. Nothing is shared between
   executions, and nothing survives one.
2. The only host object in the container is the **read-only** `dartclaw-bridge` executable. There is no socket mount,
   no published port, and no network attachment.
3. The bridge listens on container loopback and forwards bounded, framed traffic to the host over the `docker exec -i`
   pipe the host opened. It chooses no destination and holds no credential.
4. On the host, the adapter bound to that pipe pins the upstream origin, drops any client-supplied credential header,
   and injects the host-held key before forwarding over HTTPS.

### Authentication Modes

| Provider | Container mode | Host mode |
|----------|----------------|-----------|
| **Claude** | Host-held `ANTHROPIC_API_KEY` only. The adapter injects `x-api-key`; the container sees neither the key nor `~/.claude.json` | API key, OAuth login, or setup token |
| **Codex** | A generated auth-clean home selects a custom Responses provider pointed at the host gateway with client authentication disabled. The host adapter supplies the upstream key | API key or the Codex CLI's own auth |

Containerized Claude supports **API-key mediation only**. OAuth and setup-token logins have no credential-free
mediation contract, so a container execution configured that way is rejected before the turn starts, naming host
execution as the supported alternative – it is never silently downgraded. Set `ANTHROPIC_API_KEY` on the host for
container mode, or select `execution: host` for that agent.

The containerized Codex home is created fresh for each execution, contains only generated client configuration, and is
deleted when the authority is released. The host's `~/.codex/` is never mounted or copied: a logged-in Codex will
forward its saved bearer even when the client is told not to authenticate, so the only safe container home is one that
was never seeded.

For production, prefer API keys managed by the service environment or a secret manager over interactive login state.

### Security Properties

- **Key isolation** – provider credentials never exist inside the container: not in environment variables, mounted or
  generated files, command arguments, or generated client configuration
- **No shared token** – containers receive no shared operator MCP bearer; the execution-scoped pipe is the identity
- **Pinned destination** – the adapter owns the upstream origin and the allowed request paths, so a container cannot
  name where its traffic goes
- **Sole egress** – `network:none` means the host-owned pipe is the only way out of the container
- **Non-replayable** – authority is bound to one execution and revoked on release; a captured pipe cannot be revived

## ACP and Logical-Agent Security Modes

ACP security claims are topology-scoped:

| Mode | When to use | Security claim |
|------|-------------|----------------|
| Direct provider, verified | The ACP agent directly controls the model provider and verification proves it honors host filesystem reverse-calls | Guard-mediated. ACP `fs/read_text_file` and `fs/write_text_file` are bound to the active task session and evaluated by DartClaw guards before host action |
| Relay provider | The ACP target forwards work through another provider CLI or relay path | No guard-mediation claim, so a container is the only boundary it could have — and DartClaw has no ACP container mediation, so the registration is rejected at startup |
| Unverified | Startup evidence is absent or insufficient | Same as relay: rejected at startup until verification proves reverse-call mediation |
| Codex agent sessions | Codex with `approval: on-request` | Guard-mediated for supported command, file-change, and MCP operations that emit provider approval requests; unevaluated authority is declined and the sandbox remains an independent boundary |

Logical agents select providers through `agent.agents.<id>.provider` and may select `security_profile: workspace|restricted` independently. The built-in search agent requests `restricted`; other agents use an enforced ACP provider profile when present, otherwise `workspace`. Provider startup validation and exact provider/profile worker acquisition enforce the configured boundary before a logical-agent session can run. An unavailable `restricted` profile fails closed instead of falling back to host execution. An ACP provider runs on the host only, so give an agent that uses one an explicit `execution: host`; a resolved container policy is refused before the turn starts.

DartClaw does not advertise ACP `terminal/create` on any host; filesystem reverse-calls remain available. Host terminal execution stays disabled until DartClaw can prove containment of the complete spawned process tree.

## Audit Logging

All guard evaluations are logged with timestamps, verdicts, and context. Post-tool-use events log success/failure for audit trail.

Retention controls are explicit and disabled or conservative by default:

| Data | Config key | Purpose |
|------|------------|---------|
| Guard audit partitions | `guard_audit.max_retention_days` | Deletes dated guard audit files older than the limit |
| Sessions | `sessions.maintenance.prune_after_days` | Archives or prunes inactive sessions when maintenance is enabled |
| Cron sessions | `sessions.maintenance.cron_retention_hours` | Deletes orphaned cron sessions older than the limit |
| Task artifacts | `tasks.artifact_retention_days` | Cleans terminal task artifacts after terminal tasks complete |
| Knowledge inbox processed files | `knowledge.inbox.processed_retention_days` | Removes processed inbox files after the configured retention window |

Set these values deliberately for production deployments. Retention reduces local data exposure, but it is not a substitute for provider-side data retention controls in Anthropic, OpenAI, Mistral, or another configured provider account.
