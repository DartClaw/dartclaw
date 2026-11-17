# Inferred Container Posture Falls Back When the Provider Has No Container Credential

**Plan**: dev/bundle/docs/specs/inferred-posture-credential-fallback/plan.json
**Story-ID**: S01

## Feature Overview and Goal

**Intent**: A default install (`dartclaw init`, no `container:` section) on a machine with Docker or Podman stops `dartclaw serve` dead when the provider has only its CLI login, although ADR-055 promises that every refusal reachable on an install that never asked for containers downgrades to advisory mode – and `dartclaw doctor` passes the same install, so the first-run user meets the failure only at `serve`.

**Expected Outcomes**:

- [OC01] A default install whose default provider has no credential a container can use starts serving in advisory mode, with a warning that names the missing credential and how to get isolation.
- [OC02] An operator who declared `container.enabled: true` still gets a startup refusal for the same missing credential.
- [OC03] `dartclaw doctor` reports, before `serve`, that a CLI login does not cover a provider that will run in a container, with the status `serve` will act on.


## Required Context

- `dev/adrs/055-container-by-default-posture.md#decision` – item 3 is the requested-vs-inferred rule this story extends to a provider credential.
- `docs/guide/security.md#container-isolation` – the posture table operators read; it must describe the new downgrade.
- `docs/guide/getting-started.md` – the quick start's `claude setup-token` / `dartclaw auth claude` step is what isolation needs; its prose must say what happens without it.


## Acceptance Scenarios

- **S01 [OC01] A default install with only the CLI login starts in advisory mode**
  - **Given** a config with no `container:` section, a container runtime on the host, default provider `claude`, no credential stored with `dartclaw auth claude`, no `ANTHROPIC_API_KEY`, and the `claude` CLI logged in
  - **When** the runtime is composed (`dartclaw serve`)
  - **Then** composition completes, the deployment reports itself as not isolated, the primary provider is admitted on the host lane via the CLI login, and exactly one advisory warning says the host is in advisory mode because provider `claude` has no credential a container can use, naming `claude setup-token` + `dartclaw auth claude`, `ANTHROPIC_API_KEY`, and `container.enabled: false` as the ways to settle it

- **S02 [OC01] A default install with a stored credential still isolates**
  - **Given** S01's setup plus a Claude setup-token stored in the instance's credential store
  - **When** the runtime is composed
  - **Then** container isolation is active and no advisory warning is logged

- **S03 [OC02] An explicit request keeps the refusal**
  - **Given** S01's setup but `container.enabled: true`
  - **When** the runtime is composed
  - **Then** startup is refused (non-zero exit / thrown startup error, as today) and the refusal names the missing Claude credential and its remediation; nothing downgrades

- **S04 [OC01] A secondary provider's missing credential does not downgrade the deployment**
  - **Given** an inferred posture with a runtime, default provider `claude` with a stored credential, and a secondary provider `codex` with no container-usable credential
  - **When** the runtime is composed
  - **Then** container isolation stays active and `codex` gets today's warning only

- **S05 [OC01] A primary pinned to the host needs no container credential**
  - **Given** an inferred posture with a runtime, `agent.execution: host`, and S01's credential state
  - **When** the runtime is composed
  - **Then** container isolation stays active for the lanes that use it and no credential-driven advisory warning is logged

- **S06 [OC03] Doctor warns where `serve` will downgrade**
  - **Given** S01's config and host (no `container:` section, runtime present, CLI login only)
  - **When** the operator runs `dartclaw doctor`
  - **Then** row `provider.claude.credential` is `warn`, its summary says the CLI login cannot be used inside a container so `serve` will start without isolation, and its remediation names `claude setup-token` + `dartclaw auth claude` (or `ANTHROPIC_API_KEY`)

- **S07 [OC03] Doctor fails where `serve` will refuse**
  - **Given** S06's state but `container.enabled: true`
  - **When** the operator runs `dartclaw doctor`
  - **Then** row `provider.claude.credential` is `fail` with the same remediation

- **S08 [OC03] Doctor keeps passing a host-only install on the CLI login**
  - **Given** S06's credential state with `container.enabled: false`, or with no container runtime on the host
  - **When** the operator runs `dartclaw doctor`
  - **Then** row `provider.claude.credential` is `pass`, as today

