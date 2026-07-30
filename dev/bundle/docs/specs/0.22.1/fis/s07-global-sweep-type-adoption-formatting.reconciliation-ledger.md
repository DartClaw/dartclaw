# Reconciliation Ledger

> Durable, greppable record of deliberate spec-vs-code drift. Entries are written by implementation and remediation skills and transitioned by review / remediation. See `reconciliation-ledger.md` for the schema, stable-ID derivation, status lifecycle, and match/recurrence/escalation rules.

## Entries

### S07-AA-BADGE-TOKENS
- Status: CLOSED
- Class: spec-stale
- Stale targets: S07 FIS Acceptance Scenario S02 (both-themes badge AA); dev/design-system/tokens.css light-theme --brand-claude/--brand-codex/--teal; plan.json S01 scope
- Source run: S07 exec-spec run 2026-07-29
- Recurrence: 1
- Falsifier: –
- Override reason: –
- Created: 2026-07-29
- Updated: 2026-07-29
- Notes: Reconciled – S01 darkened light-theme --teal to #0d686d and --brand-claude to #954727 this run; cache-bypassed canvas re-measure clears 4.5:1 for every S02 badge in both themes (light 4.59–5.12, dark 4.89–8.71); original OPEN raised off a stale tokens.css cache; no S01 action outstanding.

### S07-FINAL-CHECKLIST-FILE-LIST
- Status: CLOSED
- Class: spec-stale
- Stale targets: S07 FIS Final Validation checklist item 1 and item 2 file lists (public bundle + private canon) contradict TI07/Work Areas which require scheduling/task_detail/knowledge template edits, health_dashboard.dart caller update, and embedded_assets.g.dart regeneration
- Source run: S07 exec-spec run 2026-07-29
- Recurrence: 1
- Falsifier: –
- Override reason: –
- Created: 2026-07-29
- Updated: 2026-07-29
- Notes: Reconciled – Final Validation checklist items 1–2 rewritten to the verified as-built delta in both the public bundle and private canonical FIS copies; both now tick. The checklist enumeration was the stale side: TI07 mandates the .card class additions in the scheduling/task_detail/knowledge templates, TI07's infoCard reshape forces the health_dashboard.dart caller rename (sole caller repo-wide; would not compile otherwise), and a Structural Criterion requires regenerating embedded_assets.g.dart. Exact Old/New spans recorded in the FIS Implementation Observations run blocks 2026-07-29 23:03 UTC (public) / 23:05 UTC (private). Applied as a direct edit plus observations audit rather than `update-fis design-change`, whose writable region is Intent and Acceptance Scenarios only and excludes the Final Validation Checklist.
