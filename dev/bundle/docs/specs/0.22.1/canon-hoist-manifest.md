# Canon hoist manifest — 0.22.1

**Created**: 2026-07-25, during plan remediation. **Authority**: `plan.json` shared decisions *Canon-first, and canon closes after P1* and *`--text-sm` retirement protocol*.

The cross-cutting review found five parallel P3/W2 stories each editing `dev/design-system/` and re-syncing the served CSS. That collides by construction: `check_design_system_sync.sh` pins a `sha256:` on line 2 of every served file, so concurrent canon edits conflict on that line, and a mechanically resolved conflict yields a red drift check that reads as a content conflict. It also inverts the release's own first decision — *canon revision before app adoption*.

Resolution: every canon rule a P3 story needs is **hoisted into the P1 story that owns that family**. P3 stories consume; they do not author canon. The sole exception is S07's serialized, deletion-only retirement of the `--text-sm` alias in `tokens.css`; it re-syncs only served `tokens.css`, regenerates embedded assets and closes parity green. It may not edit `components.css`, `icons.css` or any other canon family.

## Scope of the closure — three files, not the directory

The closure covers only the files the drift check actually enforces, verified in `check_design_system_sync.sh`:

| File | Served copy | Drift-checked | Closed after P1 |
|---|---|---|---|
| `tokens.css` | `static/tokens.css` | yes | **yes, except S07's one alias deletion** |
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
| `.shell` / `.content-area` shrinkable-row sizing — `grid-template-rows: var(--topbar-h) minmax(0, 1fr)` plus `min-height: 0` so long pages stay inside `100dvh` | S16 TI01 | **S01** | Shell chrome structure; S16 owns only the app-local `.page-content { min-height: 0; }` half |
| `.skip-link` focus-reveal treatment — visually hidden until keyboard-focused, initially above current chrome with temporary `z-index: 30` | S16 TI02 | **S01 authors; S04 TI01 converts** | Shell chrome and accessibility; S16 owns the `<body>`-first markup and the DESIGN.md contract. S01 proves the temporary literal above current chrome and records the forward handoff; S04 replaces it with `var(--z-overlay)` when the named ladder exists |
| `.msg-user .msg-content p` — canon-owned (`components.css:443`, `:476`); S08's original claim of an `app.css` rule was false | S08 D06 | **S02** | Prose typography; also removes the collision with S12, which works the same message block in the same wave |
| `.section-title` complete heading-tier binding — the canon rule must carry the same size, weight, leading and tracking as `.t-heading`, not leave a post-P1 type-rule request for S07 | S07 TI02 preflight | **S02** | Canon typography; closes the handoff before canon closes |
| `icon-chevron-up` — consumed by `dc_workflows_controller.js:561,576`, genuinely absent from canon `icons.css` | S08 TI05 dry-run | **S02** | Icon inventory; `icons.css` is strict-sync enforced |
| Icon tokens + `[data-icon]` mappings for task-event icons | S08 TI05 | **S02** | Same |
| `.tabs--sticky` material correction | S11 TI04 | **S03** | Tab component family |
| **Tab overflow affordance** — at 768px a ten-tab bar clips, leaving "Security" off-screen behind an overlay scrollbar with no indication more tabs exist. This is the other half of S11 TI04 and is equally a canon `.tabs` change | S11 TI04 | **S03** | Tab component family. **S03 must actually ship this** — S11 now consumes and reports rather than absorbing, so if S03 omits it the audit finding closes nowhere |
| Field-width scale (the audit's `--num` / `--short` suggestion, originally declined by S03) | S11 TI06 | **S03** | Belongs with the Forms section |
| `.card-header-actions` | S15 TI09 | **S03** | Component family |
| Canonical invalid-state hook — `input.form-input[aria-invalid="true"]` / `:user-invalid`; S05 Scenario S03 consumes it today and S03 never ships it | Cross-cutting M5 | **S03** | Forms family; the bespoke app family already has this shape |
| `.status-badge-muted` neutral static treatment — `ChannelStatus.disabled` already emits the class, but canon has no backing rule | S10 TI08 preflight | **S03** | State family; S10 consumes the neutral badge and pairs it with the existing `.status-dot--idle`, without inventing `.status-dot--muted` |
| `.tabs--sticky` stacking handoff — S03 authors temporary `z-index: 10`; S04 counts it among exactly five pre-ladder literals and converts it to `var(--z-sticky)` | Cross-cutting L3 | **S03 authors literal; S04 converts** | The token does not exist during S03. The exact-five pre-S04 gate prevents the handoff from being missed |
| `.dialog .tabs { border-bottom: 0; }` — tab strips inside dialog frames must not double the dialog chrome with the global `.tabs` divider | S05 TI03 preflight | **S04** | Dialog composition belongs to the dialog family. S05 consumes the canonical rule and deletes the app-local `.task-dialog-tabs` border suppression |

## Consequences for the P3 stories

Each affected story drops its canon-edit task and its re-sync step, and instead **consumes** the hoisted rule. S07 retains only the explicit token-retirement exception:

- **S07** — consume S02's completed `.section-title` type binding. Its only drift-checked canon edit is deleting the `--text-sm` alias from `tokens.css`; re-sync only served `tokens.css`, regenerate embedded assets and close parity green.
- **S08** — drop the `icons.css` edit and the `components.css` edits (D03/D06); keep the app-side adoption. Canon footprint returns to zero. Its Execution Contract's S12 coordination note becomes unnecessary.
- **S09** — drop TI01's canon edit; consume S01's `.card-featured-*` fix.
- **S10** — consume S03's neutral `.status-badge-muted` rule for `ChannelStatus.disabled`; keep the independent disabled dot on `.status-dot--idle` and do not defer or add `.status-dot--muted`.
- **S11** — drop TI04/TI06 canon edits; consume S03's `.tabs--sticky` material and field-width scale. Work Areas loses `dev/design-system/`.
- **S12** — drop TI01/TI06 canon edits; consume S01's `hr` reset and `.messages` anchoring.
- **S15** — drop TI09's canon edit; consume S03's `.card-header-actions`.
- **S16** — keep `.page-content { min-height: 0 }`, skip-link markup and DESIGN.md documentation; consume S01's canonical `.shell` / `.content-area` sizing and `.skip-link` treatment.

After the hoist, no P3 story authors a canon rule. S07 alone performs the serialized `tokens.css` alias deletion and served-token sync; the drift-checked canon is otherwise touched only by S01–S04, with S05 verifying the post-P1 boundary and S14 reconciling release close.

## Note on ordering

Hoisting moves work *earlier* in a serial chain, so it cannot deadlock: S01–S04 already run before every consumer. It does grow the P1 stories — check each against the single-session rule after the edits land, and split if any passes the size marker.
