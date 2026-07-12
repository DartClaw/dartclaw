# Reconciliation Ledger

> Durable, greppable record of deliberate spec-vs-code drift. Entries are written by implementation and remediation skills and transitioned by review / remediation. See `reconciliation-ledger.md` for the schema, stable-ID derivation, status lifecycle, and match/recurrence/escalation rules.

## Entries

### package/scoop/dartclaw.json:spec-stale:valid-scoop-version-substitution
- Status: OPEN
- Class: spec-stale
- Stale targets: dev/bundle/docs/specs/0.21/s08-windows-installer-scoop-manifest.md#acceptance-scenarios, dev/bundle/docs/specs/0.21/s08-windows-installer-scoop-manifest.md#structural-criteria, dev/bundle/docs/specs/0.21/s08-windows-installer-scoop-manifest.md#implementation-plan
- Source run: exec-spec S08 2026-07-11
- Recurrence: 1
- Falsifier: –
- Override reason: –
- Created: 2026-07-11
- Updated: 2026-07-11
- Notes: Scoop root URLs require a concrete version; `$version` is supported only under `autoupdate`, and `#{version}` is invalid.
