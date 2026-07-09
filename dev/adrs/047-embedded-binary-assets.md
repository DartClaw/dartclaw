# ADR-047: Embedded Binary Assets — Generated Dart Source Replaces the Sidecar/Download Model

**Status:** Proposed — 2026-07-07. Targets 0.20.1 (before 0.21 Windows, whose release-artifact story it simplifies). FIS bundle in private repo `docs/specs/0.20.1/`.
**Deciders:** DartClaw team

**Related:** [ADR-018](018-cli-onboarding-architecture.md) (CLI onboarding — introduced the asset download path), [ADR-038](038-homebrew-formula-publication.md) (Homebrew formula — consumes the platform archive this ADR simplifies)

---

## Context

The AOT-compiled `dartclaw` binary needs 93 built-in text files (~1.2 MB) at runtime: server Trellis templates (448 K), vendored static web assets (692 K), workflow skills (32 K), and built-in workflow YAML definitions (36 K). `dart compile exe` produces machine code plus a small runtime only — it has no asset-bundling mechanism — so these files currently ship *outside* the binary:

- a `share/dartclaw/` sidecar tree inside the platform release archive, and
- a runtime-downloaded `dartclaw-assets-v<version>.tar.gz` from GitHub releases (`AssetDownloader`, `dartclaw assets download`) with sha256 verification and `VERSION`-skew handling.

Runtime resolution walks a five-way provenance chain (`asset_resolver.dart`: explicit config → dev source tree → installed-alongside-binary → downloaded cache → source-tree default). The costs: a multi-file install contract, a runtime network dependency with its own failure modes, version-skew surface between binary and assets, release-pipeline weight (extra archive + checksum), and a broken story for SDK consumers — anyone embedding `dartclaw_server` in their own compiled binary gets no assets at all.

### Decision drivers

- **Single-file binary** is the distribution goal (Homebrew, upcoming Windows/Scoop) — sidecar models fight it structurally.
- **No runtime network dependency** for first-run correctness.
- **SDK consumers** must get self-contained packages that work inside their own `dart compile exe` output.
- **Dev loop preserved** — source checkouts must keep live-editing templates/CSS/YAML without a regeneration step per edit.
- **Core philosophy** — smallest change, no new toolchain magic, reuse existing seams (`WorkflowMaterializer`, dev-mode resolution).

## Decision

**Embed all built-in assets as data-as-code: a build-time generator emits checked-in generated Dart libraries, so assets compile into the binary.**

