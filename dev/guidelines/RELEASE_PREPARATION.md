# Release Preparation

Run `bash dev/tools/release_check.sh` before tagging — it runs the automated gates as one command: exported bundle cleanup (`dev/bundle/` and legacy transient export paths must be empty; see `dev/state/SPEC-LIFECYCLE.md`), version pin lockstep (`check_versions.sh`), `dart format --line-length=120 --set-exit-if-changed`, `dart analyze --fatal-warnings --fatal-infos`, and `dart test`. Use `--quick` to skip the test suite during iteration. The following gates are also required before tagging and should be delegated to parallel sub-agents:
- Live integration tests: `bash dev/testing/profiles/workflow-live/run.sh --full` plus any package-specific `dart test --run-skipped -t integration ...` live files relevant to the release. Runs `dart test` directly — no running server required, but needs real provider credentials.
- UI smoke test: start the server with `bash dev/testing/profiles/plain/run.sh` (port 3335, token `devtoken0`), then run the `andthen:visual-validation` skill against `http://localhost:3335/?token=devtoken0` covering TC-01…TC-31 and R-01…R-12 from `dev/testing/UI-SMOKE-TEST.md`.
- release asset audit: confirm GitHub Releases has `dartclaw-v{VERSION}-macos-arm64.tar.gz`, `dartclaw-v{VERSION}-macos-x64.tar.gz`, `dartclaw-v{VERSION}-linux-x64.tar.gz`, `dartclaw-v{VERSION}-linux-arm64.tar.gz`, `dartclaw-assets-v{VERSION}.tar.gz`, each matching `.sha256`, and `SHA256SUMS.txt` covering every archive
- Homebrew audit: the platform SHA256 values are injected automatically — only bump `version` in the canonical template `package/homebrew/dartclaw.rb` to match `dartclawVersion` (the formula test enforces lockstep; the placeholder digests stay). After tagging, the `Release Binaries` workflow's `homebrew` job renders the template with the verified release digests and pushes `Formula/dartclaw.rb` to the `DartClaw/homebrew-dartclaw` tap. Confirm the tap commit landed and that `brew tap DartClaw/dartclaw && brew install dartclaw && dartclaw --version` prints the release version exactly. Requires the `HOMEBREW_TAP_TOKEN` repo secret (fine-grained PAT with `contents:write` on the tap repo); if absent, the job skips and the formula must be rendered (`dart run dev/tools/render_homebrew_formula.dart`) and pushed manually
- provider prerequisite audit: confirm install docs keep `claude --version`, `codex --version`, Goose, and Vibe as explicit operator prerequisites rather than Homebrew dependencies

Then bump in a single commit:
- `dartclawVersion` in `packages/dartclaw_server/lib/src/version.dart`
- **every** publishable `packages/*/pubspec.yaml` `version:` field plus `apps/dartclaw_cli/pubspec.yaml` (lockstep — see `dev/guidelines/DART-PACKAGE-GUIDELINES.md` § Workspace-Wide Versioning Policy)
- `version` in the canonical Homebrew template `package/homebrew/dartclaw.rb` (lockstep with `dartclawVersion`)
- CHANGELOG, `dev/state/STATE.md`, `dev/state/ROADMAP.md`, "Current through" markers in docs

## Release sequence (squash-merge pattern)

1. **Scope-frozen** commit on `feat/<version>` — final version pins, CHANGELOG entry, STATE.md says "release-ready, awaiting tag". Run `release_check.sh` here; manual gates pass.
2. **Squash-merge** to `main` with the release-style message; that commit *is* the release.
3. **Tag** annotated `v<version>` from the squash commit; push tag.
   The release workflow must publish `macos-arm64`, `macos-x64`, `linux-x64`, and `linux-arm64` platform archives, shared assets, per-archive `.sha256` files, and aggregate `SHA256SUMS.txt`, and (via the `homebrew` job) push the rendered `Formula/dartclaw.rb` to the `DartClaw/homebrew-dartclaw` tap.
4. **Delete remote** feature branch (keep local as archive if useful).
5. **Branch `feat/<next>`** from the squash commit; first work-in-flight commit there flips STATE.md / ROADMAP.md to mark the previous version as tagged and open the new milestone as Active. No bookkeeping commit is needed on `main` itself — the tag is the source of truth for "released."
