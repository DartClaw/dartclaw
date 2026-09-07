# Project Learnings

<!-- Traps only, one bullet each: `- **{title}** – …`, trap + pointer, under 200 chars; postmortem depth lives in
     the spec archive, an ADR, or an architecture doc. Bar: "Would a competent developer with code and git access
     still get bitten?" Skills read this document whole. Maintain via the `andthen:ops` skill
     (`update-learnings dev/state/LEARNINGS.md add <topic> <entry>`); the ceiling is the Project Document Index
     row – at the ceiling, `ops prune` this file, never shard it. Delete entries once encoded as checks or stale. -->

## Dart Language

- **Injected paths need matching path context.** Host-default `package:path` joining corrupts Windows fixture paths on POSIX; select `p.windows` for drive or UNC homes.
- **`Future.timeout` cannot interrupt synchronous regex.** Single-threaded event loop. Mitigate via input truncation, not per-pattern timeouts.
- **Zone context lost in `.listen()` callbacks.** Values set with `runZonedGuarded` / `LogContext.runWith()` aren't visible inside async stream callbacks once control returns to the event loop.
- **Microtask starvation in async loops.** A loop awaiting only microtask futures never lets timers fire (`stop()`, `Completer`s) → OOM. Yield via `await Future<void>.delayed(Duration.zero)`.
- **DST-boundary date arithmetic flakes test fixtures.** `Duration(days: N)` from a local-midnight `DateTime` can land on the previous day; build date fixtures from explicit year/month/day.
- **An arrow-body `Future.then` cleanup callback re-adopts the source future.** `.then((_) => _cache.remove(key))` returns the cached future; its rejection goes unhandled. Use `{ … }` bodies.

## Agent Harness Protocols

- **A terminal result is an outcome, not success.** A resolved harness future can carry `TurnResult.isError`; translate it before guarding or persisting streamed assistant text.
- **Process ownership ends after confirmed exit.** Await the shared termination helper before removing a managed child; keep unconfirmed exit observable.
- **Pre-signalled termination must carry acceptance, not an attempted flag.** Typed results lie if callers discard `Process.kill()`'s bool; thread nullable acceptance to suppress duplicate kills.

### Claude
- **`CLAUDECODE` env var causes nesting refusal.** Clear in subprocess environment.
- **The SDK `initialize` handshake carries no policy, model, cap or effort field, and the CLI ignores unknown handshake keys silently.** `disallowedTools` / `maxTurns` sent there were no-ops from 0.6 to 0.25.1; they are spawn flags (`--max-turns`, `--disallowedTools <names…>` variadic, keep it last). Verify a handshake field against the SDK payload in the binary (`subtype:"initialize"`) before relying on it.
- **The terminal `result` line's `result` string is the final assistant message only** (verified on 2.1.261); it is the `TurnResult.finalText` source, and on an error line it holds the failure detail, so it is dropped there.
- **`sdkMcpServers` map must be spread, not double-wrapped.** Helpers already return the top-level shape; passing into another `sdkMcpServers:` field silently produces `sdkMcpServers.sdkMcpServers`.
- **`--dangerously-skip-permissions` is only safe with hooks active.** Restricted-container simple mode disables hooks → fail-closed on `can_use_tool`.
- **`file_edit` is granted separately from `file_write`.** Workflow tasks carry canonical `allowedTools` onto their leased harness worker, where `TaskToolFilterGuard` evaluates the exact grant. Permission mode and Claude's sandbox (`sandbox.enabled`) are orthogonal axes – never map sandbox→skip-permissions.
- **Per-turn `system_prompt` *replaces* spawn-time `--append-system-prompt`.** Don't inject conversation history via system prompt for `PromptStrategy.append`; inject as `<conversation_history>` XML in the user message on cold-process turns only.
- **`_buildClaudeArgs()` is process-level, not per-turn.** Claude reuse is safe only for the exact logical session and compatible spawn fingerprint; a changed process-level input requires restart rather than reuse.
- **Claude resume and persistence are one interlock.** `--resume <id>` and a request to mint a resumable id must both omit `--no-session-persistence`; an id reported while that flag is present is not safe to persist.
- **Container mode: skip host probes.** No `claude --version` / auth probes from inside the container.
- **Direct Claude setting sources default to inherited user scope.** Omit `--setting-sources` unless `providers.claude.inherit_user_settings: false`; workflow skill preflight must use the same policy as execution or `andthen:*` skills disappear before dispatch.
- **One-shot `--output-format json` buffers until turn end and starves stall monitors.** Use `--output-format stream-json --verbose --include-partial-messages`; parse the terminal `type: "result"` event – tokens nest under `usage.*`. Codex `exec --json` already streams JSONL.
- **`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` failures land on stdout, not stderr.** The scrub forces permission mode to default and prints a benign stderr notice, while the real failure (e.g. a 401) goes to stdout – surface stdout first on nonzero exit. It strips env-borne secrets only; keychain OAuth never flows through env.
- **Standalone `claude` reads keychain OAuth only when `USER` is in the spawn env.** `HOME`+`PATH` alone → "not logged in". The provider spawn sanitize deliberately keeps `USER` – never add an allowlist that drops it. Logged-out CLIs abort via `ProviderAuthPreflight` before skill introspection.
- **Standalone harness startup is deferred behind the auth preflight.** CLI wiring splits into `wirePreHarness()` (no spawn) and `startHarnesses(providers)`; run/resume/retry derive the referenced-provider set, preflight it, then start only those. The executor-level preflight stays as the in-engine backstop for connected mode.
- **A skill the harness activates by slash line must not declare `user-invocable: false`.** Claude Code 2.1.x refuses the `/skill` form for such skills and the step answers with no tool calls; `disable-model-invocation: true` keeps a host-invoked skill out of the menu while the slash form still works.
- **Claude ends a headless turn's `result` while backgrounded subagents still run, then runs a notification turn by itself.** Under 2.1.x `Agent` backgrounds by default and no flag, setting or env var disables it; a process restart in between (the finalizer's `--json-schema`, a session switch) kills the children. `ClaudeCodeHarness` holds a successful turn while a non-`local_bash` task is listed (`control-protocol.md` § 4.8), bounded by the turn timeout.

