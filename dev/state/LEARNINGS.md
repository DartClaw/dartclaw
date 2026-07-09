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
- **An arrow-body `Future.then` cleanup callback re-adopts the source future.** `probe.then((_) => _cache.remove(key), onError: (e,_) => _cache.remove(key))` returns the cached future itself; on rejection the continuation adopts that error as an *unhandled* async error. Use statement bodies (`{ _cache.remove(key); }`) so the callbacks return void.

## Agent Harness Protocols

### Claude
- **`CLAUDECODE` env var causes nesting refusal.** Clear in subprocess environment.
- **Model override goes via `--model` CLI flag, not the initialize field.**
- **`sdkMcpServers` map must be spread, not double-wrapped.** Helpers already return the top-level shape; passing into another `sdkMcpServers:` field silently produces `sdkMcpServers.sdkMcpServers`.
- **`--dangerously-skip-permissions` is only safe with hooks active.** Restricted-container simple mode disables hooks → fail-closed on `can_use_tool`.
- **`file_edit` is granted separately from `file_write`.** The Claude one-shot allow-list (`claude_cli_provider.dart#_ClaudeTaskPolicy.allowPatterns`) emits `Edit(*)/MultiEdit(*)/NotebookEdit(*)` only when a step's `allowedTools` contains `file_edit`; `file_write` alone grants just `Write(*)`. Under `--permission-mode dontAsk` (the standalone default) a step needing `Edit` but lacking `file_edit` is hard-denied ("haven't granted it yet"). No workflow definition listed `file_edit`, so standalone remediate/implement/triage steps could create files but never edit existing ones — remediation stalls into a `needsInput` hold. Masked in server mode (interactive `can_use_tool`). Permission-mode (prompt gating) and Claude's sandbox (OS isolation via Seatbelt/bubblewrap `sandbox.enabled`) are **orthogonal** axes — never map `sandbox`→skip-permissions. Fix specced: `dev/bundle/docs/specs/0.20/claude-standalone-edit-grant-and-permission-sandbox-parity.md`.
- **Per-turn `system_prompt` *replaces* spawn-time `--append-system-prompt`.** Don't inject conversation history via system prompt for `PromptStrategy.append`. Inject as `<conversation_history>` XML in the user message on cold-process turns only.
- **`_buildClaudeArgs()` is process-level, not per-task.** `HarnessPool` reuses long-lived runners; per-task flags require new processes or pool segmentation.
- **Container mode: skip host probes.** No `claude --version` / auth probes from inside the container.
- **Direct Claude setting sources default to inherited user scope.** Omit `--setting-sources` unless `providers.claude.inherit_user_settings: false`; workflow skill preflight must use the same policy as execution or `andthen:*` skills disappear before dispatch.
- **One-shot `--output-format json` is buffered and starves the stall monitor.** `claude -p --output-format json` emits a single object only at turn completion — zero stdout while working, so a silence-timer stall guard false-trips on any long turn. Use `--output-format stream-json --verbose --include-partial-messages` for per-line liveness; parse the terminal `type: "result"` event, where tokens nest under `usage.*` (`input_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`), not top-level. Codex `exec --json` already streams JSONL, so this only bites claude.
- **`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` scrubs auth env vars and its stderr warning masks the real failure.** Applied to every claude spawn via `claudeHardeningEnvVars`, it forces permission mode to default and prints a benign stderr notice ("Permission mode forced to default … allowed_non_write_users hardening") — but the *actual* failure (e.g. a 401 when no credential survives the scrub) lands on **stdout**. Any claude subprocess path that reports only stderr on a nonzero exit hides the real cause; surface stdout first (the skill introspector did this wrong). The scrub strips *env-borne* secrets (e.g. an `ANTHROPIC_API_KEY` not re-injected from the credential registry); it does **not** strip subscription OAuth, which lives in the macOS keychain and never flows through env — see the next bullet for the standalone-workflow 401 root cause.
- **The standalone-workflow `claude` 401 was a logged-out CLI + a missing workflow-path auth preflight — not env-scrub credential stripping.** Subscription OAuth lives in the keychain (never in env), so env scrubbing cannot strip it; the 401 surfaced mid skill-introspection because the workflow path had no pre-step auth gate (serve/container modes did). Fix: a `ProviderAuthPreflight` runs over the referenced-provider set before skill introspection and aborts with provider-named remediation (`claude login` / `claude setup-token` / `ANTHROPIC_API_KEY`; codex `codex login` / `CODEX_API_KEY` / `OPENAI_API_KEY`). **`USER`-for-keychain invariant:** the standalone `claude` CLI reads its keychain OAuth only when `USER` is present in the spawn env (`HOME`+`PATH` alone → "not logged in"). The workflow provider spawn sanitize keeps `USER` (no allowlist) — do not add an allowlist that drops it; guarded by a regression test on the provider env builder.
- **The executor-level auth preflight ran too late for standalone — the CLI gate is additive, before harness startup.** The executor's `_preflightProviderAuth` runs inside `WorkflowExecutor.execute()`, but standalone `CliWorkflowWiring.wire()` started the default-provider primary (and `ensureTaskRunnersForProviders` could start referenced-provider runners) *before* the engine ran, so a logged-out default surfaced a raw `StateError` from `harness.start()` and could block a run that referenced only another provider. Fix: split CLI wiring into `wirePreHarness()` (prelude/storage/task-layer/registry; `continuityProviders` from `HarnessFactory.probeContinuityProviders()`, `cwd:'/'`, no spawn) and `startHarnesses(providers)` (deferred, primary drawn from `providers`); the standalone run/resume/retry paths derive `requiredWorkflowProviders`, run `preflightProviderAuth(set)` (friendly `WorkflowPreflightException`), then `startHarnesses(set)`. Result: a logged-out referenced provider aborts before any `harness.start()`; an unreferenced logged-out default is never started or probed (OC02). The executor-level preflight stays as the in-engine backstop (connected mode + non-CLI callers). Cancel/pause keep starting only the default primary without the gate (they execute no steps).

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
- **Append-mode harnesses need explicit per-turn prompt exceptions for scoped behavior.** `PromptStrategy.append` normally returns an empty per-turn system prompt to avoid replacing the spawn prompt. Scoped web-only behavior such as onboarding must opt into a full scoped static prompt for that turn; changing the default would leak behavior into non-web callers.

