import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../security/content_guard.dart';
import '../security/guard.dart';
import '../security/guard_audit.dart';
import 'agent_definition.dart';
import 'subagent_limits.dart';

/// Callback to dispatch a turn to an agent and return the result text.
typedef TurnDispatchFn = Future<String> Function({
  required String sessionId,
  required String message,
  required String agentId,
});

/// Handles `sessions_send` and `sessions_spawn` MCP tool calls, dispatching
/// turns to sub-agents with limit enforcement.
class SessionDelegate {
  static final _log = Logger('SessionDelegate');
  static const _uuid = Uuid();

  final TurnDispatchFn _dispatch;
  final SubagentLimits limits;
  final Map<String, AgentDefinition> _agents;
  final ContentGuard? _contentGuard;
  final GuardAuditLogger? _auditLogger;
  final Map<String, Completer<String>> _pending = {};

  SessionDelegate({
    required TurnDispatchFn dispatch,
    required this.limits,
    Map<String, AgentDefinition> agents = const {},
    ContentGuard? contentGuard,
    GuardAuditLogger? auditLogger,
  })  : _dispatch = dispatch,
        _agents = agents,
        _contentGuard = contentGuard,
        _auditLogger = auditLogger;

  /// Handle synchronous delegation — wait for the sub-agent to complete.
  Future<Map<String, dynamic>> handleSessionsSend(Map<String, dynamic> params) async {
    final agentId = params['agent'] as String?;
    final message = params['message'] as String?;

    if (agentId == null || message == null) {
      return _error('Missing required params: agent and message');
    }

    final agent = _agents[agentId];
    if (agent == null) {
      return _error('Unknown agent: $agentId');
    }

    if (!limits.canSpawn(parentAgentId: 'main', currentDepth: 0)) {
      return _error('Agent limit reached — cannot spawn "$agentId"');
    }

    final sessionId = 'agent:$agentId:delegated:${_uuid.v4()}';
    limits.recordSpawn('main');

    try {
      final result = await _dispatch(
        sessionId: sessionId,
        message: message,
        agentId: agentId,
      );

      // Content-guard: scan at agent boundary before returning to main agent
      final guard = _contentGuard;
      if (guard != null) {
        final context = GuardContext(
          hookPoint: 'beforeAgentSend',
          messageContent: result,
          timestamp: DateTime.now(),
        );
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
          return _error('Web content blocked by content-guard: ${verdict.message}');
        }
      }

      // Enforce response size cap
      final maxBytes = agent.maxResponseBytes;
      final encoded = utf8.encode(result);
      final truncated = encoded.length > maxBytes
          ? utf8.decode(encoded.sublist(0, maxBytes), allowMalformed: true)
          : result;

      return _success(truncated);
    } catch (e) {
      _log.warning('sessions_send failed for agent "$agentId": $e');
      return _error('Delegation failed: $e');
    } finally {
      limits.recordComplete('main');
    }
  }

  /// Handle async delegation — return session ID immediately.
  Future<Map<String, dynamic>> handleSessionsSpawn(Map<String, dynamic> params) async {
    final agentId = params['agent'] as String?;
    final message = params['message'] as String?;

    if (agentId == null || message == null) {
      return _error('Missing required params: agent and message');
    }

    final agent = _agents[agentId];
    if (agent == null) {
      return _error('Unknown agent: $agentId');
    }

    if (!limits.canSpawn(parentAgentId: 'main', currentDepth: 0)) {
      return _error('Agent limit reached — cannot spawn "$agentId"');
    }

    final sessionId = 'agent:$agentId:spawned:${_uuid.v4()}';
    limits.recordSpawn('main');

    final completer = Completer<String>();
    _pending[sessionId] = completer;

    // Fire and forget — run in background
    unawaited(_runBackground(sessionId, agentId, message, completer));

    return _success('Spawned session: $sessionId');
  }

  Future<void> _runBackground(
    String sessionId,
    String agentId,
    String message,
    Completer<String> completer,
  ) async {
    try {
      final result = await _dispatch(
        sessionId: sessionId,
        message: message,
        agentId: agentId,
      );
      completer.complete(result);
    } catch (e) {
      _log.warning('Spawned agent "$agentId" failed: $e');
      completer.completeError(e);
    } finally {
      limits.recordComplete('main');
      _pending.remove(sessionId);
    }
  }

  static Map<String, dynamic> _success(String text) => {
        'content': [
          {'type': 'text', 'text': text},
        ],
      };

  static Map<String, dynamic> _error(String message) => {
        'content': [
          {'type': 'text', 'text': message},
        ],
        'isError': true,
      };
}
