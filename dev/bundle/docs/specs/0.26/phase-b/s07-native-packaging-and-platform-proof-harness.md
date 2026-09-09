# FIS: Native Packaging and Platform Proof Harness

**Plan**: dev/bundle/docs/specs/0.26/phase-b/plan.json
**Story-ID**: S07

_Authored against public `3396754b6501` on `feat/0.26`; commands and `packages/...` paths run from
`../dartclaw-public/`._

## Feature Overview and Goal

**Intent**: Make the built-in native embedder a reproducible part of both release archives and give final release
acceptance direct evidence that supported packages load, embed and terminate safely on their native platforms.

**Expected Outcomes**:

- [OC01] Every native archive used by a release build matches a committed version, size and SHA-256 before the
  llamadart hook can consume it, including in a network-disabled build from a supplied cache.
- [OC02] The existing `dartclaw` and `dartclaw-workflow` archives remain one all-in flavor and carry the same selected
  llamadart native libraries beside their binaries, in addition to the existing bundled SQLite library.
- [OC03] Final acceptance receives machine-readable evidence from macOS arm64, Linux arm64, Linux x64 and Windows x64
  that the real AOT provider loads the verified model, embeds cold and warm inputs, disposes within bounds, and exits
  after success and representative failures.

## Pinned Final-Gate Interface

S09 invokes one command on each matching native runner after setting `DARTCLAW_NATIVE_ARCHIVE_CACHE` to a directory
containing the pinned upstream archives and `DARTCLAW_EMBEDDING_MODEL_PATH` to the verified model:

```text
dart run apps/dartclaw_cli/tool/native_embedding_platform_gate.dart --target macos-arm64 --evidence build/native-embedding-macos-arm64.json
dart run apps/dartclaw_cli/tool/native_embedding_platform_gate.dart --target linux-arm64 --evidence build/native-embedding-linux-arm64.json
dart run apps/dartclaw_cli/tool/native_embedding_platform_gate.dart --target linux-x64 --evidence build/native-embedding-linux-x64.json
dart run apps/dartclaw_cli/tool/native_embedding_platform_gate.dart --target windows-x64 --evidence build/native-embedding-windows-x64.json
```

Each command verifies/stages the target archive, runs the target's existing release build for both binaries, compiles
the non-shipping AOT probe from `apps/dartclaw_cli/tool/native_embedding_probe.dart`, and runs the success and failure
cases below against the final staged native libraries. It exits nonzero on any failed clause and writes one JSON object
with `schemaVersion: "1"` containing:

- target, source commit, OS/architecture, Dart version and non-sensitive hardware description;
- pinned llamadart/native release, native archive basename/size/SHA-256 and verified model basename/size/SHA-256;
- both release archive basenames/SHA-256 values and each archive's relative native-library names/SHA-256 values;
- cold first-embed, warm query, document-batch and dispose durations plus vector dimension/cardinality;
- every failure case's operation, elapsed time, sanitized error, exit code, `processExitObserved` and
  `forcedTermination`; and
- a pass/fail result that is `pass` only when every required operation and bound passed.

Evidence contains no vector values, prompts beyond fixed probe labels, absolute paths, credentials, host usernames or
environment dumps. A child that reaches the outer deadline is terminated for cleanup, but records
`forcedTermination: true` and makes the gate fail; harness cleanup can never turn a stuck provider into a pass.

## Required Context

- `docs/specs/0.26/phase-b/plan.json#sharedDecisions` – the synchronous lazy S03 provider contract, exact artifact
  pins, one-binary posture, lifecycle bounds and final combined-gate ownership.
- `docs/specs/0.26/phase-b/s03-native-and-http-embedding-providers.md#pinned-consumer-surface` – exact
  `NativeEmbeddingProvider` constructor and lazy embedding/disposal semantics exercised by the AOT probe.
- `docs/specs/0.26/phase-b/prd.md#fr6-native-distribution-and-failure-handling` – checksum-before-consumption,
  same-flavor packaging, selected platform, Linux dependency, process termination and retained-evidence requirements.
- `docs/specs/0.26/phase-b/prd.md#fr8-configuration-and-operator-guidance` – existing broader release matrix and the
  final combined A+B campaign that consumes this story's commands and evidence.
- `docs/specs/0.26/phase-b/native-artifacts.json#artifacts` – upstream v0.3.0 archive names, byte sizes and SHA-256 values
  from which the public build manifest is derived.
- `docs/specs/0.26/phase-b/native-artifacts.json#model` – exact 333590944-byte EmbeddingGemma model identity used by
  every success probe.
- `docs/specs/0.26/phase-b/implementation-context.md#offline-hook-inputs` – verified llamadart local-path lookup layout,
  tag and `llama_cpp` runtime-selection inputs.
