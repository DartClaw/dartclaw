# ADR-047: Embedded Binary Assets — Generated Dart Source Replaces the Sidecar/Download Model

**Status:** Accepted — 2026-07-10. Implemented in 0.20.1 (before 0.21 Windows, whose release-artifact story it simplifies). Milestone record in private repo `docs/specs/0.20.1/prd.md`; the FIS bundle was consolidated into it and removed at release preparation. Amended by [ADR-048](048-release-builds-dart-build-bundled-sqlite.md) (2026-07-10): release artifacts are no longer single-file — `dart build cli` bundles the SQLite native library in a sibling `lib/` on every platform. Built-in text and binary assets remain embedded per this ADR. Corrected 2026-07-27 to document the implemented text-map plus binary-byte-map shape and source-tree development precedence; the accepted data-as-code decision is unchanged. **Amended 2026-08-06**: the generated libraries are no longer committed — see [Amendment: generated at build time](#amendment-2026-08-06--generated-at-build-time-not-committed). The data-as-code decision itself is unchanged.
**Deciders:** DartClaw team

**Related:** [ADR-018](018-cli-onboarding-architecture.md) (CLI onboarding — introduced the asset download path), [ADR-038](038-homebrew-formula-publication.md) (Homebrew formula — consumes the platform archive this ADR simplifies)

---

## Context

The AOT-compiled `dartclaw` binary needs 93 built-in text files (~1.2 MB) at runtime: server Trellis templates (448 K), vendored static web assets (692 K), workflow skills (32 K), and built-in workflow YAML definitions (36 K). Before this decision, these files shipped outside the binary through:

- a sidecar tree inside the platform release archive, and
- a runtime-downloaded asset archive with checksum and version-skew handling.

Runtime resolution walks a five-way provenance chain (`asset_resolver.dart`: explicit config → dev source tree → installed-alongside-binary → downloaded cache → source-tree default). The costs: a multi-file install contract, a runtime network dependency with its own failure modes, version-skew surface between binary and assets, release-pipeline weight (extra archive + checksum), and a broken story for SDK consumers — anyone embedding `dartclaw_server` in their own compiled binary gets no assets at all.

### Decision drivers

- **Single-file binary** is the distribution goal (Homebrew, upcoming Windows/Scoop) — sidecar models fight it structurally.
- **No runtime network dependency** for first-run correctness.
- **SDK consumers** must get self-contained packages that work inside their own `dart compile exe` output.
- **Dev loop preserved** — source checkouts must keep live-editing templates/CSS/YAML without a regeneration step per edit.
- **Core philosophy** — smallest change, no new toolchain magic, reuse existing seams (`WorkflowMaterializer`, dev-mode resolution).

## Decision

**Embed all built-in assets as data-as-code: a build-time generator emits generated Dart libraries, so assets compile into the binary.** (Originally "checked-in"; superseded 2026-08-06 — see the amendment.)

- **Generator**: a plain Dart script (`dev/tools/embed_assets.dart`, no build_runner) walks the four asset directories and emits one generated library per *owning* package — `dartclaw_server` (templates + static), `dartclaw_workflow` (skills + workflow definitions). Each library exposes a read-only text map (`embeddedServerAssets` / `embeddedWorkflowAssets`, `Map<String, String>`) and a separate binary byte map (`embeddedServerBinaryAssets` / `embeddedWorkflowBinaryAssets`, `Map<String, List<int>>`). Both are base64-backed and lazily decoded with caching; binary values are immutable byte lists, so consumers never UTF-8 re-encode binary assets. Only runtime-read files are embedded: the paired `.dart` template companions (30 files, ~220 K) are compiled into the binary as code and are excluded from the maps — embedded payload is therefore ~63 files / ~1.0 MB.
- ~~**Checked in + drift-gated**: generated files are committed (pub.dev doesn't run generators; SDK consumers need them present). A CI gate reruns the generator and fails on `git diff`, same discipline as the format gate.~~ **Superseded 2026-08-06** — generated at build time, not committed. See the amendment below.
- **Resolution collapses** to: explicit config → development source tree → discovered source-tree default → embedded. The `installedAlongsideBinary`, `downloadedCache`, and `VERSION`-skew paths are deleted. Dev workflows (`--dev`, maintainer `preferSourceTree`, `examples/run.sh`) keep reading files directly from the checkout — the embedded maps are the compiled-binary default, not a dev-path replacement.
- **Consumers**:
  - Template `loader.dart` reads text from `embeddedServerAssets` only for the embedded fallback; explicit, `--dev`, and discovered source-tree assets retain filesystem precedence.
  - `createEmbeddedStaticHandler` reads `embeddedServerBinaryAssets` first and writes those bytes directly to the response, then falls back to text from `embeddedServerAssets`; the filesystem static handler remains active for source-tree modes.
  - Built-in workflow YAML keeps `WorkflowMaterializer` disk-materialization — its supplied or discovered source tree wins, otherwise it reads text from `embeddedWorkflowAssets`.
  - DartClaw-native skills are provisioned by `bootstrapWorkflowSkills` through `SkillProvisioner`: a discovered skills source directory wins, otherwise `SkillProvisioner` materializes the `skills/` entries from `embeddedWorkflowAssets` into provider-native roots for harness access.
- **Deleted**: `AssetDownloader`, the `dartclaw assets` CLI command, the assets tarball + checksum from `dev/tools/build.sh` and the release workflow, and the cache/skew logic in `asset_resolver.dart`.
- **Fitness gates**: `arch_check` LOC/structural ceilings exclude generated asset libraries (they are data, not code).

## Consequences

**Positive**
- Built-in text and binary assets need no asset sidecar or runtime download. Release bundles still carry the sibling SQLite library required by ADR-048, but Homebrew and Windows/Scoop need no separate asset staging.
- No runtime download, checksum, or version-skew failure modes; the former asset-management subcommand disappears.
- pub packages become self-contained — SDK consumers' own compiled binaries get working templates/static/skills.
- Net code deletion: downloader + CLI command + two resolver provenance paths + release-pipeline steps.

**Negative / accepted**
- Binary grows by the embedded asset payload; negligible against the AOT baseline.
- ~~Asset edits require a generator re-run before commit; forgetting is caught by the CI drift gate, not at edit time.~~ **Superseded 2026-08-06** — the files are generated, not committed, and the CI drift gate is deleted; CI/build/release generate before every gate.
- ~~Generated files add ~1.6 MB of committed source (base64 expansion); diffs on vendored-asset bumps are opaque blobs (the sibling `VENDORS.md` remains the human-readable change record).~~ **Superseded 2026-08-06** — the generated libraries are no longer committed.
- Asset updates now require a release (no out-of-band asset refresh) — acceptable: assets and code were version-locked anyway; skew was a bug source, not a feature.

## Alternatives Considered

1. **SDK hooks / data assets** (`dart build cli` + `package:data_assets`) — rejected for now. Data assets are experimental (labs.dart.dev, v0.20.0), standalone-Dart support and the `dart:asset` runtime API are unbuilt (dart-lang/sdk#56217, #54003), and `dart compile exe` *fails* when hooks are present. Decisive even at stability: `dart build` outputs a bundle *directory* (sidecar files) — it never yields a single file. Note: the use of `dart build cli` for the bundled-SQLite *code* asset ([ADR-048](048-release-builds-dart-build-bundled-sqlite.md), all platforms) is orthogonal and compatible — code assets bundle via hooks, while built-in text and binary data assets stay embedded.
2. **Executable self-append** (Deno/bun-style blob trailer read via `Platform.resolvedExecutable`) — rejected. No supported contract (sdk#39576 open since 2019), and appending bytes invalidates macOS code signatures / fails notarization (Apple TN2206).
3. **Keep the sidecar/download model** — rejected; it is the problem under decision (multi-file install, network dependency, skew surface, broken SDK-consumer story).
4. **`package:embed`** (annotation + build_runner, actively maintained) — viable off-the-shelf equivalent, rejected in favor of a ~100-line bespoke script to avoid adopting build_runner into the toolchain (zero-magic posture). Revisit if generator maintenance ever exceeds the dependency cost.

**Precedents**: very_good_cli ships checked-in generated `*_bundle.dart` files (base64 `MasonBundle` literals); `dcli pack` generates `PackedResource` classes + a `ResourceRegistry` with unpack-to-disk — the same decode-and-materialize shape as our `WorkflowMaterializer`.

## Implementation Notes

- Land as the 0.20.1 FIS bundle (two stories, consolidated into private repo `docs/specs/0.20.1/prd.md`): embedding + generation + gates first, consumption + deletion + release-pipeline cleanup second.
- Encoding is an internal detail of the generated libraries — text consumers see decoded `String` values and binary consumers see decoded immutable `List<int>` values, so a later backing-encoding switch (e.g. gzip+base64 if payload grows) is non-breaking.
- The maintainer workflow profile's `preferSourceTree` must keep winning over embedded content; add a regression test.
- Risk: stale generated content when running from source without regenerating — mitigated by dev-mode source-tree precedence; since 2026-08-06 the files are generated before every gate, so staleness is structurally impossible rather than detected.
- Docs currency: `docs/guide/deployment.md`, `docs/guide/cli-reference.md`, affected package `CLAUDE.md` files, and the ADR-038 formula template update in the same change.

## Project Compliance

Aligns with the binding core philosophy: root cause over workaround (deletes the download/skew machinery instead of hardening it), reuse before build (materializer and dev-mode seams unchanged), smallest change (plain script, no build_runner), approachable over clever (data-as-code is inspectable, greppable, codesign-safe).

## Amendment (2026-08-06) — generated at build time, not committed

**The generated libraries are gitignored and emitted by the build instead of being committed.**

*Extended 2026-08-20*: the same posture now covers the three served design-system stylesheets — `packages/dartclaw_server/lib/src/static/{tokens,design-system,icons}.css` are written by the same generator from `dev/design-system/{tokens,components,icons}.css` and are likewise gitignored. They were previously committed twice and reconciled by a SHA-256 provenance header plus a fitness check; generating removes the second copy and with it the drift the check existed to catch.

The original rationale — "pub.dev doesn't run generators; SDK consumers need them present" — assumed both owning packages ship to pub.dev. [ADR-008](008-sdk-publishing-strategy.md) was narrowed the same day: publication intent is per-package and both owners (`dartclaw_server`, `dartclaw_workflow`) are undecided. Nothing is published today, so the constraint does not bind now; it binds at first publish.

Weighed against that: the committed `dartclaw_server` library is 1.7 MB of base64 (`dartclaw_workflow`'s is 70 KB), rewritten on every template, static-asset, skill, or definition edit — 13 commits so far. Staleness was gated twice (a CI `git diff` step and `embedded_assets_test.dart`) and still shipped a broken branch, because both gates only fire well after the edit. Generating always makes staleness structurally impossible rather than merely detected.

**What changed**
- Both files are in `.gitignore`; `git rm --cached` removed them from tracking. The three served stylesheets joined them under the 2026-08-20 extension, replacing `dev/tools/fitness/check_design_system_sync.sh`.
- `dart run dev/tools/embed_assets.dart` runs in `.github/workflows/ci.yml` (before format/analyze/test), in `dev/tools/build.sh` (before `dart build cli`), and in `dev/tools/release_check.sh`.
- The CI `git diff` drift gate is deleted — it can no longer fail.
- `embedded_assets_test.dart` is unchanged and retained. It verifies generator correctness (generated content matches sources) and, locally, catches an asset edit made without regenerating. In CI it can no longer fail on staleness, since generation now always precedes it — the freshness check was the deleted `git diff` gate, a separate mechanism.

**Cost accepted**: `lib/` imports the generated libraries, so a fresh checkout reports ~32 analyzer errors until the generator is run once. That bootstrap step is documented in `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md` and both package `CLAUDE.md` files.

**Publishing requirement (unresolved until first publish)**: a published package must physically contain its generated library — there is no consumer-side mechanism to produce importable Dart source. Build hooks (`hook/build.dart`) emit only `CodeAsset` native libraries consumed via `dart:ffi`, not importable source; `build_runner` does not run for consumers of a published package. `dart pub publish` selects files by walking the filesystem and filtering by ignore rules, and a `.pubignore` *replaces* a directory's `.gitignore` — so a package-local `.pubignore` that does not list the generated file should publish it even though git ignores it. **That path is inferred from the packaging rules, not verified.** Before the first publish of either owning package: run the generator, then `dart pub publish --dry-run` and confirm every generated file appears in the file listing — `lib/src/generated/embedded_assets.g.dart` for both packages, plus `lib/src/static/{tokens,design-system,icons}.css` for `dartclaw_server`. If any is missing, add the package-local `.pubignore` or unignore those files for that package. Do not assume it works.

## References

- Research appendix: [research/047-embedded-binary-assets.md](research/047-embedded-binary-assets.md) (verified SDK status, ecosystem survey, self-append analysis; mid-2026 sources)
