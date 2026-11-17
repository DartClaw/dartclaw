# S07: npm registry adapter

**Plan**: dev/bundle/docs/specs/0.28.1/plan.json
**Story-ID**: S07

## Feature Overview and Goal

**Intent**: Story S06 gave `workspace` containers a read-only registry path with pub only, so a Node project still cannot run `npm install` and FR9 stays half proven. This story adds npm through story S06's adapter seam, then closes FR9: story S02's scenario passes on both fixtures with both providers, and ADR-062 becomes Accepted.

**Expected Outcomes**:

- [OC01] `npm install` succeeds in a `workspace` container under `network:none`, and story S02's Node fixture passes its tests there with Claude Code and with Codex.
- [OC02] npm obeys the rules pub already does, with nothing new on the surface: `restricted` gets none, writes and unpinned origins are refused, and story S02's scenario passes unflagged on both fixtures with both providers.
- [OC03] An operator can see every npm request a container made, and the ADR and security docs state that npm is served.


## Required Context

Paths are relative to the public repo root (`../dartclaw-public/` from the private repo), where this FIS executes from its exported copy and where `cmd:` proofs run; `docs/specs/` and `docs/research/` paths name this plan's private sources, exported to `dev/bundle/docs/`.

- `docs/specs/0.28.1/prd.md#fr9-read-only-package-registry-egress` – the seven acceptance criteria; this story covers the npm half of the first and the last.
- `dev/adrs/062-read-only-package-registry-egress-for-containers.md` – design authority, D1-D3 pinned; its npm questions ("whether npm's default registry-host replacement already covers tarball URLs", the download origin) are answered in Constraints & Gotchas below.
- `docs/specs/0.28.1/s06-registry-bridge-surface-with-pub.md` – pins `RegistryAdapter` (`ecosystem`, `clientEnvironment(mirrorBase)`, `origins`, `carriesMetadata`), `PubRegistryAdapter` as the pattern, the one-line `SecurityWiring` registration, port 8082 with `/<route>` prefixes, the grant rule, the audit and refusal rules, and the docs and tests this story extends.
- `docs/specs/0.28.1/plan.json#sharedDecisions` – "Registry ecosystem adapter seam" (npm joins without changing the surface, the protocol or the grant rule) and "Containerized coding scenario" (S07 runs both fixtures with both providers without `--baseline`).
- `docs/specs/0.28.1/s02-live-containerized-workflow-proof.md` – `coding.sh`, its flags, fixtures, results file and teardown rules.
- `docs/specs/0.28.1/s05-agent-image-toolchain-recipe.md` – the Node recipe image, its guide mirror (SC01) and the 100 MiB `noexec` `/tmp` tmpfs whose npm cache capacity this story measures.


## Acceptance Scenarios

- **S01 [OC01] [runtime] A Node project installs and passes its tests in a workspace container**
  - **Given** a container runtime, host-held Claude Code and Codex credentials, and a bridge binary built from this candidate
  - **When** the maintainer runs story S02's scenario command on the Node fixture, for both providers, without `--baseline`
  - **Then** each provider's results row shows the install command and the test command both exited 0 inside the container, every task of the run has a `container_json` naming the `workspace` profile, the results row's count of refused registry requests is 0, and the command exits 0
  - **Proof**: `cmd: bash dev/testing/profiles/container/coding.sh --fixture node` – exit 0

- **S02 [OC02] [runtime] FR9's final proof: both fixtures, both providers, no baseline flag**
  - **Given** the same prerequisites, with story S05's recipe images
  - **When** the maintainer runs story S02's scenario command with no flags
  - **Then** all four provider and fixture rows show install and tests passing inside the container and the command exits 0, which closes FR9's last criterion
  - **Proof**: `cmd: bash dev/testing/profiles/container/coding.sh` – exit 0

- **S03 [OC01] [runtime] A container reads an npm packument and a tarball through the mirror, with no network**
  - **Given** a `workspace` authority whose npm adapter is pinned to a local fake origin serving a packument whose tarball address names `https://registry.npmjs.org/...`, plus the tarball
  - **When** a process in the container fetches the packument and the tarball from the address in its `npm_config_registry`
  - **Then** both bodies equal the origin's bytes, a scoped package's packument is requested with its slash still encoded, the container's network mode is `none`, and a `restricted` container has no `npm_config_registry` and cannot fetch
  - **Proof**: `cmd: dart test --run-skipped -t integration packages/dartclaw_runtime/test/integration/registry_bridge_integration_test.dart --name "npm"` – exit 0 with at least one npm case run; red at spec time (no npm case exists yet)

- **S04 [OC01] A packument is served unmodified, so a lockfile keeps the public address**
  - **Given** an npm adapter and a packument whose `dist.tarball` is `https://registry.npmjs.org/is-odd/-/is-odd-3.0.1.tgz`
  - **When** the container requests it, gzip-encoded or not
  - **Then** the body it receives is byte-identical, and no response of any path or content type is treated as metadata to rewrite
  - **Proof**: `packages/dartclaw_runtime/test/container/gateway/npm_registry_adapter_test.dart#serves packuments unmodified` – red at spec time

- **S05 [OC01] A scoped package reaches the origin with its slash encoded**
  - **Given** a `workspace` authority with the npm adapter and a loopback fake origin that records raw request paths
  - **When** the container requests `/npm/@sindresorhus%2fis` and `/npm/@sindresorhus/is/-/is-4.6.0.tgz`
  - **Then** the origin's raw paths are `/@sindresorhus%2Fis` (any hex case of the escape) and `/@sindresorhus/is/-/is-4.6.0.tgz`, and both are served
  - **Proof**: `packages/dartclaw_runtime/test/container/gateway/registry_bridge_surface_test.dart#passes a scoped npm package path to the origin with its slash encoded` – red at spec time

