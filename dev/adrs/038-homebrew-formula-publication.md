# ADR-038: Homebrew Formula Publication via Canonical Template + CI-Mirrored Tap

## Status

Accepted – 2026-06-09 (implemented in 0.18, fulfilling PRD FR14 "standalone binary distribution polish"); amended
2026-07-12 to apply the same publication pattern to Scoop for Windows, and 2026-07-19 to stage all platform artifacts
before one atomic GitHub Release publication.

**Related:** [ADR-008](008-sdk-publishing-strategy.md) (pub.dev publishing strategy — this is the analogous decision for the end-user binary). Runtime behavior is unaffected; CI credential handling and distribution integrity are security-critical.

## Context

0.18 ships a Homebrew-first install path (`brew tap DartClaw/dartclaw && brew install dartclaw`) for the standalone AOT binary on macOS (arm64+x64) and Linux (x64+arm64). The release workflow already builds those four platform archives and publishes them — each with a `.sha256` — as GitHub Release assets on every `v*` tag.

A Homebrew tap requires a *separate* repository (`DartClaw/homebrew-dartclaw`) containing `Formula/dartclaw.rb`, where each platform URL is pinned to its archive's SHA256. Those digests cannot exist until the binaries are built, and there are **four distinct ones across four matrix jobs** — unlike a single universal-binary formula. Left manual, the formula drifts every release (the pre-0.18 in-repo formula was stale: wrong version, placeholder digests, wrong license), and the documented install path silently breaks.

## Decision

Keep one **canonical formula template in the main repo** (`package/homebrew/dartclaw.rb`) under normal code review and a structural test (`apps/dartclaw_cli/test/tool/homebrew_formula_test.dart`), and treat the tap's `Formula/dartclaw.rb` as a **generated mirror** that is never hand-edited.

- The in-repo template carries the real structure, `version` (lockstepped to `dartclawVersion`, test-enforced), URLs, and **placeholder SHA256 digests** — the digests are the only build-derived part.
- A Dart renderer (`dev/tools/render_homebrew_formula.dart`) injects the four verified per-platform digests, asserting version lockstep and exactly one digest slot per target.
- The build matrix stages its archives as private workflow artifacts. After every platform build and the staged Windows
  installer test pass, one `publish` job verifies all five archive/sidecar pairs, creates `SHA256SUMS.txt`, and publishes
  the complete GitHub Release asset set. Homebrew and Scoop jobs depend on `publish`, then consume those public checksums.
- The `homebrew` job renders the formula and pushes it to the tap using a `HOMEBREW_TAP_TOKEN` secret. The job no-ops
  (does not fail the release) when the secret is absent.
- Auth is a **fine-grained PAT** scoped to the Homebrew tap and Scoop bucket repositories (`contents:write`), stored as
  the `HOMEBREW_TAP_TOKEN` secret in the `distribution-publication` environment.
- Both publication jobs use the protected `distribution-publication` environment. It requires approval before the PAT
  is exposed; `v*` tag creation/deletion is restricted by a repository ruleset. Workflow-wide permissions remain
  `contents:read`, with `contents:write` granted only to the single GitHub Release publication job.
- Provider CLIs (`claude`, `codex`, Goose, Vibe) remain explicit operator prerequisites, **not** `depends_on` Homebrew dependencies (test-enforced).

## Consequences

### Positive

- Single source of truth: the formula's reviewable, testable structure lives with the code; the tap holds only generated output.
- No release-time drift — version + digests are injected from the build, so the documented `brew install` always tracks the tag.
- The renderer is unit-tested and fails loud on lockstep drift or a missing/duplicate digest slot, instead of producing a silently-wrong formula.
- Least-privilege publication (PAT scoped to the two generated distribution repositories); absent secret degrades
  gracefully rather than red-failing the release.

### Negative

- The in-repo formula's placeholder digests are intentionally non-installable — a maintainer copying it by hand would get a checksum mismatch (mitigated: this ADR + a tap README note marking the formula as generated).
- Two repos and a manually-provisioned secret are operational prerequisites; an absent secret skips publication, while an expired or insufficiently authorized PAT fails the publication jobs (the release-prep checklist verifies both commits landed).

## 0.21 Amendment – Scoop Publication

Windows distribution uses the same canonical-template and generated-mirror decision. `package/scoop/dartclaw.json` is
reviewed and structurally tested in the main repo; `dev/tools/render_scoop_manifest.dart` injects the verified Windows
ZIP digest; the release workflow publishes the result as `bucket/dartclaw.json` in `DartClaw/scoop-dartclaw` using the
same distribution-scoped `HOMEBREW_TAP_TOKEN` as Homebrew.

Scoop requires the install-time `architecture.64bit.url` to contain the concrete release version. `$version`
substitution is valid only in `autoupdate.architecture.64bit.url`; `#{version}` is not Scoop syntax. This package-manager
rule refines the template shape without changing the publication architecture.

## Alternatives Considered

1. **Formula only in the tap repo, patched in place** (the xcodeproj-cli pattern) — rejected: that project fuses one universal macOS binary (1 digest, simple `sed`); DartClaw has four platform digests, and keeping the canonical structure in the main repo retains code review + the existing formula test.
2. **`brew bump-formula-pr` / GoReleaser** — rejected for now: heavier toolchain for a single tap; the Dart renderer reuses the existing AOT/asset pipeline with zero new dependencies, consistent with the zero-npm/zero-third-party posture.
3. **GitHub App token instead of a PAT** — rejected: more setup for two generated distribution repositories; one
   fine-grained PAT restricted to those repositories is sufficient.
4. **Manual formula update each release** (pre-0.18 status quo) — rejected: proven to drift (stale version, placeholder digests, wrong license) and breaks the documented install path.

## References

- CHANGELOG `[0.18.0]` — Added: Versioned distribution & Homebrew install (S08); tap auto-publication.
- `.github/workflows/release-binaries.yml` (`homebrew` job), `dev/tools/render_homebrew_formula.dart`, `package/homebrew/dartclaw.rb`, `apps/dartclaw_cli/test/tool/homebrew_formula_test.dart`
- `dev/guidelines/RELEASE_PREPARATION.md` (Homebrew audit + `HOMEBREW_TAP_TOKEN` prerequisite)
- Tap repo: `DartClaw/homebrew-dartclaw`
- Scoop bucket repo: `DartClaw/scoop-dartclaw`
- 0.18 PRD FR14.
