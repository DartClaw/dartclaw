# S10: Registry ecosystems as config

**Plan**: dev/bundle/docs/specs/0.28.1/plan.json
**Story-ID**: S10

## Feature Overview and Goal

**Intent**: Stories S06 and S07 hard-coded pub and npm as one Dart adapter class each, so a Python, Rust or Go project still cannot install dependencies in a container and every new ecosystem waits on a DartClaw release, although an ecosystem is four values with no logic. This story makes ecosystems instance-config data per ADR-062's 2026-11-18 amendment, ships PyPI, crates.io and (opt-in) Go beside pub and npm, and gives `workspace` containers a package cache that disappears with them.

**Expected Outcomes**:

- [OC01] Python (uv), Rust (Cargo) and, with Go enabled in the instance config, Go projects install their dependencies and pass their tests in a `workspace` container under `network:none` with Claude Code and with Codex, and the Dart and Node fixtures still pass.
- [OC02] An operator adds, replaces or disables a registry ecosystem in the instance config without a DartClaw release, and a record that is malformed, would widen egress past an exact HTTPS origin, or would shadow a variable DartClaw sets stops startup instead of being defaulted.
- [OC03] Each `workspace` container has a writable, executable package cache that is removed with it; every registry request is auditable with its full path and query; the guide tells operators how to extend images and records and what an added origin exposes.


## Required Context

Paths are relative to the public repo root (`../dartclaw-public/` from the private repo), where this FIS executes from its exported copy and where `cmd:` proofs run; `docs/specs/` paths name this plan's private sources, exported to `dev/bundle/docs/`.

- `docs/specs/0.28.1/prd.md#fr9-read-only-package-registry-egress` – the acceptance criteria amended on 2026-11-18 for config-driven ecosystems; this story covers those amendments and reruns the rest.
- `dev/adrs/062-read-only-package-registry-egress-for-containers.md` – binding: the Decision table (rows "Ecosystems as data", "Built-ins (0.28.1)", "Upstreams", "Package caches", "Audit") and Implementation Notes. The plan's `sharedDecisions` entry "Registry ecosystem adapter seam" is superseded by this amendment.
- `docs/specs/0.28.1/s06-registry-bridge-surface-with-pub.md` and `s07-npm-registry-adapter.md` (executed copies, with Implementation Observations) – the surface rules this story keeps (methods, header drops, pinned redirects, limits, refusal events), the tests it migrates, and the pub and npm client facts.
- `docs/specs/0.28.1/s02-live-containerized-workflow-proof.md` – `coding.sh`, its flags, results file, refusal count and teardown rules.
- `docs/specs/0.28.1/s05-agent-image-toolchain-recipe.md` – the recipe pattern, the guide subsection `### Language Toolchains in the Agent Image` and its mirror rule (its SC01).


## Acceptance Scenarios

- **S01 [OC01] [runtime] A Python project installs and passes its tests in a workspace container**
  - **Given** a container runtime, host-held Claude Code and Codex credentials, a bridge binary built from this candidate, and a uv project fixture with one runtime dependency and `pytest`, built into a Python recipe image
  - **When** the maintainer runs the scenario on the Python fixture for both providers, without `--baseline`
  - **Then** each provider's results row shows `uv sync` and `uv run pytest` exiting 0 inside the container, every task has a `container_json` naming `workspace`, the row records served `pypi` requests and zero refused ones, and the command exits 0
  - **Proof**: `cmd: bash dev/testing/profiles/container/coding.sh --fixture python` – exit 0

- **S02 [OC01] [runtime] A Rust project installs and passes its tests in a workspace container**
  - **Given** the same prerequisites and a Cargo fixture with one dependency from crates.io, built into a Rust recipe image whose Cargo `config.toml` replaces crates.io with `sparse+http://127.0.0.1:8082/crates/`
  - **When** the maintainer runs the scenario on the Rust fixture for both providers, without `--baseline`
  - **Then** each row shows `cargo fetch` and `cargo test` exiting 0, workspace placement on every task, served `crates` requests on both its routes (`/crates/` and `/crates-dl/`), zero refused, and exit 0
  - **Proof**: `cmd: bash dev/testing/profiles/container/coding.sh --fixture rust` – exit 0

- **S03 [OC01] [runtime] A Go project installs and passes its tests once Go is enabled in the instance config**
  - **Given** the same prerequisites, a Go module fixture with one external dependency and no committed `go.sum`, built into a Go recipe image, and the scenario's rendered instance config enabling the `go` record (the built-in ships disabled)
  - **When** the maintainer runs the scenario on the Go fixture for both providers, without `--baseline`
  - **Then** each row shows the fixture's install command and `go test ./...` exiting 0, workspace placement on every task, served `go` requests on the `/go/` route and on the `/gosum/` route (checksums verified through the mirrored checksum database), zero refused, and exit 0
  - **Proof**: `cmd: bash dev/testing/profiles/container/coding.sh --fixture go` – exit 0

- **S04 [OC01] [runtime] The full matrix passes unflagged, Dart and Node included**
  - **Given** the same prerequisites with every recipe image
  - **When** the maintainer runs the scenario with no flags
  - **Then** all five fixtures (dart, node, python, rust, go) pass for both providers, ten rows, and the command exits 0; the Dart row still shows the documented `pubspec.lock` mirror diff
  - **Proof**: `cmd: bash dev/testing/profiles/container/coding.sh` – exit 0

- **S05 [OC01] [runtime] Each new client fetches through the mirror with no network and no model**
  - **Given** `workspace` authorities whose records pin a loopback fake origin per ecosystem, serving PEP 691 JSON naming files on a second pinned origin, a sparse index with `config.json` and a `.crate`, and a module proxy, plus the matching recipe images
  - **When** a process in each container resolves and downloads one package with `pip` and with `uv` (from `PIP_INDEX_URL` / `UV_DEFAULT_INDEX`), with `cargo fetch`, and with `go mod download` (from `GOPROXY`)
  - **Then** each succeeds under network mode `none`, every file URL the client fetched went through the mirror route of the pin that hosts it, and a `restricted` container has none of those variables and no route
  - **Proof**: `cmd: for c in pypi crates "go module"; do dart test --run-skipped -t integration packages/dartclaw_runtime/test/integration/registry_bridge_integration_test.dart --name "$c" || exit 1; done` – exit 0 with at least one case run per name, red at spec time (no such case exists)

