# ADR-062: Read-only package-registry egress for containerized executions

## Status

Proposed – 2026-11-10. Owner pinned the defaults below for 0.28.1 (D1–D3); acceptance follows the live proof that
containerized coding steps fail without it.

## Context

A containerized execution runs with `--network none`, and its only way out is the per-authority bridge pipe to the
`HostGateway`: the `provider` surface (model API) and, when granted, the `mcp` surface (host tools, including the
canonical `web_search`/`web_fetch`). The agent image is `debian:bookworm-slim` with `curl`, `git`, `claude` and
`codex` (`docker/Dockerfile`).

So a containerized coding agent cannot run `dart pub get` or `npm install`, and any step that verifies with the
project's format, analyze and test commands (for example `merge_resolve`) depends on dependencies already present in
the mounted checkout. Container mode is the default posture where a runtime exists (ADR-055), so this is the default
experience for coding work, not an edge case.

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
| Ecosystems (0.28.1) | pub (`PUB_HOSTED_URL`) and npm (`npm_config_registry`), set in the container environment at spawn. Others are added as adapters when needed. |
| Upstreams | Each ecosystem adapter pins its origins (`https://pub.dev`, `https://registry.npmjs.org`, plus the exact download origin each one redirects to). Redirects are followed host-side only within that set. Not NetworkGuard's allowlist, whose wildcards (`*.googleapis.com`) are too broad for this. |
| Methods | `GET` and `HEAD` only. Anything else is refused host-side, so publish, login and upload paths cannot be reached. |
| Credentials | None. Requests go out without auth headers; container-supplied `Authorization` headers are dropped. Private registries are out of scope. |
| Response URLs | Absolute download URLs in registry metadata that point at a pinned origin are rewritten to the loopback mirror, so the client never tries a direct connection. A URL outside the pinned set is left unchanged and fails in the container. |
| Profiles | Granted to `workspace` authorities; never to `restricted`. No config knob. |
| Audit | Each request is recorded with authority, ecosystem, path and status; a refusal fires `GuardBlockEvent` (`guard: host-gateway`, `hook: bridge`), as other bridge refusals do. |
| Limits | The pipe's existing `BridgeLimits` apply (64 MiB per response, 8 in flight). An artifact over the cap fails with a message naming the cap. |

## Consequences

### Positive

- Containerized coding agents can resolve dependencies and run test suites, with the toolchain from a V2 image.
- The container still has no network and holds no credential; the bridge stays its only way out, so the Container
  Isolation definition in `UBIQUITOUS_LANGUAGE.md` holds unchanged.
- Read-only methods and pinned origins close the two holes devvm and `sbx` document: uploads to allowed hosts and SNI
  fronting.

### Negative

- Per-ecosystem code: each adapter knows its client's environment variable, its download origins and its URL
  rewriting. pip, cargo and others are not covered until added.
- Install-time package scripts (npm `postinstall`) run inside the container. They are contained by the same boundary
  as the agent, but a malicious dependency can still change the worktree; V3's review downgrade does not cover
  `package.json` or lockfiles.
- Registry metadata reveals which packages a task fetched; the audit log records them.
- Very large artifacts (some prebuilt binaries) exceed the 64 MiB response cap.
- A containerized `pub get` ignores a committed `pubspec.lock` whose hosted `url` differs from the mirror, writes
  one naming `http://127.0.0.1:8082/pub`, and re-resolves dependencies, possibly to newer versions. This drift is
  accepted; no host-side lockfile normalization or review hold is added.

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
  metadata rewriting and audit. Each `RegistryAdapter` owns its routes, exact origin pins, metadata detection and
  client variables; `SecurityWiring` registers each in one line.
- Pub pins `https://pub.dev` only. Execution-time metadata for `test` 1.33.0 named a pub.dev archive; its HEAD
  request returned 200 with zero redirects. The repository protocol permits redirects, so any later download
  origin must be added as an exact pin after observation, never a wildcard. Decoded JSON metadata URLs are
  rewritten to `/pub`; archive bytes are untouched. npm's registry-host replacement proof remains the next story's.
- Docs in the same change: `dev/architecture/security-architecture.md` (§ Host-Owned Provider Mediation, threat
  table), `docs/guide/security.md` (the "Sole egress" bullet), and its diagram.

## Project Compliance

- **ADR-054:** the decision is deterministic host enforcement; no model judgment is involved.
- **One authority per concern:** origin pinning lives in the surface's adapters, as it already does for provider
  adapters; NetworkGuard keeps owning tool-call domain checks.
- **ADR-015 / ADR-055:** the container boundary and its posture are unchanged; this extends the mediated path, not
  the network.

## References

- ADR-015 (container isolation strategy), ADR-051 (bridge binary packaging), ADR-052 (provider web tools denied in
  containers), ADR-055 (container-by-default posture).
- `packages/dartclaw_bridge/lib/src/bridge_protocol.dart`, `packages/dartclaw_runtime/lib/src/container/gateway/`.
- Private research: `dartclaw-private/docs/research/devvm-2026-11/research.md` (V1, §5).
