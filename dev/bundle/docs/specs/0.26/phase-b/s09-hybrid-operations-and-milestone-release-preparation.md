# FIS: Hybrid Operations and Milestone Release Preparation

**Plan**: dev/bundle/docs/specs/0.26/phase-b/plan.json
**Story-ID**: S09

_Commands and public paths run from `../dartclaw-public/` unless stated otherwise. S06, S07 and S08 must be accepted
before implementation. Phase A remains retained at public checkpoint `007ab8d48220f07b429f647a3d23dc802bc82141` with
all 17 successful receipts; no earlier story receipt substitutes for the final combined A+B evidence._

## Feature Overview and Goal

**Intent**: Let operators and contributors run, explain and prepare the shipped hybrid-search milestone from current
public guidance while preserving one auditable boundary between story-local preparation and final release acceptance.

**Expected Outcomes**:

- [OC01] Public guidance lets an operator acquire the verified local model, enable and recover both hybrid corpora,
  inspect their status and rankings, switch models, and deliberately configure an HTTP embedding endpoint.
- [OC02] Architecture, ADR, glossary and comparison records describe one local-first retrieval design with separate
  lexical/vector stores, explicit PostgreSQL administration, bounded provenance, and QMD still working while deprecated.
- [OC03] The 0.26.0 version pins, release record and milestone state form a truthful release candidate that remains
  explicitly pending combined verification, remote CI/ruleset checks, tagging and publication.
- [OC04] One machine-readable obligation manifest preserves every deferred Phase A command and owner, adds every Phase
  B and release gate, and defines evidence that can accept the combined tree without replaying heavy gates per story.

## Required Context

- `docs/specs/0.26/phase-b/plan.json#sharedDecisions` – exact configuration, provider, diagnostic, packaging,
  evaluation and final-verification ownership; no parallel command, endpoint, model-identity or evidence surface.
- `docs/specs/0.26/phase-b/prd.md#fr8-configuration-and-operator-guidance` – the operator journey, generated config
  surfaces, release preparation and complete combined A+B acceptance seed this story must cover.
- `docs/specs/0.26/phase-b/s05-runtime-activation-for-memory-and-conversations.md#pinned-configuration-and-downstream-surface`
  – exact four embedding keys, provider values, managed local model path, count readers and status fields to document.
- `docs/specs/0.26/phase-b/s06-retrieval-inspection-and-turn-source-provenance.md#pinned-operator-and-trace-surface`
  – exact root CLI, authenticated inspection endpoint, response/error shapes and retained `sourceLocators` contract.
- `docs/specs/0.26/phase-b/s07-native-packaging-and-platform-proof-harness.md#pinned-final-gate-interface` – exact four
  selected native-runner commands and JSON evidence contract the combined manifest must retain verbatim.
- `docs/specs/0.26/phase-b/s08-sealed-retrieval-evaluation-harness.md#pinned-evaluation-contract` – the only full
  held-out command, output paths and acceptance assertions; the command remains unrun until the final combined gate.
- `docs/specs/0.26/deferred-live-platform-proofs.json:1` – all 19 Phase A owner/command pairs and their pending status;
  the combined manifest must preserve every pair, with any deduplication justified by explicit coverage mapping.
- `docs/specs/0.26/s09-language-aware-postgresql-memory-and-kg-search.md#constraints--gotchas` – existing lexical
  stemming/tokenization distinctions and PostgreSQL live suites that remain part of combined acceptance.
- `docs/specs/0.26/s12-operator-and-developer-documentation.md#feature-overview-and-goal` – the landed Phase A guide,
  architecture, glossary and roadmap baseline that Phase B extends rather than restates under another owner.
- `../dartclaw-public/dev/guidelines/RELEASE_PREPARATION.md#release-preparation` – version pins, pre-tag gates,
  non-publishing dry run, evidence limits and the exact consolidate-before-prune sequence.
- `../dartclaw-public/dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md#ci-equivalent-gate` – canonical build, format,
  analysis, workspace-test, PostgreSQL-contract, architecture, fitness and whitespace commands.
- `../dartclaw-public/dev/state/PRODUCT.md#proportionality` – prototype scale and one-authority rule exclude a second
  release orchestrator, search service, model manager or persistent evidence database.