- **Generator**: a plain Dart script (`dev/tools/embed_assets.dart`, no build_runner) walks the four asset directories and emits one generated library per *owning* package — `dartclaw_server` (templates + static), `dartclaw_workflow` (skills + workflow definitions) — exposing read-only `path → content` maps. Content is base64-encoded per file (sidesteps string-escaping edge cases; the very_good_cli/dcli precedent) and lazily decoded with caching. Only runtime-read files are embedded: the paired `.dart` template companions (30 files, ~220 K) are compiled into the binary as code and are excluded from the maps — embedded payload is therefore ~63 files / ~1.0 MB.
- **Checked in + drift-gated**: generated files are committed (pub.dev doesn't run generators; SDK consumers need them present). A CI gate reruns the generator and fails on `git diff`, same discipline as the format gate.
- **Resolution collapses** to: explicit config → dev/source tree → embedded. The `installedAlongsideBinary`, `downloadedCache`, and `VERSION`-skew paths are deleted. Dev workflows (`--dev`, maintainer `preferSourceTree`, `examples/run.sh`) keep reading files directly from the checkout — the embedded map is the compiled-binary default, not a dev-path replacement.
- **Consumers**:
  - Template `loader.dart` reads from the embedded map (dev mode keeps disk reads).
  - Static assets served by a small in-memory shelf handler (content-type by extension, cache headers keyed on `dartclawVersion`), replacing `createStaticHandler` for the embedded case.
  - Skills + workflow YAML keep the existing `WorkflowMaterializer` disk-materialization (spawned claude/codex processes need real files) — only its *source* changes from a resolved directory to the embedded map.
- **Deleted**: `AssetDownloader`, the `dartclaw assets` CLI command, the assets tarball + checksum from `dev/tools/build.sh` and the release workflow, and the cache/skew logic in `asset_resolver.dart`.
- **Fitness gates**: `arch_check` LOC/structural ceilings exclude generated asset libraries (they are data, not code).

## Consequences

**Positive**
- True single-file binary; Homebrew formula and 0.21 Windows/Scoop artifacts ship one executable with no asset staging.
- No runtime download, checksum, or version-skew failure modes; `dartclaw assets download` support surface disappears.
- pub packages become self-contained — SDK consumers' own compiled binaries get working templates/static/skills.
- Net code deletion: downloader + CLI command + two resolver provenance paths + release-pipeline steps.

**Negative / accepted**
- Binary grows ~1.2 MB (payload is text; negligible against the AOT baseline).
- Asset edits require a generator re-run before commit; forgetting is caught by the CI drift gate, not at edit time.
- Generated files add ~1.6 MB of committed source (base64 expansion); diffs on vendored-asset bumps are opaque blobs (the sibling `VENDORS.md` remains the human-readable change record).
- Asset updates now require a release (no out-of-band asset refresh) — acceptable: assets and code were version-locked anyway; skew was a bug source, not a feature.

## Alternatives Considered

1. **SDK hooks / data assets** (`dart build cli` + `package:data_assets`) — rejected for now. Data assets are experimental (labs.dart.dev, v0.20.0), standalone-Dart support and the `dart:asset` runtime API are unbuilt (dart-lang/sdk#56217, #54003), and `dart compile exe` *fails* when hooks are present. Decisive even at stability: `dart build` outputs a bundle *directory* (sidecar files) — it never yields a single file. Note: 0.21's use of `dart build cli` for the bundled-SQLite *code* asset on Windows is orthogonal and compatible.
2. **Executable self-append** (Deno/bun-style blob trailer read via `Platform.resolvedExecutable`) — rejected. No supported contract (sdk#39576 open since 2019), and appending bytes invalidates macOS code signatures / fails notarization (Apple TN2206).
3. **Keep the sidecar/download model** — rejected; it is the problem under decision (multi-file install, network dependency, skew surface, broken SDK-consumer story).
4. **`package:embed`** (annotation + build_runner, actively maintained) — viable off-the-shelf equivalent, rejected in favor of a ~100-line bespoke script to avoid adopting build_runner into the toolchain (zero-magic posture). Revisit if generator maintenance ever exceeds the dependency cost.

**Precedents**: very_good_cli ships checked-in generated `*_bundle.dart` files (base64 `MasonBundle` literals); `dcli pack` generates `PackedResource` classes + a `ResourceRegistry` with unpack-to-disk — the same decode-and-materialize shape as our `WorkflowMaterializer`.

## Implementation Notes

- Land as the 0.20.1 FIS bundle (private repo `docs/specs/0.20.1/`): embedding + generation + gates first, consumption + deletion + release-pipeline cleanup second.
- Encoding is an internal detail of the generated libraries — consumers see decoded `String` content only, so a later switch (e.g. gzip+base64 if payload grows) is non-breaking.
- The maintainer workflow profile's `preferSourceTree` must keep winning over embedded content; add a regression test.
- Risk: stale generated content when running from source without regenerating — mitigated by dev-mode source-tree precedence plus the CI drift gate.
- Docs currency: `docs/guide/deployment.md`, `docs/guide/cli-reference.md`, affected package `CLAUDE.md` files, and the ADR-038 formula template update in the same change.

## Project Compliance

Aligns with the binding core philosophy: root cause over workaround (deletes the download/skew machinery instead of hardening it), reuse before build (materializer and dev-mode seams unchanged), smallest change (plain script, no build_runner), approachable over clever (data-as-code is inspectable, greppable, codesign-safe).

## References

- Research appendix: [research/047-embedded-binary-assets.md](research/047-embedded-binary-assets.md) (verified SDK status, ecosystem survey, self-append analysis; mid-2026 sources)