- **S06 [OC01,OC02] The built-in records give a workspace container exactly these client variables**
  - **Given** an instance config with no `container.registries` key
  - **When** a `workspace` and a `restricted` container are created
  - **Then** the `workspace` container carries exactly the `env` below for the enabled built-ins, with `{mirror}` expanded to `http://127.0.0.1:8082`, and the `restricted` one carries none; `go` contributes nothing until enabled
  - **Proof**: `packages/dartclaw_runtime/test/container/container_manager_test.dart#built-in registry records give a workspace container their client variables` – red at spec time

  | Record | `enabled` | `upstreams` (route → origin) | `env` | `rewrite_json` (route, path prefix, content types) |
  |---|---|---|---|---|
  | `pub` | true | `pub` → `https://pub.dev` | `PUB_HOSTED_URL={mirror}/pub` | `pub`, `/api/packages/`, `application/json` |
  | `npm` | true | `npm` → `https://registry.npmjs.org` | `npm_config_registry={mirror}/npm/`, `npm_config_audit=false` | none |
  | `pypi` | true | `pypi` → `https://pypi.org`; `pypi-files` → `https://files.pythonhosted.org` | `PIP_INDEX_URL={mirror}/pypi/simple/`, `UV_DEFAULT_INDEX={mirror}/pypi/simple` | `pypi`, `/simple/`, `application/vnd.pypi.simple.v1+json` |
  | `crates` | true | `crates` → `https://index.crates.io`; `crates-dl` → `https://static.crates.io` | none | `crates`, `/config.json`, `application/octet-stream` |
  | `go` | false | `go` → `https://proxy.golang.org`; `gosum` → `https://sum.golang.org` | `GOPROXY={mirror}/go`, `GOSUMDB=sum.golang.org {mirror}/gosum`, `GOTOOLCHAIN=local` | none |

- **S07 [OC02] An operator disables, replaces or adds a record in the instance config**
  - **Given** an instance config whose `container.registries` sets `npm: {enabled: false}`, redefines `pub` with a different origin and no `rewrite_json`, and adds `hex` with one upstream and an `env` and no `enabled` key
  - **When** the config loads and a `workspace` container is created
  - **Then** npm has no route and no variable; `pub` is exactly the operator's record (no field of the built-in survives, so pub metadata is no longer rewritten); `hex` is enabled, routed and its variable set; the other built-ins are unchanged; and with every record disabled no authority is granted the `registry` surface or any registry variable
  - **Proof**: `packages/dartclaw_kernel/test/container_registries_test.dart#instance records disable, replace and add built-ins by name` and `packages/dartclaw_runtime/test/container/gateway/host_gateway_test.dart#grants the registry surface only while an enabled record exists` – red at spec time

- **S08 [OC02] A malformed or egress-widening record refuses to load**
  - **Given** instance configs each carrying one enabled record with: an `http://` origin; userinfo in an origin; a path, query or fragment on an origin; an IPv4 or IPv6 literal host; a route reused within or across enabled records; a route that is not one path segment of lowercase letters, digits and hyphens; an `env` key another enabled record also sets (keys compare case-insensitively, as npm reads `npm_config_registry` and `NPM_CONFIG_REGISTRY` as one setting); an `env` key that is not a POSIX variable name; no upstreams; a `rewrite_json` route the record does not define; a value of the wrong type for any field
  - **When** each config loads (`dartclaw serve`, and `dartclaw doctor` through the same load)
  - **Then** each load fails with a message naming the offending `container.registries.<name>…` path and the rule, nothing is defaulted or dropped, and a disabled record is not held to the upstream, route or `env` uniqueness rules
  - **Proof**: `packages/dartclaw_kernel/test/container_registries_test.dart#refuses each invalid registry record naming its path` – red at spec time

- **S09 [OC02] A record cannot shadow a variable DartClaw sets in the container**
  - **Given** an instance config whose enabled record sets `ANTHROPIC_BASE_URL`, and one setting `CODEX_HOME`
  - **When** `dartclaw serve` starts, under an explicit and under an inferred container posture
  - **Then** startup fails in both cases naming the record, the key and that DartClaw sets it; and for valid records the container's create arguments carry every registry `-e` before DartClaw's own `-e ANTHROPIC_BASE_URL=…`
  - **Proof**: `packages/dartclaw_runtime/test/runtime/security_wiring_container_isolation_test.dart#refuses a registry record that sets a variable DartClaw sets` and `packages/dartclaw_runtime/test/container/container_manager_test.dart#registry variables precede the variables DartClaw sets` – red at spec time

- **S10 [OC01] JSON metadata is rewritten only where the record's rule says, and only to that record's pins**
  - **Given** the `pypi` and `crates` built-ins pinned to loopback fake origins, and a fake origin serving the same JSON under several paths and content types, with URLs on the record's pins, on another record's pin and on an unpinned host
  - **When** the container requests `/pypi/simple/pkg/` served as `application/vnd.pypi.simple.v1+json` (also with a `; charset` parameter, also gzip-encoded, also reached through a same-origin 301 from `/pypi/simple/pkg`), the same body as `text/html`, the same body under `/pypi/pypi/pkg/json`, and `/crates/config.json` served as `application/octet-stream`
  - **Then** only the first and last are rewritten: a `files.pythonhosted.org` URL becomes `http://127.0.0.1:8082/pypi-files/…`, `config.json`'s `dl` becomes `http://127.0.0.1:8082/crates-dl/crates` while its unpinned `api` stays `https://crates.io`, URLs of another record's pins and of unpinned hosts are unchanged, and the other responses are byte-identical to the origin's
  - **Proof**: `packages/dartclaw_runtime/test/container/gateway/registry_bridge_surface_test.dart#rewrites JSON only by the record rule and only to its own pins` – red at spec time

