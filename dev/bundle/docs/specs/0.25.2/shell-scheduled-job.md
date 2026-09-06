# Model-free scheduled job (`type: shell`)

## Feature Overview and Goal

**Intent**: A credentialed data feed — a process that holds a token and fetches data the agent only reads — cannot be declared to DartClaw today because every `scheduling.jobs` entry fires a model turn, so it lives in launchd outside the scheduler's logs, retries, pause/resume, on-demand run and Scheduling page, and the deployment has hand-built that plumbing twice.

**Expected Outcomes**

- [OC01] An operator declares a feed as a `scheduling.jobs` entry with `type: shell` and it runs on the scheduler the deployment already runs — same `schedule`/`at` forms, `enabled`, `retry.*`, failure alerting, on-demand run, and job row as every other job.
- [OC02] The feed's secret is named, never written: `env` references a `credentials.<name>` entry, the value reaches only the child process, and neither `dartclaw.yaml` nor the job's logged result carries it.
- [OC03] The agent reads the feed's output as an ordinary file under `<data_dir>/feeds/`: always a complete file, and a failed run leaves the previous one intact.
- [OC04] A `type: shell` entry is unreachable from chat and from every HTTP and tool write surface — it exists only by editing `dartclaw.yaml`.


## Required Context

- `dev/adrs/054-model-first-delegation-and-one-authority-per-concern.md#the-carve-out-what-stays-deterministic` – why the output ceiling, the timeout and every refusal here stay deterministic and host-side, and why one authority owns the write refusal rather than two agreeing checks.
- `packages/dartclaw_runtime/lib/src/scheduling/scheduled_task_runner.dart#composeConfigJobs` – the one composer boot wiring (`runtime/scheduling_wiring.dart`) and the live applier (`config/scheduling_jobs_applier.dart`) share; the shell executor is built here so a boot load and a live application cannot differ.
- `packages/dartclaw_runtime/lib/src/scheduling/schedule_service.dart#ScheduleService` – `_executeWithRetry` (retry policy + `ScheduledJobFailedEvent`), `_runJobTurn`'s `onExecute` branch, `_sameDefinition`, and `runJobNow`'s `candidate.onExecute == null` predicate, which today refuses every callback job.
- `packages/dartclaw_runtime/lib/src/scheduling/schedule_mutation.dart#ScheduleMutationService` – the one `scheduling.jobs` mutation authority; note that `_write` and the `schedule_upsert` tool both end at `commitAndApply`, while `removeJobs` (spent one-time entries) ends at `commit`.
- `packages/dartclaw_acp/lib/src/acp_config_parser.dart#_parseAcpCredentialReference` – the credential-reference refusal wording to mirror, and the fourth check (`envVars.isEmpty`) this FIS deliberately does not apply.
- `packages/dartclaw_kernel/lib/src/safe_process.dart#SafeProcess` – `start` with `includeParentEnvironment: false`, and `sanitize` overlaying `extraEnvironment` *after* the sensitive-name strip, which is what lets an injected `*_TOKEN` survive while the parent's does not.
- `packages/dartclaw_core/lib/src/harness/process_lifecycle.dart#killWithEscalation` – the SIGTERM-then-SIGKILL helper the timeout path uses; `defaultProcessOutputLimitBytes` beside it is the 16 MiB ceiling this FIS reuses.
- `packages/dartclaw_core/lib/src/storage/atomic_write.dart#secureWriteFile` – temp-file + rename, `restrictPermissions: true` for owner-only; it takes a `String`, which is why stdout is bounded on bytes and then decoded strictly.
- `packages/dartclaw_kernel/lib/src/config_meta/agent_fields.dart#scheduling.jobs` – the `ObjectEntry` shape the new entry fields join; `ConfigMeta.fields` is the only registry for operator-facing fields.
- `dev/guidelines/TESTING-STRATEGY.md#applying-this-strategy-to-new-features` – layer selection; tests must run on Linux CI and macOS, so prefer Dart APIs over shell invocations.

## Deeper Context

