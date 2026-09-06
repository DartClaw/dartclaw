# Package Architecture

- **Equal timeout defaults are a tie, not a fix.** Delete duplicate budgets; aligned values still leave two enforcement owners and race-dependent outcomes.
- **`ConfigNotifier` emits section-level keys (`security.*`), not sub-keys (`guards.*`).** `Reconfigurable.watchKeys` must use the section-level key or watches silently never fire — `ConfigDelta.hasChanged()` prefix-matches against section keys only.
- **Provider factories must normalize provider-specific executable defaults.** `HarnessFactoryConfig.executable` can only represent one default; each provider factory must substitute its own binary when not overridden.
- **Multi-provider UI/view-model code must derive the provider from `config.agent.provider`.** Hardcoded `'claude'` mislabels non-Claude deployments before usage data exists.
- **Harness capability differences belong on the base `AgentHarness` contract.** Expose via capability getters; consumers branch on flags. Unsupported telemetry → omission/null, never fake zero or provider-name conditionals.
- **Auto-accept callbacks must translate non-success `ReviewResult`s into thrown errors.** `TaskReviewService.review()` reports merge conflicts as typed results, not exceptions; callers wiring `Future<void>` callbacks otherwise lose the warning path.
- **Green tests can mask unwired features.** Direct-call tests don't prove a service is registered in DartclawRuntime/ScheduleService — verify wiring via integration test + grep for non-test refs.
- **`ScheduleService`'s job list is not user-prompt-jobs-only.** CLI wiring back-registers task definitions as `auto-task-<id>` callback jobs (`ScheduledTaskRunner.buildJobs()`), and system jobs are `onExecute`-based too — new consumers must decide explicitly how to treat `onExecute != null` entries.
- **Resolved step config has multiple consumers.** New inherited step fields must flow through dispatch, follow-up prompts, extraction, and resolved-YAML export.
- **Pub workspace build hooks honor the workspace ROOT pubspec's `hooks.user_defines`, not member pubspecs.** A root-level override wins; any per-platform override must neutralize the root block too.
- **Share the verdict object, not its message.** `resolveFamily` aliases unknown providers onto `claude`/`codex`; re-deriving availability per surface isn't parity — gate on the configured identity.
- **`CredentialRegistry.resolve()` without `family:` misfires on aliases.** Four sites, four failure modes. Pass `resolveFamily(providerId, executable:, options:)`, not `ProviderIdentity.family`.
