# Project Learnings

<!-- Traps only, one bullet each: `- **{title}** – …` under 200 chars, trap + pointer; postmortem
     depth lives in the spec archive or an ADR. Bar: "Would a competent developer with code and
     git access still get bitten?" Skills read this index whole – keep it lean. Maintain via the
     `andthen:ops` skill (`update-learnings` forms), which owns the 150-line ceiling and
     `learnings/` shard graduation. Delete entries once encoded as checks or stale. -->

## Dart Language

- **Injected paths need matching path context.** Host-default `package:path` joining corrupts Windows fixture paths on POSIX; select `p.windows` for drive or UNC homes.
- **`Future.timeout` cannot interrupt synchronous regex.** Single-threaded event loop. Mitigate via input truncation, not per-pattern timeouts.
- **`Stream` lacks `whereType<T>()`.** Use `.where((e) => e is T).cast<T>()`.
- **`=> {` in `.map()` parses as a set literal, not a block body.** Use `.map((x) { return ...; })`.
- **Zone context lost in `.listen()` callbacks.** Values set with `runZonedGuarded` / `LogContext.runWith()` aren't visible inside async stream callbacks once control returns to the event loop.
- **Class fields can't be null-promoted.** Extract to a `final` local first.
- **Microtask starvation in async loops.** `(_) async {}` and `Future.value()` complete on the microtask queue; a `while` loop awaiting only those monopolizes the event loop, so timer callbacks (`Completer` resolutions, `stop()`, etc.) never fire → multi-GB OOM. Add `await Future<void>.delayed(Duration.zero)` as a yield point in every production async loop.
- **DST-boundary date arithmetic flakes test fixtures.** `Duration(days: N)` subtracted from local-midnight `DateTime`s can roll to the previous calendar day. Use explicit year/month/day construction in date-sensitive fixtures.
- **An arrow-body `Future.then` cleanup callback re-adopts the source future.** `probe.then((_) => _cache.remove(key), onError: (e,_) => _cache.remove(key))` returns the cached future itself; on rejection the continuation adopts that error as an *unhandled* async error. Use statement bodies (`{ _cache.remove(key); }`) so the callbacks return void.

## Agent Harness Protocols

→ learnings/agent-harness-protocols.md – Terminal result maps are outcomes, not success

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
- **Collapse whitespace where a one-line report is assembled, not per text source.** A provider error, filename, or OS string the pipeline never authored can otherwise forge a report line.

## Package Architecture

- **`ConfigNotifier` emits section-level keys (`security.*`), not sub-keys (`guards.*`).** `Reconfigurable.watchKeys` must use the section-level key or watches silently never fire — `ConfigDelta.hasChanged()` prefix-matches against section keys only.
- **Channel config parsers self-register on import.** Bootstrap must call `ensure...Registered()` before `DartclawConfig.load()` or wiring fails with `StateError`.
- **Provider factories must normalize provider-specific executable defaults.** `HarnessFactoryConfig.executable` can only represent one default; each provider factory must substitute its own binary when not overridden.
- **Multi-provider UI/view-model code must derive the provider from `config.agent.provider`.** Hardcoded `'claude'` mislabels non-Claude deployments before usage data exists.
- **Harness capability differences belong on the base `AgentHarness` contract.** Expose via capability getters; consumers branch on flags. Unsupported telemetry → omission/null, never fake zero or provider-name conditionals.
- **Auto-accept callbacks must translate non-success `ReviewResult`s into thrown errors.** `TaskReviewService.review()` reports merge conflicts as typed results, not exceptions; callers wiring `Future<void>` callbacks otherwise lose the warning path.
- **Typedef-vs-class name collisions across packages need `hide` on the import.** e.g. `ReservedCommandHandler` typedef in `dartclaw_core` vs class in `dartclaw_cli`.
- **Green tests can mask unwired features.** Direct-call tests don't prove a service is registered in ServiceWiring/ScheduleService — verify wiring via integration test + grep for non-test refs.
- **`ScheduleService`'s job list is not user-prompt-jobs-only.** CLI wiring back-registers task definitions as `auto-task-<id>` callback jobs (`ScheduledTaskRunner.buildJobs()`), and system jobs are `onExecute`-based too — new consumers must decide explicitly how to treat `onExecute != null` entries.
- **Resolved step config has multiple consumers.** New inherited step fields must flow through dispatch, follow-up prompts, extraction, and resolved-YAML export.
- **Pub workspace build hooks honor the workspace ROOT pubspec's `hooks.user_defines`, not member pubspecs.** A root-level override wins; any per-platform override must neutralize the root block too.
- **Share the verdict object, not its message.** `resolveFamily` aliases unknown providers onto `claude`/`codex`; re-deriving availability per surface isn't parity — gate on the configured identity.

## Channel Integration

→ learnings/channel-integration.md – Config keys use `google_chat`, not `googlechat`

## Workflow Engine

→ learnings/workflow-engine.md – Strict task-spawn dependencies need a lifecycle-only construction path

## Storage / Data Model