- `docs/guide/scheduling.md#cron-jobs` – the operator-facing job vocabulary the new section extends.
- `docs/guide/security.md#named-credential-storage` – what the named store does and deliberately does not do; the credential-reach paragraph attaches here.
- `packages/dartclaw_kernel/lib/src/config_accept_set.dart` – an entry-shaped field is accepted whole by the unknown-key sweep, so the registry extension is for the published schema and the reference, not the loader.
- `packages/dartclaw_kernel/lib/src/file_guard.dart#FileGuard` – a denylist over protected paths, not a workspace allowlist, which is why `<data_dir>/feeds/` is readable by `file_read` with no new rule.
- `dev/state/LEARNINGS.md#security` – "Collapse whitespace where a one-line report is assembled": the stderr tail in a failure message is text this pipeline never authored.


## Acceptance Scenarios

- **S01 [OC01,OC02,OC03] [TI03,TI04,TI05] A shell job's fire spawns its command with only the referenced credential injected, and its stdout replaces the feed file atomically**
  - **Given** a `type: shell` entry naming an absolute `command`, `env: {FEED_TOKEN: feed-secret}` against an api-key `credentials.feed-secret`, and `output: mail.json`
  - **When** the job is run on demand through `ScheduleService.runJobNow`
  - **Then** the child sees `FEED_TOKEN` with the stored secret and does not see the server's own `*_TOKEN`/`*_API_KEY` variables, `<data_dir>/feeds/mail.json` holds the command's stdout, and the fire's logged result is a one-line summary naming the byte count and exit code
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/scheduling/schedule_service_shell_test.dart --name "writes stdout to the feed file with the injected credential visible"` – red at spec time (the suite does not exist yet)

- **S02 [OC01,OC03] [TI03,TI05] A fire that yields no usable document fails on the existing alert path and leaves the previous feed file untouched**
  - **Given** a shell job with `retry.attempts: 1` that has already written `<data_dir>/feeds/mail.json` once
  - **When** a later fire's command exits non-zero, or exits 0 having written nothing to stdout
  - **Then** each such fire is retried once, `ScheduledJobFailedEvent` is raised with a message naming the cause, and `feeds/mail.json` still holds the earlier run's bytes
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/scheduling/schedule_service_shell_test.dart --name "a failed run leaves the previous feed file intact and alerts"` – red at spec time (the suite does not exist yet)

- **S03 [OC01] [TI03] A fire that outruns `timeout_seconds` terminates the child and fails**
  - **Given** a shell job whose command sleeps past its `timeout_seconds`
  - **When** the job fires
  - **Then** the child process is terminated, no feed file is written for that run, and the fire fails with a message naming the timeout
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/scheduling/schedule_service_shell_test.dart --name "terminates a command that outruns its timeout and fails the fire"` – red at spec time (the suite does not exist yet)

- **S04 [OC02] [TI04] A shell entry whose `env` cannot be resolved to a presentable credential is not loaded, and the log names the reason**
  - **Given** `scheduling.jobs` entries whose `env` values name, respectively, an absent credentials entry, a `github-token` entry, and an entry resolving to an empty value
  - **When** the composer builds the config-declared jobs
  - **Then** none of the three is loaded, and each is logged with the reason in the shared refusal wording (`is not a configured credentials entry` / `is not an api_key credential` / `resolves to an empty value`), while a sibling valid entry loads
  - **Proof**: `packages/dartclaw_runtime/test/scheduling/scheduled_task_runner_test.dart#skips a shell job whose credential reference is unpresentable` – red at spec time

- **S05 [OC01,OC03] [TI02] A malformed shell entry is refused at parse rather than partially loaded**
  - **Given** entries with, respectively, an empty `command`, a relative `command[0]`, an `env` key that is not `^[A-Z_][A-Z0-9_]*$`, an absolute `output`, an `output` normalising outside `feeds/`, and a `delivery`/`prompt` key on a `type: shell` entry
  - **When** each entry is parsed
  - **Then** each is refused with a `FormatException` naming the offending field, so `composeConfigJobs` skips it and logs it exactly as it skips any other invalid entry
  - **Proof**: `packages/dartclaw_runtime/test/scheduling/scheduled_job_test.dart#refuses a malformed shell entry` – red at spec time

- **S06 [OC04] [TI06,TI07] Every `scheduling.jobs` write surface refuses a `type: shell` entry with a named reason, while prompt and task writes still succeed**
  - **Given** a `dartclaw.yaml` holding one `type: shell` entry and one prompt entry
  - **When** a create, update or delete touching the shell entry arrives through `ScheduleMutationService`, or a `schedule_upsert` call names the shell entry's id
  - **Then** the write is refused before any file change — `400 INVALID_INPUT` from the API and the seam, an `invalid_request` tool error — with a reason naming that shell jobs are file-only, and an unrelated prompt write in the same file still succeeds
  - **Proof**: `packages/dartclaw_runtime/test/scheduling/schedule_mutation_test.dart#refuses every write touching a shell entry` – red at spec time

