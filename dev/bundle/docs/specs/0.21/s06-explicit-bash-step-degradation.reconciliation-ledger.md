# Reconciliation Ledger

> Durable, greppable record of deliberate spec-vs-code drift. Entries are written by implementation and remediation skills and transitioned by review / remediation. See `reconciliation-ledger.md` for the schema, stable-ID derivation, status lifecycle, and match/recurrence/escalation rules.

## Entries

### dev/bundle/docs/specs/0.21/s06-explicit-bash-step-degradation.md:design-changed:native-windows-bash-descendant-containment-is-deferred
- Status: CLOSED
- Class: design-changed
- Stale targets: dev/bundle/docs/specs/0.21/s06-explicit-bash-step-degradation.md#feature-overview-and-goal, dev/bundle/docs/specs/0.21/s06-explicit-bash-step-degradation.md#acceptance-scenarios
- Source run: andthen-review code 2026-07-14
- Recurrence: 1
- Falsifier: –
- Override reason: –
- Created: 2026-07-14
- Updated: 2026-07-14
- Notes: Native x64 evidence disproved Bash descendant containment; 0.21 retains ADR-049's directly managed root contract.
