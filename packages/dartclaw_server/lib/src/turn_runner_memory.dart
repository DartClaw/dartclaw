part of 'turn_runner.dart';

const _flushPrompt =
    'You are approaching your context limit. Before context compression '
    'occurs, save any important information from this conversation to MEMORY.md using the '
    'memory_save tool. Focus on:\n'
    '1. Key facts, decisions, or preferences mentioned by the user\n'
    '2. Important context about ongoing tasks\n'
    '3. Any information that would be lost during compression\n\n'
    'Save concisely. Do not ask for confirmation — just save what\'s important.';

extension _TurnRunnerMemory on TurnRunner {
  Future<void> _appendDailyLog({
    required String sessionId,
    required String? userMessage,
    required List<ToolUseEvent> toolEvents,
    required String result,
  }) async {
    final memFile = _memoryFile;
    if (memFile == null || toolEvents.isEmpty) return;

    final now = DateTime.now();
    final time = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    var title = 'Chat';
    final sessions = _sessions;
    if (sessions != null) {
      try {
        final session = await sessions.getSession(sessionId);
        final t = session?.title;
        if (t != null && t.isNotEmpty) title = t;
      } catch (e) {
        TurnRunner._log.fine('Failed to fetch session title for daily log: $e');
      }
    }

    final seen = <String>{};
    final toolSummaries = <String>[];
    for (final t in toolEvents) {
      final key = '${t.toolName}:${t.input.values.firstOrNull ?? ''}';
      if (seen.add(key)) {
        final arg = t.input.values.firstOrNull;
        final argStr = arg != null ? truncate(arg.toString(), 50, suffix: '...') : '';
        toolSummaries.add('${t.toolName}($argStr)');
      }
    }

    final resultSnippet = truncate(result, 100, suffix: '...');
    final entry =
        '## $time — $title\n'
        '**User**: ${userMessage ?? '(no message)'}\n'
        '**Tools**: ${toolSummaries.join(', ')}\n'
        '**Result**: $resultSnippet';

    await memFile.appendDailyLog(entry);
  }

  Future<void> _runFlushTurn(String sessionId) async {
    final messageHash = await _computeFlushHash(sessionId);
    if (_contextMonitor.shouldSkipFlush(messageHash)) {
      TurnRunner._log.info('Pre-compaction flush skipped (dedup) for session $sessionId');
      return;
    }

    _contextMonitor.markFlushStarted();
    try {
      final systemPrompt = await _buildSystemPrompt(sessionId);
      final flushMessage = <String, dynamic>{'role': 'user', 'content': _flushPrompt};
      final agentName = _activeTurns[sessionId]?.agentName;
      await _worker.turn(
        sessionId: sessionId,
        agentId: agentName == null || agentName == 'main' ? null : agentName,
        messages: [flushMessage],
        systemPrompt: systemPrompt,
      );
      _contextMonitor.markFlushed(messageHash);
      TurnRunner._log.info('Pre-compaction flush completed for session $sessionId');
    } finally {
      _contextMonitor.markFlushCompleted();
    }
  }

  Future<String> _computeFlushHash(String sessionId) async {
    try {
      final messages = await _messages.getMessagesTail(sessionId, count: 3);
      final content = messages.map((m) => m.content).join('\n');
      return sha256.convert(utf8.encode(content)).toString();
    } catch (e) {
      TurnRunner._log.warning('Failed to compute flush hash for $sessionId — proceeding with flush', e);
      return '';
    }
  }

  String? _lastToolFileHint(List<ToolUseEvent> toolEvents) {
    if (toolEvents.isEmpty) return null;
    final last = toolEvents.last;
    final name = last.toolName.toLowerCase();
    if (name == 'read' || name == 'view') {
      final path = last.input['file_path'];
      if (path is String) return path;
    }
    if (name == 'bash' || name == 'shell') {
      final cmd = last.input['command'];
      if (cmd is String) {
        final match = RegExp(r'[\w./\-]+\.\w+').firstMatch(cmd);
        if (match != null) return match.group(0);
      }
    }
    return null;
  }
}
