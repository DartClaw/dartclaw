# LOC Baseline — 0.25

The milestone's single LOC authority. One measurement, one command, one commit. Every 0.25 size claim — the ceiling
re-baseline and the close-out's net-reduction metric — computes its delta against the figures here and never
re-derives a variant, a narrower filter or a second denominator.

## Base commit

| | |
|---|---|
| Merge base | `a3eccab242920110d337f34c47da1f75e510c7e9` — *Add ADR-057, TD-123 and .gitattributes*, 2026-08-19 |
| Resolved by | `git merge-base feat/0.25-lean-runtime main` |
| Measured on | 2026-08-22, from a detached `git worktree` at that commit with `dart pub get` and `dart run dev/tools/embed_assets.dart` run first |

The story that recorded this named `0ec0e345` ("Release 0.24.2", 2026-08-18) as the merge base. `main` advanced by one
commit before the measurement ran, so the merge base is now `a3eccab2`. The two are identical over both measured
surfaces — `git diff --stat 0ec0e345 a3eccab2 -- 'packages/**/lib/**' 'apps/**/lib/**' 'packages/**/test/**'
'apps/**/test/**'` is empty — so every figure below is the same at either commit.

## The command

Byte-identical to the *Measurement Contract* block in the stories that record and consume this file. Re-run this text,
never a variant.

```sh
# Run from the dartclaw-public repo root. Both surfaces exclude generated Dart (*.g.dart).
# 1. lib LOC
find packages apps -path '*/lib/*' -name '*.dart' -not -name '*.g.dart' -not -path '*/.dart_tool/*' -exec cat {} + | wc -l
# 2. lib file count
find packages apps -path '*/lib/*' -name '*.dart' -not -name '*.g.dart' -not -path '*/.dart_tool/*' | wc -l
# 3. test LOC - ALL *.dart under test/, not only *_test.dart
find packages apps -path '*/test/*' -name '*.dart' -not -name '*.g.dart' -not -path '*/.dart_tool/*' -exec cat {} + | wc -l
# 4. test file count
find packages apps -path '*/test/*' -name '*.dart' -not -name '*.g.dart' -not -path '*/.dart_tool/*' | wc -l
# 5. per-workspace-member lib LOC (S95's ceiling re-baseline input)
for d in packages/*/ apps/*/; do printf '%s\t%s\n' \
  "$(find "$d" -path '*/lib/*' -name '*.dart' -not -name '*.g.dart' -not -path '*/.dart_tool/*' -exec cat {} + | wc -l)" "$d"; done
```

## Measured base

| Surface | LOC | Files |
|---|---:|---:|
| `lib/`, excluding generated | **158,179** | **851** |
| `test/`, all `*.dart` | **236,592** | **837** |

### Per workspace member, `lib/` LOC — at the base commit

The "before" side. The fourteen figures sum to 158,179. The ceiling re-baseline compares against the post-milestone
table below, not this one: six of these member names no longer exist.

| Member | lib LOC |
|---|---:|
| `packages/dartclaw` | 26 |
| `packages/dartclaw_bridge` | 696 |
| `packages/dartclaw_config` | 11,595 |
| `packages/dartclaw_core` | 21,433 |
| `packages/dartclaw_google_chat` | 4,689 |
| `packages/dartclaw_models` | 1,263 |
| `packages/dartclaw_security` | 3,163 |
| `packages/dartclaw_server` | 56,667 |
| `packages/dartclaw_signal` | 1,635 |
| `packages/dartclaw_storage` | 6,125 |
| `packages/dartclaw_testing` | 3,780 |
| `packages/dartclaw_whatsapp` | 1,189 |
| `packages/dartclaw_workflow` | 25,149 |
| `apps/dartclaw_cli` | 20,769 |

These are the member names **at the base commit**, before the milestone's package consolidation. Six of them no longer
exist under those names: `dartclaw_config`, `dartclaw_models` and `dartclaw_security` were formed into
`dartclaw_kernel`, `dartclaw_storage` was absorbed into `dartclaw_core`, and `dartclaw_server` was renamed
`dartclaw_runtime`. A per-member delta is only meaningful against the consolidated groups, not name-for-name; the
repo-wide total is the figure the net-reduction metric uses.

### Per workspace member, `lib/` LOC — post-milestone (2026-08-22)

