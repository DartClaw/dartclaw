import 'dart:convert';

import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'package:dartclaw_models/dartclaw_models.dart' show AgentDefinition, SessionKey, validateOutputSchema;

/// Callback to dispatch a turn to an agent and return the result text.
typedef LogicalAgentTurnDispatch = Future<String> Function({
  required String sessionId,
  required String message,
  required String agentId,
  required bool createSession,
});

/// Callback that makes a failed newly-created logical-agent session inactive.
typedef LogicalAgentSessionDiscard = Future<void> Function(String sessionId);

/// Creates and continues logical-agent sessions.
class LogicalAgentSessionService {
  static final _log = Logger('LogicalAgentSessionService');
  static const _uuid = Uuid();

  final LogicalAgentTurnDispatch _dispatch;
  final LogicalAgentSessionDiscard? _discardSession;
  final Map<String, AgentDefinition> _agents;
  final ContentGuard? _contentGuard;
  final GuardAuditLogger? _auditLogger;

  new({
    required LogicalAgentTurnDispatch dispatch,
    LogicalAgentSessionDiscard? discardSession,
    Map<String, AgentDefinition> agents = const {},
    ContentGuard? contentGuard,
    GuardAuditLogger? auditLogger,
  }) : _dispatch = dispatch,
       _discardSession = discardSession,
       _agents = Map.unmodifiable(agents),
       _contentGuard = contentGuard,
       _auditLogger = auditLogger;

  /// Configured logical agents keyed by their stable IDs.
  Map<String, AgentDefinition> get agents => _agents;

  /// Creates a logical-agent session and waits for its first turn to complete.
  Future<Map<String, dynamic>> handleSessionsSpawn(Map<String, dynamic> params) async {
    final agentId = params['agent'] as String?;
    final message = params['message'] as String?;

    if (agentId == null || agentId.trim().isEmpty || message == null || message.trim().isEmpty) {
      return _error('Missing required params: agent and message');
    }

    final agent = _agents[agentId];
    if (agent == null) {
      return _error('Unknown agent: $agentId');
    }

    final sessionId = SessionKey.logicalAgentSession(agentId: agentId, conversationId: _uuid.v4());
    return _run(sessionId: sessionId, message: message, agent: agent, createSession: true, includeSessionId: true);
  }

  /// Sends a message to an existing logical-agent session and waits for its turn.
  Future<Map<String, dynamic>> handleSessionsSend(Map<String, dynamic> params) async {
    final sessionId = params['session_id'] as String?;
    final message = params['message'] as String?;
    if (sessionId == null || message == null || message.trim().isEmpty) {
      return _error('Missing required params: session_id and message');
    }

    final agentId = _agentIdForSession(sessionId);
    if (agentId == null) {
      return _error('Invalid logical-agent session: $sessionId');
    }
    final agent = _agents[agentId];
    if (agent == null) {
      return _error('Unknown agent for logical-agent session: $agentId');
    }

    return _run(sessionId: sessionId, message: message, agent: agent, createSession: false);
  }

  Future<Map<String, dynamic>> _run({
    required String sessionId,
    required String message,
    required AgentDefinition agent,
    required bool createSession,
    bool includeSessionId = false,
  }) async {
    final agentId = agent.id;

    try {
      final result = await _dispatch(
        sessionId: sessionId,
        message: message,
        agentId: agentId,
        createSession: createSession,
      );

      // Content-guard: scan at agent boundary before returning to main agent
      final guard = _contentGuard;
      if (guard != null) {
        final context = GuardContext(hookPoint: 'beforeAgentSend', messageContent: result, timestamp: DateTime.now());
        final verdict = await guard.evaluate(context);
        _auditLogger?.logVerdict(
          verdict: verdict,
          guardName: guard.name,
          guardCategory: guard.category,
          hookPoint: context.hookPoint,
          timestamp: context.timestamp,
        );
        if (verdict.isBlock) {
          _log.warning('Content blocked at agent boundary: ${verdict.message}');
          if (createSession) await _discardFailedSpawn(sessionId);
          return _error('Web content blocked by content-guard: ${verdict.message}');
        }
      }

      final schema = agent.outputSchema;
      if (schema != null) {
        final failure = _checkOutputSchema(result, schema, agent.maxResponseBytes);
        if (failure != null) {
          _log.warning('Logical-agent output rejected for agent "$agentId": ${failure.kind}');
          if (createSession) await _discardFailedSpawn(sessionId);
          return _error(failure.message);
        }
        // D5: a schema-bound result is never truncated — a truncated value is not the declared contract.
        return _success(result, sessionId: includeSessionId ? sessionId : null);
      }

      // Enforce response size cap
      final maxBytes = agent.maxResponseBytes;
      final truncated = truncateUtf8Bytes(result, maxBytes);

      return _success(truncated, sessionId: includeSessionId ? sessionId : null);
    } catch (e) {
      _log.warning('Logical-agent session turn failed for agent "$agentId": $e');
      if (createSession) await _discardFailedSpawn(sessionId);
      return _error('Agent session failed: $e');
    }
  }

