# Package Rules — `dartclaw_server`

**Role**: HTTP API + HTMX web UI + task runtime + container orchestration — the composition layer that wires `dartclaw_core` services behind shelf routers and Trellis-rendered pages. Entry points: `DartclawServer` (`lib/src/server.dart`), `ServerBuilder`, `TurnManager`, `TurnRunner`, `HarnessPool`, `TaskExecutor`, `TaskService`.

## Architecture
- **HTTP layer** — `DartclawServer` + `ServerBuilder` (composition root); shelf middleware (auth, security headers); `lib/src/api/*_routes.dart` (one router per domain); `sse_broadcast.dart` + `stream_handler.dart` for streaming.
- **Web UI** — `PageRegistry` (registration with reserved-prefix guard) + `lib/src/web/pages/`; Trellis templates under `lib/src/templates/` (paired `.html` + `.dart`, manifest in `expectedTemplates`); vendored static assets in `lib/src/static/`.
- **Turn orchestration** — `TurnManager` (session lock + `BusyTurnException`), `TurnRunner` (prompt composition + harness drive + guard wiring + event emission), `HarnessPool` (per-session harness reuse), `TurnGovernanceEnforcer` (turn-level limits).
- **Task runtime** — `TaskService` (CRUD), `TaskExecutor` (queue consumer), `WorktreeManager`, `MergeExecutor` / `RemotePushService` / `PrCreator` (git ops; injected into `WorkflowGitPort`), `task_*_subscriber.dart` (`EventBus` side effects).
- **Container orchestration** — `ContainerManager`, `DockerValidator`, `SecurityProfile`, `CredentialProxy` (API-key isolation for Claude harness execution).
- **Workflow glue** — `lib/src/task/workflow_*.dart` injects `WorkflowGitPort` + `WorkflowTurnAdapter` impls into `dartclaw_workflow`; reads workflow runtime state from the hydrated `WorkflowStepExecution` row.
- **Channel wiring + MCP** — `webhook_routes.dart` (synchronous inbound + JWT verification; channel impls themselves live in their own packages); `lib/src/mcp/` (Dart-side MCP endpoint at `/mcp`).
- **Security wiring** — `SecurityWiring` translates `GuardChain` verdicts to `EventBus` events (the seam `dartclaw_security` deliberately doesn't cross).

## Shape
- **Request lifecycle**: shelf pipeline (auth middleware → security headers → router) → `*_routes.dart` handler → one-shot response or SSE via `sse_broadcast.dart`.
- **Turn lifecycle**: route handler → `TurnManager.reserve(sessionKey)` (acquires session lock; returns turn token or `BusyTurnException`) → `TurnRunner.execute` (composes prompt, drives `AgentHarness`, applies guards, fires events) → outcome → lock released.
- **Task lifecycle** runs in parallel: `TaskExecutor` consumes the queue, manages worktrees + git ops, emits `TaskEvent`s — workflow-spawned tasks auto-accept, manual tasks park for review.
- **Container orchestration** wraps Claude harness execution: `ContainerManager` applies `SecurityProfile`, `CredentialProxy` injects API keys without exposing them in env.

## Boundaries
- Allowed prod deps (arch_check L1): `dartclaw_config`, `dartclaw_core`, `dartclaw_google_chat`, `dartclaw_models`, `dartclaw_security`, `dartclaw_signal`, `dartclaw_storage`, `dartclaw_whatsapp`, `dartclaw_workflow`. Plus shelf, trellis, http, anthropic_sdk_dart, crypto/jwt/pointycastle, html2md, qr.
- This is the only package allowed to import from all channel packages and storage. Channel-specific transport stays in its own package; this package only wires it.
- Container orchestration (`lib/src/container/`) lives here, not in core — `ContainerManager`, `DockerValidator`, `SecurityProfile`, `CredentialProxy`. Don't move it down.
- Workflow execution semantics belong in `dartclaw_workflow`. Workflow-task glue (`workflow_one_shot_runner.dart`, `workflow_turn_extractor.dart`, `workflow_worktree_binder.dart`, `workflow_cli_runner.dart`) lives under `lib/src/task/` and injects git impls (`MergeExecutor`, `RemotePushService`, `PrCreator`) into the workflow port.

## Conventions
- Add new dashboard pages by registering a `DashboardPage` with `PageRegistry` (`lib/src/web/page_registry.dart`). Routes must start with `/` and not collide with the reserved-route patterns (health, static, /login, channel pairing, etc.) — `register()` throws on conflict.
- Templates are paired `.html` + `.dart` files under `lib/src/templates/` (loaded by `loader.dart`; the file names are listed in `expectedTemplates` — startup fails if missing). Use Trellis with HTML-escaped placeholders; never concatenate user data into HTML strings. Follow `dev/guidelines/HTMX-GUIDELINES.md` and `dev/guidelines/TRELLIS-GUIDELINES.md` for fragments and SSE.
- Static assets under `lib/src/static/` are vendored — see `VENDORS.md` (highlight.js, DOMPurify, htmx-ext-sse). Don't add npm/CDN runtime fetches; upgrade by replacing files and bumping `VENDORS.md`.
- Routes go under `lib/src/api/*_routes.dart` (one shelf router per domain) with helpers from `api_helpers.dart`. SSE streams use `sse_broadcast.dart` / `stream_handler.dart` — don't roll new SSE plumbing.
- Auth resolution and base-URL handling belong in middleware/`auth/`, never inline in routes. Use `AllowlistValidator` for outbound URL gating.
- Turn lifecycle: callers go through `TurnManager.reserve` → `TurnRunner.execute` → outcome. `BusyTurnException` is the public busy signal. Don't construct `TurnRunner` directly in routes — go through `TurnManager`.

## Gotchas
- `pubspec.yaml` carries `hooks.user_defines.sqlite3.source: system` — required for local sqlite3 codesigning on macOS. Don't remove it without verifying CI builds the bundled asset.
- Workflow-spawned tasks have `reviewMode: auto-accept` (set by the workflow package); the server's review surface won't park them — assume they advance on `accepted`.
- Reserved route patterns in `page_registry.dart` are guarded — `/health`, `/static/`, `/whatsapp/`, `/signal/`, `/memory/content`, etc. Adding a page on a reserved prefix throws at startup, not at request time.
- `TaskExecutor` reads workflow runtime state from the hydrated `WorkflowStepExecution` row, not from `Task.configJson` — workflow-private blobs no longer round-trip through tasks.
- The `task_*_subscriber.dart` files attach to the `EventBus` — adding a new subscriber requires wiring it in `ServerBuilder` so it's actually subscribed.
- `dartclaw_server.dart` barrel is large but ceiling-checked (≤80 exports) — prefer adding sub-barrels (`*_exports.dart`) over piling onto the top barrel.

## Testing
- Test layout mirrors `lib/src/` — domain-keyed subdirs (`api/`, `task/`, `templates/`, `container/`, `harness/`, `governance/`, `mcp/`). Layer 3 handler tests invoke shelf handlers directly via `handler(Request(...))` — no TCP bind.
- Use shared fakes from `dartclaw_testing` (dev_dependency only): `FakeAgentHarness`, `FakeGuard`, `FakeChannel`, `FakeProcess`, `InMemoryTaskRepository`, `TestEventBus`, `FakeTurnManager`. Never redeclare locally.
- In-memory SQLite (`sqlite3.openInMemory()`) for storage-backed tests; temp dirs for filesystem.
- Suites that bind ports / touch CWD / share static-asset state must serialize (`-j 1`) and document why — see `dev/guidelines/TESTING-STRATEGY.md` Layer 2 note.
- Template-rendering correctness (HTML structure, escaping) is asserted at Layer 2/3 against rendered output strings — visual layout is covered by manual UI smoke tests, not Dart tests.

## Key files
- `lib/src/server.dart` + `server_builder.dart` — composition root, route mounting.
- `lib/src/web/page_registry.dart` + `lib/src/web/pages/` — dashboard page registration.
- `lib/src/templates/loader.dart` (`expectedTemplates`) + `lib/src/templates/*.{html,dart}` — Trellis templates.
- `lib/src/api/*_routes.dart` + `api_helpers.dart` + `sse_broadcast.dart` — HTTP/SSE surface.
- `lib/src/turn_manager.dart` + `turn_runner.dart` + `turn_governance_enforcer.dart` + `harness_pool.dart` — turn lifecycle.
- `lib/src/task/task_executor.dart` + `task_service.dart` + `worktree_manager.dart` + `merge_executor.dart` — task runtime + git ops.
- `lib/src/container/container_manager.dart` + `security_profile.dart` + `credential_proxy.dart` — container orchestration.
- `lib/src/static/VENDORS.md` — vendored asset versions; update when bumping highlight.js/DOMPurify/htmx-ext-sse.
