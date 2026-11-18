# S06: Registry bridge surface with pub

**Plan**: dev/bundle/docs/specs/0.28.1/plan.json
**Story-ID**: S06

## Feature Overview and Goal

**Intent**: A containerized coding step cannot resolve a single dependency, because the container has `network:none` and the host pipe serves only the model API. This story adds the read-only `registry` surface of ADR-062 with its pub adapter, so a `workspace` step runs `dart pub get` and its tests with no network attachment, certificate or credential added to the container.

**Expected Outcomes**:

- [OC01] `dart pub get` succeeds in a `workspace` container under `network:none`, and story S02's Dart fixture passes its tests there with Claude Code and with Codex.
- [OC02] The surface cannot be used for anything but reading public pub packages: `restricted` containers get none, writes, unpinned origins and credentials are refused, and an artifact over the 64 MiB pipe cap fails visibly instead of arriving truncated.
- [OC03] An operator can see every package request a container made and every refusal, and the security docs state the new egress path.
- [OC04] The pub lockfile consequence is accepted, documented and shown: a containerized `pub get` ignores a committed `https://pub.dev` `pubspec.lock`, writes one naming the mirror and may resolve newer versions, and the FR3 Dart fixture's result row records it.


## Required Context

Paths are relative to the public repo root (`../dartclaw-public/` from the private repo), where this FIS executes from its exported copy and where `cmd:` proofs run; `docs/specs/` and `docs/research/` paths name this plan's private sources, exported to `dev/bundle/docs/`.

- `docs/specs/0.28.1/prd.md#fr9-read-only-package-registry-egress` – the seven acceptance criteria; this story covers all but the npm half of the first and the last.
- `dev/adrs/062-read-only-package-registry-egress-for-containers.md` – design authority, D1-D3 pinned: its Decision table is the rule set, its Implementation Notes are settled in Architecture Decision and Constraints & Gotchas below.
- `docs/specs/0.28.1/plan.json#sharedDecisions` – "Registry ecosystem adapter seam" (story S07 adds npm through it) and "Containerized coding scenario" (this story reruns the S02 command, Dart fixture, no `--baseline`).
- `docs/specs/0.28.1/s02-live-containerized-workflow-proof.md` – `coding.sh`, its flags, results file and teardown rules.
- `docs/specs/0.28.1/s05-agent-image-toolchain-recipe.md` – the recipe images the scenario runs in, the `### Language Toolchains in the Agent Image` guide subsection, the container prompt note that must stay true, and the pub cache capacity check it defers here.
- `packages/dartclaw_runtime/lib/src/container/gateway/mcp_bridge_surface.dart` and `provider_adapter.dart` – the surface and header-handling patterns to follow.


## Acceptance Scenarios

- **S01 [OC01] [runtime] A Dart project installs and passes its tests in a workspace container**
  - **Given** a container runtime, host-held Claude Code and Codex credentials, and a bridge binary built from this candidate
  - **When** the maintainer runs story S02's scenario command on the Dart fixture, for both providers, without `--baseline`
  - **Then** each provider's results row shows the install command and the test command both exited 0 inside the container, every task of the run has a `container_json` naming the `workspace` profile, and the command exits 0
  - **And** the Dart rows record the fixture's `pubspec.lock` diff against the committed one, which now names `http://127.0.0.1:8082/pub` and holds newer `test` versions
  - **Proof**: `cmd: bash dev/testing/profiles/container/coding.sh --fixture dart` – exit 0; then `cmd: d=$(ls -dt .agent_temp/container-coding/*/ | head -1); grep -q '127.0.0.1:8082/pub' "$d/results.md"` – exit 0, the lockfile diff names the mirror

- **S02 [OC01] [runtime] A container reads package metadata and an archive through the mirror, with no network**
  - **Given** a `workspace` authority whose pub adapter is pinned to a local fake origin that serves package metadata naming an archive on that same origin, and the archive
  - **When** a process in the container fetches the metadata and then the archive from the address in its `PUB_HOSTED_URL`
  - **Then** the metadata's archive address points at the container-loopback mirror, the archive bytes equal the origin's, and the container's network mode is `none`
  - **Proof**: `cmd: dart test --run-skipped -t integration packages/dartclaw_runtime/test/integration/registry_bridge_integration_test.dart` – exit 0, red at spec time (file does not exist yet)

- **S03 [OC02] `restricted` never gets a registry path**
  - **Given** a `restricted` and a `workspace` authority registered with the same gateway
  - **When** each is registered, and each container is created
  - **Then** only the `workspace` authority requires a registry pipe and carries `PUB_HOSTED_URL`; attaching a registry pipe to the `restricted` authority is refused; a fetch from the `restricted` container fails
  - **Proof**: `packages/dartclaw_runtime/test/container/gateway/host_gateway_test.dart#grants the registry surface to workspace authorities and never restricted` – red at spec time; the container half is scenario S02's integration file

- **S04 [OC02] A write request is refused before it leaves the host**
  - **Given** a `workspace` authority with the pub adapter
  - **When** the container sends `POST`, `PUT` or `DELETE` to a registry path, a package publish upload included
  - **Then** the request is refused with 405, the origin sees no request, and a `GuardBlockEvent` (`guard: host-gateway`, `hook: bridge`) fires; `GET` and `HEAD` are served, `HEAD` without a body
  - **Proof**: `packages/dartclaw_runtime/test/container/gateway/registry_bridge_surface_test.dart#refuses a publish request without contacting the origin` – red at spec time

- **S05 [OC02] Only pinned origins are reachable**
  - **Given** a pub adapter pinning two origins, and an origin that redirects
  - **When** the container requests a path under no ecosystem route, a redirect that stays inside the pinned set, a redirect that leaves it, and a path written as another host (`//other.example/x`)
  - **Then** the first, third and fourth are refused with a `GuardBlockEvent` and nothing is requested from an unpinned host; the second is followed host-side and its body returned
  - **Proof**: `packages/dartclaw_runtime/test/container/gateway/registry_bridge_surface_test.dart#follows redirects only inside the pinned origin set` – red at spec time

- **S06 [OC01] Download addresses in metadata point at the mirror, and archives are untouched**
  - **Given** pub metadata listing archive addresses on a pinned origin and on an unpinned one, served gzip-encoded
  - **When** the container requests it, then an archive
  - **Then** the pinned-origin address now names the container-loopback mirror and the unpinned one is unchanged (it fails in the container); the archive's bytes are returned exactly, so its `archive_sha256` still matches
  - **Proof**: `packages/dartclaw_runtime/test/container/gateway/pub_registry_adapter_test.dart#rewrites pinned download addresses and leaves archives untouched` – red at spec time