- **Durable knowledge graph facts belong in `tasks.db`, not `search.db`.** `search.db` is rebuildable from MEMORY.md and can be deleted/rebuilt; temporal KG facts are authoritative source-linked records and must use the durable task database connection.
- **Task sessions have multi-layer protection from maintenance pruning.** `_isProtected()`, `_pruneStale()` skip, `protectedTypes` set, `deleteSession()` throws, `listSessions()` excludes by default.
- **FTS5 MATCH has special operators.** Wrap user input in double quotes for literal matching.
- **Task persistence is schema-backed, not generic-JSON-backed.** New `Task` fields require schema, migrations, insert/update, hydration — not just `toJson()`/`fromJson()`.
- **Legacy task-table migrations must guard missing columns at every SQL touch point.** Branching only the backfill INSERT is insufficient; index creation and `INSERT ... SELECT` also need conditional column references.
- **Validate untrusted-ingestion payloads before the first durable write, and never treat LLM text as a control boundary.** Order all checks before any sink (else retries re-run committed writes); parse structured output from a delimiter-safe channel, not free text that source-embedded fences can forge.
- **Webhook pending-state TTL must move forward on successful commit.** Reclaiming an old pending row and then marking it processed without refreshing the TTL anchor lets the next purge delete the dedupe marker immediately.
- **Parse-then-rewrite makes a lenient parser destructive.** The parse result is written back, so unknown shapes are deleted, not ignored; unparseable must refuse. `_readPage`: CRLF, flow YAML.
- **A write that becomes read-modify-write needs `secureWriteFile`.** The file is the sole copy; truncating `writeAsString` turns any interruption into total loss. `storage/atomic_write.dart:13`.
- **A reachability category must count inbound links, not the page's own.** Wiki `orphan` read each page's outbound links, so a leaf-only corpus flagged every page every run – no signal.
- **A markdown link regex must split `#fragment`/`?query` off the path.** `](page.md#section)` matched `\]\(([^)]+\.md)\)` not at all: target never link-checked, page counted linkless.

## Container / Deployment

- **Docker `exec` needs parent PATH preserved.** Otherwise host can't resolve the `docker` binary.
- **Local-path projects need explicit per-project `/projects/<id>` mounts** even when the clones root is mounted. The legacy `/projects:ro` root only covers data-dir clones.
- **Hardening env vars need dual injection paths.** Direct spawns inherit `HarnessFactoryConfig.environment`; containerized runs only see vars passed to `ContainerManager.exec(env:)`. Apply in both.
- **GitHub release assets need a separate `latest/download` URL path.** Don't treat `latest` as a normal version segment under `/releases/download/<version>/...`.

## Tooling / Verification

→ learnings/tooling-verification.md – Failure injection must hit the claimed transition

## Specs / Documentation

- **Multi-restatement spec docs.** When fixing a fact, grep all restatements; verify new claims against code; check the inventory measures the AC's property; diff applied edits vs the finding list.
- **`ops update-fis design-change` only rewrites Intent + Acceptance Scenarios** — it hard-blocks Final-Validation/Structural-Criteria edits; use a direct edit + an `observations` audit block.
- **A checklist item naming a recorder in another story has no owner.** It can go unrun until the final checkbox pass — verify the artifact exists before relying on it; absence is a gate defect.

## CSS

- **Contrast checks must resolve colours via canvas** — `color-mix()` computes to `oklab()`/`color(srgb 0–1)`; regex rgb parsing reads those as near-black and fabricates pass/fail verdicts.
- **`margin: 0 auto` cancels flex stretch.** The child turns shrink-to-fit, sized by its children's `max-width` — a prose measure collapses the container and full-width siblings. Fix: `width: 100%`.
- **Verify a measure change by the rendered width of NON-prose siblings.** Per-element checks pass while the outcome inverts — a table rendered 605px inside an 866px chat bubble.
- **`ch` units resolve against the element's own font-size.** `72ch` on an h1 is ~864px, not the ~605px the same value gives body prose — put reading measures on the text element.
- **Re-check served CSS with cache bypass after a token edit.** Assets come from a versioned `/static/v<version>/` path, so a concurrent canon change renders stale until a hard reload.
- **Contain entry transforms at the fixed shell.** A translated full-height page creates root overflow; clip `.shell` while descendants own scrolling.

## Testing

- **Bound-asserting tests must enumerate the set** – a test named 'only/every/no other' must assert with unorderedEquals/containsAll, never isNot(contains(...)); recurred in both 0.24 gap reviews.
- **Fixtures built by the code under test never exercise its parser.** `writePage`-built fixtures meant `_readPage` never parsed foreign input – four data-loss bugs, suite green. Write raw literals.
- **A fake returning a constant response makes retry tests vacuous.** The retry is byte-identical by construction, so no test can observe non-idempotent post-write effects; vary it per call.
- **A guard test must assert the value the guard suppresses, not the input.** Asserting the prompt job's *prompt* stayed unlogged left the `onExecute` guard unpinned – deleting it passed 49 tests.
- **An ordering test must fail at the step *between* the two writes.** A payload rejected during extraction can't tell "wiki write last" from "wiki write first" – both orderings passed 115 tests.
- **A report category no test asserts on can ship inverted for its whole life.** Wiki `orphan` had zero assertions and read the wrong direction of the link graph.
