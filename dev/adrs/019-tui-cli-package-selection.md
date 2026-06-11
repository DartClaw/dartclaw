# ADR-019: TUI/CLI Package Selection

**Status:** Proposed

## Context

DartClaw's CLI (`dartclaw_cli`) currently depends only on `args` and `logging` for terminal interaction. Three upcoming features require terminal UI capabilities:

1. **`dartclaw setup` wizard** (0.16.2) — interactive prompts, select menus, confirmations, progress spinners
2. **`dartclaw chat` CLI REPL** (0.next-cli-repl) — streaming output, readline history, tool approval prompts
3. **Future TUI dashboard** (speculative) — rich terminal interface with panels, status bars

ADR-018 identified this gap but only mentioned `mason_logger` in passing ("TUI library: mason_logger (593K downloads, AOT-compatible) or thin dart:io stdin layer (~200 LOC)") without systematic evaluation.


## Decision Drivers

- **Supply chain risk** — DartClaw's core principle: fewer dependencies = fewer vulnerabilities. No npm.
- **AOT compatibility** — `dart compile exe` must work. No JIT-only features in production.
- **Immediate need** — 0.16.2 ships a setup wizard; package must cover prompts, select, confirm, progress.
- **Incremental adoption** — don't commit to a 40-package TUI framework for a feature that needs 5 prompt types.
- **No premature lock-in** — the Dart TUI ecosystem is volatile (7 new frameworks in 3 months); D2/D3 decisions should be deferred until REPL work actually starts.

## Decision

### Three-dimension decomposition with phased adoption

The package selection has three independent dimensions. Only D1 is decided now.

**D1 — CLI Interaction (0.16.2): `mason_logger ^0.3.5`**

Add `mason_logger` to `dartclaw_cli/pubspec.yaml` for the setup wizard. It provides: text prompts, password (hidden) input, single-select (`chooseOne`), multi-select (`chooseAny`), confirmations, progress spinners with update/complete/fail, styled output levels, and terminal hyperlinks.

**D2 — Terminal Primitives (deferred): recommend `termlib`, re-evaluate before adoption**

termlib is currently the most feature-complete low-level terminal library in Dart (Kitty keyboard protocol, mouse events, alternate screen, bracketed paste, TermRunner lifecycle management, RGB with auto-downsampling). However, it has 28 downloads, a bus factor of 1, and a 21-month release gap before v0.5.0. The decision should be re-evaluated when REPL work begins — the ecosystem may look different.

Alternatives to consider at re-evaluation: `termio` (zero-dep, Windows-compatible), `dart_console` (widely used but feature-frozen), or nocterm internals (if D3 is adopted, D2 is subsumed).

**D3 — TUI Framework (deferred): recommend `nocterm`, re-evaluate before adoption**

nocterm (v0.6.0, 306 GitHub stars) is the only Dart TUI framework with a proven streaming REPL implementation (vide_cli — 100 stars, 599 commits). It uses a Flutter-like component model with differential cell-buffer rendering. However, it brings 34 transitive packages and adds +2.5 MB to AOT binary size.

Alternatives to consider at re-evaluation: `artisanal` (Elm/BubbleTea architecture, charm.sh port), building from D2 primitives (~300 LOC), or no framework if REPL stays simple.

### Why mason_logger

mason_logger scored **82.9%** in the weighted trade-off analysis — the highest of 5 options evaluated. Key factors:

