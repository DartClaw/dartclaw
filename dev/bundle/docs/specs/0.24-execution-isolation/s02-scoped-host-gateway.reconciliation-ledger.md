# Reconciliation Ledger

> Durable, greppable record of deliberate spec-vs-code drift. Entries are written by implementation and remediation skills and transitioned by review / remediation. See `reconciliation-ledger.md` for the schema, stable-ID derivation, status lifecycle, and match/recurrence/escalation rules.

## Entries

### packages/dartclaw_server/lib/src/container/gateway/gateway_pipe.dart:spec-stale:unknown-request-id-frames-ignored-not-revoked
- Status: OPEN
- Class: spec-stale
- Stale targets: dev/bundle/docs/specs/0.24-execution-isolation/s02-scoped-host-gateway.md#technical-overview
- Source run: s02-scoped-host-gateway/2026-08-11T21:19Z
- Recurrence: 1
- Falsifier: –
- Override reason: –
- Created: 2026-08-11
- Updated: 2026-08-11
- Notes: FIS Technical Overview says unknown request IDs "fail all matching requests and revoke the pipe"; implementation deliberately ignores frames for unknown IDs because revoking would break the legitimate cancel-vs-completion race. Code is correct; the FIS sentence is over-broad. Documentation decision owned by the release-conformance story (S04).