- **S06 [OC02] npm gets pub's refusals and cannot cross into pub's route**
  - **Given** a surface with the pub and npm adapters registered, and an npm origin that redirects
  - **When** the container sends `PUT` or `POST` to an npm route (a publish, or npm's audit upload), requests an npm redirect that leaves the pinned set, and requests a path under the pub route that names an npm package
  - **Then** the write is refused with 405 and the origin sees no request, the leaving redirect is refused, the pub route reaches only pub's origin and the npm route only npm's, and each refusal fires a `GuardBlockEvent` (`guard: host-gateway`, `hook: bridge`) naming `npm` and the rule
  - **Proof**: `packages/dartclaw_runtime/test/container/gateway/registry_bridge_surface_test.dart#applies the refusal rules to every registered adapter` and `#keeps each route on its own origin` – red at spec time

- **S07 [OC02] Only a granted authority's container carries the npm client environment**
  - **Given** a `workspace` and a `restricted` authority with the pub and npm adapters registered
  - **When** each container is created
  - **Then** the `workspace` container carries `npm_config_registry=http://127.0.0.1:8082/npm` and `npm_config_audit=false` beside pub's variable, and every other argument equals the ungranted list (`--network none` included); the `restricted` container carries neither
  - **Proof**: `packages/dartclaw_runtime/test/container/container_manager_test.dart#registry client environment carries every registered ecosystem for a granted authority only` – red at spec time

- **S08 [OC03] Served npm requests are recorded under the npm ecosystem**
  - **Given** a `workspace` authority with the npm adapter, served a packument and a tarball
  - **When** both settle
  - **Then** the audit trail holds two records, each with the authority, `npm`, the request path and status 200
  - **Proof**: `packages/dartclaw_runtime/test/container/gateway/registry_bridge_surface_test.dart#records served npm requests under the npm ecosystem` – red at spec time


## Structural Criteria

- **SC01** npm knowledge lives only in `NpmRegistryAdapter`: the `npm_config` variable names and `registry.npmjs.org` appear in no other file under `packages/*/lib`, and registering the adapter is one line in `SecurityWiring`.
- **SC02** The surface is unchanged: this story's diff names no file under `packages/dartclaw_bridge` or `packages/dartclaw_kernel` and none of `registry_bridge_surface.dart`, `host_gateway.dart`, `container_manager.dart`, so the bridge protocol version, handshake, grant rule, audit rule and config keys stay as story S06 left them. A defect scenarios S05 or S06 expose in the surface is the only exception, fixed with the failing test and named in Implementation Observations.
- **SC03** The docs state npm: `security-architecture.md`, the guide's security page and `security-host-gateway.svg` name `registry.npmjs.org` beside pub's origin, ADR-062 is `Accepted` with a date, its Decision-table "Response URLs" row and the matching Negative bullet state the no-direct-connection invariant, its Implementation Notes carry the npm answers, and `CHANGELOG.md` 0.28.1 names npm in the registry entry.


## Scope & Boundaries

### Work Areas

- `packages/dartclaw_runtime/lib/src/container/gateway/npm_registry_adapter.dart` (new) and its one registration line in `runtime/security_wiring.dart`.
- Tests: `npm_registry_adapter_test.dart` (new), `registry_bridge_surface_test.dart`, `container_manager_test.dart`, `test/integration/registry_bridge_integration_test.dart` (all story S06's).
- `dev/testing/profiles/container/coding.sh` (story S02's script): the registry-refusal check for scenario S01, only if absent; `images/node.Dockerfile` and its guide mirror only if the capacity or cache-write check fails.
- `dev/architecture/security-architecture.md`, `dev/architecture/diagrams/security-host-gateway.svg`, `docs/guide/security.md`, `dev/adrs/062-read-only-package-registry-egress-for-containers.md`, `CHANGELOG.md` (0.28.1).

### What We're NOT Doing

- A change to `RegistryAdapter`, the surface, the bridge, the handshake, the grant function, `BridgeLimits` or any config key – SC02.
- Other ecosystems, private or authenticated registries, git or tarball-URL dependencies, a CONNECT tunnel, TLS interception – ADR-062 D1-D3.
- Rewriting npm metadata – Constraints & Gotchas; ADR-062's row is reworded to match (TI09).
- The DECISIONS index row, "Current through" markers, Ubiquitous Language and other diagrams – story S09; the index keeps saying `Proposed` until that story updates it.
- Pub's cache capacity and pub's docs – story S06.


## Architecture Decision

**Approach**: `NpmRegistryAdapter`, beside `PubRegistryAdapter` and built from story S06's seam: it pins `https://registry.npmjs.org` as route `/npm` (npm's alone, no second download origin), `clientEnvironment` returns `npm_config_registry=<mirrorBase>/npm` and `npm_config_audit=false`, and `carriesMetadata` is `false` for every response. The surface does the rest unchanged.


## Constraints & Gotchas

- **npm rewrites tarball URLs itself, so the adapter must not.** With `replace-registry-host` at its default (`npmjs`), npm replaces `registry.npmjs.org` in a packument's `dist.tarball` and in a lockfile's `resolved` with the configured registry and keeps its path prefix. Checked 2026-11-13 with an unmodified packument through a throwaway proxy on `http://127.0.0.1:<port>/npm`: npm 11.20.0 and npm 10.9.9 (`node:22-bookworm`) both requested `/npm/<pkg>/-/<file>.tgz`, `npm ci` from a lockfile did the same with no packument request, and the lockfile kept `https://registry.npmjs.org/...`. Rewriting in the adapter, as pub's needs, made npm write `http://127.0.0.1:<port>/npm/...` into `package-lock.json`, which then reaches the host through the merge. Re-check at execution with the Node version the recipe image pins.
- **Fails closed outside the default.** A project `.npmrc` with `replace-registry-host=never`, or a lockfile whose `resolved` names another host, makes npm connect there directly; the container has no network, so it fails. Not worked around. A project `.npmrc` `registry=` does not matter: the environment variable wins (checked).
- **The download origin is the registry itself.** All 32 popular packages sampled (react, typescript, `@babel/core`, `@types/node`, express and others) name `https://registry.npmjs.org/...` in `dist.tarball`, and each latest tarball answered 200 with no redirect, so npm's pinned set is that origin alone. A redirect to another host seen in a later run is added to the adapter as that exact origin.
- **Scoped names carry an encoded slash.** npm requests a scoped packument as `/@scope%2fpkg` and its tarball as `/@scope/pkg/-/...`; the origin accepts `%2F`. The path must be forwarded as received: `Uri.replace(path:)` keeps the escape (normalised to `%2F`), `Uri.pathSegments` decodes it and would turn the name into two segments. Story S06's route lookup must not take that detour.
- **`npm install` audits by default**, as a `POST` to `/-/npm/v1/security/advisories/bulk`. The surface refuses it with 405, npm treats that as non-fatal (the install still finished, checked), but every install would fire a `GuardBlockEvent`. `npm_config_audit=false` removes the request instead of teaching operators to ignore a refusal. npm also fetches the `npm` package's packument on each run (update check); that is a served request, not a problem.
- **npm needs a writable cache and log directory.** Under the container flags with a read-only home, `npm install` fails writing `~/.npm/_logs`; with `npm_config_cache=/tmp/npm-cache` it succeeded and left 308 KiB for three packages (checked in `node:22-bookworm` with `--read-only`, `--cap-drop ALL`, `-u 1000` and the 100 MiB tmpfs, not through the bridge). Story S05's Node recipe is meant to set the cache path; if its executed form does not, scenario S01 fails on it, and the fix is image `ENV` in `node.Dockerfile` plus the guide mirror, never a wider mount.
- **Limits are unchanged and sufficient.** npm's `maxsockets` default of 15 fits the bridge's 8 in flight plus 16 queued, so no 503 is expected (inferred, not run at fixture scale). The largest full packuments sampled, typescript (15.9 MB) and `@types/node` (11.2 MB), are far under the 64 MiB cap. A 503 in a live run is recorded, not met by raising a limit.
- Story S06's stale-bridge gotcha applies: run `bash dev/tools/build_bridge.sh` before any live run in a source checkout.

- **Packuments are served unmodified.** npm's own host replacement keeps the client off the public host (observed) and an adapter rewrite poisons lockfiles with loopback addresses, so `carriesMetadata` stays `false`. ADR-062's Decision-table "Response URLs" row said metadata URLs are rewritten; TI09 rewords it to the invariant it protects: the client never needs a direct connection for a pinned-origin download, and an adapter rewrites metadata URLs only where its client has no host replacement of its own (pub's are rewritten, npm's are not).
- `npm_config_audit=false` rides in the adapter's client environment, so `clientEnvironment` returns more than one variable; if story S06's executed seam returns a single pair, widen it to a map and note it.
- ADR-062 moves to Accepted only when scenarios S01 and S02 pass; if story S02's scenario fails for a cause other than npm (a step-path defect), the ADR stays Proposed and the report says why.
- The DECISIONS index row stays for story S09, which owns the index for ADR-062.
- ASSUMPTION: the live scenarios need Docker and host-held Claude Code and Codex credentials on the executing machine – an executor without them leaves S01 and S02 open, keeps ADR-062 `Proposed`, and reports it, never skips.
- npm's cache capacity is measured on story S02's Node fixture only, as pub's was; a project with more dependencies needs more room than the 100 MiB tmpfs and is the operator's to size.
- **Written against the FIS of stories S02, S05 and S06**, whose `coding.sh`, `--fixture node`, `fixtures/node`, `images/node.Dockerfile`, `RegistryAdapter` and test files do not exist yet: if their execution renames any, apply the same edits by intent.
- The registry-refusal count of scenario S01 is read from the run's server log through `coding.sh`'s results; if the script does not already report it, one count of refused registry requests is added to each results row.


## Implementation Plan

### Implementation Tasks

- **TI01** `NpmRegistryAdapter` exists as in Architecture Decision, with its origin injectable for tests, and `SecurityWiring` registers it in one line beside pub's.
  - Follow `pub_registry_adapter.dart` (S06) for the constructor and tests.
  - **Verify**: `packages/dartclaw_runtime/test/container/gateway/npm_registry_adapter_test.dart#serves packuments unmodified` – no path or content type is metadata, a gzip-served body included; and `#client environment points npm_config_registry at the npm route and disables audit`; plus `cmd: test -z "$(git grep -l -i -e npm_config -e registry.npmjs.org -- 'packages/*/lib' ':!packages/dartclaw_runtime/lib/src/container/gateway/npm_registry_adapter.dart')"` – exit 0.
  - **SATISFIES**: S04, SC01

- **TI02** The surface serves npm under its existing rules: refusals, redirects inside the pinned set, route separation, audit records, and an encoded slash forwarded intact.
  - Tests only, against a loopback fake origin that counts requests and records raw paths (story S06's `registry_bridge_surface_test.dart` fixtures). A failure here is a surface defect: fix it in the surface with the failing test first, name it in Implementation Observations, keep the interface.
  - **Verify**: `registry_bridge_surface_test.dart#passes a scoped npm package path to the origin with its slash encoded`, `#applies the refusal rules to every registered adapter`, `#keeps each route on its own origin`, `#records served npm requests under the npm ecosystem`.
  - **SATISFIES**: S05, S06, S08, SC02

- **TI03** A granted authority's container is created with npm's variables beside pub's and an ungranted one without them, through story S06's existing environment path.
  - **Verify**: `container_manager_test.dart#registry client environment carries every registered ecosystem for a granted authority only` – both ecosystems' variables present for `workspace`, absent for `restricted`, all other arguments equal; story S06's existing environment test stays green unchanged; plus `cmd: test -z "$(git diff --name-only -- packages/dartclaw_bridge packages/dartclaw_kernel packages/dartclaw_runtime/lib/src/container/container_manager.dart)"` – empty for this story's commits (scope the diff to them when others share the tree), unless a named defect fix per SC02.
  - **SATISFIES**: S07, SC02

- **TI04** The real-Docker suite proves npm's mirror path with no model: a `workspace` container fetches a packument, a scoped packument and a tarball from `npm_config_registry` under network mode `none`, a `restricted` container has no variable and no path.
  - Extend story S06's file; follow its fake-origin and probe-image setup.
  - **Verify**: `cmd: dart test --run-skipped -t integration packages/dartclaw_runtime/test/integration/registry_bridge_integration_test.dart` – exit 0, npm cases included.
  - **SATISFIES**: S03

- **TI05** npm's cache fits the container's `/tmp` tmpfs: measure what `npm install` of story S02's Node fixture leaves, and if it exceeds 75% of 100 MiB, move the cache in `images/node.Dockerfile` to a writable path with room and keep the guide mirror in step (story S05's SC01).
  - **Verify**: `cmd: d=$(mktemp -d) && cp -R dev/testing/profiles/container/fixtures/node "$d/f" && (cd "$d/f" && npm_config_cache="$d/cache" npm install --no-audit --no-fund) && test "$(du -sk "$d/cache" | cut -f1)" -lt 76800` – exit 0.
  - **SATISFIES**: S01

- **TI06** The live scenario passes on the Node fixture with both providers, recorded in this FIS's `## Implementation Observations` under `npm registry proof` with both providers' result rows and the run's served and refused registry request counts; `coding.sh` reports the refused count if it did not.
  - A first-run failure from the cache or log path is fixed per Constraints & Gotchas; any other step-path defect gets a regression test that fails on the pre-fix code.
  - **Verify**: the scenario S01 `cmd:` – exit 0; `cmd: grep -rq "npm registry proof" dev/bundle/docs/specs/0.28.1` – the heading exists in the executed FIS copy.
  - **SATISFIES**: S01

- **TI07** FR9's final proof is recorded under `FR9 final proof` in Implementation Observations: the unflagged scenario on both fixtures with both providers, four result rows, exit 0.
  - **Verify**: the scenario S02 `cmd:` – exit 0; `cmd: grep -rq "FR9 final proof" dev/bundle/docs/specs/0.28.1` – the heading exists in the executed FIS copy.
  - **SATISFIES**: S02

- **TI08** The docs state npm: `security-architecture.md` (§ Host-Owned Provider Mediation and the supply-chain and exfiltration threat rows), the guide's security page (the registry paragraphs story S06 wrote, and the dependency paragraph of `### Language Toolchains in the Agent Image`), `security-host-gateway.svg` gains the `registry.npmjs.org` origin beside pub's, and the `CHANGELOG.md` 0.28.1 registry entry names npm.
  - Diagram: follow `dev/architecture/diagrams/README.md` (hand-written SVG, both themes rendered).
  - **Verify**: `cmd: for f in dev/architecture/security-architecture.md docs/guide/security.md dev/architecture/diagrams/security-host-gateway.svg; do git grep -q "registry.npmjs.org" -- "$f" || exit 1; done` – exit 0; `cmd: sed -n '/^## \[0.28.1\]/,/^## \[0.28.0\]/p' CHANGELOG.md | grep -qi -E 'registry.*npm|npm.*registry'` – exit 0.
  - **SATISFIES**: SC03

- **TI09** After TI06 and TI07 pass, ADR-062's status reads `Accepted – <today>` (the date from `date +%Y-%m-%d`); its Decision-table "Response URLs" row is reworded to the invariant (the client never needs a direct connection for a pinned-origin download; an adapter rewrites metadata URLs only where its client has no host replacement of its own) and the Negative bullet "each adapter knows ... its URL rewriting" to match; and its Implementation Notes answer the open npm questions: tarballs come from `registry.npmjs.org` itself, npm's `replace-registry-host` covers packument and lockfile URLs so the adapter rewrites nothing, and `npm_config_audit=false`.
  - **Verify**: `cmd: git grep -q -E '^Accepted – [0-9]{4}-[0-9]{2}-[0-9]{2}' -- dev/adrs/062-read-only-package-registry-egress-for-containers.md` – exit 0; `cmd: git grep -q "replace-registry-host" -- dev/adrs/062-read-only-package-registry-egress-for-containers.md` – exit 0; `cmd: git grep -q "never needs a direct connection" -- dev/adrs/062-read-only-package-registry-egress-for-containers.md && ! git grep -q "so the client never tries a direct connection" -- dev/adrs/062-read-only-package-registry-egress-for-containers.md` – exit 0, the row carries the new wording and not the old.
  - **SATISFIES**: SC03

## Discovered Requirements

- **Verified registry and qualification owners**. **Description**: S06's generic surface has one exact-origin matcher, immutable authority grants and explicit served/refused audit outcomes. Shared framing, queue and late streamed-cap failures retain transport-owned generic reasons; routed policy refusals name the ecosystem. **Rationale**: Live pub traffic and independent review exposed writer concurrency, redirect-body and ownership defects. **Interpretation**: Extend the adapter seam without duplicating these owners or changing limits. Preserve serialized frame writes, rejected-frame recovery and redirect-body cancellation. Rebuild the bridge before live proof. **Traced from**: S06/TI01–TI12 and its review. **Date**: 2026-11-17.

- **Final live fixture contract**. **Description**: S06's normal Dart command passed both providers with install/test 0, five workspace tasks each and no new system-home rollouts. Both existing fixture stories now distinguish intentional planning-red tests from final acceptance; the recorder recognizes fixed commands from structured shell arguments at command boundaries and rejects a latest genuine invalid attempt. **Rationale**: Successful installs exposed an unconditional planning-failure directive and a checksum command falsely matching `dart test`. **Interpretation**: Preserve those original prompt/recorder owners and all stub tests/verdict gates; do not wrap or repair model output. Pub lockfiles canonically use the mirror's trailing `/pub/` and may select newer dependencies. The final receipt is `.agent_temp/container-coding/20261117T203244Z.exV3Cr/results.md`; the measured pub cache remains below the relocation threshold. **Traced from**: S06/TI09–TI10 and its discovered requirements. **Date**: 2026-11-17.

- **Container baseline and lifecycle**. **Description**: Reuse S02's `container/coding.sh` and existing renderer/recorder. Its four-case baseline recorded install/test exit 127 for missing Dart/npm, workspace placement on all tasks, unchanged Dart locks and no new Codex system-home rollouts. Disposable workflow generation changes only `gitStrategy.cleanup.enabled:false`; the profile collects retained worktree evidence and owns final teardown. **Rationale**: The live proof exposed cleanup and skill-materialization constraints absent at planning. **Interpretation**: Preserve the generated definition's steps and roles. Baseline mode permits terminal failures tied to recorded acceptance commands; awaiting approval and unrelated workflow failures still gate. Bundled `dartclaw-*` skills use managed copies; provider-native AndThen remains outside auth-clean containers under ADR-040 and the FIS boundary exception. Do not copy or mount host login/plugin directories. Consult S02's observations for exact receipts and the pre-fix trace-baseline drift. **Traced from**: S02/TI04–TI08. **Date**: 2026-11-17.

- **Person-owned execution holds**. **Description**: S03 holds automatic task accepts and workflow promotion/publish when execution-surface files or symlinks are changed. Agent-tool provenance cannot release those holds; host approval state uses reserved exact-data keys. **Rationale**: Live canaries now run behind the new deterministic review boundary. **Interpretation**: Never bypass a hold to make an unattended fixture pass. Ordinary code and instruction-file changes still proceed; person UI/API/channel-button action releases the held branch. Preserve `_workflow.git.execution_surface_hold` and `_workflow.git.approved_branches` as host-owned state if extending output/bridge paths. **Traced from**: S03/TI02, S03/TI05–TI07 and its discovered requirements. **Date**: 2026-11-17.

- **Proven toolchain image settings**. **Description**: S05's Dart recipe needs `HOME=/tmp` because unified analytics writes `~/.dart-tool`, and `/usr/local/bin/dart` because Codex login shells reset SDK PATH. Provider homes stay explicit. Node uses its pinned official toolchain with writable npm cache. **Rationale**: Versions alone passed while first-use/login commands failed in real runs. **Interpretation**: Preserve those fixes when adding registry environment; client registry variables belong at granted container creation, never in image ENV. Measure the existing `/tmp` caches as specified before relocating one, and keep the guide recipe mirror in step. Final S05 recipe and forced-stock receipts are in its observations. **Traced from**: S05/TI01, S05/TI03, S05/TI06. **Date**: 2026-11-17.


- **Count host registry transport refusals**. **Description**: The zero-refusal qualification includes host-side registry transport refusals, such as in-flight limits, timeout and late streamed response caps, as well as routed refusals. **Rationale**: The routed audit alone can omit a refused transport request even if the package manager retries and exits zero. **Interpretation**: Read the owned server's structured guard audit. Its exact `registry: ` prefix comes from `GatewayPipe`; use that one guard event per routed or transport refusal, retain paired routed audit rows without counting them again, and exclude unrelated provider and MCP events. Keep the bridge and audit schemas unchanged. **Traced from**: TI06/TI07 and plan session scope clarification. **Date**: 2026-11-17.

- **Carry the qualification skill boundary into the generated FIS**. **Description**: The unflagged Claude Node implementation passed both commands but the later review entered `awaitingApproval` solely over unavailable provider-native AndThen and linked-worktree Git metadata. The review step receives `spec_path` and does not receive the original `FEATURE`. **Rationale**: Earlier providers completed using visible project evidence. The existing story guidance stated the Git boundary, but did not instruct the spec phase to pass the full qualification-only boundary to review and ship. **Interpretation**: Apply S02's existing auth-clean exception in both authored fixture stories and require it in the generated FIS. Record the provider-native skill's actual availability and complete the assigned fixture phase against visible evidence and the unchanged output contracts. Person-owned decisions and execution-surface holds still require the person. **Traced from**: TI07, run `9a0b6d75-ac1e-4a15-a15e-41bea748e3f7` and the plan session. **Date**: 2026-11-17.

- **Keep each acceptance trace attributable in later workflow phases**. **Description**: Codex's Dart ship step used one shell call with both acceptance commands and two unkeyed exit markers. The normal recorder rejected the latest attempt despite both displayed values being zero. **Rationale**: The original fixture described command capture after implementation and did not carry its separate-call contract into later phases. Each step also has a fresh container cache. **Interpretation**: Carry the original acceptance wrapper instructions into the generated FIS with the qualification boundary. Every phase that reruns acceptance commands runs install then test in that phase's container, uses one shell call and one exit marker per command, and attempts the test even if install fails. Keep the recorder's existing latest-genuine-attempt rule and structured outcomes. **Traced from**: TI07, run `68934daa-bc18-4592-a3e5-3ae4970a43c7`. **Date**: 2026-11-17.

- **Make the existing fixture contract visible before review chooses tools**. **Description**: In the third matrix the provider selected an unrelated review skill, reached inaccessible Git metadata, and requested approval before reading the generated FIS. **Rationale**: The FIS already carries both qualification provisions. Additional wording inside that file has no effect if the reviewer exits before opening it. **Interpretation**: Seed a short fixture-only pointer through the normal provider project instruction files before the disposable project's first commit. It orders review and ship to open the generated FIS before selecting tools. The story and FIS remain the authority for the fixture protocol. Preserve the normal workflow, artifacts, model decision, approvals, provider homes and mounts. **Traced from**: TI07, run `8b4921f8-9913-43d3-9a35-4d1656073c5c` and plan session Resolution Ladder rungs 2 and 4. **Date**: 2026-11-17.

## Implementation Observations

### Adapter, cache and bound tests

- TI01/S04: both bound adapter tests exited 0 with `+1: All tests passed!`. Before implementation the suite failed to load the missing `npm_registry_adapter.dart`. The gzip and plain responses both preserve every byte of the packument payload. The shared HTTP client removes gzip transport encoding before serving that payload. No adapter response classifies as metadata, and SC01's package source grep exits 0.
- TI02/S05/S06/S08: all four bound selectors exited 0 with `+1: All tests passed!`. The tests observe the two origins' exact received paths, preserved scoped escape, read-only refusal before any origin hit, same-origin redirect and outside-origin refusal, denial callback and two npm audit rows. The bridge, host gateway, registry surface, kernel and manager sources have no changes.
- TI03/S07: the new and existing grant-environment selectors each exited 0 with `+1: All tests passed!`. Removing each of the three granted env pairs from the recorded workspace creation leaves the exact restricted argument list, including `--network none`.
- TI04/S03: `bash dev/tools/build_bridge.sh` exited 0 and rebuilt both Linux architectures. The exact Docker suite exited 0 with `00:29 +3: All tests passed!`; the exact `--name "npm"` selector exited 0 with `00:14 +1: All tests passed!`. The real container fetched plain and scoped packuments and exact tarball bytes from loopback; Docker reported network mode `none` for workspace and restricted, and restricted had neither npm variable nor a reachable registry listener. Receipts: `.agent_temp/s07/ti04-integration.log`, `s03-docker-npm.log` and `proof-selectors.log`.
- TI05: the exact cache command exited 0 and measured 568 KiB after installing the Node fixture, below 76,800 KiB. Two active Claude Node workspace containers measured 18,264 KiB each in `/tmp/npm-cache` under `network:none`. No cache relocation or recipe change was needed.
- Resolution Ladder rung 3 (documentation lookup) and the pinned-image probe checked npm's registry behavior. npm 11.19.1 defaults `replace-registry-host` to `npmjs`; the isolated bundled `pacote` rewrite expression alone cannot establish prefix handling. Under `network:none` the recipe's actual Node 24.22.3/npm 11.19.1 sent `npm install` packument and tarball requests through `/npm`; `npm ci` fetched the tarball through `/npm` without a package packument request. Both exited 0, and the lock kept the public tarball URL. Sources: [npm configuration](https://docs.npmjs.com/cli/v11/using-npm/config#replace-registry-host), [11.19.1 configuration definition](https://github.com/npm/cli/blob/v11.19.1/workspaces/config/lib/definitions/definitions.js), [11.19.1 bundled remote fetcher](https://github.com/npm/cli/blob/v11.19.1/node_modules/pacote/lib/remote.js). Receipt: `.agent_temp/s07/npm-host-probe.log`.
- TI06's count was absent in the existing result recorder. Its first implementation copied the disposable server's routed registry audit rows and counted explicit allow/deny decisions. The final implementation below also includes host-observed transport refusals. Normal qualification requires a served row for the selected ecosystem, so absent audit evidence cannot pass as zero refusals. The added Python test failed first with `AttributeError: module 'coding_results' has no attribute 'registry_requests'` and then passed in the 14-test recorder suite.

### npm registry proof

- `DARTCLAW_CONTAINER_DATA_DIR=/Users/tobias/.dartclaw DARTCLAW_CODING_IMAGE=sha256:52e4820da36f5460002811640019a6d580763ea9170eb40d4ac246445847acd0 bash dev/testing/profiles/container/coding.sh --fixture node` -> exit=0. Runner lines: `claude/node: completed; install=0; test=0; Codex steps=0` and `codex/node: completed; install=0; test=0; Codex steps=5`.
- Receipt: `.agent_temp/container-coding/20261117T210058Z.5yvJP2/results.md`. Both rows have five workspace tasks and no new system-home DartClaw rollouts. Both audit files show the lodash packument and tarball served.

| Provider | Run | Install | Test | Workspace tasks | Registry served | Registry refused |
|---|---|---:|---:|---:|---:|---:|
| Claude Code | `0f8b23b8-a1e2-4fb1-acdd-e217a2a92048` | 0 | 0 | 5 | 22 | 0 |
| Codex | `3e22dfd0-59e2-47f7-84b2-8ccb8deeeead` | 0 | 0 | 5 | 6 | 0 |

- `.agent_temp/s07/node-before.json` and `node-after.json` contain 2,610 identical file digests. The recipe ran by immutable image ID and cleanup removed the owned server, containers and disposable run directory. Actual Node fixture lock from the Claude container worktree kept `https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz` (`.agent_temp/s07/node-active-lock.json`).
- An outer scratch zsh wrapper exited 1 with `zsh:24: read-only variable: status`. Before the run ended, a Darwin `NOTE_EXITSTATUS` observer registered against actual Bash profile PID 30407. The observer recorded raw wait status 0 and exit 0 independently of zsh (`.agent_temp/s07/node-child-exit.json`), after calibrating the observer against a child exiting 37. The profile scripts and inputs were untouched. The final matrix uses the command directly in an exec session.

### Chain Attestation for independent review

- OC01: S01, S03–S05 and TI01–TI06 show both providers install and test under the granted npm environment. The fake origin and real Docker path preserve packument data, encoded scoped paths and tarball bytes. The pinned-client probe keeps the public lockfile URL and confirms `npm ci` uses the mirror.
- OC02: S06/S07 and TI02/TI03 show the existing rule and grant apply to both adapters, and S03 proves the restricted listener and variables are absent in Docker. S02/TI07 remains pending for the final unflagged four-case matrix after review.
- OC03: S08/TI02 and TI08 join authority, ecosystem, path and status in focused tests, the live profile's owned audit evidence, and the architecture, guide and figure. TI09's acceptance status is still gated on the unflagged matrix.
- Inherited ownership and final fixture requirements: the unchanged registry surface, bridge, transport limits, grant and container manager pass the scoped diff check. The recorder reads the server's routed audit outputs through the existing profile and keeps the existing command trace recognizer and failure rules.
- Inherited lifecycle, approval and toolchain requirements: the Node profile kept its five workspace tasks per provider, retained the auth-clean skill boundary and zero new system-home rollouts, and cleaned its disposable resources. No workflow hold was bypassed. The existing recipe and `/tmp` cache suffice, and the pinned origin and audit variables appear only in the granted environment.

### Review, repairs and final proof inputs

Reviewed: Quick code and FIS gap review fixed baseline refusal handling and strengthened the npm-to-pub redirect proof. One audit snapshot limitation remains a Note.

- Baseline regression failed first with `AssertionError: 1 != 0`. `--baseline` keeps existing command-linked failure semantics and reports refusals. Normal qualification requires zero host registry refusal events and a served decision for the selected ecosystem. The redirect test now tries pub's pinned origin from npm, so globally searching both adapters' pins cannot pass it. Reviewer reran 15 Python tests, 61 focused Dart tests and the exact refusal selector; format, Bash syntax, XML and diff checks passed. See `.agent_temp/s07/review/code-gap.md`.
- The final audit regression first failed with `AssertionError: Lists differ` on the missing transport rows. A routed audit block and its paired event increment refusal once. Independent host queue and late-cap signals count separately, MCP events are excluded, and an upstream 404 remains a served request. The original Node server logs independently contain zero `registry: ` guard-block events. Host-observed registry refusals are the qualification boundary (Resolution Ladder rung 2). The client bridge can reject an unforwarded request locally, for example a full local waiting queue. This does not write a host audit record and has no new protocol path under SC02.
- The real SecurityWiring composition test observed two routed 405 refusals and one 400 transport refusal, with one `GuardBlockEvent` per request. Docker suite after this addition: exit 0, `00:29 +4: All tests passed!`. S03's exact npm selector: exit 0, `00:12 +2: All tests passed!`. Mutations of npm metadata classification, audit environment and the SecurityWiring denial callback each failed their owning tests. Restored code is used for both final suite and matrix.
- Routing: Note. The recorder reads persisted host audit evidence after workflow settlement and before the server's shutdown flush. `GuardBlockEvent` persistence is asynchronous. No missing audit event was observed. The disposable server still flushes on existing teardown. Review report above.
- Both 1000×694 SVG themes were independently inspected in default, hover and keyboard states. Zero P1/P2, with one inherited P3 native outline spanning the active node and its details. Boy Scout tidy retains the figure's 2.8 px node focus ring and draws no duplicate native outline. Pointer hover while another link has keyboard focus now shows just the hovered detail panel. Both themes were recaptured and looked at after these two CSS adjustments. `xmllint` exit 0, computed focus and hover checks passed, and Chromium reported no errors. Captures: `.agent_temp/s07/visual/`, including `*-final-default.png`, `*-final-keyboard.png` and `*-final-hover.png`.
- TI08 grep exited 0 for each of the architecture, guide and SVG, and the 0.28.1 changelog grep exited 0. The adjacent npm entry preserves the existing pub entry and the user's pre-existing changelog edits. The entire changelog is left uncommitted for the plan owner.
- The unflagged final matrix builds the existing recipes during setup. The build changed both outer Docker image IDs while preserving their platform, layer digests and config, measured by `.agent_temp/s07/matrix-before-*-image.txt` and `matrix-setup-*-image.txt`. The setup IDs are the proof inputs for provider turns. Both Linux bridges were rebuilt before the profile.

### Exact bound test results

Each selector was run through the documented run-one-test command. The path prefix for the gateway tests is
`packages/dartclaw_runtime/test/container/gateway/`.

| Proof | Selector | Result |
|---|---|---|
| S04 / TI01 | `npm_registry_adapter_test.dart#serves packuments unmodified` | exit 0, `+1: All tests passed!` |
| TI01 | `npm_registry_adapter_test.dart#client environment points npm_config_registry at the npm route and disables audit` | exit 0, `+1: All tests passed!` |
| S05 / TI02 | `registry_bridge_surface_test.dart#passes a scoped npm package path to the origin with its slash encoded` | exit 0, `+1: All tests passed!` |
| S06 / TI02 | `registry_bridge_surface_test.dart#applies the refusal rules to every registered adapter` | exit 0, `+1: All tests passed!` after review |
| S06 / TI02 | `registry_bridge_surface_test.dart#keeps each route on its own origin` | exit 0, `+1: All tests passed!` |
| S08 / TI02 | `registry_bridge_surface_test.dart#records served npm requests under the npm ecosystem` | exit 0, `+1: All tests passed!` |
| S07 / TI03 | `packages/dartclaw_runtime/test/container/container_manager_test.dart#registry client environment carries every registered ecosystem for a granted authority only` | exit 0, `+1: All tests passed!` |
| TI03 parity | `packages/dartclaw_runtime/test/container/container_manager_test.dart#registry client environment is set only for a granted authority` | exit 0, `+1: All tests passed!` |

- Fast tier on reviewed sources: exit 0, 12,035 passed, 59 conditional skips. Kernel 1,433, core 1,757 (19 conditional skips), search 62, workflow 2,150 (11), runtime 5,776 (26), CLI excluding slow 857 (3). Analysis reported `No issues found!`. Both integration proof selectors ran separately. Full tier remains with the plan owner under `--no-full-tier`.
- Workspace format exited 0, `Formatted 2243 files (0 changed)`, and diff check found no whitespace errors. The package namespace, bridge/kernel/manager/surface diff, wiring and test-substance scans passed. Implementation and fixture commands use the existing composition and recorder, with no new model-output parser.

### First unflagged run and fixture boundary diagnosis

- `DARTCLAW_CONTAINER_DATA_DIR=/Users/tobias/.dartclaw bash dev/testing/profiles/container/coding.sh` -> exit 1. Exact runner output: `FAIL: Install, test or workflow failed; see recorded command output.` and `claude/node: awaitingApproval; install=0; test=0; Codex steps=0`. The profile stopped before both Codex cases. Receipt: `.agent_temp/container-coding/20261117T211957Z.I5R30s/`. The frozen pre/post comparison found zero changed inputs among 2,610.
- Claude's Dart run `348c2315-dfba-4437-91b2-df934d4f4750` completed with install/test 0/0, five workspace tasks and 774 served/0 refused. The stopped Claude Node run `9a0b6d75-ac1e-4a15-a15e-41bea748e3f7` had install/test 0/0 and 22 served/0 refused. Both orderly server logs match their captured audit counts, including zero host registry refusals after shutdown.
- The structured review outcome was `needsInput`. The exact reason starts `Review cannot proceed: the andthen:review skill is not installed in this environment, and the worktree's broken git metadata (gitdir pointing to an unmounted host path) cannot be repaired because the harness denies all write attempts to .git files under don't-ask mode.` No person-owned execution-surface hold was recorded. The failed review opened its generated FIS without reading the original story. `FEATURE` reaches spec generation and the subsequent review/ship inputs are the FIS and artifacts.
- Resolution Ladder rung 2 and sanctioned rung 4 confirmed the S02 qualification-only auth-clean exception. Both original fixture stories now require carrying that exception into the generated FIS. It asks the model to check and disclose actual skill availability, carry out fixture work from visible source and recorded results, and honor the unchanged review/structured output contracts and genuine holds. No workflow definition, provider plugin, mount, approval condition or host output parser changed. The frozen failed run supplies the semantic red, and a new normal matrix is required to prove the fixture instruction works.
- The failed run also reported `rm: /Users/tobias/Repos/Libs/dartclaw/dartclaw-public/.agent_temp/container-coding-run.jqjyjw: Directory not empty`. The disposable root contained only a newly written `.DS_Store` and Docker reported no owned container. The leftover was removed after inspection without changing profile cleanup.
- A fresh narrow fixture-only code+gap review returned zero findings. It checked both appended paragraphs were byte-identical, read the S02 exception and ADR-040, confirmed the original `FEATURE` to generated FIS handoff in the unchanged workflow, and verified that genuine findings and person-owned holds remain binding. The full independent S07 review remains the earlier reviewed line.
- Before the next unflagged profile the bridge was rebuilt again. Comparing its `final-before.json` with the failed matrix's `matrix-red-after.json` found exactly the two fixture `story.md` paths changed. The recorder suite remained 15 passing tests. Both recipe builds retained the same platform, layer and config bytes at setup.

### Second unflagged run and command evidence diagnosis

- `DARTCLAW_CONTAINER_DATA_DIR=/Users/tobias/.dartclaw bash dev/testing/profiles/container/coding.sh` -> exit 1. Exact runner output: `FAIL: Acceptance command evidence missing from persisted tool traces.` and `codex/dart: completed; install=None; test=None; Codex steps=5`. Receipt: `.agent_temp/container-coding/20261117T214130Z.u9zOpL/`. All three executed rows completed with five workspace tasks and no new system-home DartClaw rollouts. Claude Dart had 0/0 and 774 served/0 refused, Claude Node had 0/0 and 18/0, Codex Dart had 392/0. Shutdown audit logs match all three. No disposable resources remained. The pre/post 2,610 input hashes were identical.
- The fixture-boundary repair worked. Claude Node's generated FIS and retained actual integrated-review report disclose the unavailable native `andthen:review` and unreachable Git metadata, and that previously failing review now completed with a real artifact. The preceding Claude Dart report shows the same. Receipts: `.agent_temp/s07/final-claude-{dart,node}-{generated-fis,integrated-review}.md`.
- Codex Dart implementation first recorded ``Could not find `bin/test.dart` in package `test`.`` and exit 65 when testing before install. Its worktree package config pointed to the previous container's `/tmp/pub-cache`. Docker confirmed each authority's separate 100 MiB tmpfs. Integrated review installed in its container and both of its separately marked commands exited 0. In ship, the latest shell call combined install, test and Git probes, printed two `DARTCLAW_ACCEPTANCE_EXIT=0` markers, and exited 0 for the whole shell call. The recorder assigned neither command an exit because the latest result had two unattributed markers, preserving the original fail-closed rule.
- The revised fixture protocol now applies the original per-command shell wrappers in every phase that reruns acceptance commands, and the spec phase copies it into the FIS. A fresh authority installs before testing. Each call carries one command and its own marker. The red live run proves the missing handoff. The recorder and its existing ambiguous/latest-attempt regressions stay unchanged, as do all workflow, approval, Git and container seams.
- Routing: Note. In this attempt Codex Dart also wrote `total.dart` during specification despite the unchanged planning-only instruction. The later distinct implementation task made its own edit. Integrated review after that edit ran and passed both commands. Raw tool traces preserve this phase-order deviation. The scenario's terminal acceptance is decided by the original strict per-command evidence, workflow status, workspace placements, source fixture hashes, audit counts and rollouts. No host phase gate or repair was added.

### Third unflagged run and skipped review inputs

- `DARTCLAW_CONTAINER_DATA_DIR=/Users/tobias/.dartclaw bash dev/testing/profiles/container/coding.sh` -> exit 1. Exact runner output: `FAIL: Install, test or workflow failed; see recorded command output.` and `claude/dart: awaitingApproval; install=0; test=0; Codex steps=0`. The first row `8b4921f8-9913-43d3-9a35-4d1656073c5c` had 537 served/0 refused, matching complete shutdown logs. No later case ran. Receipt: `.agent_temp/container-coding/20261117T220951Z.xKCuZR/`. The 2,610 pre/post input hashes matched and the profile cleaned its disposable resources.
- The generated FIS carried both capability and per-call command rules, captured in `.agent_temp/s07/qualified-claude-dart-generated-fis.md`. The integrated review did not open that FIS, the fixture story or source/tests. Its exact trace used the provider's `security-review` skill instead, probed and tried to repair inaccessible Git metadata, and returned structured `needsInput`. The harness refused the attempted repairs. The reason starts `Git worktree metadata is broken inside the container (.git file references a host-only path) and the actual .git directory lives outside the declared workspace boundary, so git commands cannot run.` It ended `No review was performed and no report was written.` No execution-surface hold was recorded.
- The first and third failures now establish that a fixture instruction reachable only through the generated FIS cannot guide a review that stops before reading it. No fourth unchanged-input matrix was launched. The command result and all raw refusal evidence remain intact.
- The plan session authorized fixture-owned native project guidance as the least scope that reaches this earlier decision. `coding.sh` copies one canonical `fixtures/project-instructions.md` into both native instruction filenames before the first commit of each disposable fixture. The pointer asks the reviewer or ship step to read the generated FIS before choosing tools. It adds no qualification rules beyond the existing story/FIS contract. A fresh narrow review returned zero findings. Bash syntax and diff checks passed. The production Prompt Surfaces inventory scopes library and bundled workflow/skill authoring sites. This disposable test fixture sits outside that scope.
- The targeted Claude/Dart probe uses the normal provider and container harness path. Before it started the bridge was rebuilt. Its 2,611-file input manifest differs from the previous attempt only in `coding.sh` and the new fixture pointer. Both initial commit copies were regular files and matched source SHA-256 `174521e9ea440bd075de7eeb31fd982fa7e262af87685a928148389b0a2f2a97`. Official Claude docs confirm [headless print mode](https://code.claude.com/docs/en/headless#start-faster-with-bare-mode) loads project `CLAUDE.md` without `--bare`, and [current directory settings](https://code.claude.com/docs/en/memory#how-claude-md-files-load) are discovered at launch. The live behavior is the proof for the installed CLI version.
- Targeted same-harness probe `coding.sh --provider claude --fixture dart` -> exit 0, `claude/dart: completed; install=0; test=0; Codex steps=0`. Run `58a32d05-085c-4a2b-aee6-03e46deebbb2`, five workspace tasks, 846 served and zero refused after shutdown. Receipt: `.agent_temp/container-coding/20261117T222100Z.L132TM/results.md`. The first review work calls located and opened the generated FIS before any skill or Git call, then read the implementation and tests. Its actual artifact `.agent_temp/s07/pointer-probe-claude-dart-integrated-review.md` records native skill unavailability, Git limits and two separate successful acceptance results. The documented autoload behavior and ordinary committed files establish the expected native input path. The trace proves the behavior in the installed auth-clean harness without visibility into its internal context assembly.
- All 2,611 inputs compared identical before and after the selected probe. The bridge was rebuilt before the next unflagged matrix, with identical source/script/fixture/binary hashes. That matrix uses the ordinary two-recipe setup.

### FR9 final proof

- `DARTCLAW_CONTAINER_DATA_DIR=/Users/tobias/.dartclaw bash dev/testing/profiles/container/coding.sh` -> exit 0. The final runner line was `codex/node: completed; install=0; test=0; Codex steps=5`. Receipt: `.agent_temp/container-coding/20261117T223104Z.wQUKgu/results.md` and its sibling JSON, tool traces, audit and shutdown logs.

| Provider | Fixture | Run | Install | Test | Workspace tasks | Registry served | Registry refused |
|---|---|---|---:|---:|---:|---:|---:|
| Claude Code | Dart | `2ea2b44d-c9f2-43b3-a1fa-5ffd4ea48fe2` | 0 | 0 | 5 | 774 | 0 |
| Claude Code | Node | `68ee163d-8d72-48a5-b480-38195cca3295` | 0 | 0 | 5 | 22 | 0 |
| Codex | Dart | `dc3d6ad3-5a6c-424c-8138-7cdfbce3afee` | 0 | 0 | 5 | 294 | 0 |
| Codex | Node | `c64d3016-2d9e-4a51-b5fe-4fb1ebc31fb3` | 0 | 0 | 5 | 6 | 0 |

- All four CLI and workflow verdicts succeeded. The latest attributable command results came from each ship task. The final specification traces wrote only their FIS files. Both Codex cases completed five steps and added zero system-home DartClaw rollouts. Both Node audit files contain successful lodash packument and tarball requests. Both Dart lock files use the pub mirror. The original source fixtures, checkout, workflow roles, and approval rules are preserved.
- Each stopped server's complete log independently agrees with the row's served and refused counts. The four comparisons and final row assertions are in `.agent_temp/s07/pointer-matrix-audit-reconciled.log` and `pointer-matrix-summary.log`. This verifies the actual receipts across shutdown alongside the review's general audit-timing Note.
- There were 2,611 identical pre/post fixture, script, source and bridge input hashes. Both recipe platform, layer and configuration hashes match the pre-setup images, and both post-setup image records are byte-identical before and after all provider turns. The disposable root and all four owner labels were absent after cleanup. Both Linux bridge builds retained their S06 hashes. The FIS references and artifacts for all four runs were saved as `.agent_temp/s07/pointer-matrix-*-generated-fis.md` and `*-integrated-review.md`.
- TI06/TI07 exact heading greps exited 0. TI09 Accepted/date, registry-host replacement and response-URL invariant checks exited 0. The changelog and all S07 document checks passed. The full tier and candidate-wide checks are the plan owner's scope.

### Final Chain Attestation

- OC01: S01/S03/S04/S05 and TI01–TI06 establish npm install and tests under the workspace bridge, real Docker scope and byte preservation, plus canonical public tarball URLs from the pinned npm client's install and ci.
- OC02: S02/S06/S07 and TI02/TI03/TI07 establish same-adapter pins, GET/HEAD-only and workspace-only rules, and a green unflagged matrix with distinct attributable command results. The restricted Docker path lacks both npm variables and a listener.
- OC03: S08 and TI02/TI08/TI09 establish routed npm request records, zero recorded refusals reconciled against shutdown logs, and both pinned origins in the guide, architecture and validated figure. ADR-062 is Accepted after both live command proofs.
- Inherited registry ownership: the adapter preserves S06's single origin matcher, immutable grant and frame writer/cap/refusal owners, as confirmed by the focused and Docker suites and empty protected-source diff.
- Inherited final fixture contract: the final matrix used strict latest-attempt command evidence after implementing real code. Both Dart rows re-resolved through the expected mirror. The prior ambiguity and phase-order observation are retained separately.
- Inherited lifecycle: the exact profile captured actual phases, worktree artifacts, fixture and image hashes and teardown, distinguishing installed provider skills from the auth-clean fixture's available tools.
- Inherited person-owned execution holds: the three red attempts preserved model-requested approval and strict command evidence. The fixture repairs changed evidence visibility and command instructions, and the unchanged workflow and guards enforce mandatory person-owned decisions.
- Inherited toolchain settings: actual recipe images retain their S05 layers and config, and the pinned npm probe and measured caches support the existing toolchain recipes within the 100 MiB tmpfs.
