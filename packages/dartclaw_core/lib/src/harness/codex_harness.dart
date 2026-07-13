import 'dart:async';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show PlatformCapabilities, UnsupportedCapabilityError;
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';

import '../bridge/bridge_events.dart';
import '../worker/worker_state.dart';

import 'agent_harness.dart';
import 'base_harness.dart';
import 'codex_environment.dart';
import 'codex_protocol_adapter.dart';
import 'codex_protocol_utils.dart';
import 'codex_settings.dart';
import 'harness_config.dart';
import 'process_lifecycle.dart';
import 'process_types.dart';
import 'protocol_message.dart' as proto;

Duration _remainingUntil(DateTime deadline) {
  final remaining = deadline.difference(DateTime.now());
  return remaining > Duration.zero ? remaining : Duration.zero;
}

Future<void> _verifyCodexExecutable(String executable, CommandProbe commandProbe) async {
  ProcessResult result;
  try {
    result = await commandProbe(executable, const ['--version']);
  } on ProcessException {
    _throwMissingCodexExecutable(executable);
  }
  if (result.exitCode != 0 || '${result.stdout}'.trim().isEmpty) {
    _throwMissingCodexExecutable(executable);
  }
}

Never _throwMissingCodexExecutable(String executable) => throw UnsupportedCapabilityError(
  capability: 'Codex harness executable',
  attemptedContext: '$executable --version',
  remediation: 'Install "$executable" and ensure it is available on PATH.',
);

String? _sandboxPermissions(String sandboxValue) => switch (sandboxValue.trim()) {
  'danger-full-access' => '["disk-full-read-write-access", "network-full-access"]',
  'workspace-write' => '["disk-full-read-access", "disk-write-platform-user-caches", "disk-write-cwd"]',
  _ => null,
};

/// Thin subprocess lifecycle manager for `codex app-server`.
class CodexHarness extends BaseHarness {
  /// Codex executable path or name.
  final String executable;

  /// Environment passed to the Codex subprocess.
  final Map<String, String> environment;

  /// Provider-specific options used for Codex request settings translation.
  final Map<String, dynamic> providerOptions;

  /// Optional guard chain used to evaluate approval requests.
  final GuardChain? guardChain;

  /// Codex protocol adapter used for all wire-format translation.
  final CodexProtocolAdapter adapter;

  /// Platform policy used for executable lookup and process semantics.
  final PlatformCapabilities platformCapabilities;

  static final _log = Logger('CodexHarness');

  final Map<String, String> _threadIds = <String, String>{};
  String? _activeSessionId;
  int _nextRequestId = 0;
  Object? _initializeRequestId;
  Object? _threadStartRequestId;
  Completer<Map<String, dynamic>>? _initializeCompleter;
  Completer<String>? _threadStartCompleter;
  Completer<Map<String, dynamic>>? _turnCompleter;
  final Set<String> _agentMessageDeltaIds = <String>{};
  CodexEnvironment? _environment;

  /// Grace period after SIGTERM before escalating to SIGKILL.
  final Duration _killGracePeriod;
  final Duration _initializeTimeout;

  CodexHarness({
    required super.cwd,
    this.executable = 'codex',
    super.turnTimeout = const Duration(seconds: 600),
    super.maxRetries = 5,
    super.baseBackoff = const Duration(seconds: 5),
    ProcessFactory? processFactory,
    CommandProbe? commandProbe,
    DelayFactory? delayFactory,
    Map<String, String>? environment,
    super.harnessConfig = const HarnessConfig(),
    Map<String, dynamic>? providerOptions,
    this.guardChain,
    CodexProtocolAdapter? adapter,
    PlatformCapabilities? platformCapabilities,
    Duration killGracePeriod = const Duration(seconds: 2),
    Duration initializeTimeout = const Duration(seconds: 10),
  }) : environment = environment ?? Platform.environment,
       providerOptions = Map<String, dynamic>.unmodifiable(providerOptions ?? const <String, dynamic>{}),
       adapter = adapter ?? CodexProtocolAdapter(),
       platformCapabilities = platformCapabilities ?? PlatformCapabilities(),
       _killGracePeriod = killGracePeriod,
       _initializeTimeout = initializeTimeout,
       super(
         log: _log,
         processFactory: processFactory ?? Process.start,
         commandProbe: commandProbe ?? Process.run,
         delayFactory: delayFactory ?? Future<void>.delayed,
       );

