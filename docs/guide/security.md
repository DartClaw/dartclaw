# Security

DartClaw uses defense-in-depth: multiple independent layers so that no single compromise breaks all boundaries.

## Architecture

```
User ──→ HTTP Auth ──→ Dart Host ──→ Guards ──→ Provider Boundary
                           │                        │
                     Guard Chain              Claude container path:
                     Audit Logger              network:none
                     Content Guard             CredentialProxy
                                               Mount Allowlist
                                              Codex: provider approval
                                              ACP relay/unverified: restricted container
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

On supported POSIX hosts, when Docker is available, DartClaw runs the claude binary inside a container with:
- `network:none` -- no direct internet access
- Capability drops (`--cap-drop ALL`)
- Read-only root filesystem
- Credential proxy (Unix socket) for API access
- Mount allowlist for workspace files

Container isolation is unavailable on native Windows even when Docker is installed. Its credential-proxy socket and
owner-only permissions require POSIX facilities, so `container.enabled: true` fails closed and directs the operator to
a POSIX host or WSL. See the [Windows capability matrix](windows.md#capability-matrix).

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
- **Same-origin Origin/Host check.** For unsafe methods (POST/PUT/PATCH/DELETE) on cookie-authenticated requests, the server compares the request's `Origin` (or `Referer`) authority against its own `Host` and returns **403** on mismatch or when neither header is present. API clients using a Bearer token and no-auth local-admin sessions are exempt.
- **Security headers.** Every response carries a strict `Content-Security-Policy` (including `form-action 'self'` and `frame-ancestors 'none'`), plus `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, and HSTS when `gateway.hsts` is enabled.

## Credential Proxy

The credential proxy currently secures the Claude/Anthropic container path. The Dart host runs a `CredentialProxy` on a Unix socket that injects authentication headers into outbound Anthropic API requests. The container's `network:none` means this proxy is the **sole egress path** for that flow — there is no direct internet access from the Claude container.

### How It Works

```
Container (network:none)                          Host
┌────────────────────────────┐             ┌───────────────────────┐
│                            │             │                       │
│  claude binary             │             │  CredentialProxy      │
│    ANTHROPIC_BASE_URL=     │             │    Unix socket:       │
│    http://localhost:8080   │             │    <data>/proxy/      │
│          │                 │             │    proxy.sock         │
│          ▼                 │             │    (chmod 600)        │
│  socat bridge              │  bind-mount │                       │
│    TCP-LISTEN:8080 ────────┼─────────────┼──► Injects headers:  │
│    → UNIX-CLIENT:          │             │      x-api-key        │
│      /var/run/dartclaw/    │             │      Authorization    │
│      proxy.sock            │             │          │            │
│                            │             │          ▼            │
└────────────────────────────┘             │  api.anthropic.com   │
                                           └───────────────────────┘
```

1. **Dart host** starts `CredentialProxy` on `<dataDir>/proxy/proxy.sock` with `chmod 600` (owner-only access). The API key is held in host memory only.
2. **Container** is created with `--network none`. The socket directory is bind-mounted into the container at `/var/run/dartclaw/`.
3. **socat** runs inside the container, bridging a local TCP port to the Unix socket: `TCP-LISTEN:8080 → UNIX-CLIENT:/var/run/dartclaw/proxy.sock`.
4. **`ANTHROPIC_BASE_URL`** environment variable points the `claude` binary at the socat listener (`http://localhost:8080`).
5. When the Claude agent makes an API call, the request flows through the chain. The proxy injects `x-api-key` and `Authorization: Bearer` headers before forwarding to `api.anthropic.com` over HTTPS.

### Authentication Modes

| Mode | When | Behavior |
|------|------|----------|
| **API key** | `ANTHROPIC_API_KEY` is configured | Proxy injects `x-api-key` and `Authorization: Bearer <key>` headers |
| **OAuth passthrough** | No API key (OAuth or setup token) | Proxy forwards existing auth headers from the `claude` binary unchanged |

In OAuth mode, the host's `~/.claude.json` is mounted read-only into the container so the `claude` binary can authenticate directly. The proxy acts as a transparent relay without adding credentials.

> Codex and ACP providers do not use this Anthropic-specific credential proxy path. Codex uses the Codex CLI's own auth flow or `CODEX_API_KEY`; ACP agents use their configured provider's credential mechanism.

For production, prefer API-key based credentials managed by the service environment or secret manager rather than interactive login state. Use `ANTHROPIC_API_KEY` for Claude/Anthropic, `CODEX_API_KEY` for Codex/OpenAI, and provider-specific secrets for ACP targets such as Goose or Vibe. The credential boundary is provider-specific: `CredentialProxy` isolates Claude container credentials, Codex receives only its resolved API key or CLI auth context, and ACP agents receive only the environment or files needed for that configured agent.

### Security Properties

- **Key isolation** — API keys never exist inside the container (not in env vars, filesystem, or process memory)
- **Owner-only socket** — `chmod 600` prevents other host processes from connecting
- **Sole egress** — `network:none` means the Unix socket is the only way out of the container
- **Observability** — the proxy tracks request and error counts for health monitoring

## ACP and Delegation Security Modes

ACP security claims are topology-scoped:

| Mode | When to use | Security claim |
|------|-------------|----------------|
| Direct provider, verified | The ACP agent directly controls the model provider and verification proves it honors host filesystem reverse-calls | Guard-mediated. ACP `fs/read_text_file` and `fs/write_text_file` are bound to the active task session and evaluated by DartClaw guards before host action |
| Relay provider | The ACP target forwards work through another provider CLI or relay path | Container-isolation-only. No guard-mediation claim |
| Unverified | Startup evidence is absent or insufficient | Container-isolation-only until verification proves reverse-call mediation |
| Codex delegation | Delegated Codex work with approvals/sandbox enabled | Provider-approval mode, not guard-mediated |

`delegate_to_agent` enforces these classifications before spawn. If an allowlist entry sets `require_guard_mediation: true`, relay and unverified ACP agents are rejected, and Codex is rejected because its delegated mode is `security_mode: "provider_approval"`. A restricted container profile is the safe default for relay or unverified ACP agents.

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
