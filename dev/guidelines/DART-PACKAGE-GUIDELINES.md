# Dart Package Creation & Publishing Guidelines

Best practices for creating, structuring, and publishing Dart packages (libraries and apps).

**Sources**: [Create Packages](https://dart.dev/tools/pub/create-packages), [Package Layout](https://dart.dev/tools/pub/package-layout), [Writing Package Pages](https://dart.dev/tools/pub/writing-package-pages), [Publishing](https://dart.dev/tools/pub/publishing), [pub.dev Scoring](https://pub.dev/help/scoring), [Versioning](https://dart.dev/tools/pub/versioning), [Dependencies](https://dart.dev/tools/pub/dependencies)


## Package Structure

### Required Layout

```
my_package/
├── pubspec.yaml          # Package metadata (required)
├── lib/
│   ├── my_package.dart   # Main library file — exports public API
│   └── src/              # Private implementation (never import from outside)
│       ├── feature_a.dart
│       └── feature_b.dart
├── test/                 # Tests
├── example/              # Example code (required for pub.dev score)
├── LICENSE               # Required for publishing (recommend BSD-3-Clause)
├── README.md             # Required for publishing
├── CHANGELOG.md          # Recommended — shown on pub.dev
└── analysis_options.yaml # Linter/analyzer config
```

### Optional Directories

- `bin/` — Executable scripts (put on PATH via `dart pub global activate`)
- `tool/` — Build scripts, code generators, dev utilities
- `benchmark/` — Performance benchmarks
- `doc/` — Additional documentation
- `integration_test/` — Integration tests

### File Rules

- Code in `lib/src/` is **private** — never import `package:x/src/...` from outside
- Main library exports public API explicitly using `export ... show`
- One class per file unless classes are tightly coupled
- Use relative imports within `lib/`; use `package:` imports from outside `lib/`
- `pubspec.lock` — commit for apps, **exclude for libraries** (`.gitignore`)


## Public API Design

### Export Strategy (Main Library File)

```dart
// lib/my_package.dart
export 'src/feature_a.dart' show FeatureA, FeatureAConfig;
export 'src/feature_b.dart' show FeatureB;
export 'src/exceptions.dart' show MyPackageException;
```

- Use `show` to expose exact symbols — prevents accidental API leaks
- Groups related exports — gives users a clear overview of public API
- Use conditional exports for platform-specific code

### API Surface Principles

- Minimize public API surface — expose only what users need
- Use `final` classes by default — only allow subclassing when designed for it
- Use `sealed` for exhaustive type hierarchies
- Avoid exposing implementation details (internal types, helper utilities)
- Prefix internal-but-exported helpers with docs stating they're internal


## pubspec.yaml

### Required Fields

```yaml
name: my_package                      # lowercase, underscores, valid Dart identifier
version: 1.0.0                        # semver
description: >-                       # concise, searchable description
  Brief description of the package.
environment:
  sdk: ^3.8.0                         # minimum Dart SDK version (use current stable)
```

### Recommended Fields

```yaml
homepage: https://example.com/my_package
repository: https://github.com/user/my_package
issue_tracker: https://github.com/user/my_package/issues
topics:                                # for pub.dev discoverability
  - templating
  - html
platforms:                             # override auto-detection if needed
  web:
  linux:
  macos:
  windows:
funding:
  - https://github.com/sponsors/user
```

### Package Naming

- All lowercase: `[a-z0-9_]`
- Underscores separate words: `just_like_this`
- Valid Dart identifier (no leading digits, no reserved words)
- Should be clear, terse, unique — check pub.dev for availability


## Dependencies

### Version Constraints

- Use caret syntax: `^1.4.0` (means `>=1.4.0 <2.0.0`)
- Range syntax for complex needs: `>=1.4.0 <2.0.0`
- **Never** use `any` — always constrain versions
- Only list direct dependencies; pub resolves transitive ones

### Dependency Categories

```yaml
dependencies:           # Runtime dependencies — shipped with package
  http: ^1.0.0

dev_dependencies:       # Development only — tests, linting, code gen
  test: ^1.25.0
  lints: ^6.0.0
```

### Rules for Published Packages

- Depend only on pub.dev hosted packages and SDK packages
- **Never** use `path:`, `git:`, or custom hosted deps in published packages
- Keep dependency count minimal — each dep is a maintenance liability
- Avoid very new/unstable packages as dependencies


## Semantic Versioning

### Version Format: `MAJOR.MINOR.PATCH`

| Change | Bump | Example |
|--------|------|---------|
| Breaking API changes | **MAJOR** | `1.0.0` → `2.0.0` |
| New backward-compatible features | **MINOR** | `1.0.0` → `1.1.0` |
| Backward-compatible bug fixes | **PATCH** | `1.0.0` → `1.0.1` |

### Pre-1.0.0 Conventions

- `0.x.y` signals unstable API — breaking changes may happen at minor bumps
- Move to `1.0.0` when API is stable and ready for production use

### Pre-release Versions

- Format: `1.0.0-dev.1`, `1.0.0-alpha.1`, `1.0.0-beta.1`, `1.0.0-rc.1`
- Precedence: `1.0.0-alpha.1` < `1.0.0-beta.1` < `1.0.0-rc.1` < `1.0.0`

### Publishing Immutability

- Published versions **cannot be changed or unpublished** (except rare cases)
- Always create a new version for any changes
- Use "discontinued" marking instead of unpublishing


## Workspace-Wide Versioning Policy (DartClaw-specific)

DartClaw uses **lockstep versioning across the workspace**: every published package
under `packages/*` plus `apps/dartclaw_cli` shares the same `version:` value, matching
the milestone identifier (`dartclawVersion` in `packages/dartclaw_server/lib/src/version.dart`).

**Rules**

- When tagging a milestone, bump **every** publishable package and the CLI app to the
  new version in a single commit. Don't bump packages piecemeal as breaking changes
  land — that produces version drift between packages, which is misleading on pub.dev
  ("Is this from 0.10 or 0.16?") and breaks the `dev/tools/check_versions.sh` invariant.
- The runtime `dartclawVersion` constant and every package `pubspec.yaml`'s `version:`
  field move together — they are not independent axes.
- `dev/tools/check_versions.sh` enforces this and **must pass** before tagging. CI runs
  it as part of release-binaries.yml prerequisites. If you have a genuine reason to
  diverge a single package's version, that's a policy change and needs an ADR — don't
  silently leave drift in.
- The bump itself follows standard semver from this section: a milestone with breaking
  changes is a MAJOR-direction bump, additive changes a MINOR bump, fix-only releases
  a PATCH bump. The lockstep applies to *which* packages bump, not to *how much*.

**Why lockstep over independent semver:** at DartClaw's current maturity (pre-1.0,
co-evolving packages, tight integration), independent semver would force every
consumer to think about cross-package compatibility matrices on every upgrade. Lockstep
reduces that to a single version axis. Once the API surface and consumer base settle,
this can be revisited via ADR — until then, keep it uniform.


