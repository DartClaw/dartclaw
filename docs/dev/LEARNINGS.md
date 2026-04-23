# Project Learnings

Non-obvious traps and recurring patterns. Bar for inclusion: *would a competent developer with access to the code still get bitten by this?* No version references — gotchas are timeless. Routine implementation detail belongs in git history, not here.

---

## Dart Language

- **`Future.timeout` cannot interrupt synchronous regex.** Single-threaded event loop. Mitigate via input truncation, not per-pattern timeouts.
- **`Stream` lacks `whereType<T>()`.** Use `.where((e) => e is T).cast<T>()`.
- **`=> {` in `.map()` parses as a set literal, not a block body.** Use `.map((x) { return ...; })`.
- **Zone context lost in `.listen()` callbacks.** Values set with `runZonedGuarded` / `LogContext.runWith()` aren't visible inside async stream callbacks once control returns to the event loop.
- **Class fields can't be null-promoted.** Extract to a `final` local first.
- **Microtask starvation in async loops.** `(_) async {}` and `Future.value()` complete on the microtask queue; a `while` loop awaiting only those monopolizes the event loop, so timer callbacks (`Completer` resolutions, `stop()`, etc.) never fire → multi-GB OOM. Add `await Future<void>.delayed(Duration.zero)` as a yield point in every production async loop.
- **DST-boundary date arithmetic flakes test fixtures.** `Duration(days: N)` subtracted from local-midnight `DateTime`s can roll to the previous calendar day. Use explicit year/month/day construction in date-sensitive fixtures.

## Agent Harness Protocols

### Claude
- **`CLAUDECODE` env var causes nesting refusal.** Clear in subprocess environment.
- **`persistSession: false` prevents disk writes.** DartClaw owns persistence.
- **Model override goes via `--model` CLI flag, not the initialize field.**
- **`sdkMcpServers` map must be spread, not double-wrapped.** Helpers already return the top-level shape; passing into another `sdkMcpServers:` field silently produces `sdkMcpServers.sdkMcpServers`.
- **`--dangerously-skip-permissions` is only safe with hooks active.** Restricted-container simple mode disables hooks → fail-closed on `can_use_tool`.
- **Per-turn `system_prompt` *replaces* spawn-time `--append-system-prompt`.** Don't inject conversation history via system prompt for `PromptStrategy.append`. Inject as `<conversation_history>` XML in the user message on cold-process turns only.
- **`_buildClaudeArgs()` is process-level, not per-task.** `HarnessPool` reuses long-lived runners; per-task flags require new processes or pool segmentation.
- **Container mode: skip host probes.** No `claude --version` / auth probes from inside the container.

