# Reconciliation Ledger

> Durable, greppable record of deliberate spec-vs-code drift. Entries are written by implementation and remediation skills and transitioned by review / remediation. See `reconciliation-ledger.md` for the schema, stable-ID derivation, status lifecycle, and match/recurrence/escalation rules.

## Entries

### S11-TI07-VERIFY-SCOPE
- Status: CLOSED
- Class: spec-stale
- Stale targets: dev/bundle/docs/specs/0.22.1/fis/s11-surface-sweep-settings.md TI07 Verify line; dartclaw-private/docs/specs/0.22.1/fis/s11-surface-sweep-settings.md TI07 Verify line
- Source run: S11 exec-spec 2026-07-30
- Notes: TI07's Verify line asserted `rg -n 'icon-triangle-alert' packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` exits 1. Its stated intent is narrower than the command: that the always-on mutability note carries no alert glyph ("neutral helper copy carrying a warning triangle is the same defect in another layer – the icon goes with the blend"). The file-wide grep was written when that note held the only occurrence. TI08, in the same FIS, mandates the persistent-failure recipe from `templates/workflow_detail.html`, whose `banner banner-error` opens with `<span class="icon icon-triangle-alert">`; canon's `.banner-error` supplies no glyph of its own, so dropping it would leave the banner's severity carried by colour plus copy alone. The two tasks' literal requirements are unsatisfiable together. Resolved on the spec side: the Verify line is block-scoped to `updateMutabilitySummaries` in both copies, keeping TI07 falsifiable while TI08 keeps the canon recipe. Intent, Expected Outcomes and Acceptance Scenarios untouched; no code was shaped to fit the assertion. Reconciled 2026-07-30 (spec was the stale side; as-built correct and unchanged): amended Verify line verified green — `awk '/^function updateMutabilitySummaries/,/^}/' packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js | rg -n 'icon-triangle-alert'` exits 1; Old:/New: spans recorded in the first observations run block's `#### FIS AMENDMENT AUDIT`.
- Recurrence: 1
- Falsifier: –
- Override reason: –
- Created: 2026-07-30
- Updated: 2026-07-30