## HTMX / SSE

- **`hx-swap="outerHTML"` required with `hx-select`.** Default `innerHTML` nests the extracted element → duplicate IDs.
- **Every page needs `id="main-content"` + `hx-history-elt`.** Missing target → silent fallback to full-page nav.
- **`HX-Location` header for POST actions, not 302 redirects.** Avoids double GET.
- **`Vary: HX-Request` header on all web responses.** Required for browser/CDN caching correctness.
- **SSE `error` event triggers `onerror`, never named-event handlers.** Rename to e.g. `turn_error` for HTMX `sse-swap`.
- **`hx-swap="none"` doesn't insert HTML into DOM.** Use a hidden swap target with `innerHTML` instead.
- **HTMX-replaced containers lose direct event listeners.** Use document-level event delegation.
- **Chat form success does not always mean SSE starts.** Command-intercept responses append ordinary HTML and never create `#streaming-msg`; composer controllers must reset on successful non-streaming form responses instead of waiting for `htmx:sseClose`.

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
- **MCP `ToolResult.error` is application-level, not JSON-RPC.** Spec requires success response with `isError: true` in content, not protocol-level `-32000`.
- **Suppress binary's built-in tools when providing MCP equivalents.** Add tool names to `disallowedTools` in `HarnessConfig`.
- **`includeParentEnvironment: false` is load-bearing whenever passing an explicit `environment:` map.** `Process.start` re-inherits parent env by default → sanitized overlays silently leak. `SafeProcess` exists to make this non-optional.
- **Sanitize git subprocess env, not just the binary.** `.git/config` can route through `core.sshCommand`, hooks, filters, and credential helpers that spawn shell children.

## Package Architecture