- `../dartclaw-public/dev/adrs/050-native-hybrid-search.md#decision` – local-first provider, explicit HTTP escape hatch,
  derived vectors, frozen fusion and QMD's deprecate-then-remove window.
- `../dartclaw-public/dev/adrs/056-package-topology-consolidation.md#amendment-2026-08-22--the-tier-order-replaces-the-per-edge-tables`
  – package count/tier authority that must admit the S01-approved search package without restoring per-edge tables.
- `docs/DEVELOPMENT-PROCESS.md#spec-lifecycle--the-prd-is-the-sole-surviving-record` – private PRD consolidation,
  unfinished-work moves and pruning rules that apply only after the actual combined result passes.

## Deeper Context

- `docs/specs/0.26/phase-b/s02-sqlite-and-postgresql-vector-projections.md#pinned-downstream-api` – separate retained
  SQLite `vectors.db`, two PostgreSQL vector tables and administrator-provisioned pgvector ordering.
- `docs/specs/0.26/phase-b/s03-native-and-http-embedding-providers.md#pinned-consumer-surface` – verified local model,
  Gemma prefixes, generic HTTP raw-input contract, model fingerprints and bounded lifecycle behavior.
- `docs/specs/0.26/phase-b/implementation-context.md#prepared-pgvector-verification-environment` – prepared PostgreSQL
  16/pgvector 0.8.6 environment and least-privilege runtime role; preparation is not a live pass.
- `../dartclaw-public/dev/adrs/004-vector-search-approach.md#decision` – superseded QMD design whose implementation
  remains functional during the 0.26 deprecation window.
- `../dartclaw-public/docs/guide/search.md#memory-search` – current FTS5/QMD/PostgreSQL/conversation guidance to
  reshape around hybrid operation without erasing lexical distinctions.
- `../dartclaw-public/docs/guide/postgresql.md#provisioning` – existing administrator/runtime-role split to extend
  with `CREATE EXTENSION vector` in `public` and least-privilege runtime use.
- `../dartclaw-public/dev/state/UBIQUITOUS_LANGUAGE.md#knowledge--memory` – current search vocabulary and changelog row
  shape; new terms must name authority and avoid using bare “model” or “backend”.
- `docs/specs/feature-comparison.md#memory-system` – private competitive record whose QMD and hybrid rows must reflect
  the completed built-in path without rewriting shipped history.

## Acceptance Scenarios

- **S01 [OC01] [TI01] The local operator journey uses one verified managed model and both corpus controls**
  - **Given** FTS is active by default and the verified local artifact may be absent, corrupt or already present
  - **When** an operator follows the public search, configuration and CLI guidance to acquire and enable hybrid search
  - **Then** the docs use only `dartclaw search download-model`, the pinned default filename under
    `<data_dir>/models`, `search.backend: hybrid` and `search.embedding.provider: local`; they explain checksum reuse,
    startup/query degradation, separate memory/conversation unembedded counts, bounded `search inspect` for each
    corpus, the existing `rebuild-index` recovery path, and the timed-out-provider restart boundary without suggesting
    an arbitrary GGUF path, automatic download, hidden retry or ranking/dimension/timeout setting

- **S02 [OC01,OC02] [TI01,TI02] HTTP model selection is explicit and discloses its trust boundary**
  - **Given** an operator wants a local HTTP outpost or a cloud embedding service instead of the verified native model
  - **When** they configure `provider: http`
  - **Then** guidance requires an explicit absolute endpoint and non-empty model, permits an optional generic API-key
    credential reference, says query and document text leave DartClaw for that endpoint, and states that the endpoint
    owns model-specific preprocessing under the OpenAI-compatible raw `input` contract; DartClaw applies no
    EmbeddingGemma prefixes or model-name heuristics, logs/serializes no secret, and never selects HTTP automatically

