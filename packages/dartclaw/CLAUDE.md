# Package Rules — `dartclaw`

**Role**: Umbrella facade for the **client tier** — re-exports `dartclaw_client` and the explicit DTO subset of `dartclaw_kernel`. The barrel is `lib/dartclaw.dart`. There is no `lib/src/` — this package owns no implementation code.

## Boundaries
- The umbrella carries the client tier only. Do not add `dartclaw_core`, `dartclaw_runtime`, `dartclaw_workflow`, `dartclaw_bridge` or a channel package to production `dependencies:` or the barrel — embedding the runtime is the fork-the-runtime tier, documented in `docs/sdk/packages.md`. A `dev_dependencies:` edge is allowed only for a cross-tier contract test whose governing spec requires this package as the host; the tier order in `dev/package_tiers.txt` places this package beside the channel packages and above the client tier, so a runtime edge (upward) and a channel edge (same tier) both fail the direction gate with no allowlist entry that could excuse them. A `dartclaw_core` edge is *downward* and the tier order permits it — `test/umbrella_exports_test.dart` is what forbids that one, and it is the reason that test exists.
- Do not add code under `lib/src/`. New client-tier code belongs in `dartclaw_client`; new shared DTOs in `dartclaw_kernel`.
- Keep the kernel export's `show` list equal to the client DTO surface. Config, guard, and utility symbols stay out of the umbrella even though they share the kernel package.

## Conventions
- When either re-exported barrel changes its surface, update `test/umbrella_exports_test.dart` — the contract that downstream `import 'package:dartclaw/dartclaw.dart';` users rely on. Its third case is the negative half: it asserts no runtime package entered production dependencies or the barrel.
- `test/config_advisory_baseline_test.dart` is the cross-tier exception: it dev-depends on `dartclaw_runtime` to exercise the canonical config-load seam and byte-locks the resulting advisories in `test/goldens/config_advisory_baseline.txt`.
- Keep the dartdoc on `library;` aligned with the README's "Client-Tier Abstractions" list — both are user-facing surface.

## Gotchas
- `version:` here is the project-wide version (`dartclawVersion`) — bumping it is part of release prep, not a per-package decision. See `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md`.
- `publish_to: none` today; this and `dartclaw_client` are the intended first publishable set (ADR-008), so do not import private/server-only types into the export graph.

## Key files
- `lib/dartclaw.dart` — the only source file; barrel of barrels.
- `test/umbrella_exports_test.dart` — symbol-presence contract plus the runtime-absence assertion.
- `test/config_advisory_baseline_test.dart` — registry-derived config advisory fidelity gate; its header owns regeneration.
- `test/goldens/config_advisory_baseline.txt` — committed byte-exact advisory baseline.
- `example/example.dart` — the client-tier example: connect, call an endpoint, follow an SSE stream.
- `pubspec.yaml` — sub-package set; canonical version anchor.
- `README.md` — public-facing intro (kept in sync with re-export surface).