- **S11 [OC03] Every request is audited with its query; refusal messages still carry none**
  - **Given** a `workspace` authority served `/pypi/simple/pkg/?format=json` and refused `POST /pypi/simple/?secret=hidden`
  - **When** both settle
  - **Then** both audit records carry the authority, `pypi`, the path including its query, and the status; the refusal's `GuardBlockEvent` reason names `pypi` and the rule and contains no query text
  - **Proof**: `packages/dartclaw_runtime/test/container/gateway/registry_bridge_surface_test.dart#records each request with its query and keeps refusal reasons query-free` – red at spec time

- **S12 [OC03] [runtime] Workspace containers get a package cache that is removed with them**
  - **Given** a `workspace` and a `restricted` authority on the stock image, one in the `create`/`start` lifecycle and one in the `run --rm` (volatile generated state) lifecycle
  - **When** each container runs a probe as uid 1000, then is released
  - **Then** in `workspace` containers `/var/cache/dartclaw` is writable and a script written there executes while `/tmp` stays `noexec`; in `restricted` it is not writable; after release no volume of either `workspace` container remains; and every removal DartClaw issues (stop, stale-name removal before create, orphan reclaim) removes anonymous volumes
  - **Proof**: `cmd: dart test --run-skipped -t integration packages/dartclaw_runtime/test/integration/registry_bridge_integration_test.dart --name "package cache"` – exit 0 with at least one case run, red at spec time; plus `packages/dartclaw_runtime/test/container/container_manager_test.dart#workspace containers get an anonymous package cache that every removal deletes` – red at spec time


## Structural Criteria