## README Best Practices

### Structure for Maximum Impact

1. **Short description** (1-2 sentences) at the very top
2. **Badges** — build status, pub.dev version, coverage
3. **Visual content** — screenshots, GIFs for UI packages (near top)
4. **Key features** — bulleted list
5. **Getting started** — installation, basic setup
6. **Usage examples** — practical code snippets
7. **API overview** — link to generated docs
8. **Limitations** — known constraints, unsupported platforms
9. **Contributing** — link to contribution guide
10. **License** — brief mention with link

### Key Tips

- Users spend seconds deciding — optimize for quick scanning
- Use lists and headers liberally
- Include keywords/related terms for discoverability
- Show code examples with proper Dart syntax highlighting
- Mention constraints early (platform limitations, min SDK)


## CHANGELOG Best Practices

### Format

```markdown
## 1.1.0

- Added `newFeature()` method
- Fixed null handling in `parse()` (#42)

## 1.0.0

- **Breaking change:** Renamed `oldMethod()` to `newMethod()`
- Initial stable release

### Upgrading from 0.x

Change calls to `oldMethod()` to `newMethod()`.

## 0.1.0

- Initial development release
```

### Rules

- Each version gets its own section
- Consistent heading levels (all `##` or all `#`)
- Highlight breaking changes prominently
- Include migration guidance for major versions
- Reference issue numbers where applicable


