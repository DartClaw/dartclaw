// Compile-time guard: every BridgeEvent subtype must be handled somewhere.
//
// The switch below is exhaustive over the sealed hierarchy, so adding a subtype
// breaks compilation here until it is handled. It replaces the guard that lived
// in the deleted barrel_export_test.dart; no runtime consumer enumerates
// BridgeEvent (the turn runner branches with if/else), so nothing else forces a
// new subtype to be considered.

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

String _describe(BridgeEvent event) => switch (event) {
  DeltaEvent() => 'delta',
  ToolUseEvent() => 'tool_use',
  ToolResultEvent() => 'tool_result',
  ToolApprovalWaitEvent() => 'approval_wait',
  ToolApprovalResolvedEvent() => 'approval_resolved',
  ProviderProgressBridgeEvent() => 'progress',
  SystemInitEvent() => 'init',
  CompactionStartingBridgeEvent() => 'compaction_starting',
  CompactionCompletedBridgeEvent() => 'compaction_completed',
};

void main() {
  test('every BridgeEvent subtype is distinguishable through the sealed hierarchy', () {
    final described = [
      DeltaEvent('hello'),
      ToolUseEvent(toolName: 'bash', toolId: 't1', input: const {}),
      ToolResultEvent(toolId: 't1', output: 'ok', isError: false),
      ToolApprovalWaitEvent(requestId: 'r1', toolName: 'bash'),
      ToolApprovalResolvedEvent(requestId: 'r1'),
      ProviderProgressBridgeEvent(kind: 'agent_thought_chunk', text: 'thinking'),
      SystemInitEvent(contextWindow: 200000),
      CompactionStartingBridgeEvent(),
      CompactionCompletedBridgeEvent(),
    ].map(_describe).toList();

    // A subtype that fell through to another's arm would collide here.
    expect(described.toSet(), hasLength(described.length));
  });
}
