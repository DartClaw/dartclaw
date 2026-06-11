# ADR-014: SDK Package Decomposition Strategy

**Status:** Accepted
**Date:** 2026-03-09
**Updated:** 2026-03-18 (0.10.1 verification + follow-up hardening)
**Deciders:** DartClaw team
**Supersedes:** None (refines ADR-008 publishing strategy, ADR-010 models split)

## Context

DartClaw is preparing for pub.dev SDK publishing. The current 5-package structure (models, core, storage, server, umbrella) was designed for internal development. Publishing makes package boundaries into **versioned API contracts** — moving a type between packages is a breaking change for every consumer.

`dartclaw_core` currently exports 80+ symbols across 18 subdirectories (security, channels, harness, events, config, container, etc.). All consumers must depend on everything, even if they only need a subset (e.g., guard framework, or harness-only).

Analysis grounded in Ford & Richards' connascence theory and decomposition trade-off framework ("Software Architecture: The Hard Parts") and Farley's testability/reversibility heuristics ("Modern Software Engineering").


### Consumer Profiles Identified

| Consumer | Needs | Doesn't need |
|----------|-------|-------------|
| Custom agent app | Harness, guards, config, events, models | Channels, container mgmt |
| Channel integrator | Channel interface, DM access, models | Guards, harness internals |
| Guard/security plugin | Guard interfaces, verdicts, classifiers | Channels, harness, storage |
| Full-stack embedder | Everything | Server/UI templates |

### Extraction Candidates Evaluated

| Candidate | Verdict | Key reason |
|-----------|---------|------------|
| `dartclaw_security` | Strong candidate, defer | Cleanest independent identity; extract when reused outside DartClaw or requested by consumers |
| `dartclaw_channels` | Viable, defer | Messier boundary — config/session-key algorithm connascence |
| Per-channel packages | Right pattern, premature | Single maintainer; trigger at third channel or external contributor |
| `dartclaw_events` | Don't extract | Shared kernel — extraction creates more dep arrows than it removes |
| `dartclaw_testing` | Extract when consumers exist | Standard Dart pattern; ship with first real SDK release |

## Decision

### 1. Publish 5 packages (current structure + testing)

```
Published:
  dartclaw              # Umbrella re-export
  dartclaw_models       # Zero-dep data types
  dartclaw_core         # Harness + guards + channels + events + config
  dartclaw_storage      # sqlite3 persistence
  dartclaw_testing      # Test doubles (when consumers exist)

Not published:
  dartclaw_server       # HTTP/web UI (publish_to: none)
  dartclaw_cli          # CLI app (publish_to: none)
```

No further package splits now. The current granularity matches the project's reality (single maintainer, no external consumers yet).

### 2. Narrow the `dartclaw_core` barrel export

Use the barrel file as the API boundary (cheaper than package splits, still effective). Demote implementation details to `src/`-only access.

**Keep in barrel (SDK surface, verified in 0.10.1):**
- Models: `Session`, `Message`, `SessionKey`, `Task`, `Goal`, `TaskArtifact`, status/type enums
- Core services: `SessionService`, `MessageService`, `KvService`, `MemoryFileService`
- Harness and security surface: `AgentHarness`, `ClaudeCodeHarness`, `HarnessConfig`, `McpTool`, `ToolResult`, `ToolApprovalPolicy`, `ProcessFactory`, `CommandProbe`, `DelayFactory`, `HealthProbe`, `WorkerState`, `Guard`, `GuardChain`, `GuardVerdict`
- Channel/runtime surface: `Channel`, `ChannelType`, `ChannelManager`, `MentionGating`, `ReviewCommandParser`, `ReviewCommand`, `ChannelReviewResult`, `ChannelReviewHandler`, `TaskTriggerConfig`, `TaskTriggerParser`, `TaskTriggerResult`, `ChannelConfig`, `ChannelConfigProvider`, `DmAccessController`, `TaskOrigin`, `TaskCreator`, `TaskLister`
- Container surface required by harness wiring: `ContainerConfig`, `ContainerManager`, `RunCommand`, `StartCommand`
- Config and events: `DartclawConfig`, `LiveScopeConfig`, `SessionScopeConfig`, `EventBus`, `BridgeEvent`, `DartclawEvent`

**Demote to `src/` (power-user direct import only, completed in 0.10.1):**
- Container internals: `DockerValidator`, `CredentialProxy`, `SecurityProfile`, `resolveProfile`
- Misc operational types: `SessionLifecycleSubscriber`

### 3. Define decomposition trigger points

Do not split further until a concrete driver emerges:

| Trigger | Action |
|---------|--------|
| Third messaging channel | Consider per-channel packages (`dartclaw_whatsapp`, etc.) |
| External contributor maintains a channel | Extract that channel into own package |
| Guard framework reused outside DartClaw | Extract `dartclaw_security` |
| Consumer requests guard-only dep | Extract `dartclaw_security` |
| Barrel grows materially beyond the current 60 exported symbols | Reassess core scope |
| Pre-1.0 review, or a private deployment consumer needs custom config sections | Revisit composed config (R2) |

