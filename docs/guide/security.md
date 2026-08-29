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

> **Workflow one-shot steps do not pass through the guard chain.** A workflow step runs as a single
> non-interactive provider invocation rather than through the long-lived harness, and that path has no hook
> channel for guards to evaluate on — so `CommandGuard`, `FileGuard`, `NetworkGuard`, `ContentGuard`, and the
> guard audit log do not apply to it. What does constrain such a step: the step's own `allowedTools` allow-list
> (enforced by the provider), the read-only tool denials, the denied native web tools, and — when enabled —
> container isolation with its `network:none` boundary and mount allowlist. A step that declares no
> `allowedTools` and runs outside a container is therefore constrained only by the provider's own defaults.
> Run workflows under container isolation, and declare `allowedTools` on every step, if a workflow may act on
> untrusted input.

### Built-in Guards

| Guard | Category | What It Blocks |
|-------|----------|---------------|
| **InputSanitizer** | input | Prompt injection patterns (instruction override, role-play, prompt leak, meta-injection) |
| **CommandGuard** | command | Shell injection, dangerous commands (rm -rf, curl to untrusted hosts) |
| **FileGuard** | filesystem | Access to `.ssh/`, `.aws/`, credentials files, symlink escape |
| **NetworkGuard** | network | Connections to non-allowlisted hosts/ports |
| **ContentGuard** | content | Prompt injection and harmful content at agent boundaries, in `web_fetch` results, and in results from `network_class: public` MCP servers |
| **TaskToolFilterGuard** | tool | Tools not in the task's allowlist; mutating tools while a task is read-only |

When content classification is configured, a successful `tools/call` against an outbound MCP server declared
`network_class: public` is classified before its result reaches an agent — declare a content-bearing server `public` to
get that scanning; results from `local` and `private` servers are not scanned. Two limits are worth knowing:

- The scan covers the `text` of every content block that carries one — the same string the agent receives. A result with
  no text-carrying block has nothing to score and is passed unclassified.
- A result whose text exceeds `guards.content.max_bytes` is **denied**, not prefix-scanned. Raise `max_bytes` for servers
  with large payloads.

The scope is `tools/call` results only. Tool *descriptions* a `public` server advertises through `tools/list` are not
classified.

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

### File Ownership on Native Linux

The container image runs its agent process as uid 1000, and on native Linux Docker, bind-mount file ownership passes
through verbatim. DartClaw aligns the per-execution host directories it mounts (generated state, artifacts) to uid 1000
with a best-effort `chown` — a no-op when the service already runs as uid 1000 (the default first user on most
distributions). This is the standard bind-mount uid-mismatch constraint every containerized tool shares, not a
DartClaw-specific one; Docker Desktop on macOS/Windows masks it entirely through its own uid remapping.

Running the service as a **dedicated non-1000 user** (for example a `dartclaw` system account) therefore needs one of:

- **root or `CAP_CHOWN`** for the service process, so the alignment `chown` succeeds, or
- **rootless / userns-remapped Docker**, where the daemon maps container uid 1000 into the service user's subordinate
  uid range — this works with zero extra privileges and is the recommended unprivileged posture.

Without either, containerized executions fail on their mounted state and artifact directories. The alignment is
best-effort by design (a failed `chown` is logged, never fatal) so uid-remapped daemons are unaffected.

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

