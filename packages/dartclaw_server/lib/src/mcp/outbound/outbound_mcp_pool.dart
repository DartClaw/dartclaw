import 'dart:async';

import 'package:dartclaw_config/dartclaw_config.dart'
    show CredentialEntry, CredentialsConfig, McpServerEntry, McpServersConfig, SlidingWindowRateLimiter;
import 'package:dartclaw_core/dartclaw_core.dart' show EventBus, OutboundMcpGovernanceEvent;
import 'package:dartclaw_security/dartclaw_security.dart';

import 'http_mcp_transport.dart';
import 'outbound_mcp_client.dart';
import 'outbound_mcp_errors.dart';
import 'outbound_mcp_models.dart';
import 'outbound_mcp_transport.dart';
import 'stdio_mcp_transport.dart';

typedef OutboundMcpTimerFactory = Timer Function(Duration duration, void Function() callback);
typedef OutboundMcpClock = DateTime Function();

final class OutboundMcpPool {
  final Map<String, McpServerEntry> _registry;
  final Duration _idleTtl;
  final Duration _timeout;
  final int _maxResponseBytes;
  final OutboundMcpTransportFactory _transportFactory;
  final OutboundMcpGuardHook? _guardHook;
  final OutboundMcpGuardDecisionHook? _guardDecisionHook;
  final GuardAuditLogger? _auditLogger;
  final EventBus? _eventBus;
  final OutboundMcpObserver? _observer;
  final OutboundMcpTimerFactory _timerFactory;
  final OutboundMcpClock _clock;
  final CredentialsConfig _credentials;
  final Map<String, _PooledConnection> _connections = {};
  final Map<String, _ServerGovernanceState> _governance = {};
  var _closed = false;

  OutboundMcpPool({
    required McpServersConfig mcpServers,
    Duration idleTtl = const Duration(minutes: 5),
    Duration timeout = const Duration(seconds: 30),
    int maxResponseBytes = 1024 * 1024,
    OutboundMcpTransportFactory? transportFactory,
    OutboundMcpGuardHook? guardHook,
    OutboundMcpGuardDecisionHook? guardDecisionHook,
    GuardAuditLogger? auditLogger,
    EventBus? eventBus,
    OutboundMcpObserver? observer,
    OutboundMcpTimerFactory? timerFactory,
    OutboundMcpClock? clock,
    CredentialsConfig credentials = const CredentialsConfig.defaults(),
  }) : _registry = mcpServers.enabledRegistry,
       _idleTtl = idleTtl,
       _timeout = timeout,
       _maxResponseBytes = maxResponseBytes,
       _transportFactory = transportFactory ?? _defaultTransportFactory,
       _guardHook = guardHook,
       _guardDecisionHook = guardDecisionHook,
       _auditLogger = auditLogger,
       _eventBus = eventBus,
       _observer = observer,
       _timerFactory = timerFactory ?? Timer.new,
       _clock = clock ?? DateTime.now,
       _credentials = credentials;

  /// Lists tools exposed by an enabled outbound MCP server.
  ///
  /// By default only tools named in the server's `surface_tools` are returned.
  /// Set [surfacedOnly] to `false` to inspect the full external `tools/list`
  /// response while still validating configured surface entries. Throws an
  /// [OutboundMcpException] when the pool is closed, the server is unavailable,
  /// the external list call fails, or a configured surface entry is absent from
  /// the server's advertised tools.
  Future<List<OutboundMcpTool>> listTools(String serverName, {bool surfacedOnly = true}) async {
    if (_closed) {
      throw const OutboundMcpException('pool_closed', 'Outbound MCP pool is closed');
    }
    final connection = await _connection(serverName);
    if (_closed) {
      throw const OutboundMcpException('pool_closed', 'Outbound MCP pool is closed');
    }
    _touch(serverName, connection);
    late final List<OutboundMcpTool> tools;
    try {
      tools = await connection.client.listTools();
    } catch (_) {
      await _remove(serverName, eventType: 'list-failed');
      rethrow;
    }
    _validateSurfaceTools(serverName, tools);
    return surfacedOnly ? _surfacedTools(serverName, tools) : tools;
  }