- **S07 [OC02] No credential crosses in either direction**
  - **Given** a container request carrying `Authorization`, `Cookie` and `X-Api-Key` headers
  - **When** the host forwards it, and the origin answers with `Set-Cookie`
  - **Then** the origin receives none of the three, the host adds none, and the container receives no `Set-Cookie`
  - **Proof**: `packages/dartclaw_runtime/test/container/gateway/registry_bridge_surface_test.dart#drops credential headers both ways` – red at spec time

- **S08 [OC02] An artifact over the 64 MiB cap fails with a message naming the cap**
  - **Given** an origin whose archive advertises a `Content-Length` over `BridgeLimits.maxResponseBytes`, and one that streams past it with no length
  - **When** the container requests each
  - **Then** the first fails with a non-success status whose text names the cap in bytes and no archive bytes arrive; the second ends as an aborted connection on the container side, never as a complete short body
  - **Proof**: `packages/dartclaw_runtime/test/container/gateway/registry_bridge_surface_test.dart#refuses an advertised oversize artifact naming the cap` – red at spec time; the aborted-connection half is `packages/dartclaw_bridge/test/bridge_runner_test.dart#a response overrunning the cap after it started aborts the connection`

- **S09 [OC03] Every request is recorded; a refusal names the rule, not the content**
  - **Given** a `workspace` authority served two requests and refused one
  - **When** the requests settle
  - **Then** the audit trail holds three records, each with the authority, `pub`, the request path and the response status, and each refusal's `GuardBlockEvent` message names the ecosystem and the rule broken without a URL query, header value or body
  - **Proof**: `packages/dartclaw_runtime/test/container/gateway/registry_bridge_surface_test.dart#records served and refused requests without request content` – red at spec time


- **S10 [OC04] [runtime] A pub.dev lockfile is re-resolved through the mirror and the outcome is asserted**
  - **Given** a Dart project whose committed `pubspec.lock` names `https://pub.dev` and pins a dependency below its latest version, a `workspace` container under `network:none` running the story S05 Dart recipe image, and a pub adapter pinned to a local fake origin serving two versions of that dependency (a minimal package archive built in the test)
  - **When** `dart pub get` runs in the container
  - **Then** it succeeds, the resulting `pubspec.lock` names `http://127.0.0.1:8082/pub` in place of `https://pub.dev`, and the dependency resolved to the newer version
  - **Proof**: `cmd: dart test --run-skipped -t integration packages/dartclaw_runtime/test/integration/registry_bridge_integration_test.dart` – exit 0, includes `#pub get ignores a pub.dev lockfile and writes one naming the mirror`, red at spec time


## Structural Criteria

- **SC01** The container boundary is unchanged: `--network none`, dropped capabilities, read-only root, mounts and the `/tmp` tmpfs are identical for every authority, and the only addition to the create/run arguments is the registry client environment of a granted authority.
- **SC02** The seam story S07 relies on holds: ecosystem-specific code (origins, environment variable name, routes, metadata detection) lives only in `RegistryAdapter` implementations; the surface, handshake, grant rule, audit and refusal rules mention no ecosystem, and registering an adapter is one line in `SecurityWiring`.
- **SC03** No protocol or config change: `bridgeProtocolVersion` stays `1`, the frame layout is untouched, and no `container:` or `security:` config key, doctor row or kernel type is added.
- **SC04** The grant rule has one author: whether an authority gets the registry surface and whether its container gets the client environment are answered by the same function.
- **SC05** The docs state the new path: `security-architecture.md`, the guide's security page and `security-host-gateway.svg` name the `registry` surface, its pinned origins, GET/HEAD-only rule and `workspace`-only grant.
- **SC06** The lockfile consequence is documented in both places a reader looks: an ADR-062 Consequences/Negative row and the guide's dependency paragraph say that a containerized `pub get` ignores a committed `pubspec.lock` whose `url` differs, writes one naming the mirror, and so re-resolves to newer versions.


## Scope & Boundaries

### Work Areas

