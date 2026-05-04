# Package Rules — `dartclaw_security`

**Role**: Defense-in-depth Layer 3 primitives — `Guard`/`GuardChain`/`GuardContext`/`GuardVerdict`, the built-in guards (`CommandGuard`, `FileGuard`, `NetworkGuard`, `InputSanitizer`, `ContentGuard`, `TaskToolFilterGuard`), `MessageRedactor`, `ContentClassifier` interface (+ `AnthropicApiClassifier`, `ClaudeBinaryClassifier`, `CloudflareDetector`), `GuardAuditLogger`, `SafeProcess`/`EnvPolicy` env sanitization.

## Architecture
- **Guard chain** — `Guard` (interface), `GuardChain` (sequential evaluator: first-block-wins, 5s `.timeout()`, fail-closed default), `GuardContext` (canonical tool name + args + raw provider name for audit), `GuardVerdict` (sealed `Pass` / `Warn` / `Block`), `GuardVerdictCallback` (the seam upstream uses to translate verdicts to events).
- **Built-in guards** — `CommandGuard` (regex policy on shell commands; quote-stripping, subshell-aware), `FileGuard` (glob policy on resolved paths; symlink-aware; self-protection mode), `NetworkGuard` (URL allowlist/blocklist), `InputSanitizer` (prompt-injection patterns), `ContentGuard` (classifier-driven), `TaskToolFilterGuard` (provider tool gating).
- **Classifiers** — pluggable content scanners. `ContentClassifier` (interface), `AnthropicApiClassifier`, `ClaudeBinaryClassifier`, `CloudflareDetector`. Throws are the caller's contract — `ContentGuard` decides fail-open vs fail-closed.
- **Redaction** — `MessageRedactor` (proportional redaction at the agent boundary; preserves shape for audit).
- **Audit trail** — `GuardAuditLogger` (NDJSON appender; fire-and-forget) + `AuditEntry` (record schema).
- **Process safety** — `SafeProcess` (the only sanctioned subprocess spawner), `EnvPolicy.sanitize()` (env allowlist + sensitive-name strip), `kDefaultBashStepEnvAllowlist` / `kDefaultGitEnvAllowlist` / `kDefaultSensitivePatterns` (defaults).

## Boundaries
- Allowed deps: `dartclaw_models`, plus `logging`, `path`. **No** dependency on `dartclaw_core`, `dartclaw_storage`, `dartclaw_config`, or any workspace package above models. Keep this leaf.
- **Zero EventBus.** This package must not import `dartclaw_event.dart` or fire `GuardBlockEvent` directly. Callers (`dartclaw_server` via `SecurityWiring`) translate verdicts → events using the `GuardVerdictCallback` seam on `GuardChain`.
- No file I/O outside `GuardAuditLogger` (NDJSON appends) and `FileGuard` symlink resolution. Guards are pure evaluators; no DB, no HTTP, no process spawning except via `SafeProcess`.

## Conventions
- New guard: extend `Guard`, return `GuardPass` / `GuardWarn(message)` / `GuardBlock(reason)`. Set stable `name` and `category` strings — they appear in audit NDJSON and config keys.
- Guards must **not throw** from `evaluate`. Catch internally and return `GuardBlock`. The chain's 5s `.timeout()` + fail-closed default exists as a backstop, not the primary error path.
- New classifier: implement `ContentClassifier`. Throws are the caller's contract (`ContentGuard` decides fail-open vs fail-closed) — do not swallow inside the classifier.
- Pattern lists in `CommandGuard` / `InputSanitizer` are extended via config-driven extras (`extra_patterns`, `extra_rules`); don't hardcode policy that an operator should be able to adjust.
- Subprocess env: route everything through `SafeProcess` with an explicit `EnvPolicy.sanitize(...)`. Use `kDefaultBashStepEnvAllowlist` / `kDefaultGitEnvAllowlist` as starting points — `kDefaultSensitivePatterns` strips `*_API_KEY`/`*_SECRET`/`*_TOKEN`/`*_CREDENTIAL`/`*_PASSWORD`. SSH-agent vars are intentionally allowlisted for git only.

## Gotchas
- Guards evaluate the **canonical** tool name (`shell`, `file_write`, etc.); the provider-native string is preserved on `GuardContext.rawProviderToolName` for audit only. Don't write policy against raw names.
- `GuardChain.replaceGuards` is the hot-reload entry point — it captures the list reference per-evaluation so concurrent reloads don't corrupt in-flight evaluations. Don't replace the internal list in-place.
- First **block** wins and short-circuits; warns accumulate as the worst non-block verdict. Guard order matters — cheap/decisive guards first.
- `CommandGuard` strips single-quoted strings before scanning to defeat `'rm' '-rf'` bypass, but `$(...)` subshells are intentionally not blocked (their inner command is rescanned). Don't add subshell blocking — container isolation handles the variable-expansion class.
- `FileGuard` resolves symlinks (e.g. `/var` → `/private/var` on macOS); rules use globs against the **resolved** path. Use `FileGuardConfig.withSelfProtection(configPath)` so the agent cannot rewrite its own `dartclaw.yaml`.
- Provider-specific interception: Claude Code uses `--dangerously-skip-permissions` + `PreToolUse` hook (guard chain is the active gate); Codex uses approval requests only (must keep approvals on, never `--yolo`).
- Workflow read-only research/analysis steps express write-policy via `configJson.readOnly = true` + post-turn `git status` against the worktree, not a separate guard rule.

## Testing
- Flat `test/<feature>_test.dart` layout — one file per guard / classifier / utility. Add tests in the matching file when touching behavior.
- Use `FakeGuard` from `dartclaw_testing` to compose chains in upstream tests; here, exercise real guards.
- No integration tag — this package's tests are pure unit. If a test needs a process or filesystem, use `SafeProcess` with a temp dir.

## Key files
- `lib/dartclaw_security.dart` — barrel.
- `lib/src/guard.dart` — `Guard`, `GuardChain`, `GuardContext`, `GuardVerdictCallback`.
- `lib/src/guard_verdict.dart` — sealed `GuardVerdict` (`Pass`/`Warn`/`Block`).
- `lib/src/{command,file,network,content}_guard.dart`, `input_sanitizer.dart`, `task_tool_filter_guard.dart` — built-in guards.
- `lib/src/content_classifier.dart` + `anthropic_api_classifier.dart` / `claude_binary_classifier.dart` / `cloudflare_detector.dart` — classifier interface + impls.
- `lib/src/safe_process.dart` — `SafeProcess`, `EnvPolicy`, env allowlists, sensitive-name patterns.
- `lib/src/guard_audit.dart` — `GuardAuditLogger`, `AuditEntry` (NDJSON, fire-and-forget).
- `lib/src/message_redactor.dart` — proportional redaction at the agent boundary.
