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
