# Agent Harness Protocols

- **Terminal result maps are outcomes, not success.** A resolved harness future can carry `stop_reason:error`; translate it before guarding or persisting streamed assistant text.
- **Process ownership ends after confirmed exit.** Await the shared termination helper before removing a managed child; keep unconfirmed exit observable.
- **`AgentHarness.turn()`'s result-map keys are not a uniform cross-harness contract.** `'response'` (assistant text) is ACP-only — Claude/Codex stream text as `DeltaEvent`s instead; never assume `'response'` exists outside ACP.

### Process lifecycle
- **Pre-signalled termination must carry acceptance, not an attempted flag.** Typed results lie if callers discard `Process.kill()`'s bool; thread nullable acceptance to suppress duplicate kills.

### Claude
- **`CLAUDECODE` env var causes nesting refusal.** Clear in subprocess environment.
- **Model override goes via `--model` CLI flag, not the initialize field.**
- **`sdkMcpServers` map must be spread, not double-wrapped.** Helpers already return the top-level shape; passing into another `sdkMcpServers:` field silently produces `sdkMcpServers.sdkMcpServers`.
- **`--dangerously-skip-permissions` is only safe with hooks active.** Restricted-container simple mode disables hooks → fail-closed on `can_use_tool`.
- **`file_edit` is granted separately from `file_write`.** The Claude one-shot allow-list (`claude_cli_provider.dart`) emits `Edit`/`NotebookEdit` only for steps whose `allowedTools` contain `file_edit`; `file_write` alone grants just `Write`, so under the standalone default `--permission-mode dontAsk` a step can create files but never edit them (server mode masks this via interactive `can_use_tool`). Permission mode (prompt gating) and Claude's sandbox (`sandbox.enabled`, OS isolation) are orthogonal axes — never map sandbox→skip-permissions.
- **Per-turn `system_prompt` *replaces* spawn-time `--append-system-prompt`.** Don't inject conversation history via system prompt for `PromptStrategy.append`. Inject as `<conversation_history>` XML in the user message on cold-process turns only.
- **`_buildClaudeArgs()` is process-level, not per-task.** `HarnessPool` reuses long-lived runners; per-task flags require new processes or pool segmentation.
- **Container mode: skip host probes.** No `claude --version` / auth probes from inside the container.
- **Direct Claude setting sources default to inherited user scope.** Omit `--setting-sources` unless `providers.claude.inherit_user_settings: false`; workflow skill preflight must use the same policy as execution or `andthen:*` skills disappear before dispatch.
- **One-shot `--output-format json` buffers until turn end and starves stall monitors.** Zero stdout while working, so silence-timer guards false-trip on long turns. Use `--output-format stream-json --verbose --include-partial-messages`; parse the terminal `type: "result"` event — tokens nest under `usage.*`, not top-level. Codex `exec --json` already streams JSONL.
- **`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` failures land on stdout, not stderr.** The scrub (applied via `claudeHardeningEnvVars`) forces permission mode to default and prints a benign stderr notice, while the real failure (e.g. a 401) goes to stdout — surface stdout first on nonzero exit. It strips env-borne secrets only; keychain subscription OAuth never flows through env.
- **Standalone `claude` reads keychain OAuth only when `USER` is in the spawn env.** `HOME`+`PATH` alone → "not logged in". The workflow provider spawn sanitize deliberately keeps `USER` — never add an allowlist that drops it (regression-tested on the provider env builder). Logged-out CLIs abort via `ProviderAuthPreflight` with provider-named remediation before skill introspection.
- **Standalone harness startup is deferred behind the auth preflight.** CLI wiring splits into `wirePreHarness()` (no spawn) and `startHarnesses(providers)`; run/resume/retry derive the referenced-provider set, run `preflightProviderAuth`, then start only those — an unreferenced logged-out default is never started or probed. The executor-level preflight stays as the in-engine backstop for connected mode.

### Codex
- **Codex reads `config.toml` only at app-server startup.** Write `CODEX_HOME/config.toml` before spawning; later changes have no effect.
- **Crash recovery must clear cached `_threadIds`.** All thread IDs are stale after process exit. Continuity comes from DartClaw's NDJSON history replay, not Codex resume.
- **`thread/start` returns a `thread_id` that must be reused** on every subsequent `turn/start`, or you silently start an orphan thread.
- **Per-turn model override needs `harnessConfig.model` fallback.** Otherwise the configured default model is silently ignored.
- **No cost reporting.** `supportsCostReporting` is `false`. Budget enforcement must use tokens.
- **Anthropic and Codex disagree on `input_tokens` semantics.** Claude reports fresh input directly; Codex reports cache-inclusive input, so normalize at the harness/workflow boundary before persisting or comparing usage.
- **Strict structured output requires every nested object fully closed.** `additionalProperties: false` and `required` covering every property. Nullable optionals → required keys whose schema allows `null`.
- **App-server hangs on tool-use turns when approval is required.** Upstream bug ([codex#11816](https://github.com/openai/codex/issues/11816)): `exec_approval.rs` awaits client approval with no timeout, no cancellation. Workaround: `approval: never` + `sandbox: danger-full-access`; lower `worker_timeout` to 120s in crowd-coding to limit blast radius.
- **App-server tests must drive handshake responses while `start()` is in flight.** `start()` correctly blocks on `initialize → initialized → thread/start`; awaiting `start()` before emitting responses deadlocks.
- **Approval-path sanitization is local containment only**, not transport mutation. Don't try to rewrite `tool_input` before the provider sees it.
- **Exec-mode shutdown must not await a pending `Process.start`.** One-shot harness `stop()` must complete the turn completer immediately and defer cleanup until spawn settles.
- **One-shot codex spawns without `--model` inherit the operator's `~/.codex/config.toml`.** A user-level model override there can break every live run (unknown-model failures). Live codex spawn paths must pin `--model` or run under a controlled `CODEX_HOME`; `workflow-live/run.sh` exports a hermetic, model-pinned `CODEX_HOME`.

### Turn Routing
- **Provider-routed sessions need turn-reservation bookkeeping in `TurnManager`.** When provider selection happens at reserve time, all of `executeTurn` / `waitForOutcome` / `releaseTurn` must hit the same runner.
- **Append-mode prompt exceptions follow conversational scope.** Onboarding may opt into a full static prompt for Web UI/channels; automation, logical-agent, and evaluator turns stay excluded.
- **Claude PreToolUse must remain unfiltered.** Omitted matcher/if covers built-ins and dynamic MCP tools; a static name list silently bypasses host guards.
- **Claude discovery is not capability grant.** Let exact `ToolSearch` load schemas under a closed allowlist; separately evaluate every selected tool, and keep toolless policies closed.