  Future<OutboundMcpCallResult> callTool({
    required String serverName,
    required String toolName,
    required Map<String, dynamic> arguments,
    required OutboundMcpCaller caller,
  }) async {
    if (_closed) {
      return _failureResult(
        serverName: serverName,
        toolName: toolName,
        code: 'pool_closed',
        message: 'Outbound MCP pool is closed',
      );
    }
    if (!_registry.containsKey(serverName)) {
      return _deniedUnavailableResult(serverName: serverName, toolName: toolName, arguments: arguments, caller: caller);
    }

    try {
      final guardRequest = OutboundMcpGuardRequest(
        serverName: serverName,
        toolName: toolName,
        arguments: arguments,
        caller: caller,
      );
      final decision = await _guardDecision(guardRequest);
      if (!decision.allowed) {
        return await _denyWithAudit(guardRequest, decision);
      }
      final governanceDecision = _checkGovernance(guardRequest);
      if (!governanceDecision.allowed) {
        return await _denyWithAudit(guardRequest, governanceDecision);
      }
      try {
        await _auditDecision(guardRequest, decision);
      } catch (error) {
        return _deniedResult(
          serverName: serverName,
          toolName: toolName,
          reason: 'Egress denied: guard/audit failure: $error',
        );
      }
      final connection = await _connection(serverName);
      if (_closed) {
        return _failureResult(
          serverName: serverName,
          toolName: toolName,
          code: 'pool_closed',
          message: 'Outbound MCP pool is closed',
        );
      }
      _touch(serverName, connection);
      final result = await connection.client.callTool(toolName: toolName, arguments: arguments, caller: caller);
      if (result.isSuccess) {
        _recordGovernanceUsage(serverName, result.outboundCallTokens);
      }
      return result;
    } on OutboundMcpException catch (error) {
      _emit(serverName, 'failure', detail: error.code);
      return _failureResult(serverName: serverName, toolName: toolName, code: error.code, message: error.message);
    } catch (error) {
      _emit(serverName, 'failure', detail: 'connection_failure');
      return _failureResult(
        serverName: serverName,
        toolName: toolName,
        code: 'connection_failure',
        message: error.toString(),
      );
    }
  }

  Future<void> close() async {
    _closed = true;
    final connections = _connections.values.toList(growable: false);
    _connections.clear();
    final closeErrors = <(Object, StackTrace)>[];
    for (final connection in connections) {
      connection.idleTimer?.cancel();
      try {
        await connection.client.close();
      } catch (error, stackTrace) {
        closeErrors.add((error, stackTrace));
      }
    }
    if (closeErrors.length == 1) {
      final (error, stackTrace) = closeErrors.single;
      Error.throwWithStackTrace(error, stackTrace);
    }
    if (closeErrors.isNotEmpty) {
      throw OutboundMcpException(
        'close_failed',
        'Failed to close ${closeErrors.length} outbound MCP connections: '
            '${closeErrors.map((entry) => entry.$1).join('; ')}',
      );
    }
  }

  Future<_PooledConnection> _connection(String serverName) async {
    if (_closed) {
      throw const OutboundMcpException('pool_closed', 'Outbound MCP pool is closed');
    }
    final existing = _connections[serverName];
    if (existing != null) {
      if (await existing.client.ping()) {
        _emit(serverName, 'reuse');
        return existing;
      }
      await _remove(serverName, eventType: 'respawn');
    }
    final entry = _registry[serverName];
    if (entry == null) {
      throw OutboundMcpException('server_unavailable', 'MCP server "$serverName" is absent from the enabled registry');
    }
    final credentialRef = entry.credential;
    final credential = credentialRef == null ? null : _credentials[credentialRef];
    if (credentialRef != null && (credential == null || !credential.isPresent)) {
      throw OutboundMcpException(
        'credential_unavailable',
        'MCP server credential "$credentialRef" is unavailable at connection time',
      );
    }
    final transport = await _transportFactory(
      OutboundMcpServerDefinition(name: serverName, entry: entry),
      OutboundMcpTransportOptions(timeout: _timeout, maxResponseBytes: _maxResponseBytes, credential: credential),
    );
    final client = OutboundMcpClient(
      serverName: serverName,
      transport: transport,
      timeout: _timeout,
      maxResponseBytes: _maxResponseBytes,
      observer: _observer,
    );
    if (_closed) {
      try {
        await client.close();
      } catch (_) {}
      throw const OutboundMcpException('pool_closed', 'Outbound MCP pool is closed');
    }
    final connection = _PooledConnection(client);
    _connections[serverName] = connection;
    _emit(serverName, 'spawn');
    return connection;
  }