### 4. Manage config connascence

`DartclawConfig` is the highest-risk coupling point (highest-degree connascence — every subsystem reads it). 0.10.1 broke the config ↔ channel cycle by introducing a neutral `scoping/` module, but it intentionally deferred a full composed-config rewrite. Revisit composed config before the first stable release, or when a private-deployment consumer needs custom config sections.

## Consequences

### Positive

- Minimal maintenance burden — 5 packages (4 published) is manageable for single maintainer
- Barrel narrowing gives SDK consumers a clean, focused API without package proliferation
- Trigger points prevent both premature decomposition and paralysis — clear "when to split" criteria
- Preserves internal development convenience (channels, container mgmt in same package/test suite)
- Power users can still reach internals via `src/` imports (explicit "you're reaching into internals" signal)

### Negative

- Guard-only consumers must still depend on `dartclaw_core` (includes harness, channels in `src/`)
- Barrel narrowing is a breaking change for anyone currently importing demoted symbols via barrel
- Config composition evaluation adds work before stable release

### Neutral

- `dartclaw_testing` deferred until consumer demand — no upfront cost
- Per-channel packages remain a future option — not foreclosed
- Server and CLI remain unpublished — no change from ADR-008

## Alternatives Considered

### A: Extract `dartclaw_security` now

- **Pros**: Cleanest boundary, highest reuse potential, lowest connascence cost
- **Cons**: No concrete consumer demand yet; single maintainer must coordinate 2 more packages
- **Rejected because**: premature — "last responsible moment" principle. Extract when a driver (consumer request, external reuse) materializes

### B: Full 7-package split (models, security, channels, core, storage, testing, umbrella)

- **Pros**: Maximum flexibility for consumers; each package serves one profile
- **Cons**: 7-package version coordination is punishing for single maintainer; config connascence spreads across more boundaries
- **Rejected because**: maintenance cost exceeds flexibility gains at current scale (same conclusion as ADR-008 "full split" alternative)

### C: Keep current barrel unchanged, split later

- **Pros**: Zero work now; no breaking change
- **Cons**: First pub.dev consumers adopt wide barrel → more breakage when eventually narrowed; channel impls become part of de facto public API
- **Rejected because**: narrowing barrel now (before real consumers) is cheaper than narrowing later. "The best time to narrow an API is before anyone depends on the wide one."

## Implementation Notes

1. Narrow `dartclaw_core.dart` barrel — move demoted symbols to `src/`-only, update `dartclaw_server` and `dartclaw_cli` to use `src/` imports for demoted types
2. Verify `dart analyze` clean after barrel changes
3. Run full test suite — no test should break (tests import from `src/` already or via barrel, adjust as needed)
4. Update `dartclaw_core/README.md` to document SDK surface tiers and `src/` import convention
5. Add `dartclaw_testing` package (initially `publish_to: none`) when preparing first real publish

## 0.10.1 Results

`0.10.1` completed the pre-publish hardening work inside `dartclaw_core`, with a follow-up pass on 2026-03-18 to close remaining SDK-surface and documentation gaps.

- The config ↔ channel cycle was removed by introducing `src/scoping/` for `ChannelConfig`, `ChannelConfigProvider`, `LiveScopeConfig`, and `SessionScopeConfig`, and the remaining `channel ↔ scoping` edge was eliminated by moving `ChannelType` to a neutral runtime module. `DartclawConfig` now delegates through `channelConfigProvider` instead of implementing the interface directly.
- `TaskService` and `GoalService` moved from `dartclaw_core` to `dartclaw_server`. `ChannelManager` now depends on `TaskCreator` / `TaskLister` callbacks instead of the concrete service.
- The `dartclaw_core` barrel now exports the full set of types referenced by exported public signatures. Remaining `src/` access is limited to deeper operational internals such as docker validation, credential-proxy plumbing, security-profile resolution, and lifecycle subscribers.

Verified post-0.10.1 internal coupling graph:

```
channel  -> scoping, events, task
config   -> scoping, agents, container, utils
container -> task
events   -> task
harness  -> bridge, container, worker
memory   -> storage
storage  -> events
runtime  -> (no internal deps)
scoping  -> runtime
```

R2 remains deferred: revisit composed config before 1.0, or when a private deployment needs custom config sections.

## References

- [ADR-008: SDK Publishing Strategy](008-sdk-publishing-strategy.md)
- [ADR-010: Package Split (Models)](010-package-split-models.md)
- 0.9 PRD
- Ford, N. & Richards, M. — *Software Architecture: The Hard Parts* (O'Reilly, 2021)
- Farley, D. — *Modern Software Engineering* (Addison-Wesley, 2022)
- Research sources are summarized in the linked research appendix.
