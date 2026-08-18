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
const _dailyLogMaxDepth = 16;
const _dailyLogMaxCollectionItems = 512;
const _dailyLogMaxSerializedToolBytes = 64 * 1024;
// Raw text caps reserve worst-case JSON-escaping headroom within the sink's record ceiling.
const _dailyLogMaxRawTitleBytes = 1024;
const _dailyLogMaxRawUserBytes = 48 * 1024;
const _dailyLogMaxRawResultBytes = 16 * 1024;
const _dailyLogDepthTruncated = '[truncated: recursion depth]';
const _dailyLogItemsTruncated = '[truncated: collection items]';
const _dailyLogToolsTruncated = '[truncated: tool events]';
const _dailyLogBytesTruncated = '[truncated: serialized bytes]';

extension _TurnRunnerMemory on TurnRunner {
  Future<void> _appendDailyLog({
    required String sessionId,
    required String? source,
    required String? userMessage,
    required List<ToolUseEvent> toolEvents,
    required int toolEventCount,
    required String result,
  }) async {
    final memFile = _memoryFile;
    if (memFile == null || toolEventCount == 0 || toolEvents.isEmpty) return;

    final now = DateTime.now();
    final time = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    var title = 'Chat';
    final sessions = _sessions;
    if (sessions == null) return;
    try {
      final session = await sessions.getSession(sessionId);
      if (session == null || !_dailyLogSessionTypes.contains(session.type)) return;
      final t = session.title;
      if (t != null && t.isNotEmpty) title = t;
    } catch (e) {
      TurnRunner._log.fine('Failed to fetch session title for daily log: $e');
      return;
    }

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
      final inputSummary = _DailyLogValueSerializer(redactor)
          .serializeInput(t.input)
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ');
      final toolName = _DailyLogValueSerializer(redactor).serializeString(t.toolName, maxBytes: 1024);
      final key = '$toolName:${_DailyLogValueSerializer(redactor).serializeInput(t.input, canonical: true)}';
      if (seen.add(key)) {
        final summary = '$toolName($inputSummary)';
        final encodedBytes = utf8.encode(jsonEncode(summary)).length;
        final separatorBytes = toolSummaries.isEmpty ? 0 : 1;
        final markerBytes = utf8.encode(jsonEncode(_dailyLogBytesTruncated)).length + 1;
        if (serializedToolBytes + separatorBytes + encodedBytes + markerBytes > _dailyLogMaxSerializedToolBytes) {
          toolSummaries.add(_dailyLogBytesTruncated);
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
      if (serializedToolBytes + separatorBytes + markerBytes <= _dailyLogMaxSerializedToolBytes) {
        toolSummaries.add(_dailyLogToolsTruncated);
      } else {
        toolSummaries.add(_dailyLogBytesTruncated);
      }
    }

    final titleSummary = _DailyLogValueSerializer(redactor).serializeString(title, maxBytes: _dailyLogMaxRawTitleBytes);
    final userSummary = _DailyLogValueSerializer(redactor)
        .serializeString(loggedUserMessage ?? '(no message)', maxBytes: _dailyLogMaxRawUserBytes);
    final resultSummary = _DailyLogValueSerializer(redactor)
        .serializeString(result, maxBytes: _dailyLogMaxRawResultBytes)
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    final entry =
        '## $time — ${jsonEncode(titleSummary)}\n'
        '**User**: ${jsonEncode(userSummary)}\n'
        '**Tools**: ${jsonEncode(toolSummaries)}\n'
        '**Result**: ${jsonEncode(resultSummary)}';

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

final class _DailyLogValueSerializer {
  final MessageRedactor _redactor;
  late _DailyLogStringWriter _writer;
  var _items = 0;

  new(this._redactor);

  String serializeInput(Map<String, dynamic> input, {bool canonical = false}) {
    _writer = _DailyLogStringWriter(_dailyLogMaxSerializedToolBytes);
    _writeMap(input, depth: 0, canonical: canonical, includeBraces: canonical);
    return _writer.finish();
  }

  String serializeString(String value, {required int maxBytes}) {
    _writer = _DailyLogStringWriter(maxBytes);
    _writeString(value, canonical: false);
    return _writer.finish();
  }

  void _writeValue(Object? value, {required int depth, required bool canonical, Object? key}) {
    if (_writer.isTruncated) return;
    if (key != null && MessageRedactor.isSecretKey(key)) {
      _writeString('***', canonical: canonical, redact: false);
      return;
    }
    if (value is List) {
      if (depth >= _dailyLogMaxDepth) {
        _writeMarker(_dailyLogDepthTruncated, canonical: canonical);
        return;
      }
      _writeList(value, depth: depth, canonical: canonical);
      return;
    }
    if (value is Map) {
      if (depth >= _dailyLogMaxDepth) {
        _writeMarker(_dailyLogDepthTruncated, canonical: canonical);
        return;
      }
      _writeMap(value, depth: depth, canonical: canonical);
      return;
    }
    if (value is String) {
      _writeString(value, canonical: canonical);
      return;
    }
    final scalar = value?.toString() ?? 'null';
    _writer.write(canonical && value != null && value is! num && value is! bool ? jsonEncode(scalar) : scalar);
  }

  void _writeList(List<dynamic> values, {required int depth, required bool canonical}) {
    _writer.write('[');
    var wroteItem = false;
    for (final value in values) {
      if (!_consumeItem()) {
        if (wroteItem) _writer.write(', ');
        _writeMarker(_dailyLogItemsTruncated, canonical: canonical);
        break;
      }
      if (wroteItem) _writer.write(', ');
      _writeValue(value, depth: depth + 1, canonical: canonical);
      wroteItem = true;
    }
    _writer.write(']');
  }

  void _writeMap(
    Map<dynamic, dynamic> values, {
    required int depth,
    required bool canonical,
    bool includeBraces = true,
  }) {
    if (includeBraces) _writer.write('{');
    final entries = canonical ? _canonicalEntries(values) : values.entries;
    var wroteItem = false;
    var itemsTruncated = false;
    for (final entry in entries) {
      if (!_consumeItem()) {
        itemsTruncated = true;
        break;
      }
      if (wroteItem) _writer.write(', ');
      _writeString(entry.key.toString(), canonical: canonical);
      _writer.write(
        canonical
            ? ':'
            : includeBraces
            ? ': '
            : '=',
      );
      _writeValue(entry.value, depth: depth + 1, canonical: canonical, key: entry.key);
      wroteItem = true;
    }
    if (itemsTruncated || (canonical && entries.length < values.length)) {
      if (wroteItem) _writer.write(', ');
      if (canonical) {
        _writer.write('${jsonEncode(_dailyLogItemsTruncated)}:null');
      } else {
        _writer.write(_dailyLogItemsTruncated);
      }
    }
    if (includeBraces) _writer.write('}');
  }

  List<MapEntry<dynamic, dynamic>> _canonicalEntries(Map<dynamic, dynamic> values) {
    final remaining = _dailyLogMaxCollectionItems - _items;
    final entries = values.entries.take(remaining + 1).toList()
      ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
    return entries;
  }

  bool _consumeItem() {
    if (_items >= _dailyLogMaxCollectionItems) return false;
    _items++;
    return true;
  }

  void _writeString(String value, {required bool canonical, bool redact = true}) {
    final bounded = _utf8Prefix(value, _writer.remainingBytes);
    final safeValue = redact ? _redactor.redact(bounded.text) : bounded.text;
    _writer.write(canonical ? jsonEncode(safeValue) : safeValue);
    if (!bounded.complete) _writer.markTruncated();
  }

  void _writeMarker(String marker, {required bool canonical}) {
    _writer.write(canonical ? jsonEncode(marker) : marker);
  }
}

final class _DailyLogStringWriter {
  final int _maxBytes;
  final _buffer = StringBuffer();
  var _usedBytes = 0;
  var _isTruncated = false;

  new(this._maxBytes);

  int get remainingBytes => _maxBytes - _usedBytes;
  bool get isTruncated => _isTruncated;

  void write(String value) {
    if (_isTruncated || value.isEmpty) return;
    final bounded = _utf8Prefix(value, remainingBytes);
    _buffer.write(bounded.text);
    _usedBytes += bounded.bytes;
    if (!bounded.complete) _isTruncated = true;
  }

  void markTruncated() {
    _isTruncated = true;
  }

  String finish() {
    final value = _buffer.toString();
    if (!_isTruncated) return value;
    final markerBytes = _utf8Prefix(_dailyLogBytesTruncated, _maxBytes).bytes;
    final prefix = _utf8Prefix(value, _maxBytes - markerBytes);
    return '${prefix.text}$_dailyLogBytesTruncated';
  }
}

({String text, int bytes, bool complete}) _utf8Prefix(String value, int maxBytes) {
  if (maxBytes <= 0) return (text: '', bytes: 0, complete: value.isEmpty);
  var bytes = 0;
  var codeUnits = 0;
  for (final rune in value.runes) {
    final runeBytes = rune <= 0x7f
        ? 1
        : rune <= 0x7ff
        ? 2
        : rune <= 0xffff
        ? 3
        : 4;
    if (bytes + runeBytes > maxBytes) break;
    bytes += runeBytes;
    codeUnits += rune > 0xffff ? 2 : 1;
  }
  return (text: value.substring(0, codeUnits), bytes: bytes, complete: codeUnits == value.length);
}