- **`ConfigNotifier` emits section-level keys (`security.*`), not sub-keys (`guards.*`).** `Reconfigurable.watchKeys` must use the section-level key or watches silently never fire — `ConfigDelta.hasChanged()` prefix-matches against section keys only.
- **Channel config parsers self-register on import.** Bootstrap must call `ensure...Registered()` before `DartclawConfig.load()` or wiring fails with `StateError`.
- **Provider factories must normalize provider-specific executable defaults.** `HarnessFactoryConfig.executable` can only represent one default; each provider factory must substitute its own binary when not overridden.
- **Multi-provider UI/view-model code must derive the provider from `config.agent.provider`.** Hardcoded `'claude'` mislabels non-Claude deployments before usage data exists.
- **Harness capability differences belong on the base `AgentHarness` contract.** Expose via capability getters; consumers branch on flags. Unsupported telemetry → omission/null, never fake zero or provider-name conditionals.
- **Auto-accept callbacks must translate non-success `ReviewResult`s into thrown errors.** `TaskReviewService.review()` reports merge conflicts as typed results, not exceptions; callers wiring `Future<void>` callbacks otherwise lose the warning path.
- **Typedef-vs-class name collisions across packages need `hide` on the import.** e.g. `ReservedCommandHandler` typedef in `dartclaw_core` vs class in `dartclaw_cli`.
- **Green tests can mask unwired features.** Direct-call tests don't prove a service is registered in ServiceWiring/ScheduleService — verify wiring via integration test + grep for non-test refs.
- **Resolved step config has multiple consumers.** New inherited step fields must flow through dispatch, follow-up prompts, extraction, and resolved-YAML export.

## Channel Integration

### Google Chat
- **Config keys use `google_chat`, not `googlechat`.** Even though `ChannelType.googlechat` omits the underscore. Mismatch → channel wiring silently disappears.
- **Use `argumentText`, not `message.text`.** `message.text` includes the `@mention` prefix.
- **`spaces.members.get` uses bare numeric ID, not the `users/` prefix.** Strip `users/` from sender JIDs before constructing member URLs.
- **`quotedMessageMetadata` requires user OAuth.** `chat.bot` returns 403. When quoting fails with a typing placeholder present, *edit* the placeholder — *deleting* it leaves a permanent "message deleted by its author" tombstone.
- **Reactions also require user OAuth.** `chat.bot` cannot create or delete.
- **Quoting unsupported in unthreaded spaces.** Check `spaceType` against `UNTHREADED_MESSAGES` (`DM`, `GROUP_CHAT`) before building the quote.
- **`CARD_CLICKED` payload is flat `Map<String, String>`, not nested JSON.** `invokedFunction` + flat string parameters.
- **Slash commands have two event shapes.** `MESSAGE` with `message.slashCommand` AND `APP_COMMAND` with `appCommandMetadata` — write a compatibility parser.
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