- **S07 [OC04] [TI08] The Scheduling page lists a shell job as a run-only row**
  - **Given** a loaded `type: shell` job and a loaded prompt job
  - **When** the Scheduling page renders its jobs table
  - **Then** the shell row is present and badged as its kind with a Run control but no Edit or Delete control, the prompt row keeps all three, and a page edit or delete posted for the shell id surfaces the seam's refusal as an error toast
  - **Proof**: `packages/dartclaw_runtime/test/web/scheduling_page_test.dart#renders a shell job as a run-only row` – red at spec time


## Structural Criteria

- **SC01** `composeConfigJobs` stays the single builder of a config-declared job's executor: no second shell-job construction path in `runtime/scheduling_wiring.dart`, `config/scheduling_jobs_applier.dart`, or `ScheduleService`.
- **SC02** A change to a shell entry's `command`, `env`, `output` or `timeout_seconds` re-arms the loaded job on live application; an untouched entry keeps its armed timer.
- **SC03** Prompt and `type: task` entries parse and load exactly as before — no shell branch alters their fields, defaults, or refusals.
- **SC04** The published `scheduling.jobs` shape (`schemas/dartclaw.schema.json` and the generated region of `docs/guide/configuration.md`) matches `ConfigMeta.fields` after the entry-shape extension.
- **SC05** Non-shell writes are unaffected by the file-only rule: `ScheduleMutationService.removeJobs` still drops a spent one-time entry, and prompt/task create, update, delete and `schedule_upsert` still write.
- **SC06** A shell fire reports byte count, exit code and a whitespace-collapsed bounded stderr tail — never the output content, and never an injected secret value.
- **SC07** The operator guide, the runtime package rules and the changelog state the shell kind, its file-only rule, its `feeds/` location, its credential reach, and the containerized-lane limitation.


## Scope & Boundaries

### Work Areas

- `packages/dartclaw_kernel/lib/src/config_meta/agent_fields.dart` (`scheduling.jobs` entry shape) plus the regenerated `schemas/dartclaw.schema.json` and the generated region of `docs/guide/configuration.md`.
- `packages/dartclaw_runtime/lib/src/scheduling/scheduled_job.dart` — `ScheduledJobType.shell`, the shell definition value, and its parse in `ScheduledJob.fromConfig`.
- A new `packages/dartclaw_runtime/lib/src/scheduling/shell_job_runner.dart` — spawn, credential injection, timeout, bounded capture, atomic feed write, result summary.
- `packages/dartclaw_runtime/lib/src/scheduling/scheduled_task_runner.dart#composeConfigJobs` and its two callers (`runtime/scheduling_wiring.dart`, `config/scheduling_jobs_applier.dart`) — credential resolution and executor construction.
- `packages/dartclaw_runtime/lib/src/scheduling/schedule_service.dart` — `_sameDefinition` and `runJobNow`.
- `packages/dartclaw_runtime/lib/src/scheduling/schedule_mutation.dart` and `packages/dartclaw_runtime/lib/src/mcp/schedule_tools.dart` — the file-only refusal and its tool encoding, plus the `schedule_list` row.
- `packages/dartclaw_runtime/lib/src/web/pages/scheduling_page.dart` and `lib/src/templates/scheduling.{html,dart}` — the run-only shell row.
- Documentation: `docs/guide/scheduling.md`, `docs/guide/security.md`, `docs/guide/web-ui-and-api.md`, `packages/dartclaw_runtime/AGENTS.md`, `CHANGELOG.md`.

### What We're NOT Doing

- **No shell strings, no `stdin`, no streaming output** — `command` is argv and stdout is captured whole under a fixed ceiling; a shell string would put quoting and word-splitting into operator config, and streaming is a second output contract nobody asked for.
- **No guard evaluation over the command, and no PATH or environment knobs** — the entry is operator-declared config with the same trust as `credentials.*`; a guard over it would imply the command is untrusted, which it is not, and a PATH knob is a second way to decide which binary runs.
- **No `feeds/` mount convention for containerized agent lanes** — a containerized lane does not see the host data dir; this ships as a stated limitation rather than a new mount surface, because the mount is a container-isolation decision, not a scheduling one.
- **No API, page or tool form for creating a shell job** — the kind is file-only by design (OC04); adding a form would be the chat-driven command execution this rule exists to prevent.
- **No change to prompt jobs' unread `enabled` key** — recorded below as a NOTICED observation; fixing it changes the load behaviour of existing deployments' prompt jobs and needs its own change.


