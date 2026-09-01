# ADR-051: Container Bridge Binary Packaging — Release-Time Cross-Compile, Host-Shipped, Mounted at Create

**Status:** Accepted — 2026-08-11 (targets 0.24 execution-isolation correction). Amended 2026-08-27 by [ADR-055](055-container-by-default-posture.md) — an undeliverable bridge binary downgrades to advisory mode under an inferred posture and stays fatal under an explicit one.
**Deciders:** DartClaw team

**Related:** [ADR-015](015-container-isolation-strategy.md) (hardened Docker container boundary), [ADR-039](039-outbound-mcp-trust-boundary-and-transport.md) (Dart-owned MCP trust boundary precedent), [ADR-047](047-embedded-binary-assets.md) (embedded binary assets — the shipping mechanism this ADR extends)

---

## Context

The 0.24 execution-isolation work introduces a small Dart-written bridge executable that runs *inside* the `network:none` agent container: a loopback HTTP-to-framed-stdio helper carrying provider and MCP traffic over host-controlled `docker exec` pipes. The host-side DartClaw process and the in-container bridge speak a custom framed protocol and must stay in version lockstep.

The agent image is `debian:bookworm-slim` with no Dart runtime and no DartClaw artifact. `ContainerManager.ensureImage()` returns early whenever the image tag exists, so anything baked into the image can silently go stale across DartClaw releases. End users run the AOT-compiled `dartclaw` binary and have no Dart SDK installed.

### Decision drivers

- **Version lockstep** — a bridge older or newer than the host framing codec is a protocol fault; skew must be structurally impossible or fail loudly.
- **No Dart on user machines beyond the shipped binary** — users cannot compile anything; the build must happen at release time.
- **Image stays minimal and stable** — the hardened agent image should not grow a toolchain or need rebuilds on every DartClaw release.
- **Portability** — macOS (Docker Desktop, arm64/x64) and Linux hosts; amd64 and arm64 container images.
- **Core philosophy** — smallest change, reuse existing seams (the embed-assets pipeline), no speculative machinery.

## Decision

**Cross-compile the bridge at release time and ship it with DartClaw; deliver it into the container at create time; verify compatibility with a protocol-version handshake.**

- **Build**: `dart compile exe --target-os=linux --target-arch=x64|arm64` (stable since Dart 3.8) produces self-contained Linux AOT binaries (~10 MB each) in CI/release, alongside the existing build steps. The first cross-compile per architecture downloads target SDK artifacts (cached in `~/.dart`) — a release-infrastructure concern only.
- **Ship**: both architecture variants ship with the DartClaw distribution via the existing embedded-binary-assets mechanism (ADR-047) — the host binary materializes the arch-matching bridge to its data directory on demand.
- **Deliver**: at container create, the bridge is provided read-only to the container — a read-only bind mount of the materialized binary (exec permitted on bind mounts by default, works on Docker Desktop and Linux), or a copy onto an exec-capable tmpfs (`--tmpfs <path>:exec,mode=0755`) where a mount is undesirable. Plain `docker cp` onto the read-only rootfs fails, and default `--tmpfs` mounts are `noexec` — both are known traps, not options.
- **Verify**: the first exchange on every bridge pipe is a protocol-version handshake; mismatch fails the surface closed before any harness admission. This is belt-and-braces — lockstep shipping makes mismatch structurally unlikely; the handshake makes it impossible to run through.
- The agent image remains Dart-free and does not change when DartClaw releases.

## Consequences

**Positive**
- Host and bridge are the same release by construction — no image-rebuild orchestration, no stale-bridge window behind `ensureImage()`'s tag check.
- Agent image stays minimal, stable, and cacheable across DartClaw releases.
- No network, SDK pull, or docker-build work on user machines; airgapped-friendly.
- Reuses the ADR-047 shipping pipeline instead of adding a second artifact channel.

**Negative / accepted**
- Distribution grows ~20 MB uncompressed (two Linux AOT binaries); compressible, and in line with the ADR-047/048 bundle model.
- Release CI gains two cross-compile invocations and their (cached) target-SDK downloads.
- A read-only bind mount adds one mount to the container inspection surface; it is enumerated in the isolation conformance checks (it is a binary the host controls, not a socket or writable channel).

## Alternatives Considered

