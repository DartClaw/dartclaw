# ADR-062: Read-only package-registry egress for containerized executions

## Status

Accepted – 2026-11-17. Both providers installed dependencies and passed tests in the Dart and Node workspace fixtures.

Amended – 2026-11-18, accepted 2026-11-19: ecosystems become configuration data instead of one Dart adapter class
each, built-in ecosystems grow to pub, npm (with bun), PyPI (pip, uv), crates.io (Cargo) and Go, and `workspace`
containers get a package-cache volume. Both providers installed dependencies and passed tests in the Dart, Node,
Python, Rust and Go workspace fixtures. Before the amendment, every new ecosystem
needed a DartClaw release, while the per-ecosystem knowledge was four values with no logic.

## Context

Before this decision, a containerized execution ran with `--network none` and could leave only through two
`HostGateway` surfaces: `provider` for model calls and, when granted, `mcp` for host tools including
`web_search` and `web_fetch`. The agent image is `debian:bookworm-slim` with `curl`, `git`, `claude` and
`codex` (`docker/Dockerfile`).

Without a path to package registries, a containerized coding agent could not install dependencies with `dart pub get`
or `npm install`. Steps that verify with the project's format, analyze and test commands (for example `merge_resolve`)
depended on dependencies already present in the mounted checkout. Container mode is the default posture where a
runtime exists (ADR-055), so this affected coding work by default.

Two outside designs were examined (private research `devvm-2026-11`, 2026-11-07 and 2026-11-10): devvm and Docker
Sandboxes (`sbx`) both put a host-side forward proxy in front of an allowlist, and both intercept TLS with a
per-sandbox CA to apply credentials or method/path rules. devvm documents that its SNI-only host check admits domain
fronting. `sbx`'s issue history shows the CA's cost: a CA compromise that forced image rebuilds (0.49.2), nested
`docker build` trust failures, and whole-body buffering that breaks streaming.

The bridge already has the shape needed. The in-container bridge serves plain HTTP on a loopback port and frames each
request and response over the pipe; the host makes the real HTTPS call to an upstream origin the adapter pins
(`provider_adapter.dart`). `HostGateway.register` decides the authority's surfaces and `_surfaceFor` picks the handler
per surface (`host_gateway.dart:133`, `:222`).

## Decision

Add a third bridge surface, `registry`, served by a host-side registry mirror.