## Architecture Decision

**Approach**: `type: shell` is a config-declared *callback* job — the mechanism `ScheduledJob.onExecute` already runs for git sync, wiki lint and credential health — so the schedule, retry, alert, pause and on-demand machinery is reused unchanged, and only the executor is new. The executor is built inside `composeConfigJobs`, the one composer boot wiring and the live applier share, so there is exactly one construction path.
**Why this over alternatives**: a new job *type* in `ScheduleService` would fork the fire path that already carries retries and alerting; per ADR-054's carve-out the timeout, output ceiling and every refusal stay deterministic and host-side, and no model turn is involved at any point.


## Technical Overview

`ScheduledJob.fromConfig` gains a credential-free shell branch: it parses `command`, `env`, `output`, `timeout_seconds` and `enabled` into a `ShellJobDefinition` and refuses every shape error, so `SchedulingPage._liveData` — which calls `fromConfig` with no config beyond the entry — renders shell rows instead of silently dropping them. `composeConfigJobs`, which alone holds `CredentialsConfig` and the data dir, resolves each `env` value to a `credentials.<name>` secret (skipping and logging the entry when it cannot) and closes over the resolved map, the resolved output path and the timeout to build the job's `onExecute`. `ScheduleService` sees an ordinary callback job: `_executeWithRetry` applies the retry policy and raises `ScheduledJobFailedEvent` on exhaustion, and `_runJobTurn` invokes the callback with no session turn. The write-refusal lives in `ScheduleMutationService.commitAndApply`, the single point both the seam's own CRUD and the tool's merge path pass through.


## Code Patterns & External References

```
# type | path#anchor                                                              | why needed (intent)
file   | packages/dartclaw_runtime/lib/src/scheduling/scheduled_task_runner.dart#ScheduledTaskRunner.buildJobs | callback-job construction inside the composer – the shape the shell executor follows
file   | packages/dartclaw_runtime/lib/src/scheduling/schedule_service.dart#_executeWithRetry | how a thrown onExecute becomes retries then ScheduledJobFailedEvent
file   | packages/dartclaw_acp/lib/src/acp_config_parser.dart#_parseAcpCredentialReference | credential-reference refusal wording and its skip-and-warn shape
file   | packages/dartclaw_kernel/lib/src/safe_process.dart#SafeProcess.resolveEnvironment | EnvPolicy.minimal semantics – allowlist strip then extraEnvironment overlay
file   | packages/dartclaw_core/lib/src/harness/process_lifecycle.dart#killWithEscalation | SIGTERM→SIGKILL termination with a confirmed-exit result
file   | packages/dartclaw_kernel/lib/src/config_meta/agent_fields.dart#_scheduledTaskEntry | nested entry-shape declaration style for the new shell fields
file   | packages/dartclaw_runtime/test/scheduling/schedule_service_alert_test.dart#makeFailJob | failed-fire fixture shape to reuse for the shell alert scenario
file   | packages/dartclaw_runtime/test/scheduling/schedule_service_fixtures.dart#ConfigurableTurnManager | shared ScheduleService fixtures the new shell suite reuses
```


## Constraints & Gotchas

