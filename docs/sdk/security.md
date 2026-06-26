# SDK Security Guide

**SDK Guide** | [Quick Start](quick-start.md) | [Concepts](concepts.md) | [Architecture](architecture.md) | [User Security Guide](../guide/security.md)

DartClaw's SDK security model assumes your Dart host is responsible for policy, isolation, credentials, and auditability. The reference server is one composition of those controls. SDK consumers can use the same primitives in smaller hosts.

## Guard Chain

The guard chain is the application-level policy layer. A `GuardChain` evaluates one or more `Guard` instances in order and returns a `GuardVerdict`.

Guards can run at three important hook points:

- `messageReceived` before inbound user or channel content enters the runtime.
- `beforeToolCall` before a provider tool request is approved.
- `beforeAgentSend` before assistant content is sent back to a user.

Built-in guards cover command, file, network, tool-policy, input-sanitizer, and content-classification use cases. Custom guards should be narrow, deterministic, and fail closed by returning `GuardVerdict.block(...)` when they cannot evaluate safely.

## Writing Custom Guards

A custom guard extends `Guard`, provides stable `name` and `category` strings, and returns `GuardVerdict.pass()`, `GuardVerdict.warn(...)`, or `GuardVerdict.block(...)`.

Use stable names because they appear in audit logs and operator output. Do not throw from `evaluate`; catch failures inside the guard and return a block verdict with a useful reason. `GuardChain` also has a timeout and fail-closed backstop for unexpected failures.

See [custom_guard](../../examples/sdk/custom_guard/) for a runnable example.

## Isolation Expectations

The SDK guard layer is not a replacement for OS isolation. For hosts that let agents use shell, file, or network tools, combine guards with process/container isolation appropriate to the risk:

- Restrict working directories.
- Pass explicit environment maps instead of inheriting all process variables.
- Disable or constrain network access when the task does not require it.
- Keep writable paths narrow.
- Treat tool approval as a policy decision, not just a UX prompt.

The reference server shows a full hardening composition. Smaller SDK hosts can start with guard-chain checks and add container isolation when they expose higher-risk tools.

## Credential Handling

Do not bake provider credentials into source code, example prompts, or persisted messages. Prefer one of these patterns:

- Let the native `claude` binary use its existing authenticated login.
- Provide `ANTHROPIC_API_KEY` through the process environment for local examples.
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

`GuardChain` exposes a verdict callback so hosts can translate non-pass decisions into logs, events, or audit records without making `dartclaw_security` depend on a specific application layer.

## Reference Implementation Boundary

`dartclaw_server` and `dartclaw_cli` are reference implementations built from SDK packages. They include deployment-oriented choices such as HTTP auth, security headers, task isolation, and operational commands. SDK consumers can reuse the underlying guard, harness, storage, and event primitives without adopting that full application.