- **Strict task-spawn dependencies need a lifecycle-only construction path.** `WorkflowService`'s default constructor requires task-persistence ports (so production wiring fails at compile time when missing); route/view tests and webhook fakes that only exercise pause/resume/cancel/list should use the explicit lifecycle-only constructor, not fabricated persistence ports.
- **Shared worktree caches need both persisted bindings and per-key mutexes.** In-memory map alone fails on retry/restart; same-key fanout needs a `finally`-released waiter/completer guard.
- **Validator file splits must preserve diagnostic ordering.** `workflow validate` output order is observable, so rule-group moves need either the original call sequence in the composer or explicit golden coverage for ordering.
- **`git worktree list` automation must use `--porcelain`.** Human-format output is not stable for reconciliation.
- **Review-report path outputs must resolve from the runtime-artifacts `reviews/` dir (`--output-dir`), never the worktree diff.** `resolveFileSystemOutput` must, in order: accept the bare-suffix alias (a parallel step namespaces its output `<stepId>.review_report_path` to avoid context-key collisions; the skill emits bare `review_report_path`); try the runtime-artifacts root before worktree-relative (when `.data/` is nested in the checkout, an absolute claim is also inside the worktree and would resolve wrong); fall back to the newest report in the reviews dir rather than throwing. Worktree-relative reports (e.g. `andthen:architecture` via `review-report-location.md`) legitimately use the diff path, so the fix is precedence/aliasing, not removing the fallback. Parallel review steps uniformly prefix keys `<stepId>.{review_report_path,findings_count,gating_findings_count}`; aggregate-step keys stay bare. Contract-locked in `built_in_workflow_contracts_test.dart`.
- **Merge inside the integration worktree when the integration branch is checked out there.** Reusing the main checkout fails with `branch is already used by worktree` once a shared worktree owns the branch.
- **e2e artifact capture must snapshot the *terminal* task config**, not the queued snapshot. Otherwise completion-time writes are silently hidden even when the row was updated correctly.
- **Workflow agent steps should omit `type:` or use `type: agent`.** Removed authoring values such as `custom`, `coding`, `research`, `analysis`, `writing`, and `automation` now fail validation; read-only behavior belongs in `allowedTools`, not semantic step names.
- **Loop exit gates only see exact context keys — step outputs are NOT auto-namespaced.** A gate like `re-validate.findings_count == 0` requires the step to emit that dotted alias explicitly.
- **Broad `stepDefaults` glob patterns silently drift after step renames.** Re-validate the defaults layer whenever step IDs change.
- **Loop crash recovery needs a checkpoint after every successful sibling step.** Checkpointing only at iteration boundaries loses outputs the next sibling depends on.
- **Workflow start must preflight and persist effective `PROJECT`/`BRANCH` before any coding task is created.** Deferring resolution to `TaskExecutor` lets invalid runs leak coding tasks and serves authored defaults to early prompts.
- **Resolve a null `gitStrategy` as the default `auto` before keying worktree behavior on the resolved mode.** All worktree-mode resolution flows through the single `step_config_policy.resolveWorktreeMode` seam = `(strategy ?? const WorkflowGitStrategy()).effectiveWorktreeMode(...)`, so a strategy-less parallel map/foreach resolves to `per-map-item` (isolated worktrees, fan-out preserved) — not `inline`. With null collapsed to `auto`, the map/foreach concurrency clamp keys safely on the *resolved* mode (`resolvedWorktreeMode == 'inline' ? 1 : maxParallel`): only an authored `worktree: inline` or the `--inline` override resolves to `inline` and serializes; everything else keeps `maxParallel` fan-out. The clamp and the dispatcher's worktree-provisioning gate (`resolvedWorktreeMode != 'inline'`) therefore agree on one resolved value. (Trap that was fixed here: the runners previously used `... ?? 'inline'`, collapsing null to a literal `inline` so the dispatcher skipped per-item worktrees while the clamp — keyed on the authored null mode — ran iterations concurrently against one shared checkout. The fix is at the resolution layer, not a clamp special-case.)
- **Local-path projects need their dirty-tree / branch-mismatch gate at the same workflow-start seam.** Putting the check later leaks coding tasks against a live checkout.
- **Workflow git cleanup must run after child-task shutdown and walk the full run-owned set.** Shared-key cleanup is insufficient for `per-map-item` workflows.
- **Artifact auto-commit must verify task worktree paths are real git worktrees.** Test scaffolds and workflow workspaces may use temporary directories for output materialization; commit load-bearing artifacts to the resolved project checkout instead.
- **Artifact commit must use output resolver semantics, not raw output formats.** List-shaped filesystem outputs can be represented as `lines` in the current model but are still load-bearing artifacts.
- **Dependency-aware fan-out is explicit, not inferred from object shape.** The shared map/foreach scheduler only engages when items declare `dependencies`; root records in that mode still need `dependencies: []`, or validation correctly treats the collection as malformed.
- **Resume `story_specs` legitimately carry deps on completed stories; prune by completion status in the contract layer, not in `DependencyGraph`.** On resume, discovery excludes done/skipped stories but their IDs still appear in remaining stories' `dependsOn`. `validateStorySpecsContract(completedStoryIds:)` prunes a dep only when it names a `done`/`skipped` plan story (per `plan.json` `stories[].status`). Prune by *completion status*, not mere absence from the emitted set — a story can be absent for non-completion reasons (no `fis`, `blocked`, dropped) and pruning those would treat an unsatisfied prerequisite as met. Keep deps on non-completed/unknown ids so `DependencyGraph` still rejects them (typos, hallucinated text, real-but-incomplete prereqs). Null catalog → strict. `DependencyGraph` is untouched.
- **Promotion-conflict retries need the iteration cursor preserved on failure.** If a dependency-aware `mapOver` / `foreach` clears `executionCursor` after a blocked promotion, downstream items become permanently undispatchable and `workflow retry` cannot resume the ready-set correctly.
- **`map_iteration_dispatcher` and `step_dispatcher` share the same async-listener / SQLite-teardown race.** Both need the synchronous-listener pattern: filter `failed + retry-in-progress` and `queued|running` re-emissions, then fire-and-forget `_taskService.get` for terminal events. Fixing only one leaves the other ticking.
- **Foreach-vs-mapOver routing is a real footgun for skill tests.** The merge-resolve retry loop and `serialize-remaining` drain live in `_executeForeachStep` (ForeachNode), not `_executeMapStep` (MapNode). Tests using a plain `mapOver` step silently take the wrong code path; they must use a foreach controller (`type: foreach`, `foreachSteps: [...]`) for the new state machines to fire.
- **Multi-flag idempotency persists are crash-windows.** Two booleans persisted in sequence (e.g. `is_serial_mode` then `drain_done`) leave a window where a crash mid-sequence reopens the work on resume. Use a single phase-string field (`enacting`/`drained`/`none`) and persist it atomically.
- **Per-attempt artifact filenames must scope by foreach iteration index.** A multi-story foreach with `merge_resolve_attempt_<n>.json` collides across iterations under the same task id; scope as `merge_resolve_iter_<i>_attempt_<n>.json`.
- **Bash variable interpolation must shell-escape both `{{context.X}}` and `{{VAR}}` for symmetry.** Asymmetric escape-vs-raw is an injection footgun; the consistency contract is "all interpolations escape; if you need literal text, write it directly in the template."
- **Schema validator strictness is signaling, not enforcement.** Treat `additionalProperties: false`, `enum`, `minimum`, `maximum` as warnings under the soft-validate contract — they catch preset drift without breaking legacy YAML.
- **`workflow_definition_parser._parseGitStrategy` is the real wiring gate for `gitStrategy:` extensions.** Adding a new typed sub-block to `WorkflowGitStrategy` without threading it through the parser leaves YAML-sourced workflows silently dropping the field; validator unit tests pass but `workflow validate` is unreachable. Always add the parser threading and a parser test in the same change.
- **`OutputConfig.setValue: null` vs absent must round-trip distinctly.** A plain `Object? setValue` collapses "explicitly null" and "unset" at the JSON layer, breaking the per-iteration reset semantic. Back it with a sentinel-or-value (`_workflowDefinitionFieldUnset` = unset; anything else, incl. `null` = explicitly set), gate `toJson` on `hasSetValue`, and treat `json.containsKey('setValue')` as the `fromJson` discriminator. Applies to any future per-key literal slot on `OutputConfig`.
- **Workflow validators that compare provider roles need runtime role defaults.** Alias equality such as `@executor` vs a concrete provider is only meaningful after resolving through `WorkflowRoleDefaults`; CLI validation and server wiring must construct validators with the same configured defaults the runtime will use.
- **Use task-level `maxRetries` for harness crashes, not `onFailure: retry` for story steps.** `onFailure: retry` retries explicit failed `<step-outcome>` results too, which can re-enter a per-story worktree containing the prior semantic failure's partial diff. Resilient story fan-out should record failed slots and let later review/summary steps consume the aggregate.
- **Standalone workflow teardown must preserve non-terminal workflow git state.** Approval-held, paused, and running workflows still need their integration branch and per-map worktrees for resume. Cleanup on process dispose should only reap terminal runs; otherwise the next task attaches to a deleted workflow-owned ref.
- **Best-effort workflow cleanup should use `onFailure: continue`, not a cleanup-specific branch.** Optional steps such as `simplify-code` may emit `needsInput` on red baselines; treating `continue` as "record and advance" for both `failed` and `needsInput` keeps required producer/review semantics strict while avoiding workflow-specific special cases.
- **Post-step artifact validation must follow the producing task worktree.** A workflow can resolve its active root before later git isolation binds a task worktree; validating `story_specs.spec_path` against the stale root rejects files the step wrote. Prefer `task.worktreeJson.path` for path-bearing outputs; active root only as the no-worktree fallback.
- **Live workflow step-isolation tests must cancel provider turns before deleting sessions.** Dart test timeouts can fire while a Codex subprocess is still returning; teardown must call the runner cancellation seam before disposing message storage or removing the temp session directory.
- **`gating_findings_count` counts review findings at or above the resolved gating severity (`gatingSeverity`, default `high`), not fix-character.** DartClaw-owned LLM-prompt preset in `schema_presets.dart` (`gatingFindingsCountPreset`); built-in remediation loops gate exit on `== 0`. Sub-threshold findings are reported but never block, so the loop converges. The deterministic `isGatingFinding` fallback in `review_finding_derivations.dart` applies the same severity threshold to inline `verdict`-shaped payloads. Used only as a loop entry/exit measure in the built-in YAMLs, never a terminal pass/fail quality gate.
- **Deleting a skill-name-gated validator can silently drop a security axis the generic replacement doesn't cover.** ADR-041 decoupling removed `discover_andthen_spec_validator`, which ran `validateArgumentSafePath` (flag-shaped-segment/control-char rejection) on the spec workflow's top-level `spec_path` before it's interpolated into `--auto {{context.spec_path}}`. The generic `format:path` resolver does containment+existence ONLY, and `_requiresActiveWorkspaceRoot` fired only on `story_specs` steps — so `spec_path` lost argument-safety. The whole test suite stayed green because the only parity scenario exercised `story_specs.items[].spec_path` (which kept argument-safety via `produced_artifact_resolver`), never the bare `spec_path`. Trap: when deleting a bespoke validator in favor of a generic path, enumerate EVERY axis the old one enforced (containment, existence, AND argument-safety) and prove each at the generic surface for every output shape, not just the one the happy-path test touches. Fix landed in `context_extractor._assertArgumentSafeFileSystemOutput` (non-absolute single-value path outputs only; absolute runtime-artifacts + list outputs exempt). Related: [[green-tests-mask-unwired-features]].
- **Un-gating validation onto a generic validator means removing EVERY fail-closed layer keyed on that precondition, not just the dispatch gate.** ADR-041 moved `story_specs` validation onto the generic `format: path` path (`story_spec_output_validator.dart`), which already does the correct no-root behavior (containment + argument-safety enforced, existence skipped — S02 OC05). But two stale fail-closed layers keyed on "no active workspace root" survived and shadowed it: (1) a run-level pre-dispatch guard in `workflow_executor.dart` (`_requiresActiveWorkspaceRoot` → `_failRun('Workflow requires an active workspace root…')`) and (2) a post-validation override in `workflow_executor_helpers.dart._validateStorySpecOutputs` that manufactured a failure whenever `story_specs` was present with a null/empty root. The FIS was marked done with S02-C checked, yet no-root `story_specs` still failed closed end-to-end because the generic path never got to run. Trap: when promoting a skill-gated check onto a generic validator, grep for ALL guards keyed on the same precondition — run-level AND per-output post-validation — not only the dispatch-site skill-name gate; a leftover fail-closed layer silently defeats the generic path's edge-case behavior while unit tests of the generic validator stay green. Fix: removed both layers; `_requiresActiveWorkspaceRoot` → `_emitsStorySpecs` (resolves the root when available, never fails on its absence). Sibling to the entry above on the same decoupling dropping a security axis.
- **A "canonical manifest" only holds if BOTH the write side and the read side honor it.** `SkillProvisioner` wrote the DC-native skill cache from `dartclaw-native-skills.txt`, but `WorkspaceSkillInventory._discoverSkillNames` read it back by wildcard (`any dartclaw-* dir with SKILL.md`), so a stale managed skill left on disk after a manifest removal was still linked into workspaces and could satisfy preflight — the manifest was canonical on write, advisory on read. Cleanup was a hardcoded `retiredDcNativeSkillNames` list (a manual mirror of "manifest by absence" that rots). Fix (both ends): provisioning purges every `dartclaw-*` cache dir the manifest omits (no hardcoded list) AND persists the manifest names to the data-dir marker, which the inventory intersects against discovered names (shared reader in `dc_native_skill_manifest.dart`). Trap: when a file/manifest is declared the source of truth for an inventory, audit every *reader* too — a wildcard/glob discovery on the same directory silently reopens the drift the manifest was meant to close, and tests that only check "the manifest skills are present" pass while the stale extras leak. Note: a read-side manifest guard that falls back to wildcard on an absent/legacy marker is bounded by the write-side purge, not a standalone guarantee — keep both.

