# ADR-059: Doctor preserves config load refusals

## Status

Accepted – 2026-09-04. The operator approved the scenario reconciliation before implementation.

## Context

Unknown configuration fields cause `_loadYaml` to throw before constructing `DartclawConfig`.
The doctor specification instead assumed they produced blocking warnings and required directory repair despite them.
The loader owns validation and directory resolution (ADR-054); doctor must not reconstruct a rejected config.

## Decision

Report a fatal loader exception as `config.valid: fail` and skip config-dependent checks and repairs.
Continue checking and repairing a loadable config even when it carries blocking warnings.
The repair scenario uses an invalid registered non-path setting instead of an unknown field.

## Alternatives considered

Scores use 1–5, with one authority weighted 50%, preserving loader behavior 30%, and repair availability 20%.

| Option | One authority | Loader behavior | Repair availability | Weighted score |
|---|---:|---:|---:|---:|
| Respect fatal loads; repair loadable configs | 5 | 5 | 3 | 4.6 |
| Add a tolerant mode to the loader | 5 | 2 | 5 | 4.1 |
| Reconstruct config paths inside doctor | 1 | 2 | 5 | 2.1 |

A tolerant mode adds a config acceptance contract solely to retain a stale fixture.
A separate doctor parser duplicates directory resolution and can repair unintended paths.

## Consequences

An operator must fix unknown fields before doctor can inspect or create instance directories.
A loadable invalid setting remains a failure after directory repair; YAML bytes do not change.
No loader changes or additional parsing authority are required.

## Evidence

- `packages/dartclaw_kernel/lib/src/config_parser.dart`: `_loadYaml` rejects the acceptance sweep before returning.
- `packages/dartclaw_kernel/test/config_accept_set_test.dart`: 17 tests passed, including unknown-field refusal.
- `packages/dartclaw_kernel/test/providers_config_test.dart`: invalid registered auth values yield blocking warnings.
- Approved scenario text: `.agent_temp/doctor-spec-reconciliation.md`.