The "after" side, and the input the per-package ceilings in `dev/tools/arch_check.dart` are set from. Same command,
item 5, re-run at the milestone tip. Recorded here so the ceilings can be checked against a record rather than
against a re-run of the command on a tree that has since moved.

| Member | lib LOC | Ceiling | Band |
|---|---:|---:|---:|
| `packages/dartclaw` | 45 | 60 | 15 |
| `packages/dartclaw_acp` | 2,729 | 2,929 | 400 |
| `packages/dartclaw_bridge` | 696 | 896 | 224 |
| `packages/dartclaw_client` | 469 | 625 | 156 |
| `packages/dartclaw_core` | 25,419 | 25,619 | 400 |
| `packages/dartclaw_google_chat` | 5,546 | 5,746 | 400 |
| `packages/dartclaw_kernel` | 17,762 | 17,962 | 400 |
| `packages/dartclaw_runtime` | 65,840 | 66,040 | 400 |
| `packages/dartclaw_signal` | 1,311 | 1,511 | 377 |
| `packages/dartclaw_testing` | 2,971 | 3,171 | 400 |
| `packages/dartclaw_whatsapp` | 949 | 1,149 | 287 |
| `packages/dartclaw_workflow` | 23,930 | 24,130 | 400 |
| `apps/dartclaw_cli` | 10,652 | 10,852 | 400 |

Thirteen members, not fourteen: `dev/fitness` is a workspace member with no `lib/`, so it carries no ceiling. The
thirteen sum to **158,319** — 140 lines above the 158,179 base, matching the whole-repo figure below. The band is
`min(400, ceiling ~/ 4)`; a ceiling more than its band above actual fails until it is lowered. A raise is exceptional
and follows ADR-033's reviewed-necessity amendment.

### Reviewed C2 runtime rebaseline (2026-08-25)

C2's server-rendered task, workflow, guard-editor, and channel-detail surfaces initially measured 64,206 lines in
`packages/dartclaw_runtime/lib`. Behavior-preserving consolidation removed 381 lines, leaving **63,825**. Further
reduction could not close the remaining 658-line breach without moving decisions into non-Dart files for the counter,
compressing readable code, or taking public-API risks that still fell short. The maintainer accepted the measured
growth and the runtime ceiling moved from **63,167** to **64,225**, `_maxCeilingFor(63,825)` under the unchanged
400-line band. This is a ceiling record, not a replacement for the milestone-wide base or close-out measurement.

### Reviewed C5 Google Chat topology rebaseline (2026-08-26)

Moving the Space Events wiring, subscription routes and OAuth mechanics to their channel owner leaves
`packages/dartclaw_google_chat/lib` at **6,009** lines. The sibling-channel audit's JID-helper move leaves
`packages/dartclaw_runtime/lib` at **63,203**. The old Google
Chat ceiling of 5,746 cannot contain the owned surface without reversing the package boundary or count-driven
compression. The maintainer accepted a Google Chat ceiling of **6,409**, `_maxCeilingFor(6,009)`. Runtime's ceiling
ratchets down in the same cluster from **63,956** to **63,603**, `_maxCeilingFor(63,203)`. Both retain the unchanged
400-line band; this is a topology reallocation, not duplicated or speculative code.

### Whole repo, post-milestone (2026-08-22)

Measured at the commit that recorded this table. Every figure below moves as the remaining stories land; the close-out
re-runs the same command block at its own commit and that run, not this one, is the milestone's result.

| Surface | LOC | Files |
|---|---:|---:|
| `lib/`, excluding generated | 158,319 | 864 |
| `test/`, all `*.dart` | 246,192 | 865 |

Against the base: `lib/` is **140 lines larger** and the test surface is **9,600 lines larger**. Recorded because it is
the number, not because it is the verdict: the net-reduction metric is not satisfied at this point in the branch.

## The generated-file exclusion is load-bearing

`-not -name '*.g.dart'` is not cosmetic. The embedded-asset libraries are generated from the web and workflow asset
trees, are not committed, and are **regenerated by this milestone's web-surface deletions** — so counting them reports
asset-embedding churn as a source-code delta.

| Reading at the base commit | lib LOC |
|---|---:|
| Excluding `*.g.dart` (**the contract**) | 158,179 |
| Including `*.g.dart` | 177,625 |