- **S03 [OC01,OC02] [TI01,TI02] Storage, diagnostics, lexical behavior and QMD status agree across guides**
  - **Given** either SQLite or PostgreSQL storage and any supported `fts5`, `hybrid` or deprecated `qmd` search backend
  - **When** an operator reads setup, inspection, rebuild and failure guidance
  - **Then** SQLite names replaceable `search.db` and separate retained `vectors.db`; PostgreSQL names two
    corpus-specific vector tables, requires an administrator to install pgvector in `public`, and keeps the runtime
    role non-superuser and least-privilege; FTS-only PostgreSQL needs no extension; the guide distinguishes SQLite
    token matching, PostgreSQL stemming and semantic embedding matches, explains status/inspection/rebuild for both
    corpora, and marks QMD deprecated but still working until the following milestone removes it

- **S04 [OC02] [TI02] Contributor records describe one current hybrid-search architecture**
  - **Given** a contributor traces package tiers, search/storage ownership, configuration, diagnostics and turn traces
  - **When** they read the affected architecture docs, ADR-004, ADR-050, ADR-056, state glossary/decision/stack records
    and private feature comparison
  - **Then** every surface agrees on the 13-package tier graph, local/HTTP provider boundary, frozen weighted RRF,
    separate corpus projections, backend-specific vector storage, bounded source locators, QMD deprecation window and
    exact configuration/inspection ownership; architecture “Current through” markers name the shipped 0.26 scope,
    ADR-004/050/056 statuses/amendments no longer describe Phase B as future, and no superseded package or sqlite-vec
    mechanism is presented as current

- **S05 [OC03] [TI04] Version and release records form a truthful unaccepted 0.26.0 candidate**
  - **Given** S01–S08 are accepted but combined live/platform/held-out/UI evidence has not yet passed
  - **When** release preparation updates the lockstep version pins, generated schema, CHANGELOG, private/public roadmap
    and architecture markers
  - **Then** every enforced pin is `0.26.0`, the top heading is `## [0.26.0] - Unreleased`, the release record names
    hybrid search, two corpora, local/HTTP trust posture, native packaging, diagnostics and QMD deprecation, and both
    roadmaps say release candidate or combined verification pending; none claims a tag, release, remote CI/ruleset,
    publication, held-out pass, platform pass or combined acceptance

- **S06 [OC04] [TI03,TI04] The combined manifest is complete before any heavy acceptance run**
  - **Given** the 19 Phase A deferred entries, S07's four exact platform commands, S08's one sealed command, current
    build/release guidance and all integrated A+B implementation
  - **When** S09 prepares the machine-readable manifest and story-local checks finish
  - **Then** every original owner and command is retained; additional obligations cover both binary builds, full
    workspace and integration suites, zero-warning analysis, format, architecture/fitness/config-reference drift,
    PostgreSQL security/contracts, native packaging/failure evidence, held-out evaluation, container conformance on
    Linux Docker and Docker Desktop/OrbStack, workflow component/live coverage, UI smoke with screenshots, version and
    release-doc checks, and independent combined code/gap/security reviews; each entry names the exact command or
    evidence predicate, execution environment, owners, status and receipt path, starts pending, and permits one result
    to cover another entry only through an explicit coverage list; story completion executes none of those heavy gates

## Structural Criteria

- **SC01** The public operator contract contains exactly the four `search.embedding.*` keys from S05 and the existing
  `database.fts_language`; it introduces no model path/checksum, fingerprint, dimension, fusion, candidate, timeout,
  retry, corpus-selector or vector-database setting.
- **SC02** Public docs, examples, generated config and prepared evidence contain no DSN, API-key value, raw query or
  document body, vector, absolute private-cache path, or claim that external HTTP embedding stays inside the host.
- **SC03** Contributor docs keep one owner per concern: canonical projections and lexical identity authenticate
  results, `dartclaw_search` owns provider/fusion/synchronization, core owns concrete vector stores, runtime owns
  composition, and the existing CLI/API/trace surfaces own presentation and provenance.
- **SC04** The combined manifest is preparation rather than evidence: every executable obligation begins pending and
  only an actual zero-exit command plus its acceptance predicate, or the named review/screenshot/platform evidence,
  can satisfy it; skipped, absent, mock-only, historical or differently scoped evidence cannot become a pass.
- **SC05** Private `docs/specs/0.25.2/prd.md` remains byte-identical to its S09-start snapshot, including unrelated
  in-progress work, and neither release preparation nor later 0.26 consolidation traverses into that directory.

## Scope & Boundaries

### Work Areas

