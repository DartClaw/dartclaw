# DartClaw 0.27.2 – align with AndThen 1.0 rc.4

> **Source**: AndThen `feat/1.0.0-rc.4` – ADR-024 (skill names `plan`/`exec-plan`, story statuses), ADR-025 (`decide` skill), ADR-018 (one plugin), CHANGELOG `[1.0.0-rc.4]`. Inventory of `dartclaw-public` `feat/0.27.2` at `5f5bfbc9` (2026-10-02); every line number below is as of that commit.

## Problem

`5f5bfbc9` already moved the built-in workflows to AndThen rc.4: the `andthen:plan`/`andthen:exec-plan` names, discover rules 6 and 7, the validator hint, and the `spec-ready` fixtures. What is left:
- the maintainer custom workflows call `andthen-some:council`, which ADR-018 retired, so their preflight fails on any install without the old satellite plugin;
- `spec-and-implement` is named for a skill that no longer exists;
- prose, docs, and tests still name retired skills and the old `skipped` semantics.

## Outcome

DartClaw 0.27.2 runs every built-in and maintainer custom workflow against AndThen 1.0 rc.4 with no reference to a retired skill, and its docs describe what the workflows do.

## Decisions (settled with the maintainer, 2026-10-02)

- **D1 – `spec-and-implement` becomes `story-and-implement`.** Removing it was weighed and rejected: `plan-and-implement` fails fast without a PRD, while this workflow takes an inline description or an existing FIS. The new name pairs with `plan-and-implement` (several stories) as the one-story path. Its `spec` step keeps steering `andthen:plan` to one story ("Write one FIS for a single story."). The `spec` step id, the `spec_path`/`spec_source` outputs, and the `dartclaw-discover-andthen-spec` skill keep their names, because they name the FIS, which AndThen still calls a spec. No alias: the maintainer is the only user.
- **D2 – remove the council steps** from the maintainer customs. AndThen maps the retired council to the Findings Filter already inside `review`.
- **D3 – "Requires AndThen 1.0"**, stated in the CHANGELOG and the skills guide. No build pin and no preflight version check.
- **D4 – `--no-full-tier`** replaces the prose that asks for the same thing in the inline plan workflow.

## Changes

### Workflows
- **C1 – rename `spec-and-implement` to `story-and-implement`** (D1): the definition file, its `name:` and user-visible `description` (`spec-and-implement.yaml:1-4`, which also says `exec-spec`), the `exec-spec` mentions at `:75` and `:99`, the custom `spec-and-implement-inline.yaml`, `dev/tools/dartclaw-workflows/spec.sh`, registry, tests, and docs. Sweep every bare name, not only invocations, because a rename sweep keyed on invocations misses prose (about 51 files carry the name).
- **C2 – remove the `andthen-some:council` steps** (D2) from `.dartclaw/workflows/custom/spec-and-implement-inline.yaml:111-140`, `plan-and-implement-inline.yaml:200-231`, and `review-and-remediate-inline.yaml:91-123` (header `:6`), and drop them from each `aggregateReviews` (`:140`, `:231`, `:123`). Update `test/workflow/built_in_workflow_contracts_test.dart:609-610` (inline step lists) and remove the council test at `:752-775`.
- **C3 – `--no-full-tier`** (D4) on the per-story `andthen:exec-plan` step in `plan-and-implement-inline.yaml:111-116`, replacing the prose. The built-in per-story step keeps the full tier.

### Discover skill
- **C4 – `dartclaw-discover-andthen-plan/SKILL.md:42` and `:77`** still describe closed or skipped stories as pruned. Only `done` entries are pruned now, and rule 9's empty catalog also covers stories blocked behind a `skipped` one. Reword to "done entries removed" and "no story left to run".

