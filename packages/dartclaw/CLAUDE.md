# Package Rules — `dartclaw`

**Role**: Published umbrella facade — re-exports `dartclaw_core`, `dartclaw_storage`, and the three channel packages (`dartclaw_whatsapp`, `dartclaw_signal`, `dartclaw_google_chat`). The barrel is `lib/dartclaw.dart`. There is no `lib/src/` — this package owns no implementation code.

## Boundaries
- Do not add code under `lib/src/`. New runtime types belong in `dartclaw_core` (or `dartclaw_storage` if SQLite-bound). New shared DTOs belong in `dartclaw_models`. New config types belong in `dartclaw_config`.
- `dartclaw_models`, `dartclaw_security`, and `dartclaw_config` are reachable transitively through `dartclaw_core`. Do not add them as direct dependencies in `pubspec.yaml` — `dartclaw_config` is `dev_dependencies` only (used by the umbrella export test).
- Do not add new top-level `export` lines without checking what is already transitively re-exported by `dartclaw_core`. Duplicate re-exports cause symbol collisions for downstream consumers.

## Conventions
- When adding a new sub-package or changing what `dartclaw_core` re-exports, update `test/umbrella_exports_test.dart` — the only test in this package, and the contract that downstream `import 'package:dartclaw/dartclaw.dart';` users rely on.
- Keep the dartdoc on `library;` aligned with the README's "Core Abstractions" list — both are user-facing surface.

## Gotchas
- `version:` here is the project-wide version (`dartclawVersion`) — bumping it is part of release prep, not a per-package decision. See `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md`.
- `publish_to: none` today; this still ships to pub.dev later, so do not import private/server-only types into the export graph.

## Key files
- `lib/dartclaw.dart` — the only source file; barrel of barrels.
- `test/umbrella_exports_test.dart` — symbol-presence contract.
- `pubspec.yaml` — sub-package set; canonical version anchor.
- `README.md` — public-facing intro (kept in sync with re-export surface).