- Public search, PostgreSQL, security, configuration and CLI operator guidance plus generated config reference.
- Public architecture, ADR-004/050/056, glossary, decisions, stack and current-through markers.
- Private feature comparison and private/public 0.26 roadmap alignment.
- Complete transient 0.26 combined-verification manifest and final evidence acceptance contract.
- Lockstep 0.26.0 pins, generated schema, CHANGELOG and local release-candidate preparation.
- Existing generated/config/version/architecture gates plus bounded task-local documentation and manifest checks.

### What We're NOT Doing

- Running live PostgreSQL/pgvector, native platform, held-out retrieval, full workspace/fitness/integration, container,
  workflow-live or UI screenshot gates during S09 completion – root runs the combined campaign once afterward.
- Publishing a release, pushing, merging to `main`, tagging, editing repository rulesets or claiming remote CI – these
  external actions remain explicitly unrun under the authorized scope.
- Removing QMD – 0.26 warns while the existing implementation still works; removal belongs to the following milestone.
- Adding search behavior, configuration knobs, release flavors, a second evidence service or permanent milestone
  database – S01–S08 and existing release tooling supply all runtime and build behavior.
- Consolidating/pruning the 0.26 private specs or removing the public export before the actual combined result passes –
  lifecycle cleanup consumes accepted evidence and cannot be a story-local preparation check.

## Architecture Decision

**Approach**: Extend existing public guides/state/release records and carry one transient combined-verification manifest
whose entries point at the shipped command/evidence owners; keep execution receipts outside the product and specs.
**Why this over alternatives**: A new release orchestrator or persisted evidence store would duplicate current scripts
and root orchestration, while prose-only checklists cannot prove that every deferred obligation received real evidence.

## Technical Overview

S09 has two boundaries. Story implementation makes the shipped contract discoverable, aligns architecture/state,
pins 0.26.0 and prepares one complete pending manifest. Story completion runs only focused checks over those artifacts.
Root then freezes the integrated A+B tree and executes the manifest once, retaining command exits, non-skipped counts,
platform JSON, held-out report/checksums, review verdicts and UI screenshots in a run-owned evidence directory. Missing
or failing evidence blocks acceptance without changing frozen settings. Only an accepted evidence set unlocks private
PRD consolidation, spec/export pruning and the release-ready roadmap transition.

## Code Patterns & External References

```text
# type | path#anchor | why needed
file | docs/guide/search.md#Memory Search | primary hybrid/QMD/lexical operator narrative
file | docs/guide/postgresql.md#Provisioning | administrator and least-privilege runtime-role guidance
file | docs/guide/configuration.md#Core Config | generated embedding configuration reference
file | docs/guide/cli-reference.md#rebuild-index | existing rebuild command and JSON/human output owner
file | dev/architecture/data-model.md#Storage Mechanisms | authoritative versus lexical/vector derived stores
file | dev/architecture/system-architecture.md#Package Structure | 13-package tier graph and runtime composition
file | dev/architecture/configuration-architecture.md#Section Config Classes | exact embedding config owner and restart tier
file | dev/architecture/cli-api-architecture.md#Command Structure | root-only search family and connected inspection command
file | dev/architecture/observability-operations-architecture.md#Turn Traces | diagnostics/counts and source-locator persistence
file | dev/tools/check_versions.sh#main | enforced version, packaging and CHANGELOG pins
file | dev/tools/release_check.sh#main | local/remote release-preparation boundary
```

## Constraints & Gotchas

- Treat S05's managed local artifact as the only native model contract. “Switch model” means configure explicit HTTP
  endpoint/model/optional credential, not an arbitrary local filename or checksum.
- Keep the HTTP disclosure precise: DartClaw sends raw `input`; the configured endpoint owns preprocessing. Only the
  native provider uses the frozen EmbeddingGemma query/document prefixes and includes that convention in its fingerprint.
- PostgreSQL pgvector is optional derived-search infrastructure. Administrator installation occurs in `public`; runtime
  SQL qualifies vector types/functions/operators while using the application schema and a non-superuser role.
- Preserve all 19 Phase A manifest owner/command pairs exactly. Do not collapse commands because their paths overlap;
  deduplicate only when one recorded result demonstrably executed the same/superset command and lists covered IDs.