### Docs
- **C5 – `docs/guide/andthen-skills.md:5`** says AndThen split into two plugins, that `andthen:architecture` offers `advise` and `trade-off`, and that review moved to `andthen-some:architecture-analysis`. Replace it: AndThen ships as one plugin, `andthen`, the workflows use only its core skills, and DartClaw requires AndThen 1.0 (D3). Note there that `andthen:exec-plan` now runs `andthen:simplify-code` once when a plan's last story completes, inside the implement step, so every `story-and-implement` run pays for one pass.
- **C6 – `docs/guide/workflows.md`**: the resume rule at `:609` and `:993` adds that dependents of a `skipped` story are omitted; replace the `andthen-some:council` example at `:279-292`; `:1062` may read "FIS or plan".
- **C7 – council comments**: `plan-and-implement.yaml:222-224`, `spec-and-implement.yaml:122-124`, `packages/dartclaw_workflow/CLAUDE.md:62`, `dev/tools/dartclaw-workflows/README.md:23`, `dev/tools/dartclaw-workflows/review.sh:4`.
- **C8 – `dev/state/DECISIONS.md:4,8,141`**: the maintenance comments name `andthen:architecture` in `--mode trade-off` as the ADR writer. It is the `andthen:decide` skill now.
- **C9 – `dev/state/LEARNINGS.md:170`** names `validateStorySpecsContract(completedStoryIds:)`, which does not exist, and says `skipped` deps are pruned. Correct both or delete the bullet.
- **C10 – maintainer process docs**: `CLAUDE.md:49,53,60-65,78,86`, `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md:225`, `dev/state/LEARNINGS.md:5` call `andthen:ops` and `andthen-some:*` and describe the retired `dartclaw-*` branded install. Point them at current skills.
- **C11 – `CHANGELOG.md`**: a `[0.27.2]` section: built-ins call `andthen:plan`/`andthen:exec-plan`; `skipped` stories block their dependents; `spec-and-implement` is renamed `story-and-implement`; the council steps are gone from the maintainer customs; requires AndThen 1.0.

### Tests and fixtures
- **C12 – stub skill lists** in `packages/dartclaw_runtime/test/runtime/server_builder_integration_test.dart:40-47`, `service_wiring_andthen_skills_test.dart:137-144`, and `headless_runtime_test_support.dart:338-346` list `andthen:plan` twice and still name `andthen:prd`, `andthen:quick-review`, and (first file) `andthen:ops`. Dedupe and trim to shipped skills.
- **C13 – `test/fixtures/s-plan-json-adoption-sample-plan.json:11,238`** prose says `spec-ready`, `dartclaw-exec-spec`, `andthen-ops`. Cosmetic.
- **C14 – descriptive strings** naming `exec-spec`: `test/workflow/built_in_workflow_contracts_test.dart:400`, `prompt_augmenter_test.dart:274`.

## Done when

- DartClaw's fast tier (`dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md`) passes.
- Outside the records – `CHANGELOG.md` history and `dev/adrs/` – `rg` over `dartclaw-public` finds none of: `andthen-some:`, `andthen:ops`, `andthen:prd`, `andthen:quick-review`, `exec-spec`, `spec-and-implement`, `spec-ready`, `--mode trade-off`.
- With the installed AndThen plugin refreshed to `feat/1.0.0-rc.4` or later (the cached `88510fac` build predates the rename), one live run each of:
  - `story-and-implement` with a terse one-line FEATURE. rc.4 `plan` routes a source too thin to draft Intent from toward `clarify`; under `--auto` the `spec` step must still write a FIS or fail loudly, never pass with an empty `spec_path`. Note the implement step's duration with the simplify pass in it.
  - `plan-and-implement` on a small PRD.
  - one maintainer custom (`*-inline`) workflow, proving preflight passes without the council skill.

## Not in this change

Noticed during the inventory, outside rc.4 alignment:
- `plan-and-implement.yaml:83-86,115-118` declare a `technical_research` output AndThen stopped producing in 0.17.0.
- `plan.md` is still in the `plan` path patterns and discover rule 4; AndThen reads and writes only `plan.json`.
- `dev/state/STACK.md:94` and `docs/guide/agents.md:418` use pre-0.19 skill names and the retired provisioning model.
- `code-review.yaml:49-52` passes `branch=`/`pr=`/`base=` pairs `andthen:review` does not define; it takes a PR URL or `PR <n>`.
