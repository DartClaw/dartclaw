# 0.22.1 – Design-System Refinement & Web UI Polish (point release)

Refinement pass on the canonical design system and the Web UI built on it. 0.22 made the app *compliant* with Afterglow; this makes it *good*. Surface/depth revision, type-scale rationalization + a composite type layer, a wide-container tier, the form/tab/dialog primitives canon never shipped, eradication of native `alert`/`confirm`/`prompt`, a 64-issue glitch sweep, and local vendoring of the three remaining CDN runtime dependencies. The original plan resolved to 16 stories.

**Status**: Implemented; final release validation is pending. [prd.md](prd.md) is the complete and only 0.22.1 scope, delivery, decision, and release-close record. This index intentionally does not duplicate the post-plan delivery history.

> **Why a point release and not part of 0.24 or Cross-Surface UX.** The Cross-Surface UX backlog contains only two items relevant to these defects (QW-10 confirm-modal, OH-10 memory polling) and **no item at all** for type scale, visual hierarchy, surface depth, or density — this is new work with no existing home. 0.24 is already over its 10–14-story budget; adding it would force cutting Phase C. See the Decisions Log in [prd.md](prd.md).

> **Sequencing is load-bearing.** 0.24's Phase-0 conversation/control-plane components (`.composer`, `.tool-call`, `.approval-card`, `.notif-item`, `.palette-item`, `.chip`) already live in canon. FR1/FR2 change them by construction. Running 0.22.1 **before 0.24 planning** avoids reworking shipped chat components; running it after guarantees that rework.

> **Canon-first is mandatory.** 0.22's drift check requires `design-system.css` byte-identical to `dev/design-system/components.css`. Every visual fix in this release starts in `dartclaw-public/dev/design-system/` and is re-synced — app-side edits to canon-owned rules fail CI.

## Contents

```
README.md
prd.md                             ← the point-release PRD
audit-ui-polish-2026-07-25.md      ← the evidence: 232 verified findings across 23 surfaces, by scope/severity/surface
vendoring-analysis.md              ← FR8 decision record: sizes, CSP, embed mechanics, verification gate
```

## The evidence in one paragraph

`.sidebar` (components.css:96), `.topbar` (:283) and `.card` (:783) all use `--bg-mantle`, and the body ground gradient (:55) terminates on that same token — measured card-vs-ground contrast **1.07:1**, below just-noticeable-difference. All card colour is `:hover`-gated, so **0.50–1.45%** of resting content pixels carry any chroma. Three of seven type tiers sit inside a 2px band and absorb ~90% of declarations, while DESIGN.md names 8 tiers the CSS never binds. Canon ships **no** form, tab, or dialog primitives and actively sanctions `window.confirm()`. One 900px container serves prose and data alike — the direct cause of the `PROVID/ER` mid-word table-header wrapping. Full detail in [audit-ui-polish-2026-07-25.md](audit-ui-polish-2026-07-25.md).

## Related

- Complete scope and delivery record: [prd.md](prd.md)
- Original audit evidence: [audit-ui-polish-2026-07-25.md](audit-ui-polish-2026-07-25.md)
- Vendoring decision record: [vendoring-analysis.md](vendoring-analysis.md)
- Canonical design system: [`DESIGN.md`](../../../../design-system/DESIGN.md)
