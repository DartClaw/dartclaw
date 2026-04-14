# Security Checklist

Use this checklist when the reviewed scope can affect secrets, trust boundaries, or agentic behavior.

This checklist is adapted from OWASP guidance and tuned for DartClaw's server-hosted workflows, local workspace access, and tool-using harnesses.

## Pre-Review

- [ ] Identify the trust boundaries, privileged actions, and sensitive data flows.
- [ ] Identify which code paths can reach the network, filesystem, shell, or model tools.
- [ ] Check whether the feature changes authentication, authorization, or policy enforcement.
- [ ] Review any threat model, security note, or data classification guidance that already exists.

## OWASP Framing

The review should map findings back to the OWASP category that best explains the failure mode.
For DartClaw, the most relevant categories are access control, injection, misconfiguration, secrets handling, and LLM or agentic risk.

### Access Control

- [ ] Authentication is required for protected data or privileged actions.
- [ ] Authorization is checked at the point of use, not only at the entry point.
- [ ] Default deny is used for privileged resources and routes.
- [ ] Object-level checks prevent IDOR-style access across users, tasks, projects, or sessions.
- [ ] Role, session, and workspace boundaries are enforced consistently.
- [ ] Privileged behavior cannot be reached through an alternate route, default, or fallback.
- [ ] Rate limiting protects sensitive actions from brute force or abuse.

### Injection

- [ ] User-controlled strings are validated before use in commands, SQL, file paths, URLs, prompts, or templates.
- [ ] Shell and subprocess calls do not interpolate untrusted data.
- [ ] SQL and query construction use parameterized or safe APIs.
- [ ] File path handling rejects traversal, symlink surprises, and unsafe joins.
- [ ] URL handling validates destinations and blocks internal or unexpected schemes.
- [ ] Serialization and deserialization do not trust attacker-controlled payloads.
- [ ] Output encoding or escaping matches the rendering context.

### LLM and Agentic Risk

- [ ] Prompt instructions do not grant broader authority than the task requires.
- [ ] Retrieved context is treated as untrusted input unless it is explicitly verified.
- [ ] Model output is not used to build commands, queries, or file edits without strict validation.
- [ ] Tool approval, workspace scope, and write boundaries are respected.
- [ ] System prompts, policies, and hidden context are not leaked into user-visible output.
- [ ] Agent loops have limits so a bad prompt or tool response cannot run forever.
- [ ] The implementation resists prompt injection, tool hijacking, and output re-injection.

### Secrets and Data Exposure

- [ ] Secrets are not logged, echoed, or stored in low-trust artifacts.
- [ ] Sensitive values are redacted before persistence or telemetry.
- [ ] Responses do not expose workspace content, credentials, or private metadata unnecessarily.
- [ ] Error messages avoid revealing internal paths, tokens, or detailed stack traces to low-trust clients.

### Integrity and Supply Chain

- [ ] Dependency, asset, and script trust boundaries are clear.
- [ ] Generated or copied artifacts are provenance-aware.
- [ ] Configuration changes do not broaden the attack surface without justification.
- [ ] External inputs are validated before they influence execution or policy decisions.

## Issue Classification

### CRITICAL

- Authentication bypass or authorization bypass.
- Remote code execution, destructive command execution, or arbitrary file write via untrusted input.
- Secret disclosure, credential leakage, or private workspace exposure.
- Prompt injection or agentic compromise that can trigger privileged actions or data exfiltration.

### HIGH

- Broken access control on a sensitive resource or action.
- Injection vulnerability with a realistic exploit path.
- Unsafe model output handling that can reach shell, SQL, or file writes.
- Trust boundary violation that allows untrusted context to control privileged behavior.

### MEDIUM

- Missing defense in depth, weak redaction, or verbose errors.
- Misconfiguration that expands exposure but does not yet create a direct exploit path.
- Missing rate limiting on a non-critical path.

### LOW

- Hardening opportunities, diagnostic improvements, or policy clarifications.
