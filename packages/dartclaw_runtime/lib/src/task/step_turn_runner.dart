import 'package:dartclaw_core/dartclaw_core.dart' show TurnOutcome;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import '../turn_runner.dart';

/// Runs one workflow step turn on a leased [TurnRunner].
final class StepTurnRunner {
  static const stepAgentName = 'workflow-step';

  final TurnRunner _runner;

  new(this._runner);

  Future<TurnOutcome> runStepTurn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    String? directory,
    String? model,
    String? effort,
    String? taskId,
    List<String>? allowedTools,
    bool readOnly = false,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    Duration? turnTimeout,
  }) async {
    final providerEnforcedSchema = _runner.harness.supportsStructuredOutput ? outputSchema : null;
    final turnId = await _runner.reserveAdmittedTurn(
      sessionId,
      agentName: stepAgentName,
      directory: directory,
      model: model,
      effort: effort,
      taskId: taskId,
      turnTimeout: turnTimeout,
      allowedTools: allowedTools,
      readOnly: readOnly,
      maxTurns: maxTurns,
      outputSchema: providerEnforcedSchema,
      providerSessionId: providerSessionId,
      requestProviderSessionResume: requestProviderSessionResume,
      promptScope: PromptScope.task,
    );

    try {
      _runner.executeTurn(sessionId, turnId, messages, source: 'task', agentName: stepAgentName);
      return await _runner.waitForOutcome(sessionId, turnId);
    } catch (_) {
      if (_runner.isActiveTurn(sessionId, turnId)) _runner.releaseTurn(sessionId, turnId);
      rethrow;
    }
  }
}