- **Critical**: `EnvPolicy.minimal` strips `*_TOKEN`/`*_API_KEY`/`*_SECRET` from the *inherited* environment and then overlays `extraEnvironment` — Must handle by: passing the resolved credential map as `extraEnvironment` and never pre-merging it into a base map, or the injected variable is stripped along with the parent's.
- **Constraint**: `secureWriteFile` takes a `String`, so stdout cannot be written as opaque bytes — Workaround: bound the raw stdout bytes at 16 MiB (`defaultProcessOutputLimitBytes`), then decode UTF-8 strictly; a non-UTF-8 or over-cap stdout fails the fire rather than being repaired or truncated (ADR-054: no repair ladders, and a cost bound stays host-side).
- **Avoid**: re-deriving the `feeds/` containment rule at both parse and compose time — Instead: decide it once in the parse against a synthetic `feeds` root (`p.isAbsolute` refusal plus `p.posix.isWithin('feeds', p.posix.normalize(p.posix.join('feeds', output)))`), and have the composer only join `<data_dir>/feeds/<output>`.
- **Critical**: `runJobNow`'s predicate is `candidate.onExecute == null`, and `ScheduledTaskRunner.buildJobs` produces config-declared callback jobs whose `jobType` is `prompt` — Must handle by: admitting on `jobType == ScheduledJobType.shell`, never on `isConfigDeclared` alone, or `auto-task-*` jobs become on-demand runnable too.
- **Constraint**: `packages/dartclaw_runtime/test/scheduling/schedule_service_test.dart` is 1175 lines against `dev/fitness`'s 1300-line per-test-file cap — Workaround: new shell execution scenarios go in `schedule_service_shell_test.dart`, reusing `schedule_service_fixtures.dart`.
- **Avoid**: spawning `/bin/sh` in tests the way `packages/dartclaw_kernel/test/safe_process_test.dart` does — Instead: spawn `Platform.resolvedExecutable` against a temp Dart script, so the suites run identically on Linux CI and macOS.

**NOTICED BUT NOT TOUCHING**: `ScheduledJob.fromConfig` never reads `enabled` for prompt jobs — only `ScheduledTaskDefinition` honours it — so a prompt entry with `enabled: false` loads and fires today. This FIS honours `enabled` for shell entries (mirroring the task behaviour) and leaves the prompt-job gap alone: closing it would change the load behaviour of existing deployments' prompt jobs and needs its own change with its own note.

**ASSUMPTION (deviation from the backlog wording, recorded deliberately)**: the backlog describes `env` as "references to `credentials.<name>` entries injected under the names the entry declares — the ACP `credential:` mechanism". This FIS instead makes `env` an explicit map of environment-variable name → credentials entry name. A credential written by `dartclaw secrets set` is stored as `CredentialEntry(apiKey:)` with an **empty** `envVars` list, so the ACP rule's fourth check (`envVars.isEmpty`, "is a literal value with no environment variable name to present it under") would refuse exactly the case this feature exists for. The other three ACP refusals are mirrored verbatim; the fourth is deliberately not applied.


## Implementation Plan

### Implementation Tasks

- **TI01** `scheduling.jobs` publishes the shell entry shape, and the generated schema and configuration reference match the registry
  - In `packages/dartclaw_kernel/lib/src/config_meta/agent_fields.dart#scheduling.jobs`, `type`'s `allowedValues` includes `shell`, and the entry gains `command` (`stringList`), `env` (`objectMap` with a `ValueEntry` string shape), `output` (`string`), `timeout_seconds` (`int_`, `min: 1`, nullable), each with a description, and `timeout_seconds`'s naming its default; regenerate with `dart run packages/dartclaw_kernel/tool/generate_config_schema.dart` then `dart run dev/tools/render_config_reference.dart`. `config_accept_set.dart` accepts an entry-shaped field whole, so no loader change is needed.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_kernel/test/config_meta_test.dart packages/dartclaw_kernel/test/config_json_schema_test.dart` – the registry and its schema projection agree with `shell`, `command`, `env`, `output` and `timeout_seconds` present
  - **SATISFIES**: SC04

- **TI02** `ScheduledJob` carries a parsed shell kind, and every malformed shell entry is refused
  - `ScheduledJobType` gains `shell`; a `ShellJobDefinition` value holds `command`, `env` (variable name → credentials entry name), `output`, `timeout` (default 300 s) and `enabled`. `ScheduledJob.fromConfig` parses it **without** `CredentialsConfig` — `SchedulingPage._liveData` calls it with the entry alone — and throws `FormatException` naming the field for: empty `command`, non-string element, relative `command[0]` (`p.isAbsolute`), an `env` key failing `^[A-Z_][A-Z0-9_]*$`, a non-string `env` value, a blank/absolute `output` or one escaping the synthetic `feeds` root, `timeout_seconds < 1`, and any of `delivery`, `prompt`, `task`, `model`, `effort`, `webhook_url`, `allowed_tools` present on a shell entry. Prompt and task parsing is untouched.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/scheduling/scheduled_job_test.dart` – each malformed shell entry throws naming its field, a valid one yields `jobType == shell` with its definition, and the existing prompt/task cases still pass
  - **SATISFIES**: S05, SC03

