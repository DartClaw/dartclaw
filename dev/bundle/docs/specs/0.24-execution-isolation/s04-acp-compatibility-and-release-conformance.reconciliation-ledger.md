# Reconciliation Ledger

> Durable, greppable record of deliberate spec-vs-code drift. Entries are written by implementation and remediation skills and transitioned by review / remediation. See `reconciliation-ledger.md` for the schema, stable-ID derivation, status lifecycle, and match/recurrence/escalation rules.

## Entries

### packages/dartclaw_core/lib/src/harness/provider_execution_compatibility.dart:spec-stale:compatibility-reads-two-registration-fields-not-four
- Status: CLOSED
- Class: spec-stale
- Stale targets: dev/bundle/docs/specs/0.24-execution-isolation/s04-acp-compatibility-and-release-conformance.md#technical-overview, dev/bundle/docs/specs/0.24-execution-isolation/s04-acp-compatibility-and-release-conformance.md#implementation-tasks
- Source run: exec-spec-s04-acp-compatibility-and-release-conformance-2026-08-12T02:30Z-a7f3
- Recurrence: 1
- Falsifier: Searched `provider_execution_compatibility.dart` for every `AcpAgentConfig` field read and confirmed only topology and `containerIsolationRequired` affect the release-wide container requirement.
- Override reason: –
- Created: 2026-08-12
- Updated: 2026-08-13
- Notes: Closed by narrowing the active Architecture Decision and TI01 wording to the two inputs the implementation reads. Verification metadata and container_profile are now explicitly described as separate declarations that cannot grant container support in 0.24.