  void _touch(String serverName, _PooledConnection connection) {
    connection.idleTimer?.cancel();
    connection.idleTimer = _timerFactory(_idleTtl, () {
      unawaited(_remove(serverName, eventType: 'idle-teardown'));
    });
  }

  Future<void> _remove(String serverName, {required String eventType}) async {
    final connection = _connections.remove(serverName);
    if (connection == null) return;
    connection.idleTimer?.cancel();
    await connection.client.close();
    _emit(serverName, eventType);
  }

  void _emit(String serverName, String type, {String? detail}) {
    _observer?.call(
      OutboundMcpLifecycleEvent(serverName: serverName, type: type, detail: detail, timestamp: DateTime.now()),
    );
  }

  Future<OutboundMcpGuardDecision> _guardDecision(OutboundMcpGuardRequest request) async {
    try {
      final decisionHook = _guardDecisionHook;
      return decisionHook == null ? await _legacyGuard(request) : await decisionHook(request);
    } catch (error) {
      return OutboundMcpGuardDecision.deny('Egress denied: guard/audit failure: $error');
    }
  }

  Future<OutboundMcpGuardDecision> _legacyGuard(OutboundMcpGuardRequest request) async {
    final guardHook = _guardHook;
    if (guardHook == null) return const OutboundMcpGuardDecision.deny('Egress denied: no allowlist matched');
    await guardHook(request);
    return const OutboundMcpGuardDecision.allow();
  }

  OutboundMcpGuardDecision _checkGovernance(OutboundMcpGuardRequest request) {
    final state = _governanceState(request.serverName);
    if (state == null) return const OutboundMcpGuardDecision.allow();
    final now = _clock();
    if (!state.tryAdmitRate(request.serverName, now)) {
      const reason = 'Egress denied: governance rate limit exceeded';
      state.recordRejection(now);
      _emitGovernanceCounters(request.serverName, state, now, rejectionReason: reason);
      return const OutboundMcpGuardDecision.deny(reason);
    }
    if (!state.checkTokenBudget(now)) {
      const reason = 'Egress denied: governance token budget exceeded';
      state.recordRejection(now);
      _emitGovernanceCounters(request.serverName, state, now, rejectionReason: reason);
      return const OutboundMcpGuardDecision.deny(reason);
    }
    _emitGovernanceCounters(request.serverName, state, now);
    return const OutboundMcpGuardDecision.allow();
  }

  void _recordGovernanceUsage(String serverName, int outboundCallTokens) {
    final state = _governanceState(serverName);
    if (state == null) return;
    final now = _clock();
    state.recordTokens(outboundCallTokens, now);
    _emitGovernanceCounters(serverName, state, now);
  }

  _ServerGovernanceState? _governanceState(String serverName) {
    final entry = _registry[serverName];
    if (entry == null) return null;
    return _governance.putIfAbsent(serverName, () => _ServerGovernanceState(entry));
  }

  void _emitGovernanceCounters(
    String serverName,
    _ServerGovernanceState state,
    DateTime now, {
    String? rejectionReason,
  }) {
    final eventBus = _eventBus;
    if (eventBus == null) return;
    eventBus.fire(
      OutboundMcpGovernanceEvent(
        serverName: serverName,
        callsUsed: state.callsUsed(serverName, now),
        tokensUsed: state.tokensUsed(now),
        rejections: state.rejections(now),
        rejectionReason: rejectionReason,
        timestamp: now,
      ),
    );
  }

