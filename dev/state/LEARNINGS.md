# Project Learnings

<!-- Traps only, one bullet each: `- **{title}** – …` under 200 chars, trap + pointer; postmortem
     depth lives in the spec archive or an ADR. Bar: "Would a competent developer with code and
     git access still get bitten?" Skills read this index whole – keep it lean. Maintain via the
     `andthen:ops` skill (`update-learnings`, no `--ceiling` – an append must never be refused
     for want of room; an already-sharded topic is edited in its `learnings/` file by hand).
     Over 200 lines, prune or graduate a topic to a shard as its own change. Delete entries once
     encoded as checks or stale. -->

## Dart Language

- **Injected paths need matching path context.** Host-default `package:path` joining corrupts Windows fixture paths on POSIX; select `p.windows` for drive or UNC homes.
- **`Future.timeout` cannot interrupt synchronous regex.** Single-threaded event loop. Mitigate via input truncation, not per-pattern timeouts.
- **`Stream` lacks `whereType<T>()`.** Use `.where((e) => e is T).cast<T>()`.
- **`=> {` in `.map()` parses as a set literal, not a block body.** Use `.map((x) { return ...; })`.
- **Zone context lost in `.listen()` callbacks.** Values set with `runZonedGuarded` / `LogContext.runWith()` aren't visible inside async stream callbacks once control returns to the event loop.
- **Microtask starvation in async loops.** A loop awaiting only microtask futures never lets timers fire (`stop()`, `Completer`s) → OOM. Yield via `await Future<void>.delayed(Duration.zero)`.
- **DST-boundary date arithmetic flakes test fixtures.** `Duration(days: N)` from a local-midnight `DateTime` can land on the previous day; build date fixtures from explicit year/month/day.
- **An arrow-body `Future.then` cleanup callback re-adopts the source future.** `.then((_) => _cache.remove(key))` returns the cached future; its rejection goes unhandled. Use `{ … }` bodies.

## Agent Harness Protocols

→ learnings/agent-harness-protocols.md – Terminal result maps are outcomes, not success; a provider may enforce a schema it gives you no way to read back

## HTMX / SSE

- **`hx-swap="outerHTML"` required with `hx-select`.** Default `innerHTML` nests the extracted element → duplicate IDs.
- **Every page needs `id="main-content"` + `hx-history-elt`.** Missing target → silent fallback to full-page nav.
- **`HX-Location` header for POST actions, not 302 redirects.** Avoids double GET.
- **`Vary: HX-Request` header on all web responses.** Required for browser/CDN caching correctness.
- **SSE `error` event triggers `onerror`, never named-event handlers.** Rename to e.g. `turn_error` for HTMX `sse-swap`.
- **`hx-swap="none"` doesn't insert HTML into DOM.** Use a hidden swap target with `innerHTML` instead.
- **HTMX-replaced containers lose direct event listeners.** Use document-level event delegation.
- **Chat form success does not always mean SSE starts.** Composer controllers must reset on successful non-streaming form responses instead of waiting for `htmx:sseClose`.

## Trellis Templates

- **`tl:if="${x > 0}"` fails smoke render when var is null.** Smoke render passes null for all variables. Pre-compute booleans in context builders.
- **Use `tl:attr="data-foo=${val}"` for data attributes.** Raw `data-foo="${val}"` skips Trellis escaping → attribute injection.
- **Trellis truthiness follows JS-like rules.** Complex conditions are safer as pre-computed Dart booleans.

## Config / YAML

- **`yaml_edit.update()` doesn't auto-create intermediate maps.** Throws `ArgumentError` on missing keys. Catch, create empty maps for missing segments, retry.
- **Empty YAML document root is null, not an empty map.** Initialize with `editor.update([], {})` before path creation works.
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
- **`includeParentEnvironment: false` is load-bearing with an explicit `environment:` map.** `Process.start` otherwise re-inherits the parent env past the sanitized overlay; spawn via `SafeProcess`.
- **Sanitize git subprocess env, not just the binary.** `.git/config` can route through `core.sshCommand`, hooks, filters, and credential helpers that spawn shell children.
- **Collapse whitespace where a one-line report is assembled, not per text source.** A provider error, filename, or OS string the pipeline never authored can otherwise forge a report line.

## Package Architecture

→ learnings/package-architecture.md – Equal timeout defaults are a tie, not a fix

## Channel Integration

→ learnings/channel-integration.md – Config keys use `google_chat`, not `googlechat`

## Workflow Engine

→ learnings/workflow-engine.md – Strict task-spawn dependencies need a lifecycle-only construction path

## Storage / Data Model

→ learnings/storage-data-model.md – Durable knowledge graph facts belong in `tasks.db`, not `search.db`

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
- **Cross-story deferral can land a seam nowhere.** Chained "story X owns it" deferrals shipped a type declared, exported and caught whose only `throw` was a fake – grep the producer before done.
- **Re-derive a recorded blocker against the current transport.** TD-122's "not a wiring change" held only for the output-only spawn; on a leased `TurnRunner` the guard hook points were reachable.
- **rg-verify spec deletion lists.** "Zero usage"/"only consumer is X" claims need `rg` proof against shipped assets (workflow YAMLs, templates) – 0.25 PRD review F1/F6: two false dead claims.
- **A doc-task `Verify` must fail on the pre-change tree.** `rg -q` clauses matched a bare word or spanned two paths – dry-run each `cmd:` Verify for non-zero exit; one path per clause.

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
- **`dev/fitness` caps a `*_test.dart` at 1300 lines; the breach shows in the workspace gate only.** Put a new group in a sibling file with its own `setUp`.

## Scheduling

- **A paused one-time job must keep its timer.** Its instant arrives once; cancel the timer and it passes unnoticed, leaving a paused row nothing will run that still holds its id against a re-create.
- **`ScheduleService` resolves a job id by first match, and config jobs precede built-ins.** A colliding `scheduling.jobs` entry starves the built-in; drop it at construction, not only on live apply.