  @override
  PromptStrategy get promptStrategy => PromptStrategy.append;

  @override
  bool get supportsCostReporting => false;

  @override
  bool get supportsCachedTokens => true;

  @override
  bool get supportsSessionContinuity => true;

  @override
  String skillActivationLine(String skill) => '\$$skill';

  @override
  Future<void> start() => startLifecycle(
    busyMessage: 'Cannot start CodexHarness while busy',
    beforeStart: () async {
      isStopping = false;
      await _cleanupEnvironment();
      await _verifyCodexExecutable(executable, commandProbe);
      _environment = CodexEnvironment(
        developerInstructions: harnessConfig.appendSystemPrompt ?? '',
        mcpServerUrl: harnessConfig.mcpServerUrl,
        mcpGatewayToken: harnessConfig.mcpGatewayToken,
        useSystemCodexHome: _boolProviderOption('use_system_codex_home', defaultValue: true),
        platformCapabilities: platformCapabilities,
      );
    },
    start: () async {
      try {
        await _environment!.setup();
        await _spawnProcess();
        await _initialize();
        currentState = WorkerState.idle;
      } catch (_) {
        // Any startup step failed — release env/process resources before bubbling the cause.
        await _cleanupStartupFailure();
        rethrow;
      }
    },
  );

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
  }) async {
    if (currentState == WorkerState.stopped) {
      await start();
    }
    while (currentState == WorkerState.crashed) {
      await recoverFromCrash(() async {
        try {
          await _restartAfterCrash();
        } catch (_) {
          if (currentState != WorkerState.crashed) {
            rethrow; // Unexpected restart failure — surface to caller.
          }
          // Still crashed after restart attempt — loop will retry.
        }
      });
    }

    if (currentState != WorkerState.idle) {
      throw StateError('CodexHarness is not idle (state: $currentState)');
    }
    if (currentProcess == null) {
      throw StateError('CodexHarness has not completed startup');
    }
    if (messages.isEmpty) {
      throw StateError('CodexHarness requires at least one message');
    }

    currentState = WorkerState.busy;
    _activeSessionId = sessionId;
    _turnCompleter = Completer<Map<String, dynamic>>();
    final stopwatch = Stopwatch();
    final deadline = DateTime.now().add(turnTimeout);

    try {
      final threadId =
          _threadIds[sessionId] ??
          await _startThread(
            sessionId,
          ).timeout(_remainingUntil(deadline), onTimeout: () => _stopAfterTurnTimeout<String>());

      final previousMessages = messages.length > 1
          ? messages.sublist(0, messages.length - 1)
          : const <Map<String, dynamic>>[];
      final payload = adapter.buildTurnRequest(
        message: stringifyMessageContent(messages.last['content']),
        systemPrompt: systemPrompt.trim().isEmpty ? null : systemPrompt,
        threadId: threadId,
        history: previousMessages,
        settings: CodexSettings.buildDynamicSettings(
          model: model ?? harnessConfig.model,
          cwd: directory,
          sandbox: _stringProviderOption('sandbox'),
          approval: _stringProviderOption('approval'),
        ),
        resume: resume,
      );
      payload['id'] = _nextJsonRpcId();
      final promptPreview = stringifyMessageContent(messages.last['content']);
      final params = payload['params'] as Map<String, dynamic>?;
      final sandboxPolicy = params?['sandboxPolicy'] as Map<String, dynamic>?;
      _log.info(
        'Turn start: session=$sessionId, thread=$threadId, '
        'model=${model ?? harnessConfig.model}, '
        'sandbox=${sandboxPolicy?['type'] ?? 'not-set'}, '
        'prompt=${promptPreview.length > 120 ? '${promptPreview.substring(0, 120)}...' : promptPreview}',
      );
      stopwatch.start();
      _writeLine(payload);

      final result = await _turnCompleter!.future.timeout(
        _remainingUntil(deadline),
        onTimeout: () => _stopAfterTurnTimeout<Map<String, dynamic>>(),
      );
      if (stopwatch.isRunning) {
        stopwatch.stop();
      }
      _log.info('Turn finished in ${stopwatch.elapsedMilliseconds}ms');
      result['duration_ms'] ??= stopwatch.elapsedMilliseconds;
      if (currentState != WorkerState.stopped && currentState != WorkerState.crashed) {
        crashCount = 0;
        currentState = WorkerState.idle;
      }
      return result;
    } catch (_) {
      // Turn failed — restore idle state (unless stopping/crashed) and bubble the original error.
      if (stopwatch.isRunning) {
        stopwatch.stop();
      }
      if (currentState != WorkerState.stopped && currentState != WorkerState.crashed) {
        currentState = WorkerState.idle;
      }
      rethrow;
    } finally {
      _agentMessageDeltaIds.clear();
      _threadStartCompleter = null;
      _threadStartRequestId = null;
      _turnCompleter = null;
      _activeSessionId = null;
    }
  }

  Future<T> _stopAfterTurnTimeout<T>() {
    _log.warning('Turn timeout exceeded, stopping Codex...');
    _threadStartCompleter = null;
    _threadStartRequestId = null;
    _turnCompleter = null;
    return stop().then<T>((_) => throw TimeoutException('Codex turn exceeded $turnTimeout'));
  }

  @override
  Future<void> cancel() async {
    await _requestCancellation();
  }

  Future<ProcessTerminationResult?> _requestCancellation({Process? process}) async {
    final activeProcess = process ?? currentProcess;
    if (activeProcess == null) return null;
    beginIntentionalProcessTeardown(activeProcess, platformCapabilities);
    try {
      await activeProcess.stdin.close();
    } catch (_) {} // stdin may already be closed if the process exited.
    if (platformCapabilities.posixSignalsAvailable) {
      final result = ProcessTerminationResult(
        initialTerminationAccepted: activeProcess.kill(ProcessSignal.sigterm),
        exitConfirmed: false,
        hardTerminationUsed: false,
      );
      return result;
    }
    final result = await killWithEscalation(
      activeProcess,
      label: 'Codex',
      gracePeriod: _killGracePeriod,
      platformCapabilities: platformCapabilities,
      log: _log,
    );
    completeIntentionalProcessTeardown(activeProcess, result, platformCapabilities);
    return result;
  }

  @override
  Future<void> resetSessionContinuity(String sessionId) async {
    _threadIds.remove(sessionId);
  }

  @override
  Future<void> stop() {
    isStopping = true;
    beginIntentionalProcessTeardown(currentProcess, platformCapabilities);
    return withLock(_stopInternal);
  }

  Future<void> _stopInternal() async {
    final process = currentProcess;
    final wasBusy = currentState == WorkerState.busy;
    ProcessTerminationResult? cancellationResult;
    if (wasBusy) {
      cancellationResult = await _requestCancellation(process: process);
      await delayFactory(const Duration(milliseconds: 50));
    }

    currentState = WorkerState.stopped;
    _threadIds.clear();
    _completePendingWithError(StateError('CodexHarness stopped'));

    if (cancellationResult != null && !platformCapabilities.posixSignalsAvailable) {
      await cancelTrackedSubscriptions();
      if (process != null) completeIntentionalProcessTeardown(process, cancellationResult, platformCapabilities);
    } else {
      await shutdownCurrentProcess(
        label: 'Codex',
        gracePeriod: _killGracePeriod,
        platformCapabilities: platformCapabilities,
        initialTerminationAccepted: cancellationResult?.initialTerminationAccepted,
        process: process,
      );
    }
    if (process == null) {
      await _cleanupEnvironment();
      return;
    }

    await _cleanupEnvironment();
  }

  Future<void> _spawnProcess() async {
    final spawnEnvironment = <String, String>{...environment, ...?_environment?.environmentOverrides()};

    // Build app-server args with sandbox permissions from provider options.
    // The per-turn `sandbox` JSON-RPC parameter is ignored in app-server mode;
    // sandbox must be configured at process startup via `-c sandbox_permissions`.
    final args = ['app-server'];
    final sandboxOption = _stringProviderOption('sandbox');
    if (sandboxOption != null) {
      final permissions = _sandboxPermissions(sandboxOption);
      if (permissions != null) {
        args.addAll(['-c', 'sandbox_permissions=$permissions']);
        _log.info('Codex sandbox permissions: $permissions (from "$sandboxOption")');
      }
    }

    final process = await processFactory(
      executable,
      args,
      workingDirectory: cwd,
      environment: spawnEnvironment,
      includeParentEnvironment: false,
    );

    _log.info('Codex process spawned (pid: ${process.pid}, cwd: $cwd)');
    attachProcess(process, dropEmptyStdoutLines: true);
  }

  /// Maps DartClaw sandbox config values to Codex `sandbox_permissions` TOML arrays.
  Future<void> _restartAfterCrash() async {
    await cancelTrackedSubscriptions();
    _threadIds.clear();
    try {
      await _spawnProcess();
      await _initialize();
      currentState = WorkerState.idle;
    } catch (_) {
      await shutdownCurrentProcess(
        label: 'Codex',
        gracePeriod: _killGracePeriod,
        platformCapabilities: platformCapabilities,
      );
      currentState = WorkerState.crashed;
      rethrow;
    }
  }

  Future<void> _cleanupStartupFailure() async {
    currentState = WorkerState.stopped;
    _threadIds.clear();
    _completePendingWithError(StateError('CodexHarness startup failed'));

    await shutdownCurrentProcess(
      label: 'Codex',
      gracePeriod: _killGracePeriod,
      platformCapabilities: platformCapabilities,
    );

    await _cleanupEnvironment();
  }

  Future<void> _cleanupEnvironment() async {
    final environment = _environment;
    _environment = null;
    if (environment == null) {
      return;
    }
    await environment.cleanup();
  }

  Future<void> _initialize() async {
    final id = _nextJsonRpcId();
    _initializeRequestId = id;
    _initializeCompleter = Completer<Map<String, dynamic>>();
    _writeLine(adapter.buildInitializeRequest(id: id));
    try {
      await _initializeCompleter!.future.timeout(_initializeTimeout);
    } on TimeoutException {
      throw StateError('Codex initialize handshake timed out after ${_initializeTimeout.inSeconds}s');
    }
    _writeLine(adapter.buildInitializedNotification());
  }

  Future<String> _startThread(String sessionId) async {
    final id = _nextJsonRpcId();
    _threadStartRequestId = id;
    _threadStartCompleter = Completer<String>();
    // Per Codex issues #14068/#15310: thread/start must include sandbox +
    // approvalPolicy for reliable sandbox override in app-server mode.
    // Note: thread/start uses kebab-case values (e.g. "danger-full-access"),
    // unlike turn/start which uses camelCase in a sandboxPolicy object.
    final threadParams = <String, dynamic>{'thread_id': '$sessionId-thread-$id'};
    final sandboxOption = _stringProviderOption('sandbox');
    if (sandboxOption != null) {
      threadParams['sandbox'] = sandboxOption;
    }
    final approvalOption = _stringProviderOption('approval');
    if (approvalOption != null) {
      threadParams['approvalPolicy'] = approvalOption;
    }
    _writeLine(adapter.buildThreadStartRequest(id: id, params: threadParams));
    final threadId = await _threadStartCompleter!.future;
    _threadIds[sessionId] = threadId;
    return threadId;
  }

  @override
  void handleProcessStdoutLine(String line) {
    _emitCompletedAgentMessageFallback(line);
    _handlePendingResponse(line);

    final message = adapter.parseLine(line);
    if (message == null) {
      return;
    }

    switch (message) {
      case proto.TextDelta(:final text):
        emitEvent(DeltaEvent(text));

      case proto.ToolUse(:final name, :final id, :final input):
        _log.fine('Tool use: $name (id=$id)');
        emitEvent(ToolUseEvent(toolName: name, toolId: id, input: input));

      case proto.ToolResult(:final toolId, :final output, :final isError):
        if (isError) {
          _log.warning('Tool error (id=$toolId): ${output.length > 200 ? '${output.substring(0, 200)}...' : output}');
        }
        emitEvent(ToolResultEvent(toolId: toolId, output: output, isError: isError));

      case proto.ProgressMessage(:final text, :final kind):
        if (kind == 'provider_setup_warning') {
          _log.warning(text);
        }
        emitEvent(ProviderProgressBridgeEvent(kind: kind, text: text));

      case proto.SessionMetadataUpdate():
        break;

      case proto.ProtocolDiagnostic(:final message, :final method, :final updateType):
        if (method == 'mcpServer/startupStatus/updated' && updateType == 'failed') {
          _log.warning(message);
        }

      case proto.ControlRequest(:final requestId, :final subtype, :final data):
        _log.fine('Control request: $subtype (id=$requestId)');
        unawaited(_dispatchControlRequest(requestId, subtype, data, sessionId: _activeSessionId));

      case proto.TurnComplete(
        :final stopReason,
        :final inputTokens,
        :final outputTokens,
        :final cacheReadTokens,
        :final cacheWriteTokens,
      ):
        _log.info(
          'Turn complete: reason=$stopReason, '
          'tokens(in=${inputTokens ?? 0}, out=${outputTokens ?? 0}, '
          'cacheR=${cacheReadTokens ?? 0}, cacheW=${cacheWriteTokens ?? 0})',
        );
        final completer = _turnCompleter;
        if (completer != null && !completer.isCompleted) {
          final result = <String, dynamic>{'stop_reason': stopReason ?? 'completed'};
          if (stopReason == 'error') {
            final error = _extractTurnFailedError(line);
            if (error != null) {
              result['error'] = error;
            }
          } else {
            result['input_tokens'] = inputTokens ?? 0;
            result['output_tokens'] = outputTokens ?? 0;
            result['cache_read_tokens'] = cacheReadTokens ?? 0;
            result['cache_write_tokens'] = cacheWriteTokens ?? 0;
          }
          completer.complete(result);
        }

      case proto.SystemInit(:final contextWindow):
        _log.info('System init: contextWindow=$contextWindow');
        if (contextWindow != null) {
          emitEvent(SystemInitEvent(contextWindow: contextWindow));
        }

      case proto.CompactBoundary():
        // CompactBoundary is a Claude Code-specific wire format. Codex
        // compaction is handled via CodexProtocolAdapter. No-op here.
        break;

      case proto.CompactionStarted():
        _log.info('Compaction started');
        // TurnRunner translates bridge-level compaction signals into the
        // shared DartclawEvents stream for observers and alerts.
        emitEvent(CompactionStartingBridgeEvent());

      case proto.CompactionCompleted():
        _log.info('Compaction completed');
        // TurnRunner translates bridge-level compaction signals into the
        // shared DartclawEvents stream for observers and alerts.
        emitEvent(CompactionCompletedBridgeEvent());
    }
  }

  @override
  void handleProcessStderrLine(String line) {
    _log.warning('stderr: $line');
  }

  @override
  void handleUnexpectedProcessExit(int exitCode) {
    if (currentState == WorkerState.stopped || isStopping) {
      return;
    }
    _threadIds.clear();
    currentState = WorkerState.crashed;
    crashCount++;
    _completePendingWithError(StateError('Codex process exited with code $exitCode'));
  }

  void _emitCompletedAgentMessageFallback(String line) {
    final decoded = decodeJsonObject(line);
    if (decoded == null) {
      return;
    }

    final method = stringValue(decoded['method']);
    final params = mapValue(decoded['params']);
    if (method == 'item/agentMessage/delta') {
      final itemId = stringValue(params?['itemId']);
      if (itemId != null && itemId.isNotEmpty) {
        _agentMessageDeltaIds.add(itemId);
      }
      return;
    }

    if (method != 'item/completed') {
      return;
    }

    final item = mapValue(params?['item']);
    final itemType = stringValue(item?['type']);
    if (item == null || (itemType != 'agentMessage' && itemType != 'agent_message')) {
      return;
    }

    final itemId = stringValue(item['id']);
    if (itemId != null && _agentMessageDeltaIds.contains(itemId)) {
      return;
    }

    final text = stringValue(item['text']) ?? stringValue(item['delta']);
    if (text == null || text.isEmpty) {
      return;
    }
    emitEvent(DeltaEvent(text));
  }

  Future<void> _dispatchControlRequest(
    String requestId,
    String subtype,
    Map<String, dynamic> data, {
    String? sessionId,
  }) async {
    if (subtype != 'approval') {
      _log.fine('Ignoring unsupported Codex control request subtype: $subtype');
      return;
    }

    try {
      await _handleApprovalRequest(requestId, data, sessionId: sessionId);
    } catch (error, stackTrace) {
      _log.severe('Failed to handle Codex approval request $requestId: $error', error, stackTrace);
      if (_tryWriteApprovalResponse(requestId, allow: false, reason: 'Approval handler error: $error')) {
        emitEvent(ToolApprovalResolvedEvent(requestId: requestId));
      }
    }
  }

  Future<void> _handleApprovalRequest(String requestId, Map<String, dynamic> data, {String? sessionId}) async {
    final rawToolName = data['tool_name'] as String? ?? '';
    emitEvent(ToolApprovalWaitEvent(requestId: requestId, toolName: rawToolName));
    final providerToolInput = Map<String, dynamic>.from(mapValue(data['tool_input']) ?? const <String, dynamic>{});
    // Codex approval responses can only allow or deny; they cannot mutate the
    // provider's actual tool_input. Redact and normalize a DartClaw-side copy
    // so guards and audit logs never see raw credentials.
    final guardToolInput = _prepareGuardToolInput(rawToolName, providerToolInput);
    final kind = rawToolName == 'file_change' ? _inferFileChangeKind(guardToolInput) : null;
    final canonicalTool = adapter.mapToolName(rawToolName, kind: kind);
    final guardToolName = canonicalTool?.stableName ?? 'codex:$rawToolName';

    if (canonicalTool == null) {
      _log.warning('Falling back to unmapped Codex tool name: $rawToolName -> $guardToolName');
    }

    final chain = guardChain;
    if (chain != null) {
      try {
        final verdict = await chain.evaluateBeforeToolCall(
          guardToolName,
          guardToolInput,
          sessionId: sessionId,
          rawProviderToolName: rawToolName,
        );
        if (verdict.isBlock) {
          if (_tryWriteApprovalResponse(requestId, allow: false, reason: verdict.message)) {
            emitEvent(ToolApprovalResolvedEvent(requestId: requestId));
          }
          return;
        }
      } catch (error, stackTrace) {
        _log.severe('GuardChain evaluation failed for Codex approval $requestId: $error', error, stackTrace);
        if (_tryWriteApprovalResponse(requestId, allow: false, reason: 'Guard evaluation failed: $error')) {
          emitEvent(ToolApprovalResolvedEvent(requestId: requestId));
        }
        return;
      }
    }

    if (_tryWriteApprovalResponse(requestId, allow: true)) {
      emitEvent(ToolApprovalResolvedEvent(requestId: requestId));
    }
  }

  void _handlePendingResponse(String line) {
    final decoded = decodeJsonObject(line);
    if (decoded == null) {
      return;
    }

    final id = decoded['id'];
    final result = mapValue(decoded['result']);
    final error = decoded['error'];

    if (_initializeCompleter != null && !(_initializeCompleter!.isCompleted) && id == _initializeRequestId) {
      if (error != null) {
        _initializeCompleter!.completeError(StateError('Codex initialize failed: $error'));
      } else {
        _initializeCompleter!.complete(result ?? const <String, dynamic>{});
      }
      _initializeRequestId = null;
      _initializeCompleter = null;
    }

    if (_threadStartCompleter != null && !(_threadStartCompleter!.isCompleted) && id == _threadStartRequestId) {
      // Codex v0.118.0 may wrap the result in a ClientResponse envelope.
      // Support both flat (legacy) and nested (v0.118.0) shapes.
      final responseEnvelope = mapValue(result?['response']);
      final thread = mapValue(result?['thread']) ?? mapValue(responseEnvelope?['thread']);
      final threadId = result?['thread_id'] ?? result?['id'] ?? thread?['id'];
      if (error != null) {
        _threadStartCompleter!.completeError(StateError('Codex thread/start failed: $error'));
      } else if (threadId is String && threadId.isNotEmpty) {
        _threadStartCompleter!.complete(threadId);
      } else {
        _threadStartCompleter!.completeError(
          StateError('Codex thread/start response missing thread_id, id, or thread.id'),
        );
      }
      _threadStartRequestId = null;
      _threadStartCompleter = null;
    }
  }

  void _completePendingWithError(Object error) {
    final initializeCompleter = _initializeCompleter;
    if (initializeCompleter != null && !initializeCompleter.isCompleted) {
      initializeCompleter.completeError(error);
    }
    _initializeCompleter = null;
    _initializeRequestId = null;

    final threadStartCompleter = _threadStartCompleter;
    if (threadStartCompleter != null && !threadStartCompleter.isCompleted) {
      threadStartCompleter.completeError(error);
    }
    _threadStartCompleter = null;
    _threadStartRequestId = null;

    final turnCompleter = _turnCompleter;
    if (turnCompleter != null && !turnCompleter.isCompleted) {
      turnCompleter.completeError(error);
    }
  }

  int _nextJsonRpcId() {
    _nextRequestId += 1;
    return _nextRequestId;
  }

  bool _tryWriteApprovalResponse(String requestId, {required bool allow, String? reason}) {
    try {
      _writeLine(adapter.buildApprovalResponse(requestId, allow: allow, reason: reason));
      return true;
    } catch (error, stackTrace) {
      _log.severe('Failed to write Codex approval response for $requestId: $error', error, stackTrace);
      return false;
    }
  }

  void _writeLine(Map<String, dynamic> message) {
    writeJsonLine(message, processNotRunningMessage: 'Codex process is not running');
  }

  static String? _inferFileChangeKind(Map<String, dynamic> toolInput) {
    final directKind = toolInput['kind'];
    if (directKind is String && directKind.isNotEmpty) {
      return directKind;
    }

    final changes = toolInput['changes'];
    if (changes is List) {
      for (final change in changes) {
        final changeMap = mapValue(change);
        final nestedKind = changeMap?['kind'];
        if (nestedKind is String && nestedKind.isNotEmpty) {
          return nestedKind;
        }
      }
    }

    return null;
  }

  static Map<String, dynamic> _prepareGuardToolInput(String rawToolName, Map<String, dynamic> providerToolInput) {
    final guardToolInput = Map<String, dynamic>.from(providerToolInput);
    _stripCredentialEnvVars(guardToolInput);

    if (rawToolName != 'file_change') {
      return guardToolInput;
    }

    final primaryChange = _primaryFileChange(guardToolInput);
    final filePath = stringValue(guardToolInput['path']) ?? stringValue(primaryChange?['path']);
    if (filePath != null && filePath.isNotEmpty) {
      guardToolInput['file_path'] = filePath;
    }

    final kind = stringValue(guardToolInput['kind']) ?? stringValue(primaryChange?['kind']);
    if (kind != null && kind.isNotEmpty) {
      guardToolInput['kind'] = kind;
    }

    final oldString =
        stringValue(guardToolInput['old_string']) ??
        stringValue(guardToolInput['old_text']) ??
        stringValue(primaryChange?['old_string']) ??
        stringValue(primaryChange?['old_text']);
    if (oldString != null) {
      guardToolInput['old_string'] = oldString;
    }

    final newString =
        stringValue(guardToolInput['new_string']) ??
        stringValue(guardToolInput['new_text']) ??
        stringValue(primaryChange?['new_string']) ??
        stringValue(primaryChange?['new_text']);
    if (newString != null) {
      guardToolInput['new_string'] = newString;
    }

    return guardToolInput;
  }

  static Map<String, dynamic>? _primaryFileChange(Map<String, dynamic> toolInput) {
    final changes = toolInput['changes'];
    if (changes is! List) {
      return null;
    }

    for (final change in changes) {
      final changeMap = mapValue(change);
      if (changeMap != null) {
        return changeMap;
      }
    }

    return null;
  }

  static void _stripCredentialEnvVars(Map<String, dynamic> toolInput) {
    final envMap = mapValue(toolInput['env']);
    if (envMap == null) {
      return;
    }

    final sanitized = Map<String, dynamic>.from(envMap)
      ..remove('OPENAI_API_KEY')
      ..remove('CODEX_API_KEY');
    if (sanitized.length == envMap.length) {
      return;
    }

    toolInput['env'] = sanitized;
    _log.info('Stripped Codex API key environment variables from approval input env');
  }

  static String? _extractTurnFailedError(String line) {
    final decoded = decodeJsonObject(line);
    final params = mapValue(decoded?['params']);
    final turn = mapValue(params?['turn']);
    final error = params?['error'] ?? turn?['error'];

    if (error is String && error.isNotEmpty) {
      return error;
    }

    final errorMap = mapValue(error);
    final message = errorMap?['message'];
    if (message is String && message.isNotEmpty) {
      return message;
    }

    final topLevelMessage = params?['message'];
    if (topLevelMessage is String && topLevelMessage.isNotEmpty) {
      return topLevelMessage;
    }

    return null;
  }

  String? _stringProviderOption(String key) {
    final value = providerOptions[key];
    return value is String && value.trim().isNotEmpty ? value : null;
  }

  bool _boolProviderOption(String key, {required bool defaultValue}) {
    final value = providerOptions[key];
    if (value is bool) return value;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true') return true;
      if (normalized == 'false') return false;
    }
    return defaultValue;
  }
}