## Storage / Data Model

- **Durable knowledge graph facts belong in `tasks.db`, not `search.db`.** `search.db` is rebuildable from MEMORY.md and can be deleted/rebuilt; temporal KG facts are authoritative source-linked records and must use the durable task database connection.
- **Task sessions have multi-layer protection from maintenance pruning.** `_isProtected()`, `_pruneStale()` skip, `protectedTypes` set, `deleteSession()` throws, `listSessions()` excludes by default.
- **FTS5 MATCH has special operators.** Wrap user input in double quotes for literal matching.
- **Task persistence is schema-backed, not generic-JSON-backed.** New `Task` fields require schema, migrations, insert/update, hydration — not just `toJson()`/`fromJson()`.
- **Legacy task-table migrations must guard missing columns at every SQL touch point.** Branching only the backfill INSERT is insufficient; index creation and `INSERT ... SELECT` also need conditional column references.
- **Validate untrusted-ingestion payloads before the first durable write, and never treat LLM text as a control boundary.** Order all checks before any sink (else retries re-run committed writes); parse structured output from a delimiter-safe channel, not free text that source-embedded fences can forge.
- **Webhook pending-state TTL must move forward on successful commit.** Reclaiming an old pending row and then marking it processed without refreshing the TTL anchor lets the next purge delete the dedupe marker immediately.

