# 0.22 — Afterglow Design-System Overhaul (one milestone)

Full adoption of the updated **"Afterglow"** design system across the Web UI, plus fixing the app's drifted CSS copies (verbatim synced `design-system.css` + `app.css` with a drift check). Brand mascot, claw loader, glass tier, meters, skeletons, identicons, terminal frames, ambient ground, extended palette + chart ramp. ~18 stories across 3 phases (foundation → per-page adoption → brand moments).

**Status**: **scheduled as 0.22** (2026-07-06); **first** of the UX/app-track milestones — ships first because visual quality multiplies every later UI item, and the 0.19/0.24/Cross-Surface-UX UI work must be built on the new system, not migrated after. Sequencing decision 2026-06-10; numbering 2026-07-06. **PRD written** ([prd.md](prd.md)); **next step: the implementation plan** (`/andthen:plan` on this dir) — clean session recommended.

> Sizing note: ~18 stories is at the upper edge of the 10–14 target; phase 3 (brand moments) may split into a follow-up wave.
> Prerequisite for implementation: the Afterglow **base** is already canonical in `dartclaw-public/dev/design-system/` (since 0.18). The **Phase-0 conversation/control-plane/orchestration extension components** (`tool-call`, `approval-card`, `composer`, `run-card`, `pipeline`, `notif-item`, palette rows — consumed by 0.23 Chat & Workflow Studio) are committed but **unmerged**: branch `feat/design-system-afterglow-extension` in the public repo (1 commit off `main`, design-system files only). Merge that branch into mainline canon before/as part of this milestone — the drift-checked sync ships canon → app, so the extension must be in canon for the app to receive it.

## Contents

```
README.md
prd.md                              ← the milestone PRD
audit-design-system-compliance.md   ← the evidence: CSS drift, adoption map, violations, 18-story breakdown
```

## Related

- Strategy + version mapping: [cross-surface UX plan](../../../../../../dartclaw-private/docs/specs/0.next-ui-ux-improvements/cross-surface-ux-plan-2026-06.md) (DS-0 + §3a Afterglow component bindings)
- The canonical design system being adopted: `../../../../design-system/DESIGN.md`
- Sibling milestone: [Cross-Surface UX (`0.next-ui-ux-improvements`)](../../../../../../dartclaw-private/docs/specs/0.next-ui-ux-improvements/) — Cross-Surface UX (ships after this)