- **TI03** A shell job's fire spawns its command under `SafeProcess`, bounds and writes its stdout atomically into `<data_dir>/feeds/`, and fails loudly otherwise
  - New `packages/dartclaw_runtime/lib/src/scheduling/shell_job_runner.dart`: `SafeProcess.start(command[0], command.skip(1), env: EnvPolicy.minimal(extraEnvironment: resolvedSecrets), workingDirectory: dataDir)`; stdout accumulated as bytes under `defaultProcessOutputLimitBytes` and decoded UTF-8 strictly; stderr kept as a whitespace-collapsed bounded tail for the failure message; `killWithEscalation` on timeout. Exit 0 creates the output's parent directories and writes through `secureWriteFile(..., restrictPermissions: true)`, returning `wrote <N> bytes to feeds/<output> (exit 0)`. A non-zero exit, a timeout, an over-cap or non-UTF-8 stdout, a write failure, **and an exit-0 run whose stdout is empty** all **throw** so `_executeWithRetry` owns the retry and the alert; no partial, empty or stale-overwriting file is written on any of them. Zero bytes is the same class as over-cap and non-UTF-8 — the command produced no document — and silently replacing a good feed with an empty file would give the agent an authoritative-looking empty answer with no alert; a legitimately empty payload is still `[]` or `{}`, not zero bytes.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/scheduling/schedule_service_shell_test.dart` – injected variable visible to the child and parent `*_TOKEN` absent, stdout lands at `<data_dir>/feeds/<output>`, a non-zero exit and an exit-0 empty stdout each leave the previous file's bytes and raise `ScheduledJobFailedEvent` after their retries, a sleeping command is terminated and the fire fails, and no logged result carries the output content
  - **SATISFIES**: S01, S02, S03, SC06

- **TI04** `composeConfigJobs` is the one builder of a shell job's executor, resolving its credentials for boot and live apply alike
  - `composeConfigJobs` takes `credentials` and `dataDir`; both callers (`runtime/scheduling_wiring.dart`, `config/scheduling_jobs_applier.dart`) already hold a full `DartclawConfig` and pass `config.credentials` / `config.server.dataDir`. Each `env` value resolves through the entry's `isApiKeyCredential` / `isPresent` checks, mirroring `_parseAcpCredentialReference`'s first three refusal phrases; an unresolvable reference (or `enabled: false`) logs and skips that entry only. The resulting closure calls TI03's runner. No second construction path anywhere.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/scheduling/scheduled_task_runner_test.dart` – unknown, `github-token` and empty credential references each skip their entry with the named reason while a sibling valid shell entry loads with an `onExecute`
  - **SATISFIES**: S01, S04, SC01

- **TI05** `ScheduleService` re-arms and runs a shell job like any other config-declared job
  - `_sameDefinition` compares the shell definition (command, env, output, timeout, enabled) so any change re-arms and an untouched entry keeps its timer; `runJobNow` admits a candidate whose `jobType == ScheduledJobType.shell` alongside the existing `onExecute == null` arm, leaving built-ins and `auto-task-*` callback jobs refused. Depends on TI02's `ShellJobDefinition` and TI04's composed job.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/scheduling/schedule_service_shell_test.dart --name "live application"` – a changed command re-arms the job, an unchanged list leaves it armed, `runJobNow` returns `started` for a shell job and `notFound` for a built-in callback job
  - **SATISFIES**: S01, S02, SC02

- **TI06** `scheduling.jobs` writes are file-only for shell entries, refused by one authority before any file change
  - `ScheduleMutationService.commitAndApply` compares the `type: shell` entries in the freshly-read file against those in the proposed list and throws a typed refusal on any difference — added, removed, or changed — so the seam's `createJob`/`updateJob`/`deleteJob` and the `schedule_upsert` tool's merge path are both covered by the same check. `_write` maps it to `_refused(400, 'INVALID_INPUT', 'Shell jobs are file-only: edit scheduling.jobs in dartclaw.yaml', …)`. `removeJobs` calls `commit`, not `commitAndApply`, and stays unaffected.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/scheduling/schedule_mutation_test.dart` – create, update and delete touching a shell entry each refuse `400 INVALID_INPUT` with the file-only reason and leave the file byte-identical, while a prompt create in the same file succeeds and `removeJobs` still drops a spent one-time entry
  - **SATISFIES**: S06, SC05