### Codex
- **Write `CODEX_HOME/config.toml` before spawning.** Later edits are unreliable as a control surface; see the `developerInstructions` entry for what the file does *not* govern.
- **`thread/start` `developerInstructions` overrides `config.toml`.** The config is re-read per thread start and the request value wins (`codex-rs/core/src/config/mod.rs`, rust-v0.146.0). `CodexHarness` passes the composed system prompt on every `thread/start`, so workers sharing one dedicated `CODEX_HOME` do *not* race on the file.
- **Crash recovery must clear cached `_threadIds`.** DartClaw-owned NDJSON replay remains the default after process exit; an explicit durable provider-session id is reloaded with `thread/resume` rather than trusted from the cleared cache.
- **Codex resume is only as durable as `CODEX_HOME`.** System and dedicated homes preserve rollout files across workers; isolated-seeded and container auth-clean homes do not advertise provider-session resume.
- **`thread/start` returns a `thread_id` that must be reused** on every subsequent `turn/start`, or you silently start an orphan thread.
- **Per-turn model override needs `harnessConfig.model` fallback.** Otherwise the configured default model is silently ignored.
- **No cost reporting.** `supportsCostReporting` is `false`. Budget enforcement must use tokens.
- **Anthropic and Codex disagree on `input_tokens` semantics.** Claude reports fresh input directly; Codex reports cache-inclusive input, so normalize at the harness/workflow boundary before persisting or comparing usage.
- **Strict structured output requires every nested object fully closed.** `additionalProperties: false` and `required` covering every property. Nullable optionals → required keys whose schema allows `null`.
- **App-server hangs on tool-use turns when approval is required.** Upstream [codex#11816](https://github.com/openai/codex/issues/11816): `exec_approval.rs` awaits client approval with no timeout. Workaround: `approval: never` + `sandbox: danger-full-access`; a short `governance.turn_limits.turn_timeout` limits blast radius.
- **App-server tests must drive handshake responses while `start()` is in flight.** `start()` blocks on `initialize → initialized → thread/start`; awaiting `start()` before emitting responses deadlocks.
- **Approval-path sanitization is local containment only**, not transport mutation. Don't try to rewrite `tool_input` before the provider sees it.
- **Exec-mode shutdown must not await a pending `Process.start`.** One-shot harness `stop()` must complete the turn completer immediately and defer cleanup until spawn settles.
- **One-shot codex spawns without `--model` inherit the operator's `~/.codex/config.toml`.** A user-level model override there can break every live run. Live codex spawn paths must pin `--model` or run under a controlled `CODEX_HOME`; `workflow-live/run.sh` exports a hermetic, model-pinned one.
- **A stored Codex subscription runs in a DartClaw-generated home, not `~/.codex`.** Anything expected there – plugins, skills, MCP stanzas – must be mirrored in by DartClaw (`completeDedicatedCodexHome`), never assumed; the symptom was `Missing skills for provider codex: andthen:*` at workflow preflight.

### Structured Output
- **Enforcement and readback are separate questions; a harness may only declare support when it can prove the second.** `supportsStructuredOutput` defaults to `false`; a schema handed to a harness that answers `false` is refused by name before any provider work.
- **Claude's `--json-schema` is a spawn flag, so a schema change is a process restart** – and so is *dropping* it. Every restart re-injects the bounded `<conversation_history>` replay; batch schema-bearing turns together.
- **Codex enforces the schema server-side but gives no way to read the result back.** `output_schema` reaches the Responses API as a strict `json_schema` format, yet `TurnCompletedNotification` / `AgentMessage` carry no validated field, so `CodexHarness` declares `false` and a `format: json` step on Codex refuses at `TaskExecutor`'s capability gate; client-side parsing stays barred by ADR-031. Reopening needs a typed result on the app-server turn.
- **The wire spelling is `outputSchema`, the Rust field is `output_schema`.** `TurnStartParams` is `rename_all = "camelCase"`; assert the camelCase form on the wire – a test asserting snake_case passes against a request the app server ignores.

### Turn Routing
- **Provider-routed sessions need turn-reservation bookkeeping in `TurnManager`.** When provider selection happens at reserve time, all of `executeTurn` / `waitForOutcome` / `releaseTurn` must hit the same runner.
- **Append-mode prompt exceptions follow conversational scope.** Onboarding may opt into a full static prompt for Web UI/channels; automation, logical-agent, and evaluator turns stay excluded.
- **Claude PreToolUse must remain unfiltered.** Omitted matcher/if covers built-ins and dynamic MCP tools; a static name list silently bypasses host guards.
- **Claude discovery is not capability grant.** Let exact `ToolSearch` load schemas under a closed allowlist; separately evaluate every selected tool, and keep toolless policies closed.
- **Continuity is a per-harness fact; the runner cannot infer it from busyness.** A Claude process holds one conversation, a Codex process keeps a `_threads` entry per session served, ACP opens a session per turn – so a continuity reset for session B while A runs must reach the harness, and each harness answers for its own process.
- **One turn per worker, not per session.** Admission keys on sessionId and `reserveAdmittedTurn` skips it, so parallel steps can double-drive one `TurnRunner`; `BusyTurnException` only backstops.

## HTMX / SSE

- **`hx-swap="outerHTML"` required with `hx-select`.** Default `innerHTML` nests the extracted element → duplicate IDs.
- **Every page needs `id="main-content"` + `hx-history-elt`.** Missing target → silent fallback to full-page nav.
- **SSE `error` event triggers `onerror`, never named-event handlers.** Rename to e.g. `turn_error` for HTMX `sse-swap`.
- **`hx-swap="none"` doesn't insert HTML into DOM.** Use a hidden swap target with `innerHTML` instead.
- **HTMX-replaced containers lose direct event listeners.** Use document-level event delegation.
- **Chat form success does not always mean SSE starts.** Composer controllers must reset on successful non-streaming form responses instead of waiting for `htmx:sseClose`.

## Trellis Templates

- **`tl:if="${x > 0}"` fails smoke render when var is null.** Smoke render passes null for all variables. Pre-compute booleans in context builders.
- **Use `tl:attr="data-foo=${val}"` for data attributes.** Raw `data-foo="${val}"` skips Trellis escaping → attribute injection.

## Config / YAML

- **`yaml_edit.update()` doesn't auto-create intermediate maps.** Throws `ArgumentError` on missing keys. Catch, create empty maps for missing segments, retry.
- **Empty YAML document root is null, not an empty map.** Initialize with `editor.update([], {})` before path creation works.
- **JSON decoders emit doubles for whole-number values.** Distinguish `3000.0` (accept) from `3000.5` (reject) via `value != value.toInt().toDouble()`.
- **A new `ConfigMeta` field drifts a third artifact.** Beside schema and reference, rerun `packages/dartclaw/test/config_advisory_baseline_test.dart` with `DARTCLAW_UPDATE_CONFIG_ADVISORY_GOLDEN=1`.
- **`ConfigNotifier` emits section-level keys (`security.*`), not sub-keys (`guards.*`).** `Reconfigurable.watchKeys` must use the section-level key or watches silently never fire.

## Concurrency / Async

- **Serialize fire-and-forget writes via a `_pendingWrite` future chain.** `_pendingWrite = _pendingWrite.then((_) => _doWrite())` keeps callers non-blocking; independent `unawaited()` calls race.
- **Concurrent HTTP + channel reviews need atomic state checks.** Two simultaneous accepts can otherwise both pass the status check.
- **Lazy first-use initialization races.** Flip state to `busy` *before* the async initialization await, or overlapping first calls both see `idle` and race past the single-use contract.

## Security

- **MCP `ToolResult.error` is application-level, not JSON-RPC.** Spec requires success response with `isError: true` in content, not protocol-level `-32000`.
- **Suppress binary's built-in tools when providing MCP equivalents.** Add tool names to `disallowedTools` in `HarnessConfig`.
- **`includeParentEnvironment: false` is load-bearing with an explicit `environment:` map.** `Process.start` otherwise re-inherits the parent env past the sanitized overlay; spawn via `SafeProcess`.
- **Sanitize git subprocess env, not just the binary.** `.git/config` can route through `core.sshCommand`, hooks, filters, and credential helpers that spawn shell children.
- **Collapse whitespace where a one-line report is assembled, not per text source.** A provider error, filename, or OS string the pipeline never authored can otherwise forge a report line.

## Package Architecture

- **Equal timeout defaults are a tie, not a fix.** Delete duplicate budgets; aligned values still leave two enforcement owners and race-dependent outcomes.
- **Provider factories must normalize provider-specific executable defaults.** `HarnessFactoryConfig.executable` can only represent one default; each provider factory must substitute its own binary when not overridden.
- **Multi-provider UI/view-model code must derive the provider from `config.agent.provider`.** Hardcoded `'claude'` mislabels non-Claude deployments before usage data exists.
- **Harness capability differences belong on the base `AgentHarness` contract.** Expose via capability getters; consumers branch on flags. Unsupported telemetry → omission/null, never fake zero or provider-name conditionals.
- **Auto-accept callbacks must translate non-success `ReviewResult`s into thrown errors.** `TaskReviewService.review()` reports merge conflicts as typed results, not exceptions; `Future<void>` callbacks otherwise lose the warning path.
- **Green tests can mask unwired features.** Direct-call tests don't prove a service is registered in DartclawRuntime/ScheduleService – verify wiring via integration test + grep for non-test refs.
- **`ScheduleService`'s job list is not user-prompt-jobs-only.** CLI wiring back-registers task definitions as `auto-task-<id>` callback jobs, and system jobs are `onExecute`-based too – new consumers must decide explicitly how to treat `onExecute != null` entries.
- **Resolved step config has multiple consumers.** New inherited step fields must flow through dispatch, follow-up prompts, extraction, and resolved-YAML export.
- **Pub workspace build hooks honor the workspace ROOT pubspec's `hooks.user_defines`, not member pubspecs.** A root-level override wins; any per-platform override must neutralize the root block too.
- **Share the verdict object, not its message.** `resolveFamily` aliases unknown providers onto `claude`/`codex`; re-deriving availability per surface isn't parity – gate on the configured identity.
- **`CredentialRegistry.resolve()` without `family:` misfires on aliases.** Pass `resolveFamily(providerId, executable:, options:)`, not `ProviderIdentity.family`.

## Channel Integration

### Google Chat
- **Config keys use `google_chat`, not `googlechat`.** Even though `ChannelType.googlechat` omits the underscore. Mismatch → channel wiring silently disappears.
- **Use `argumentText`, not `message.text`.** `message.text` includes the `@mention` prefix.
- **`spaces.members.get` uses bare numeric ID, not the `users/` prefix.** Strip `users/` from sender JIDs before constructing member URLs.
- **`quotedMessageMetadata` and reactions require user OAuth.** `chat.bot` returns 403. When quoting fails with a typing placeholder present, *edit* the placeholder – *deleting* it leaves a permanent tombstone.
- **Quoting unsupported in unthreaded spaces.** Check `spaceType` against `UNTHREADED_MESSAGES` (`DM`, `GROUP_CHAT`) before building the quote.
- **`CARD_CLICKED` payload is flat `Map<String, String>`, not nested JSON.** `invokedFunction` + flat string parameters.
- **Slash commands have two event shapes.** `MESSAGE` with `message.slashCommand` AND `APP_COMMAND` with `appCommandMetadata` – write a compatibility parser.
- **Thread binding endpoints must share the live `ThreadBindingStore` instance.** Per-request reconstruction reads stale file state.

### Workspace Events / Pub/Sub
- **Workspace Events scopes differ from Chat API scopes.** Service account auth needs `chat.app.spaces` + `chat.app.memberships`; `chat.bot` is insufficient, and service-account auth is Developer Preview needing one-time admin approval (user OAuth does not).
- **Workspace Events API must be enabled separately** from Pub/Sub and the Chat API. Missing enablement → `403 SERVICE_DISABLED`.
- **Pub/Sub Publisher and Subscriber are separate grants on different resources.** `chat-api-push@system.gserviceaccount.com` needs Publisher on the topic; your service account needs Subscriber on the subscription.
- **Pub/Sub shutdown must `dispose()`, not just `stop()`.** `stop()` won't abort in-flight HTTP pulls; process shutdown without `dispose()` hits the 5-second timeout.

### Signal
- **Sealed-sender: pairing UUID vs later `sourceNumber`.** Allowlist must handle both forms and self-heal on first dual-form message. UUIDs are mixed-case – lowercase before storage and lookup.

### Session routing
- **A `channel`-surface execution request is re-routed onto the primary's provider and policy.** `ExecutionCoordinator._laneFor` sends `ExecutionSurface.channel` to the primary lane, so a channel session pinned to another provider would silently run as the primary. A pinned channel turn must present the logical-agent surface (`TurnManager._reserveExecutionForSession`), keeping `wait` admission.

## Workflow Engine

- **Strict task-spawn dependencies need a lifecycle-only construction path.** `WorkflowService`'s default constructor requires task-persistence ports; tests that only exercise pause/resume/cancel/list use the explicit lifecycle-only constructor, not fabricated ports.
- **Validator file splits must preserve diagnostic ordering.** `workflow validate` output order is observable; rule-group moves need the original call sequence in the composer or golden coverage for ordering.
- **Multi-flag idempotency persists are crash-windows.** Two booleans persisted in sequence reopen the work if a crash lands between them; use a single atomically-persisted phase-string field.
- **Shared worktree caches need both persisted bindings and per-key mutexes.** In-memory map alone fails on retry/restart; same-key fanout needs a `finally`-released waiter/completer guard.
- **Every `format: path` output resolves under one rule, and the worktree diff is not part of it.** `resolveFileSystemOutput` probes an existing claim against the roots in order (step artifacts dir, worktree, runtime-artifacts, project data), else captures from the step artifacts dir by the output's own pattern. Contract-locked in `built_in_workflow_contracts_test.dart`.
- **Merge inside the integration worktree when the integration branch is checked out there.** Reusing the main checkout fails with `branch is already used by worktree`.
- **e2e artifact capture must snapshot the *terminal* task config**, not the queued snapshot, or completion-time writes are hidden.
- **Workflow agent steps should omit `type:` or use `type: agent`.** Removed authoring values (`custom`, `coding`, `research`, …) fail validation; read-only behavior belongs in `allowedTools`.
- **Loop exit gates only see exact context keys – step outputs are NOT auto-namespaced.** A gate like `re-validate.findings_count == 0` requires the step to emit that dotted alias explicitly.
- **Broad `stepDefaults` glob patterns silently drift after step renames.** Re-validate the defaults layer whenever step IDs change.
- **Loop crash recovery needs a checkpoint after every successful sibling step.** Checkpointing only at iteration boundaries loses outputs the next sibling depends on.
- **Workflow start must preflight and persist effective `PROJECT`/`BRANCH` before any workflow task is created**, and local-path projects need their dirty-tree / branch-mismatch gate at the same seam. Deferring either leaks tasks against a live checkout.
- **Resolve a null `gitStrategy` as the default `auto` before keying behavior on the mode.** All resolution flows through `step_config_policy.resolveWorktreeMode`; the concurrency clamp keys on the *resolved* mode so clamp and dispatcher agree – fix at the resolution layer, never a clamp special-case.
- **A foreach dependency-hold pause has no resume path.** After a settled-failed story blocks a dependent, `workflow resume` re-pauses immediately – cancel and start a fresh run; discovery re-derives only unfinished stories.
- **Workflow git cleanup must run after child-task shutdown and walk the full run-owned set.** Shared-key cleanup is insufficient for `per-map-item` workflows; standalone teardown must preserve non-terminal (approval-held, paused, running) git state for resume.
- **Artifact auto-commit must verify task worktree paths are real git worktrees, and use output resolver semantics, not raw output formats.** List-shaped filesystem outputs can be `lines` yet still be load-bearing artifacts.
- **Dependency-aware fan-out is explicit, not inferred from object shape.** The scheduler engages only when items declare `dependencies`; root records still need `dependencies: []`.
- **Resume `story_specs` prune deps by completion status, not absence.** `validateStorySpecsContract(completedStoryIds:)` drops a dep only when it names a `done`/`skipped` story; other absences stay so typos and incomplete prereqs are still rejected.
- **Promotion-conflict retries need the iteration cursor preserved on failure.** Clearing `executionCursor` after a blocked promotion makes downstream items permanently undispatchable.
- **Every task-completion listener shares the same async-listener / SQLite-teardown race.** Each needs the synchronous-listener pattern: filter `failed + retry-in-progress` and `queued|running` re-emissions, then fire-and-forget `_taskService.get` for terminal events. Fixing one dispatcher and not its siblings leaves the others ticking.
- **A `mapOver` step without per-item steps is no longer executable.** `foreach` is the only iteration controller since 0.25; tests must use `type: foreach` + `foreachSteps: [...]`.
- **Schema validator strictness is signaling, not enforcement.** `additionalProperties: false`, `enum`, `minimum`, `maximum` are warnings under the soft-validate contract.
- **`workflow_definition_parser._parseGitStrategy` is the real wiring gate for `gitStrategy:` extensions.** A new typed sub-block without parser threading is silently dropped from YAML-sourced workflows while validator unit tests stay green.
- **Workflow validators that compare provider roles need runtime role defaults.** Alias equality (`@executor` vs a concrete provider) is only meaningful after resolving through `WorkflowRoleDefaults`; CLI validation and server wiring must use the same defaults.
- **Use task-level `maxRetries` for harness crashes, not `onFailure: retry` for story steps.** `onFailure: retry` also retries explicit failed `<step-outcome>` results, re-entering a worktree that holds the prior semantic failure's partial diff.
- **Post-step artifact validation must follow the producing task worktree.** Prefer `task.worktreeJson.path`; active root only as the no-worktree fallback.
- **Live workflow step-isolation tests must cancel provider turns before deleting sessions**, or a still-returning Codex subprocess races the disposed storage.
- **`gating_findings_count` counts findings at or above `defaultGatingSeverity` (`high`), not fix-character.** The threshold reaches the model through the `schema_presets.dart` prompt fragment alone; the emitted integer is the count, a loop entry/exit measure, never a terminal gate.
- **When replacing a bespoke validator with a generic one, prove EVERY axis it enforced – containment, existence, AND argument-safety – for every output shape.** ADR-041 silently dropped argument-safety on the bare `spec_path` while tests stayed green; and un-gating means removing EVERY fail-closed layer keyed on the same precondition, not just the dispatch gate.
- **A workflow step's finalizer turn restarts the Claude process, so background work from the work turn dies there unless the harness waits.** The engine owns no wait; `ClaudeCodeHarness` holds the turn until the background-task inventory empties. Probe: the `background-subagent` canary in `workflow-live/run.sh`.
- **A canonical manifest holds only if BOTH write and read sides honor it.** `SkillProvisioner` wrote the DC-native skill cache from the manifest but discovery read it back by wildcard, so stale skills leaked past removals; audit every reader when declaring a source of truth (`dc_native_skill_manifest.dart`).

## Storage / Data Model

- **Durable knowledge graph facts belong in `tasks.db`, not `search.db`.** `search.db` is rebuildable from MEMORY.md; temporal KG facts are authoritative source-linked records.
- **Task persistence is schema-backed, not generic-JSON-backed.** New `Task` fields require schema, migrations, insert/update, hydration – not just `toJson()`/`fromJson()`.
- **Legacy task-table migrations must guard missing columns at every SQL touch point.** Index creation and `INSERT ... SELECT` also need conditional column references, not only the backfill INSERT.
- **Validate untrusted-ingestion payloads before the first durable write, and never treat LLM text as a control boundary.** Order all checks before any sink (else retries re-run committed writes); parse structured output from a delimiter-safe channel.
- **Parse-then-rewrite makes a lenient parser destructive.** The parse result is written back, so unknown shapes are deleted, not ignored; unparseable must refuse. `_readPage`: CRLF, flow YAML.
- **A write that becomes read-modify-write needs `secureWriteFile`.** Truncating `writeAsString` turns any interruption into total loss. `storage/atomic_write.dart:13`.
- **A reachability category must count inbound links, not the page's own.** Wiki `orphan` read each page's outbound links, so a leaf-only corpus flagged every page.
- **A markdown link regex must split `#fragment`/`?query` off the path.** `](page.md#section)` never matched `\]\(([^)]+\.md)\)`: target never link-checked, page counted linkless.
- **Fingerprint the corpus replacement at the current revision, bump only on commit.** `MEMORY.md` carries its revision in its bytes, so a post-bump identity guard never fires.

## Container / Deployment

- **Docker `exec` needs parent PATH preserved.** Otherwise host can't resolve the `docker` binary.
- **Local-path projects need explicit per-project `/projects/<id>` mounts** even when the clones root is mounted. The legacy `/projects:ro` root only covers data-dir clones.
- **Hardening env vars need dual injection paths.** Direct spawns inherit `HarnessFactoryConfig.environment`; containerized runs only see vars passed to `ContainerManager.exec(env:)`. Apply in both.
- **GitHub release assets need a separate `latest/download` URL path.** Don't treat `latest` as a normal version segment under `/releases/download/<version>/...`.

## Tooling / Verification

- **Failure injection must hit the claimed transition.** A pre-backup lock does not prove post-backup rollback; fail the second move and assert complete-tree restoration.
- **PowerShell pipeline cardinality is unstable.** Wrap possibly empty pipeline output in `@(...)` before `.Count`; and under `ErrorActionPreference=Stop` use a bounded `Continue` scope around native commands so stderr doesn't bypass `LASTEXITCODE`.
- **Installer activation needs atomic directory renames.** `Move-Item` can partially move a tree; same-volume `[IO.Directory]::Move` preserves rollback.
- **Config guards must parse configuration syntax.** YAML-shaped regex misses flow maps, tags, and quoting; use the real parser for semantic invariants.
- **Credential-free process smoke still needs a startup seam.** Skipping provider turns does not skip harness startup; use a protocol-valid local stub.
- **Scoop root URLs do not interpolate.** Use concrete architecture URLs; `$version` works only under `autoupdate`, and `#{version}` is invalid.
- **Asset resolution must treat explicit source paths as intent.** Profiles pass `--source-dir` to exercise the checkout – embedded assets must never shadow local templates, static files, skills, or workflow definitions.
- **Path-output test stubs must materialize claimed files under the same roots production validation probes** (task worktree, `dataDir/projects/<projectId>`, discovered `project_root`); otherwise stricter path validation correctly coerces outputs to empty.
- **Nested `dart run` subprocesses inside `dart test` can stall on build hooks.** Use `Platform.resolvedExecutable` against the script path, and size the readiness poll for a slow host – the child blocks on the hook cache the parent holds.
- **`HarnessWiring` is the deterministic seam for spawn-time prompt tests.** Wire `StorageWiring` + `SecurityWiring` + `HarnessWiring` directly (`dartclaw_runtime`, `lib/src/runtime/`) with a recording harness factory.
- **Standalone CLI preflight tests must inject an explicit environment snapshot**, and wiring tests need a dummy credential entry for the selected provider – the provider validator runs before the fake harness factory is used.
- **Workspace-root sqlite validation owns native-asset regeneration.** Adding `sqlite3` only at package scope leaves the root `.dart_tool/native_assets.yaml` stale and breaks package-wide test runs.
- **Testing-profile smoke runs must bypass stale CLI snapshots after schema changes.** `dev/testing/profiles/*/run.sh` prefers cached `.dart_tool/pub/bin` snapshots; rebuild after storage migrations.
- **Prove env-export fidelity with a micro-canary, not a full live run.** One live provider turn whose prompt runs `mkdir -p "$VAR"` covers the only unit-untestable link: provider-CLI → shell-tool env inheritance + expansion.
- **Green unit suites hide wiring gaps.** Tests injecting absolute paths/null deps prove units, not the product. Require ≥1 test driving the real composition root + path discovery.
- **A bare `exit(...)` in a `Process` fake kills the test runner while `dart test` reports success.** Unqualified `exit(0)` binds to `dart:io`'s top-level; call `this.exit(...)` and treat a dropping test count as a failure.
- **`dart test` runs suites as isolates in ONE process – `Directory.current` is shared.** A suite that assigns it moves the cwd under every concurrent suite; inject the working directory instead (`WorktreeManager(currentDirectory:)`). `apps/dartclaw_cli` still carries this hazard.
- **Tests must never spawn `dart run <workspace script>`.** Concurrent suites racing the shared `.dart_tool/native_assets.yaml` abort the VM; run dependency-free tools from a hermetic temp copy instead.
- **Package-scoped `dart analyze`/`dart test` can stay green while the workspace fails to build.** Removing a barrel export or retyping a cross-package contract breaks consumers the scoped gate never sees – always run workspace-wide analyze + all-package tests.
- **.dart templates compile into the serve VM; static/.html reload from disk.** Long-running serves render stale .dart output – verify "no consumers" sweeps against source; test edits on a fresh port.
- **A dangling symlink does not shadow a binary on PATH.** PATH skips non-executables, so clean-PATH proofs pass meaninglessly – shim an executable stub exiting 127.
- **Concurrent agents in one checkout share gitignored state.** `build/` collides mid-AOT, `embedded_assets.g.dart` needs `embed_assets.dart` re-run (a stale one fails unrelated tests), package-wide `dart format` hits others' files.
- **A fake-terminal test cannot prove terminal behaviour.** An async `stdin` read passed every unit test and broke `dartclaw auth claude` on a real TTY (`EBADF` in the restoring `finally`, before the token was stored). Verify TTY code on a real pty (Python `pty.openpty` + `TIOCSCTTY`), asserting `stty -g` byte-identical before and after.
- **A verification gate can be structurally incapable of a verdict.** The Claude raw-Bearer wire check sent no `anthropic-version`, so upstream answered `400` before judging the credential; assert the *shape of the request it sends*, not just its verdict classification.
- **Restoring a directory another process recreated nests it.** Moving `~/.codex` aside let the vendor CLI recreate the path; `mv` then moved the real home *inside* the new one. Stage to a fresh path and verify the target is absent before restoring.
- **`regenerate_fitness_baseline.dart` ratifies all accumulated drift, not just yours.** For a rename, hand-edit the path keys.
- **A green live run can be resting on host state.** The host `~/.codex`, an untracked fixture overlay, and the enclosing repo's git config all leak in silently; seed the profile credential store and reset the fixture before trusting a green.
- **A helper writing git config into a directory it did not create must use `git -C <dir>` and check for `.git` there first.** Git otherwise walks up and writes into the enclosing checkout's `.git/config`. Guard: `_requireFixtureRepoRoot` in `workflow_e2e_integration_test.dart`.
- **`release_check.sh` is not CI.** Its gates run on the local host only; the Linux `Container boundary` job and the Windows release matrix exist solely on a pushed branch or tag – 0.25.0 shipped a tag that failed on Windows after it passed.
- **Four things this host silently covers that CI does not.** macOS Docker Desktop remaps uids; the system `libsqlite3` masks a skipped build hook; every dev box has `claude` on PATH; no `pwsh` exists, so no `.ps1` is ever parsed. "Passes locally" is zero evidence for container posture, bundled sqlite, provider-CLI absence, and PowerShell syntax.
- **A `.ps1` string interpolating `$name:` needs `${name}`.** PowerShell reads `$exitCode:` as a drive-qualified variable – with no local parser, the first sight of it is a red tag build.
- **`build_windows_test.ps1` drives the validation helpers against `.bat` stubs, never the real binary.** The FTS5 probe now seeds no corpus at all: `rebuild-index` on an empty workspace is the whole proof, and the canonical dialect stays `dartclaw_core`'s alone.
- **`arch_check`'s package count reads the filesystem on purpose – a red count on a developer host is real.** `git mv` and deletion leave a directory behind when it still holds ignored build output; delete the skeletons (ADR-056).
- **A fitness gate's own remediation string can be asserted by that gate.** `memory_architecture_test.dart` pins its remediation wording; grep a gate for its own message before editing its advisory text.
- **A `workflow_dispatch` dry run of `Release Binaries` proves nothing about publication.** `publish`, `homebrew` and `scoop` are gated on `github.ref_type == 'tag'`; render the formulas and manifests locally against fixture checksum files (`render_homebrew_formula.dart`, `render_scoop_manifest.dart --artifact <name>`).
- **A live fixture must stage the shipped `dartclaw-*` skills itself.** A spawned Claude Code falls back to `~/.claude/skills` when the fixture has none; use `SkillProvisioner` + `WorkspaceSkillLinker` in setup.
- **Precompile Dart-script test doubles that a test spawns.** `dart fake.dart` recompiles per spawn and overruns a 10-second handshake timeout on CI; `dart compile kernel` once in `setUpAll` and spawn the `.dill`.

## Specs / Documentation

- **Multi-restatement spec docs.** When fixing a fact, grep all restatements; verify new claims against code; check the inventory measures the AC's property; diff applied edits vs the finding list.
- **`ops update-fis design-change` only rewrites Intent + Acceptance Scenarios** – it hard-blocks Final-Validation/Structural-Criteria edits; use a direct edit + an `observations` audit block.
- **A checklist item naming a recorder in another story has no owner.** Verify the artifact exists before relying on it; absence is a gate defect.
- **Cross-story deferral can land a seam nowhere.** Chained "story X owns it" deferrals shipped a type whose only `throw` was a fake – grep the producer before done.
- **rg-verify spec deletion lists.** "Zero usage"/"only consumer is X" claims need `rg` proof against shipped assets (workflow YAMLs, templates).
- **A doc-task `Verify` must fail on the pre-change tree.** `rg -q` clauses matched a bare word or spanned two paths – dry-run each `cmd:` Verify for non-zero exit; one path per clause.
- **`schemas/dartclaw.schema.json` is nested; a dotted key path never appears in it.** Match the leaf under its parent block or rely on `--check`.

## CSS

- **Contrast checks must resolve colours via canvas** – `color-mix()` computes to `oklab()`/`color(srgb 0–1)`; regex rgb parsing reads those as near-black and fabricates verdicts.
- **`margin: 0 auto` cancels flex stretch.** The child turns shrink-to-fit, sized by its children's `max-width`. Fix: `width: 100%`.
- **Verify a measure change by the rendered width of NON-prose siblings.** Per-element checks pass while the outcome inverts – a table rendered 605px inside an 866px chat bubble.
- **`ch` units resolve against the element's own font-size.** `72ch` on an h1 is ~864px, not the ~605px body prose gives – put reading measures on the text element.
- **Re-check served CSS with cache bypass after a token edit.** Assets come from a versioned `/static/v<version>/` path, so a concurrent canon change renders stale until a hard reload.
- **Contain entry transforms at the fixed shell.** A translated full-height page creates root overflow; clip `.shell` while descendants own scrolling.

## Testing

- **Bound-asserting tests must enumerate the set** – a test named 'only/every/no other' must assert with unorderedEquals/containsAll, never isNot(contains(...)).
- **Fixtures built by the code under test never exercise its parser.** `writePage`-built fixtures meant `_readPage` never parsed foreign input – four data-loss bugs, suite green. Write raw literals.
- **A fake returning a constant response makes retry tests vacuous.** Vary it per call, or no test can observe non-idempotent post-write effects.
- **A guard test must assert the value the guard suppresses, not the input.** Asserting the prompt job's *prompt* stayed unlogged left the `onExecute` guard unpinned – deleting it passed 49 tests.
- **An ordering test must fail at the step *between* the two writes.** A payload rejected during extraction can't tell "wiki write last" from "wiki write first".
- **A report category no test asserts on can ship inverted for its whole life.** Wiki `orphan` had zero assertions and read the wrong direction of the link graph.
- **`dev/fitness` caps a `*_test.dart` at 1300 lines; the breach shows in the workspace gate only.** Put a new group in a sibling file with its own `setUp`.

## Scheduling

- **A paused one-time job must keep its timer.** Its instant arrives once; cancel the timer and it passes unnoticed, leaving a paused row nothing will run that still holds its id against a re-create.
- **`ScheduleService` resolves a job id by first match, and config jobs precede built-ins.** A colliding `scheduling.jobs` entry starves the built-in; drop it at construction, not only on live apply.
