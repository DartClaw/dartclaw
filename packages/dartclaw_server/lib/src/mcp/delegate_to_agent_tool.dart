import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart'
    show
        AcpHarnessErrorCode,
        AcpHarnessException,
        HarnessPool,
        McpTool,
        TextDeltaProgressEvent,
        ToolResult,
        TurnOutcome,
        TurnRunner,
        TurnStatus;
import 'package:path/path.dart' as p;

import '../turn_runner.dart' as server_turn;

/// Security mode returned by `delegate_to_agent`.
enum DelegationSecurityMode {
  guardMediated('guard_mediated'),
  containerIsolationOnly('container_isolation_only'),
  providerApproval('provider_approval');

  final String wireName;

  const DelegationSecurityMode(this.wireName);
}

/// Result status returned by `delegate_to_agent`.
enum DelegationResultStatus {
  completed('completed'),
  cancelled('cancelled'),
  budgetExceeded('budget_exceeded'),
  error('error');

  final String wireName;

  const DelegationResultStatus(this.wireName);
}

/// Internal MCP tool for bounded delegation to allowlisted provider agents.
class DelegateToAgentTool implements McpTool {
  final DartclawConfig _config;
  final HarnessPool _pool;
  final String _workspaceDir;
  final String _canonicalWorkspaceDir;
  final Duration _executionTimeout;
  final SlidingWindowRateLimiter? _rateLimiter;

  /// Optional preflight token estimator for tests and future provider-specific estimators.
  final int Function(String task)? _estimateTaskTokens;

  /// Optional strict-budget usage stream for tests and future provider usage events.
  final Stream<int> Function(TurnRunner runner)? _strictUsageStream;

  /// Creates a `delegate_to_agent` MCP tool.
  DelegateToAgentTool({
    required DartclawConfig config,
    required HarnessPool pool,
    String? workspaceDir,
    SlidingWindowRateLimiter? rateLimiter,
    int Function(String task)? estimateTaskTokens,
    Stream<int> Function(TurnRunner runner)? strictUsageStream,
    Duration executionTimeout = const Duration(seconds: 110),
  }) : _config = config,
       _pool = pool,
       _workspaceDir = p.normalize(p.absolute(workspaceDir ?? config.workspaceDir)),
       _canonicalWorkspaceDir =
           _resolveExistingPath(p.normalize(p.absolute(workspaceDir ?? config.workspaceDir))) ??
           p.normalize(p.absolute(workspaceDir ?? config.workspaceDir)),
       _executionTimeout = executionTimeout,
       _rateLimiter =
           rateLimiter ??
           (config.delegation.rateLimit.maxPerMinute > 0
               ? SlidingWindowRateLimiter(
                   limit: config.delegation.rateLimit.maxPerMinute,
                   window: const Duration(minutes: 1),
                 )
               : null),
       _estimateTaskTokens = estimateTaskTokens,
       _strictUsageStream = strictUsageStream;

  @override
  String get name => 'delegate_to_agent';