### Codex
- **Codex reads `config.toml` only at app-server startup.** Write `CODEX_HOME/config.toml` before spawning; later changes have no effect.
- **Crash recovery must clear cached `_threadIds`.** All thread IDs are stale after process exit. Continuity comes from DartClaw's NDJSON history replay, not Codex resume.
- **`thread/start` returns a `thread_id` that must be reused** on every subsequent `turn/start`, or you silently start an orphan thread.
- **Per-turn model override needs `harnessConfig.model` fallback.** Otherwise the configured default model is silently ignored.
- **No cost reporting.** `supportsCostReporting` is `false`. Budget enforcement must use tokens.
- **Anthropic and Codex disagree on `input_tokens` semantics.** Claude reports fresh input directly; Codex reports cache-inclusive input, so normalize at the harness/workflow boundary before persisting or comparing usage.
- **Strict structured output requires every nested object fully closed.** `additionalProperties: false` and `required` covering every property. Nullable optionals → required keys whose schema allows `null`.
- **App-server hangs on tool-use turns when approval is required.** Upstream bug ([codex#11816](https://github.com/openai/codex/issues/11816)): `exec_approval.rs` awaits client approval with no timeout, no cancellation. Workaround: `approval: never` + `sandbox: danger-full-access`; lower `worker_timeout` to 120s in crowd-coding to limit blast radius.
- **App-server tests must drive handshake responses while `start()` is in flight.** `start()` correctly blocks on `initialize → initialized → thread/start`; awaiting `start()` before emitting responses deadlocks.
- **Approval-path sanitization is local containment only**, not transport mutation. Don't try to rewrite `tool_input` before the provider sees it.
- **Exec-mode shutdown must not await a pending `Process.start`.** One-shot harness `stop()` must complete the turn completer immediately and defer cleanup until spawn settles.

### Turn Routing
- **Provider-routed sessions need turn-reservation bookkeeping in `TurnManager`.** When provider selection happens at reserve time, all of `executeTurn` / `waitForOutcome` / `releaseTurn` must hit the same runner.
- **`_dispatchChannelTurn` must load full session history before `startTurn()`** to match the web UI path.

## HTMX / SSE

- **`hx-swap="outerHTML"` required with `hx-select`.** Default `innerHTML` nests the extracted element → duplicate IDs.
- **Every page needs `id="main-content"` + `hx-history-elt`.** Missing target → silent fallback to full-page nav.
- **`HX-Location` header for POST actions, not 302 redirects.** Avoids double GET.
- **`Vary: HX-Request` header on all web responses.** Required for browser/CDN caching correctness.
- **SSE `error` event triggers `onerror`, never named-event handlers.** Rename to e.g. `turn_error` for HTMX `sse-swap`.
- **`hx-swap="none"` doesn't insert HTML into DOM.** Use a hidden swap target with `innerHTML` instead.
- **HTMX-replaced containers lose direct event listeners.** Use document-level event delegation.

## Trellis Templates

- **`tl:if="${x > 0}"` fails smoke render when var is null.** Smoke render passes null for all variables. Pre-compute booleans in context builders.
- **Use `tl:attr="data-foo=${val}"` for data attributes.** Raw `data-foo="${val}"` skips Trellis escaping → attribute injection.
- **Trellis truthiness follows JS-like rules.** Complex conditions are safer as pre-computed Dart booleans.

## Config / YAML

- **`yaml_edit.update()` doesn't auto-create intermediate maps.** Throws `ArgumentError` on missing keys. Catch, create empty maps for missing segments, retry.
- **Empty YAML document root is null, not an empty map.** Initialize with `editor.update([], {})` before path creation works.
- **Trim string-to-enum config values on both parse paths.** `default_type: "analysis "` (trailing space) silently resolves to a different value.
- **JSON decoders emit doubles for whole-number values.** Distinguish `3000.0` (accept) from `3000.5` (reject) via `value != value.toInt().toDouble()`.

## Concurrency / Async

- **Serialize fire-and-forget writes via a `_pendingWrite` future chain.** `_pendingWrite = _pendingWrite.then((_) => _doWrite())` keeps callers non-blocking; independent `unawaited()` calls race.
- **Wrap fire-and-forget in `unawaited()` with a caught-and-logged error handler.** Never let exceptions escape silently.
- **`StreamController.broadcast()` fire is synchronous.** Subscribers update before the calling function returns; no `await Future.delayed()` needed in tests.
- **Concurrent HTTP + channel reviews need atomic state checks.** Two simultaneous accepts can otherwise both pass the status check.
- **Lazy first-use initialization races.** Flip state to `busy` *before* the async initialization await, or overlapping first calls both see `idle` and race past the single-use contract.

## Security

- **Constant-time webhook signature comparison via XOR accumulation.** Prevents timing attacks.
- **`ContentGuard` fails open when `ANTHROPIC_API_KEY` missing.** Warn at startup, disable guard.
- **MCP `ToolResult.error` is application-level, not JSON-RPC.** Spec requires success response with `isError: true` in content, not protocol-level `-32000`.
- **Suppress binary's built-in tools when providing MCP equivalents.** Add tool names to `disallowedTools` in `HarnessConfig`.
- **`includeParentEnvironment: false` is load-bearing whenever passing an explicit `environment:` map.** `Process.start` re-inherits parent env by default → sanitized overlays silently leak. `SafeProcess` exists to make this non-optional.
- **Sanitize git subprocess env, not just the binary.** `.git/config` can route through `core.sshCommand`, hooks, filters, and credential helpers that spawn shell children.

## Package Architecture

- **`ConfigNotifier` emits section-level keys (`security.*`), not sub-keys (`guards.*`).** `Reconfigurable.watchKeys` must use the section-level key or watches silently never fire — `ConfigDelta.hasChanged()` prefix-matches against section keys only.
- **Typedef-based decoupling avoids dragging deps across package boundaries.** e.g. `SearchIndexCounter` closure typedef instead of a raw `sqlite3.Database` handle.
- **Callback-based decoupling for cross-package event firing.** Package defines callback parameters; application layer wires to `EventBus`.
- **Channel config parsers self-register on import.** Bootstrap must call `ensure...Registered()` before `DartclawConfig.load()` or wiring fails with `StateError`.
- **Barrel re-exports work as backward-compat after package splits.** `export 'package:dartclaw_models/...'` preserves consumer imports.
- **Provider factories must normalize provider-specific executable defaults.** `HarnessFactoryConfig.executable` can only represent one default; each provider factory must substitute its own binary when not overridden.
- **Multi-provider UI/view-model code must derive the provider from `config.agent.provider`.** Hardcoded `'claude'` mislabels non-Claude deployments before usage data exists.
- **Harness capability differences belong on the base `AgentHarness` contract.** Expose via capability getters; consumers branch on flags. Unsupported telemetry → omission/null, never fake zero or provider-name conditionals.
- **Auto-accept callbacks must translate non-success `ReviewResult`s into thrown errors.** `TaskReviewService.review()` reports merge conflicts as typed results, not exceptions; callers wiring `Future<void>` callbacks otherwise lose the warning path.
- **Typedef-vs-class name collisions across packages need `hide` on the import.** e.g. `ReservedCommandHandler` typedef in `dartclaw_core` vs class in `dartclaw_cli`.

## Channel Integration

### Google Chat
- **Config keys use `google_chat`, not `googlechat`.** Even though `ChannelType.googlechat` omits the underscore. Mismatch → channel wiring silently disappears.
- **Use `argumentText`, not `message.text`.** `message.text` includes the `@mention` prefix.
- **Thread replies post with `thread: {name: <server-resource-name>}`, not `threadKey`.** Different API shapes for thread create vs thread reply.
- **`spaces.members.get` uses bare numeric ID, not the `users/` prefix.** Strip `users/` from sender JIDs before constructing member URLs.
- **`quotedMessageMetadata` requires user OAuth.** `chat.bot` returns 403. When quoting fails with a typing placeholder present, *edit* the placeholder — *deleting* it leaves a permanent "message deleted by its author" tombstone.
- **Reactions also require user OAuth.** `chat.bot` cannot create or delete.
- **Quoting unsupported in unthreaded spaces.** Check `spaceType` against `UNTHREADED_MESSAGES` (`DM`, `GROUP_CHAT`) before building the quote.
- **`CARD_CLICKED` payload is flat `Map<String, String>`, not nested JSON.** `invokedFunction` + flat string parameters.
- **Slash commands have two event shapes.** `MESSAGE` with `message.slashCommand` AND `APP_COMMAND` with `appCommandMetadata` — write a compatibility parser.
- **Typing placeholders must run on every dedup-eligible ingress path.** If only the webhook handler runs the placeholder, the dedup-winning Pub/Sub path skips it.
- **Thread binding endpoints must share the live `ThreadBindingStore` instance.** Per-request reconstruction reads stale file state.

### Workspace Events / Pub/Sub
- **Workspace Events scopes differ from Chat API scopes.** Service account auth needs `chat.app.spaces` + `chat.app.memberships`; standard `chat.bot` is insufficient.
- **Workspace Events service account auth is Developer Preview.** Even with correct scopes, a Workspace admin must grant one-time approval. User OAuth (GA) does not need admin approval.
- **Workspace Events API must be enabled separately** from Pub/Sub and the Chat API. Missing enablement → `403 SERVICE_DISABLED`.
- **Pub/Sub Publisher and Subscriber are separate grants on different resources.** `chat-api-push@system.gserviceaccount.com` needs Publisher on the topic; your service account needs Subscriber on the subscription. Easy to confuse the two `403`s.
- **Pub/Sub shutdown must `dispose()`, not just `stop()`.** `stop()` is restart-safe and won't abort in-flight HTTP pulls; process shutdown without `dispose()` hits the 5-second timeout.

### Signal
- **Sealed-sender: pairing UUID vs later `sourceNumber`.** Allowlist must handle both forms and self-heal on first dual-form message.
- **UUIDs are mixed-case.** Lowercase before storage and lookup.

## Workflow Engine

- **Shared worktree caches need both persisted bindings and per-key mutexes.** In-memory map alone fails on retry/restart; same-key fanout needs a `finally`-released waiter/completer guard.
- **Validator file splits must preserve diagnostic ordering.** `workflow validate` output order is observable, so rule-group moves need either the original call sequence in the composer or explicit golden coverage for ordering.
- **`git worktree list` automation must use `--porcelain`.** Human-format output is not stable for reconciliation.
- **Foreach unwraps must accept immutable map views.** Wrapped payloads can arrive as `UnmodifiableMapView`, not always `Map<String, dynamic>`.
- **Merge inside the integration worktree when the integration branch is checked out there.** Reusing the main checkout fails with `branch is already used by worktree` once a shared worktree owns the branch.
- **e2e artifact capture must snapshot the *terminal* task config**, not the queued snapshot. Otherwise completion-time writes are silently hidden even when the row was updated correctly.
- **Built-ins that drop semantic `type:` must explicitly author `type: custom`.** Parser keeps legacy omitted-`type` defaults for backward compat; intentional drops otherwise inherit old read-only/project-binding behavior.
- **Loop exit gates only see exact context keys — step outputs are NOT auto-namespaced.** A gate like `re-validate.findings_count == 0` requires the step to emit that dotted alias explicitly.
- **Broad `stepDefaults` glob patterns silently drift after step renames.** Re-validate the defaults layer whenever step IDs change.
- **Loop crash recovery needs a checkpoint after every successful sibling step.** Checkpointing only at iteration boundaries loses outputs the next sibling depends on.
- **Workflow start must preflight and persist effective `PROJECT`/`BRANCH` before any coding task is created.** Deferring resolution to `TaskExecutor` lets invalid runs leak coding tasks and serves authored defaults to early prompts.
- **Local-path projects need their dirty-tree / branch-mismatch gate at the same workflow-start seam.** Putting the check later leaks coding tasks against a live checkout.
- **Workflow-owned refs stay local refs all the way through publish.** Coding steps must attach to the existing branch/worktree; base-ref freshness logic must stop rewriting back to `origin/*`.
- **Workflow git cleanup must run after child-task shutdown and walk the full run-owned set.** Shared-key cleanup is insufficient for `per-map-item` workflows.
- **Artifact auto-commit must verify task worktree paths are real git worktrees.** Test scaffolds and workflow workspaces may use temporary directories for output materialization; commit load-bearing artifacts to the resolved project checkout instead.
- **Partial inline structured payloads must not satisfy a structured-output schema.** If any required narrative key is missing, run the extraction turn and let context extraction preserve inline precedence per field.
- **Artifact commit must use output resolver semantics, not raw output formats.** List-shaped filesystem outputs can be represented as `lines` in the current model but are still load-bearing artifacts.
- **Dependency-aware fan-out is explicit, not inferred from object shape.** The shared map/foreach scheduler only engages when items declare `dependencies`; root records in that mode still need `dependencies: []`, or validation correctly treats the collection as malformed.
- **Promotion-conflict retries need the iteration cursor preserved on failure.** If a dependency-aware `mapOver` / `foreach` clears `executionCursor` after a blocked promotion, downstream items become permanently undispatchable and `workflow retry` cannot resume the ready-set correctly.

## Storage / Data Model

- **Tail-window pagination is a parse-window optimization.** Scan NDJSON from the end; materialize only the requested window. Cursor semantics stay 1-based line numbers.
- **Task sessions have multi-layer protection from maintenance pruning.** `_isProtected()`, `_pruneStale()` skip, `protectedTypes` set, `deleteSession()` throws, `listSessions()` excludes by default.
- **FTS5 MATCH has special operators.** Wrap user input in double quotes for literal matching.
- **Task persistence is schema-backed, not generic-JSON-backed.** New `Task` fields require schema, migrations, insert/update, hydration — not just `toJson()`/`fromJson()`.
- **Legacy task-table migrations must guard missing columns at every SQL touch point.** Branching only the backfill INSERT is insufficient; index creation and `INSERT ... SELECT` also need conditional column references.

## Container / Deployment

- **Docker `exec` needs parent PATH preserved.** Otherwise host can't resolve the `docker` binary.
- **Local-path projects need explicit per-project `/projects/<id>` mounts** even when the clones root is mounted. The legacy `/projects:ro` root only covers data-dir clones.
- **Hardening env vars need dual injection paths.** Direct spawns inherit `HarnessFactoryConfig.environment`; containerized runs only see vars passed to `ContainerManager.exec(env:)`. Apply in both.
- **GitHub release assets need a separate `latest/download` URL path.** Don't treat `latest` as a normal version segment under `/releases/download/<version>/...`.
- **Token bootstrap (`?token=`) must be route-agnostic.** Must work on deep links like `/settings`, then redirect back without leaking the token.

## Tooling / Verification

- **Workflow Codex E2E needs real `CODEX_API_KEY`** even when the binary starts cleanly. Empty creds surface as websocket `401 Unauthorized` on the first live turn — environment blocker, not product regression.
- **Path-output test stubs must materialize claimed files under the same roots production validation probes.** For workflow tests, write files under task worktree, `dataDir/projects/<projectId>`, and discovered `project_root` when relevant; otherwise stricter path validation correctly coerces outputs to empty.
- **Nested `dart run` subprocesses inside `dart test` can stall on build hooks.** Use `Platform.resolvedExecutable` against the script path from the package root.
- **Filesystem teardown for project/worktree tests needs async retry, not one-shot `deleteSync()`.** Git/file watchers leave temp dirs briefly non-empty.
- **`HarnessWiring` is the deterministic seam for spawn-time prompt tests.** `ServiceWiring` hides spawn behind the background poller; wire `StorageWiring` + `SecurityWiring` + `HarnessWiring` directly with a recording harness factory.
- **Standalone CLI preflight tests must inject an explicit environment snapshot.** Otherwise `Platform.environment` makes credential tests non-deterministic.
- **`TurnManager` interface changes ripple into many test doubles.** New optional named parameters break test-local subclass compilation everywhere.
- **Focused package runs are the stable verification unit for server feature slices.** Full parallel runs surface unrelated temp-dir flakiness that obscures the feature under test.
- **Provider-validator runs before the fake harness factory is used.** Wiring tests still need a dummy credential entry for the selected provider, even when no subprocess launches.
- **Workspace-root sqlite validation owns native-asset regeneration.** Adding `sqlite3` only at package scope leaves the root `.dart_tool/native_assets.yaml` stale and breaks package-wide test runs.
- **Testing-profile smoke runs should bypass stale CLI snapshots after schema changes.** `docs/testing/*/run.sh` prefers cached `.dart_tool/pub/bin` snapshots; rebuild after storage migrations or you'll debug old code.
- **Nested architecture-doc links resolve relative to the nested doc, not the repo root.** Run a scoped markdown link check after architecture-doc edits — silent drift otherwise.
- **Mechanical file-split refactors silently change behavior via fallback differences.** Verify shared utility functions have identical fallback behavior to the inlined original — `null` vs fallback-object, empty-string vs error-summary, etc.
