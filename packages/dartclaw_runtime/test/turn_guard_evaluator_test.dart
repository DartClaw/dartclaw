import 'dart:convert';

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

  test('memory provenance comes from the correlated result in exact first-return order', () {
    final handler = createHandler();
    handler.handleToolUse(ToolUseEvent(toolName: 'memory_search', toolId: 'memory', input: {'locator': 'invented'}));
    handler.handleToolUse(ToolUseEvent(toolName: 'read', toolId: 'other', input: const {}));
    final locators = [' first ', 'first', ' first ', for (var i = 0; i < 60; i++) 'source-$i'];
    handler.handleToolResult(
      ToolResultEvent(
        toolId: 'memory',
        isError: false,
        output: jsonEncode({
          'results': [
            for (final locator in locators) {'locator': locator, 'snippet': 'never retained'},
          ],
        }),
      ),
    );
    final record = handler.completedToolCalls.single;
    expect(record.sourceLocators, [' first ', 'first', for (var i = 0; i < 48; i++) 'source-$i']);
    expect(record.success, isTrue);
    expect(record.name, 'memory_search');
    expect(record.toJson().toString(), isNot(contains('never retained')));
    expect(() => record.sourceLocators.add('invented'), throwsUnsupportedError);
    expect(handler.pendingToolCallCount, 1);
    expect(handler.toolCallCount, 2);
    expect(handler.failedToolCallCount, 0);
  });

  final malformed = <Object?>[
    null,
    [],
    {},
    {'results': null},
    {'results': {}},
    {
      'results': [null],
    },
    {
      'results': ['locator'],
    },
    {
      'results': [{}],
    },
    {
      'results': [
        {'locator': 1},
      ],
    },
    {
      'results': [
        {'locator': '  '},
      ],
    },
    {
      'results': [
        {'locator': 'valid'},
        {'locator': null},
      ],
    },
    {
      'results': [
        for (var i = 0; i < 51; i++) {'locator': 'source-$i'},
        {},
      ],
    },
  ];
  for (var i = 0; i < malformed.length; i++) {
    test('malformed result $i cannot retain partial provenance or break accounting', () {
      final handler = createHandler();
      handler.handleToolUse(ToolUseEvent(toolName: 'memory_search', toolId: 'id', input: {'locator': 'invented'}));
      handler.handleToolResult(ToolResultEvent(toolId: 'id', isError: false, output: jsonEncode(malformed[i])));
      expect(handler.completedToolCalls.single.sourceLocators, isEmpty);
      expect(handler.completedToolCalls.single.success, isTrue);
      expect(handler.pendingToolCallCount, 0);
      expect(handler.failedToolCallCount, 0);
    });
  }
  for (final mode in ['invalid JSON', 'error', 'other tool', 'unmatched']) {
    test('$mode is not provenance', () {
      final handler = createHandler();
      handler.handleToolUse(
        ToolUseEvent(toolName: mode == 'other tool' ? 'read' : 'memory_search', toolId: 'id', input: const {}),
      );
      handler.handleToolResult(
        ToolResultEvent(
          toolId: mode == 'unmatched' ? 'unknown' : 'id',
          isError: mode == 'error',
          output: mode == 'invalid JSON'
              ? '{'
              : jsonEncode({
                  'results': [
                    {'locator': 'returned'},
                  ],
                }),
        ),
      );
      if (mode == 'unmatched') {
        expect(handler.completedToolCalls, isEmpty);
        expect(handler.pendingToolCallCount, 1);
      } else {
        expect(handler.completedToolCalls.single.sourceLocators, isEmpty);
        expect(handler.completedToolCalls.single.success, mode != 'error');
        expect(handler.failedToolCallCount, mode == 'error' ? 1 : 0);
      }
    });
  }

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