The 19,446-line gap is `packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart` (18,654) plus
`packages/dartclaw_workflow/lib/src/generated/embedded_assets.g.dart` (792). Both are base64 payloads chunked at 88
characters per line, so their line count tracks total asset bytes and nothing else.

Two further properties of the command form are part of the contract, not style:

- `-exec cat {} + | wc -l` streams every batch into one counter. `... | xargs wc -l | tail -1` silently reports only
  the **last batch's** subtotal once the path list exceeds one `xargs` invocation.
- `-exec ... +` runs nothing on an empty match set, where `xargs cat` on GNU coreutils runs `cat` with no arguments and
  blocks on stdin.

Do not substitute an `rg`-based variant: it inherits `.gitignore` semantics the contract does not assume, which would
drop the generated files by a different rule and hide the exclusion's effect.

**A caveat for anyone reproducing the unexcluded figure**: the generated libraries are gitignored, so a plain checkout
has neither of them and both readings come out at 158,179. Reproducing 177,625 requires `dart run
dev/tools/embed_assets.dart` in the checkout first, as this measurement did.

## Reviewed T1 runtime rebaseline (2026-08-27)

`dartclaw_runtime`'s ceiling was raised **63603 → 64058** — `_maxCeilingFor(63658)`, the measured value plus the
unchanged 400 band. Maintainer-accepted under [ADR-033](../adrs/033-architectural-governance-via-fitness-functions.md)'s
reviewed-necessity exception. Every other ceiling is unchanged, and this milestone raised no other one.

**Why.** The 0.25 tail's container work uncovered two boot defects and the posture corrections that follow from them.
Measured at the close of that work, `packages/dartclaw_runtime/lib` stands at 63658, a net **+58** over the story
commit `b6a3154f`:

| File | Δ | What |
|---|---|---|
| `container/gateway/mcp_bridge_surface.dart` | +23/−11 | resolving the in-container MCP endpoint on first request instead of at bridge attach — what lets a containerized primary agent start at all |
| `api/config_apply_service.dart` | +22/−3 | `PATCH /api/config` validating against the posture in force rather than the one the file declares |
| `runtime/service_wiring.dart` | +22/−18 | `_correctPostureIfDowngraded` and `containerIsolationActive`: the resolved posture as a single authority |
| `runtime/service_wiring_result.dart` | +16/−0 | the `require*` accessors, moved here |
| `runtime/security_wiring.dart` | +4/−1 | an advisory reason that states a fact about the deployment rather than a probe result the zero-server lane never produced |
| four others | +5/−2 | threading the settled posture to its readers |

**Reduction taken before the raise was requested.** Both new doc blocks were trimmed three times, keeping the rationale
and cutting the elaboration. The `require*` accessors moved out of `service_wiring.dart` into its `part` — forced
independently, because that **file** crossed the 1500-line ceiling twice during the work; it now sits at exactly 1500
with `max_file_loc` green. What remains is a defect fix or the reason a defect fix exists. Compressing those into
one-liners to clear a counter is the density gaming this baseline exists to prevent, so it was not done.

**What this is not.** No behaviour was moved out of Dart, no code was hidden in templates, and no generated file was
counted differently. The measurement is the same command block recorded above, run unmodified.

## Close measurement (2026-08-27)

The milestone's result. The command block above, re-run unmodified at `ea678de2` — the last commit touching Dart
before the close-out record was written, so every Markdown-only commit after it leaves these figures unchanged. The
generated libraries were present (`dart run dev/tools/embed_assets.dart` had been run) and excluded by
`-not -name '*.g.dart'`, exactly as at the base.

| Surface | Base `a3eccab2` | Close `ea678de2` | Delta |
|---|---:|---:|---:|
| `lib/` LOC, excluding generated | 158,179 | **156,183** | **−1,996** |
| `lib/` files | 851 | 858 | +7 |
| `test/` LOC, all `*.dart` | 236,592 | **244,112** | **+7,520** |
| `test/` files | 837 | 861 | +24 |
| `apps/dartclaw_cli` lib LOC | 20,769 | **10,491** | **−10,278** |

### Per workspace member, `lib/` LOC — at the close commit

