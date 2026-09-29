part of 'turn_runner.dart';

const _flushPrompt =
    'You are approaching your context limit. Before context compression '
    'occurs, record important information from this conversation with memory_observe '
    "using role='observation'. Focus on:\n"
    '1. Key facts, decisions, or preferences mentioned by the user\n'
    '2. Important context about ongoing tasks\n'
    '3. Any information that would be lost during compression\n\n'
    'Save concisely. Do not ask for confirmation — just save what\'s important.';

const _dailyLogSessionTypes = {SessionType.main, SessionType.user, SessionType.channel};
const _dailyLogToolsTruncated = '[truncated: tool events]';

extension _TurnRunnerMemory on TurnRunner {
  Future<void> _appendDailyLog({
    required String sessionId,
    required String? source,
    required String? userMessage,
    required List<ToolUseEvent> toolEvents,
    required int toolEventCount,
    required String result,
  }) async {
    if (toolEventCount == 0 || toolEvents.isEmpty) return;
    final agentName = _activeTurns[sessionId]?.agentName;

    final now = DateTime.now();

    var title = 'Chat';
    final sessions = _sessions;
    if (sessions == null) return;
    try {
      final session = await sessions.getSession(sessionId);
      if (session == null || !_dailyLogSessionTypes.contains(session.type)) return;
      if (!(_dailyLogEligible?.call(session) ?? true)) return;
      final memFile =
          _memoryFileForSession?.call(session, agentName) ??
          (agentName == null || agentName == 'main' ? _memoryFile : null);
      if (memFile == null) return;
      final t = session.title;
      if (t != null && t.isNotEmpty) title = t;

      await _appendDailyLogRecord(
        memFile: memFile,
        sessionId: sessionId,
        source: source,
        userMessage: userMessage,
        toolEvents: toolEvents,
        toolEventCount: toolEventCount,
        result: result,
        title: title,
        now: now,
      );
    } catch (e) {
      TurnRunner._log.fine('Failed to fetch session title for daily log: $e');
    }
  }

  Future<void> _appendDailyLogRecord({
    required MemoryFileService memFile,
    required String sessionId,
    required String? source,
    required String? userMessage,
    required List<ToolUseEvent> toolEvents,
    required int toolEventCount,
    required String result,
    required String title,
    required DateTime now,
  }) async {
    var loggedUserMessage = userMessage;
    if (source == 'web') {
      try {
        final persisted = await _messages.getMessagesTail(sessionId, count: 2);
        final userMessages = persisted.where((message) => message.role == 'user');
        if (userMessages.isEmpty) {
          TurnRunner._log.fine('Skipping daily log because the persisted Web message is unavailable');
          return;
        }
        loggedUserMessage = userMessages.last.content;
      } catch (e) {
        TurnRunner._log.fine('Failed to fetch persisted user message for daily log: $e');
        return;
      }
    }

    final redactor = _redactor ?? MessageRedactor();
    final seen = <String>{};
    final toolSummaries = <String>[];
    var serializedToolBytes = 2;
    var bytesTruncated = false;
    final maxEvents = TurnToolHookCallbackHandler.maxRetainedToolEvents;
    final eventCount = toolEvents.length < maxEvents ? toolEvents.length : maxEvents;
    for (var i = 0; i < eventCount; i++) {
      final t = toolEvents[i];
      final serialized = DailyLogToolSerializer(redactor).serializeInput(t.input);
      final toolName = dailyLogText(redactor, t.toolName, 1024);
      final key = '$toolName:${serialized.identity}';
      if (seen.add(key)) {
        final summary = '$toolName(${serialized.summary})';
        final encodedBytes = utf8.encode(jsonEncode(summary)).length;
        final separatorBytes = toolSummaries.isEmpty ? 0 : 1;
        final markerBytes = utf8.encode(jsonEncode(dailyLogBytesTruncated)).length + 1;
        if (serializedToolBytes + separatorBytes + encodedBytes + markerBytes > dailyLogMaxSerializedToolBytes) {
          toolSummaries.add(dailyLogBytesTruncated);
          bytesTruncated = true;
          break;
        }
        toolSummaries.add(summary);
        serializedToolBytes += separatorBytes + encodedBytes;
      }
    }
    if (!bytesTruncated && toolEventCount > maxEvents) {
      final separatorBytes = toolSummaries.isEmpty ? 0 : 1;
      final markerBytes = utf8.encode(jsonEncode(_dailyLogToolsTruncated)).length;
      if (serializedToolBytes + separatorBytes + markerBytes <= dailyLogMaxSerializedToolBytes) {
        toolSummaries.add(_dailyLogToolsTruncated);
      } else {
        toolSummaries.add(dailyLogBytesTruncated);
      }
    }

    await memFile.appendDailyLog(
      buildDailyLogRecord(
        at: now,
        redactor: redactor,
        title: title,
        userMessage: loggedUserMessage ?? '(no message)',
        toolSummaries: toolSummaries,
        result: result,
      ),
    );
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
        agentId: TurnRunner._harnessAgentId(agentName),
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
}
