# Reconciliation Ledger

> Durable, greppable record of deliberate spec-vs-code drift. Entries are written by implementation and remediation skills and transitioned by review / remediation. See `reconciliation-ledger.md` for the schema, stable-ID derivation, status lifecycle, and match/recurrence/escalation rules.

## Entries

### packages/dartclaw_core/lib/src/harness/provider_execution_compatibility.dart:spec-stale:compatibility-reads-two-registration-fields-not-four
- Status: OPEN
- Class: spec-stale
- Stale targets: dev/bundle/docs/specs/0.24-execution-isolation/s04-acp-compatibility-and-release-conformance.md#technical-overview, dev/bundle/docs/specs/0.24-execution-isolation/s04-acp-compatibility-and-release-conformance.md#implementation-tasks
- Source run: exec-spec-s04-acp-compatibility-and-release-conformance-2026-08-12T02:30Z-a7f3
- Recurrence: 1
- Falsifier: –
- Override reason: –
- Created: 2026-08-12
- Updated: 2026-08-12
- Notes: TI01 and the Technical Overview enumerate four registration fields as compatibility inputs (topology, verification, container_isolation_required, container_profile). The implementation reads only topology and container_isolation_required, because the computed posture makes every ACP container combination unavailable regardless of verification or container_profile — reading them could not change any verdict. The posture is identical; the FIS's field enumeration is broader than the inputs that can affect the result.
