# Release Preparation

Run `bash dev/tools/release_check.sh` before tagging — it runs the automated gates as one command: exported bundle cleanup (`dev/bundle/` and legacy transient export paths must be empty; see `dev/state/SPEC-LIFECYCLE.md`), version pin lockstep (`check_versions.sh`), `dart format --set-exit-if-changed`, `dart analyze --fatal-warnings --fatal-infos`, and `dart test`. Use `--quick` to skip the test suite during iteration. The script's manual gates (still required before tagging) are:
- `dart test -t integration`
- UI smoke test: `bash dev/testing/profiles/smoke-test/run.sh` (requires a running dev server)

Then bump in a single commit:
- `dartclawVersion` in `packages/dartclaw_server/lib/src/version.dart`
- **every** publishable `packages/*/pubspec.yaml` `version:` field plus `apps/dartclaw_cli/pubspec.yaml` (lockstep — see `dev/guidelines/DART-PACKAGE-GUIDELINES.md` § Workspace-Wide Versioning Policy)
- CHANGELOG, `dev/state/STATE.md`, `dev/state/ROADMAP.md`, "Current through" markers in docs

## Release sequence (squash-merge pattern)

1. **Scope-frozen** commit on `feat/<version>` — final version pins, CHANGELOG entry, STATE.md says "release-ready, awaiting tag". Run `release_check.sh` here; manual gates pass.
2. **Squash-merge** to `main` with the release-style message; that commit *is* the release.
3. **Tag** annotated `v<version>` from the squash commit; push tag.
4. **Delete remote** feature branch (keep local as archive if useful).
5. **Branch `feat/<next>`** from the squash commit; first work-in-flight commit there flips STATE.md / ROADMAP.md to mark the previous version as tagged and open the new milestone as Active. No bookkeeping commit is needed on `main` itself — the tag is the source of truth for "released."