| Aspect | Rule |
|---|---|
| Transport | The package manager talks plain HTTP to the bridge's loopback port; the host performs the HTTPS request. No CA in the container, no CONNECT tunnel, no network attachment. `network:none` stays. |
| Ecosystems as data | Each ecosystem is a `container.registries.<name>` record: `enabled`, `upstreams` (`{route, origin}` list), `env` (client variables; `{mirror}` expands to the mirror base) and `rewrite_json` (`{route, path_prefix, content_types}` list). Built-ins ship as the same records. An operator toggles a built-in with an entry that carries only `enabled` (so `go: {enabled: true}` turns Go on), replaces one by redefining its name with any other field (whole record, no field merge) or adds one. `env` keys compare case-insensitively. The setting is restart-only and read only from the instance config, never from a project. |
| Built-ins (0.28.1) | `pub` (`PUB_HOSTED_URL`), `npm` (`npm_config_registry` with a trailing slash so bun resolves it, `npm_config_audit=false`), `pypi` (`PIP_INDEX_URL`, `UV_DEFAULT_INDEX`; `pypi.org` + `files.pythonhosted.org`), `crates` (`index.crates.io` + `static.crates.io`; `config.json` rewritten) and `go` (`GOPROXY`, `GOSUMDB`; `proxy.golang.org` + `sum.golang.org`), each admitted by its passing fixture on 2026-11-19. `go` ships `enabled: false`: proxy.golang.org fetches any module path it is asked for, so it relays requests to hosts the container chooses. Cargo has no environment setting for source replacement, so its `config.toml` lives in the toolchain's image recipe, where the route names are a documented contract. Maven, RubyGems, NuGet and Hex are config-only additions until a fixture admits them. Composer, Gradle, Poetry, SwiftPM and CocoaPods are out of scope: they fetch from GitHub, fetch over git (which needs POST), or have no global mirror setting. |
| Upstreams | Each record pins its exact HTTPS origins. The host follows redirects only within that record's pins. Startup refuses an invalid record: non-https origin, userinfo, a path or an IP literal in an origin, a duplicate route, or an `env` key another record or DartClaw itself sets. |
| Package caches | `workspace` containers get an anonymous volume at `/var/cache/dartclaw`, writable and executable, removed with the container. Image recipes point package caches and `GOTMPDIR` there. Runtimes give local volumes no portable size cap, so its size is bounded by container lifetime and host disk, not by a limit. |
| Methods | `GET` and `HEAD` only. Anything else is refused host-side, so publish, login and upload paths cannot be reached. |
| Credentials | None. Requests go out without auth headers; container-supplied `Authorization` headers are dropped. Private registries are out of scope. |
| Response URLs | The client never needs a direct connection for a pinned-origin download. A record lists metadata for URL rewriting only if its client has no registry-host replacement. JSON is the only rewrite format; no in-scope ecosystem needs HTML or XML. URLs outside the pins have no route through the mirror. |
| Profiles | Granted to `workspace` authorities; never to `restricted`. No config knob. |
| Audit | Each request is recorded with authority, ecosystem, path including query, and status; a refusal fires `GuardBlockEvent` (`guard: host-gateway`, `hook: bridge`), as other bridge refusals do. |
| Limits | The pipe's existing `BridgeLimits` apply (64 MiB per response, 8 in flight). An artifact over the cap fails with a message naming the cap. |

## Consequences

### Positive

- Containerized coding agents can resolve dependencies and run test suites, with the toolchain from a V2 image.
- The container still has no network and holds no credential; the bridge stays its only way out, so the Container
  Isolation definition in `UBIQUITOUS_LANGUAGE.md` holds unchanged.
- Read-only methods and pinned origins close the two holes devvm and `sbx` document: uploads to allowed hosts and SNI
  fronting.

### Negative

- A record's pins are GET egress to that origin under the container's control: path, query and non-credential headers
  reach it. That is safe for a single-tenant package registry and an exfiltration channel for GitHub, object storage,
  a CDN or JitPack. Validation cannot judge an origin, so the operator who adds one owns that choice; the guide says so.
- Path-prefixed private mirrors (Artifactory, Nexus) cannot be a pin, because pins are origins only. They are out of
  scope with private registries.
- Clients without registry-host replacement require metadata URL rewriting to keep pinned-origin downloads on the
  mirror.
- Install-time package scripts (npm `postinstall`) run inside the container. They are contained by the same boundary
  as the agent, but a malicious dependency can still change the worktree; V3's review downgrade does not cover
  `package.json` or lockfiles.
- Registry metadata reveals which packages a task fetched; the audit log records them.
- Very large artifacts (some prebuilt binaries) exceed the 64 MiB response cap.
- A containerized `pub get` ignores a committed `pubspec.lock` whose hosted `url` differs from the mirror, writes
  one naming `http://127.0.0.1:8082/pub/`, and re-resolves dependencies, possibly to newer versions. `uv` likewise
  writes mirror URLs into `uv.lock`, so `uv sync --locked` fails on a lockfile written outside the container. This
  drift is accepted; no host-side lockfile normalization or review hold is added.
- The package-cache volume has no size cap; a dependency tree that fills it fails the install, and leftover volumes
  are removed with their container.

## Alternatives Considered

- **CONNECT tunnel with a host allowlist.** Works for any client, but the host sees only the target host, never method
  or path, and needs a new bidirectional frame type. Inherits devvm's SNI fronting weakness. Rejected.
- **TLS termination with a per-authority CA** (devvm, `sbx`). Full method/path control for any client, but the CA must
  be trusted by every toolchain in the image, and `sbx`'s issues show the operational cost. Rejected.