`${VAR}` references resolve at startup. If the variable is unset, DartClaw treats `gateway.token` as absent rather than
as an empty token — it warns, falls back to the generated `gateway_token` file in the data directory, and refuses a hot
reload of the unresolved value. See [Configuration](configuration.md#status-and-token-commands).

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
                                           │  api.openai.com /     │
                                           │  chatgpt.com backend  │
                                           └───────────────────────┘
```

1. Each live container authority gets its own container and its own bridge processes. Nothing is shared between
   executions, and nothing survives one.
2. The host objects the mediation path adds are the **read-only** `dartclaw-bridge` executable, a writable per-authority
   generated-state directory mounted at `/home/dartclaw/.dartclaw` (the container's home for generated client
   configuration, deleted with the authority), and – only for an execution that writes durable artifacts – a writable
   host-owned directory mounted at `/artifacts`. There is no socket mount, no published port, and no network attachment.
3. The bridge listens on container loopback and forwards bounded, framed traffic to the host over the `docker exec -i`
   pipe the host opened. It chooses no destination and holds no credential.
4. On the host, the adapter bound to that pipe pins the upstream origin, drops any client-supplied credential header,
   and injects the host-held credential before forwarding over HTTPS. The answer is filtered the same way on the way
   back: the pipe is the only channel into the container, so credential-bearing response headers (`authorization`,
   `x-api-key`, `proxy-authenticate`, `set-cookie`) are dropped before anything is written back — an upstream or error
   page that reflects a request header would otherwise hand the host's credential into the boundary.

### Authentication Modes

**Subscription authentication is the default for both providers, on both execution boundaries.** When a subscription
credential is stored, DartClaw presents it; an API key is used when no subscription credential is present, and stays a
fully supported choice you can select explicitly. Exactly one credential is presented upstream per execution.

| Provider | Host mode | Container mode |
|----------|-----------|----------------|
| **Claude** | The stored `setup-token` is passed to the real `claude` CLI as `CLAUDE_CODE_OAUTH_TOKEN`; the CLI makes its own calls | The host adapter injects `Authorization: Bearer <setup-token>` plus `anthropic-beta: oauth-2025-04-20`, drops any client-supplied auth header, and pins `api.anthropic.com`. The container holds no credential |
| **Codex** | The real `codex` CLI runs against DartClaw's dedicated `CODEX_HOME` and owns refresh in that store | The host adapter re-pins the upstream to `https://chatgpt.com/backend-api/codex` and injects `Authorization: Bearer <access token>` plus `ChatGPT-Account-ID`, read from the dedicated store per request |
| **Either, on an API key** | The key is injected into the harness subprocess environment | The adapter injects `x-api-key` (Claude, `api.anthropic.com`) or `Authorization: Bearer` (Codex, `api.openai.com`) |

The Codex host row covers every host lane: the interactive and workflow lanes a running `dartclaw serve` owns, and a
standalone `dartclaw workflow` run outside the server. All of them spawn the vendor CLI against the dedicated
`CODEX_HOME`, never your own `~/.codex` login.

The container boundary is unchanged by this. A containerized execution still runs with `network:none` and still holds no
credential in its environment, filesystem, arguments, or generated configuration – only *which* credential the host
injects on the outbound leg, and which upstream it is pinned to, differ between subscription and API-key mode.

> **Note – container-mode Claude on a subscription.** The raw-`Authorization: Bearer` `setup-token` path is verified
> against a real token: Anthropic accepted a stored `setup-token` presented as a raw Bearer under the
> `oauth-2025-04-20` beta (pre-ship gate, 2026-08-17). There is no runtime `x-api-key` fallback: the Anthropic adapter selects its
> header from the resolved credential mode alone, so an upstream refusal fails the turn rather than silently degrading
> to a key. A 401 or 403 answered to a subscription turn is treated as the credential itself being refused — the
> container is told why, the execution's container is destroyed, and the provider is marked `reauth-required` — rather
> than being forwarded as a bare 401. Host-mode Claude is unaffected.

The containerized Codex home is created fresh for each execution, contains only generated client configuration, and is
deleted when the authority is released. The host's `~/.codex/` is never mounted or copied: a logged-in Codex will
forward its saved bearer even when the client is told not to authenticate, so the only safe container home is one that
was never seeded.

### Setting Up Subscription Authentication

DartClaw keeps its own credential stores. When it resolves a subscription credential it takes the one in its own store,
and it never writes back to your personal `~/.claude` or `~/.codex` login. (Two paths still *read* your own login: the
startup auth-status probe, and `providers.codex.use_system_codex_home: false`, which seeds an isolated home from
`~/.codex/auth.json`.) Store a credential per provider:

```bash
# Claude – issue a setup token with the vendor CLI, then hand it to DartClaw over stdin
claude setup-token
dartclaw auth claude          # prompts with hidden input, or accepts the token piped on stdin
```

`dartclaw auth claude` takes no argument. A token passed on a command line lands in your shell history and in the
process list, so the command refuses positional arguments and reads the value only from stdin.

```bash
# Codex – DartClaw runs the vendor login against its own home
dartclaw auth codex           # runs `codex login` with CODEX_HOME set to DartClaw's dedicated store
```

**Addressing the right instance.** The store is derived from `data_dir`, so `dartclaw auth` must resolve the same one
`dartclaw serve` reads. Pass the global `--config` for the instance's YAML, and `--data-dir` whenever `serve` is started
with a `--data-dir` that overrides the YAML value:

```bash
dartclaw --config /etc/dartclaw/dartclaw.yaml auth claude --data-dir /var/lib/dartclaw
```

A credential written against a different `data_dir` is invisible to the server, which refuses the provider as if none
were stored – the refusal names the directory it searched, so compare that against the path `dartclaw auth` printed.

**Where credentials live.** Both stores sit under the instance data directory (`~/.dartclaw` by default, or
`$DARTCLAW_HOME` / the configured `data_dir`):

| Provider | Path | Written by |
|----------|------|------------|
| Claude | `<data_dir>/credentials/claude/setup-token.json` | DartClaw, atomically (temp file + rename) |
| Codex | `<data_dir>/credentials/codex/` – used as `CODEX_HOME`, holding the vendor's own `auth.json` | The `codex` CLI |

On POSIX hosts, store directories are created `0700` and the Claude token file is written `0600`, owner-only. Windows
has no equivalent step – the store inherits the data directory's ACLs, so restrict that directory yourself. Credential
values never enter logs, `dartclaw status`, or the audit journal.

**Collision refusal.** If a dedicated store path resolves onto one of your interactive login stores – `~/.claude`,
`~/.codex`, or wherever `CLAUDE_CONFIG_DIR` / `CODEX_HOME` points – DartClaw refuses to open it rather than share a
store with a second writer, and names the two colliding paths. Point `data_dir` – or `CODEX_HOME` / `CLAUDE_CONFIG_DIR`
– somewhere distinct.

**Renewal.** A Claude `setup-token` is static and lasts about a year: re-run `claude setup-token` and
`dartclaw auth claude` before it lapses; DartClaw starts warning 30 days out. Codex rotates its own token in the
dedicated store, but its refresh token goes stale eight days after the last write – re-run `dartclaw auth codex` then,
and note the warning window is only the last 48 hours of that, so a Codex instance left idle for more than a week needs
a re-login. Each command prints the store it used, and `dartclaw auth claude` also prints the derived expiry date.

**Fail-closed admission.** An absent, expired, or refresh-failed credential is refused with a remediation naming the
exact command to run, and a forced `auth` selection is never silently satisfied with the other credential type. The
refusal lands at execution admission – container-authority registration or host-worker startup – before any turn runs.
Startup validation treats the **default** provider strictly: an unsatisfiable credential there stops `dartclaw serve`.
For a **secondary** provider startup only warns – but admission still refuses, so the first task, schedule, or logical-
agent session that needs it fails with the same remediation instead of running on something else.

A host-mode turn falls through to the agent binary's own login – Claude's `claude auth login`, Codex's `~/.codex`, or
whatever an ACP agent authenticates with – in exactly three cases: when you have forced nothing (`auth: auto` with no
credential configured, so DartClaw presents nothing and the CLI authenticates itself); when `credentials_required: false`
skips the gate outright; and when the provider is a registered ACP agent (`harness.acp.agents.<id>`), which is never
refused on credential grounds whatever its `auth:` says – including a forced `subscription` or `api_key`. An ACP agent
is also **credential-isolated**: it receives no DartClaw-managed provider credential at all – not a subscription token,
which is never forwarded to a third-party client, and not `credentials.anthropic`/`credentials.openai` – unless its
registration names one explicitly with `harness.acp.agents.<id>.credential` (an API-key entry only). `model_provider`
routes and validates; it selects no credential. Otherwise the agent authenticates itself from its own configuration,
keyring, or login, as with other ACP hosts. Outside those, a forced `auth: subscription` or `auth: api_key` is never rescued that way. So configure the
credential you intend rather than relying on the fall-through. See
[Configuration § Provider authentication](configuration.md#provider-authentication) for the selection key.

### Choosing Between Subscription and API Key

A subscription credential is convenient and needs no metered API account, but it is a materially broader credential than
a scoped API key. Read this before making subscription the credential your deployment runs on.

- **Host-mode exposure.** The container boundary protects container mode only. In host mode the credential is present to
  the agent's own subprocess – Claude as `CLAUDE_CODE_OAUTH_TOKEN` in its environment, Codex as the dedicated
  `CODEX_HOME` on disk – so a host-mode agent with shell access can read and exfiltrate it. **Use an API key for
  host-mode deployments running less-trusted agents**: losing a scoped, individually revocable key is a far smaller
  event than losing a year-long full-account token.
- **Blast radius.** A subscription Bearer authenticates as your whole account, is long-lived (~1 year for Claude), and
  is harder to revoke than a scoped API key. Container isolation and execution-scoped authorities bound the window, but
  a compromise anywhere drives calls under the broader credential. Choose an API key when you want least privilege or
  independent revocation and billing.
- **Terms-of-service residual on the container path.** Host-mode Claude runs the real CLI, which is the vendor-sanctioned
  path. Container mode instead replays the token directly as a Bearer. DartClaw treats that form as permitted by
  equivalence to the sanctioned Agent SDK path, but no primary source names it – and on a container-enabled deployment,
  container is the default boundary. **An API key is
  the ToS-conservative choice** and carries no such ambiguity. If the provider refuses the mediated form, the turn fails
  with that rejection; DartClaw does not quietly retry under a different credential. Switch that provider to
  `auth: api_key`, or give the affected agents `execution: host`.
- **The Codex backend contract is not pinnable.** Container-mode Codex depends on the ChatGPT backend's Bearer contract,
  which lives server-side at `chatgpt.com`. The container image pins the `codex` *binary*, not that behavior, so a
  server-side change can break container-mode Codex regardless of the pinned binary. DartClaw detects a contract break
  as a signature distinct from expiry and alerts on it separately, but the fallback is an API key.
- **Subscription usage limits.** Subscription traffic draws on your plan's rate and usage limits rather than metered API
  capacity, and the available model set differs from the platform API. A `429` is a usage condition, not a credential
  fault – for Codex it is classified as one, so hitting a plan limit does not report as an expired credential.

For production deployments, an API key managed by the service environment or a secret manager remains the most
predictable choice: it is scoped, individually revocable, independently billed, and free of the container-path ToS
residual.

### Credential Health

DartClaw probes credential health hourly and on startup, and surfaces it in three places: per-provider cards on
`/settings`, the same fields as JSON on `GET /api/providers`, and – whenever health is degraded – a warning line on the
`serve` process's stderr, written whether or not an alert target is configured (raising `logging.level` above `WARNING`
suppresses it like any other warning). Degradation also raises a routed alert
(nearing expiry and refresh failure as warnings; required re-authentication and a broken mediation contract as
critical). See [Web UI and API § Provider credential health](web-ui-and-api.md#provider-credential-health).

### Named Credential Storage

`dartclaw secrets set <name> --type api-key|github-token` writes one owner-only JSON file per name under
`<data_dir>/credentials/named/`. A stored entry resolves as `credentials.<name>` at every config load, so a secret
never has to appear in `dartclaw.yaml` or in a service unit that `dartclaw service install` will regenerate. See
[CLI Reference § Secrets](cli-reference.md#secrets) for the commands.

**What the store protects.**

- **File permissions.** Files are written `0600` and directories created `0700`, through the same atomic
  temp-file-plus-rename path the subscription stores use. `dartclaw secrets audit` reports the credential directories,
  any file under `<data_dir>/credentials/`, or the config file itself when accessible beyond its owner.
- **No secret in argv.** The value is read from stdin only: a masked prompt or a pipe. No option carries it, so it
  never enters shell history or the process list.
- **Login-store collision refusal.** Opening the store refuses, before reading any credential, a path that
  symlink-resolves onto `$CODEX_HOME`/`~/.codex` or `$CLAUDE_CONFIG_DIR`/`~/.claude`. The named store never reads,
  writes, or probes those paths; provider auth-status probes and explicitly enabled Codex-home seeding are separate
  pre-existing paths that can read an operator login.
- **Path validation.** A name must match `^[a-z0-9][a-z0-9_-]{0,63}$`, checked before any path is constructed — the
  store is addressed by filename, so an unvalidated name would be an arbitrary-path write.
- **No echo over HTTP.** Stored credentials merge into the in-memory config, but the config API emits no `credentials`
  key, so neither `GET /api/config` nor a `PATCH` read-before-merge returns one.

**What the store does not do.** It is a store, not a vault. Read the following as a list of properties it deliberately
lacks, not as an oversight:

- **No encryption at rest.** The file holds the secret in plaintext. Anyone who can read the file, or a backup or
  snapshot of it, has the secret. Its confidentiality is exactly the confidentiality of `<data_dir>`.
- **No OS keychain integration.** Nothing here touches the macOS Keychain, the Secret Service API, or any credential
  helper. That is a pinned invariant, not a gap awaiting an implementation.
- **No rotation, expiry, or read auditing** for named entries. An API key carries no expiry to track, and the store
  keeps no access log.

For a deployment where those properties matter, keep delivering the secret from an external secret manager through a
`${VAR}` reference — which keeps working unchanged — and use `dartclaw secrets audit` to confirm nothing drifted back
into the config file.

### Security Properties

- **Key isolation** – provider credentials never exist inside the container: not in environment variables, mounted or
  generated files, command arguments, or generated client configuration
- **No shared token** – containers receive no shared operator MCP bearer; the execution-scoped pipe is the identity
- **Pinned destination** – the adapter owns the upstream origin and the allowed request paths, so a container cannot
  name where its traffic goes
- **Sole egress** – `network:none` means the host-owned pipe is the only way out of the container. The pipe refuses any
  request declaring a provider-side network tool (web search/fetch, remote MCP connectors), which would otherwise run at
  the provider where `network:none` cannot reach it. The container's web path is instead the bridged canonical
  `web_search` / `web_fetch` grant: those run host-side, under the SSRF and private-range policy, NetworkGuard's domain
  allowlist (the built-in defaults plus `guards.network.extra_allowed_domains` and
  `agent_overrides.<id>.extra_domains`), and content classification. This applies to every container profile, not just
  `restricted`
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
