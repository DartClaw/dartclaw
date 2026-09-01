import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/turn_governance_enforcer.dart';
import 'package:dartclaw_runtime/src/turn_guard_evaluator.dart';
import 'package:test/test.dart';

void main() {
  TurnToolHookCallbackHandler createHandler() => TurnToolHookCallbackHandler(
    sessionId: 'session',
    turnId: 'turn',
    governanceEnforcer: TurnGovernanceEnforcer(
      budgetEnforcer: null,
      globalRateLimiter: null,
      loopDetector: null,
      loopAction: null,
      sseBroadcast: null,
      eventBus: null,
    ),
    buildSnapshot: () => const TurnProgressSnapshot(elapsed: Duration.zero, toolCallCount: 0),
    emitProgressEvent: (_) {},
  );

  test('tool hook handler bounds raw and pending retention while preserving total count and latest event', () {
    final handler = createHandler();

    for (var index = 0; index < 100; index++) {
      handler.handleToolUse(
        ToolUseEvent(toolName: 'read', toolId: 'tool-$index', input: {'file_path': 'file-$index.dart'}),
      );
    }

    expect(handler.toolCallCount, 100);
    expect(handler.toolEvents, hasLength(TurnToolHookCallbackHandler.maxRetainedToolEvents));
    expect(handler.pendingToolCallCount, TurnToolHookCallbackHandler.maxRetainedToolEvents);
    expect(handler.toolEvents.first.toolId, 'tool-0');
    expect(handler.toolEvents[TurnToolHookCallbackHandler.maxRetainedToolEvents - 2].toolId, 'tool-62');
    expect(handler.toolEvents.last.toolId, 'tool-99');
    expect(handler.lastToolEvent?.toolId, 'tool-99');

    handler.finalizePendingToolCalls();
    expect(handler.pendingToolCallCount, 0);
    expect(handler.completedToolCalls, hasLength(TurnToolHookCallbackHandler.maxRetainedToolEvents));
    expect(handler.failedToolCallCount, 100);
  });

  test('tool hook handler bounds completed retention while preserving the latest result', () {
    final handler = createHandler();

    for (var index = 0; index < 100; index++) {
      handler.handleToolUse(ToolUseEvent(toolName: 'read-$index', toolId: 'tool-$index', input: const {}));
      handler.handleToolResult(ToolResultEvent(toolId: 'tool-$index', output: 'ok', isError: index == 64));
    }

    expect(handler.pendingToolCallCount, 0);
    expect(handler.completedToolCalls, hasLength(TurnToolHookCallbackHandler.maxRetainedToolEvents));
    expect(handler.completedToolCalls.first.name, 'read-0');
    expect(handler.completedToolCalls[62].name, 'read-62');
    expect(handler.completedToolCalls.last.name, 'read-99');
    expect(handler.failedToolCallCount, 1);
  });
}