- **A separate networked install container** that runs only the project's install command. Generic and needs no
  proxy, but Docker has no egress allowlist without a proxy, so install scripts run with open network beside the
  mounted source. Rejected.
- **Host-side dependency prefetch** before the container starts. Runs third-party package scripts on the host, and
  cannot serve a dependency the agent adds mid-turn. Rejected.
- **Status quo** (dependencies must be vendored). Leaves container mode unusable for most coding work. Rejected.

## Implementation Notes

- Bridge: `BridgeSurface.registry` uses loopback port 8082. Client environment is set at container creation by
  `ContainerManager`, from the same positive `workspace` grant that selects the pipe. A bridge process cannot
  export variables to a sibling provider process. The protocol version stays 1: only the surface enum grows,
  no framing or handshake layout changes. A stale binary refuses `--surface=registry` and acquisition fails closed.
- Host: `RegistryBridgeSurface` owns methods, header stripping, pinned redirects (at most five hops), limits,
  metadata rewriting and audit. It reads validated `container.registries` records; the `RegistryAdapter` interface
  and its per-ecosystem classes are removed. Registry `env` is emitted before DartClaw's own container variables, and
  validation refuses overlapping keys, so no record can replace `ANTHROPIC_BASE_URL`.
- Pub pins `https://pub.dev` only. Execution-time metadata for `test` 1.33.0 named a pub.dev archive; its HEAD
  request returned 200 with zero redirects. The repository protocol permits redirects, so any later download
  origin must be added as an exact pin after observation, never a wildcard. Decoded JSON metadata URLs are
  rewritten to `/pub`; archive bytes are untouched.
- npm pins `https://registry.npmjs.org` for both packuments and tarballs. With Node 24.22.3 and npm 11.19.1,
  the default `replace-registry-host` routed downloads from both packuments and lockfiles through `/npm` during
  `npm install` and `npm ci`. The adapter leaves packuments untouched, and `package-lock.json` keeps public URLs.
  `npm_config_audit=false` prevents the default audit POST.
- PyPI, crates.io and Go (fixtures run on 2026-11-19 with Python 3.14.9 and uv 0.13.6, Cargo 1.99.0, Go 1.26.9).
  Every row was served on all of its record's routes, with no refusal:
  - uv accepts the plain-HTTP loopback index without flags.
  - Cargo accepts the `sparse+http://` replacement registry from the recipe's `/.cargo/config.toml`.
  - Go accepts an `http://` `GOPROXY` and an `http://` URL in `GOSUMDB`, which reaches the checksum database only
    through the `gosum` route.
  - `go mod tidy` writes `go.sum`; `go mod download` writes only the `/go.mod` hashes, after which `go test` fails.
  - Neither `GOTOOLCHAIN=local` nor bun's reading of the npm record was exercised by a fixture: both are set from
    their tools' documentation and the second-opinion bun experiment.
- Docs in the same change: `dev/architecture/security-architecture.md` (§ Host-Owned Provider Mediation, threat
  table), `docs/guide/security.md` (the "Sole egress" bullet), and its diagram.

## Project Compliance

- **ADR-054:** the decision is deterministic host enforcement; no model judgment is involved.
- **One authority per concern:** ecosystem data (origins, routes, client variables, rewrite rules) lives in the
  kernel's `container_registries.dart` records and is validated once at config load. `RegistryBridgeSurface` enforces
  the pins it is handed and names no ecosystem. NetworkGuard keeps owning tool-call domain checks.
- **ADR-015 / ADR-055:** the container boundary and its posture are unchanged; this extends the mediated path, not
  the network.

## References

- ADR-015 (container isolation strategy), ADR-051 (bridge binary packaging), ADR-052 (provider web tools denied in
  containers), ADR-055 (container-by-default posture).
- `packages/dartclaw_bridge/lib/src/bridge_protocol.dart`, `packages/dartclaw_runtime/lib/src/container/gateway/`.
- Private research: `dartclaw-private/docs/research/devvm-2026-11/research.md` (V1, §5).
