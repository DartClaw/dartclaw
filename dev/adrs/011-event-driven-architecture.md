# ADR-011: Lightweight Event Bus for Internal Decoupling

**Status:** Proposed
**Date:** 2026-03-09
**Deciders:** DartClaw team

## Context

DartClaw's internal component communication is predominantly synchronous method calls wired through `DartclawServer.setRuntimeServices()`. This works at the current scale (~1600 tests, single-process server) but creates coupling friction at specific integration points:

1. **Guard blocks** — `GuardChain._evaluate()` calls `auditLogger.logVerdict()` directly. Adding a new consumer (metrics, UI notification, Slack alert) requires modifying guard code.
2. **Config changes** — `config_api_routes.dart` applies side-effects via a `switch` statement that manually calls `heartbeat.start/stop()`, `runtimeConfig.x = y`. Adding a new live-reloadable field requires modifying the API route.
3. **Session lifecycle** — Turn outcomes use 1:1 `Completer`s. No broadcast for session create/end/error events. Multiple consumers (logging, metrics, UI) must be wired independently.
4. **Channel messages** — Messages enter the queue and become opaque. No observable state transitions for monitoring, rate limiting, or notification badges.

The codebase already has event-like patterns (`AgentHarness.events` broadcast stream, `SseBroadcast` for SSE, `LogService` stream subscription) but they are ad-hoc and domain-specific — no unified event bus exists.

### Prior Art: OpenClaw

OpenClaw (Node.js predecessor) evolved through a similar trajectory:
- Started with direct method calls
- Added a **hook system** with ~15 lifecycle event types (`before_tool_call`, `message_received`, `session_start`, etc.)
- Uses a **lane-aware command queue** (global + per-session concurrency)
- Has a proposed **OpenClawBus RFC** for persistent append-only message bus (not yet implemented)

DartClaw can learn from this progression without repeating the growing pains.

### Dart Ecosystem

Evaluated options:
- `event_bus` (pub.dev, 741 likes) — thin wrapper around `StreamController.broadcast()`. ~50 LOC.
- `rxdart` (2,860 likes) — overkill for simple event bus; useful if operators (debounce, throttle) are needed later.
- **Native `dart:async`** — `StreamController.broadcast()` + Dart 3 sealed classes provide type-safe event bus with zero dependencies.

Research is summarized in the linked appendix.

## Decision

Introduce a **lightweight, typed event bus** using native Dart primitives (no external dependencies). Scope is **targeted decoupling** at proven pain points — not a wholesale architectural shift.

### Implementation

```dart
// ~15 lines, zero deps
class EventBus {
  final _controller = StreamController<DartclawEvent>.broadcast();
  Stream<T> on<T extends DartclawEvent>() => _controller.stream.whereType<T>();
  void fire(DartclawEvent event) => _controller.add(event);
  Future<void> dispose() => _controller.close();
}
```

Event hierarchy using Dart 3 sealed classes:

```
sealed class DartclawEvent
├── GuardBlockEvent
├── ConfigChangedEvent
├── SessionLifecycleEvent (sealed)
│   ├── SessionCreatedEvent
│   ├── SessionEndedEvent
│   └── SessionErrorEvent
├── ChannelMessageEvent (sealed)
│   ├── MessageReceivedEvent
│   └── MessageFailedEvent
├── MemoryPrunedEvent
├── ScheduledJobEvent (sealed)
│   ├── JobCompletedEvent
│   └── JobFailedEvent
├── TaskLifecycleEvent (sealed)        ← future: task orchestrator (0.8)
│   ├── TaskStatusChangedEvent
│   └── TaskReviewReadyEvent
└── ContainerLifecycleEvent (sealed)   ← future: per-type containers (ADR-012)
    ├── ContainerStartedEvent
    └── ContainerCrashedEvent
```

### Placement

`EventBus` class and event types in `dartclaw_core` (events are domain concepts, not server-specific). Wired as a singleton in `service_wiring.dart`.

### Migration Strategy

Additive — existing direct calls are preserved until consumers are migrated:

1. Add `fire(GuardBlockEvent(...))` alongside existing `auditLogger.logVerdict()` call
2. Migrate audit logger from direct call to event subscription
3. Add SSE broadcast subscriber for guard events (UI gets real-time notifications)
4. Repeat pattern for config changes, session lifecycle

Each step is independently shippable and testable.

## Alternatives Considered

### A. Full event-sourcing / CQRS

Rejected. Massive over-engineering for a single-process server. No persistence or replay requirements. Dart has no production event-sourcing framework.

### B. External package (`event_bus`, `rxdart`)

Rejected. `event_bus` is ~50 LOC and adds no value over native streams. `rxdart` is overkill. Zero-dep solution is preferred for a library/SDK project.

### C. OpenClaw-style hook/plugin system

Deferred. Hooks are a superset of events — they allow *blocking* interception (before/after with cancellation). DartClaw's guard system already provides blocking semantics for security. A general plugin hook system may be warranted later but is beyond current scope.

### D. Do nothing

Viable today. The coupling pain points are manageable. Risk: as feature count grows (0.7+), the `switch` statement in config_api_routes and the manual wiring in `setRuntimeServices()` will accumulate more cases. The event bus is low-cost insurance against that growth.

## Consequences

**Positive:**
- Decouples producers from consumers — adding a new consumer requires zero changes to the producer
- Sealed class exhaustiveness means the compiler catches missing handlers when new event types are added
- Existing `AgentHarness.events` pattern validates that broadcast streams work well in DartClaw
- Zero external dependencies
- Testable — fire events in tests, assert subscribers react correctly

**Negative:**
- Indirection — "who handles this event?" requires searching for `on<EventType>()` calls (mitigated by sealed class and small subscriber count)
- Broadcast streams don't buffer — events lost if no listener (by design: events are notifications, state is queried separately)
- Risk of over-adoption — must resist adding events for everything; only add when there's a real coupling pain point

**Neutral:**
- No performance impact — `StreamController.add()` is microtask-level overhead in Dart's single-threaded model
- Does not replace existing patterns (SSE broadcast, harness stream, log stream) — coexists alongside them