1. **Multi-stage Dockerfile (Dart SDK build stage compiles the bridge into the agent image)** — rejected. Users have no Dart SDK and the image builds on their machines: this ships bridge *source* to users, pulls a ~300 MB SDK image at image-build time, and freezes the bridge into an image that outlives releases — recreating the stale-bridge problem plus a rebuild/invalidation story that lockstep shipping avoids entirely.
2. **Dedicated bridge sidecar image** (Testcontainers-Ryuk style) — rejected. A second published artifact with tag-coordination burden, for a helper whose whole contract is lockstep with the host binary; appropriate for genuinely standalone helpers, which this is not.
3. **Run the bridge from source / bundle a Dart runtime in the image** — rejected outright; contradicts the minimal hardened image and the zero-toolchain posture.

**Precedents**: VS Code Server (client copies the exact-commit server into the container at attach), JetBrains dev-container backends (IDE-version-matched backend installed at runtime), and Dagger's CLI-provisioned engine (pinned same-version image) all converge on host-owned, version-lockstep helper delivery at runtime; image-baked helpers (OpenHands runtime image, E2B envd) belong to systems that must graft onto arbitrary user images or own both sides of a template pipeline.

## Implementation Notes

- Add the two cross-compile invocations to `dev/tools/build.sh` and the release workflow next to the existing embed/build steps; local source-tree development compiles the bridge on demand (Linux dev hosts natively; macOS via the same cross-compile flag).
- Handshake carries protocol version and surface identity; the host codec owns the version constant.
- The mount/tmpfs delivery path, the exec-permission trap, and the inspection-surface entry are specified in the 0.24 execution-isolation gateway spec (`dev/bundle/docs/specs/0.24-execution-isolation/`, transient) and land in `dev/architecture/security-architecture.md` with that work.
- Multi-arch: host materializes the variant matching the container platform (amd64/arm64), not the host platform.

## Project Compliance

Smallest change that solves the real problem (two compiler invocations + an existing shipping pipeline), reuse before build (ADR-047 mechanism), root cause over workaround (removes the version-skew class instead of detecting it after the fact), approachable over clever (a copied binary and a version byte beat image-rebuild orchestration).

## References

- Research appendix: [research/051-container-bridge-binary-packaging.md](research/051-container-bridge-binary-packaging.md) (Dart cross-compilation status, helper-shipping precedent survey, exec-mount traps; 2026-08 sources)

## Amendment (2026-08-21) – the bridge remains a zero-dependency package

The 0.25 topology consolidation leaves `dartclaw_bridge` at `packages/dartclaw_bridge/` as a standing top-level
package with zero dependencies. This supersedes the bridge half of FR14's proposed core absorption; the storage half
landed in core as recorded by [ADR-056](056-package-topology-consolidation.md).

The decision follows the build-hook probe run with Dart 3.13.0:

| Entrypoint package | `dart compile exe` result |
|---|---|
| pre-absorption `dartclaw_storage`, with `sqlite3` | Refused: `dart compile` does not support build hooks and names `sqlite3` |
| pre-absorption `dartclaw_core`, before it gained `sqlite3` | Succeeded |
| `dartclaw_bridge`, targeting Linux x64 and arm64 | Succeeded |
| `dartclaw_cli`, with `sqlite3` | Refused with the same build-hook message |

The expected refusal is not itself a sufficient safety boundary. The workspace misclassification recorded in
[ADR-048](048-release-builds-dart-build-bundled-sqlite.md) can instead let `dart compile exe` succeed while omitting
SQLite's native-asset mapping. After storage absorption, core therefore cannot host a supported self-contained runtime
artifact on that path whether the SDK refuses correctly or silently emits an incomplete binary. Keeping the bridge's
entrypoint and wire implementation together in a dependency-free package prevents both outcomes structurally.

Two workarounds remain rejected:

1. Switching the bridge to `dart build cli` would run hooks but cannot cross-compile. It would replace one host build
   of both Linux targets with native runners per target despite the bridge needing no native asset.
2. Moving the implementation and leaving a package-shaped executable stub would keep the package count while losing
   the zero-dependency reason for it. The stub would either depend on a hook-bearing host or duplicate the wire
   implementation, and a later cleanup could fold it away without seeing the packaging invariant.

A dedicated package makes hook freedom an enforced property rather than an incidental property of whichever host
package happens to be hook-free today. The fitness suite pins the pubspec shape, and fixed-path binary comparisons pin
the release artifact produced by `dev/tools/build_bridge.sh`.
