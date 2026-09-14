part of 'turn_runner.dart';

extension TurnRunnerExecution on TurnRunner {
  /// Whether [turnId] is still tracked as externally completed. Should be false
  /// once `executeTurn` has exited via any path – used to assert no leak.
  @visibleForTesting
  bool tracksExternalCompletion(String turnId) => _externallyCompletedTurns.contains(turnId);

  Future<String> _buildSystemPrompt(String sessionId) async {
    final turnContext = _activeTurns[sessionId];
    final override = turnContext?.systemPromptOverride;
    if (override != null && override.trim().isNotEmpty) {
      return override;
    }

    final effectiveBehavior = turnContext?.behaviorOverride ?? _behavior;
    final scope = turnContext?.promptScope ?? PromptScope.restricted;
    final provenance = await effectiveBehavior.promptProvenance(
      scope: scope,
      includeAppendFile: _worker.promptStrategy == PromptStrategy.append,
    );
    if (turnContext != null) _promptProvenance[turnContext.turnId] = provenance;

    if (_worker.promptStrategy == PromptStrategy.append) {
      return effectiveBehavior.composeStaticPrompt(
        scope: scope,
        includeOnboarding: turnContext?.isHumanInput ?? false,
        origin: turnContext?.origin,
      );
    }

    final behaviorPrompt = await effectiveBehavior.composeSystemPrompt(
      scope: scope,
      includeOnboarding: turnContext?.isHumanInput ?? false,
      origin: turnContext?.origin,
    );

    final agentsContent = await effectiveBehavior.composeAppendPrompt(scope: scope);
    if (agentsContent.isEmpty) return behaviorPrompt;
    return '$behaviorPrompt\n\n$agentsContent';
  }

  Future<void> _runTurn({
    required String sessionId,
    required String turnId,
    required List<Map<String, dynamic>> messages,
    String? source,
  }) async {
    return LogContext.runWith(
      () => _runTurnInner(sessionId: sessionId, turnId: turnId, messages: messages, source: source),
      sessionId: sessionId,
      turnId: turnId,
    );
  }

  Future<void> _runTurnAndSettle({
    required String sessionId,
    required String turnId,
    required List<Map<String, dynamic>> messages,
    String? source,
  }) async {
    Object? settlementError;
    StackTrace? settlementStackTrace;
    try {
      await _runTurn(sessionId: sessionId, turnId: turnId, messages: messages, source: source);
    } catch (error, stackTrace) {
      settlementError = error;
      settlementStackTrace = stackTrace;
    }
    try {
      await _awaitAcceptedCancelRecovery(sessionId);
    } catch (error, stackTrace) {
      settlementError ??= error;
      settlementStackTrace ??= stackTrace;
    }
    if (settlementError != null) _isReusable = false;
    _completeExecutionSettlement(turnId, error: settlementError, stackTrace: settlementStackTrace);
  }

  void _completeExecutionSettlement(String turnId, {Object? error, StackTrace? stackTrace}) {
    _externallyAdmittedTurns.remove(turnId);
    final pending = _executionSettledPending[turnId]?.completer;
    if (pending == null || pending.isCompleted) return;
    if (error == null) {
      pending.complete();
    } else {
      pending.completeError(error, stackTrace);
    }
  }

  Future<void> _trackSessionUsage(String sessionId, String turnId, TurnResult result, String provider) async {
    final kv = _kv;
    final session = await _sessions?.getSession(sessionId);
    if (kv != null && (session?.retention ?? ConversationRetention.durable).isDurable) {
      final key = 'session_cost:$sessionId';
      final existing = await kv.get(key);
      final costData = existing != null
          ? jsonDecode(existing) as Map<String, dynamic>
          : <String, dynamic>{
              'input_tokens': 0,
              'output_tokens': 0,
              'cache_read_tokens': 0,
              'cache_write_tokens': 0,
              'total_tokens': 0,
              'effective_tokens': 0,
              'estimated_cost_usd': null,
              'cost_reported_turn_count': 0,
              'turn_count': 0,
            };
      final inputTokens = result.inputTokens;
      final outputTokens = result.outputTokens;
      final cacheReadTokens = result.cacheReadTokens;
      final cacheWriteTokens = result.cacheWriteTokens;
      final reportedCostUsd = _worker.supportsCostReporting ? result.costUsd : null;
      final existingProvider = switch (costData['provider']) {
        final String value when value.trim().isNotEmpty => value,
        _ => null,
      };
      final effectiveDelta = computeEffectiveTokens(
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cacheReadTokens: cacheReadTokens,
        cacheWriteTokens: cacheWriteTokens,
      );

      costData['input_tokens'] = ((costData['input_tokens'] as num?)?.toInt() ?? 0) + inputTokens;
      costData['output_tokens'] = ((costData['output_tokens'] as num?)?.toInt() ?? 0) + outputTokens;
      costData['cache_read_tokens'] = ((costData['cache_read_tokens'] as num?)?.toInt() ?? 0) + cacheReadTokens;
      costData['cache_write_tokens'] = ((costData['cache_write_tokens'] as num?)?.toInt() ?? 0) + cacheWriteTokens;
      costData['total_tokens'] = ((costData['total_tokens'] as num?)?.toInt() ?? 0) + inputTokens + outputTokens;
      costData['effective_tokens'] = ((costData['effective_tokens'] as num?)?.toInt() ?? 0) + effectiveDelta;
      final accumulatedCostUsd = (costData['estimated_cost_usd'] as num?)?.toDouble();
      costData['estimated_cost_usd'] = reportedCostUsd == null
          ? accumulatedCostUsd
          : (accumulatedCostUsd ?? 0) + reportedCostUsd;
      costData['cost_reported_turn_count'] =
          ((costData['cost_reported_turn_count'] as num?)?.toInt() ?? 0) + (reportedCostUsd == null ? 0 : 1);
      costData['turn_count'] = ((costData['turn_count'] as num?)?.toInt() ?? 0) + 1;
      costData['provider'] = existingProvider ?? provider;
      await kv.set(key, jsonEncode(costData));
    }

    final observeTelemetry = _contextTelemetryObserver;
    if (observeTelemetry == null) return;
    final contextWindow = _turnContextWindows[turnId];
    final provenance = _promptProvenance[turnId];
    await observeTelemetry(
      SessionContextTelemetry(
        sessionId: sessionId,
        source: provider,
        observedAt: DateTime.now().toUtc(),
        availability: contextWindow == null
            ? ContextMeasurementAvailability.unavailable
            : ContextMeasurementAvailability.measured,
        usedTokens: contextWindow == null ? null : result.inputTokens,
        contextWindowTokens: contextWindow,
        behaviorFiles: provenance?.files ?? const [],
        memoryContributed: provenance?.memoryContributed ?? false,
      ),
    );
  }
}