  @override
  String get description => 'Delegate bounded work to an allowlisted ACP or Codex provider agent.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'agent_id': {'type': 'string', 'description': 'Allowlisted provider identity to delegate to'},
      'task': {'type': 'string', 'description': 'Non-empty delegated task text'},
      'work_dir': {'type': 'string', 'description': 'Optional workspace-jailed working directory'},
    },
    'required': ['agent_id', 'task'],
    'additionalProperties': false,
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final preflight = _preflight(args);
    if (preflight.error != null) return ToolResult.text(jsonEncode(preflight.error));

    final request = preflight.request!;
    final security = _resolveSecurityMode(request.agentId, request.allowlistEntry);
    if (security.error != null) return ToolResult.text(jsonEncode(security.error));

    final limiter = _rateLimiter;
    if (limiter != null && !limiter.check('delegate_to_agent')) {
      return ToolResult.text(
        jsonEncode(
          _error(request.agentId, 'RATE_LIMITED', 'Delegation rate limit exhausted', securityMode: security.mode),
        ),
      );
    }

    final budgetLimit = _config.delegation.maxBudgetTokens;
    if (budgetLimit > 0) {
      final estimate = _estimateTaskTokens?.call(request.task) ?? 0;
      if (estimate > budgetLimit) {
        return ToolResult.text(
          jsonEncode(
            _budgetExceeded(
              request.agentId,
              security.mode!,
              budgetTokens: estimate,
              budgetLimit: budgetLimit,
              source: 'preflight_estimated',
            ),
          ),
        );
      }
    }

    final runner = _pool.tryAcquireForProvider(request.agentId);
    if (runner == null) {
      return ToolResult.text(
        jsonEncode(
          _error(
            request.agentId,
            'UNKNOWN_AGENT',
            'No idle provider runner registered for ${request.agentId}',
            securityMode: security.mode,
          ),
        ),
      );
    }

    try {
      return ToolResult.text(jsonEncode(await _execute(request, security.mode!, runner)));
    } finally {
      _pool.release(runner);
    }
  }

  Future<Map<String, dynamic>> _execute(
    _DelegationRequest request,
    DelegationSecurityMode securityMode,
    TurnRunner runner,
  ) async {
    final sessionId = 'delegation:${request.agentId}:${DateTime.now().microsecondsSinceEpoch}';
    try {
      final turnId = await runner.reserveTurn(
        sessionId,
        agentName: request.agentId,
        directory: request.workDir,
        isHumanInput: false,
      );
      try {
        runner.executeTurn(
          sessionId,
          turnId,
          [
            {'role': 'user', 'content': request.task},
          ],
          source: 'delegate_to_agent',
          agentName: request.agentId,
        );
      } catch (_) {
        runner.releaseTurn(sessionId, turnId);
        rethrow;
      }
      final outcome = await _waitForDelegationOutcome(request, runner, sessionId, turnId).timeout(_executionTimeout);
      return _fromOutcome(request, securityMode, outcome.outcome, strictBudgetTokens: outcome.strictBudgetTokens);
    } on TimeoutException {
      await runner.cancelTurn(sessionId);
      return _terminal(
        status: DelegationResultStatus.cancelled,
        agentId: request.agentId,
        securityMode: securityMode,
        code: 'CANCELLED',
        message: 'Delegation timed out and was cancelled',
        usage: _usage(budgetTokens: 0, budgetLimit: _config.delegation.maxBudgetTokens, source: 'unknown'),
        budgetStatus: 'unknown',
        budgetEnforcement: _strictOrNone(_config.delegation.maxBudgetTokens),
      );
    } on AcpHarnessException catch (e) {
      final code = switch (e.errorCode) {
        AcpHarnessErrorCode.authRequired => 'ACP_AUTH_REQUIRED',
        AcpHarnessErrorCode.spawnFailed => 'SPAWN_FAILED',
        _ => 'AGENT_CRASHED',
      };
      return _error(request.agentId, code, e.message, securityMode: securityMode);
    } on StateError catch (e) {
      final message = e.message;
      return _error(
        request.agentId,
        message.toLowerCase().contains('spawn') ? 'SPAWN_FAILED' : 'AGENT_CRASHED',
        message,
        securityMode: securityMode,
      );
    } catch (e) {
      return _error(request.agentId, 'AGENT_CRASHED', e.toString(), securityMode: securityMode);
    }
  }

  Map<String, dynamic> _fromOutcome(
    _DelegationRequest request,
    DelegationSecurityMode securityMode,
    TurnOutcome outcome, {
    int? strictBudgetTokens,
  }) {
    final budgetLimit = _config.delegation.maxBudgetTokens;
    final budgetTokens = strictBudgetTokens ?? outcome.effectiveTokens;
    final usageSource = strictBudgetTokens != null
        ? 'stream_estimated'
        : budgetTokens > 0
        ? 'provider_reported'
        : 'unknown';
    final postRunOnly = request.allowlistEntry.postRunAccountingOnly;
    final overBudget = budgetLimit > 0 && budgetTokens > budgetLimit;
    final budgetStatus = postRunOnly && budgetLimit > 0 && budgetTokens == 0
        ? 'unknown'
        : overBudget
        ? 'over_budget'
        : 'within_budget';

    if (strictBudgetTokens != null) {
      return _budgetExceeded(
        request.agentId,
        securityMode,
        budgetTokens: budgetTokens,
        budgetLimit: budgetLimit,
        source: usageSource,
      );
    }

    if (outcome.status == TurnStatus.cancelled) {
      return _terminal(
        status: DelegationResultStatus.cancelled,
        agentId: request.agentId,
        securityMode: securityMode,
        code: 'CANCELLED',
        message: 'Delegation cancelled',
        usage: _usage(budgetTokens: budgetTokens, budgetLimit: budgetLimit, source: usageSource),
        budgetStatus: budgetStatus,
        budgetEnforcement: postRunOnly ? 'post_run' : _strictOrNone(budgetLimit),
      );
    }

    if (outcome.status == TurnStatus.failed) {
      final message = outcome.errorMessage ?? 'Delegated agent failed';
      return _error(
        request.agentId,
        message.contains('GUARD') ? 'GUARD_DENIED' : 'AGENT_CRASHED',
        message,
        securityMode: securityMode,
        usage: _usage(budgetTokens: budgetTokens, budgetLimit: budgetLimit, source: usageSource),
      );
    }

    if (!postRunOnly && budgetLimit > 0 && budgetTokens == 0) {
      return _error(
        request.agentId,
        'BUDGET_USAGE_UNAVAILABLE',
        'Strict delegation budget requires provider-reported usage',
        securityMode: securityMode,
      );
    }

    if (!postRunOnly && overBudget) {
      return _budgetExceeded(
        request.agentId,
        securityMode,
        budgetTokens: budgetTokens,
        budgetLimit: budgetLimit,
        source: usageSource,
      );
    }

    return _terminal(
      status: DelegationResultStatus.completed,
      agentId: request.agentId,
      securityMode: securityMode,
      output: outcome.responseText ?? '',
      usage: _usage(
        budgetTokens: budgetTokens,
        budgetLimit: budgetLimit,
        source: postRunOnly && overBudget ? 'post_run_estimated' : usageSource,
      ),
      budgetStatus: budgetStatus,
      budgetEnforcement: postRunOnly ? 'post_run' : _strictOrNone(budgetLimit),
    );
  }

  _PreflightResult _preflight(Map<String, dynamic> args) {
    final agentId = (args['agent_id'] as String?)?.trim();
    final task = (args['task'] as String?)?.trim();
    if (!_config.delegation.enabled) {
      return _PreflightResult.error(_error(agentId, 'DELEGATION_DISABLED', 'Delegation is disabled'));
    }
    if (agentId == null || agentId.isEmpty) {
      return _PreflightResult.error(_error(null, 'AGENT_NOT_ALLOWLISTED', 'agent_id is required'));
    }
    final entry = _config.delegation.agent(agentId);
    if (entry == null) {
      return _PreflightResult.error(_error(agentId, 'AGENT_NOT_ALLOWLISTED', 'Agent is not allowlisted'));
    }
    if (!_pool.hasTaskRunnerForProvider(agentId)) {
      return _PreflightResult.error(_error(agentId, 'UNKNOWN_AGENT', 'Unknown delegation agent'));
    }
    if (task == null || task.isEmpty) {
      return _PreflightResult.error(_error(agentId, 'EMPTY_TASK', 'Delegation task is empty'));
    }
    final workDir = _resolveWorkDir(args['work_dir']);
    if (workDir == null) {
      return _PreflightResult.error(_error(agentId, 'INVALID_WORK_DIR', 'work_dir escapes workspace'));
    }
    return _PreflightResult.request(
      _DelegationRequest(agentId: agentId, task: task, workDir: workDir, allowlistEntry: entry),
    );
  }

  String? _resolveWorkDir(Object? raw) {
    if (raw == null) return _workspaceDir;
    if (raw is! String || raw.trim().isEmpty) return null;
    final rawPath = raw.trim();
    final candidate = p.normalize(p.isRelative(rawPath) ? p.join(_workspaceDir, rawPath) : p.absolute(rawPath));
    final canonicalCandidate = _resolveExistingPath(candidate);
    if (canonicalCandidate == null) return null;
    final lexicallyJailed = _isInsideDirectory(candidate, _workspaceDir);
    final physicallyJailed = _isInsideDirectory(canonicalCandidate, _canonicalWorkspaceDir);
    if (lexicallyJailed && physicallyJailed) return candidate;
    return null;
  }

  static bool _isInsideDirectory(String candidate, String root) {
    final rootWithSeparator = root.endsWith(p.separator) ? root : '$root${p.separator}';
    return candidate == root || candidate.startsWith(rootWithSeparator);
  }

  static String? _resolveExistingPath(String rawPath) {
    final normalized = p.normalize(p.absolute(rawPath));
    var current = normalized;
    final missingSegments = <String>[];

    while (true) {
      if (FileSystemEntity.typeSync(current, followLinks: false) != FileSystemEntityType.notFound) {
        String resolved;
        try {
          resolved = Directory(current).resolveSymbolicLinksSync();
        } on FileSystemException {
          return null;
        }
        var rebuilt = resolved;
        for (final segment in missingSegments.reversed) {
          rebuilt = p.join(rebuilt, segment);
        }
        return p.normalize(rebuilt);
      }

      final parent = p.dirname(current);
      if (parent == current) return normalized;
      missingSegments.add(p.basename(current));
      current = parent;
    }
  }

  _SecurityResult _resolveSecurityMode(String agentId, DelegationAgentConfig entry) {
    if (agentId == 'codex') {
      if (entry.requireGuardMediation) {
        return _SecurityResult.error(
          _error(agentId, 'AGENT_SECURITY_MODE_UNAVAILABLE', 'Codex cannot satisfy guard mediation'),
        );
      }
      final provider = _config.providers['codex'];
      final approval = provider?.options['approval'] as String?;
      final sandbox = provider?.options['sandbox'] as String?;
      final approvalOk = _codexApprovalPreservesProviderApproval(approval);
      final sandboxOk = _codexSandboxPreservesBoundary(sandbox);
      if (!approvalOk || !sandboxOk) {
        return _SecurityResult.error(
          _error(agentId, 'AGENT_SECURITY_MODE_UNAVAILABLE', 'Codex approval and sandbox policy are required'),
        );
      }
      return const _SecurityResult.mode(DelegationSecurityMode.providerApproval);
    }

    final acp = _config.harness.acp[agentId];
    if (acp == null) {
      return _SecurityResult.error(_error(agentId, 'AGENT_SECURITY_MODE_UNAVAILABLE', 'ACP security mode unavailable'));
    }
    final mode = switch (acp.securityClassification) {
      AcpSecurityClassification.guardMediated => DelegationSecurityMode.guardMediated,
      AcpSecurityClassification.containerIsolationOnly => DelegationSecurityMode.containerIsolationOnly,
    };
    if (entry.requireGuardMediation && mode != DelegationSecurityMode.guardMediated) {
      return _SecurityResult.error(_error(agentId, 'AGENT_SECURITY_MODE_UNAVAILABLE', 'Agent is not guard mediated'));
    }
    if (mode == DelegationSecurityMode.containerIsolationOnly && !acp.containerIsolationRequired) {
      return _SecurityResult.error(
        _error(agentId, 'AGENT_SECURITY_MODE_UNAVAILABLE', 'Container isolation is not enforceable'),
      );
    }
    return _SecurityResult.mode(mode);
  }

  Future<({TurnOutcome outcome, int? strictBudgetTokens})> _waitForDelegationOutcome(
    _DelegationRequest request,
    TurnRunner runner,
    String sessionId,
    String turnId,
  ) async {
    final budgetLimit = _config.delegation.maxBudgetTokens;
    final strictBudget = budgetLimit > 0 && !request.allowlistEntry.postRunAccountingOnly;
    if (!strictBudget) {
      return (outcome: await runner.waitForOutcome(sessionId, turnId), strictBudgetTokens: null);
    }

    final usageStream = _usageStream(runner);
    if (usageStream == null) {
      return (outcome: await runner.waitForOutcome(sessionId, turnId), strictBudgetTokens: null);
    }

    final outcomeFuture = runner.waitForOutcome(sessionId, turnId);
    final budgetBreach = usageStream.firstWhere((tokens) => tokens > budgetLimit);
    final winner = await Future.any<Object>([outcomeFuture, budgetBreach]);
    if (winner is TurnOutcome) {
      return (outcome: winner, strictBudgetTokens: null);
    }

    final crossedTokens = winner as int;
    await runner.cancelTurn(sessionId);
    try {
      await outcomeFuture;
    } catch (_) {
      // Cancellation is the terminal result for this tool; stale provider errors are ignored.
    }
    return (
      outcome: TurnOutcome(
        turnId: turnId,
        sessionId: sessionId,
        status: TurnStatus.cancelled,
        completedAt: DateTime.now(),
      ),
      strictBudgetTokens: crossedTokens,
    );
  }

  Stream<int>? _usageStream(TurnRunner runner) {
    final injected = _strictUsageStream?.call(runner);
    if (injected != null) return injected;
    if (_config.delegation.budgetAccounting != DelegationBudgetAccounting.estimateIfUnreported) {
      return null;
    }
    if (runner is! server_turn.TurnRunner) return null;
    var estimatedChars = 0;
    return runner.progressEvents.where((event) => event is TextDeltaProgressEvent).map((event) {
      estimatedChars += (event as TextDeltaProgressEvent).text.length;
      return (estimatedChars / 4).ceil();
    });
  }

  bool _codexApprovalPreservesProviderApproval(String? raw) {
    final approval = raw?.trim().toLowerCase();
    return approval == 'on-request' || approval == 'on-failure';
  }

  bool _codexSandboxPreservesBoundary(String? raw) {
    final sandbox = raw?.trim().toLowerCase();
    return sandbox == 'read-only' || sandbox == 'workspace-write';
  }

  Map<String, dynamic> _budgetExceeded(
    String agentId,
    DelegationSecurityMode securityMode, {
    required int budgetTokens,
    required int budgetLimit,
    required String source,
  }) {
    return _terminal(
      status: DelegationResultStatus.budgetExceeded,
      agentId: agentId,
      securityMode: securityMode,
      code: 'BUDGET_EXCEEDED',
      message: 'Delegation budget exceeded',
      usage: _usage(budgetTokens: budgetTokens, budgetLimit: budgetLimit, source: source),
      budgetStatus: 'over_budget',
      budgetEnforcement: 'strict',
    );
  }

  Map<String, dynamic> _error(
    String? agentId,
    String code,
    String message, {
    DelegationSecurityMode? securityMode,
    Map<String, dynamic>? usage,
  }) {
    return _terminal(
      status: DelegationResultStatus.error,
      agentId: agentId,
      securityMode: securityMode,
      code: code,
      message: message,
      usage: usage,
      budgetStatus: 'unknown',
      budgetEnforcement: _strictOrNone(_config.delegation.maxBudgetTokens),
    );
  }

  Map<String, dynamic> _terminal({
    required DelegationResultStatus status,
    required String? agentId,
    DelegationSecurityMode? securityMode,
    String? code,
    String? message,
    String? output,
    Map<String, dynamic>? usage,
    required String budgetStatus,
    required String budgetEnforcement,
  }) {
    return {
      'status': status.wireName,
      'agent_id': ?agentId,
      'security_mode': ?securityMode?.wireName,
      'code': ?code,
      'message': ?message,
      'output': ?output,
      'usage': usage ?? _usage(budgetTokens: 0, budgetLimit: _config.delegation.maxBudgetTokens, source: 'unknown'),
      'budget_status': budgetStatus,
      'budget_enforcement': budgetEnforcement,
    };
  }

  Map<String, dynamic> _usage({required int budgetTokens, required int budgetLimit, required String source}) => {
    'budget_tokens': budgetTokens,
    'budget_limit': budgetLimit,
    'source': source,
  };

  String _strictOrNone(int budgetLimit) => budgetLimit > 0 ? 'strict' : 'none';
}

class _DelegationRequest {
  final String agentId;
  final String task;
  final String workDir;
  final DelegationAgentConfig allowlistEntry;

  const _DelegationRequest({
    required this.agentId,
    required this.task,
    required this.workDir,
    required this.allowlistEntry,
  });
}

class _PreflightResult {
  final _DelegationRequest? request;
  final Map<String, dynamic>? error;

  const _PreflightResult.request(this.request) : error = null;

  const _PreflightResult.error(this.error) : request = null;
}

class _SecurityResult {
  final DelegationSecurityMode? mode;
  final Map<String, dynamic>? error;

  const _SecurityResult.mode(this.mode) : error = null;

  const _SecurityResult.error(this.error) : mode = null;
}