- `packages/dartclaw_bridge/` – `BridgeSurface.registry`, the binary's `--surface` usage, and the abort-on-overrun fix in `bridge_runner.dart`.
- `packages/dartclaw_runtime/lib/src/container/gateway/` – new `registry_adapter.dart` (seam), `pub_registry_adapter.dart`, `registry_bridge_surface.dart`; `gateway_models.dart` (port), `host_gateway.dart` (grant, attach, handler); the header-strip lists extracted from `provider_adapter.dart` into one shared home.
- `packages/dartclaw_runtime/lib/src/container/container_manager.dart` and `runtime/security_wiring.dart` – client environment at container creation, adapter registration, audit sink.
- Tests beside each: `registry_bridge_surface_test.dart`, `pub_registry_adapter_test.dart` (new), `host_gateway_test.dart`, `container_manager_test.dart`, `bridge_runner_test.dart`, and `test/integration/registry_bridge_integration_test.dart` (new, `integration` + `slow` tags like `scoped_host_gateway_integration_test.dart`).
- `dev/architecture/security-architecture.md`, `dev/architecture/diagrams/security-host-gateway.svg`, `docs/guide/security.md`, `dev/adrs/062-read-only-package-registry-egress-for-containers.md` (Implementation Notes and one Consequences/Negative row; the Decision-table "Response URLs" row and its Negative bullet are story S07's), `CHANGELOG.md` (0.28.1).

### What We're NOT Doing

- The npm adapter, `npm_config_registry`, npm cache capacity – story S07. Only pub's cache is measured here, because pub is all this story can exercise.
- Moving ADR-062 to Accepted – story S07 closes FR9; the status line stays `Proposed`.
- A config knob, another ecosystem, private or authenticated registries, a CONNECT tunnel, TLS interception – ADR-062 D1-D3.
- Raising `BridgeLimits`, the 64 MiB cap or the in-flight count – the ADR keeps them.
- Normalising a mirror lockfile host-side, holding lockfile changes for review, or any pub-specific lockfile handling – the drift is accepted and documented (Constraints).
- Edits to story S05's prompt note, recipe Dockerfiles or `container.image` handling, except the recipe's pub cache location if TI10's capacity check fails.
- "Current through" markers, the DECISIONS index, Ubiquitous Language and diagrams other than `security-host-gateway.svg` – story S09.
- Host-mode behavior: host agents have network, and nothing about them changes.


## Architecture Decision

**Approach**: One `RegistryBridgeSurface` (a `GatewaySurfaceHandler` like `McpBridgeSurface`) serves every ecosystem on one container-loopback port, 8082, under `/<route>/...`. It owns every rule that is not ecosystem knowledge: GET/HEAD only, header stripping, host-side redirects within the pinned set, the size cap, metadata rewriting, audit and refusal. A `RegistryAdapter` supplies only `ecosystem`, `clientEnvironment(mirrorBase)` (a map of variable to value; story S07's npm adapter returns two), `origins` (an ordered list of pinned origin plus the mirror route that stands for it; the first is the client's base), and `carriesMetadata(path, contentType)`. pub is `/pub` to `https://pub.dev` with `PUB_HOSTED_URL=http://127.0.0.1:8082/pub`. The client environment is set by `ContainerManager` at container creation, beside `ANTHROPIC_BASE_URL`, so every process in the container inherits it.
**Why this over the floor**: the floor is serving registry paths on the provider surface. Its adapters hold the credential and accept POST to fixed paths only (`ProviderAdapter.handle`), and ADR-062 puts registry traffic on a third pipe so a package request never rides the credential-bearing one.
**Flow**: tool in container → `http://127.0.0.1:8082/pub/...` → bridge (`registry` pipe) → surface: route lookup, method check → pinned-origin fetch, redirects followed inside the set → metadata rewrite on a decoded body → size check → audit record → response.


## Constraints & Gotchas

- **Route lookup keeps the raw path.** Match the `/<route>/` prefix on the raw request path and forward the remainder unchanged: npm (story S07) requests scoped packages as `/@scope%2fpkg`, and `Uri.pathSegments` decodes `%2F` into two segments. Use `Uri.replace(path:)` on the pinned origin, never `pathSegments`.
- **Grant rule is positive.** `workspace` gets the surface; every other profile, `restricted` included, does not, so a profile added later is denied until someone opts it in. The surface is only granted when the gateway has at least one adapter, so existing constructions of `HostGateway` stay as they are.
- **The client environment cannot come from the bridge binary.** ADR-062's note says it exports the variables, but the bridge is a separate `docker exec` process and cannot set a sibling's environment. Use container-level `-e` in `ContainerManager.start` (the `volatileGeneratedState` `docker run` path shares the same argument list). It must not be image `ENV` (story S05's recipes): `restricted` shares the image and must not see the variable. Correct the ADR note (TI11).
- **No version bump, and a stale bridge fails closed.** The handshake carries the surface name and the host compares it to the pipe's own, so a new enum value changes no frame. A bridge binary without `registry` exits 64 on `--surface=registry` (`_parse` returns null), the authority's `ready` times out at 30 s, and acquisition fails for every `workspace` container. In a source checkout run `bash dev/tools/build_bridge.sh` before any live run; release builds embed a matching bridge.
- **Truncation looks like success.** On an over-cap response the pipe sends a failure frame after `responseStart`, and `BridgeRunner`'s `fail` then closes the chunked response normally, so the client sees a well-formed short body. Hence the `Content-Length` pre-check in the surface (the status and text reach the client) and the abort in TI06 (the unadvertised case).
- **Compose the upstream URL by replacing the path on the pinned origin** (`origin.replace(path:, query:)`, as `ProviderAdapter.composeTarget` does), never by resolving a container-supplied target: `//other.example/x` or an absolute URL would pick the destination. A redirect's `Location` is host-controlled, so resolve that one against the current URL and then check its origin.
- **Rewriting needs the decoded body.** Drop the client's `accept-encoding`, let the host `HttpClient` decompress (`autoUncompress`), and drop `content-encoding` and `content-length` on the way back, as `ProviderAdapter` does. Rewrite only responses `carriesMetadata` names; an archive streams through unread, which is also what keeps its hash valid.
- **Extract the header-strip lists, do not copy them.** `ProviderAdapter`'s request and response drop sets move to one shared home both import; `provider_adapter_test.dart` stays green untouched. The surface adds `accept-encoding` to the request set.
- **The provider CLI must pass the variable to its tool shell.** Claude runs with the subprocess scrub explicitly off (`claudeContainerHardeningEnvVars`). Codex filters the environment it hands to commands by its own shell-environment policy, which DartClaw does not configure; scenario S01's Codex row is the proof. If `PUB_HOSTED_URL` is dropped, fix it in the Codex config DartClaw generates for the container, not in the image.
- **Parallel metadata fetches meet the bridge's 8 in-flight and 16 queued limits.** An authoring-time probe of the fixture's `test` dependency made 98 requests; surplus requests get 503, which pub retries. Leave the limits; if S01 fails on this, record it rather than raising them.
- **Facts checked on 2026-11-13, re-check at execution.** pub.dev metadata carries an absolute `archive_url` (`https://pub.dev/api/archives/<pkg>-<version>.tar.gz`) and `archive_sha256`; all 49 archives of `package:test` answered 200 with no redirect, so pub's pinned set is `https://pub.dev` alone. Dart 3.14.0 accepts a plain-HTTP loopback `PUB_HOSTED_URL` with a path prefix, and an end-to-end `dart pub get` through a throwaway rewriting proxy of this exact shape resolved all 49 packages. That install left a 41 MiB pub cache (42260 KiB). A redirect to another origin in a later live run is added to the adapter as that exact origin, nothing wider.

- **Lockfile drift is accepted and documented.** pub's hosted source writes the URL into each lockfile entry (`serializeForLockfile` writes `description.url`), the default URL comes from `PUB_HOSTED_URL`, and source equality includes `url` (dart-lang/pub `lib/src/source/hosted.dart`). A committed `pubspec.lock` naming `https://pub.dev` therefore reads as a different source than the mirror, so a containerized `pub get` ignores it, re-resolves, and writes a lockfile naming `http://127.0.0.1:8082/pub`, possibly at newer versions. pub has no host-replace option; normalising the URL host-side would keep the silent upgrade, and holding the lockfile change would stop every Dart task. The ADR-062 Negative row, the guide's dependency paragraph, the S10 integration case and the Dart fixture's result row (story S02 commits its lockfile pinned below latest) carry it.
- One loopback port with an ecosystem route prefix serves all ecosystems; a port per ecosystem would need one bridge process, hence one surface, per ecosystem, which contradicts the plan's single `registry` surface.
- Served requests are recorded as `pass` audit entries through `GuardAuditLogger.writeEntry` (`server` the ecosystem, `tool` the path, `principal` the authority id, `decision` `allow`, the status in `reason`), because `AuditEntry` has no status field; a typed status column would be a kernel `AuditEntry` change this story does not make.
- A redirect chain longer than 5 hops is refused: pub and npm use at most one, and a longer observed chain raises the limit in a patch.
- The over-cap message names the cap in bytes, taken from the gateway's `BridgeLimits`.
- Story S05's container prompt note stays untouched because it claims only "no direct network access"; if its executed wording says installs cannot work, edit that one sentence and note it.
- ASSUMPTION: S01 and S10 need Docker, and S01 needs host-held Claude Code and Codex credentials, on the executing machine – an executor without them leaves S01 and S10 open and reports it, never skips it.
- **Written against story S02's and story S05's FIS**, whose `coding.sh`, `--fixture` flag, recipe images and guide subsection do not exist yet: if their execution renames any of them, apply the same edits by intent.


## Implementation Plan

### Implementation Tasks

- **TI01** `BridgeSurface.registry` exists with container port 8082 (`bridgePortFor`), and the bridge binary accepts `--surface=registry` and lists it in its usage text; `bridgeProtocolVersion` is unchanged.
  - Exhaustive `switch`es over the enum (`bridgePortFor`, `HostGateway._handlerFor`) are the compiler's checklist.
  - **Verify**: `packages/dartclaw_bridge/test/bridge_runner_test.dart#registry surface handshakes and listens` – the handshake frame names `registry` and the runner reports ready; plus `BridgeSurface.fromWire('registry')` resolves.
  - **SATISFIES**: SC03, S02

- **TI02** `RegistryAdapter` (the seam) and `PubRegistryAdapter` exist as in Architecture Decision; pub's origin is injectable for tests, its metadata responses are the JSON ones under `/api/packages/`, and a pinned origin's absolute URLs are rewritten to its mirror route on a decoded text body.
  - Follow `provider_adapter.dart#AnthropicMessagesAdapter` for an adapter whose upstream is a constructor argument.
  - **Verify**: `packages/dartclaw_runtime/test/container/gateway/pub_registry_adapter_test.dart#rewrites pinned download addresses and leaves archives untouched` – asserts the pinned address becomes `http://127.0.0.1:8082/pub/...`, an unpinned one is unchanged, a gzip-served body is rewritten, and an archive response is not read; and `#client environment points PUB_HOSTED_URL at the pub route`.
  - **SATISFIES**: S06, SC02

- **TI03** `RegistryBridgeSurface` serves GET and HEAD only, maps `/<route>/...` to its adapter's pinned origin, follows redirects host-side inside the pinned set up to 5 hops, drops credential and routing headers both ways, and refuses everything else with a status and reason that fire the gateway's denial sink.
  - Follow `mcp_bridge_surface.dart` for the handler shape and `provider_adapter.dart#handle` for header copying, with the shared lists extracted per Constraints.
  - **Verify**: `registry_bridge_surface_test.dart#refuses a publish request without contacting the origin`, `#follows redirects only inside the pinned origin set` (covers the other-host path), `#drops credential headers both ways`, each against a loopback fake origin that counts its requests.
  - **SATISFIES**: S04, S05, S07

- **TI04** An artifact over the response cap fails visibly: a `Content-Length` above `BridgeLimits.maxResponseBytes` is refused before `responseStart` with text naming the cap in bytes.
  - The cap comes from the gateway's limits passed to the surface, so a test can lower it.
  - **Verify**: `registry_bridge_surface_test.dart#refuses an advertised oversize artifact naming the cap` – status is a failure, the text contains the configured byte count, no body bytes are written.
  - **SATISFIES**: S08

- **TI05** Each served request writes one audit record (authority, ecosystem, path, status) through a sink `SecurityWiring` binds to the audit logger, and each refusal reason names the ecosystem and the broken rule, never a query, header value or body.
  - **Verify**: `registry_bridge_surface_test.dart#records served and refused requests without request content` – three records for two served and one refused request; the refusal message contains the ecosystem and no query string planted in the request.
  - **SATISFIES**: S09

- **TI06** `BridgeRunner` ends a response that overruns the cap after it started by aborting the connection, so the client gets an error, not a complete short body.
  - Write the test first and watch it fail on the current clean close.
  - **Verify**: `packages/dartclaw_bridge/test/bridge_runner_test.dart#a response overrunning the cap after it started aborts the connection` – the loopback client sees a connection error or a body shorter than a declared length, never a normal end.
  - **SATISFIES**: S08

- **TI07** `HostGateway` takes the registry adapters, grants the `registry` surface to `workspace` authorities through one function (the one `ContainerManager`'s environment also asks), builds `RegistryBridgeSurface` in `_handlerFor`, and refuses `attach` of `registry` to an authority that was not granted it.
  - Existing `attach` of an ungranted `mcp` surface returns normally (a test pins it), so refuse `registry` specifically.
  - **Verify**: `host_gateway_test.dart#grants the registry surface to workspace authorities and never restricted` – required surfaces per profile, with no adapters configured as a third case; `#refuses to attach a registry pipe to an authority without the grant`.
  - **SATISFIES**: S03, SC04

- **TI08** A granted authority's container is created with its adapters' client environment, an ungranted one with arguments exactly as before, and `SecurityWiring` registers `PubRegistryAdapter` in one line, passes it to `HostGateway`, and binds the audit sink.
  - Thread the environment the way `hasMcpBridge` is threaded (`_ContainerTemplate`, `buildManager`); the grant answer comes from TI07's function.
  - **Verify**: `packages/dartclaw_runtime/test/container/container_manager_test.dart#registry client environment is set only for a granted authority` – `-e PUB_HOSTED_URL=http://127.0.0.1:8082/pub` present, `--network none` and all other arguments equal to the ungranted list; existing argument-list tests unchanged.
  - **SATISFIES**: SC01, SC04, S03

- **TI09** A real-Docker suite proves the path end to end without a model: a `workspace` container fetches metadata and an archive through the mirror under network mode `none`, and a `restricted` container has neither the variable nor a way to fetch.
  - Follow `scoped_host_gateway_integration_test.dart` and `container_integration_support.dart` (`FakeProviderUpstream`-style loopback origin, `ensureBridgeBinary`, `ensureGatewayProbeImage`).
  - The suite also holds the S10 case: the story S05 Dart recipe image (built from the stock image), a fake pub origin serving two versions of one dependency, a project with a committed pub.dev `pubspec.lock` pinning the older one, `dart pub get` under `--network none`; it asserts success, the lockfile naming the mirror and the newer version.
  - **Verify**: the scenario S02 `cmd:` – exit 0, covering the `restricted` half of S03 and the `#pub get ignores a pub.dev lockfile and writes one naming the mirror` case of S10.
  - **SATISFIES**: S02, S03, S10, SC01

- **TI10** Pub's cache fits the container's `/tmp` tmpfs, and the live scenario passes on the Dart fixture, recorded in this FIS's `## Implementation Observations` under `Pub registry proof` with both providers' result rows.
  - Measure the cache a `dart pub get` of story S02's Dart fixture leaves; if it exceeds 75% of the 100 MiB tmpfs, move the recipe's pub cache to a writable path with room and keep story S05's guide mirror in step (its SC01). npm's measure is story S07's.
  - **Verify**: `cmd: d=$(mktemp -d) && cp -R dev/testing/profiles/container/fixtures/dart "$d/f" && (cd "$d/f" && PUB_CACHE="$d/cache" dart pub get) && test "$(du -sk "$d/cache" | cut -f1)" -lt 76800` – exit 0; the scenario S01 `cmd:` – exit 0; `cmd: d=$(ls -dt .agent_temp/container-coding/*/ | head -1); grep -q '127.0.0.1:8082/pub' "$d/results.md"` – the Dart rows' lockfile diff names the mirror; `cmd: grep -rq "Pub registry proof" dev/bundle/docs/specs/0.28.1` – the heading exists in the executed FIS copy.
  - **SATISFIES**: S01

- **TI11** The docs state the surface: `security-architecture.md` (§ Host-Owned Provider Mediation and the threat table's supply-chain and exfiltration rows), the guide's security page (the "Sole egress" bullet, "How It Works", and a paragraph in story S05's `### Language Toolchains in the Agent Image` on how dependencies are reached and that `restricted` has none), `security-host-gateway.svg` with a `registry` node, ADR-062's Implementation Notes with the settled answers (client environment set at container creation, no version bump, pub's pinned set), the ADR's Consequences/Negative section with the lockfile row of SC06, the guide's dependency paragraph with the same statement, and `CHANGELOG.md` 0.28.1 gains an `### Added` entry.
  - Diagram: follow `dev/architecture/diagrams/README.md` (hand-written SVG, both themes rendered).
  - **Verify**: `cmd: git grep -q -i "registry" -- dev/architecture/security-architecture.md docs/guide/security.md dev/architecture/diagrams/security-host-gateway.svg CHANGELOG.md` – exit 0; `cmd: git grep -q -i "container creation" -- dev/adrs/062-read-only-package-registry-egress-for-containers.md` – exit 0; `cmd: git grep -q "pubspec.lock" -- docs/guide/security.md && git grep -q "pubspec.lock" -- dev/adrs/062-read-only-package-registry-egress-for-containers.md` – exit 0.
  - **SATISFIES**: SC05, SC06

- **TI12** The seam holds: nothing outside `pub_registry_adapter.dart` names pub's origin or variable, and the story added no config or protocol surface.
  - **Verify**: `cmd: test -z "$(git grep -n -i 'pub\.dev\|PUB_HOSTED_URL' -- packages/dartclaw_runtime/lib packages/dartclaw_bridge/lib ':!packages/dartclaw_runtime/lib/src/container/gateway/pub_registry_adapter.dart')"` – exit 0; `cmd: git grep -q "const int bridgeProtocolVersion = 1;" -- packages/dartclaw_bridge/lib/src/bridge_protocol.dart` – exit 0; `cmd: git diff --name-only -- packages/dartclaw_kernel` – empty for this story's commits (scope the diff to them when others share the tree).
  - **SATISFIES**: SC02, SC03


## Final Validation Checklist

- Render `security-host-gateway.svg` in both themes and look at it before closing TI11.
- Run the scenario S01 command only after `bash dev/tools/build_bridge.sh` in a source checkout (Constraints & Gotchas).

## Discovered Requirements

- **Container baseline and lifecycle**. **Description**: Reuse S02's `container/coding.sh` and existing renderer/recorder. Its four-case baseline recorded install/test exit 127 for missing Dart/npm, workspace placement on all tasks, unchanged Dart locks and no new Codex system-home rollouts. Disposable workflow generation changes only `gitStrategy.cleanup.enabled:false`; the profile collects retained worktree evidence and owns final teardown. **Rationale**: The live proof exposed cleanup and skill-materialization constraints absent at planning. **Interpretation**: Preserve the generated definition's steps and roles. Baseline mode permits terminal failures tied to recorded acceptance commands; awaiting approval and unrelated workflow failures still gate. Bundled `dartclaw-*` skills use managed copies; provider-native AndThen remains outside auth-clean containers under ADR-040 and the FIS boundary exception. Do not copy or mount host login/plugin directories. Consult S02's observations for exact receipts and the pre-fix trace-baseline drift. **Traced from**: S02/TI04–TI08. **Date**: 2026-11-17.

- **Person-owned execution holds**. **Description**: S03 holds automatic task accepts and workflow promotion/publish when execution-surface files or symlinks are changed. Agent-tool provenance cannot release those holds; host approval state uses reserved exact-data keys. **Rationale**: Live canaries now run behind the new deterministic review boundary. **Interpretation**: Never bypass a hold to make an unattended fixture pass. Ordinary code and instruction-file changes still proceed; person UI/API/channel-button action releases the held candidate (ADR-063). Preserve `_workflow.git.execution_surface_hold` and `_workflow.git.approved_candidate` as host-owned state if extending output/bridge paths. **Traced from**: S03/TI02, S03/TI05–TI07 and its discovered requirements. **Date**: 2026-11-17.

- **Proven toolchain image settings**. **Description**: S05's Dart recipe needs `HOME=/tmp` because unified analytics writes `~/.dart-tool`, and `/usr/local/bin/dart` because Codex login shells reset SDK PATH. Provider homes stay explicit. Node uses its pinned official toolchain with writable npm cache. **Rationale**: Versions alone passed while first-use/login commands failed in real runs. **Interpretation**: Preserve those fixes when adding registry environment; client registry variables belong at granted container creation, never in image ENV. Measure the existing `/tmp` caches as specified before relocating one, and keep the guide recipe mirror in step. Final S05 recipe and forced-stock receipts are in its observations. **Traced from**: S05/TI01, S05/TI03, S05/TI06. **Date**: 2026-11-17.

- **Concurrent registry frames must preserve the pipe writer's ownership**. **Description**: Pub's parallel metadata fetches exposed concurrent `BridgeRunner._write` calls adding to stdout while another frame's flush bound the sink, crashing the bridge with `Bad state: StreamSink is bound to a stream`. **Rationale**: Existing provider traffic did not exercise concurrent request-start writes against real stdio. **Interpretation**: Serialize frame add/flush pairs in the existing bridge writer, as the host pipe already does; keep frame layout, protocol version, in-flight and queue limits unchanged. Add a regression that holds one flush while another request arrives, then rebuild and rerun Docker/live proofs. **Traced from**: S06/TI10. **Date**: 2026-11-17.

- **Pre-implementation red is not a failed planning step**. **Description**: Once registry installs worked, the normal live Dart workflow stopped in `spec`: it ran the intentional stub test (Expected 4, Actual 0) and obeyed the fixture FEATURE's unconditional instruction to mark a command failure as a failed step. **Rationale**: S02/S05 baselines stopped on missing tools or registry access before this distinction was observable. **Interpretation**: In both existing fixture `story.md` prompt owners, distinguish expected red while classifying/planning from the post-implementation acceptance verdict. Preserve implementation stubs, tests, lockfiles, workflow phases and the normal recorder/verdict gate; do not pre-implement the fixture or repair model output. Fresh normal runs must implement the function and then install/test with exit 0. Session approved this reading at Resolution Ladder rung 2 (Widen), under TI10 and S02's step-path defect ownership. **Traced from**: S06/TI10; affects S07 and S09. **Date**: 2026-11-17.

- **Qualification command identity comes from executable/argument boundaries**. **Description**: Both normal live workflows completed and Codex recorded four real `dart test` results with exit marker 0, but the recorder's substring lookup matched a later `sha256sum total.dart test/total_test.dart ...` and replaced the valid test result with missing evidence. **Rationale**: S02's failing baselines did not reach the ship hash command. **Interpretation**: Keep one recognition owner in `coding_results.py`, consume the structured shell `command` argument, and recognize the fixed acceptance executable/arguments only at command boundaries using the standard shell lexer and the observed shell `-c` wrapper. Preserve the final genuine invalid-attempt refusal and every recorder/verdict gate. This is protocol-exact qualification evidence under ADR-054's deterministic carve-out, approved by the plan session at Resolution Ladder rung 2. Preserve the failed receipt and run the normal command again on final inputs. **Traced from**: S06/TI10; affects S07 and S09. **Date**: 2026-11-17.

## Implementation Observations

### Registry boundary and proof setup

- Admission: S02 and S05 were `done`; only shared `CHANGELOG.md` was dirty. Its existing edits are preserved and the whole file remains uncommitted for the plan owner. S06 owns its plan row and all other changed paths.
- TI02's metadata proof exercises the generic surface, so TI02–TI05 were implemented as one connected adapter/surface unit before closing those tasks. The pub adapter owns its origin, route, variable and metadata detection; the surface has no ecosystem literals. Existing provider header drop sets moved unchanged to `bridge_headers.dart` and provider regression tests stayed green.
- TI06 regression first failed with `Expected: throws <Instance of 'HttpException'>` / `Which: emitted <Instance of '_HttpResult'>`. Both a host failure frame after a chunk and the runner's own over-cap check now abort the connection. `HttpResponse.detachSocket` cannot detach after headers are sent (`Bad state: Headers already sent`); `response.deadline = Duration.zero` is the supported connection-destruction seam. The test covers both paths. Official API: <https://api.dart.dev/stable/latest/dart-io/HttpResponse/deadline.html>.
- An added non-HTTP redirect case first failed with `Bad state: Origin is only applicable to schemes http and https: file:///secret`; the origin check now rejects that scheme before comparing origins. It remains a deterministic enforcement decision under ADR-054.
- Real-Docker setup initially ran `docker exec dart pub get` in the image's `/workspace`, despite the manager's configured execution directory. The shared test wrapper's raw `docker exec` does not use `ContainerManager.exec`'s `-w`; the proof now explicitly enters the mounted `/project` before `dart pub get`.
- The Docker lockfile proof observed pub canonicalizing the hosted base to `http://127.0.0.1:8082/pub/` (trailing slash). This is the same mirror source required by S10, not host normalization. The fixture resolved from 1.0.0 to 1.1.0 and the assertion pins that actual lockfile spelling.
- External documentation was verified in fresh worker contexts using Context7 and Fetch. The current hosted protocol (<https://github.com/dart-lang/pub/blob/master/doc/repository-spec-v2.md>) permits archive redirects. `test` 1.33.0 metadata named a pub.dev archive and its HEAD returned 200 with zero redirects. Upstream `hosted.dart`, `package_name.dart`, `version_solver.dart` and `lock_file.dart` confirm that hosted URL is package source identity and a different mirror invalidates reuse of the old locked source. The executed S10 test supplies the newer-version evidence.

### Pub registry proof

- `bash dev/tools/build_bridge.sh` -> exit=0; both linux-x64 and linux-arm64 binaries generated before Docker and live proofs. Protocol version remains 1 and all existing limits remain unchanged.
- `dart test --run-skipped -t integration packages/dartclaw_runtime/test/integration/registry_bridge_integration_test.dart` -> exit=0, `00:17 +2: All tests passed!`. Workspace metadata and exact archive bytes cross the registry pipe under `network:none`; restricted has neither the variable nor a reachable registry listener. The Dart recipe installs from a fake registry and rewrites the old pub.dev lock to mirror source version 1.1.0.
- TI10's exact cache command plus `du -sk "$d/cache"` -> exit=0, `63456` KiB, below `76800` KiB (75% of the 100 MiB tmpfs). No recipe or cache relocation was needed.
- The normal both-provider live Dart run is collecting evidence; its final rows and input-freeze comparison are recorded below when settled.

### Verification and figure

- Focused bridge, gateway and container manager suites -> exit=0, `+172: All tests passed!`. This includes unchanged provider adapter regressions.
- Fast tier -> exit=0: kernel 1433, core 1757 (19 conditional skips), search 62, workflow 2150 (11 conditional skips), runtime 5768 (26 conditional skips), CLI excluding slow 857 (3 conditional skips): 12027 passing tests, 59 conditional skips. The newly excluded integration suite was explicitly executed above. Analysis reported `No issues found!`.
- `xmllint --noout dev/architecture/diagrams/security-host-gateway.svg` -> exit=0. Both 1000×694 theme renders were opened and inspected: `.agent_temp/s06/gateway-light.png`, `gateway-dark.png`; no clipped labels, crossing boxes or unreadable arrows. Browser pointer checks on registry and OpenAI nodes showed their details and registry edge highlight. The SVG's image role was removed only in the browser DOM to expose its native links to the pointer tool, with no source change.

### Parallel pub request diagnosis

- First normal live attempt: `.agent_temp/container-coding/20261117T194832Z.BealDj/`, command `DARTCLAW_CONTAINER_DATA_DIR=/Users/tobias/.dartclaw bash dev/testing/profiles/container/coding.sh --fixture dart`; deliberately interrupted (exit 130) after two registry bridge crashes. Each crash was `Bad state: StreamSink is bound to a stream` in `BridgeRunner._write` while pub's metadata requests overlapped stdout flush. Diagnostic input comparison `.agent_temp/s06/diagnostic-input-comparison.json` recorded zero source/script/bridge input changes during the attempt. Existing teardown removed its disposable resources.
- Regression `bridge_runner_test.dart#parallel requests serialize frames while stdout is flushing` first failed with `Expected: empty` / `Actual: [StateError:Bad state: StreamSink is bound to a stream]`. A gated real `IOSink` holds one frame's flush while another HTTP request arrives. Serializing add/flush pairs in the existing writer turns it green without a new protocol, limit or queue. The whole bridge runner file then passed 12 tests. No registry/provider policy was loosened.
- Boy Scout tidies: the extracted header-drop comment now describes both consumers rather than the provider-only JSON body; the edited security-wiring relative imports are ordered with the gateway dependency before the local owner.

- Second normal attempt: `.agent_temp/container-coding/20261117T195352Z.O2A63r/`, run `f37f5d99-2a6c-4db5-bbf2-6286e47b8e42`, exited 1 at `spec`. Registry install exited 0, changed 49 hosted source entries to `http://127.0.0.1:8082/pub/`, and moved `test` from 1.29.0 to 1.33.0. The spec step's intentional-stub test exited 1 (`Expected: <4>` / `Actual: <0>`), and the fixture's unconditional failure directive terminated the planning phase. No concurrency crash recurred. `.agent_temp/s06/recheck-input-comparison.json` records zero input changes. Both fixture instruction owners now distinguish pre-implementation red from post-implementation acceptance; stubs, tests, locks, recorder and normal verdict are unchanged.
- ASSUMPTION: S09's ecosystem-specific refusal wording applies to routed `RegistryBridgeSurface` policy decisions; shared framing, capacity and late streamed-cap failures remain `GatewayPipe`/`BridgeRunner` transport decisions with generic reasons. This preserves one authority per concern and the TI03/TI04/TI06 split, confirmed by the plan session at Resolution Ladder rung 2 (Widen). An explicit requirement for ecosystem attribution before route dispatch would change this reading. The security architecture and guide state the distinction.
- Independent primary-source check found that pub sends cached ETags as `If-None-Match`; its 304 handling precedes JSON decoding. The observed pub.dev 304 carries no Content-Type or body, so the adapter does not classify it as metadata and the existing response path preserves it. No special conditional-request handler was added.

- Falsifiability checks: removing method enforcement, redirect pinning, request header drops, response header drops, advertised-size refusal, audit recording, metadata rewriting, HEAD handling, positive grant, attach refusal or container environment each made its owning proof fail (11 mutations, exit 1 each). Eager archive buffering separately timed out the gated archive proof (exit 1), so byte-equality alone cannot hide buffering. All source was edited back before the fresh live run; restored focused suites passed 173 tests. Logs: `.agent_temp/s06/mutation-*.log` and `proof-selectors.log`.
- The redirect test's unpinned destination is a third loopback HTTP origin that records contacts. This makes removal of the pin fail on an actual outbound connection instead of accidentally passing on a DNS failure. The archive test holds origin EOF until `handle` returns, proving pass-through without body prefetch, and checks metadata HEAD returns no body.

- Third normal attempt: `.agent_temp/container-coding/20261117T200307Z.NhE1fF/`, Claude run `a77c3030-6c11-4dcd-9be7-cdaa958e6955` completed with install/test 0/0; Codex workflow also completed with all five tasks in `workspace`, zero new system-home rollouts and four actual successful `dart test` marker results. The command still exited 1 because a later ship hash command (`sha256sum total.dart test/total_test.dart ...`) matched the recorder's `dart test` substring and replaced the valid evidence with `None`. New regression first failed `AssertionError: None != 0`; the recorder now uses its one standard-lexer recognition owner over structured `arguments.command`, with no trace-preview fallback, shell-language evaluator or result repair. Latest genuine invalid attempts still refuse. Replaying only the original trace projection yields both providers 0/0 (`.agent_temp/s06/third-run-recorder-replay.json`); the original red results stay unchanged. A fresh final-input normal run remains mandatory.
- Third-attempt source/script/bridge comparison found no proof-epoch changes. The comparison reconstructs `coding_results_test.py` by removing the regression appended only after exit, which exactly matches its before hash; all other files compare directly. Receipt: `.agent_temp/s06/final-attempt-input-comparison.json`. Docker's scripted recipe build changed the outer image-index ID by exporting a new attestation; its cached layers and config remained the S05 build (`config sha256:2c39ad8f2eb4340c6981c01693a9d0c1067a5306fb26169a00139a628acfa670`). The build is at scenario setup, before provider turns. The next proof selects that built recipe by immutable image ID through the profile's existing `DARTCLAW_CODING_IMAGE` override, so both input manifests compare directly.
- Additional tidy: `GatewayRequest.readBody` no longer calls the service set “both bridge surfaces”; its UTF-8 rationale applies without an obsolete surface count.

### Chain attestation for independent review

- OC01: S01/S02 and TI01/TI02/TI07–TI10 connect the registry pipe, one grant and inherited client environment to real Docker installs and both real providers' successful install/test traces. The normal command's final projection on the corrected recorder remains a pending gate until the fresh final-input run exits 0.
- OC02: S03–S08 and TI03/TI04/TI06–TI09 prove positive workspace-only grant/attach refusal, GET/HEAD-only forwarding, exact redirect pins, credential stripping, cap preflight and abort after a streamed overrun; the targeted tests are falsified by removing those behaviors, and real restricted Docker access fails.
- OC03: S09 and TI05/TI11 connect routed request audit rows and policy refusal messages to SecurityWiring's existing audit/event owners; static security docs and the looked-at figure state the workspace-only pinned GET/HEAD path and distinguish shared transport failures.
- OC04: S01/S10 and TI09/TI11 prove the fake dependency's 1.0.0→1.1.0 re-resolution and both live providers' test 1.29.0→1.33.0 mirror lock diffs, with the accepted consequence documented in the ADR and guide.
- Inherited container baseline/lifecycle requirement: the existing profile/recorder remains the only scenario, its Python suite and actual live definition receipts preserve workflow phases and placement, native AndThen's auth-clean exception remains S02's, and teardown uses the existing owner. Only fixture instruction text and false-positive command recognition changed under the appended discoveries.
- Inherited person-owned hold requirement: no S03 gate, reserved key or authority path changed; the fast tier retains its regressions and the live ordinary-code fixture proceeds through the unchanged gates. No hold was bypassed.
- Inherited toolchain requirement: both recipe files, provider-home selections and container mount/capability arguments are unchanged apart from granted registry environment. The cache check is below threshold, login-shell Dart resolution succeeds in actual Codex traces, and the live runs use the existing S05 Dart recipe.

### Independent review and final proof epoch

- Reviewed: quick code+gap against S06 FIS and base 007816a50. Five Fix findings applied, no remaining code findings.
- The one repair round encodes frames before enqueueing so a per-request bound failure cannot poison the writer; cancels ignored redirect bodies without waiting for EOF; freezes the authority's granted-surface snapshot; supplies explicit served/refused audit state (upstream 404 is still served); and centralizes exact-origin lookup for redirects and metadata. Report and red/green evidence: `.agent_temp/s06/review/code-gap.md`. The reviewer also looked at both figure renders. The pending normal-command receipt remains executor-owned, not replaced by its review.
- Executor reran the final fast tier: exit 0, 12028 passed, 59 conditional skips (kernel 1433, core 1757/19 skips, search 62, workflow 2150/11, runtime 5769/26, CLI 857/3); analysis `No issues found!`. Executor's focused suites passed 175, Python recorder passed 13, both bridge architectures rebuilt, Docker suite passed `00:19 +2: All tests passed!`, global format reported `2241 files (0 changed)`, and diff/static namespace/protocol/kernel/XML checks were clean. Full/candidate gates remain the plan owner's tier under `--no-full-tier`.
- Direct substance/wiring scan found every registry adapter/surface/environment/header symbol consumed through the gateway, SecurityWiring and container creation; no new placeholder or unimplemented production path. The only null returns are explicit no-route/no-pin refusals. Fixture implementation stubs remain intentional and unchanged in the committed fixture source.

### Final accepted live receipt and proof lines

- `DARTCLAW_CONTAINER_DATA_DIR=/Users/tobias/.dartclaw DARTCLAW_CODING_IMAGE=sha256:21ea2b45e305a4afba1e0b8a800f6bef03390eb5a432a2d73c745b088b21f0d5 bash dev/testing/profiles/container/coding.sh --fixture dart` -> exit=0. Runner lines: `claude/dart: completed; install=0; test=0; Codex steps=0`; `codex/dart: completed; install=0; test=0; Codex steps=5`.
- Final receipt `.agent_temp/container-coding/20261117T203244Z.exV3Cr/results.md` / `results.json`: Claude run `56635084-4474-446c-b508-9a6c097dafb4`; Codex run `66915108-f096-4137-abe7-09c38f096da9`. Both CLI exits 0, all five tasks per provider name `workspace`, both lock diffs replace pub.dev with `http://127.0.0.1:8082/pub/` and upgrade test 1.29.0→1.33.0, zero new system-home DartClaw rollouts. The profile's teardown and fixture-source checks passed through its exit 0.
- Frozen final-input comparison `.agent_temp/s06/frozen-final-input-comparison.json`: 2438 inputs checked, zero changed. The immutable image index/layers/environment compare byte-identical before/after. It is the existing S05 Dart recipe, built from stock `sha256:f68f74c37b0d027b52344d4931f938932fdb793b3e82e8e9c1d46070ae99caed` plus pinned SDK digest `sha256:c78970229c8944bd6076caf4e5977ef569ba66750d301a2149f63b41a6725cec`, config `sha256:2c39ad8f2eb4340c6981c01693a9d0c1067a5306fb26169a00139a628acfa670`, linux/arm64, user dartclaw. SDK binary and its login-shell link both hash `af4456227aae943b9c91c6dd83496f6e0f67bfbb9c23b1311233de55387899b9`.
- Final rebuilt bridge SHA-256: linux-x64 `ef4a0012d41847cf0c877667a10e814f887f4adced67940b5deb362f384df7b4`; linux-arm64 `7f08479dfa58fef9bd394f05d74256e541fcd9b5b8f99177e6d1abd1feb0fbb2`. Both built before the accepted live proof. Live Docker server: linux/arm64.
- The active Codex container cache was also observed at 42264 KiB, below the 76800 KiB threshold (`.agent_temp/s06/codex-live-cache-observation.json`); this observation supplements TI10's completed exact host cache command at 63456 KiB. No cache or image recipe edit was needed.
- S01 mirror grep and TI10 heading grep -> exit=0. A stricter anchored heading check also passed, so the proof is the actual `### Pub registry proof` section rather than the FIS's own Verify text. TI11 registry checks passed for each named path individually; container-creation and both lockfile doc checks passed. TI12 namespace, protocol-version and empty-kernel-diff commands passed. Figure checklist was already rendered/looked at in both themes; the bridge-build-before-live checklist is met by the hashes above.

Final exact selector executions (each runner reported one passing test):

- TI01: packages/dartclaw_bridge/test/bridge_runner_test.dart#registry surface handshakes and listens -> exit=0, +1: All tests passed!
- TI02/S06: packages/dartclaw_runtime/test/container/gateway/pub_registry_adapter_test.dart#rewrites pinned download addresses and leaves archives untouched -> exit=0, +1: All tests passed!
- TI02/env: packages/dartclaw_runtime/test/container/gateway/pub_registry_adapter_test.dart#client environment points PUB_HOSTED_URL at the pub route -> exit=0, +1: All tests passed!
- TI03/S04: packages/dartclaw_runtime/test/container/gateway/registry_bridge_surface_test.dart#refuses a publish request without contacting the origin -> exit=0, +1: All tests passed!
- TI03/S05: packages/dartclaw_runtime/test/container/gateway/registry_bridge_surface_test.dart#follows redirects only inside the pinned origin set -> exit=0, +1: All tests passed!
- TI03/S07: packages/dartclaw_runtime/test/container/gateway/registry_bridge_surface_test.dart#drops credential headers both ways -> exit=0, +1: All tests passed!
- TI04/S08: packages/dartclaw_runtime/test/container/gateway/registry_bridge_surface_test.dart#refuses an advertised oversize artifact naming the cap -> exit=0, +1: All tests passed!
- TI05/S09: packages/dartclaw_runtime/test/container/gateway/registry_bridge_surface_test.dart#records served and refused requests without request content -> exit=0, +1: All tests passed!
- TI06/S08: packages/dartclaw_bridge/test/bridge_runner_test.dart#a response overrunning the cap after it started aborts the connection -> exit=0, +1: All tests passed!
- TI07/S03: packages/dartclaw_runtime/test/container/gateway/host_gateway_test.dart#grants the registry surface to workspace authorities and never restricted -> exit=0, +1: All tests passed!
- TI07/attach: packages/dartclaw_runtime/test/container/gateway/host_gateway_test.dart#refuses to attach a registry pipe to an authority without the grant -> exit=0, +1: All tests passed!
- TI08/SC01: packages/dartclaw_runtime/test/container/container_manager_test.dart#registry client environment is set only for a granted authority -> exit=0, +1: All tests passed!

### Final Chain Attestation

- OC01 closes through S01/S02 and TI01/TI02/TI07–TI10: the real Docker suite and the final normal command both pass, with two real providers installing and testing inside workspace containers without a network attachment.
- OC02 closes through S03–S08 and TI03/TI04/TI06–TI09: immutable positive grants, refused attach/write/unpinned routes, shared credential stripping, advertised-cap refusal and post-start abort all have executed proofs with unchanged pipe limits and container arguments.
- OC03 closes through S09 and TI05/TI11: explicit served/refused records and existing denial events carry routed authority/ecosystem/path/status without query/header/body content; the security docs and both looked-at diagram themes state the egress path.
- OC04 closes through S01/S10 and TI09/TI11: the fake lockfile proof selects 1.1.0 over 1.0.0, both real rows show test 1.33.0 over 1.29.0 and the mirror URL, and the guide/ADR accept that consequence.
- Inherited baseline/lifecycle closes through the existing scenario's final exit 0, source-fixture and cleanup checks, placement rows and zero system-home rollouts; no host provider home/plugin mount or second scenario was added.
- Inherited person-owned holds remain enforced through the unchanged S03 paths/reserved keys and their fast-tier regressions; the accepted fixture changed ordinary code/lock/spec files and no hold was bypassed.
- Inherited toolchain settings close through unchanged recipe source and final recipe provenance plus real Codex login-shell Dart installs/tests; the measured cache remains below relocation threshold and registry variables are granted at container creation only.

No separate Learnings entry was added: the admitted traps are now encoded in regressions, the bridge rationale, ADR-062 and the guide. S07/S09 inherit the fixture phase distinction and the shared recorder's command-boundary contract. No unresolved design or requirements debt was deferred.