  List<OutboundMcpTool> _surfacedTools(String serverName, List<OutboundMcpTool> tools) {
    final surfaceTools = _registry[serverName]?.surfaceTools ?? const [];
    final surfaceSet = surfaceTools.toSet();
    return tools.where((tool) => surfaceSet.contains(tool.name)).toList(growable: false);
  }

  void _validateSurfaceTools(String serverName, List<OutboundMcpTool> tools) {
    final surfaceTools = _registry[serverName]?.surfaceTools ?? const [];
    final exposed = tools.map((tool) => tool.name).toSet();
    for (final surfaced in surfaceTools) {
      if (!exposed.contains(surfaced)) {
        throw OutboundMcpException(
          'invalid_surface_tool',
          'mcp_servers.$serverName.surface_tools references unknown tool "$surfaced"',
        );
      }
    }
  }

  Future<OutboundMcpCallResult> _denyWithAudit(
    OutboundMcpGuardRequest request,
    OutboundMcpGuardDecision decision,
  ) async {
    try {
      await _auditDecision(request, decision);
      return _deniedResult(
        serverName: request.serverName,
        toolName: request.toolName,
        reason: decision.reason ?? 'Egress denied',
      );
    } catch (error) {
      return _deniedResult(
        serverName: request.serverName,
        toolName: request.toolName,
        reason: 'Egress denied: guard/audit failure: $error',
      );
    }
  }

  Future<void> _auditDecision(OutboundMcpGuardRequest request, OutboundMcpGuardDecision decision) async {
    final auditLogger = _auditLogger;
    if (auditLogger == null) {
      throw StateError('outbound MCP audit logger unavailable');
    }
    final entry = _registry[request.serverName];
    await auditLogger.writeEntry(
      AuditEntry(
        timestamp: DateTime.now(),
        guard: 'EgressGuard',
        hook: 'outbound_mcp_tools_call',
        verdict: decision.allowed ? 'pass' : 'block',
        reason: decision.reason,
        rawProviderToolName: request.toolName,
        sessionId: request.caller.sessionId,
        server: request.serverName,
        tool: request.toolName,
        decision: decision.decision,
        principal: request.caller.principal ?? request.caller.sessionId,
        credentialRef: entry?.credential,
      ),
    );
  }

  OutboundMcpCallResult _failureResult({
    required String serverName,
    required String toolName,
    required String code,
    required String message,
  }) {
    return OutboundMcpCallResult(
      serverName: serverName,
      toolName: toolName,
      content: const [],
      outboundCallTokens: 0,
      error: OutboundMcpError(code: code, message: message, serverName: serverName),
    );
  }

  OutboundMcpCallResult _deniedResult({required String serverName, required String toolName, required String reason}) {
    return OutboundMcpCallResult(
      serverName: serverName,
      toolName: toolName,
      content: [
        {'type': 'text', 'text': reason},
      ],
      isError: true,
      outboundCallTokens: 0,
      error: OutboundMcpError(code: 'egress_denied', message: reason, serverName: serverName),
      decision: 'deny',
      reason: reason,
    );
  }

  Future<OutboundMcpCallResult> _deniedUnavailableResult({
    required String serverName,
    required String toolName,
    required Map<String, dynamic> arguments,
    required OutboundMcpCaller caller,
  }) async {
    final request = OutboundMcpGuardRequest(
      serverName: serverName,
      toolName: toolName,
      arguments: arguments,
      caller: caller,
    );
    final reason = 'MCP server "$serverName" is absent from the enabled registry';
    final decision = OutboundMcpGuardDecision.deny(reason);
    try {
      await _auditDecision(request, decision);
      return _deniedResult(serverName: serverName, toolName: toolName, reason: reason);
    } catch (error) {
      return _deniedResult(
        serverName: serverName,
        toolName: toolName,
        reason: 'Egress denied: guard/audit failure: $error',
      );
    }
  }
}

final class _PooledConnection {
  final OutboundMcpClient client;
  Timer? idleTimer;

  _PooledConnection(this.client);
}