- `docs/specs/0.26/phase-b/implementation-context.md#initialization-lifecycle-source-check-2026-09-09-0200-cest` –
  dependency-owned worker handshake, unbounded model/dispose distinction and why caller timeouts do not prove exit.
- `../dartclaw-public/dev/state/PRODUCT.md#proportionality` – prototype scale and the prohibition on another worker,
  release flavor or native service.
- `../dartclaw-public/dev/adrs/050-native-hybrid-search.md#decision` – one all-in binary, local in-process provider and
  verified native-bundle release posture.

## Deeper Context

- `docs/research/dart-native-hybrid-search/spike-llamadart-embeddings.md#1-packaging--aot` – historical feasibility,
  Linux OpenMP discovery and the old unbounded failure symptom; it is not final product proof.
- `../dartclaw-public/dev/adrs/056-package-topology-consolidation.md#amendment-2026-08-22--the-tier-order-replaces-the-per-edge-tables`
  – current package graph and the standing hook-free bridge exception.
- `../dartclaw-public/dev/tools/build.sh#compile_binary` – POSIX two-binary `dart build cli` graph and shared `lib/`
  staging behavior to extend.
- `../dartclaw-public/dev/tools/build_windows.ps1#Assert-WindowsReleaseLayout` – Windows exact-layout, smoke and bundled
  SQLite validation that must admit the selected native libraries for both artifacts.
- `../dartclaw-public/.github/workflows/release-binaries.yml#jobs` – five-target native release matrix and artifact
  upload boundary that runs the four selected probes.
- `../dartclaw-public/apps/dartclaw_cli/test/tool/build_tool_test.dart#main` – existing archive, checksum, both-binary and
  bundled-library proof patterns.
- `../dartclaw-public/apps/dartclaw_cli/test/tool/release_binaries_workflow_test.dart#main` – parsed workflow contract
  tests that prevent a dry run from publishing.
- `../dartclaw-public/dev/guidelines/RELEASE_PREPARATION.md#release-preparation` – the non-publishing final matrix
  run S09 uses after release/build-tool changes.

## Acceptance Scenarios

- **S01 [OC01] [TI01] Release preparation stages only a manifest-matching native archive**
  - **Given** a target and either an exact, absent, wrong-size or wrong-hash archive in an operator-supplied cache
  - **When** native preparation selects the target archive for the llamadart v0.3.0 local-path hook
  - **Then** it validates the manifest shape, target mapping, exact byte size and SHA-256 before publishing the archive
    into an operation-unique hook staging directory; exact bytes are accepted, while every missing/corrupt/unknown case
    fails before `dart build cli` and leaves no consumable stage

- **S02 [OC01] [TI01] Network-disabled preparation neither fetches nor falls back to the upstream hook**
  - **Given** offline mode and a supplied cache with or without the exact target archive
  - **When** preparation runs
  - **Then** an exact archive is reused without network access; a missing archive is refused with its expected basename
    and digest; the build cannot fall through to llamadart's unchecked GitHub download path. An explicitly online
    preparation may download to a unique temporary file, but must validate it before atomic cache/stage publication

- **S03 [OC02] [TI02] Both release packages carry one identical native library set**
  - **Given** the existing POSIX or Windows two-binary build graph with the target archive already verified
  - **When** it builds and extracts `dartclaw` and `dartclaw-workflow`
  - **Then** both artifacts retain their existing names/checksums and contain `VERSION`, their own binary, bundled
    SQLite and the identical relative llamadart library set selected for `llama_cpp`; neither adds a build flavor,
    `share/` sidecar, model file or shipped probe command

- **S04 [OC03] [TI03] [runtime] A selected native package performs cold and warm embeddings and exits cleanly**
  - **Given** an extracted release library set and model matching the committed manifests
  - **When** the AOT probe constructs `NativeEmbeddingProvider`, times its first `embedQuery` including lazy verification
    and initialization, performs a warm `embedQuery`, embeds an ordered non-empty document batch, then disposes
  - **Then** cold initialization plus embedding completes within 60 seconds; all vectors are finite, non-empty,
    equal-dimension and order/cardinality preserving; disposal completes within 10 seconds; the probe returns naturally,
    and the outer gate observes OS-process termination without calling `exit()` in the child or killing it

- **S05 [OC03] [TI03] [runtime] Missing library, absent/corrupt model and native-load failure terminate by operation**
  - **Given** separate extracted-package copies with the required native library removed, an absent model path, model
    bytes that fail the configured SHA-256, or the target native library replaced by invalid loader bytes
  - **When** each fresh AOT probe process makes its first embed call through the final provider
  - **Then** it returns a sanitized nonzero failure within 60 seconds, no later embed is attempted on that terminal
    instance, provider cleanup returns naturally, and the OS process exits without child `exit()` or outer forced
    termination. A returned Dart timeout alone is insufficient: any process retained by a private worker isolate fails

