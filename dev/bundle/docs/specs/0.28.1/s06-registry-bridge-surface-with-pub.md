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

- **Person-owned execution holds**. **Description**: S03 holds automatic task accepts and workflow promotion/publish when execution-surface files or symlinks are changed. Agent-tool provenance cannot release those holds; host approval state uses reserved exact-data keys. **Rationale**: Live canaries now run behind the new deterministic review boundary. **Interpretation**: Never bypass a hold to make an unattended fixture pass. Ordinary code and instruction-file changes still proceed; person UI/API/channel-button action releases the held branch. Preserve `_workflow.git.execution_surface_hold` and `_workflow.git.approved_branches` as host-owned state if extending output/bridge paths. **Traced from**: S03/TI02, S03/TI05–TI07 and its discovered requirements. **Date**: 2026-11-17.

- **Proven toolchain image settings**. **Description**: S05's Dart recipe needs `HOME=/tmp` because unified analytics writes `~/.dart-tool`, and `/usr/local/bin/dart` because Codex login shells reset SDK PATH. Provider homes stay explicit. Node uses its pinned official toolchain with writable npm cache. **Rationale**: Versions alone passed while first-use/login commands failed in real runs. **Interpretation**: Preserve those fixes when adding registry environment; client registry variables belong at granted container creation, never in image ENV. Measure the existing `/tmp` caches as specified before relocating one, and keep the guide recipe mirror in step. Final S05 recipe and forced-stock receipts are in its observations. **Traced from**: S05/TI01, S05/TI03, S05/TI06. **Date**: 2026-11-17.