- The authoring inventories under private `.agent_temp/0.26-execution/` are preparation facts only. The committed or
  exported manifest must derive its commands from current FIS, tests and release docs and must not depend on those files.
- Held-out assets, settings, judgments and tolerances stay sealed through story implementation. S09 prepares their exact
  command but does not run it, inspect scores or retune after any later failure.
- Current local preparation can establish no remote CI, required-ruleset, tag or publication result. Record those as
  external/unrun instead of coercing them into failures or passes.

## Implementation Plan

### Implementation Tasks

- **TI01** Public operator guidance is sufficient for local and explicit HTTP hybrid operation
  - Extend the existing search/PostgreSQL/security/CLI/config-reference owners with S01–S03's exact commands, fields,
    trust disclosure, corpus status/inspection/rebuild recovery, lexical-versus-semantic behavior and QMD warning.
  - **Verify**: `cmd: bash -c 'set -eu; rg -q "search download-model" docs/guide/cli-reference.md; rg -q "search inspect" docs/guide/cli-reference.md; rg -q "embeddinggemma-300M-Q8_0.gguf" docs/guide/search.md; rg -q "<data_dir>/models" docs/guide/search.md; rg -q "memoryUnembeddedCount" docs/guide/web-ui-and-api.md; rg -q "conversationUnembeddedCount" docs/guide/web-ui-and-api.md; rg -qi "raw input|raw query|raw document" docs/guide/search.md; rg -qi "leaves DartClaw|sent to.*endpoint" docs/guide/search.md; rg -qi "QMD.*deprecated|deprecated.*QMD" docs/guide/search.md; rg -q "vectors.db" docs/guide/search.md; rg -qi "CREATE EXTENSION vector" docs/guide/postgresql.md; rg -qi "public.*vector|vector.*public" docs/guide/postgresql.md; for key in search.embedding.provider search.embedding.model search.embedding.endpoint search.embedding.credential; do rg -q "$key" docs/guide/configuration.md; done; ! rg -q "search\.embedding\.(path|checksum|fingerprint|dimension|timeout|retry)" docs/guide/configuration.md; dart run dev/tools/render_config_reference.dart --check; dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check'` – bounded checks prove the exact local/HTTP commands and fields, trust-boundary clause, two-corpus status, backend storage distinction, pgvector posture and still-working QMD deprecation without adding a config key or permanent prose test
  - **SATISFIES**: S01, S02, S03, SC01, SC02

- **TI02** Contributor architecture and state describe the shipped hybrid design under current names
  - Align the affected architecture docs, ADR-004/050/056, glossary, decisions/stack and private feature comparison with
    S01–S06 ownership; bump only affected current-through markers and preserve historical release statements.
  - **Verify**: `cmd: bash -c 'set -eu; dart run dev/tools/arch_check.dart; for f in dev/architecture/system-architecture.md dev/architecture/data-model.md dev/architecture/configuration-architecture.md dev/architecture/cli-api-architecture.md dev/architecture/observability-operations-architecture.md; do rg -q "^\*\*Current through\*\*: 0\.26" "$f"; done; rg -qi "superseded.*ADR-050" dev/adrs/004-vector-search-approach.md; rg -qi "0\.26.*deprecat|deprecat.*0\.26" dev/adrs/004-vector-search-approach.md dev/adrs/050-native-hybrid-search.md; rg -qi "13 packages|package count.*13" dev/adrs/056-package-topology-consolidation.md; rg -q "^\| Embedding Provider \|" dev/state/UBIQUITOUS_LANGUAGE.md; rg -q "^\| Vector Index \|" dev/state/UBIQUITOUS_LANGUAGE.md; rg -q "^\| Hybrid Search \|" dev/state/UBIQUITOUS_LANGUAGE.md; rg -q "050-native-hybrid-search" dev/state/DECISIONS.md; rg -qi "llamadart|embeddinggemma" dev/state/STACK.md; rg -qi "0\.26.*hybrid|hybrid.*0\.26" ../dartclaw-private/docs/specs/feature-comparison.md; ! rg -q "(packages/|package:)dartclaw_(storage|server|config|models|security)\b" dev/architecture/system-architecture.md dev/architecture/data-model.md dev/architecture/configuration-architecture.md dev/architecture/cli-api-architecture.md dev/architecture/observability-operations-architecture.md'` – the existing architecture gate plus bounded document checks prove the 13-package graph, provider/storage/composition/provenance owners, pgvector and QMD decisions, exact glossary/state vocabulary, current markers and private comparison rows without adding a maintained prose test
  - **SATISFIES**: S02, S03, S04, SC02, SC03

