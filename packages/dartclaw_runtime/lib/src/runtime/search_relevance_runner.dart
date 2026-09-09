import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnOutcome, TurnStatus;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import '../turn_manager.dart';

/// Runs schema-bound search relevance judgments through the runtime's normal turn authority.
final class SearchRelevanceRunner {
  /// Creates a runner pinned to the primary provider, model, effort and placement.
  const new({
    required SessionService sessions,
    required TurnManager turns,
    required String providerId,
    String? model,
    String? effort,
    required ExecutionPolicy executionPolicy,
  }) : _sessions = sessions,
       _turns = turns,
       _providerId = providerId,
       _model = model,
       _effort = effort,
       _executionPolicy = executionPolicy;

  static const _agentName = 'search-relevance';

  final SessionService _sessions;
  final TurnManager _turns;
  final String _providerId;
  final String? _model;
  final String? _effort;
  final ExecutionPolicy _executionPolicy;

  /// Requests one bounded turn under a read-only policy and returns its schema-bound relevance map.
  ///
  /// Providers without native structured output must return exactly one JSON object.
  Future<Map<String, dynamic>> run(String prompt, Map<String, dynamic> outputSchema) async {
    final session = await _sessions.createSession(
      type: SessionType.logicalAgent,
      provider: _providerId,
      securityProfile: _executionPolicy.containerProfile,
      executionMode: _executionPolicy.mode,
    );
    String? turnId;
    try {
      turnId = await _turns.reserveTurn(
        session.id,
        agentName: _agentName,
        model: _model,
        effort: _effort,
        workerPolicy: _executionPolicy,
        maxTurns: 4,
        outputSchema: outputSchema,
        outputSchemaWhenSupported: true,
        turnTimeout: const Duration(seconds: 30),
        promptScope: PromptScope.task,
        allowedTools: const [],
        readOnly: true,
      );
      final usesNativeStructuredOutput = _turns.reservedTurnUsesNativeStructuredOutput(session.id, turnId);
      try {
        _turns.executeTurn(
          session.id,
          turnId,
          [
            {'role': 'user', 'content': prompt},
          ],
          source: _agentName,
          agentName: _agentName,
        );
      } catch (_) {
        _turns.releaseTurn(session.id, turnId);
        turnId = null;
        rethrow;
      }

      final outcome = await _turns.waitForOutcome(session.id, turnId);
      if (outcome.status != TurnStatus.completed) {
        throw StateError('Search relevance turn ${outcome.status.name}: ${outcome.errorMessage ?? 'no detail'}');
      }
      if (usesNativeStructuredOutput) {
        return outcome.structuredOutput ??
            (throw StateError('Search relevance turn completed without provider-native structured output'));
      }
      final responseText =
          outcome.responseText ?? (throw StateError('Search relevance turn completed without a response'));
      final decoded = decodeOutputSchemaJson(responseText);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Search relevance output must be a JSON object');
      }
      return decoded;
    } finally {
      final activeTurnId = turnId;
      if (activeTurnId != null && _turns.isActiveTurn(session.id, activeTurnId)) {
        await _turns.cancelTurn(session.id);
      }
    }
  }
}
