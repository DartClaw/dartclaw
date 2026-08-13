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

    if (_worker.promptStrategy == PromptStrategy.append) {
      return effectiveBehavior.composeStaticPrompt(scope: scope, includeOnboarding: turnContext?.isHumanInput ?? false);
    }

    final behaviorPrompt = await effectiveBehavior.composeSystemPrompt(
      scope: scope,
      includeOnboarding: turnContext?.isHumanInput ?? false,
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
    bool resume = false,
  }) async {
    return LogContext.runWith(
      () => _runTurnInner(sessionId: sessionId, turnId: turnId, messages: messages, source: source, resume: resume),
      sessionId: sessionId,
      turnId: turnId,
    );
  }

  Future<void> _runTurnAndSettle({
    required String sessionId,
    required String turnId,
    required List<Map<String, dynamic>> messages,
    String? source,
    bool resume = false,
  }) async {
    Object? settlementError;
    StackTrace? settlementStackTrace;
    try {
      await _runTurn(sessionId: sessionId, turnId: turnId, messages: messages, source: source, resume: resume);
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

  Future<void> _trackSessionUsage(String sessionId, Map<String, dynamic> result, String provider) async {
    final kv = _kv;
    if (kv == null) return;

    final key = 'session_cost:$sessionId';
    final existing = await kv.get(key);
    Map<String, dynamic> costData;
    if (existing != null) {
      costData = jsonDecode(existing) as Map<String, dynamic>;
    } else {
      costData = {
        'input_tokens': 0,
        'output_tokens': 0,
        'cache_read_tokens': 0,
        'cache_write_tokens': 0,
        'total_tokens': 0,
        'effective_tokens': 0,
        'estimated_cost_usd': 0.0,
        'turn_count': 0,
      };
    }

    final inputTokens = result['input_tokens'] as int? ?? 0;
    final outputTokens = result['output_tokens'] as int? ?? 0;
    final cacheReadTokens = (result['cache_read_tokens'] as num?)?.toInt() ?? 0;
    final cacheWriteTokens = (result['cache_write_tokens'] as num?)?.toInt() ?? 0;
    final costUsd = _worker.supportsCostReporting ? (result['total_cost_usd'] as num?)?.toDouble() ?? 0.0 : 0.0;
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
    costData['estimated_cost_usd'] = (costData['estimated_cost_usd'] as num).toDouble() + costUsd;
    costData['turn_count'] = ((costData['turn_count'] as num?)?.toInt() ?? 0) + 1;
    costData['provider'] = existingProvider ?? provider;

    await kv.set(key, jsonEncode(costData));
  }

  Future<void> _applySessionMetadata(String sessionId, Map<String, dynamic> result) async {
    final sessions = _sessions;
    if (sessions == null) return;
    final title = switch (result['session_title']) {
      final String value when value.trim().isNotEmpty => value.trim(),
      _ => null,
    };
    if (title != null) {
      final session = await sessions.getSession(sessionId);
      if (session?.type == SessionType.main) return;
      await sessions.updateTitle(sessionId, title);
    }
  }
}