- **TI03** One pending manifest accounts for every combined A+B obligation and evidence kind
  - Create private `docs/specs/0.26/final-combined-verification.json` and its byte-equivalent public export
    `dev/bundle/docs/specs/0.26/final-combined-verification.json` from current sources. Embed the original 19-entry
    Phase A array unchanged and bind each indexed entry to its environment/receipt predicate; append S07/S08 plus all
    build, integration, security, container, workflow, UI, review, version and release-doc obligations with exact
    coverage/evidence rules. This is a transient milestone artifact, not a permanent release-ledger schema.
  - **Verify**: `cmd: bash -c 'set -eu; manifest=dev/bundle/docs/specs/0.26/final-combined-verification.json; prior=../dartclaw-private/docs/specs/0.26/deferred-live-platform-proofs.json; cmp -s ../dartclaw-private/docs/specs/0.26/final-combined-verification.json "$manifest"; jq -e --slurpfile prior "$prior" '\''.phaseA == $prior[0] and (([.evidenceBindings[] | select(.source == "phaseA") | .sourceIndex] | sort) == [range(0; ($prior[0] | length))]) and ([.evidenceBindings[] | has("environment") and has("receiptPath") and has("acceptancePredicate")] | all) and ([.obligations[] | .status == "pending-final-combined-gate"] | all) and ([.obligations[] | has("owners") and has("environment") and has("receiptPath") and has("acceptancePredicate")] | all) and (([.obligations[].category] | unique) | contains(["analysis","architecture","build","config-drift","container","docs","format","heldout","integration","native-platform","release","review","security","ui","version","workflow"]))'\'' "$manifest" >/dev/null; for target in macos-arm64 linux-arm64 linux-x64 windows-x64; do command="dart run apps/dartclaw_cli/tool/native_embedding_platform_gate.dart --target $target --evidence build/native-embedding-$target.json"; jq -e --arg command "$command" '\''([.obligations[] | select(.command == $command)] | length) == 1'\'' "$manifest" >/dev/null; done; jq -e '\''([.obligations[] | select(.command == "dart run apps/dartclaw_cli/tool/retrieval_evaluation.dart --model-path \"$DARTCLAW_TEST_EMBEDDING_MODEL\" --output-dir .agent_temp/0.26-final/retrieval-evaluation")] | length) == 1'\'' "$manifest" >/dev/null'` – structured task-local checks preserve every Phase A entry, bind all 19 receipts, require the four S07 commands and normalized S08 command exactly once, enumerate every required category/evidence field and confirm all new obligations remain pending without installing a public manifest-test owner
  - **SATISFIES**: S06, SC04

