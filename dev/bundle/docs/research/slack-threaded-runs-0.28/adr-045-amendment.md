# ADR-045 amendment draft: preserve pre-origin workflow runs

## Status

Proposed text for `dev/adrs/045-pluggable-database-backend.md`, selected for the 0.28 plan on 2026-09-19 and owner-confirmed on 2026-09-20 with the proportionality constraint below. Not applied to the public repository. Reconciled with the subsequent 0.27 PostgreSQL-only decision (ADR-060): this changes the closed compatibility gate for PostgreSQL, without restoring SQLite or introducing a migration history.

## Context

The 0.28 run-origin requirement retains existing workflow runs, exposes their origin as `unknown`, and sends no notifications for them. The current schema lacks `workflow_runs.origin_json`. Under the existing compatibility gate, adding it to the required manifest makes prior PostgreSQL stores incompatible. ADR-060 removes SQLite in 0.27. A decoder default cannot help because repositories are never reached.

## Decision

For 0.28, admit **one bounded transition from the released-0.27 authoritative PostgreSQL schema**. Do not add a SQLite path, accumulate prior transitions or permit chained upgrades.

Pin the prior marker and required-object manifest to the actual released 0.27 baseline before implementation. Inspect before writing. Only that matching marker/manifest with `origin_json` absent qualifies. Required-object matching retains the established tolerance for unrelated extra objects/columns; it does not accept a missing or differently typed required object, a malformed marker, or a partially present origin column.

Inside one backend transaction, add nullable `TEXT origin_json` to `workflow_runs`, then establish and validate the release's full current schema identity/marker before repository construction. Existing rows retain SQL NULL and hydrate through the typed run-origin codec as `surface: unknown`. Fresh stores bootstrap directly with the new column; exact current stores are unchanged. Every other old, newer, unmarked, malformed or partial authoritative shape refuses before mutation with backup/reset/recreate guidance. Failure during the admitted transition rolls the whole transition back.

There is no ordered version stream, history table, transition chain, migration runner, generic transformation registry or automatic repair of a partially changed store. Derived-store behavior and ambiguous-outcome handling stay under their existing contracts.

Reuse the existing schema-gate inspection and transaction support for this one column addition. Add no compatibility framework or historical schema catalog. DartClaw remains experimental and breaking changes remain acceptable; retaining these rows satisfies FR4, without promising support for older release upgrades.

## Consequences

Existing runs survive the single supported PostgreSQL release transition without acquiring fabricated channel provenance. The cost is one deliberately bounded schema-gate transition and its PostgreSQL failure tests; unsupported older stores continue to refuse. No earlier SQLite adoption path survives as an upgrade chain.

## Alternatives considered

- **Reset/recreate only:** smaller schema-gate code, but cannot satisfy the explicit requirement to retain pre-origin runs as unknown.
- **Treat missing origin as unknown only in the decoder:** cannot pass startup manifest validation.
- **Store origin inside mutable execution context:** avoids a new column but couples routing authority to a separately mutable value and does not implement the chosen separate-field boundary.
- **Versioned migration runner:** unnecessary for one released baseline and reverses the standing no-runner posture much more broadly.

The floor satisfying the PRD is the single transactional transition; it buys retained legacy rows over the refusal-only floor of the previous decision.

## Implementation notes and compliance

The plan pins the released baseline after the 0.27 squash and uses the existing PostgreSQL schema gate, bootstrap manifest and repository. Test fresh/current/exact-prior/refused shapes, injected DDL rollback, restart after success, NULL-to-unknown decoding, preservation of stored origin on lifecycle UPDATE, and suppression of all notifications for unknown origins. Execute the live PostgreSQL contract runner; a skipped run is not evidence.

This is the sole F4 reversal of a recorded decision: it changes the closed compatibility exception while preserving ADR-045's current-schema ownership and no-versioned-runner stance, ADR-060's sole-engine decision, ADR-054's single authority, and the prototype's bounded scope. Update ADR-045's status note and its existing decision-index row when applying this amendment; no additional storage authority is introduced.

## References

[ADR-045](../../../../dartclaw-public/dev/adrs/045-pluggable-database-backend.md), [PRD FR4](../../specs/0.28/prd.md#fr4-run-origin-and-chat-threaded-run-lifecycle), [F4 comparison](tradeoff-matrix.md#f4-dedicated-origin_json-on-workflow_runs), [recommendation](recommendation.md#f4-immutable-origin-json-value).