final class _ServerGovernanceState {
  final McpServerEntry entry;
  final SlidingWindowRateLimiter _rateLimiter;
  final List<({DateTime timestamp, int tokens})> _tokenUsage = [];
  final List<DateTime> _rejections = [];

  _ServerGovernanceState(this.entry)
    : _rateLimiter = SlidingWindowRateLimiter(limit: entry.rateLimit.calls, window: entry.rateLimit.window);

  bool tryAdmitRate(String serverName, DateTime now) {
    if (entry.rateLimit.isDisabled) return true;
    return _rateLimiter.check(serverName, now: now);
  }

  bool checkTokenBudget(DateTime now) {
    if (entry.tokenBudget.isDisabled) return true;
    return tokensUsed(now) < entry.tokenBudget.tokens;
  }

  void recordTokens(int tokens, DateTime now) {
    if (entry.tokenBudget.isDisabled || tokens <= 0) return;
    _evictTokens(now);
    _tokenUsage.add((timestamp: now, tokens: tokens));
  }

  void recordRejection(DateTime now) {
    _evictRejections(now);
    _rejections.add(now);
  }

  int callsUsed(String serverName, DateTime now) => _rateLimiter.currentCount(serverName, now: now);

  int tokensUsed(DateTime now) {
    _evictTokens(now);
    return _tokenUsage.fold<int>(0, (total, entry) => total + entry.tokens);
  }

  int rejections(DateTime now) {
    _evictRejections(now);
    return _rejections.length;
  }

  void _evictTokens(DateTime now) {
    if (entry.tokenBudget.isDisabled) {
      _tokenUsage.clear();
      return;
    }
    final cutoff = now.subtract(entry.tokenBudget.window);
    _tokenUsage.removeWhere((entry) => entry.timestamp.isBefore(cutoff));
  }

  void _evictRejections(DateTime now) {
    final window = _rejectionWindow(entry);
    final cutoff = now.subtract(window);
    _rejections.removeWhere((timestamp) => timestamp.isBefore(cutoff));
  }
}

Duration _rejectionWindow(McpServerEntry entry) {
  final windows = <Duration>[
    if (!entry.rateLimit.isDisabled) entry.rateLimit.window,
    if (!entry.tokenBudget.isDisabled) entry.tokenBudget.window,
  ];
  if (windows.isEmpty) return Duration.zero;
  return windows.reduce((a, b) => a >= b ? a : b);
}

Future<OutboundMcpTransport> _defaultTransportFactory(
  OutboundMcpServerDefinition server,
  OutboundMcpTransportOptions options,
) {
  final entry = server.entry;
  if (entry.command != null) {
    final credential = options.credential;
    if (credential != null) {
      return StdioMcpTransport.start(entry.command!, environment: stdioCredentialEnvironment(credential));
    }
    return StdioMcpTransport.start(entry.command!);
  }
  if (entry.url != null) {
    return Future.value(
      HttpMcpTransport(
        entry.url!,
        requireTls: true,
        networkClass: entry.networkClass,
        credentialSecret: options.credential?.secret,
      ),
    );
  }
  throw const OutboundMcpException('invalid_server', 'MCP server entry has no transport');
}

/// Builds the child-process environment that delivers a resolved stdio MCP
/// [credential] secret to the subprocess.
///
/// S04 sanctions credential delivery through the `SafeProcess`/`EnvPolicy` env
/// path: the secret is overlaid onto the child environment only — never argv,
/// the inherited parent env, logs, or the audit record (which keeps the
/// `credentialRef` alone). The injection variable name(s) come from the
/// credential's declared [CredentialEntry.envVars]; a credentialed stdio server
/// whose credential names no env var cannot be targeted safely, so it fails
/// closed rather than guessing a name or leaking the secret elsewhere.
Map<String, String> stdioCredentialEnvironment(CredentialEntry credential) {
  if (credential.envVars.isEmpty) {
    throw const OutboundMcpException(
      'credential_env_unmapped',
      'Credentialed stdio MCP server requires the referenced credential to declare the '
          'environment variable name(s) to inject (e.g. credentials.<ref> sourced from \${VAR})',
    );
  }
  return {for (final name in credential.envVars) name: credential.secret};
}