- **S09 [OC01,OC03] [runtime] The first-run quick start reaches a serving instance**
  - **Given** a Docker host with the `claude` CLI logged in, nothing stored with `dartclaw auth`, and an empty PostgreSQL 14+ database
  - **When** the operator runs `dartclaw init --non-interactive --provider claude --auth-claude oauth --model-claude sonnet --port <free port>`, `dartclaw --config <cfg> doctor --fix`, then `dartclaw --config <cfg> serve`
  - **Then** doctor reports S06's `warn` row and zero `fail` rows, and `serve` answers HTTP on the port with S01's advisory warning in its log


## Structural Criteria

- **SC01** The credential-admission rule (stored credential, else the binary's own login only when nothing is configured and execution is on the host) has one implementation, in `ProviderValidator`; the doctor check and runtime validation both call it, and `apps/dartclaw_cli/lib` holds no copy of the rescue.
- **SC02** Whether the primary provider runs in a container is answered by the existing placement authorities (`resolveContainerPosture` for the posture, `ExecutionPolicyResolver.resolveForPrimary` for placement); neither `SecurityWiring` nor `SetupChecks` re-derives placement from `agent.execution` or `container.enabled` by hand.
- **SC04** The decision "this resolved config will decline containers for a credential" (inferred posture, primary placement container, TI01's rule refuses) is one runtime-side function in `dartclaw_runtime`, called by both `SecurityWiring._wireContainers` and `SetupChecks`; the container profile ids the resolver is built over come from one source, not repeated at each call site (ADR-054, one authority per concern).
- **SC03** The operator-facing record matches the new behavior: ADR-055 carries a dated amendment making a missing default-provider container credential an inferred-only refusal, the `dev/state/DECISIONS.md` ADR-055 row cites it, `docs/guide/security.md` § Container Isolation's posture table and `docs/guide/getting-started.md`'s step 4 say what happens without the stored credential, and `CHANGELOG.md` 0.28.1 `### Fixed` has the entry.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_kernel/lib/src/provider_validator.dart` – the single credential-admission rule
- `packages/dartclaw_runtime/lib/src/runtime/security_wiring.dart` – `_wireContainers`, where the inferred downgrade lives
- `packages/dartclaw_runtime/lib/src/container/` – home of the SC04 function, exported for the CLI beside `resolveContainerPosture`
- `apps/dartclaw_cli/lib/src/commands/init/setup_checks.dart` – `_runNetwork` / `_defaultProviderVerified`
- `dev/adrs/055-container-by-default-posture.md`, `dev/state/DECISIONS.md` (ADR-055 row), `docs/guide/security.md`, `docs/guide/getting-started.md`, `CHANGELOG.md` (0.28.1)

### What We're NOT Doing
- Keeping containers for some lanes while only the primary runs on the host – ADR-055 settles one posture per deployment through `_correctPostureIfDowngraded`; a split posture would be a second answer to "is this deployment isolated".
- Writing a `container:` section from `dartclaw init` – unset is ADR-055's intended default.
- Changing the zero-server `--standalone` lane – it reads the posture as written and never probes (security.md § Container Isolation).
- Downgrading for a missing credential under an explicit `true`, or for ACP's `container_isolation_required` – both stay fail-closed per ADR-055.
- Changing doctor's verdict for host placement, or for providers whose credential is present.


## Architecture Decision

**Approach**: Under an inferred posture, `_wireContainers` checks the default provider's container credential through `ProviderValidator`'s rule first, before the runtime probe and image build (a deployment that will downgrade never builds an image, and an absent-runtime test can tell the two refusals apart); a gap becomes one more inferred-only refusal, so it reaches advisory mode through the existing `refuse` path and `_correctPostureIfDowngraded`. Doctor resolves the posture with `resolveContainerPosture` and asks the same SC04 function `_wireContainers` asks.
**Why this over the floor**: The floor – a doc note telling users to run `dartclaw auth` – leaves OC01 unmet: ADR-055 Consequences commit that every refusal reachable on an install that never asked for containers downgrades, and this one does not. Downgrading after harness validation instead would mean unwinding container authorities that `SecurityWiring` already registered.


## Constraints & Gotchas

- **Constraint**: Shared worktree – `CHANGELOG.md`, `README.md` and `docs/guide/getting-started.md` carry another session's uncommitted edits. Edit only the hunks this story needs; never `git restore`, `git stash` or `git checkout --` them, and don't touch `README.md` at all.
- **Constraint**: The SC04 function runs before `ExecutionPolicyResolver` exists in `HarnessWiring`. It builds a resolver over the profiles container wiring registers (`SecurityProfile.workspace` / `restricted` ids, from the one source SC04 names) and treats `ExecutionPolicyException` as host, as `HarnessWiring.wire`'s `isHostExecution` already does.


## Implementation Plan

### Implementation Tasks

- **TI01** `ProviderValidator` exposes the per-provider credential-admission rule as one public static (inputs: provider id and entry, registry, host-or-container placement, credentials dir, home path; output: admitted, or the `credentialRemediationFor` message), and `validate()` uses it
  - **Verify**: `packages/dartclaw_kernel/test/provider_validator_test.dart` – new tests call the new static directly (the existing `validate` tests already prove these readings through `validate()`): container placement with only a binary login is refused with the remediation message; host placement with nothing configured is admitted on the binary login; a forced selection is never rescued; existing tests stay green
  - **SATISFIES**: SC01

- **TI02** Under an inferred posture (keyed on `container.declaredEnabled`, as `refuse` is), `_wireContainers` declines containers when the default provider's primary placement is container and TI01's rule refuses it; the advisory warning names the provider and the three remediations, and the existing "No host-held Claude credential" warning is not also logged on that downgrade (it would announce containerized executions that will not exist); an explicit `true` keeps today's path
  - Follows `packages/dartclaw_runtime/test/runtime/security_wiring_container_isolation_test.dart#an inferred posture whose runtime probe fails downgrades instead of exiting` for shape. Depends on TI01.
  - **Verify**: `packages/dartclaw_runtime/test/runtime/security_wiring_container_isolation_test.dart` – new tests, each with `ContainerConfig().resolved(enabled: true, runtimeBinary: 'dartclaw-absent-runtime')` (no test can reach `containersEnabled == true`, so the runtime refusal is the marker that wiring got past the credential check): S01 → `containersEnabled == false`, exactly one `Container isolation disabled` warning, naming `claude`, `claude setup-token`, `dartclaw auth claude`, `ANTHROPIC_API_KEY` and `container.enabled: false`, and not naming the runtime; S02 (setup-token stored), S04 (secondary `codex` gap) and S05 (`agent.execution: host`) → the downgrade reason is the absent runtime and no warning names a credential; S03 (`ContainerConfig(enabled: true)`, same credential state) → exits with the runtime refusal, no credential advisory
  - The decision itself is the SC04 function; `_wireContainers` only calls it and acts on the answer.
  - **SATISFIES**: S01, S02, S03, S04, S05, SC02, SC04

- **TI03** The composed runtime starts on S01's inputs: the downgraded posture reaches `HarnessWiring`, which admits the primary on the host lane via the CLI login; under an explicit `true` with containers wired, `HarnessWiring` still refuses the container primary naming the credential
  - Composition seam: `packages/dartclaw_runtime/test/runtime/service_wiring_login_store_collision_test.dart` (`DartclawRuntime.build` with `_harnessFactory`, `openPreparedTaskBackend`, an injected `environment` without `ANTHROPIC_API_KEY`). The logged-in CLI is a `#!/bin/sh` stub at an absolute path answering `--version` and `auth status` (`{"loggedIn":true}`), per `apps/dartclaw_cli/test/commands/auth/auth_codex_command_test.dart`'s stub; a bare name resolves on the test process's PATH. The explicit arm cannot be composed (it exits at the runtime probe without Docker), so it uses `packages/dartclaw_runtime/test/runtime/harness_wiring_warnings_test.dart#_ContainerCapableSecurityWiring`. Depends on TI02.
  - **Verify**: `packages/dartclaw_runtime/test/runtime/inferred_posture_credential_fallback_test.dart` – composing with an inferred posture resolved to enabled on `dartclaw-absent-runtime`, no stored credential and the stub CLI completes with `containerIsolationActive == false` and an advisory warning naming the credential, not the runtime; a `HarnessWiring` over `_ContainerCapableSecurityWiring` with `container.enabled: true`, a container primary and the same credential state throws naming `claude setup-token`
  - **SATISFIES**: S01, S03

- **TI04** `SetupChecks` judges `provider.<id>.credential` through TI01's rule at the placement `serve` will use: `warn` where an inferred posture will downgrade, `fail` where an explicit `true` will refuse, `pass` on host placement as today; a `warn` row does not turn `init`'s outcome into configured-but-unverified
  - Placement via `resolveContainerPosture(runCommand: _runCommand, platformCapabilities: ...)` and `ExecutionPolicyResolver.resolveForPrimary`; the declared-`true`-fails, otherwise-warns split follows `apps/dartclaw_cli/lib/src/commands/init/setup_checks.dart#_containerRows`. The `providerVerified` seam answers a bool and cannot carry `warn`, so it changes shape with the row. The downgrade prediction is the SC04 function, not a doctor-side composition. Resolve the posture once per `diagnose` and feed both this row and `_containerRows`, so the runtime is probed once. Depends on TI01 and TI02.
  - **Verify**: `apps/dartclaw_cli/test/commands/init/setup_checks_test.dart` – new tests in group `default provider verification resolves the credential admission will`, with the runtime probe answered by an injected `runCommand` and the CLI login by an absolute-path stub (`runCommand` does not reach the auth probe): S06 → `warn`, summary says the CLI login cannot be used inside a container so `serve` starts without isolation, remediation names `claude setup-token` + `dartclaw auth claude` and `ANTHROPIC_API_KEY`; S07 → `fail`, same remediation; S08 → `pass` for both the declared-`false` and no-runtime readings; `verify()` on S06's state still reports success; existing tests green
  - **SATISFIES**: S06, S07, S08, SC01, SC02, SC04

- **TI05** The copied rescue is gone from the CLI, and neither wiring site reads `agent.execution` itself
  - **Verify**: `cmd: test -z "$(git grep -n -e 'probeAuthStatus' -e 'CredentialUnavailableReason.noneConfigured' -- apps/dartclaw_cli/lib)"` – no binary-login probe or rescue gate remains outside `ProviderValidator`; `cmd: test -z "$(git grep -n 'agent\.execution' -- packages/dartclaw_runtime/lib/src/runtime/security_wiring.dart apps/dartclaw_cli/lib/src/commands/init/setup_checks.dart)"` – placement comes from `ExecutionPolicyResolver`
  - **SATISFIES**: SC01, SC02

- **TI06** SC03's documents carry the change
  - **Verify**: `inspect: dev/adrs/055-container-by-default-posture.md:28` – a dated amendment under § Consequences (or its own section) names the missing default-provider container credential as an inferred-only refusal; `inspect: dev/state/DECISIONS.md:72` – the ADR-055 row cites it; `inspect: docs/guide/security.md:303` – § Container Isolation's table or its note states the credential downgrade; `inspect: docs/guide/getting-started.md:133` – step 4 says `serve` starts without isolation when it is skipped; `inspect: CHANGELOG.md:29` – the 0.28.1 Fixed entry names the old failure (`serve` exited with "has no credential configured") and the new advisory start
  - **SATISFIES**: SC03

- **TI07** S09 has run for real on this Docker host
  - Write `.agent_temp/inferred-posture-s09.sh` (not shipped): start a throwaway `postgres:14` container on a free loopback port, `init` a temp instance under `.agent_temp/` exactly as S09 states with `DARTCLAW_DATABASE_URL` set, run `doctor --fix`, start `serve` in the background, poll the port up to 120 s, then always remove the server process, the instance directory and the container. It uses the logged-in `claude` CLI and stores nothing with `dartclaw auth`. Depends on TI02 and TI04.
  - **Verify**: `cmd: bash .agent_temp/inferred-posture-s09.sh` – exits 0 only when doctor's output has `provider.claude.credential` as `warn` and zero `fail` rows, the port answers HTTP, and the server log has S01's advisory warning naming the credential
  - **SATISFIES**: S09


## Implementation Observations

- **TI03 explicit arm exits instead of throwing.** `HarnessWiring.wire` catches the primary-start `StateError`, logs it severe as "Failed to start harness" and calls `exitFn(1)`; it does not rethrow. The test asserts exit code 1 and the severe record's `StateError` naming `claude setup-token` and `dartclaw auth claude`, which is the refusal "as today". The shared `_ContainerCapableSecurityWiring` moved from `harness_wiring_warnings_test.dart` into `harness_wiring_fixture.dart` (`ContainerCapableSecurityWiring`) so both suites use it; it is wired with a disabled posture so its inherited `wire` skips the real runtime probe.
- **`SecurityWiring` takes an `environment`.** Its credential registry read `Platform.environment` while `HarnessWiring` reads the injected one, so under an injected environment the downgrade and the harness refusal could disagree (and S01 depended on the test host having no `ANTHROPIC_API_KEY`). `DartclawRuntime` now passes its `_environment`; both wirings and the new tests read one credential state.
- **SC04 is `inferredPostureCredentialGap` plus `primaryRunsInContainer`** (`packages/dartclaw_runtime/lib/src/container/inferred_posture_credential_gap.dart`, both exported). `primaryRunsInContainer` is the one place the resolver is built over `containerSecurityProfiles`; `SetupChecks` calls it for per-provider placement instead of building a resolver. The gap function judges only the claude and codex families: a registrar-owned (ACP) default provider carries its own authentication, which `SecurityWiring` cannot see, so judging it would downgrade falsely.
- **TI04 seam shape.** `providerVerified` is now `ProviderCredentialCheck`: `(providerId, binary, configPath, {required hostExecution}) -> String?`, the `credentialRefusalFor` answer (`null` is admitted). Callers in four CLI test files were migrated mechanically. Row rules: placement is host for every provider when `inferredPostureCredentialGap` predicts a downgrade; a host refusal is `fail` with today's wording; a container refusal is `fail` for the default provider and `warn` for others (`serve` only warns for those); the predicted downgrade is `warn` for the gap provider. `verify()` judges host placement only and tolerates `warn` rows. Resolving the posture in `init`'s verify would probe Docker there and make the injected-seam tests depend on the host.
- **`_containerRows` still probes once more for an explicit `true`.** `resolveContainerPosture` keeps `runtimeBinary`'s default `docker` when nothing answers, so only an inferred posture (enabled exactly when a runtime answered) can be read back from the resolved config. An explicit `true` asks `detectRuntime` again, as before the change.
- **An existing test changed meaning, not strength.** `an inferred posture whose runtime probe fails downgrades instead of exiting` now stores a Claude credential, because without one the host's own credential state would decide the downgrade reason before the runtime probe is reached.

### Review fix round

- **The gap decision is outside `refuse`.** `inferredPostureCredentialGap` answers only for an inferred posture, so the gap returns its reason straight to `wire()`'s advisory warning and logs no severe record. The ADR-055 amendment, the `_wireContainers` doc comment and the runtime `CLAUDE.md` said otherwise ("through the existing `refuse` path", "the asymmetry lives here and nowhere else") and now describe two deciding sites.
- **The provider status card no longer credits a login a container cannot use.** `ProviderStatusService.probe` asked its own `noneConfigured` gate, ignoring placement. It now asks `ProviderValidator.credentialRefusalFor` through a new `loginProbe` parameter (so the injected `AuthProbe` still stands in for the vendor probe), at the placement `HarnessWiring.isHostExecution` reports (the closure `validate` already used, now a method both consume). Under an explicit `true` with only a `~/.codex` login the status is `missing`/degraded and the login is never probed. Test: `a vendor login does not answer for a provider whose resolved placement is a container` (failed on `credentialStatus` `oauth` before the fix). `credentialRefusalFor` keeps the rule's only login read; the kernel `CLAUDE.md` claim names its callers and the spawn-time host gates that only decline to refuse `noneConfigured`.
- **The credential downgrade still sweeps orphans.** `_wireContainers` returned before `reclaimOwnedContainers`, and `dispose` sweeps only when a gateway exists, so a labelled orphan from a crashed earlier `serve` was left. The gap block now sits after probe construction and runs the (non-fatal) sweep when `probe.isRuntimeAvailable()`. The claude host-credential warning moved below it so a downgrade still does not announce containerized executions. Tests: `the credential downgrade still reclaims containers an earlier serve left behind` (a stub runtime CLI records `rm -f dartclaw-orphan`; failed before: no runtime call at all) and `an absent runtime on the credential downgrade attempts no sweep`.
- **F4 is not reachable through the config loader.** `SetupChecks` compared the normalized downgrade provider id with the raw row id, but the loader normalizes provider keys, so a `Claude:` key already yields `provider.claude.credential`; no test could fail before the fix. The comparison now normalizes `id` anyway, and `a mixed-case provider key still gets the downgrade warning` pins the spelling case (green before and after).
- **Test strength.** The `verify` test is renamed to what it proves (it judges host placement only). New doctor test `a secondary provider with no container credential warns that its containerized runs are rejected` covers the secondary-provider warn row; it covers an existing branch and was green on first run.
