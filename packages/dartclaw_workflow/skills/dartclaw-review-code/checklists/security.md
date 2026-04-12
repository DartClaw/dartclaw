# Security Checklist

Use this checklist when the reviewed scope can affect security, secrets, or trust boundaries.

## Identity and Access

- [ ] Authentication is required where the feature touches protected data or privileged actions.
- [ ] Authorization is checked at the point of use, not only at the entry point.
- [ ] Privileged paths are not reachable through alternative routes or defaults.

## Input and Injection

- [ ] User-controlled strings are validated before use in commands, SQL, file paths, URLs, or prompts.
- [ ] Path handling rejects traversal, symlink surprises, and unsafe joins.
- [ ] Shell or subprocess calls do not interpolate untrusted data.
- [ ] Serialization and deserialization do not trust attacker-controlled payloads.

## Secrets and Data Exposure

- [ ] Secrets are not logged, echoed, or stored in low-trust artifacts.
- [ ] Sensitive values are redacted before persistence or telemetry.
- [ ] Responses and reports do not expose private workspace content unnecessarily.

## LLM and Agentic Risk

- [ ] Prompt instructions do not grant broader authority than the task requires.
- [ ] Tool approval and file-write boundaries are respected.
- [ ] Retrieved context cannot silently override the user's intent.

## Integrity and Supply Chain

- [ ] Dependency, asset, and script trust boundaries are clear.
- [ ] Generated or copied artifacts are provenance-aware.
- [ ] Configuration changes do not broaden attack surface without justification.

