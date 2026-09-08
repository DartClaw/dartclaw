# Draft: Broaden Config Hot Reload

**Status**: Unscheduled draft (brief). Trimmed 2026-09-03 from the former "Config & Workflow Schemas & Live Reload" draft – everything else in it has an owner now (see Disposition).
**Date**: 2026-06-03 · Trimmed 2026-09-03
**Source**: Lean Runtime Q12 extension, 2026-08-18. Competitor evidence: `../0.25/prd.md` § Decisions log (Q4).

## What is left in this draft

One item: **broadening which config sections apply without a restart** (the OpenClaw-style hybrid apply – hot-apply the safe keys, label the rest restart-required).

0.25 S59 landed *honest* reload tiers, which is a different thing. `ConfigReloadTier` in `../../../../dartclaw-public/packages/dartclaw_kernel/lib/src/config_notifier.dart` has exactly two members, `reloadable` and `restart`, and every section on `DartclawConfig` carries one, enforced by a fitness gate. The tier map is deliberately conservative: a section is `reloadable` **only while some registered service genuinely applies its changes**, and everything else is `restart`. Today that leaves `server`, `sessions`, `context`, `security` and `workspace` reloadable and the rest – `agent`, `auth`, `gateway`, `harness`, `memory`, `knowledge`, `search`, `mcpServers`, `providers`, `credentials`, `tasks`, `scheduling`, `onboarding`, `workflow` and the others – on restart. Three keys (`server.port`, `server.host`, `server.data_dir`) are non-reloadable outright.

So the labelling is truthful and the mechanism exists. What does not exist is the work of making more sections genuinely applicable at runtime, which means writing the `Reconfigurable` implementations that apply them and then moving each section's tier.

## Why it is not scheduled

Each section is its own piece of work with its own risk, and none of them is blocking anything. The honest tiers already removed the failure mode that mattered: an operator no longer edits a key, sees no error, and assumes it took effect.

If it is picked up, the shape is per-section, not a milestone: pick the sections an operator actually edits mid-run, write the `Reconfigurable` that applies each, prove it with a test that changes the value on a live instance and observes the behaviour change, then flip the tier. The fitness gate that requires a tier per section is what keeps that honest.

## Open questions

1. **Which sections earn it first.** `scheduling` already gained live application of `scheduling.jobs` without a restart in 0.25.1, so the natural candidates are the ones an operator tunes while a server is running. Needs operator input, not analysis.
2. **What "hybrid apply" means for a partially-reloadable section.** Today the tier is per section. A section where some keys apply live and others do not would need either a finer granularity or a split of the section – both are more machinery than the current two-tier model, and neither is justified yet.

## Disposition of the rest of this draft (2026-09-03)

| Former content | Where it went |
|---|---|
| Track 1 – generate `dartclaw.schema.json` from the config metadata registry | **Shipped in 0.25 (S54).** The emitter is `packages/dartclaw_kernel/lib/src/config_meta/json_schema.dart`, the generator is `packages/dartclaw_kernel/tool/generate_config_schema.dart`, the artifact is `schemas/dartclaw.schema.json` (draft-2020-12, strict, generated-only), and the drift gate runs in `dev/tools/fitness/run_all.sh`. |
| Resolved decision 3 – per-field descriptions on `FieldMeta` | **Shipped in 0.25 (S10).** Every `FieldMeta` carries a required non-empty description, and `docs/guide/configuration.md` is generated from the schema's 279 accepted leaves. |
| Distribution & versioning – the `# yaml-language-server: $schema=` modeline written by `dartclaw init`, a published rolling URL, per-minor pinned snapshots, `dartclaw config schema --out <path>` – plus open questions 1 (hosting) and 2 (version scheme) | **Moved to 0.25.1** (owner, 2026-09-03). None of it exists today; `dartclaw config` has only `show`, `get` and `set`, and the shipped schema emits no `$id` precisely because hosting and the version scheme were undecided. |
| Track 2 – `workflow.schema.json`, per-step-type discrimination via `oneOf`/`if`–`then`, CI validation against the shipped workflow YAML; resolved decision 4; open question 3 | **Moved to 0.26 as S16 and S17** (owner, 2026-09-03): `../0.26/s16-declarative-workflow-step-type-rule-source.md` and `../0.26/s17-published-workflow-json-schema-and-drift-gate.md`. Open question 3 is answered by S16. |
| Out-of-scope items (a full LSP, broadening the internal `SchemaValidator`, web UI config-editor changes) | Still out of scope; S17 restates the `SchemaValidator` boundary where it matters. |

The step-type list the old Track 2 carried (`bash, approval, aggregate-reviews, loop, map, foreach, parallel_group`) was wrong and is not carried forward: `map` and `parallel_group` are not step types – parallelism is the `parallel:` flag on a step and `map_over` is a field on a `foreach` controller. The six live types are `agent`, `bash`, `approval`, `foreach`, `loop` and `aggregate-reviews`.

## References

- `../../../../dartclaw-public/packages/dartclaw_kernel/lib/src/config_notifier.dart` – `ConfigReloadTier`, the per-section tier map, and `nonReloadableKeys`
- `../../../../dartclaw-public/packages/dartclaw_kernel/lib/src/reconfigurable.dart` – the interface a section needs an implementation of before its tier can move
- `../../../../dartclaw-public/CHANGELOG.md` § 0.25.0 – the shipped config schema, generated configuration reference, and honest reload tiers