## Container / Deployment

- **Docker `exec` needs parent PATH preserved.** Otherwise host can't resolve the `docker` binary.
- **Local-path projects need explicit per-project `/projects/<id>` mounts** even when the clones root is mounted. The legacy `/projects:ro` root only covers data-dir clones.
- **Hardening env vars need dual injection paths.** Direct spawns inherit `HarnessFactoryConfig.environment`; containerized runs only see vars passed to `ContainerManager.exec(env:)`. Apply in both.
- **GitHub release assets need a separate `latest/download` URL path.** Don't treat `latest` as a normal version segment under `/releases/download/<version>/...`.

## Tooling / Verification

- **Asset resolution precedence must treat explicit source paths as intent, not freshness hints.** Dev/testing profile runs pass `--source-dir` specifically to exercise the checkout, so a populated `~/.dartclaw/assets/v<version>` cache must never shadow those templates/static assets even when its `VERSION` matches. The cache version marker only catches cross-version leftovers; within a development cycle the version can lag content, so startup must log the resolved asset source and wire templates, static files, skills, and workflow definitions from one resolved asset session.
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
- **Testing-profile smoke runs should bypass stale CLI snapshots after schema changes.** `dev/testing/profiles/*/run.sh` prefers cached `.dart_tool/pub/bin` snapshots; rebuild after storage migrations or you'll debug old code.
- **Mechanical file-split refactors silently change behavior via fallback differences.** Verify shared utility functions have identical fallback behavior to the inlined original — `null` vs fallback-object, empty-string vs error-summary, etc.
- **Prove env-export fidelity with a fast micro-canary, not a full `workflow-live --canary` run.** A single live provider `executeTurn` whose prompt runs `mkdir -p "$VAR"` with the value injected via `extraEnvironment`, asserting the real dir was created (~11s), covers the only unit-untestable link — provider-CLI → shell-tool env inheritance + expansion — for any per-task spawn-env feature. The host-side transform/merge stays covered by unit+integration tests; the micro-canary covers just the provider-internal seam. Pattern: real `WorkflowCliRunner` (codex, sandbox `danger-full-access`, PATH/HOME inherited since `SafeProcess` uses `includeParentEnvironment:false`), integration-tagged, guarded by `codexAvailable()`.
- **Green unit suites hide wiring gaps.** Tests injecting absolute paths/null deps prove units, not the product. Require ≥1 test driving the real composition root + path discovery.
- **Bounded filesystem traversal must stream entries.** `Directory.list().toList()` defeats traversal budgets in large flat directories even if callers later cap result counts.
- **Contract-changing stories need the full CI gate.** Retyping a parse/validation contract consumed cross-package requires workspace analyze + all-package tests + fitness.