- **SC01** Ecosystem knowledge has one home: `registry_adapter.dart`, `pub_registry_adapter.dart`, `npm_registry_adapter.dart` and their two adapter tests are deleted; no origin or client variable of any built-in appears under `packages/*/lib` outside the kernel's `container_registries.dart` and NetworkGuard's pre-existing host allowlist; the surface, gateway and container manager name no ecosystem.
- **SC02** The container boundary changes only by the `workspace` cache volume and the registry variables' position: `--network none`, dropped capabilities, read-only root, the `/tmp` tmpfs and every other mount are unchanged per authority; `bridgeProtocolVersion` stays `1` and `packages/dartclaw_bridge` is untouched.
- **SC03** Registries are instance config only: `container.registries` is a `ConfigMeta` field read by `DartclawConfig`'s container section alone, `readonly` (file-only, applied at startup, never written through the API, matching `container.enabled`, because it sets egress pins), and the generated schema, the generated config reference and the config advisory golden match it.
- **SC04** The docs state what shipped: `docs/guide/security.md` (registries section with the S06 table, recipes for Python, Rust incl. its Cargo `config.toml` and its route contract, Go incl. enabling `go` and why it ships off, the operator-pin exfiltration warning, Maven/RubyGems/NuGet/Hex as unproven config-only examples, Composer/Gradle/Poetry/SwiftPM/CocoaPods as unsupported with the reason, the `uv.lock` drift beside pub's, the package cache), `docs/guide/configuration.md`, `dev/architecture/security-architecture.md` (§ Host-Owned Provider Mediation and the threat rows), `security-host-gateway.svg`, the runtime and kernel `AGENTS.md`, and `CHANGELOG.md` 0.28.1.
- **SC05** ADR-062 records the outcome: its amendment line reads Accepted with a date only after scenarios S01–S04 pass for every built-in it lists, its Implementation Notes carry the client facts the fixtures settled, and its Project Compliance "one authority" line names the records instead of adapters.


## Scope & Boundaries

### Work Areas

- `packages/dartclaw_kernel/lib/src/` – `container_config.dart` (registries field, equality), new `container_registries.dart` (record value type and built-in records), `config_meta/server_fields.dart` (`container.registries`); tests `container_config_test.dart`, new `container_registries_test.dart`.
- `schemas/dartclaw.schema.json`, `docs/guide/configuration.md` generated region, `dev/tools/config_reference_core_keys.txt`, `packages/dartclaw/test/goldens/config_advisory_baseline.txt` – regenerated.
- `packages/dartclaw_runtime/lib/src/container/gateway/` – `registry_bridge_surface.dart`, `host_gateway.dart` on records; the three adapter files deleted.
- `packages/dartclaw_runtime/lib/src/container/container_manager.dart`, `security_profile.dart`, `runtime/security_wiring.dart`, `runtime/provider_resolution.dart` (reserved-key set) – cache volume, removals, env order, wiring from config, reserved-key refusal.
- Runtime tests: `registry_bridge_surface_test.dart`, `host_gateway_test.dart`, `container_manager_test.dart`, `security_wiring_container_isolation_test.dart`, `test/integration/registry_bridge_integration_test.dart`; `pub_registry_adapter_test.dart` and `npm_registry_adapter_test.dart` deleted after their assertions move.
- `docker/Dockerfile`; `dev/testing/profiles/container/` – `coding.sh`, `coding_config.dart`, `data/coding.yaml`, `coding_results.py`, `coding_results_test.py`, `fixtures/{python,rust,go}/`, `images/{dart,node,python,rust,go}.Dockerfile`.
- Docs per SC04 and ADR-062 per SC05.

### What We're NOT Doing

- A bun fixture – bun shares npm's record; the trailing slash it needs was established by a second-opinion experiment (Constraints).
- Built-in records for Maven, RubyGems, NuGet or Hex, or support for Composer, Gradle, Poetry, SwiftPM or CocoaPods – ADR-062 Built-ins row.
- Private or authenticated registries, path-prefixed mirrors, HTML or XML rewriting – ADR-062 Credentials, Negative and Response URLs rows.
- Project-level or API-editable registries, or hot reload of them – ADR-062 "Ecosystems as data" row; SC03.
- A cache size cap, a larger `/tmp` tmpfs, or a cache for `restricted` – ADR-062 Package caches row.
- Lockfile normalisation for pub or uv – accepted drift (ADR-062 Negative).
- Changing the grant rule, `BridgeLimits`, the bridge protocol, or NetworkGuard's host-mode allowlist.
- The DECISIONS row (already amended) and Ubiquitous Language ("Registry Surface" still holds).


## Architecture Decision

**Approach**: The kernel owns an immutable registry record value type and the built-in records as data; `ContainerConfig.fromYaml` overlays `container.registries` on the built-ins by name (whole-record replacement) and validates once, throwing `FormatException` like `gateway.mcp_clients` does. The runtime takes the enabled records as given: `HostGateway` grants and expands `{mirror}`, `RegistryBridgeSurface` routes, pins, rewrites by rule and audits, and `SecurityWiring` refuses a record naming a variable DartClaw sets, from the runtime's one reserved-key set. `SecurityProfile.workspace` carries the cache volume. See ADR: `dev/adrs/062-read-only-package-registry-egress-for-containers.md`.
**Why this over the floor**: the floor is keeping `RegistryAdapter` and adding three classes; ADR-062's "Ecosystems as data" row (operators add, replace or disable an ecosystem without a release, built-ins as the same records) rules it out.
**Flow**: instance YAML → `ContainerConfig.fromYaml` (built-ins overlaid, validated) → `SecurityWiring` (reserved-key check, gateway from enabled records) → `HostGateway` (grant, `{mirror}` expansion) → `ContainerManager` (registry `-e` first, then DartClaw's; `workspace` cache volume) → `RegistryBridgeSurface` (route → pin, method and redirect rules, rewrite rule of the pin that answered, audit with query).


## Constraints & Gotchas

- **Validation has one author, and tests bypass it on purpose.** The record type validates nothing; only `fromYaml` does, so tests build records with loopback `http://127.0.0.1:<port>` origins directly, as they inject adapters today. The runtime never re-validates a record; its only check is the reserved-key one, which the kernel cannot make because the keys are set in core and runtime.
- **Reserved keys are every variable DartClaw passes into a container**: create-time `-e` (`ANTHROPIC_BASE_URL`) and per-exec `ContainerManager.exec(env:)` (Claude container hardening, `CODEX_HOME` and the rest). Derive the set from those sites; `provider_resolution.dart`'s spawn-reserved set already owns most of it and compares uppercased, so extend that owner rather than writing a second list.
- ASSUMPTION: `env` keys compare case-insensitively, against each other (scenario S08) and against the reserved set (scenario S09), because npm reads both spellings of its variables and the reserved-set owner already compares uppercased – a case-sensitive owner decision narrows only those two comparisons. A per-exec variable already wins over a container variable, and emission order makes `ANTHROPIC_BASE_URL` win; the refusal exists so an operator's value is never silently ignored.
- **The cache volume's ownership comes from the image.** A new anonymous volume copies the image's directory at that path, ownership included, so `docker/Dockerfile` must create `/var/cache/dartclaw` owned by uid 1000; without it the volume is root-owned and unwritable. macOS Docker Desktop remaps uids and hides this (`LEARNINGS.md` § Tooling / Verification); the integration case must assert the uid-1000 write, and the release check's Lima `linux` gate is the native proof. Do not place files a recipe depends on inside `/var/cache/dartclaw`: copy-up happens only into an empty new volume.
- **`/tmp` is `noexec`.** Go runs test binaries from `GOTMPDIR`, Cargo builds into the worktree's `target/`. Recipes point `PUB_CACHE`, `NPM_CONFIG_CACHE`, `PIP_CACHE_DIR`, `UV_CACHE_DIR`, `CARGO_HOME`, `GOMODCACHE`, `GOCACHE` and `GOTMPDIR` under `/var/cache/dartclaw` and keep `HOME=/tmp`; a `restricted` container sees that directory read-only. Move the Dart and Node recipes' caches there too and keep the guide mirror in step (story S05's SC01).
- **Removal must name volumes.** `docker rm -f` leaves anonymous volumes; `rm -f -v` removes them (Podman accepts the same flag). `container_manager.dart` has three removal sites (stop, stale-name removal in `start`, `reclaimOwnedContainers`); `run --rm` removes them itself. `coding.sh`'s `cleanup_server` uses `rm -f` too.
- **Fixtures need a `.gitignore`.** The host commit sweep commits the worktree: `.venv/` (uv) contains symlinks, and any added symlink holds the change under the execution-surface review (`task/execution_surface.dart`), and `target/` would be committed whole.
- **Recipe traps.** Rust links test binaries with a C linker the slim base lacks; Cargo has no environment variable for source replacement (Cargo config docs), so its `config.toml` lives in the image outside `CARGO_HOME` when that is on the volume, e.g. at `/.cargo/config.toml`, which Cargo's upward search reaches from any working directory. uv must use the image's Python (`UV_PYTHON_DOWNLOADS=never`). Go sets `CGO_ENABLED=0` unless the recipe installs a C toolchain.
- **Facts probed with curl on 2026-11-18, re-check at execution.** `https://index.crates.io/config.json` is `application/octet-stream`, body `{"dl":"https://static.crates.io/crates","api":"https://crates.io"}`; `static.crates.io/crates/<crate>/<version>/download` answers 200 without redirect. `pypi.org/simple/<pkg>` answers 301 to `/simple/<pkg>/`; the JSON response is `application/vnd.pypi.simple.v1+json` with absolute `files.pythonhosted.org` file URLs (PEP 691 also permits relative ones, which resolve against the mirror and need no rewrite). `proxy.golang.org/sumdb/sum.golang.org/supported` answers 404, so Go reaches the checksum database only through `GOSUMDB`'s URL, hence the `gosum` route.
- **Facts from official docs, looked up on 2026-11-18.** pip's `SECURE_ORIGINS` include `127.0.0.0/8` (no `--trusted-host`), pip's `Accept` prefers `application/vnd.pypi.simple.v1+json`, `PIP_INDEX_URL` and `PIP_CACHE_DIR` map to their options; `UV_DEFAULT_INDEX` supersedes the deprecated `UV_INDEX_URL`; `GOTMPDIR`, `GOMODCACHE` and `GOCACHE` mean what the recipes use them for; bun reads `NPM_CONFIG_REGISTRY`.
- ASSUMPTION: Cargo accepts a `sparse+http://` replacement registry, uv accepts a plain-HTTP loopback index without flags, Go accepts an `http://` `GOPROXY` and an `http://` URL in `GOSUMDB` (bypassing the proxy and using its built-in key), and `GOTOOLCHAIN=local` stops toolchain downloads – the docs do not state these; scenarios S01–S03 and S05 prove them. A failure fixable in the record or recipe is fixed there and named in Implementation Observations.
- ASSUMPTION: bun reads the lowercase `npm_config_registry` DartClaw sets and needs its trailing slash (second-opinion experiment with bun 1.3.9; bun's docs name only the uppercase spelling and are silent on the slash) – a contrary observation changes the npm record's value, not the surface.
- **Enabling a built-in that ships disabled is one line.** A same-name entry carrying only `enabled` toggles the built-in record (`go: {enabled: true}` turns Go on, owner decision 2026-11-18); an entry carrying any other field replaces the whole record. TI01, TI02, scenario S07 and the guide follow this; scenario S08's no-upstreams rule applies only to a replacing or added record.
- ASSUMPTION: Podman's anonymous-volume copy-up and `rm -v` match Docker's – scenario S12 runs on whichever runtime answers; a Podman difference is recorded, not worked around.
- **An ecosystem is admitted only by its passing fixture** (ADR-062 Built-ins row). One whose fixture still fails after in-scope fixes is removed from the built-in records, moved to the guide's config-only examples and ADR-062's Built-ins row, and named in the report; it never ships enabled unproven, and SC05's Accepted line waits for the rest.
- **A new `ConfigMeta` field reaches five artifacts**: the schema generator and `render_config_reference.dart` (`KEY_DEVELOPMENT_COMMANDS.md`), the advisory golden (`LEARNINGS.md`), `dev/fitness/test/config_key_consumers_test.dart` (every schema leaf needs a consumer) and `packages/dartclaw_runtime/test/web/settings_form_test.dart` (the `container` prefix already claims it). Nested leaves of an object map are matched under their parent block (`LEARNINGS.md`).
- ASSUMPTION: the live scenarios need Docker and host-held Claude Code and Codex credentials on the executing machine – an executor without them leaves S01–S04 and S12 open, keeps SC05's line Proposed, and reports it, never skips. Run `bash dev/tools/build_bridge.sh` first in a source checkout (story S06).
- **Written against the executed stories S02, S05, S06 and S07** and the tree on 2026-11-18; if names have moved since, apply the same edits by intent.


## Implementation Plan

### Implementation Tasks

- **TI01** `ContainerConfig` carries the effective registry records: the S06 table's built-ins as kernel data, overlaid by `container.registries` by name with whole-record replacement, `enabled` defaulting to true; `container.registries` is a `readonly` `ConfigMeta` object-map field whose entry shape declares `enabled`, `upstreams`, `env` and `rewrite_json`, and equality covers the records.
  - Follow `packages/dartclaw_kernel/lib/src/config_meta/server_fields.dart#gateway.mcp_clients` for an object entry and `packages/dartclaw_kernel/lib/src/config_meta/agent_fields.dart` for nested object fields.
  - **Verify**: `packages/dartclaw_kernel/test/container_registries_test.dart#built-in records match the documented set`, `packages/dartclaw_kernel/test/container_registries_test.dart#instance records disable, replace and add built-ins by name` – the table's exact values, no field merge on replacement, an omitted `enabled` reads true, an absent key yields the built-ins; `packages/dartclaw_kernel/test/container_registries_test.dart#container.registries is a file-only field` – its `FieldMeta` is `ConfigMutability.readonly` and `ConfigValidator` refuses a write to it.
  - **SATISFIES**: S06, S07, SC03

- **TI02** `fromYaml` refuses every invalid record of scenario S08 with a `FormatException` naming its path and rule, and holds disabled records to type checks only.
  - Follow `packages/dartclaw_kernel/lib/src/config_parser.dart#_parseMcpClients` refusals; `container.enabled`/`container.image` keep their warn-and-default handling.
  - **Verify**: `packages/dartclaw_kernel/test/container_registries_test.dart#refuses each invalid registry record naming its path` – one case per S08 bullet, each message containing the dotted path; plus a disabled record with an `http://` origin and a duplicate route loads.
  - **SATISFIES**: S08

- **TI03** `RegistryBridgeSurface` and `HostGateway` serve enabled records: route lookup over every record's upstreams, redirects within the record's pins, `{mirror}` expanded in `env`, the `registry` grant only while an enabled record exists, JSON rewrite when the pin that answered matches a rule's route, its upstream path starts with the prefix and its media type (parameters dropped, case-insensitive) is listed, URLs on the record's own pins mapped to their routes, and audit paths carrying the query; the adapter interface, both adapter classes and their tests are gone, their assertions moved onto built-in records with loopback origins.
  - Keep every S06/S07 surface test green with its intent intact; the one change is the audit path, which now carries the query (rename that test to S11's).
  - **Verify**: `packages/dartclaw_runtime/test/container/gateway/registry_bridge_surface_test.dart#rewrites JSON only by the record rule and only to its own pins` (all S10 variants), `packages/dartclaw_runtime/test/container/gateway/registry_bridge_surface_test.dart#records each request with its query and keeps refusal reasons query-free`, the migrated pub rewrite and npm unmodified-packument cases; `packages/dartclaw_runtime/test/container/gateway/host_gateway_test.dart#grants the registry surface only while an enabled record exists`.
  - **SATISFIES**: S07, S10, S11, SC01

- **TI04** `SecurityWiring` builds the gateway from `config.container.registries`, and startup refuses, in every container posture, a record whose `env` names a reserved key (Constraints), naming record, key and owner; `ContainerManager` emits registry `-e` pairs before DartClaw's.
  - The refusal is a config error, not a probe result, so it does not go through `_wireContainers`' `refuse` and its advisory downgrade.
  - **Verify**: `packages/dartclaw_runtime/test/runtime/security_wiring_container_isolation_test.dart#refuses a registry record that sets a variable DartClaw sets` – `ANTHROPIC_BASE_URL` and `CODEX_HOME` cases, explicit and inferred posture; `packages/dartclaw_runtime/test/container/container_manager_test.dart#registry variables precede the variables DartClaw sets`; `packages/dartclaw_runtime/test/container/container_manager_test.dart#built-in registry records give a workspace container their client variables` – exact S06 set for `workspace`, none for `restricted`.
  - **SATISFIES**: S06, S09

- **TI05** `workspace` containers are created with an anonymous volume at `/var/cache/dartclaw` and `restricted` ones without, and every `rm` DartClaw issues for a container passes `-v`.
  - The volume belongs to `SecurityProfile.workspace` (both `buildManager` branches use it); update S06's argument-list test so `workspace` differs from `restricted` only by the volume and the registry variables.
  - **Verify**: `packages/dartclaw_runtime/test/container/container_manager_test.dart#workspace containers get an anonymous package cache that every removal deletes` – volume argument present for `workspace` in `create` and `run --rm` forms, absent for `restricted`; the stop, stale-name and reclaim calls all carry `-v`.
  - **SATISFIES**: S12, SC02

- **TI06** The stock image owns `/var/cache/dartclaw` as uid 1000, the Dart and Node recipes keep their caches there, and Python (uv and pip), Rust (with its Cargo `config.toml` naming the `crates` route) and Go recipes exist with pinned toolchain versions and the cache variables of Constraints.
  - Follow `images/node.Dockerfile` (copy from the official image at an exact version); the guide mirrors each recipe byte for byte (TI10).
  - **Verify**: `cmd: docker build -q -t dartclaw-agent:latest docker/ >/dev/null && for f in dart node python rust go; do docker build -q -t "dartclaw-recipe-probe-$f" -f "dev/testing/profiles/container/images/$f.Dockerfile" dev/testing/profiles/container/images >/dev/null || exit 1; done` – exit 0; the cache behaviour itself is TI07's.
  - **SATISFIES**: S01, S02, S03, S12

- **TI07** The real-Docker suite proves S05's four clients and S12's cache, and its pub and npm cases run from built-in records with loopback origins instead of adapters.
  - Extend `registry_bridge_integration_test.dart`; the test builds the minimal wheel, `.crate` and module zip its fake origins serve, and Go's case may omit `GOSUMDB` from its test record (scenario S03 proves the checksum route live).
  - **Verify**: the scenario S05 `cmd:` – exit 0, a case run per name; the scenario S12 `cmd:` – exit 0 with at least one case run.
  - **SATISFIES**: S05, S12

- **TI08** The scenario accepts `--fixture python|rust|go` and runs all five by default; `coding_config.dart` renders the `go` record enabled for the Go fixture only; `coding_results.py` maps each fixture to its install and test commands and its ecosystem; the three fixtures exist with stories in the existing protocol and a `.gitignore`; `cleanup_server` removes volumes.
  - Follow `fixtures/node/story.md` for the story text and `coding_results.py#main` for the per-fixture tables. Go's install command is whichever of `go mod download` or `go mod tidy` writes `go.sum` through the checksum database for the pinned Go version.
  - **Verify**: `cmd: PYTHONDONTWRITEBYTECODE=1 python3 dev/testing/profiles/container/coding_results_test.py` – exit 0, with new cases for the python, rust and go command and ecosystem mapping; `cmd: bash -n dev/testing/profiles/container/coding.sh` – exit 0.
  - **SATISFIES**: S01, S02, S03, S04

- **TI09** The live scenarios pass and are recorded in this FIS's `## Implementation Observations` under `Ecosystem fixture proofs`, with each provider's rows, served and refused counts and the routes S02/S03 require.
  - Run per fixture first, then the unflagged matrix last; a step-path defect gets a regression test that fails on the pre-fix code; an unadmittable ecosystem follows Constraints.
  - **Verify**: the S01, S02, S03 and S04 `cmd:` – each exit 0; `cmd: grep -Eq '^(#+ |\*\*)Ecosystem fixture proofs' dev/bundle/docs/specs/0.28.1/s10-registry-ecosystems-as-config.md` – the heading exists in the executed FIS copy (anchored so this task's own text does not match).
  - **SATISFIES**: S01, S02, S03, S04

- **TI10** The docs of SC04 state what shipped, the CHANGELOG 0.28.1 registry entries describe config records and the five built-ins, its toolchain line says the recipes are for the projects agents work on and that DartClaw itself needs none of them, and the generated config artifacts match the field.
  - Diagram: follow `dev/architecture/diagrams/README.md`; render both themes and look before closing.
  - **Verify**: `cmd: dart run packages/dartclaw_kernel/tool/generate_config_schema.dart && dart run dev/tools/render_config_reference.dart --check && git diff --exit-code -- schemas/dartclaw.schema.json` – exit 0; `cmd: dart test --reporter=failures-only packages/dartclaw/test/config_advisory_baseline_test.dart` – exit 0; `cmd: for f in docs/guide/security.md dev/architecture/security-architecture.md dev/architecture/diagrams/security-host-gateway.svg; do git grep -q "container.registries" -- "$f" && git grep -q "files.pythonhosted.org" -- "$f" || exit 1; done` – exit 0; `cmd: git grep -q "crates-dl" -- docs/guide/security.md && git grep -q -i "exfiltrat" -- docs/guide/security.md && git grep -q "uv.lock" -- docs/guide/security.md` – exit 0; `cmd: git grep -q -e Maven -- docs/guide/security.md && git grep -q -e Composer -- docs/guide/security.md && git grep -q "/var/cache/dartclaw" -- docs/guide/security.md` – exit 0; `cmd: git grep -q "container.registries" -- packages/dartclaw_kernel/AGENTS.md packages/dartclaw_runtime/AGENTS.md` – exit 0; `cmd: test -z "$(git grep -n -e RegistryAdapter -e PubRegistryAdapter -e NpmRegistryAdapter -- packages docs dev/architecture)"` – exit 0; `cmd: sed -n '/^## \[0.28.1\]/,/^## \[0.28.0\]/p' CHANGELOG.md | grep -q "container.registries" && test -z "$(sed -n '/^## \[0.28.1\]/,/^## \[0.28.0\]/p' CHANGELOG.md | grep 'pinned Dart and Node toolchains using')"` – exit 0, the old toolchain wording is gone; `cmd: for f in dev/testing/profiles/container/images/*.Dockerfile; do while IFS= read -r l; do [ -z "$l" ] || grep -qxF -- "$l" docs/guide/security.md || exit 1; done < "$f"; done` – exit 0, every recipe line is mirrored in the guide.
  - **SATISFIES**: SC03, SC04

- **TI11** After TI09, ADR-062's amendment line reads `Accepted – <date>` (from `date +%Y-%m-%d`) for the built-ins admitted, its Built-ins row matches what was admitted, its Implementation Notes record the client facts the fixtures settled (the Constraints' ASSUMPTION lines), and its Project Compliance line names the records as the one home of origin pinning.
  - **Verify**: `cmd: git grep -q -E '^Amended – 2026-11-18.*Accepted – [0-9]{4}-[0-9]{2}-[0-9]{2}' -- dev/adrs/062-read-only-package-registry-egress-for-containers.md && test -z "$(git grep -n 'Proposed until each new ecosystem' -- dev/adrs/062-read-only-package-registry-egress-for-containers.md)"` – exit 0; `cmd: test -z "$(git grep -n "surface's adapters" -- dev/adrs/062-read-only-package-registry-egress-for-containers.md)"` – exit 0.
  - **SATISFIES**: SC05

- **TI12** The seam and boundary hold across the story's diff.
  - **Verify**: `cmd: test -z "$(git grep -n -i -F -e pub.dev -e registry.npmjs.org -e pypi.org -e pythonhosted.org -e crates.io -e golang.org -e PUB_HOSTED_URL -e npm_config -e PIP_INDEX_URL -e UV_DEFAULT_INDEX -e GOPROXY -e GOSUMDB -- ':(glob)packages/*/lib/**' | grep -v -e 'dartclaw_kernel/lib/src/container_registries.dart' -e 'dartclaw_kernel/lib/src/network_guard.dart')"` – exit 0; `cmd: test -z "$(git ls-files packages/dartclaw_runtime | grep -e registry_adapter -e pub_registry_adapter -e npm_registry_adapter)"` – exit 0; `cmd: git grep -q "const int bridgeProtocolVersion = 1;" -- packages/dartclaw_bridge/lib/src/bridge_protocol.dart` – exit 0; `cmd: test -z "$(git diff --name-only -- packages/dartclaw_bridge)"` – exit 0, empty for this story's commits (scope the diff to them when others share the tree).
  - **SATISFIES**: SC01, SC02


## Implementation Observations

Executed 2026-11-18 to 2026-11-19 (CET) in a worktree shared with another agent. Status: **done**. Every task is
implemented and verified, including the live S01–S04 matrix (TI09) and ADR-062's acceptance (TI11).

### Chain Attestation

- **OC01**: the code side is done and proven. TI06 adds the recipes, TI08 adds the fixtures, `coding.sh` and
  `coding_results.py`, and TI07 runs real-Docker S05 and S12. In the live runs, each new ecosystem installed through
  the mirror inside the container: uv through `pypi` and `pypi-files`, cargo through `crates` and `crates-dl`, Go
  through `go` and `gosum`. The live S01–S04 matrix passes on both providers. Its first attempts all failed at the
  `spec` step's branch promotion, a defect outside this story that was fixed here (below).
- **OC02**: proven by S06–S10 through TI01–TI04 and TI12. Built-ins are kernel data overlaid by name, a toggle-only
  entry is distinguished from whole-record replacement, `fromYaml` refuses an invalid record and names its path, the
  runtime refuses a record setting a reserved key in every posture, and no ecosystem literal appears in runtime `lib`.
- **OC03**: proven by S11 and S12 through TI03, TI05, TI07 and TI10. The cache volume works in both lifecycles and
  every `rm` passes `-v`. Audit rows carry the query and refusal reasons do not. The guide covers recipes, records,
  the exfiltration warning and the config-only and unsupported ecosystems.

### Proof lines

- TI01/TI02 (S06–S08): `dart test --reporter=failures-only packages/dartclaw_kernel` → exit 0, `+1474: All tests passed!`. `container_registries_test.dart` has the 3 named tests plus 29 refusal and disabled-record cases.
- TI03 (S07, S10, S11): `dart test --reporter=failures-only packages/dartclaw_runtime/test/container/gateway` → exit 0, `+120: All tests passed!`.
- TI04/TI05 (S06, S09, S12 unit): `dart test --reporter=failures-only packages/dartclaw_runtime/test/container packages/dartclaw_runtime/test/runtime/security_wiring_container_isolation_test.dart packages/dartclaw_runtime/test/web/settings_form_test.dart` → exit 0, `+251 ~1: All other tests passed!`.
- Runtime package: `dart test --reporter=failures-only packages/dartclaw_runtime` → exit 0, `+5830 ~25: All other tests passed!`.
- TI06: the recipe build loop for the stock image plus dart, node, python, rust and go → `BUILD-EXIT=0`. A probe as uid 1000 found Python 3.14.9 with ssl, sqlite3, ctypes, lzma and bz2, uv 0.13.6, cargo/rustc 1.99.0 with `/.cargo/config.toml`, and go1.26.9.
- TI07 (S05): `for c in pypi crates "go module"; do dart test --run-skipped -t integration …registry_bridge_integration_test.dart --name "$c" || exit 1; done` → `S05-EXIT=0`. S12: `--name "package cache"` → `S12-EXIT=0`. Whole file → `+8: All tests passed!`.
- TI08: `PYTHONDONTWRITEBYTECODE=1 python3 dev/testing/profiles/container/coding_results_test.py` → `Ran 17 tests … OK`. `bash -n dev/testing/profiles/container/coding.sh` → exit 0.
- TI09 (S01–S04): see "Ecosystem fixture proofs". The unflagged matrix exits 0 with ten passing rows.
- TI11: ADR-062's amendment reads "accepted 2026-11-19", its Built-ins row says each built-in was admitted by its passing fixture on that date, its Implementation Notes record the client facts below, and its Project Compliance line names the kernel records as the home of ecosystem data. The `DECISIONS.md` row matches.
- TI10: `generate_config_schema.dart && render_config_reference.dart --check && git diff --exit-code -- schemas/…` → the generated schema is committed-ready and `--check` exits 0. `config_advisory_baseline_test.dart` → `+8: All tests passed!`. Every documentation grep, the CHANGELOG check and the recipe-mirror loop pass. The diagram passes `xmllint` and was rendered and inspected in light, dark and both hover panels.
- TI12: the seam grep is empty, `bridgeProtocolVersion = 1`, and `git diff --name-only -- packages/dartclaw_bridge` is empty. The adapter `git ls-files` check still lists the three adapter files and two tests, because their deletion is unstaged. Committing must stage the deletions.
- Fast tier: `dart run dev/tools/embed_assets.dart && dart analyze --fatal-infos && dart test … server_test.dart` → `No issues found!` and `+28: All tests passed!`. Format: `dart format --line-length=120 --output=none --set-exit-if-changed .` → exit 0. `dev/fitness/test/config_key_consumers_test.dart` → `+3`.
- Falsifiability: each of these mutants made its owning test fail, and each was restored:
  - the toggle-only rule (`value.length == 1`);
  - the reserved-key refusal in `SecurityWiring.wire`;
  - `-v` on the stop removal.
  The `coding_results` route check has a red subcase, rust with only `/crates/` served.

### Ecosystem fixture proofs

Command: `DARTCLAW_CONTAINER_DATA_DIR=~/.dartclaw bash dev/testing/profiles/container/coding.sh` (unflagged: every fixture on both providers), run 2026-11-19 17:22–18:29 CET, exit 0. Results: `.agent_temp/container-coding/20261119T162224Z.ZV7O96/results.md`. Every row's workflow completed with each step in a `workspace` container, and every route of the fixture's record served a request.

| Fixture | Install | Test | claude served / refused | codex served / refused | Routes served |
|---|---|---|---|---|---|
| dart | `dart pub get` 0 | `dart test` 0 | 493 / 0 | 294 / 0 | pub |
| node | `npm install` 0 | `npm test` 0 | 15 / 0 | 5 / 0 | npm |
| python | `uv sync` 0 | `uv run pytest` 0 | 23 / 0 | 23 / 0 | pypi, pypi-files |
| rust | `cargo fetch` 0 | `cargo test` 0 | 20 / 0 | 10 / 0 | crates, crates-dl |
| go | `go mod tidy` 0 | `go test ./...` 0 | 30 / 0 | 32 / 0 | go, gosum |

Codex completed all 5 workflow steps in each of its rows. The single-fixture Claude reruns before the matrix (`20261119T155619Z.S6zxnk` python, `20261119T160322Z.tvApwE` rust) passed too.

**Two defects outside this story blocked the matrix, and both were fixed here at the owner's request:**
- Every first attempt failed at the `spec` step: `promotion failed: Bad state: Workflow branch "dartclaw/workflow/<run>" changed after inspection.` `implement-story` resolves to a `shared` worktree, whose steps run on the integration branch itself, so promotion's source and destination are one branch. The approval check added in cbafb21f2 (ADR-063) sweeps source then destination and checks each against its inspected revision, so the second sweep saw the first sweep's commit as a change. `_promoteWorkflowBranchLocallyUnlocked` (`workflow_git_support.dart`) now sweeps once when the two branches are the same. Test: `workflow_git_support_test.dart` "promoteWorkflowBranchLocally commits a step that ran on the integration branch", red before the fix; the suite passes 39.
- The first passing go row crashed `coding_results.py` with `shlex`'s "No closing quotation" on an agent shell call with unbalanced quotes. `runs_acceptance_command` now falls back to a quote-blind split, which can only add an attempt without the exit marker and so fails closed, and the tool trace is written before parsing. Test: "unbalanced quotes in a script never hide or fake an attempt", red before the fix; 18 tests pass.

The checksum-database route and the client facts from the Constraints' ASSUMPTION lines are proven by these rows and by S05:
- Cargo accepts the `sparse+http://` replacement.
- uv accepts the plain-HTTP loopback index without flags.
- Go accepts an `http://` `GOPROXY` and the `http://` `GOSUMDB` URL: `/gosum/` was served live.
- `go mod tidy`, not `go mod download`, writes `go.sum` with Go 1.26.9. `go mod download` wrote only the `/go.mod` hash, and `go test` then failed with "missing go.sum entry".
- Not exercised by a fixture: `GOTOOLCHAIN=local` and bun's reading of the npm record (the node fixture uses npm). Both remain as the Constraints state them.

### Drift Notes

- `RegistryUpstream.origin` is a `String`, not a `Uri`. The kernel validates the string once; the runtime parses it where it connects.
- The reserved-key set in `provider_resolution.dart` gained `ANTHROPIC_API_KEY` and `CLAUDE_CODE_SIMPLE`, both set per exec. As a side effect, `sanitizeProviderRequestEnvironment` now also strips them from request extras.
- The reserved-key refusal runs at the top of `SecurityWiring.wire()` in every posture, including disabled, because it is a config error and not a probe result.
- A record field outside `enabled`, `upstreams`, `env` and `rewrite_json` is refused, so a typo cannot silently drop a rule.
- The cache volume is a bare-path entry (`/var/cache/dartclaw`) in `SecurityProfile.workspace(...).workspaceMounts`. Every `split(':')` consumer skips entries with fewer than two parts. `security_profile_test.dart` counts were updated.
- `setUpAll` in the integration suite rebuilds `dartclaw-agent:latest` from `docker/`, so the cache directory's ownership is the one under test. The go integration record sets `GOSUMDB=off`, which TI07 permits.
- `coding_results.py` requires a served request on every route of the fixture's record. For PyPI that includes `/pypi-files/`, which is stricter than S01's "served `pypi` requests".
- `config_json_schema_test.dart` used to pin `required` to `['id']`. It now asserts that `required` names only declared entry fields, and it pins the two registry entry shapes. `config_meta_test.dart`'s pinned readonly set gains `container.registries`.
- The npm integration commands use `${npm_config_registry}is-odd`, because the specified npm value ends in `/`.
- Review repair: `_rewrite` now keeps a URL fragment. A fragment case was added to "rewrites JSON only by the record rule…", and it failed before the fix.

### Review

`Reviewed:` a fresh reviewer ran `andthen:review --quick --fix` (code and gap lenses) over the changed paths against
this FIS. It found no Fix-routed findings and one LOW Note: `_rewrite` dropped URL fragments. That Note was fixed
under a test that failed first. Nothing else is open from review.

### Open

- None in scope. The commit must stage the three deleted adapter files and their two tests.
