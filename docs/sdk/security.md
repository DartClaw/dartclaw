# SDK Security Guide

**SDK Guide** | [Quick Start](quick-start.md) | [Concepts](concepts.md) | [Architecture](architecture.md) | [Package Guide](packages.md) | [User Security Guide](../guide/security.md)

The two tiers have different security jobs. A client-tier consumer holds a credential and talks to a trust boundary someone else operates. A runtime-tier consumer *is* that trust boundary and owns policy, isolation, credentials, and auditability.

## Token Handling (Client Tier)

`DartclawApiClient` takes an explicit token and sends it as `authorization: Bearer <token>` on every request. Pass `null` only when the server's gateway runs with `auth_mode: none`.

- **Do not hard-code the token.** Read it from the environment, a secret manager, or your platform's credential store at startup.
- **The client will not find it for you.** Resolving a token from a config file or a DartClaw data directory is deliberately outside the package — that is why the client has no dependencies and never touches the filesystem. `apps/dartclaw_cli/lib/src/commands/connected_command_support.dart` shows a full resolution chain (`--token` → `gateway.token` → the data directory's `gateway_token` file) for a host that legitimately has that access.
- **`DartclawApiException.message` never contains the token**, including on `401`, where it names the remediation commands instead. It can contain the base URI, though, so keep credentials and query parameters out of `baseUri` before printing it. Do not log the request headers.
- **Use `https://` for anything but loopback.** A bearer token on a plaintext connection is a token on the wire.
- **Treat the token as the whole authorization.** It is not scoped per endpoint; a token that can read tasks can also create them. Do not hand a gateway token to a component you would not give server-side access to.

Rotate with `dartclaw token rotate`; see the [User Security Guide](../guide/security.md).

## Guard Chain (Runtime Tier)

The guard chain is the application-level policy layer. A `GuardChain` evaluates one or more `Guard` instances in order and returns a `GuardVerdict`.

Guards run at three hook points:

- `messageReceived` before inbound user or channel content enters the runtime.
- `beforeToolCall` before a provider tool request is approved.
- `beforeAgentSend` before assistant content is sent back to a user.

Built-in guards cover command, file, network, tool-policy, and content-classification use cases. Custom guards should be narrow, deterministic, and fail closed by returning `GuardVerdict.block(...)` when they cannot evaluate safely.

### Writing Custom Guards

A custom guard extends `Guard`, provides stable `name` and `category` strings, and returns `GuardVerdict.pass()`, `GuardVerdict.warn(...)`, or `GuardVerdict.block(...)`.

Use stable names because they appear in audit logs and operator output. Do not throw from `evaluate`; catch failures inside the guard and return a block verdict with a useful reason. `GuardChain` also has a timeout and fail-closed backstop for unexpected failures.

See [custom_guard](../../examples/sdk/custom_guard/) for a runnable example.

## Isolation Expectations (Runtime Tier)

The guard layer is not a replacement for OS isolation. For hosts that let agents use shell, file, or network tools, combine guards with process/container isolation appropriate to the risk:

- Restrict working directories.
- Pass explicit environment maps instead of inheriting all process variables.
- Disable or constrain network access when the task does not require it.
- Keep writable paths narrow.
- Treat tool approval as a policy decision, not just a UX prompt.

The reference server shows a full hardening composition. Smaller hosts can start with guard-chain checks and add container isolation when they expose higher-risk tools.

This section is one of the strongest arguments for staying on the client tier: `dartclaw serve` already implements this composition, and a client-tier consumer inherits it instead of rebuilding it.

## Credential Handling (Runtime Tier)

Do not bake provider credentials into source code, example prompts, or persisted messages. Prefer one of these patterns:

- Let the native `claude` binary use its existing authenticated login. No SDK example calls a provider API
  directly, so a subscription login is a complete credential path on its own.
- Where that login is unavailable (CI, a headless host), the binary also accepts `ANTHROPIC_API_KEY` from the
  process environment. It is an alternative to the login, never a requirement alongside it.
- In service hosts, centralize credential loading and pass only the minimum provider environment needed by the worker.
- Avoid logging request bodies, environment maps, or tool inputs that may contain secrets.

The runnable examples document live-mode credential prerequisites before any command that requires them.

## Audit and Observability

Security decisions should be visible. At minimum, record guard blocks and warnings with:

- Guard name and category.
- Hook point.
- Verdict and reason.
- Session or request identifier when available.
- Timestamp.

`GuardChain` exposes a verdict callback so hosts can translate non-pass decisions into logs, events, or audit records without making `dartclaw_kernel` depend on a specific application layer.

Client-tier consumers get this for free: the server audits, and the audit surface is readable over the same API.

## Reference Implementation Boundary

`dartclaw_runtime` and `dartclaw_cli` are working implementations built from the runtime packages. They include deployment-oriented choices such as HTTP auth, security headers, task isolation, and operational commands. Forks can reuse the underlying guard, harness, storage, and event primitives without adopting the full application — but the runtime tier is unpublished and carries no compatibility promise, so a fork owns its upgrade path.
