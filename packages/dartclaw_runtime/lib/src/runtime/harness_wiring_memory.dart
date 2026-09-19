part of 'harness_wiring.dart';

extension _HarnessWiringMemory on HarnessWiring {
  Future<Map<String, dynamic>> _callScopedHarnessMemory(
    String toolName,
    Map<String, dynamic> arguments,
    HarnessTurnContext context,
  ) async {
    await _refuseTemporaryMemoryWrite(toolName, context.sessionId);
    final memory = await _storage.memoryContextForCaller(
      sessionId: context.sessionId,
      agentId: context.agentName,
      callerKind: context.source == 'cron' ? MemoryCallerKind.scheduled : MemoryCallerKind.ordinary,
    );
    final handlers =
        _workspaceMemoryHandlers[memory.principal] ??
        (throw StateError('Memory workspace is unavailable: ${memory.principal}'));
    final cronAgent = context.source == 'cron' ? context.agentName : null;
    var originKind = MemoryOriginKind.turn;
    var sourceLocator = 'session:${context.sessionId}';
    if (cronAgent?.startsWith('cron:memory-journal') ?? false) {
      originKind = MemoryOriginKind.journal;
      sourceLocator = cronAgent!.substring('cron:'.length);
    } else if (cronAgent?.startsWith('cron:$memoryCurationJobId') ?? false) {
      originKind = MemoryOriginKind.curation;
      sourceLocator = cronAgent!.substring('cron:'.length);
    }
    final capture = MemoryCaptureContext(
      userId: memory.principal,
      originKind: originKind,
      sourceLocator: sourceLocator,
      sourceEvent: 'turn:${context.turnId}',
      caller: context.agentName == 'main' ? toolName : context.agentName,
      sessionRef: context.sessionId,
    );
    return _dispatchMemoryTool(toolName, arguments, handlers, capture, 'Unsupported contextual memory tool: $toolName');
  }

  Future<Map<String, dynamic>> _callScopedMemory(
    String toolName,
    Map<String, dynamic> arguments,
    McpCallerContext caller,
  ) async {
    await _refuseTemporaryMemoryWrite(toolName, caller.sessionId);
    final memory = await _storage.memoryContextForCaller(sessionId: caller.sessionId, agentId: caller.agentId);
    final handlers =
        _workspaceMemoryHandlers[memory.principal] ??
        (throw StateError('Memory workspace is unavailable: ${memory.principal}'));
    final context = MemoryCaptureContext(
      userId: memory.principal,
      originKind: MemoryOriginKind.turn,
      sourceLocator: caller.taskId != null
          ? 'task:${caller.taskId}'
          : caller.sessionId == null
          ? 'authority:${caller.authorityId}'
          : 'session:${caller.sessionId}',
      caller: caller.agentId ?? 'mcp-bridge:$toolName',
      sessionRef: caller.sessionId,
      sourceEvent: caller.sourceEvent,
    );
    return _dispatchMemoryTool(toolName, arguments, handlers, context, 'Unsupported memory tool: $toolName');
  }

  Future<Map<String, dynamic>> _dispatchMemoryTool(
    String toolName,
    Map<String, dynamic> arguments,
    MemoryHandlers handlers,
    MemoryCaptureContext context,
    String unsupportedToolError,
  ) => switch (toolName) {
    'memory_apply' => handlers.apply(arguments, context),
    'memory_observe' => handlers.observe(arguments, context),
    'memory_search' => handlers.search(arguments, context),
    'memory_read' => handlers.read(arguments, context),
    _ => throw StateError(unsupportedToolError),
  };

  /// Wires compaction EventBus callbacks onto a [ClaudeCodeHarness] instance.
  ///
  /// No-op for other harness types — only [ClaudeCodeHarness] exposes the
  /// compaction callback fields.
  void _wireCompactionCallbacks(AgentHarness harness) {
    if (harness is! ClaudeCodeHarness || _memoryHandlers == null) return;
    harness.onCompactionStarting = (sessionId, trigger) async {
      try {
        await _capturePreCompactObservation(sessionId, trigger, harness.activeTurnContext);
      } finally {
        _eventBus.fire(CompactionStartingEvent(sessionId: sessionId, trigger: trigger, timestamp: DateTime.now()));
      }
    };
    harness.onCompactionCompleted = (trigger, preTokens) {
      final sessionId = harness.sessionId ?? '';
      _eventBus.fire(
        CompactionCompletedEvent(
          sessionId: sessionId,
          trigger: trigger,
          preTokens: preTokens,
          timestamp: DateTime.now(),
        ),
      );
    };
  }

  Future<void> _capturePreCompactObservation(String sessionId, String trigger, HarnessTurnContext? turnContext) async {
    final session = await _storage.sessions.getSession(sessionId);
    if (session == null) return;
    final agentName = turnContext?.agentName;
    final memory = await _storage.memoryContextForCaller(
      sessionId: sessionId,
      agentId: agentName,
      callerKind: turnContext?.source == 'cron' ? MemoryCallerKind.scheduled : MemoryCallerKind.ordinary,
    );
    final memoryHandlers = _workspaceMemoryHandlers[memory.principal];
    if (memoryHandlers == null) return;
    final messages = await _storage.messages.getMessagesTail(sessionId, count: HarnessWiring._preCompactMessageCount);
    if (messages.isEmpty) return;
    final triggerLabel = trigger == 'manual' ? 'manual' : 'auto';
    final tail = messages.map((message) => '[${message.role}] ${_messageRedactor.redact(message.content)}').join('\n');
    final text = truncateUtf8Bytes(
      'Pre-compaction conversation context ($triggerLabel):\n$tail',
      HarnessWiring._preCompactObservationMaxBytes,
    );
    await memoryHandlers.observe(
      {'text': text, 'role': 'observation'},
      MemoryCaptureContext(
        userId: memory.principal,
        originKind: MemoryOriginKind.turn,
        sourceLocator: 'session:$sessionId',
        sourceEvent: 'pre-compact:${messages.last.id}',
        caller: agentName == null || agentName == 'main' ? 'claude:PreCompact' : agentName,
        sessionRef: sessionId,
      ),
    );
  }
}