## pub.dev Scoring (160 points max)

| Category | Points | Key Requirements |
|----------|--------|------------------|
| Documentation — API docs | 10 | ≥20% of public API has `///` doc comments |
| Documentation — Example | 10 | Working example in `example/` directory |
| Platform Support | 20 | Support multiple platforms (auto-detected from imports) |
| Static Analysis | 50 | No errors, warnings, lints, or formatting issues |
| Dependencies | 10 | All deps supported in latest version |
| SDK Compatibility | 10 | Compatible with latest stable Dart/Flutter SDKs |

> Scoring criteria may evolve — check [pub.dev/help/scoring](https://pub.dev/help/scoring) for current model.

### Score Maximization Checklist

- Complete pubspec.yaml with all recommended fields
- `LICENSE` file (BSD-3-Clause preferred)
- `README.md` with description, examples, features
- `CHANGELOG.md` with proper per-version formatting
- `example/` directory with working example code
- Document ≥20% of public API with `///` doc comments
- Support multiple platforms (avoid platform-specific imports when possible)
- Use conditional imports for platform-specific code
- Keep dependencies up-to-date
- Use latest stable Dart SDK


## Publishing Workflow

### Pre-Publish Checklist

1. Verify `pubspec.yaml` — all required fields, valid URLs
2. Run `dart analyze` — zero issues
3. Run `dart test` — all tests passing
4. Run `dart doc` — docs generate without errors
5. Run `dart pub outdated` — review and update stale dependencies
6. Run `dart pub publish --dry-run` — verify pre-flight checks pass
7. Verify README renders correctly
8. Check CHANGELOG includes new version entry
9. Verify no `path:` or `git:` dependencies
10. Check package size (< 100 MB gzip, < 256 MB uncompressed)
11. Verify example code works

### Publish Commands

```bash
# Dry run — validate without publishing
dart pub publish --dry-run

# Publish (interactive confirmation)
dart pub publish
```

### Verified Publishers

- **Recommended** for all published packages
- Displays verified domain + badge on pub.dev (instead of personal email)
- Setup: pub.dev → Create Publisher → DNS verification via Google Search Console

### Automated Publishing (GitHub Actions)

1. Enable on pub.dev Admin tab → "Automated publishing" → GitHub Actions
2. Set repository and tag pattern (e.g., `v{{version}}`)
3. Create workflow:

```yaml
# .github/workflows/publish.yml
name: Publish to pub.dev
on:
  push:
    tags:
      - 'v[0-9]+.[0-9]+.[0-9]+'
jobs:
  publish:
    permissions:
      id-token: write  # Required for OIDC
    uses: dart-lang/setup-dart/.github/workflows/publish.yml@v1
```

4. Tag and push to trigger: `git tag v1.2.3 && git push origin v1.2.3`


## Security & Maintenance

- Monitor GitHub Advisory Database for dependency vulnerabilities
- Mark discontinued packages as "discontinued" (don't unpublish)
- Keep dependencies updated — stale deps hurt pub.dev score
- Use `.pubignore` to exclude dev-only files from published package
- Never publish secrets, credentials, or large binary files
- Respond to issues/PRs actively — signals package health


## .pubignore

Exclude files from published package (like `.gitignore` but for `dart pub publish`):

```
# Development files
.github/
.vscode/
.idea/
tool/
benchmark/
doc/
.agent_temp/

# Config
.editorconfig
.fvm/
pubspec_overrides.yaml
```
