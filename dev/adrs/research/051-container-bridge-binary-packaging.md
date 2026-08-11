# Research Appendix — ADR-051 Container Bridge Binary Packaging

Sources gathered 2026-08-11 for the bridge-executable packaging decision. Web findings summarized; URLs as-retrieved.

## Dart cross-compilation status

- `dart compile exe --target-os=linux --target-arch=x64|arm64` is **stable since Dart 3.8** (May 2025); ARM32/RISCV64 targets added in 3.9. Target OS is Linux only — sufficient here. Output is a fully self-contained AOT executable (~10 MB); no experimental flags. (dart.dev/tools/dart-compile; Dart 3.8 announcement)
- First cross-compile per target downloads target-arch SDK artifacts, cached under `~/.dart` — a build-infrastructure concern, irrelevant to end users.
- Decisive constraint: DartClaw end users run an AOT binary with **no Dart SDK**, so any "compile on the user's machine" variant (including image-build-time compilation, which runs on the user's machine) effectively ships source plus a toolchain requirement.

## Helper-shipping precedent survey

| System | Baked vs copied-in | Version-skew handling |
|---|---|---|
| VS Code Dev Containers | Copied in at runtime (VS Code Server) | Pinned to the exact client commit (`~/.vscode-server/bin/<commit>`) — skew structurally impossible |
| JetBrains dev containers | Copied in at runtime (IDE backend) | Backend version matched to IDE client |
| Dagger | Engine as pinned same-version image, CLI-provisioned; earlier per-container shim later removed | CLI↔engine version identity via pinned tag |
| Testcontainers Ryuk | Own dedicated image | Tag pinned per library release; tiny protocol rarely skews |
| OpenHands runtime server | Baked — runtime image built on the user's machine at session start | Tag encodes version; needs docker build at startup; documented start-failure bugs |
| E2B envd | Baked into template rootfs at template build | Template rebuild on envd update; vendor owns both sides |

Pattern: systems that own both ends and update in lockstep copy the helper in at runtime with exact-version pinning; image-baking suits standalone helpers or grafting onto arbitrary user images.

## Multi-stage Dart image build (rejected option)

- Official pattern exists (`FROM dart:stable` build stage → AOT binary into slim/scratch stage; multi-arch supported). Cost in DartClaw's model: the agent image builds on the *user's* machine (`ensureImage()`), so a build stage means shipping bridge source, pulling the ~300 MB SDK image, minutes of build, and a bridge frozen into an image that outlives releases — `ensureImage()` early-returns whenever the tag exists, so staleness is silent without an added rebuild trigger. A protocol handshake would still be required, so the option pays image-rebuild orchestration *and* still needs the safety net.

## Exec-into-read-only-container traps

- `docker cp` into a read-only rootfs fails ("rootfs is marked read-only"); the target must be a writable or mounted path.
- `--tmpfs` defaults to `noexec,nosuid,nodev` — a binary copied there will not execute unless the tmpfs is mounted with explicit `exec` (long-standing behavior; docker/compose#3425).
- Read-only **bind mounts** permit exec by default, work on Docker Desktop (virtiofs) and Linux, and are host-controlled and tamper-proof from inside the container — the simplest deterministic delivery.
- Architecture match is required: Apple Silicon → linux/arm64 image → arm64 bridge; both targets covered by the stable cross-compiler.

## Synthesis

Option B (release-time cross-compile, ship with DartClaw, mount at create) wins on version skew (lockstep by construction), robustness (one exec-permission care point vs. rebuild orchestration + user-side SDK pulls), release complexity (two compiler invocations + ~20 MB assets vs. a second build pipeline), and portability (macOS/Linux hosts, amd64/arm64 images). It matches the strongest precedent class (VS Code Server, JetBrains, Dagger) and reuses the ADR-047 shipping mechanism. The protocol-version handshake is retained as belt-and-braces in either option, which removes the multi-stage option's only structural advantage.
