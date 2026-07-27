# Canon hoist manifest — 0.22.1

**Created**: 2026-07-25, during plan remediation. **Authority**: `plan.json` shared decision *Canon-first, and canon closes after P1*.

The cross-cutting review found five parallel P3/W2 stories each editing `dev/design-system/` and re-syncing the served CSS. That collides by construction: `check_design_system_sync.sh` pins a `sha256:` on line 2 of every served file, so concurrent canon edits conflict on that line, and a mechanically resolved conflict yields a red drift check that reads as a content conflict. It also inverts the release's own first decision — *canon revision before app adoption*.

Resolution: every canon rule a P3 story needs is **hoisted into the P1 story that owns that family**. P3 stories consume; they do not author canon.

## Scope of the closure — three files, not the directory

The closure covers only the files the drift check actually enforces, verified in `check_design_system_sync.sh`:

| File | Served copy | Drift-checked | Closed after P1 |
|---|---|---|---|
| `tokens.css` | `static/tokens.css` | yes | **yes** |
| `components.css` | `static/design-system.css` | yes | **yes** |
| `icons.css` | `static/icons.css` | yes | **yes** |
| `DESIGN.md` | — | no | **no** — prose, never synced |
| `showcase.html` | — | no | **no** — demo, never synced |

The sha256-collision rationale reaches only the three synced files. `DESIGN.md` and `showcase.html` stay writable by any story that establishes a documented contract — S12's drawer and page-header contracts are the motivating case — and S14 reconciles the whole document at release close. A story may therefore document a contract it owns while consuming a rule S01–S04 shipped.

## Hoist table

| Canon change | Discovered by | Hoist to | Why that owner |
|---|---|---|---|
| `.card-featured-*` background grammar — the four base + four `:hover` rules need the `linear-gradient(<fill>,<fill>) padding-box, linear-gradient(135deg,…) border-box` idiom so the gradient border is distinct from the card fill | S09 TI01 | **S01** | Surface/depth family; depends on the card-fill token S01 settles |
| `hr` element reset — sidebar dividers render as the browser-default beveled `<hr>` | S12 TI01 | **S01** | Chrome surface treatment |
| `.messages` bottom-anchoring — thread never bottom-anchors on short conversations | S12 TI06 | **S01** | Named in S01's own audit assetRefs (`chat-session` layout finding) |
| `.data-table thead` band — canon-owned selector (`components.css:1566-1588`) | S08 D03 | **S01** | Surface/colour banding |
| `.msg-user .msg-content p` — canon-owned (`components.css:443`, `:476`); S08's original claim of an `app.css` rule was false | S08 D06 | **S02** | Prose typography; also removes the collision with S12, which works the same message block in the same wave |
| `icon-chevron-up` — consumed by `dc_workflows_controller.js:561,576`, genuinely absent from canon `icons.css` | S08 TI05 dry-run | **S02** | Icon inventory; `icons.css` is strict-sync enforced |
| Icon tokens + `[data-icon]` mappings for task-event icons | S08 TI05 | **S02** | Same |
| `.tabs--sticky` material correction | S11 TI04 | **S03** | Tab component family |
| **Tab overflow affordance** — at 768px a ten-tab bar clips, leaving "Security" off-screen behind an overlay scrollbar with no indication more tabs exist. This is the other half of S11 TI04 and is equally a canon `.tabs` change | S11 TI04 | **S03** | Tab component family. **S03 must actually ship this** — S11 now consumes and reports rather than absorbing, so if S03 omits it the audit finding closes nowhere | 
| Field-width scale (the audit's `--num` / `--short` suggestion, originally declined by S03) | S11 TI06 | **S03** | Belongs with the Forms section |
| `.card-header-actions` | S15 TI09 | **S03** | Component family |
| Canonical invalid-state hook — `input.form-input[aria-invalid="true"]` / `:user-invalid`; S05 Scenario S03 consumes it today and S03 never ships it | Cross-cutting M5 | **S03** | Forms family; the bespoke app family already has this shape |
| `.tabs--sticky` stacking value — must use `var(--z-sticky)`, not a literal, or S04's z-index sweep may miss it | Cross-cutting L3 | **S03 authors, S04 defines the token** | Ordering: S03 references the token S04 ships one wave later; if that is impossible, S04 absorbs the declaration |

## Consequences for the P3 stories

Each affected story drops its canon-edit task and its re-sync step, and instead **consumes** the hoisted rule:

- **S08** — drop the `icons.css` edit and the `components.css` edits (D03/D06); keep the app-side adoption. Canon footprint returns to zero. Its Execution Contract's S12 coordination note becomes unnecessary.
- **S09** — drop TI01's canon edit; consume S01's `.card-featured-*` fix.
- **S11** — drop TI04/TI06 canon edits; consume S03's `.tabs--sticky` material and field-width scale. Work Areas loses `dev/design-system/`.
- **S12** — drop TI01/TI06 canon edits; consume S01's `hr` reset and `.messages` anchoring.
- **S15** — drop TI09's canon edit; consume S03's `.card-header-actions`.

After the hoist, **no P3 story re-syncs anything**, and the drift check is touched only by S01–S04 (serial) and verified by S05 and S14.

## Note on ordering

Hoisting moves work *earlier* in a serial chain, so it cannot deadlock: S01–S04 already run before every consumer. It does grow the P1 stories — check each against the single-session rule after the edits land, and split if any passes the size marker.