- **TI07** The MCP schedule tools surface the write refusal and report shell entries as non-editable
  - `ScheduleUpsertTool` maps TI06's typed refusal to `toolError('invalid_request', …)` beside its existing `StateError`/`FileSystemException` arms — an upsert naming an existing shell id therefore refuses through the one authority rather than a second check; the tool's `type` enum stays `prompt|task`, so `type: shell` already fails argument validation. `ScheduleListTool` reports a shell row with `type: shell` and `editable: false`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/mcp/schedule_tools_test.dart` – an upsert on a shell id returns `invalid_request` with the file-only reason and writes nothing, `type: shell` fails argument validation, `schedule_list` reports the shell row as `editable: false`, and a prompt upsert still writes
  - **SATISFIES**: S06, SC05

- **TI08** The Scheduling page shows a shell job as a run-only row
  - `SchedulingPage._liveData` carries the parsed kind into its row map (it already routes non-task jobs into `jobs`, and TI02 makes the parse succeed so the row is no longer dropped); `templates/scheduling.dart#schedulingJobsFragment` sets a shell flag that renders a kind badge beside the name — the existing `isSystem` badge is the pattern — and suppresses Edit and Delete while keeping Run, so the table keeps its five columns. The page's `_save`/`_delete` need no branch: they render TI06's refusal as an error toast through `_tableResult`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/web/scheduling_page_test.dart` – the rendered table contains the shell row with a Run control and no edit or delete control, the prompt row keeps all three, and a delete posted for the shell id answers with the refusal message
  - **SATISFIES**: S07

- **TI09** Operator docs, package rules and the changelog describe shell jobs, their file-only rule and their credential reach
  - `docs/guide/scheduling.md` gains a *Shell jobs* section (a `hey … --json` example writing `feeds/mail.json`, the `feeds/` location, the file-only rule, that a hand edit is applied at restart because the `scheduling` section is restart-tier, the `timeout_seconds` default, that a command producing no output fails the fire rather than replacing the feed, and the containerized-lane limitation); `docs/guide/security.md` gains a short paragraph beside *Named Credential Storage* stating the command is operator-declared config with `credentials.*` trust, that no guard runs over it, and that the secret reaches only the child; `docs/guide/web-ui-and-api.md`'s `schedule_upsert` / `schedule_list` rows name the refusal; `packages/dartclaw_runtime/AGENTS.md` gains the composer and file-only-seam bullets; `CHANGELOG.md` § Unreleased records the feature under 0.25.2.
  - **Verify**: `cmd: rg -q '^### Shell jobs' docs/guide/scheduling.md && rg -q 'feeds/' docs/guide/scheduling.md && rg -q 'timeout_seconds' docs/guide/scheduling.md && rg -q 'file-only' docs/guide/web-ui-and-api.md && rg -q 'file-only' packages/dartclaw_runtime/AGENTS.md && rg -q 'type: shell' docs/guide/security.md && rg -q 'type: shell' CHANGELOG.md` – each surface is asserted separately (`rg -q` over two paths passes on either one), and every clause fails on the pre-change tree: the guide names the kind, its `feeds/` location and its timeout default, the API reference and the package rules both name the file-only rule, and the security guide and changelog both name the kind
  - **SATISFIES**: SC07

### Testing Strategy

- Layer 2 for execution: spawn a real child through `Platform.resolvedExecutable` running a temp Dart script (print to stdout, exit with a chosen code, sleep past a timeout), never `/bin/sh` — that is what keeps the suite identical on Linux CI and macOS. Per-test temp dirs for the data dir; never assign `Directory.current`.
- Layer 1 for `ScheduledJob.fromConfig` refusals and Layer 3 for the seam, tool and page surfaces, reusing `schedule_service_fixtures.dart` and `schedule_service_alert_test.dart`'s failed-fire fixture shape.
- Assert the *absence* of a parent secret in the child's environment by exporting a `DARTCLAW_TEST_TOKEN` in the test process and having the script report its own environment — asserting only the injected variable's presence would leave the strip unpinned.

### Execution Contract

- TI02 before TI03/TI04 (they consume `ShellJobDefinition`); TI03 before TI04 (the composer closes over the runner); TI06 before TI07 (the tool maps the typed refusal TI06 introduces).
- Re-run `dart run dev/tools/embed_assets.dart` after the template edit in TI08, and `dart format --line-length=120 --output=none --set-exit-if-changed .` before declaring the change done.


## Implementation Observations

_No observations recorded yet._
