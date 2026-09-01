import 'dart:async';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../bridge/bridge_events.dart';
import '../container/container_executor.dart';
import '../worker/worker_state.dart';

import 'agent_harness.dart';
import 'base_harness.dart';
import 'canonical_tool.dart';
import 'codex_environment.dart';
import 'codex_protocol_adapter.dart';
import 'codex_protocol_utils.dart';
import 'codex_settings.dart';
import 'harness_launch_options.dart';
import 'process_lifecycle.dart';
import 'process_types.dart';
import 'protocol_message.dart' as proto;

Duration _remainingUntil(DateTime deadline) {
  final remaining = deadline.difference(DateTime.now());
  return remaining > Duration.zero ? remaining : Duration.zero;
}

Future<T> _withinTurnDeadline<T>(
  Future<T> operation,
  DateTime? deadline, {
  required FutureOr<T> Function() onTimeout,
}) => deadline == null ? operation : operation.timeout(_remainingUntil(deadline), onTimeout: onTimeout);

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

  /// Request-scoped environment passed only to a containerized Codex subprocess.
  final Map<String, String> containerEnvironment;

  /// Provider-specific options used for Codex request settings translation.
  final Map<String, dynamic> providerOptions;

  /// Optional guard chain used to evaluate approval requests.
  final GuardChain? guardChain;

  /// Codex protocol adapter used for all wire-format translation.
  final CodexProtocolAdapter adapter;

  /// Platform policy used for executable lookup and process semantics.
  final PlatformCapabilities platformCapabilities;

  /// Container selected by effective policy, or `null` for host execution.
  /// A configured container must execute there or fail; placement is never inferred.
  final ContainerExecutor? containerManager;

  /// Makes the DartClaw-dedicated `CODEX_HOME` usable and returns its path, or
  /// `null` when this deployment presents an API key instead. Awaited before
  /// every host spawn so the vendor CLI starts on a token that is not about to
  /// expire; the refresh authority behind it is the only thing that rotates the
  /// store.
  final Future<String?> Function()? prepareSubscriptionHome;

  static final _log = Logger('CodexHarness');

  final Map<String, ({String threadId, String? instructions})> _threads = {};
  String? _activeSessionId;
  String? _activeAgentId;
  int _nextRequestId = 0;
  Object? _initializeRequestId;
  ({Object id, String method, Completer<String> completer})? _threadRequest;
  Completer<Map<String, dynamic>>? _initializeCompleter;
  Completer<TurnResult>? _turnCompleter;
  final Set<String> _agentMessageDeltaIds = <String>{};
  CodexEnvironment? _environment;
  String? _activeProviderSessionId;

  /// Grace period after SIGTERM before escalating to SIGKILL.
  final Duration _killGracePeriod;
  final Duration _initializeTimeout;

  new({
    required super.cwd,
    this.executable = 'codex',
    super.turnTimeout = const Duration(seconds: 1800),
    super.maxRetries = 5,
    super.baseBackoff = const Duration(seconds: 5),
    ProcessFactory? processFactory,
    CommandProbe? commandProbe,
    DelayFactory? delayFactory,
    Map<String, String>? environment,
    Map<String, String> containerEnvironment = const {},
    super.harnessConfig = const HarnessLaunchOptions(),
    Map<String, dynamic>? providerOptions,
    this.guardChain,
    CodexProtocolAdapter? adapter,
    PlatformCapabilities? platformCapabilities,
    this.containerManager,
    this.prepareSubscriptionHome,
    Duration killGracePeriod = const Duration(seconds: 2),
    Duration initializeTimeout = const Duration(seconds: 10),
  }) : environment = environment ?? Platform.environment,
       containerEnvironment = Map.unmodifiable(containerEnvironment),
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
  bool get supportsProviderSessionResume => _environment?.supportsProviderSessionResume ?? false;

  /// `turn/start` accepts an output-schema param, but the app server returns the
  /// final assistant message as plain text with no field distinguishing a
  /// schema-validated payload from ordinary prose. Recovering one would mean
  /// parsing that text, which is a heuristic rather than enforcement evidence,
  /// so support is refused rather than claimed on a forwarded key.
  @override
  bool get supportsStructuredOutput => false;

  @override
  String skillActivationLine(String skill) => '\$$skill';

  String? get _effectiveSandbox => containerManager == null ? _stringProviderOption('sandbox') : 'danger-full-access';

  @override
  Future<void> start() => startLifecycle(
    busyMessage: 'Cannot start CodexHarness while busy',
    beforeStart: () async {
      isStopping = false;
      await _cleanupEnvironment();
      if (containerManager == null) {
        await _verifyCodexExecutable(executable, commandProbe);
      }
    },
    start: () async {
      try {
        await _prepareEnvironment();
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

  /// Builds the Codex home lifecycle for the effective execution location.
  ///
  /// The container is started first: its generated-state mount has to exist
  /// before the auth-clean home can be written into it.
  Future<void> _prepareEnvironment() async {
    final container = containerManager;
    if (container == null) {
      // A subscription-resolved deployment runs against the DartClaw-dedicated
      // store instead of the operator's login or a home seeded from it, so
      // `use_system_codex_home` does not apply and no seeding step runs.
      final dedicatedHome = await prepareSubscriptionHome?.call();
      _environment = dedicatedHome != null
          ? CodexEnvironment.dedicated(
              developerInstructions: harnessConfig.appendSystemPrompt ?? '',
              homePath: dedicatedHome,
              mcpServerUrl: harnessConfig.mcpServerUrl,
              mcpGatewayToken: harnessConfig.mcpGatewayToken,
              platformCapabilities: platformCapabilities,
            )
          : CodexEnvironment(
              developerInstructions: harnessConfig.appendSystemPrompt ?? '',
              mcpServerUrl: harnessConfig.mcpServerUrl,
              mcpGatewayToken: harnessConfig.mcpGatewayToken,
              useSystemCodexHome: _boolProviderOption('use_system_codex_home', defaultValue: true),
              platformCapabilities: platformCapabilities,
            );
      return;
    }

    await container.start();
    if (!await containerExecutableRuns(container, _containerExecutable)) {
      _throwMissingCodexExecutable('$_containerExecutable (container ${container.profileId})');
    }
    final hostHome = p.join(container.generatedStateDir, 'codex-home');
    final containerHome = container.containerPathForHostPath(hostHome);
    if (containerHome == null) {
      throw StateError('Codex container home is not mounted in the container: $hostHome');
    }
    _environment = CodexEnvironment.containerAuthClean(
      developerInstructions: harnessConfig.appendSystemPrompt ?? '',
      hostHomePath: hostHome,
      containerHomePath: containerHome,
      gatewayBaseUrl: '${container.providerBridgeUrl}/v1',
      // Provider-side web search escapes `network:none` because it runs at the
      // provider. Host mediation refuses it for every containerized execution;
      // turning it off here keeps the client from asking.
      nativeWebSearch: false,
      mcpServerUrl: container.mcpBridgeUrl,
      platformCapabilities: platformCapabilities,
    );
  }

  /// The binary the container image ships, unless an absolute path was pinned.
  String get _containerExecutable => executable.contains('/') ? executable : containerCodexExecutable;

  /// Where the harness's own process runs.
  ///
  /// A restricted container deliberately mounts no workspace, so an unmapped
  /// default cwd is the expected state, not an error: it resolves to the
  /// profile's own working directory rather than leaking a host path into the
  /// container.
  String _resolveDefaultWorkingDirectory() {
    final container = containerManager;
    if (container == null) return cwd;
    return container.containerPathForHostPath(cwd) ?? container.workingDir;
  }

  /// Translates a directory a turn explicitly asked for, refusing an unmounted
  /// one rather than silently running somewhere else.
  String _resolveRequestedWorkingDirectory(String hostDirectory) {
    final container = containerManager;
    if (container == null) return hostDirectory;
    final translated = container.containerPathForHostPath(hostDirectory);
    if (translated == null) {
      throw StateError('Requested working directory is not mounted in the container: $hostDirectory');
    }
    return translated;
  }

  @override
  Future<TurnResult> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    String? agentId,
    Map<String, dynamic>? mcpServers,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
  }) async {
    AgentHarness.requireStructuredOutputSupport(this, outputSchema);
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
    if ((providerSessionId != null || requestProviderSessionResume) && !supportsProviderSessionResume) {
      throw const UnsupportedHarnessCapabilityException(
        provider: 'CodexHarness (non-durable CODEX_HOME)',
        capability: AgentHarness.providerSessionResumeCapability,
      );
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
    _activeAgentId = agentId;
    _turnCompleter = Completer<TurnResult>();
    final stopwatch = Stopwatch();
    final effectiveTimeout = effectiveTurnTimeout;
    final deadline = effectiveTimeout > Duration.zero ? DateTime.now().add(effectiveTimeout) : null;

    try {
      final scopedInstructions = systemPrompt.trim().isEmpty ? null : systemPrompt;
      var thread = _threads[sessionId];
      thread = providerSessionId != null && thread?.threadId != providerSessionId ? null : thread;
      if (providerSessionId == null && thread != null && thread.instructions != scopedInstructions) {
        _threads.remove(sessionId);
        thread = null;
      }
      final threadId =
          thread?.threadId ??
          await _withinTurnDeadline(
            _openThread(sessionId, scopedInstructions, providerSessionId),
            deadline,
            onTimeout: () => _stopAfterTurnTimeout<String>(effectiveTimeout),
          );
      if (providerSessionId != null || requestProviderSessionResume) _activeProviderSessionId = threadId;

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
          effort: effort ?? harnessConfig.effort,
          cwd: directory == null || directory.trim().isEmpty ? null : _resolveRequestedWorkingDirectory(directory),
          sandbox: _effectiveSandbox,
          approval: _stringProviderOption('approval'),
        ),
      );
      payload['id'] = ++_nextRequestId;
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

      final result = await _withinTurnDeadline(
        _turnCompleter!.future,
        deadline,
        onTimeout: () => _stopAfterTurnTimeout<TurnResult>(effectiveTimeout),
      );
      if (stopwatch.isRunning) {
        stopwatch.stop();
      }
      _log.info('Turn finished in ${stopwatch.elapsedMilliseconds}ms');
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
      _threadRequest = null;
      _turnCompleter = null;
      _activeSessionId = null;
      _activeAgentId = null;
      _activeProviderSessionId = null;
    }
  }

  Future<T> _stopAfterTurnTimeout<T>(Duration effectiveTimeout) {
    _log.warning('Turn timeout exceeded, stopping Codex...');
    _threadRequest = null;
    _turnCompleter = null;
    return stop().then<T>((_) => throw TimeoutException('Codex turn exceeded $effectiveTimeout'));
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
    _threads.remove(sessionId);
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
    _threads.clear();
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
    // Build app-server args with sandbox permissions from provider options.
    // The per-turn `sandbox` JSON-RPC parameter is ignored in app-server mode;
    // sandbox must be configured at process startup via `-c sandbox_permissions`.
    final args = ['app-server'];
    final container = containerManager;
    // Containerized spawns always run danger-full-access: the container is the
    // isolation boundary, and Codex's own sandbox tooling can neither ship in
    // the image nor start under the hardening – honoring a stricter configured
    // value would fail every tool call while the turn still reports success
    // (security-architecture.md § Multi-Provider Sandbox Interaction). Host
    // approvals/guards stay active either way.
    final sandboxOption = _effectiveSandbox;
    if (sandboxOption != null) {
      final permissions = _sandboxPermissions(sandboxOption);
      if (permissions != null) {
        args.addAll(['-c', 'sandbox_permissions=$permissions']);
        _log.info('Codex sandbox permissions: $permissions (from "$sandboxOption")');
      }
    }

    final workingDirectory = _resolveDefaultWorkingDirectory();
    final Process process;
    if (container == null) {
      process = await processFactory(
        executable,
        args,
        workingDirectory: workingDirectory,
        environment: <String, String>{...environment, ...?_environment?.environmentOverrides()},
        includeParentEnvironment: false,
      );
    } else {
      // Only sanitized request extras and the generated home cross the boundary.
      process = await container.exec(
        [_containerExecutable, ...args],
        workingDirectory: workingDirectory,
        env: {...containerEnvironment, ...?_environment?.environmentOverrides()},
      );
    }

    _log.info('Codex process spawned (pid: ${process.pid}, cwd: $workingDirectory)');
    attachProcess(process, dropEmptyStdoutLines: true);
  }

  /// Maps DartClaw sandbox config values to Codex `sandbox_permissions` TOML arrays.
  Future<void> _restartAfterCrash() async {
    await cancelTrackedSubscriptions();
    _threads.clear();
    try {
      // Same path as a cold start, so a restart re-verifies the container and
      // rebuilds its auth-clean home instead of respawning against whatever
      // state the crashed process left behind.
      await _cleanupEnvironment();
      await _prepareEnvironment();
      await _environment!.setup();
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
    _threads.clear();
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
    final id = ++_nextRequestId;
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

  Future<String> _openThread(String sessionId, String? developerInstructions, String? providerSessionId) async {
    final id = ++_nextRequestId;
    final completer = Completer<String>();
    final method = providerSessionId == null ? 'thread/start' : 'thread/resume';
    _threadRequest = (id: id, method: method, completer: completer);
    if (providerSessionId != null) {
      _writeLine(adapter.buildThreadResumeRequest(id: id, threadId: providerSessionId));
    } else {
      final params = <String, dynamic>{'thread_id': '$sessionId-thread-$id'};
      if (developerInstructions != null) params['developerInstructions'] = developerInstructions;
      final sandbox = _effectiveSandbox;
      if (sandbox != null) params['sandbox'] = sandbox;
      final approval = _stringProviderOption('approval');
      if (approval != null) params['approvalPolicy'] = approval;
      _writeLine(adapter.buildThreadStartRequest(id: id, params: params));
    }
    final threadId = await completer.future;
    if (providerSessionId != null && threadId != providerSessionId) {
      throw StateError('Codex thread/resume returned $threadId, requested $providerSessionId');
    }
    _threads[sessionId] = (threadId: threadId, instructions: developerInstructions);
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

      case proto.ToolResultMessage(:final toolId, :final output, :final isError):
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
        unawaited(
          _dispatchControlRequest(requestId, subtype, data, sessionId: _activeSessionId, agentId: _activeAgentId),
        );

      case proto.TurnComplete(
        :final stopReason,
        :final finalText,
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
          // Codex reports no usage alongside a failure, so the error arm leaves
          // the token counts at zero rather than attributing stale ones.
          completer.complete(
            stopReason == 'error'
                ? TurnResult(
                    stopReason: stopReason,
                    error: _extractTurnFailedError(line),
                    providerSessionId: _activeProviderSessionId,
                  )
                : TurnResult(
                    stopReason: stopReason ?? 'completed',
                    finalText: finalText,
                    providerSessionId: _activeProviderSessionId,
                    inputTokens: inputTokens ?? 0,
                    outputTokens: outputTokens ?? 0,
                    cacheReadTokens: cacheReadTokens ?? 0,
                    cacheWriteTokens: cacheWriteTokens ?? 0,
                  ),
          );
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
    _threads.clear();
    currentState = WorkerState.crashed;
    crashCount++;
    _completePendingWithError(streamFailure ?? StateError('Codex process exited with code $exitCode'));
  }

  @override
  Future<void> shutdownAfterStreamFailure() =>
      shutdownCurrentProcess(label: 'Codex', gracePeriod: _killGracePeriod, platformCapabilities: platformCapabilities);

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
    String? agentId,
  }) async {
    if (subtype == 'unsupported_elicitation' ||
        subtype == 'unsupported_permission_request' ||
        subtype == 'unsupported_command_request' ||
        subtype == 'unsupported_server_request') {
      if (subtype == 'unsupported_command_request') {
        _log.warning('Declining unsupported Codex command request: ${data['dartclawUnsupportedReasons']}');
      }
      emitEvent(ToolApprovalWaitEvent(requestId: requestId, toolName: subtype));
      if (_tryWriteApprovalResponse(requestId, allow: false, reason: 'Unsupported Codex request')) {
        emitEvent(ToolApprovalResolvedEvent(requestId: requestId));
      }
      return;
    }
    if (subtype != 'approval') {
      _log.fine('Ignoring unsupported Codex control request subtype: $subtype');
      return;
    }

    try {
      await _handleApprovalRequest(requestId, data, sessionId: sessionId, agentId: agentId);
    } catch (error, stackTrace) {
      _log.severe('Failed to handle Codex approval request $requestId: $error', error, stackTrace);
      if (_tryWriteApprovalResponse(requestId, allow: false, reason: 'Approval handler error: $error')) {
        emitEvent(ToolApprovalResolvedEvent(requestId: requestId));
      }
    }
  }

  Future<void> _handleApprovalRequest(
    String requestId,
    Map<String, dynamic> data, {
    String? sessionId,
    String? agentId,
  }) async {
    final rawToolName = data['tool_name'] as String? ?? '';
    emitEvent(ToolApprovalWaitEvent(requestId: requestId, toolName: rawToolName));
    final providerToolInput = Map<String, dynamic>.from(mapValue(data['tool_input']) ?? const <String, dynamic>{});
    final evaluations = rawToolName == 'file_change'
        ? _fileChangeGuardEvaluations(providerToolInput)
        : [_guardEvaluation(rawToolName, providerToolInput)];
    if (evaluations == null || evaluations.isEmpty) {
      if (_tryWriteApprovalResponse(requestId, allow: false, reason: 'File change context is incomplete')) {
        emitEvent(ToolApprovalResolvedEvent(requestId: requestId));
      }
      return;
    }

    final chain = guardChain;
    if (chain != null) {
      try {
        for (final evaluation in evaluations) {
          final verdict = await chain.evaluateBeforeToolCall(
            evaluation.$1,
            evaluation.$2,
            sessionId: sessionId,
            agentId: agentId,
            rawProviderToolName: rawToolName,
          );
          if (verdict.isBlock) {
            if (_tryWriteApprovalResponse(requestId, allow: false, reason: verdict.message)) {
              emitEvent(ToolApprovalResolvedEvent(requestId: requestId));
            }
            return;
          }
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

  (String, Map<String, dynamic>) _guardEvaluation(String rawToolName, Map<String, dynamic> providerToolInput) {
    final canonicalTool = adapter.mapToolName(
      rawToolName,
      mcpServer: stringValue(providerToolInput['server']),
      mcpTool: stringValue(providerToolInput['tool']),
    );
    final semanticMcpArguments = rawToolName == 'mcp_tool_call' && canonicalTool != CanonicalTool.mcpCall
        ? mapValue(providerToolInput['arguments'])
        : null;
    final guardToolInput = _prepareGuardToolInput(rawToolName, semanticMcpArguments ?? providerToolInput);
    final guardToolName = canonicalTool?.stableName ?? 'codex:$rawToolName';
    if (canonicalTool == null) {
      _log.warning('Falling back to unmapped Codex tool name: $rawToolName -> $guardToolName');
    }
    return (guardToolName, guardToolInput);
  }

  List<(String, Map<String, dynamic>)>? _fileChangeGuardEvaluations(Map<String, dynamic> providerToolInput) {
    if (stringValue(providerToolInput['grantRoot']) case final grantRoot? when grantRoot.isNotEmpty) {
      return null;
    }
    final rawChanges = providerToolInput['changes'];
    final changes = rawChanges is List
        ? rawChanges.map(mapValue).whereType<Map<String, dynamic>>().toList()
        : [providerToolInput];
    if (changes.isEmpty || (rawChanges is List && changes.length != rawChanges.length)) {
      return null;
    }

    final evaluations = <(String, Map<String, dynamic>)>[];
    for (final change in changes) {
      final kind = codexFileChangeKind(change['kind']);
      final path = stringValue(change['path']);
      final movePath = stringValue(mapValue(change['kind'])?['move_path']);
      final canonicalTool = switch (kind) {
        'add' || 'create' => CanonicalTool.fileWrite,
        'modify' || 'update' => CanonicalTool.fileEdit,
        _ => null,
      };
      if (canonicalTool == null || path == null || path.isEmpty || (movePath != null && movePath.isNotEmpty)) {
        return null;
      }
      final input = Map<String, dynamic>.from(change)..['kind'] = kind;
      evaluations.add((canonicalTool.stableName, _prepareGuardToolInput('file_change', input)));
    }
    return evaluations;
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

    final pendingThread = _threadRequest;
    if (pendingThread != null && !pendingThread.completer.isCompleted && id == pendingThread.id) {
      // Codex v0.118.0 may wrap the result in a ClientResponse envelope.
      // Support both flat (legacy) and nested (v0.118.0) shapes.
      final responseEnvelope = mapValue(result?['response']);
      final thread = mapValue(result?['thread']) ?? mapValue(responseEnvelope?['thread']);
      final threadId = result?['thread_id'] ?? result?['id'] ?? thread?['id'];
      if (error != null) {
        pendingThread.completer.completeError(StateError('Codex ${pendingThread.method} failed: $error'));
      } else if (threadId is String && threadId.isNotEmpty) {
        pendingThread.completer.complete(threadId);
      } else {
        pendingThread.completer.completeError(
          StateError('Codex ${pendingThread.method} response missing thread_id, id, or thread.id'),
        );
      }
      _threadRequest = null;
    }
  }

  void _completePendingWithError(Object error) {
    final initializeCompleter = _initializeCompleter;
    if (initializeCompleter != null && !initializeCompleter.isCompleted) {
      initializeCompleter.completeError(error);
    }
    _initializeCompleter = null;
    _initializeRequestId = null;

    final threadRequest = _threadRequest;
    if (threadRequest != null && !threadRequest.completer.isCompleted) threadRequest.completer.completeError(error);
    _threadRequest = null;

    final turnCompleter = _turnCompleter;
    if (turnCompleter != null && !turnCompleter.isCompleted) {
      turnCompleter.completeError(error);
    }
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
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
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
