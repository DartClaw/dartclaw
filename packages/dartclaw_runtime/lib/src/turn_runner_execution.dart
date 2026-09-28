part of 'turn_runner.dart';

extension TurnRunnerExecution on TurnRunner {
  Future<Map<String, dynamic>?> _beginSessionAccounting(String sessionId, String turnId) async {
    final kv = _kv;
    if (kv == null) return null;
    final session = await _sessions?.getSession(sessionId);
    if (!(session?.retention ?? ConversationRetention.durable).isDurable) return null;
    final key = 'session_cost:$sessionId';
    final raw = await kv.get(key);
    final before = raw == null ? <String, dynamic>{} : jsonDecode(raw) as Map<String, dynamic>;
    final pending = <String, dynamic>{...before, 'pending_accounting_turn_id': turnId};
    if (before['pending_accounting_turn_id'] != null) pending['token_usage_complete'] = false;
    try {
      await kv.set(key, jsonEncode(pending));
    } catch (_) {
      throw const AccountingPersistenceException();
    }
    return before;
  }

  TurnResult _normalizeTurnUsage(
    String sessionId,
    TurnResult result,
    Map<String, dynamic>? before, {
    required bool resumed,
  }) {
    final snapshot = result.claudeUsageSnapshot;
    if (snapshot == null) return result;
    final prior = before == null
        ? _processUsageBaselines[sessionId]
        : ClaudeUsageSnapshot.fromJson(before['claude_native_snapshot']);
    final baselineMissing = before != null && before['pending_accounting_turn_id'] != null;
    final noEarlierTurn = before == null ? !_processUsageSeen.contains(sessionId) : before.isEmpty;
    final canStartFresh =
        !resumed &&
        !baselineMissing &&
        (noEarlierTurn || (prior != null && prior.nativeSessionId != snapshot.nativeSessionId));
    final comparable = prior != null && prior.nativeSessionId == snapshot.nativeSessionId && !baselineMissing;
    var complete = canStartFresh || comparable;
    var input = 0;
    var output = 0;
    var cacheRead = 0;
    var cacheWrite = 0;
    double? cost;
    if (complete) {
      for (final entry in snapshot.models.entries) {
        final old = comparable ? prior.models[entry.key] : null;
        if (comparable && old == null) {
          complete = false;
          break;
        }
        final value = entry.value;
        final nextInput = value.input - (old?.input ?? 0);
        final nextOutput = value.output - (old?.output ?? 0);
        final nextRead = value.cacheRead - (old?.cacheRead ?? 0);
        final nextWrite = value.cacheWrite - (old?.cacheWrite ?? 0);
        if (nextInput < 0 || nextOutput < 0 || nextRead < 0 || nextWrite < 0) {
          complete = false;
          break;
        }
        input += nextInput;
        output += nextOutput;
        cacheRead += nextRead;
        cacheWrite += nextWrite;
      }
      if (comparable && prior.models.keys.any((key) => !snapshot.models.containsKey(key))) complete = false;
      final currentCost = snapshot.totalCostUsd;
      final previousCost = comparable ? prior.totalCostUsd : 0.0;
      if (currentCost != null && previousCost != null && currentCost >= previousCost) {
        cost = currentCost - previousCost;
      }
    }
    if (!complete) {
      input = result.inputTokens;
      output = result.outputTokens;
      cacheRead = result.cacheReadTokens;
      cacheWrite = result.cacheWriteTokens;
      cost = null;
    }
    return TurnResult(
      finalText: result.finalText,
      stopReason: result.stopReason,
      error: result.error,
      costUsd: cost,
      sessionTitle: result.sessionTitle,
      providerSessionId: result.providerSessionId,
      structuredOutput: result.structuredOutput,
      inputTokens: input,
      outputTokens: output,
      cacheReadTokens: cacheRead,
      cacheWriteTokens: cacheWrite,
      tokenUsageComplete: complete && _kv != null,
      claudeUsageSnapshot: snapshot,
      mainSessionInputTokens: result.mainSessionInputTokens,
    );
  }

  TurnResult _withTokenCompleteness(TurnResult result, bool complete) => TurnResult(
    finalText: result.finalText,
    stopReason: result.stopReason,
    error: result.error,
    costUsd: result.costUsd,
    sessionTitle: result.sessionTitle,
    providerSessionId: result.providerSessionId,
    structuredOutput: result.structuredOutput,
    inputTokens: result.inputTokens,
    outputTokens: result.outputTokens,
    cacheReadTokens: result.cacheReadTokens,
    cacheWriteTokens: result.cacheWriteTokens,
    tokenUsageComplete: complete,
    claudeUsageSnapshot: result.claudeUsageSnapshot,
    mainSessionInputTokens: result.mainSessionInputTokens,
  );

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

  Future<void> _trackSessionUsage(
    String sessionId,
    String turnId,
    TurnResult result,
    String provider,
    Map<String, dynamic>? before,
  ) async {
    final kv = _kv;
    final session = await _sessions?.getSession(sessionId);
    if (kv != null && (session?.retention ?? ConversationRetention.durable).isDurable) {
      final key = 'session_cost:$sessionId';
      final costData = before == null || before.isEmpty
          ? <String, dynamic>{
              'input_tokens': 0,
              'output_tokens': 0,
              'cache_read_tokens': 0,
              'cache_write_tokens': 0,
              'total_tokens': 0,
              'effective_tokens': 0,
              'estimated_cost_usd': null,
              'cost_reported_turn_count': 0,
              'turn_count': 0,
            }
          : <String, dynamic>{...before};
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
      costData['token_usage_complete'] =
          (before == null || before.isEmpty || before['token_usage_complete'] == true) &&
          before?['pending_accounting_turn_id'] == null &&
          result.tokenUsageComplete;
      costData['last_accounted_turn_id'] = turnId;
      costData.remove('pending_accounting_turn_id');
      if (result.claudeUsageSnapshot case final snapshot?) {
        costData['claude_native_snapshot'] = snapshot.toJson();
      } else if (provider == 'claude') {
        costData.remove('claude_native_snapshot');
      }
      await kv.set(key, jsonEncode(costData));
    } else if (result.claudeUsageSnapshot case final snapshot?) {
      _processUsageSeen.add(sessionId);
      _processUsageBaselines[sessionId] = snapshot;
    } else if (provider == 'claude') {
      _processUsageSeen.add(sessionId);
      _processUsageBaselines.remove(sessionId);
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
        usedTokens: contextWindow == null ? null : (result.mainSessionInputTokens ?? result.inputTokens),
        contextWindowTokens: contextWindow,
        behaviorFiles: provenance?.files ?? const [],
        memoryContributed: provenance?.memoryContributed ?? false,
      ),
    );
  }
}