- **Battle-tested:** 596K downloads, 40+ releases, maintained by Very Good Ventures (Felix Angelov). Used in production by Shorebird CLI, very_good_cli, fvm, Mason CLI.
- **Clean supply chain:** 10 total packages, 7 from dart.dev. Only community packages are mason_logger itself (VGV/brickhub.dev) and win32 (Flutter Favorite, 4.52M downloads).
- **AOT-confirmed:** Ships in AOT binaries for Shorebird, fvm, very_good_cli.
- **Windows-hardened:** Multiple shipped fixes — arrow key navigation (PR #1061), echoMode ordering, win32 compatibility.
- **Zero lock-in:** mason_logger operates in line mode (cooked stdin). Adding a D2/D3 package for the REPL later is purely additive — no rework of wizard code.
- **Established integration pattern:** `Logger`-injection-into-`CommandRunner` is the standard VGV pattern, compatible with DartClaw's existing `args`-based CLI.

**On the naming:** mason_logger is misleadingly named — it's a CLI interaction toolkit (prompts, progress, styled output) that also has logging capabilities. DartClaw continues to use `package:logging` for structured logging. mason_logger is added for its interactive features. This should be documented in STACK.md.

### Why not the alternatives

**Hand-rolled dart:io (~500 LOC):** Scored 62.9%. The "~200 LOC" estimate from ADR-018 was optimistic by 2-3x (realistic: 400-600 LOC for 5 prompt types). Windows raw mode has an unresolved SDK bug (#48329) that breaks arrow keys. You own all platform bugs forever with no community support.

**terminice ecosystem:** Scored 71.2%. The most capable wizard toolkit — 30+ components, `configEditor`, 11 themes, excellent API ergonomics. But all 3 packages are 19 days old with a single maintainer and zero external users. DartClaw's supply chain bar requires more maturity. Reassess in 6+ months.

**mason_logger + termlib (Layered Foundation):** Scored 72.1%. Adding termlib now is premature — it's only needed for the REPL, which is unscheduled. termlib has 28 downloads and a bus factor of 1. Defer.

**mason_logger + nocterm (Full TUI Stack):** Scored 74.0% — higher on extensibility (10/10) but 40 packages total, +2.5 MB binary, and Logger naming conflict. Premature for a wizard that mason_logger handles alone.

## Consequences

### Positive

- **0.16.2 wizard ships with a proven, minimal dependency.** 10 packages (7 dart.dev) added. +0.1 MB binary size.
- **Clean integration with existing `args` CommandRunner.** Established VGV pattern.
- **All REPL options remain open.** mason_logger creates zero architectural lock-in. When REPL ships, add D2/D3 alongside — mason_logger for wizard, new package for REPL.
- **Windows support included.** Multiple platform-specific fixes already shipped by VGV.
- **Testable.** mason_logger's `TerminalOverrides` zone pattern enables unit testing of interactive flows without real stdin.

### Negative

- **Two "logger" packages.** `logging` for structured logs, `mason_logger` for CLI interaction. The naming overlap is confusing. Mitigated by documenting in STACK.md.
- **No REPL primitives.** mason_logger has no raw mode, no cursor positioning, no readline. The REPL will require a separate package. This is by design — don't pay for what you don't use yet.
- **win32 version churn.** Recent revert from v6 to v5 due to native asset hook failures. VGV manages this actively but it's a volatility source.

### Neutral

- **D2/D3 decisions are documented but not binding.** The research and recommendations for termlib and nocterm are preserved privately for when REPL work starts. The ecosystem should be re-surveyed at that point.
- **terminice is not precluded.** If it matures (6+ months, community adoption, no abandonment signals), its `configEditor` component could enhance the wizard in a future pass.

## Implementation Notes

- Add `mason_logger: ^0.3.5` to `apps/dartclaw_cli/pubspec.yaml`
- Update `docs/STACK.md` CLI section: add mason_logger with note distinguishing it from `package:logging`
- Guard interactive prompts with `stdout.hasTerminal` for non-interactive mode support
- Update ADR-018 implementation notes to reference this ADR for the TUI library decision

### Pre-REPL Re-evaluation Checklist

Before starting `0.next-cli-repl`, re-evaluate D2/D3 by checking:

- [ ] nocterm: star count, release cadence, community growth, vide_cli status
- [ ] artisanal: maturity, adoption, whether Elm/BubbleTea model is preferred
- [ ] termlib: Windows support status, adoption growth, release gaps
- [ ] terminice: age (target: 6+ months), community adoption, maintenance signals
- [ ] New entrants not yet published
- [ ] Whether REPL actually needs a framework or can be built from primitives

## References

- [ADR-018: CLI Onboarding Architecture](018-cli-onboarding-architecture.md) — setup wizard design
- 0.16.2 PRD — setup wizard requirements
- CLI REPL requirements were planned for a later CLI milestone.
- [mason_logger on pub.dev](https://pub.dev/packages/mason_logger)
- [nocterm on pub.dev](https://pub.dev/packages/nocterm) · [nocterm.dev](https://nocterm.dev)
- [termlib on pub.dev](https://pub.dev/packages/termlib)
- Research sources are summarized in the linked research appendix.