- **TI04** The integrated tree is a locally coherent 0.26.0 release candidate without an acceptance claim
  - Apply the documented lockstep pins, regenerate the versioned schema, complete the 0.26.0 CHANGELOG and align both
    roadmaps/current markers as combined-verification pending; prepare local release artifacts only through focused
    version/workflow contracts and leave lifecycle cleanup locked behind the post-story result.
  - **Verify**: `cmd: bash -c 'set -eu; bash dev/tools/check_versions.sh 0.26.0; dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check; dart run dev/tools/render_config_reference.dart --check; dart test --reporter=failures-only apps/dartclaw_cli/test/tool/release_binaries_workflow_test.dart; private_section=$(awk '\''/^### 0\.26/{p=1} p && /^### / && !/^### 0\.26/{exit} p'\'' ../dartclaw-private/docs/ROADMAP.md); public_section=$(awk '\''/^### 0\.26/{p=1} p && /^### / && !/^### 0\.26/{exit} p'\'' dev/state/ROADMAP.md); changelog_section=$(awk '\''/^## \[0\.26\.0\]/{p=1} p && /^## \[/ && !/^## \[0\.26\.0\]/{exit} p'\'' CHANGELOG.md); for section in "$private_section" "$public_section"; do printf "%s\n" "$section" | rg -qi "combined.*pending|pending.*combined"; ! printf "%s\n" "$section" | rg -qi "combined.*(passed|accepted)|held.?out.*pass|platform.*pass|Status.*release-ready|Status.*released|Status.*tagged"; done; printf "%s\n" "$changelog_section" | rg -qi "hybrid"; printf "%s\n" "$changelog_section" | rg -qi "memory.*conversation|conversation.*memory"; printf "%s\n" "$changelog_section" | rg -qi "QMD.*deprecat|deprecat.*QMD"; ! printf "%s\n" "$changelog_section" | rg -qi "held.?out.*pass|platform.*pass|combined.*(passed|accepted)"; cmp -s ../dartclaw-private/.agent_temp/0.26-final/s09-prep/0.25.2-prd.before ../dartclaw-private/docs/specs/0.25.2/prd.md'` – every enforced release pin and generated surface agrees, the existing workflow test keeps publication tag-gated, both exact 0.26 roadmap sections say combined verification pending without a premature release/platform/held-out claim, the release record names the shipped hybrid scope and QMD deprecation without claiming acceptance, and the pre-existing private 0.25.2 PRD bytes are untouched
  - **SATISFIES**: S05, S06, SC05

### Testing Strategy

- Existing schema/reference/version/workflow/architecture checks retain their current owners. Task-local `rg`, `awk`,
  `jq` and `cmp` checks cover only S09's prose, manifest and candidate-state obligations and leave no permanent suite.
- TI04 runs version/schema/reference/workflow contract checks only. It does not invoke `release_check.sh`, real builds,
  full suites, networked services, native archives/models, remote workflows or browser validation.

### Execution Contract

- Before any edit, copy private `docs/specs/0.25.2/prd.md` byte-for-byte to
  `.agent_temp/0.26-final/s09-prep/0.25.2-prd.before`; TI04 consumes that snapshot after all S09 edits.
- S06 must be accepted before TI01/TI02 bind its final CLI/API/source-locator wording. S07 and S08 must be accepted
  before TI03 copies their exact final commands; dependency acceptance is a plan gate, not a reason to invent prose.
- Run TI01–TI04 focused Verifies and the standard story fast tier. Do not run any manifest obligation whose purpose is
  combined acceptance, including the held-out asset/report mode.
- Do not commit or push the private repository. Do not push, merge, tag, publish, edit repository settings or dispatch
  remote workflows from either repository.

## Final Validation Checklist

_Root-owned after S09 story completion; these items do not belong to `complete-story`._

- Freeze one integrated A+B source revision and run multiple independent combined code/gap/security reviews against
  both 0.26 PRDs and the Phase B FIS set; remediate findings before accepting any invalidated evidence.
- Execute every pending manifest obligation once in its named environment, with targeted reruns only when a causal fix
  invalidates that result. Record exact commands, exits, non-skipped counts, revisions and explicit coverage mappings.
- Run S07's four exact native commands on macOS arm64, Linux arm64, Linux x64 and Windows x64, retaining all platform
  JSON; separately retain the broader five-target/two-binary packaging evidence without calling macOS x64 an embed pass.
- Run S08's exact held-out command only after the tree is frozen. Require exit 0, `status: pass`, 144 slice rows, zero
  violations and the artifact checksum file; never change settings, fixtures, judgments or tolerances from its result.
- Retain PostgreSQL security/contract evidence under the prepared least-privilege role, both container-engine results,
  workflow component/live results with remote GitHub publication disabled, and UI TC-01…TC-31/R-01…R-14 screenshots.
- Record remote CI/required-ruleset/release-publication actions as unrun under current authority. Local evidence does not
  satisfy or fabricate those results.
- Only after every locally executable obligation and independent review passes: consolidate the complete 0.26 cycle
  into private `docs/specs/0.26/prd.md`, including both phases and adjacent/interlude outcomes; move unfinished future
  work; prune private `docs/specs/0.26/` to `prd.md`; remove the public exported bundle; leave
  `docs/specs/0.25.2/prd.md` untouched; then mark 0.26 release-ready pending the external release sequence.

## Implementation Observations

_No observations recorded yet._
