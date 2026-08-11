# Reconciliation Ledger

> Durable, greppable record of deliberate spec-vs-code drift. Entries are written by implementation and remediation skills and transitioned by review / remediation. See `reconciliation-ledger.md` for the schema, stable-ID derivation, status lifecycle, and match/recurrence/escalation rules.

## Entries

### packages/dartclaw_core/lib/src/harness/claude_protocol.dart:spec-stale:container-claude-placeholder-api-key
- Status: OPEN
- Class: spec-stale
- Stale targets: dev/bundle/docs/specs/0.24-execution-isolation/prd.md#fr3-host-owned-provider-credentials, dev/bundle/docs/specs/0.24-execution-isolation/s03-claude-and-codex-container-parity.md#acceptance-scenarios
- Source run: s03-claude-and-codex-container-parity/2026-08-12T01:34Z
- Recurrence: 1
- Falsifier: A containerized Claude turn that reaches the host adapter with no `ANTHROPIC_API_KEY` present in the container environment.
- Override reason: –
- Created: 2026-08-12
- Updated: 2026-08-12
- Notes: FR3 says containerized Claude "uses host-held `ANTHROPIC_API_KEY` mediation **without receiving the key**", and S02's Then clause says the container environment contains no provider credential. Both are honored — the host key never crosses — but the container environment does now carry an `ANTHROPIC_API_KEY` variable holding the non-secret constant `containerClaudePlaceholderApiKey`. Verified live against claude 2.1.228: with no key present at all the CLI refuses at its own local auth gate (`duration_api_ms: 0`, `result: "Not logged in · Please run /login"`) and never issues a request, so mediation could not happen; with any non-empty value it proceeds to `ANTHROPIC_BASE_URL`. The host adapter drops every client-supplied credential header and injects the real key last, so the placeholder cannot reach a provider. Upstream wording should distinguish "no provider credential" from "no `ANTHROPIC_API_KEY` variable"; reconciliation owned by the release-conformance story (S04).