  /// Parses, validates, then size-checks a schema-bound [result].
  ///
  /// Returns `null` when [result] conforms. The order matters: truncating first
  /// would turn an oversize result into a parse failure, and parsing first keeps
  /// a non-JSON oversize result reported as the parse failure it is.
  static _OutputFailure? _checkOutputSchema(String result, Map<String, dynamic> schema, int maxBytes) {
    final Object? decoded;
    try {
      decoded = jsonDecode(result);
    } on FormatException catch (e) {
      // FormatException.toString() embeds a slice of the source; use the reason and offset only.
      final offset = e.offset;
      return _OutputFailure(
        'parse',
        'Agent output does not parse as a single JSON value: ${e.message}'
            '${offset == null ? '' : ' (at offset $offset)'}.',
      );
    }

    final duplicateOffset = _DuplicateJsonMemberScanner(result).firstDuplicateOffset();
    if (duplicateOffset != null) {
      return _OutputFailure(
        'parse',
        'Agent output is ambiguous JSON: duplicate object member name (at offset $duplicateOffset).',
      );
    }

    final violation = validateOutputSchema(decoded, schema);
    if (violation != null) {
      return _OutputFailure(
        'violation',
        'Agent output violates its output_schema at "${violation.pointer}": ${violation.message}.',
      );
    }

    final bytes = utf8.encode(result).length;
    if (bytes > maxBytes) {
      return _OutputFailure('size', 'Agent output is $bytes bytes, over the $maxBytes-byte max_response_bytes cap.');
    }
    return null;
  }

  Future<void> _discardFailedSpawn(String sessionId) async {
    try {
      await _discardSession?.call(sessionId);
    } catch (e) {
      _log.warning('Failed to discard logical-agent session "$sessionId": $e');
    }
  }

  static String? _agentIdForSession(String sessionId) {
    try {
      final key = SessionKey.parse(sessionId);
      if (key.scope != 'logical' || key.identifiers.isEmpty) return null;
      final agentId = Uri.decodeComponent(key.agentId);
      return agentId.isEmpty ? null : agentId;
    } on FormatException {
      return null;
    } on ArgumentError {
      // Uri.decodeComponent throws ArgumentError, not FormatException, on malformed percent-escapes.
      return null;
    }
  }

  static Map<String, dynamic> _success(String text, {String? sessionId}) => {
    'content': [
      {'type': 'text', 'text': text},
    ],
    'sessionId': ?sessionId,
  };

  static Map<String, dynamic> _error(String message) => {
    'content': [
      {'type': 'text', 'text': message},
    ],
    'isError': true,
  };
}

class _DuplicateJsonMemberScanner {
  final String source;
  var _offset = 0;

  new(this.source);

  int? firstDuplicateOffset() {
    _skipWhitespace();
    return _scanValue();
  }

  int? _scanValue() {
    _skipWhitespace();
    final code = source.codeUnitAt(_offset);
    if (code == 0x7b) return _scanObject();
    if (code == 0x5b) return _scanArray();
    if (code == 0x22) {
      _scanString();
    } else {
      _scanScalar();
    }
    return null;
  }

  int? _scanObject() {
    _offset++;
    _skipWhitespace();
    if (source.codeUnitAt(_offset) == 0x7d) {
      _offset++;
      return null;
    }
    final names = <String>{};
    while (true) {
      _skipWhitespace();
      final keyOffset = _offset;
      final name = _scanString();
      if (!names.add(name)) return keyOffset;
      _skipWhitespace();
      _offset++;
      final duplicate = _scanValue();
      if (duplicate != null) return duplicate;
      _skipWhitespace();
      if (source.codeUnitAt(_offset++) == 0x7d) return null;
    }
  }

  int? _scanArray() {
    _offset++;
    _skipWhitespace();
    if (source.codeUnitAt(_offset) == 0x5d) {
      _offset++;
      return null;
    }
    while (true) {
      final duplicate = _scanValue();
      if (duplicate != null) return duplicate;
      _skipWhitespace();
      if (source.codeUnitAt(_offset++) == 0x5d) return null;
    }
  }

  String _scanString() {
    final start = _offset++;
    while (true) {
      final code = source.codeUnitAt(_offset++);
      if (code == 0x5c) {
        _offset++;
      } else if (code == 0x22) {
        return jsonDecode(source.substring(start, _offset)) as String;
      }
    }
  }

  void _scanScalar() {
    while (_offset < source.length) {
      final code = source.codeUnitAt(_offset);
      if (code == 0x2c || code == 0x5d || code == 0x7d || _isWhitespace(code)) return;
      _offset++;
    }
  }

  void _skipWhitespace() {
    while (_offset < source.length && _isWhitespace(source.codeUnitAt(_offset))) {
      _offset++;
    }
  }

  static bool _isWhitespace(int code) => code == 0x20 || code == 0x0a || code == 0x0d || code == 0x09;
}

/// A schema-bound result rejected at the agent boundary.
class _OutputFailure {
  /// `parse`, `violation`, or `size` — the kind named in the warning log.
  final String kind;

  /// Message returned to the caller; never carries a slice of the result.
  final String message;

  const new(this.kind, this.message);
}
