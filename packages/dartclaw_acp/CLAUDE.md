# Package Rules — `dartclaw_acp`

**Role**: the single owner of Agent Client Protocol support — config DTOs and parsing, stdio JSON-RPC transport, `AcpHarness`, protocol adaptation, reverse-call mediation, target validation, container admission and runtime registration.

## Boundaries

- Production workspace dependencies are the public barrels of `dartclaw_core` and `dartclaw_kernel`, plus the listed external libraries. Never import another workspace package's `lib/src/`. This package sits **beside** the runtime in the tier order (`dev/package_tiers.txt`), not above it: an edge to `dartclaw_runtime` would point sideways and fail the direction gate.
- `json_rpc_2` and `stream_channel` belong here, not in core. ACP transport code must not leak back into `dartclaw_core`.
- `dartclaw_core` owns the generic `HarnessRegistrar` / `HarnessRegistration` seam this package implements; `dartclaw_runtime` consumes it and carries no ACP type, string branch or production dependency. `dartclaw_cli` is the production composition root and passes `AcpHarnessRegistrar` explicitly.
- `dartclaw_kernel` retains `harness.<name>` as raw section data. Parse `harness.acp` only through `acpConfigFor`, which uses the config's warning sink and caches once per config instance.

## Security Contracts

- ACP is host-only. A registration requiring container isolation is refused at declaration because DartClaw has no mediated ACP container path. Never downgrade it to host execution.
- `credential:` is the only DartClaw-managed credential path. It may present a named API-key entry under its declared environment variables; `model_provider` selects no credential and subscription credentials are never forwarded.
- Permission decisions derive from each runner's own `GuardChain`. Preserve per-runner isolation and deny when guard evaluation throws.
- Filesystem reverse-calls stay turn-scoped and workspace-jailed. Terminal reverse-calls remain unavailable until complete descendant containment is proven.

## Conventions

- `AcpHarnessRegistrar` is the only production composition seam. It owns provider entries, declared profiles, credential overlay, target validation and startup warnings.
- Registrar ownership is first-claim-wins across provider entry, profile and credential lookups. A normalized provider-ID collision throws rather than choosing one.
- `claude` and `codex` are built-in provider IDs and cannot be claimed by an ACP registration; declaration rejects the exact `harness.acp.agents.<id>` path.
- Operator configuration is authoritative for a registration's container profile; there is no code-declared default.
- Public API exports use explicit `show` clauses in `lib/dartclaw_acp.dart`.
- A non-empty turn system prompt is prepended to the ACP message together with bounded replay history; model and effort overrides remain unsupported.
- `AcpHarness` gives stdout exclusively to the JSON-RPC peer and reads stderr separately. Route decode and stream errors through `_failStream`, which accepts only the currently owned process, fails the active turn with `ProcessStreamException`, closes the peer before serialized teardown and ignores teardown-induced duplicate faults. Never replace that path with a logging-only `onError`.
- Wire shape is pinned to ACP 0.13.4 (the `agent-client-protocol-schema` crate on docs.rs): `initialize` sends `clientCapabilities` (boolean `terminal`; `fs.readTextFile` / `fs.writeTextFile` booleans inside the nested filesystem capability), `session/new` answers `result.sessionId`, `session/update` carries `params.update` discriminated by `sessionUpdate` with assistant text wrapped as `update.content.content` `{type: "text", text}`, and `tool_call` / `tool_call_update` use `toolCallId`, `title`, `status`, `rawInput`, `rawOutput`. The `test/` fixtures assert these names. When bumping the protocol version, read the crate's `agent.rs` / `client.rs` sources rather than prose about newer method names – an earlier lookup summary that omitted the `ContentChunk` wrapper had to be corrected against them.

## Testing

- Relocated suites under `test/` preserve their former assertions. Changes should normally be import-only unless a generic seam replaced an ACP-typed seam.
- Run `dart test --reporter=failures-only packages/dartclaw_acp`, then the affected config/core/server/CLI suites and the full workspace gate for cross-package changes.
