# Requirements Clarification: 0.22.1 Preflight Decisions

> **Scope**: Focused preflight clarification of five user-visible contracts left open by the 0.22.1 FIS bundle. All five recommended options were ratified on 2026-07-26 and folded into the affected FIS.

## Resolved Decisions

| Decision key | Decision | Rationale | Affected FIS |
|---|---|---|---|
| `heartbeat-presentation` | Render heartbeat status once. When enabled, show the interval as a numeral plus `MIN`; when disabled, omit the interval. | Keeps status and quantitative information distinct without presenting words or absence as metrics. | S08 |
| `memory-budget-cue` | Keep the percentage and add visible `Near limit` text at 80–100% and `Over limit` above 100%. | Meets the non-colour accessibility contract with explicit, readable state. | S09 |
| `error-page-shell-policy` | Shell-wrap the `/no-such-page` Cascade fallback with nav-only data. Keep `_htmlNotFound` and `_htmlError` on the bare fallback unless a caller already has shell data. | Satisfies the bad-URL scenario without threading new state through unrelated error paths. | S12 |
| `page-header-semantics` | `pageHeader` has an optional `<h2 class="t-page-title">`; omit it when the title is empty while retaining subtitle and actions. The topbar remains the sole page `<h1>`. | Preserves heading hierarchy and supports subtitle-only page heads without empty or duplicate titles. | S16 |
| `absolute-timestamp-contract` | Use relative time through 30 elapsed days. From day 31, render in server-local time as `d MMM` when the date is in the current local calendar year and `d MMM yyyy` otherwise; retain the source ISO value in `title`. | Defines the rollover, year rule and timezone basis consistently across all consumers. | S16 |

## Open Questions

None at requirements altitude.

## Decisions Log

| Decision | Rationale | Date |
|---|---|---|
| Ratified all five preflight requirements recommendations | Closes observable-behaviour ambiguities before unattended execution | 2026-07-26 |
