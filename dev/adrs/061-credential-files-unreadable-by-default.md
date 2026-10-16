# ADR-061: Credential files unreadable by default for every harness

## Status

Accepted – 2026-10-16. The owner chose to promote the credential deny set to the shared FileGuard default.

## Context

FileGuard's defaults marked `.env`, `.env.*`, `*.pem`, `*.key` and `.kube/config` `read_only`, which permits reads,
and protected the instance's `dartclaw.yaml` only against writes. The native-harness credential-deny-rule spec
(private planning, 2026-08-10) denied reads of a credential set for the in-process `DirectApiHarness` only, and stated
it would not change `FileGuardConfig._defaultRules`. Its reasoning: subprocess harnesses run behind a process and
optionally a container boundary, so they could keep the looser baseline.

That boundary does not stop the leak the set exists to prevent. Claude Code, Codex and ACP agents read files into the
provider's context; a mounted project's `.env` is inside every boundary the agent runs in, and reading it sends the key
to the provider and to whatever the agent writes next. `<dataDir>/credentials/` holds the subscription tokens and named
API keys (ADR-053) as plain files, protected only by file mode, and `<dataDir>/gateway_token` is the bearer for the
internal MCP surface.

FileGuard also had no way to express an exception: `fromYaml` only appends rules and the most restrictive match wins,
so neither `.env.example` (a template agents legitimately edit) nor an operator who needs `.env` readable could be
carved out of a broader rule.

## Decision

Reverse the spec's "do not change `_defaultRules`" stance. These become `no_access` defaults for every harness:

| Rule | Patterns |
|---|---|
| Instance config (C4) | `<dataDir>/dartclaw.yaml` |
| Gateway token (C5) | `<dataDir>/gateway_token` |
| Env files (C11) | `**/.env`, `**/.env.*` – except `.env.example`, `.env.sample`, `.env.template`, `.env.dist` |
| Private keys (C12) | `**/*.pem`, `**/*.p12`, `**/*.pfx`, `**/id_rsa*`, `**/id_dsa*`, `**/id_ecdsa*`, `**/id_ed25519*` |
| Credential stores (C13) | `<dataDir>/credentials`, `<dataDir>/credentials/**` |

`*.key` and `.kube/config` stay `read_only`: `.key` is an ambiguous suffix, as the spec argued.

Add a fourth level, `allow`: a path matching an `allow` rule is exempt from every other file rule. The four `.env.*`
exemptions ship as default `allow` rules, and an operator re-allows a default path with a `guards.file.extra_rules`
entry at `allow` (for example `**/.env`). The data-dir rules are anchored on the symlink-resolved data directory, so
they match no same-named file elsewhere.

FileGuard is one layer, not the whole containment. Harness-native deny rules and OS sandboxes (Claude Code's `Read`
deny rules, Codex permission profiles and its sandbox) own workspace and home secrets and what a search enumerates.
FileGuard is the harness-neutral floor beneath them: it holds DartClaw's own secrets, covers harnesses without native
rules (ACP agents), and is the layer every block is audited through. It sees only the tool calls a harness submits for
a decision, so it does not see Codex shell commands in a container, which run without an approval request; there the
container's mount allowlist is the boundary. So a Claude `Grep` or `Glob`
is checked like a read of the directory it searches, as Claude's own deny rules are: it is refused when that directory
is, or lies inside, a protected path, and a protected file below an allowed root does not refuse it.

## Consequences

- Agents on every harness are refused reads of the paths above through file tools, recognised shell reads, and Claude
  `Grep`/`Glob`.
- A whole-repo search still runs where a `.env` sits in the checkout, and FileGuard does not stop its matches from
  reaching the provider; keeping them out is the harness-native rules' and the sandbox's job.
- `.env.example` and its siblings lose their write protection: agents may now create and edit them.
- `allow` overrides even built-in `no_access` rules. An operator can widen access only through file config, which is
  already the authority that can switch the whole chain off with `guards.enabled: false`.
- `guards.enabled: false` still removes every rule here. Unconditional protection for the in-process harness remains the
  native-harness spec's harness-owned layer.
- A config loaded from outside the data directory is not covered: the guard builder knows only the data dir.

**Reversal**: two-way door – revert the default table and the `allow` level; no stored data depends on either.

## Alternatives Considered

1. **Keep the deny set for the in-process harness only** – rejected: the subprocess/container boundary does not stop a
   read of a mounted `.env` or of the data dir's plaintext stores from reaching the provider.
2. **Exact-pattern override (an extra rule for a default's pattern replaces its level)** – rejected: it cannot express
   the `.env.example` exemptions, which match `**/.env.*` without sharing its pattern, so it would need an exception
   mechanism anyway.
3. **Last-match-wins rule order** – rejected: one broad operator rule (`**/*: no_delete`) would silently lift the
   built-in `no_access` stores.
4. **Floor option – extend what exists (defaults plus `extra_rules`, no exception)** – rejected: `.env.*` would block
   the example templates every repo ships, with no way back for an operator who needs `.env` readable.

## Implementation Notes

- `packages/dartclaw_kernel/lib/src/file_guard.dart`: default table, `FileAccessLevel.allow`,
  `FileGuardConfig.withDataDirProtection` (replaces `withSelfProtection`); `Grep`/`Glob` are checked on their root only,
  which replaces the earlier probe that refused a root holding a `no_access` path.
- Paths, and exact-path rules, resolve symlinks through their longest existing ancestor, so a file not created yet
  under a symlinked data dir (macOS `/var` → `/private/var`) still matches the anchored rules.
- `packages/dartclaw_runtime/lib/src/security/guard_builder.dart` wires the data dir; the guard editor and config
  metadata accept `allow`.

## Project Compliance

Extends the existing FileGuard seam with one level instead of adding a guard or config key (Core Philosophy: reuse
before you build). One authority per concern (ADR-054): FileGuard remains the single file-path policy for the guard
chain.

## References

- ADR-053 – subscription credential stores under `<dataDir>/credentials/`.
- ADR-054 – one authority per concern.
- `dev/architecture/security-architecture.md` – FileGuard section.