- **S06 [OC02,OC03] [TI02,TI04] [runtime] The release matrix retains complete platform and dependency evidence**
  - **Given** the existing five target release matrix
  - **When** its non-publishing final dry run executes
  - **Then** every target still builds both archives; macOS arm64, Linux arm64, Linux x64 and Windows x64 additionally
    run S04/S05 and upload their JSON with the archives; Linux installs the declared `libgomp1` prerequisite before
    build/probe and evidence records `libgomp.so.1` as resolved in the package environment; macOS x64 retains its
    broader packaging obligation without being misreported as an executed embedding probe

## Structural Criteria

- **SC01** One committed public native-build manifest derives from the five currently shipped target entries in
  `native-artifacts.json`, preserving exact upstream URL, v0.3.0 basename, size and SHA-256. Windows arm64 is not a
  shipped release target and this story does not introduce one.
- **SC02** Release scripts direct the hook to an operation-local verified stage and select only `llama_cpp`; they do not
  commit an absolute cache path, make normal source tests depend on a private cache, or mutate the shared root pubspec
  temporarily. The hook never sees an unverified archive or receives permission to fetch one itself.
- **SC03** `dartclaw` remains the full runtime binary and `dartclaw-workflow` remains the workflow-only binary. Sharing
  the all-in native library set changes neither command surface nor tree-shaken Dart code and leaves the hook-free
  `dartclaw_bridge` package/build unchanged.
- **SC04** Story completion proves manifest, staging, archive-layout, workflow-wiring and process-observation logic with
  synthetic archives, fake child processes and static/mutation checks. It records no platform pass; only S09's one
  final combined run may turn the four runtime scenarios into accepted platform evidence.

## Scope & Boundaries

### Work Areas

- Public native archive manifest plus portable verified cache/staging tool.
- POSIX and Windows release build scripts and exact archive-layout validation for both binaries.
- Non-shipping native AOT probe and outer process/evidence harness.
- Release workflow dependency setup, selected probe steps and evidence upload.
- Focused synthetic/static harness and build-tool contract tests.

### What We're NOT Doing

- Provider implementation, retry policy, model acquisition or runtime configuration – S03 and S05 own those surfaces.
- A second isolate, helper service, build flavor or product-visible probe command – the harness is release tooling only.
- Bundling the 333590944-byte model in release archives – operators acquire it explicitly and final runners supply the
  already verified input.
- Vendoring OpenMP into the Linux archives – ADR-050 chose the documented `libgomp1` system prerequisite; S09 updates
  public installation guidance while this story verifies it in each Linux package environment.
- Executing heavyweight builds, models or failure probes during story completion – all four selected platform legs,
  the existing broader five-target matrix and retained evidence execute once in S09's final combined gate.

## Architecture Decision

**Approach**: Put checksum enforcement and release-only hook staging in portable build tooling, retain the existing
two-binary archive graph, and run the final S03 provider through a non-shipping AOT child whose OS-process exit is
observed by an outer evidence harness.
**Why this over alternatives**: A timeout inside the provider cannot prove its private isolate ended, and a new product
command, worker wrapper, permanent local hook path or release flavor would add machinery without strengthening proof.

## Code Patterns & External References

```text
# type | path#anchor | why needed
file | dev/tools/build.sh#compile_binary | native POSIX AOT bundle and same-lib staging seam
file | dev/tools/build_windows.ps1#Assert-WindowsReleaseLayout | exact Windows package validation and both-binary loop
file | .github/workflows/release-binaries.yml#jobs | native-runner matrix, dry-run boundary and uploaded artifacts
file | apps/dartclaw_cli/test/tool/build_tool_test.dart#main | archive/hash/layout contract-test style
file | apps/dartclaw_cli/test/tool/release_binaries_workflow_test.dart#main | parsed workflow mutation guards
```

## Constraints & Gotchas

- Normalize DartClaw target names to upstream bundle names explicitly (`macos-x64` maps to `macos-x86_64`); reject an
  unknown target rather than selecting by substring or host defaults.
- Verification streams archive bytes into SHA-256 and enforces the declared size. A failed download/stage cleans only
  its unique temporary path and never truncates a pre-existing cache entry. Cache reuse re-verifies bytes every run.
- The release build must receive local-path, tag v0.3.0 and `llamadart_native_runtimes: [llama_cpp]` hook inputs without
  rewriting the shared checkout's root pubspec. Ordinary development remains free to use its normal hook resolution.
