part of 'workflow_one_shot_runner.dart';

extension _WorkflowOneShotRunnerHelpers on WorkflowOneShotRunner {
  Future<void> _trackWorkflowSessionUsage(
    String sessionId, {
    required String provider,
    required ({int inputTokens, int newInputTokens, int outputTokens, int cacheReadTokens, int cacheWriteTokens}) usage,
    required double? totalCostUsd,
  }) async {
    final kv = _kv;
    if (kv == null) return;
    final key = 'session_cost:$sessionId';
    final existing = await kv.get(key);
    final costData = existing != null ? jsonDecode(existing) as Map<String, dynamic> : _emptySessionCost(provider);
    if (costData.containsKey(WorkflowOneShotRunner._legacySessionCostFreshInputKey)) {
      costData
        ..clear()
        ..addAll(_emptySessionCost(provider));
    }
    final freshInputTokens = usage.newInputTokens;
    final effectiveDelta = computeEffectiveTokens(
      inputTokens: freshInputTokens,
      outputTokens: usage.outputTokens,
      cacheReadTokens: usage.cacheReadTokens,
      cacheWriteTokens: usage.cacheWriteTokens,
    );
    costData['input_tokens'] = ((costData['input_tokens'] as num?)?.toInt() ?? 0) + freshInputTokens;
    costData['output_tokens'] = ((costData['output_tokens'] as num?)?.toInt() ?? 0) + usage.outputTokens;
    costData['cache_read_tokens'] = ((costData['cache_read_tokens'] as num?)?.toInt() ?? 0) + usage.cacheReadTokens;
    costData['cache_write_tokens'] = ((costData['cache_write_tokens'] as num?)?.toInt() ?? 0) + usage.cacheWriteTokens;
    costData['total_tokens'] =
        ((costData['total_tokens'] as num?)?.toInt() ?? 0) + freshInputTokens + usage.outputTokens;
    costData['effective_tokens'] = ((costData['effective_tokens'] as num?)?.toInt() ?? 0) + effectiveDelta;
    costData['estimated_cost_usd'] =
        ((costData['estimated_cost_usd'] as num?)?.toDouble() ?? 0.0) + (totalCostUsd ?? 0.0);
    costData['turn_count'] = ((costData['turn_count'] as num?)?.toInt() ?? 0) + 1;
    costData['provider'] = costData['provider'] ?? provider;
    await kv.set(key, jsonEncode(costData));
  }

  Future<Map<String, dynamic>?> _tryExtractInlineStructuredPayload(
    String sessionId,
    Map<String, dynamic> structuredSchema,
  ) async {
    final messages = await _messages.getMessagesTail(sessionId, count: 50);
    final assistantMessages = messages.where((message) => message.role == 'assistant').toList(growable: false);
    if (assistantMessages.isEmpty) return null;
    final extracted = WorkflowTurnExtractor(
      log: _log,
    ).parse(assistantMessages.last.content, requiredKeys: WorkflowTurnExtractor.requiredTopLevelKeys(structuredSchema));
    return extracted.inlinePayload.isEmpty ? null : Map<String, dynamic>.from(extracted.inlinePayload);
  }

  Future<_SessionUsageSnapshot> _readSessionUsageSnapshot(String sessionId) async {
    try {
      final raw = await _kv?.get('session_cost:$sessionId');
      if (raw == null) return const _SessionUsageSnapshot();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return _SessionUsageSnapshot(
        inputTokens: (json['input_tokens'] as num?)?.toInt() ?? 0,
        outputTokens: (json['output_tokens'] as num?)?.toInt() ?? 0,
        cacheReadTokens: (json['cache_read_tokens'] as num?)?.toInt() ?? 0,
        cacheWriteTokens: (json['cache_write_tokens'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return const _SessionUsageSnapshot();
    }
  }

  Future<Task> _writeWorkflowTokenBreakdownToTaskConfig(
    Task task, {
    required int inputTokens,
    required int cacheReadTokens,
    required int outputTokens,
  }) async {
    final current = await _tasks.get(task.id);
    if (current == null || current.status.terminal) return current ?? task;
    final patch = WorkflowTaskConfig.taskConfigTokenBreakdownPatch(
      inputTokensNew: cacheReadTokens > inputTokens ? 0 : inputTokens - cacheReadTokens,
      cacheReadTokens: cacheReadTokens,
      outputTokens: outputTokens,
    );
    return _tasks.mergeConfigJson(current.id, patch);
  }

  Map<String, dynamic> _emptySessionCost(String provider) {
    return <String, dynamic>{
      'input_tokens': 0,
      'output_tokens': 0,
      'cache_read_tokens': 0,
      'cache_write_tokens': 0,
      'total_tokens': 0,
      'effective_tokens': 0,
      'estimated_cost_usd': 0.0,
      'turn_count': 0,
      'provider': provider,
    };
  }
}

final class _SessionUsageSnapshot {
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

  const _SessionUsageSnapshot({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
  });
}
