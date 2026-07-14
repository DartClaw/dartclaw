# Reconciliation Ledger

> Durable, greppable record of deliberate spec-vs-code drift. Entries are written by implementation and remediation skills and transitioned by review / remediation. See `reconciliation-ledger.md` for the schema, stable-ID derivation, status lifecycle, and match/recurrence/escalation rules.

## Entries

### dev/bundle/docs/specs/0.21/s03-windows-safe-process-lifecycle.md:design-changed:native-windows-owner-proof-is-compositional
- Status: CLOSED
- Class: design-changed
- Stale targets: dev/bundle/docs/specs/0.21/s03-windows-safe-process-lifecycle.md#acceptance-scenarios, dev/bundle/docs/specs/0.21/s03-windows-safe-process-lifecycle.md#implementation-plan
- Source run: andthen-review security 2026-07-14
- Recurrence: 1
- Falsifier: –
- Override reason: –
- Created: 2026-07-14
- Updated: 2026-07-14
- Notes: Acceptance scenario and TI03 now require the same real-root plus native-host owner-suite compositional proof.
