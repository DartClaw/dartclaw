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

Workflow steps run through the same guarded harness turn path as other background work — in `dartclaw serve` and in a
standalone `dartclaw workflow` run, which composes the same root. Their leased worker evaluates the configured guard
chain before tool calls, applies the step's `allowedTools`/read-only policy, retains container isolation when the
resolved execution policy selects it, and a blocked call is written to the guard audit log exactly as an interactive
turn's is.

**Coverage is stated per provider, because interception is per provider.** On Claude it is unconditional: every tool
call passes the host `PreToolUse` gate. On Codex it is bounded to the approval handler — broadest under
`approval: on-request`, partial under a granular approval mode, and inactive under `approval: never`, because the
upstream approval flow deadlocks otherwise ([codex#11816](https://github.com/openai/codex/issues/11816)).

What this does **not** cover, named rather than omitted: the content classifier's own provider spawn, which passes no
guard chain at all. Two neighbouring surfaces are bounded rather than excluded — inbound MCP `tools/call` dispatch **is**
guard-evaluated against the same base chain and audited, but it is not a runner turn, so per-task tool policy and
read-only mode do not apply there (this holds for a named MCP client too — see
[Context Engine Mode](context-engine.md), whose bound is the five-tool profile plus that base chain); and an ACP-backed provider carries only its own reverse-call mediation, which is
weaker than the host tool gate. DartClaw does not today refuse an ACP provider named by a workflow step, so treat
"workflow steps are guarded" as bounded by whichever provider the step names. Do not read "the same guarded path" as
"every model-spawning path is guard-evaluated" — that is a broader claim this release does not make.

### Built-in Guards

| Guard | Category | What It Blocks |
|-------|----------|---------------|
| **CommandGuard** | command | Shell injection, dangerous commands (rm -rf, curl to untrusted hosts) |
| **FileGuard** | filesystem | Access to `.ssh/`, `.aws/`, credentials files, symlink escape |
| **NetworkGuard** | network | Connections to non-allowlisted hosts/ports |
| **ContentGuard** | content | Prompt injection and harmful content at agent boundaries, in `web_fetch` results, and in results from `network_class: public` MCP servers |
| **TaskToolFilterGuard** | tool | Tools not in the task's allowlist; every shell command not proven read-only while a task is read-only |

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

A file rule's `pattern` is a glob, matched against the full path, the file's basename and every path suffix:

| | |
|---|---|
| `*` | any run of characters inside one path segment |
| `**` | any run of characters, separators included |
| `**/` | zero or more whole leading segments — anchored to a segment boundary, so `**/.ssh/*` matches `a/.ssh/k` but not `a/my.ssh/k` |
| `?` | one character inside a segment |
| `{a,b}` | either alternative, each taken literally |

A pattern with no `*` and no `?` is an exact path, resolved through symlinks before comparison.

Injection judgment has one owner: the **ContentGuard** classifier, which evaluates at the agent boundary
(`beforeAgentSend`) and on fetched web content. The content reaches the classifier inside an untrusted-content
frame, declared as data to classify rather than instructions to follow.

> **Inbound channel messages are not scanned on arrival.** The regex `InputSanitizer` that used to run at
> `messageReceived` was removed in 0.25 — a pattern list cannot decide what is an instruction, and it gave
> a coverage claim the runtime did not deliver. What constrains a hostile channel message is what the agent
> can then *do* with it: the command, file, network, and tool-policy guards on every tool call the host
> intercepts (unconditional on Claude; on Codex, host-guard interception stays approval-routed), the content
> classifier on anything the agent fetches or hands to another agent, and container isolation when enabled.
> The `messageReceived` hook point remains available to custom guards.

### Read-Only Sessions

A task or workflow step put in read-only mode admits shell commands from an **allowlist** of commands proven
read-only (`cat`, `grep`, `find`, `test`, `pwd`, read-only `git` subcommands, and similar). Anything the
allowlist does not name is blocked, as is any command carrying a redirect, command substitution, environment
assignment prefix, or `sudo`, any unterminated quote, and any shell input the guard cannot read as a command
string. Quoting is resolved the way a shell resolves it, so `grep 'a|b'` is one command while `echo \" > f \"`
is a redirect.

A command is on the list only if no invocation of it is *intended* to write a file or run another program. That
excludes `awk` and `sed` (they execute shell commands from their program text), `rg` (`--pre` runs a command),
`file` (`-C` writes a compiled magic file), the pagers (`-o` logging, `!` shell escape), and `sort`, `uniq`,
`tree` and `xxd` (each takes an output file). `git` and `find` are admitted with their arguments inspected.

The `git` inspection is a per-subcommand allowlist in two dimensions: only the listed subcommands run, and each
one admits only the flags enumerated for it. A subcommand carrying an unlisted flag blocks, which is what keeps
out flag-carried config writes (`git branch --set-upstream-to=…`, `-uorigin/main`, `--unset-upstream`),
editor-spawning flags (`git branch --edit-description`), flag-carried ref deletion (`git symbolic-ref -d`),
the output-file flag (`git diff --output=…`), the pager-running flag (`git grep -O…`), the flags that turn on a
config-named external program for `git log` and `git show` (`--ext-diff`, `--textconv`, `--show-signature`), and
`--help`, which execs `man` from `PATH`. `-h` blocks with every other unlisted flag. The subcommand must also be
the first argument, so a pre-subcommand global such as `git --exec-path=…` or `git -c core.pager=…` blocks
before the subcommand is read. Subcommands that read when bare and write when given a target carry a non-flag
argument budget: `git branch` and `git remote` admit none, `git symbolic-ref` admits one.

Two shapes are stricter than git's own parser. A flag is matched whole unless it is a long flag with an attached
value, so a short option must be written separated and unbundled – `git log -n 5`, not `-n5`; `git status -s -b`,
not `-sb`. And where a subcommand's positional budget is finite, a value-taking flag must be written attached
(`--contains=HEAD`), since a separate value spends a slot. Both directions fail closed: the command is refused,
never silently reinterpreted.

What this bounds is the `git` command line. It is **not** a bound on what the repository's own configuration can
make git do – `git diff` runs a configured external diff driver or textconv filter by default, and a signed
commit makes `git log` exec `gpg.program`, none of which the command line has to ask for. Nor is it a bound on
flags added by a future git release that the allowlist has not yet seen (those block, which is the intended
failure), or on anything outside the shell surface. Container isolation remains the boundary that does not
depend on argument parsing.

File-writing and memory-writing tools (`file_write`, `file_edit`, `memory_apply`, `memory_observe`) stay
blocked outright. Read-only mode does **not** gate outbound MCP calls or sub-session spawns — a step that
needs those bounded as well must also carry a tool allowlist.

### Guard Editor (Web UI)

Admins can manage guard extensions from the **Settings** page instead of hand-editing YAML. The editor groups the command, file, and network guards and lets you list, add, edit, delete, and test their **extension** fields:

| Guard | Editable extension field |
|-------|--------------------------|
| Command | `extra_blocked_patterns` |
| File | `extra_rules` |
| Network | `extra_allowed_domains` |

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

**As of 0.25 this is the default posture.** A config that declares no `container:` section is resolved once at startup:
DartClaw probes for a container runtime (`docker`, then `podman`) and isolates agent execution where it finds one. Where
it finds none, the server still starts, in advisory mode, and says at startup that no OS boundary is active and why.
Detection never blocks startup.

Declaring the key opts out of that inference in either direction:

| `container.enabled` | Host with a runtime | Host without one |
|---|---|---|
| unset (default) | isolated | starts in advisory mode, with a startup warning naming the missing runtime |
| `true` | isolated | **startup fails** — an explicit request is refused, never downgraded |
| `false` | advisory mode | advisory mode |

**The table describes `dartclaw serve`.** The posture is resolved once at server startup, so the zero-server lane —
`dartclaw workflow run --standalone` and the other `--standalone` verbs — uses the posture as written in the file, with
no probe. An undeclared section there means **not isolated**, which is what it meant before 0.25. If you run standalone
workflows and want them isolated, declare `container.enabled: true`.

The same asymmetry covers a probe that fails part-way (an engine architecture no bridge binary ships for, an
undeliverable bridge): under an inferred posture it downgrades with the failure named; under an explicit `true` it is
fatal.

On supported POSIX hosts, when a container runtime is available, DartClaw runs the packaged `claude` or `codex` binary
inside a container with:
- `network:none` -- no direct internet access
- Capability drops (`--cap-drop ALL`)
- Read-only root filesystem
- Host-mediated provider access over framed `docker exec` pipes (see below) -- no credential in the container
- Mount allowlist for workspace files

ACP agents have no container execution: DartClaw mediates no provider credential or host capability for an ACP client,
so ACP registrations run on the host only and a container-requiring registration is rejected at startup.

Container isolation is unavailable on native Windows even when Docker is installed. Its per-authority pipes and
owner-only generated state require POSIX facilities, so an explicit `container.enabled: true` fails closed and directs
the operator to a POSIX host or WSL; auto-detection never runs there at all. See the [Windows capability matrix](windows.md#capability-matrix).

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
trusted machine, but it is not isolation parity. What advisory mode does and does not cover is stated per provider: on
Codex, host-tool interception is bounded by the configured approval mode, so guards see what that mode routes for
approval and nothing else. The startup warning names why *this* host is in advisory mode — no runtime detected, or the
probe step that failed — and links back here.

Container isolation costs the agent no host tool it reaches on the host lane: a containerized primary agent is granted
the same bridged MCP surface (web, memory, and the task, review and binding tools) minus the session-spawning tools,
which are excluded on both lanes. Tools with no canonical mapping — `kg_*`, `context_research`, `onboarding_complete`
and the outbound MCP adapters — are unreachable from a container, as they were before this became the default.

### Emergency Stop Without a Channel

Stopping every running turn and task does not require a chat channel:

```bash
dartclaw stop                       # cancels all active turns and running/queued tasks
curl -X POST http://localhost:3333/api/emergency-stop -H "Authorization: Bearer $DARTCLAW_TOKEN"
```

Both go through the same sequence a channel `/stop` runs, emit the same `EmergencyStopEvent`, and are gated exactly as
the admin-only configuration and guard mutations above: a request without admin context is refused with `403` and
cancels nothing. **What "admin context" means follows `gateway.auth_mode`**, and this endpoint is no exception — with
gateway auth enabled it means an authenticated session or a bearer token, so an unauthenticated request is refused;
with `gateway.auth_mode: none` the local instance *is* the single admin, so a loopback request needs no credential.
That is the same trade the no-auth mode makes for every other mutating route, and it is why no-auth deployments belong
on loopback. The recorded caller is derived from how the request authenticated, never from anything the caller states
about itself.

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

**What the dedicated Codex home carries.** It isolates the *credential*, not your Codex capabilities. Alongside the
vendor's `auth.json` and DartClaw's generated `config.toml`, the host lane mirrors the `[plugins.*]` tables from your
`~/.codex/config.toml` plus your `plugins/cache` and `skills` directories into that home. A Codex plugin is enabled by
the home it runs in, so without this a stored subscription would resolve none of your plugins and any workflow step
referencing a provider-side skill – every built-in workflow references `andthen:*` – would fail its preflight. Your
`auth.json` is never copied across, in either direction.

The mirror is kept current, not merely seeded: every spawn and every probe re-derives it from your `~/.codex`, so a
plugin you uninstall there loses both its table and its mirrored files on the next run. DartClaw prunes only what it
mirrored – recorded in `.dartclaw-mirror.json` in the store – so anything you install into the dedicated home directly
(`CODEX_HOME=<store> codex …`) stays. If your `~/.codex/config.toml` uses TOML that DartClaw cannot split with
certainty, it mirrors nothing that run and logs a warning rather than splicing a half-read config.

Containerized execution is deliberately excluded: its home is never seeded and carries only generated client
configuration, which is the boundary container mode exists to keep.

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

ACP registrations are admitted only when they match a verified target profile. The shipped wiring produces no
guard-mediated ACP classification: `requires_guard_mediation: true` is refused at startup because terminal reverse-calls
are not advertised and no live target probe is wired. Admitted ACP registrations are host-only.

| Mode | When to use | Security claim |
|------|-------------|----------------|
| Direct provider, verified | The registration matches a verified target profile and does not require guard mediation | Host-only. Filesystem reverse-calls are evaluated by DartClaw guards, but the shipped wiring makes no end-to-end guard-mediation claim |
| Relay provider | The ACP target forwards work through another provider CLI or relay path | No guard-mediation claim, so a container is the only boundary it could have — and DartClaw has no ACP container mediation, so the registration is rejected at startup |
| Unverified | The registration has no matching verified target profile | Rejected at startup; the shipped wiring has no path that promotes it to guard-mediated |
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
