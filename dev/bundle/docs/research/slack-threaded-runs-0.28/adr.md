# ADR-056 amendment handback: Slack package admission

Status: owner-confirmed 0.28 choice, with wording clarified on 2026-09-20; not yet applied to the public repository. Append the following section to `dev/adrs/056-package-topology-consolidation.md`; retain prior sections as history. At implementation, reconcile the status summary to the actual shipped package count.

## Amendment (2026-09-19) – admit the Slack channel boundary for 0.28

The 0.28 Slack integration is admitted as `dartclaw_slack`, beside the three existing channel packages at T2. It owns Slack transport, protocol normalisation, formatting and native interaction rendering. Its only workspace dependencies are `dartclaw_kernel` and `dartclaw_core`. Shared channel contracts remain in core; workflow orchestration and host composition do not move into the channel package.

Raise `_workspacePackageCeiling` from **13 to 14** for this named boundary. With Slack present, `packages/` contains **14 packages** and the root pub workspace contains **16 members**, including the CLI application and `dev/fitness` outside `packages/`. `dartclaw_bridge` remains one of the counted packages. The ceiling equals the admitted shipped count; it reserves no slot for another unreviewed boundary.

The count is an inventory guard, not an architectural size target. Adding an adapter under an established package/tier pattern, already approved in the feature requirements, needs the corresponding inventory and ceiling update rather than a second package-design approval. A new responsibility boundary or dependency-policy exception still requires architectural review. Do not distort package ownership to preserve the count.

`dev/package_tiers.txt` remains the single dependency-direction authority. Add Slack to T2 and the root workspace list; no same-tier channel/workflow edge or upward core/channel edge is permitted. Shared callbacks and capability contracts live below their implementations, with runtime supplying workflow-backed behavior. Record Slack's measured lib LOC and proportional ceiling under the existing governance rule when the implementation lands.

The smallest option satisfying the approved scope is this admission. Folding Slack into core would place a platform adapter below its peers and contradict the required package. Merging all four channels would widen the change to unrelated adapters and aggregate their dependencies without a required consumer benefit. Neither is used to preserve an arbitrary count.

This amendment changes only the admitted inventory and count. The tier order, hook-free bridge, client isolation, runtime/ACP inversion and downward-only dependency rule remain in force. The cost is one additional package in lockstep maintenance and qualification.

Implementation proof includes workspace membership/tier reconciliation, dependency-direction and package-count gates, a measured Slack LOC ceiling, analysis and the channel qualification profile. Admission lands in the plan's first story, before the adapter implementation.

---

## `arch_check.dart` replacement snippet

Replace the existing package-count comment and constant together. This is handback text only:

```dart
// Tracks the approved package inventory (ADR-056), including Slack and bridge.
// Update with approved additions; this guards unrecorded packages, not growth.
const _workspacePackageCeiling = 14;
```

Rationale and alternatives: [F1 weighted trade-off](tradeoff-matrix.md#f1-admit-the-slack-package). No new numbered ADR is needed for this amendment.
