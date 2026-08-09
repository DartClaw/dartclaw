import 'dart:convert';

import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'package:dartclaw_models/dartclaw_models.dart' show AgentDefinition;
import 'subagent_limits.dart';

/// Callback to dispatch a turn to an agent and return the result text.
typedef TurnDispatchFn =
    Future<String> Function({
      required String sessionId,
      required String message,
      required String agentId,
      required bool createSession,
    });

/// Callback that makes a failed newly-created delegated session inactive.
typedef SessionDiscardFn = Future<void> Function(String sessionId);

/// Creates and continues delegated agent sessions with limit enforcement.
class SessionDelegate {
  static final _log = Logger('SessionDelegate');
  static const _uuid = Uuid();

  final TurnDispatchFn _dispatch;
  final SessionDiscardFn? _discardSession;
  final SubagentLimits limits;
  final Map<String, AgentDefinition> _agents;
  final ContentGuard? _contentGuard;
  final GuardAuditLogger? _auditLogger;

  SessionDelegate({
    required TurnDispatchFn dispatch,
    SessionDiscardFn? discardSession,
    required this.limits,
    Map<String, AgentDefinition> agents = const {},
    ContentGuard? contentGuard,
    GuardAuditLogger? auditLogger,
  }) : _dispatch = dispatch,
       _discardSession = discardSession,
       _agents = agents,
       _contentGuard = contentGuard,
       _auditLogger = auditLogger;

  /// Creates a delegated session and waits for its first turn to complete.
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

    final sessionId = 'agent:${Uri.encodeComponent(agentId)}:delegated:${_uuid.v4()}';
    return _run(sessionId: sessionId, message: message, agent: agent, createSession: true, includeSessionId: true);
  }

  /// Sends a message to an existing delegated session and waits for its turn.
  Future<Map<String, dynamic>> handleSessionsSend(Map<String, dynamic> params) async {
    final sessionId = params['session_id'] as String?;
    final message = params['message'] as String?;
    if (sessionId == null || message == null || message.trim().isEmpty) {
      return _error('Missing required params: session_id and message');
    }

    final agentId = _agentIdForSession(sessionId);
    if (agentId == null) {
      return _error('Invalid delegated session: $sessionId');
    }
    final agent = _agents[agentId];
    if (agent == null) {
      return _error('Unknown agent for delegated session: $agentId');
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

    if (!limits.canSpawn(parentAgentId: 'main', currentDepth: 0)) {
      return _error('Agent limit reached — cannot spawn "$agentId"');
    }

    limits.recordSpawn('main');

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

      // Enforce response size cap
      final maxBytes = agent.maxResponseBytes;
      final truncated = _truncateUtf8(result, maxBytes);

      return _success(truncated, sessionId: includeSessionId ? sessionId : null);
    } catch (e) {
      _log.warning('Delegated session turn failed for agent "$agentId": $e');
      if (createSession) await _discardFailedSpawn(sessionId);
      return _error('Delegation failed: $e');
    } finally {
      limits.recordComplete('main');
    }
  }

  Future<void> _discardFailedSpawn(String sessionId) async {
    try {
      await _discardSession?.call(sessionId);
    } catch (e) {
      _log.warning('Failed to discard delegated session "$sessionId": $e');
    }
  }

  static String? _agentIdForSession(String sessionId) {
    const prefix = 'agent:';
    const separator = ':delegated:';
    if (!sessionId.startsWith(prefix)) return null;
    final separatorIndex = sessionId.indexOf(separator, prefix.length);
    if (separatorIndex <= prefix.length || separatorIndex + separator.length >= sessionId.length) return null;
    final encodedAgentId = sessionId.substring(prefix.length, separatorIndex);
    try {
      final agentId = Uri.decodeComponent(encodedAgentId);
      return agentId.isEmpty ? null : agentId;
    } on FormatException {
      return null;
    }
  }

  static String _truncateUtf8(String value, int maxBytes) {
    final encoded = utf8.encode(value);
    if (encoded.length <= maxBytes) return value;
    var end = maxBytes;
    while (end > 0) {
      try {
        return utf8.decode(encoded.sublist(0, end));
      } on FormatException {
        end--;
      }
    }
    return '';
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