- POSIX already stages the first full binary's `lib/` for both archives. Windows must likewise package the full
  release-library set with each binary rather than copying only `sqlite3.dll` or trusting workflow-tree-shaken output.
- `libgomp1` is an explicit Linux system dependency, installed before the package probe and later documented by S09.
  Record loader resolution plus the successful actual embed; presence of the package name alone is insufficient proof.
- The child probe uses the fixed S03 constructor and invokes first embed for initialization. It never calls a removed
  eager `open`, treats constructor return as initialization success, or claims the dependency's 30-second handshake
  bounds model loading/disposal.
- A provider whose first embed reaches the initialization deadline is terminal. The probe must not call it again or
  allocate another worker; recovery is provider reconstruction after diagnosis, and any retained child process fails.
- Give the first-embed child a small outer grace beyond the provider's 60-second deadline and disposal/process exit a
  small grace beyond 10 seconds. Exceeding either grace permits cleanup but is always a failed case.
- Tests must drive synthetic tiny archives and fake child processes. Do not read, copy, hash or execute the prepared
  hundreds-of-megabytes private artifacts during ordinary story verification, and do not claim those mocks prove a
  platform.

## Implementation Plan

### Implementation Tasks

- **TI01** Release builds consume only verified staged native archives
  - Derive a public five-target v0.3.0 manifest from the pinned private source and provide portable online/offline
    cache preparation whose successful output is the sole local-path hook input; verification precedes publication.
  - **Verify**: `cmd: dart test --reporter=failures-only apps/dartclaw_cli/test/tool/native_artifact_preparation_test.dart` – synthetic exact, missing, wrong-size, wrong-hash, unknown-target, offline/no-fetch, online atomic-publication and re-verification cases prove that no rejected bytes become hook input
  - **SATISFIES**: S01, S02, SC01, SC02

- **TI02** Both release archives carry the verified all-in native layout
  - Extend `build.sh` and `build_windows.ps1` through their current two-binary graph so both packages receive one
    identical selected native-library set; retain all existing names, checksums, SQLite checks and command separation.
  - **Verify**: `cmd: dart test --reporter=failures-only apps/dartclaw_cli/test/tool/native_packaging_contract_test.dart apps/dartclaw_cli/test/tool/build_tool_test.dart` – synthetic POSIX/Windows layouts and source mutations prove pre-build verification order, equal native library manifests, existing archive shape, no shipped probe/model/flavor and explicit Linux OpenMP setup without compiling a real release
  - **SATISFIES**: S03, S06, SC02, SC03

- **TI03** The AOT platform gate distinguishes bounded calls from terminated processes
  - Build the non-shipping probe against S03's final provider and an outer cross-platform harness that runs each case in
    a fresh process, enforces hard cleanup deadlines and emits the pinned evidence schema only after observing exit.
  - **Verify**: `cmd: dart test --reporter=failures-only apps/dartclaw_cli/test/tool/native_embedding_platform_gate_test.dart` – fake probe processes cover natural success/failure returns, every failure operation, malformed output, deadline cleanup, forced-termination failure, retained-child detection, no child `exit()` concealment, sanitized evidence and all required schema fields without loading a model
  - **SATISFIES**: S04, S05, SC04

- **TI04** The release dry run owns the four platform proofs and their evidence
  - Wire the existing five-target workflow so the selected four native runners invoke the exact commands above after
    dependency/artifact preparation and upload each JSON; keep macOS x64 build-only and publication tag-gated.
  - **Verify**: `cmd: dart test --reporter=failures-only apps/dartclaw_cli/test/tool/release_binaries_workflow_test.dart` – parsed workflow assertions pin all five builds, four probe commands/evidence uploads, Linux `libgomp1` ordering, exact environment inputs and the existing non-publishing dispatch boundary
  - **SATISFIES**: S06, SC04

### Testing Strategy

- TI01-TI04 are S07's focused completion proof. They use generated tiny archives, fake processes and parsed build/workflow
  sources so they can fail on corrupt bytes, reordered verification, stuck-child acceptance or missing matrix wiring
  without consuming cached native/model artifacts.
- The four commands in `Pinned Final-Gate Interface` are intentionally not task `Verify` lines. S09 runs them once on
  native runners, collects the four JSON files with the existing five-target release artifacts, and treats any absent,
  malformed, forced-termination or failed result as a release blocker.

### Execution Contract

- Implementation requires accepted S05 despite this FIS being authorable from the pre-resolved build graph and S03 API.
- Do not dispatch `Release Binaries`, build a real AOT package, load the prepared model, or run failure probes while
  completing S07. S09 owns that single heavyweight run after all Phase B implementation and docs are integrated.

## Implementation Observations

_No observations recorded yet._
