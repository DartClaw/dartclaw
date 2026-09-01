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
      final serialized = _DailyLogSerializer(redactor).serializeInput(t.input);
      final toolName = _dailyLogText(redactor, t.toolName, 1024);
      final key = '$toolName:${serialized.identity}';
      if (seen.add(key)) {
        final summary = '$toolName(${serialized.summary})';
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

    final titleSummary = _dailyLogText(redactor, title, _dailyLogMaxRawTitleBytes);
    final userSummary = _dailyLogText(redactor, loggedUserMessage ?? '(no message)', _dailyLogMaxRawUserBytes);
    final resultSummary = _dailyLogText(
      redactor,
      result,
      _dailyLogMaxRawResultBytes,
    ).trim().replaceAll(RegExp(r'\s+'), ' ');
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

/// The summary is written through a running byte budget rather than encoded
/// whole and then cut back, so peak memory stays at
/// [_dailyLogMaxSerializedToolBytes] however wide the input is.
///
/// Identity is fed the raw value stream ahead of that budget and of redaction:
/// two calls sharing a large leading value summarise identically, and deriving
/// identity from the summary would silently drop the second from the log. Depth,
/// breadth and secret redaction do reach identity — past those the two calls
/// have nothing left to tell apart.
final class _DailyLogSerializer {
  final MessageRedactor _redactor;
  final _identity = _DailyLogIdentity();
  final _summary = StringBuffer();
  var _items = 0;
  var _usedBytes = 0;
  var _exhausted = false;
  var _truncated = false;

  new(this._redactor);

  ({String summary, String identity}) serializeInput(Map<String, dynamic> input) {
    _writeValue(input, depth: 0);
    return (
      summary: _dailyLogBounded(_summary.toString(), _dailyLogMaxSerializedToolBytes, truncated: _truncated),
      identity: _identity.finish(),
    );
  }

  void _writeValue(Object? value, {required int depth, Object? key}) {
    if (key != null && MessageRedactor.isSecretKey(key)) {
      _identity.tag('*');
      _write('"***"');
      return;
    }
    if (value is List) {
      if (depth >= _dailyLogMaxDepth) return _writeMarker(_dailyLogDepthTruncated);
      _identity.tag('[');
      _write('[');
      var wrote = false;
      for (final item in value) {
        if (!_consumeItem()) {
          if (wrote) _write(',');
          _writeMarker(_dailyLogItemsTruncated);
          break;
        }
        if (wrote) _write(',');
        _writeValue(item, depth: depth + 1);
        wrote = true;
      }
      _identity.tag(']');
      _write(']');
      return;
    }
    if (value is Map) {
      if (depth >= _dailyLogMaxDepth) return _writeMarker(_dailyLogDepthTruncated);
      _identity.tag('{');
      _write('{');
      var wrote = false;
      for (final entry in value.entries) {
        if (!_consumeItem()) {
          if (wrote) _write(',');
          _writeMarker(_dailyLogItemsTruncated);
          _write(':null');
          break;
        }
        if (wrote) _write(',');
        _writeString('${entry.key}');
        _write(':');
        _writeValue(entry.value, depth: depth + 1, key: entry.key);
        wrote = true;
      }
      _identity.tag('}');
      _write('}');
      return;
    }
    if (value is String) return _writeString(value);
    // jsonEncode throws on a non-finite double, and the caller swallows that, so
    // one such value would cost the whole entry.
    if (value is num && value.isFinite) {
      _identity.tag('n$value;');
      _write('$value');
      return;
    }
    if (value is bool || value == null) {
      _identity.tag(value == null ? 'z;' : 'b$value;');
      _write('$value');
      return;
    }
    _writeString(value.toString());
  }

  void _writeString(String value) {
    _identity.string(value);
    if (_exhausted) return;
    final bounded = _utf8Prefix(value, _dailyLogMaxSerializedToolBytes - _usedBytes);
    // Redaction always sees the value's own cap, never the smaller budget
    // remainder: that remainder lands wherever the entries before it ended, and
    // a secret split by it stops matching its pattern. Only what fits the
    // remainder is written, so the extra text redacted here never reaches the
    // entry.
    final redacted = _redactor.redact(
      bounded.complete ? bounded.text : _utf8Prefix(value, _dailyLogMaxSerializedToolBytes).text,
    );
    _write(jsonEncode(redacted));
    // The cut must outlive the value that took it: redaction can shrink an
    // over-cap string back under the budget, and the summary would then read as
    // complete and lose its truncation marker.
    if (!bounded.complete) _truncated = true;
  }

  void _writeMarker(String marker) {
    _identity.tag('!');
    _identity.string(marker);
    _write(jsonEncode(marker));
    _truncated = true;
  }

  /// The budget counts what is written, not what is read, so a value redaction
  /// shrinks cannot starve the entries after it. Exhausting it stops the summary
  /// but not the walk, which keeps feeding identity.
  void _write(String value) {
    if (_exhausted) return;
    final bounded = _utf8Prefix(value, _dailyLogMaxSerializedToolBytes - _usedBytes);
    _summary.write(bounded.text);
    _usedBytes += bounded.bytes;
    if (!bounded.complete) {
      _exhausted = true;
      _truncated = true;
    }
  }

  bool _consumeItem() {
    if (_items >= _dailyLogMaxCollectionItems) return false;
    _items++;
    return true;
  }
}

/// Values are type-tagged and strings length-prefixed — labels are ASCII, since
/// [tag] feeds code units as bytes — so no two distinct inputs feed the same
/// bytes. Strings go in raw: unredacted, uncut, and chunked so no encoded copy
/// of the input is ever held, because what the summary can afford to show must
/// not decide what the dedup key can tell apart.
final class _DailyLogIdentity {
  static const _chunkCodeUnits = 4096;

  late final Digest _result;
  late final ByteConversionSink _sink = sha256.startChunkedConversion(
    ChunkedConversionSink<Digest>.withCallback((digests) => _result = digests.single),
  );

  void tag(String label) => _sink.add(label.codeUnits);

  void string(String value) {
    tag('s${value.length}:');
    for (var start = 0; start < value.length; start += _chunkCodeUnits) {
      final end = start + _chunkCodeUnits < value.length ? start + _chunkCodeUnits : value.length;
      final bytes = List<int>.filled((end - start) * 2, 0);
      for (var i = start; i < end; i++) {
        final unit = value.codeUnitAt(i);
        bytes[(i - start) * 2] = unit >> 8;
        bytes[(i - start) * 2 + 1] = unit & 0xff;
      }
      _sink.add(bytes);
    }
  }

  /// Closes the stream: no value may be fed after this.
  String finish() {
    _sink.close();
    return '$_result';
  }
}

/// [value] redacted and bounded to [maxBytes].
///
/// The cut runs before redaction to bound the regex work on an unbounded value,
/// and again after because redaction can lengthen text (`[REDACTED]` is longer
/// than a short match) and because only the second pass carries the truncation
/// marker. Cutting first is not what keeps an over-cap secret safe — a PEM block
/// survives it only because the redactor carries an unterminated-block pattern,
/// and a pattern needing a complete shape can still leave a partial match.
String _dailyLogText(MessageRedactor redactor, String value, int maxBytes) {
  final bounded = _utf8Prefix(value, maxBytes);
  return _dailyLogBounded(redactor.redact(bounded.text), maxBytes, truncated: !bounded.complete);
}

/// [value] cut to [maxBytes], carrying the truncation marker when anything was
/// dropped here or by [truncated] upstream.
String _dailyLogBounded(String value, int maxBytes, {bool truncated = false}) {
  final fitted = _utf8Prefix(value, maxBytes);
  if (fitted.complete && !truncated) return fitted.text;
  final markerBytes = _utf8Prefix(_dailyLogBytesTruncated, maxBytes).bytes;
  return '${_utf8Prefix(value, maxBytes - markerBytes).text}$_dailyLogBytesTruncated';
}

/// The kernel's byte-boundary truncation plus the byte count and completeness
/// the daily-log budget needs. The cut itself is not re-derived here.
({String text, int bytes, bool complete}) _utf8Prefix(String value, int maxBytes) {
  if (maxBytes <= 0) return (text: '', bytes: 0, complete: value.isEmpty);
  final text = truncateUtf8Bytes(value, maxBytes);
  return (text: text, bytes: utf8.encode(text).length, complete: text.length == value.length);
}