| Member | lib LOC |
|---|---:|
| `packages/dartclaw` | 44 |
| `packages/dartclaw_acp` | 2,718 |
| `packages/dartclaw_bridge` | 696 |
| `packages/dartclaw_client` | 469 |
| `packages/dartclaw_core` | 24,995 |
| `packages/dartclaw_google_chat` | 6,009 |
| `packages/dartclaw_kernel` | 17,805 |
| `packages/dartclaw_runtime` | 63,848 |
| `packages/dartclaw_signal` | 1,347 |
| `packages/dartclaw_testing` | 2,964 |
| `packages/dartclaw_whatsapp` | 888 |
| `packages/dartclaw_workflow` | 23,909 |
| `apps/dartclaw_cli` | 10,491 |

The thirteen sum to 156,183, matching the whole-repo figure. `dev/fitness` is the fourteenth workspace member and has
no `lib/`.

### What the figures say

Metric 1 required `lib/` ≤ 146,179 (158,179 − 12,000) and the test surface ≤ 211,592 (a ≥ 25K reduction). Neither
holds. The lib surface fell by 1,996 lines — 17% of the 12,000 target — and the test surface **grew** by 7,520. The
milestone is **not** re-baselined against a lowered target: every Should story that metric 1 depended on landed, so
there is no descope to re-baseline against, and a target lowered after the fact is the thing this record exists to
prevent. The figure of record is the miss.

Two things the headline delta does not say, both measured rather than argued. The package consolidation moved roughly
70K lines between members without changing the total, so a per-member delta name-for-name is meaningless and only the
repo-wide figure is the metric. And `apps/dartclaw_cli` did fall by half — 20,769 to 10,491 — which is the largest
single reduction the milestone produced and is still 2,491 above metric 5's ≤ 8K bar.

## Reviewed margin rebaseline (2026-09-01)

Owner decision at the 0.25 close-out, after the 0.24.3 merge: `_locHeadroom` in `dev/tools/arch_check.dart` moves
**400 → 1500** and every ceiling is re-cut to `_maxCeilingFor(measured)`. The band rule and the slack failure are
unchanged; only the tolerated slack is wider. Four packages were over their ceiling on the merged tree and the 400
band had needed a reviewed raise every few days of the tail.

| Package | Measured | Old ceiling | New ceiling |
|---|---|---|---|
| dartclaw | 44 | 58 | 58 |
| dartclaw_acp | 2735 | 2929 | 3646 |
| dartclaw_bridge | 696 | 896 | 928 |
| dartclaw_cli | 11219 | 10847 | 12719 |
| dartclaw_client | 469 | 625 | 625 |
| dartclaw_core | 26240 | 25378 | 27740 |
| dartclaw_google_chat | 6009 | 6409 | 7509 |
| dartclaw_kernel | 18420 | 17962 | 19920 |
| dartclaw_runtime | 63856 | 64058 | 65356 |
| dartclaw_signal | 1347 | 1511 | 1796 |
| dartclaw_testing | 2988 | 3171 | 3984 |
| dartclaw_whatsapp | 888 | 1149 | 1184 |
| dartclaw_workflow | 24132 | 24130 | 25632 |

Measured with the command block above on the tree at the 0.24.3 merge plus the close-out fixes (`d05b994e`).

## Superseded readings

Every figure below is recorded here so a reader who meets one elsewhere recognises it as stale, not as a second
authority. None of them is a base for any delta.

| Superseded claim | Where it appears | Why it is not the base |
|---|---|---|
| 154K lib LOC | the milestone PRD's executive summary | An estimate. The measured figure is 158,179. |
| ~226K test surface | the milestone PRD | An observation, not a definition; superseded by the measured 236,592. |
| 225,904 test LOC across 785 files | the `*_test.dart`-only reading | Reproduces exactly at this commit, and is **not** the denominator. The milestone deletes fixtures, helpers and test support, which this filter cannot see, so it would report that work as no reduction at all. The base is all `*.dart` under `test/`. |
| ~100K lib LOC across ~600 files | `dev/architecture/system-architecture.md` | Stale by roughly a third. Correcting that document is the close-out story's, not this record's. |
| 262,679 unexcluded lib LOC; a 103,708-line `embedded_assets.g.dart` | the recording story's own Measurement Contract prose | **Does not reproduce.** At the merge base, with that commit's own generator, the two generated libraries total 19,446 lines and the unexcluded reading is 177,625. The figures above are the measured ones. The trap the number illustrated is real and unchanged — a regenerated 19,446-line artifact against a 158,179-line base is 12% — only its magnitude was overstated. |
