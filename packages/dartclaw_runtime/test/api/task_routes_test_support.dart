import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager;

class CancelTrackingTurns extends TurnManager {
  new()
    : super(
        turnLimits: const TurnLimitsConfig.defaults(),
        messages: ThrowingMessageService(),
        worker: FakeAgentHarness(),
        behavior: BehaviorFileService(workspaceDir: Directory.systemTemp.path),
      );

  final List<String> cancelledSessions = [];

  @override
  Future<void> cancelTurn(String sessionId) async {
    cancelledSessions.add(sessionId);
  }
}

class ThrowingMessageService implements MessageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class MockMergeExecutor extends MergeExecutor {
  new({required this.result}) : super(projectDir: '/mock');

  final MergeResult result;
  int callCount = 0;

  @override
  Future<MergeResult> merge({
    required String branch,
    required String baseRef,
    required String taskId,
    required String taskTitle,
    String? expectedBaseSha,
    MergeStrategy? strategy,
  }) async {
    callCount++;
    return result;
  }
}

class ThrowingMergeExecutor extends MergeExecutor {
  new(this.error) : super(projectDir: '/mock');

  final Object error;

  @override
  Future<MergeResult> merge({
    required String branch,
    required String baseRef,
    required String taskId,
    required String taskTitle,
    String? expectedBaseSha,
    MergeStrategy? strategy,
  }) async {
    throw error;
  }
}
