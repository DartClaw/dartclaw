import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/dartclaw_core.dart' as proto;
import 'package:logging/logging.dart';

import 'acp_client.dart';
import 'acp_errors.dart';
import 'acp_protocol_adapter.dart';
import 'acp_reverse_call_handlers.dart';

part 'acp_harness_presentation.dart';

/// Minimal subprocess-backed ACP harness.
final class AcpHarness extends AgentHarness
    with SequentialLock, ProcessLifecycleOwner
    implements HarnessTurnContextSink {
  /// Working directory used for the ACP subprocess and session.
  final String cwd;

  /// ACP binary path or executable name.
  final String executable;

  /// Arguments passed to [executable].
  final List<String> arguments;

  /// Environment passed to the ACP subprocess.
  final Map<String, String> environment;

  /// Optional container boundary for container-isolation-only ACP agents.
  final ContainerExecutor? containerManager;

  /// Maximum time allowed for one prompt.
  final Duration turnTimeout;

  /// Limits applied when replaying persisted DartClaw history into fresh ACP sessions.
  final HistoryConfig historyConfig;

  final ProcessFactory _processFactory;
  final PlatformCapabilities _platformCapabilities;
  final Duration _terminationGracePeriod;
  final Duration _initializeTimeout;
  final GuardChain? guardChain;
  final AcpPermissionDecision? permissionDecision;
  final AcpReverseCallAuditSink? onReverseCallAudit;
  final StreamController<BridgeEvent> _eventsController = StreamController<BridgeEvent>.broadcast();
  final AcpProtocolAdapter _adapter;
  List<int> _stderrDiagnostics = const [];
  bool _stderrDiagnosticsTruncated = false;
  String? _activeSessionTitle;
  int? _activeInputTokens;
  int? _activeOutputTokens;
  int? _activeCacheReadTokens;
  int? _activeCacheWriteTokens;

  static final _log = Logger('AcpHarness');

  /// Maximum bytes retained from recent ACP stderr output.
  static const int retainedDiagnosticsLimitBytes = 64 * 1024;
  static const String _diagnosticsTruncatedMarker = '[... earlier stderr truncated ...]\n';
  static final int _diagnosticsTruncatedMarkerBytes = utf8.encode(_diagnosticsTruncatedMarker).length;

  WorkerState _state = WorkerState.stopped;
  AcpClient? _client;
  String? _activeAcpSessionId;
  Completer<void>? _activeTurnCompleter;
  AcpReverseCallHandlers? _reverseCallHandlers;
  bool _stopping = false;
  bool _disposed = false;
  HarnessTurnContext? _activeTurnContext;

  @override
  void setTurnContext(HarnessTurnContext? context) {
    _activeTurnContext = context;
  }

  /// Creates an ACP harness.
  new({
    required this.cwd,
    this.executable = 'goose',
    this.arguments = const <String>[],
    this.turnTimeout = const Duration(seconds: 1800),
    this.historyConfig = const HistoryConfig.defaults(),
    ProcessFactory? processFactory,
    AcpProtocolAdapter? adapter,
    this.guardChain,
    this.permissionDecision,
    this.onReverseCallAudit,
    this.containerManager,
    Map<String, String>? environment,
    PlatformCapabilities? platformCapabilities,
    Duration terminationGracePeriod = const Duration(seconds: 2),
    Duration initializeTimeout = const Duration(seconds: 10),
  }) : _processFactory = processFactory ?? Process.start,
       _platformCapabilities = platformCapabilities ?? PlatformCapabilities(),
       _terminationGracePeriod = terminationGracePeriod,
       _initializeTimeout = initializeTimeout,
       _adapter = adapter ?? AcpProtocolAdapter(),
       environment = Map<String, String>.unmodifiable(environment ?? Platform.environment);

  @override
  WorkerState get state => _state;

  @override
  bool get isRootProcessTerminationConfirmed => currentProcess == null;

  @override
  Logger get processLifecycleLog => _log;

  @override
  Stream<BridgeEvent> get events => _eventsController.stream;

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  @override
  bool get supportsCostReporting => false;

  @override
  bool get supportsToolApproval => false;

  @override
  bool get supportsStreaming => true;

  @override
  bool get supportsCachedTokens => true;

  @override
  bool get supportsSessionContinuity => false;

  /// ACP's `session/prompt` has no output-schema field, so a schema handed here
  /// could only be dropped.
  @override
  bool get supportsStructuredOutput => false;

  @override
  bool get supportsProviderSessionResume => false;

  @override
  bool get supportsPreCompactHook => false;

  @override
  String skillActivationLine(String skill) => AgentHarness.defaultSkillActivationLine(skill);

  @override
  Future<void> start() => withLock(_startInternal);

  Future<void> _startInternal() async {
    if (_disposed) {
      throw StateError('AcpHarness has been disposed');
    }
    if (_state == WorkerState.idle) {
      return;
    }
    if (_state == WorkerState.busy) {
      throw StateError('Cannot start AcpHarness while busy');
    }
    if (currentProcess != null) {
      throw StateError('Cannot start AcpHarness while previous process exit is unconfirmed');
    }
    if (_reverseCallHandlers?.ownsTerminals ?? false) {
      throw StateError('Cannot start AcpHarness while terminal process exit is unconfirmed');
    }

    _stopping = false;
    _state = WorkerState.busy;
    try {
      final process = await _spawnProcess();
      currentProcess = process;
      _collectStderr(process);
      watchOwnedProcessExit(process, (code) {
        if (_stopping || _state == WorkerState.stopped) return;
        _state = WorkerState.crashed;
        final completer = _activeTurnCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.completeError(
            AcpHarnessException(
              AcpHarnessErrorCode.processExited,
              'ACP process exited with code $code',
              diagnostics: _diagnostics(exitCode: code),
            ),
          );
        }
      });
      final reverseCallHandlers = containerManager == null
          ? AcpReverseCallHandlers(
              guardChain: guardChain,
              permissionDecision: permissionDecision,
              onAudit: onReverseCallAudit,
            )
          : null;
      _reverseCallHandlers = reverseCallHandlers;
      final client = AcpClient(
        process.stdout,
        process.stdin,
        onSessionUpdate: _handleSessionUpdate,
        onMalformedLine: _handleMalformedLine,
        onStreamError: (error) => _failStream(process, 'stdout', error),
        reverseCallHandlers: reverseCallHandlers,
      );
      _client = client;
      await client.initialize().timeout(_initializeTimeout);
      _state = WorkerState.idle;
    } on AcpHarnessException {
      await _cleanupAfterStartupFailure();
      rethrow;
    } catch (error) {
      await _cleanupAfterStartupFailure();
      throw AcpHarnessException(
        AcpHarnessErrorCode.initFailed,
        'ACP initialize failed',
        diagnostics: {'error': '$error', ..._diagnostics()},
      );
    }
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
    if (providerSessionId != null || requestProviderSessionResume) {
      throw const AcpHarnessException(
        AcpHarnessErrorCode.unsupportedCapability,
        'ACP does not support provider session resume',
      );
    }
    AgentHarness.requireStructuredOutputSupport(this, outputSchema);
    final effectiveDirectory = directory ?? cwd;
    final activeTurn = await withLock(() async {
      if (_state != WorkerState.idle) {
        throw StateError('AcpHarness is not idle (state: $_state)');
      }
      final client = _client;
      if (client == null) {
        throw StateError('AcpHarness has not completed startup');
      }
      if (messages.isEmpty) {
        throw StateError('AcpHarness requires at least one message');
      }

      final reverseCallHandlers = _reverseCallHandlers;
      reverseCallHandlers?.bindTurn(sessionId: sessionId, agentId: agentId, effectiveDirectory: effectiveDirectory);
      _state = WorkerState.busy;
      _activeTurnCompleter = Completer<void>();
      _resetActiveMetadata();
      return (client: client, reverseCallHandlers: reverseCallHandlers);
    });
    final client = activeTurn.client;
    final effectiveTimeout = _activeTurnContext?.turnTimeout ?? turnTimeout;
    final deadline = effectiveTimeout > Duration.zero ? DateTime.now().add(effectiveTimeout) : null;

    try {
      final interruptedSession = _activeTurnCompleter!.future.then<String?>((_) => null);
      final acpSessionId = await _withinTurnDeadline(
        Future.any<String?>([
          client.createSession(cwd: effectiveDirectory).then<String?>((sessionId) => sessionId),
          interruptedSession,
        ]),
        deadline,
      );
      if (acpSessionId == null) {
        const result = AcpPromptResult(text: '', stopReason: 'cancelled');
        _emitProtocolMessages(_adapter.messagesForPromptResult(result));
        await stop();
        return const TurnResult(stopReason: 'cancelled');
      }
      _activeAcpSessionId = acpSessionId;
      TurnResult? response;
      var terminateAfterTurn = false;
      AcpHarnessException? promptError;
      try {
        final currentMessage = _messageText(messages.last['content']);
        final priorMessages = messages.length > 1
            ? messages.sublist(0, messages.length - 1)
            : const <Map<String, dynamic>>[];
        final history = buildReplaySafeHistory(priorMessages, historyConfig);
        final effectiveMessage = history.isEmpty ? currentMessage : '$history\n\n$currentMessage';
        final prompt = _promptText(effectiveMessage, systemPrompt);
        final promptFuture = client.prompt(sessionId: acpSessionId, text: prompt);
        final cancelOrCrashFuture = _activeTurnCompleter!.future.then(
          (_) => const AcpPromptResult(text: '', stopReason: 'cancelled'),
        );
        final result = await _withinTurnDeadline(Future.any([promptFuture, cancelOrCrashFuture]), deadline);
        _emitProtocolMessages(_adapter.messagesForPromptResult(result));
        terminateAfterTurn = result.stopReason == 'cancelled';
        // Assistant text leaves through _emitProtocolMessages above; carrying it
        // on the result too would reintroduce a field no other provider sets.
        response = TurnResult(
          stopReason: result.stopReason,
          sessionTitle: result.sessionTitle ?? _activeSessionTitle,
          inputTokens: result.inputTokens ?? _activeInputTokens ?? 0,
          outputTokens: result.outputTokens ?? _activeOutputTokens ?? 0,
          cacheReadTokens: result.cacheReadTokens ?? _activeCacheReadTokens ?? 0,
          cacheWriteTokens: result.cacheWriteTokens ?? _activeCacheWriteTokens ?? 0,
        );
      } on AcpHarnessException catch (error) {
        promptError = error;
        rethrow;
      } finally {
        final terminalCloseTimeout = terminateAfterTurn || promptError?.errorCode == AcpHarnessErrorCode.authRequired
            ? const Duration(milliseconds: 250)
            : deadline == null
            ? null
            : _remainingUntil(deadline);
        if (identical(_client, client)) {
          await _closeSession(client, acpSessionId, timeout: terminalCloseTimeout);
        }
        await _reverseCallHandlers?.disposeTerminals();
      }
      if (terminateAfterTurn) {
        await stop();
      }
      return response;
    } catch (error) {
      if (error is TimeoutException) {
        final stopFuture = stop();
        await stopFuture;
      }
      if (error is AcpHarnessException) {
        if (error.errorCode == AcpHarnessErrorCode.authRequired) {
          await stop();
        }
        rethrow;
      }
      // The typed fault all three harnesses raise, so one caller branch names it.
      if (error is ProcessStreamException) rethrow;
      throw AcpHarnessException(
        AcpHarnessErrorCode.processExited,
        'ACP turn failed',
        diagnostics: {'error': '$error', ..._diagnostics()},
      );
    } finally {
      _activeAcpSessionId = null;
      _activeTurnCompleter = null;
      await activeTurn.reverseCallHandlers?.unbindTurn(sessionId);
      _resetActiveMetadata();
      if (_state != WorkerState.stopped && _state != WorkerState.crashed) {
        _state = WorkerState.idle;
      }
    }
  }

  @override
  Future<void> cancel() async {
    final activeTurn = _activeTurnCompleter;
    if (activeTurn == null) {
      return;
    }
    final activeSessionId = _activeAcpSessionId;
    final client = _client;
    if (activeSessionId != null && client != null) {
      await _cancelSession(client, activeSessionId, timeout: const Duration(milliseconds: 250));
    }
    _completeActiveTurn();
    if (activeSessionId == null) {
      await stop();
    }
  }

  @override
  Future<void> resetSessionContinuity(String sessionId) async {}

  @override
  Future<void> stop() {
    _stopping = true;
    beginIntentionalProcessTeardown(currentProcess, _platformCapabilities);
    return withLock(_stopInternal);
  }

  Future<void> _stopInternal() async {
    if (_state == WorkerState.stopped && currentProcess == null && !(_reverseCallHandlers?.ownsTerminals ?? false)) {
      return;
    }
    final process = currentProcess;
    beginIntentionalProcessTeardown(process, _platformCapabilities);
    final client = _client;
    _client = null;
    if (client != null) {
      await _cancelAndCloseActiveSession(client);
      try {
        await client.close();
      } catch (error) {
        _log.fine('ACP peer close failed: $error');
      }
    }
    final reverseCallHandlers = _reverseCallHandlers;
    if (reverseCallHandlers != null) {
      await reverseCallHandlers.disposeTerminals();
      if (!reverseCallHandlers.ownsTerminals && identical(_reverseCallHandlers, reverseCallHandlers)) {
        _reverseCallHandlers = null;
      }
    }
    if (process != null) {
      await terminateOwnedProcess(
        label: 'acp',
        gracePeriod: _terminationGracePeriod,
        platformCapabilities: _platformCapabilities,
        process: process,
      );
    }
    _state = WorkerState.stopped;
  }

  @override
  Future<void> dispose() async {
    await stop();
    _disposed = true;
    if (!_eventsController.isClosed) {
      await _eventsController.close();
    }
  }

  Future<Process> _spawnProcess() async {
    try {
      final containerManager = this.containerManager;
      if (containerManager != null) {
        return await containerManager.exec(
          [executable, ...arguments],
          env: environment,
          workingDirectory: containerManager.workingDir,
        );
      }
      return await _processFactory(
        executable,
        arguments,
        workingDirectory: cwd,
        environment: environment,
        includeParentEnvironment: true,
      );
    } catch (error) {
      throw AcpHarnessException(
        AcpHarnessErrorCode.spawnFailed,
        'Failed to spawn ACP agent "$executable"',
        diagnostics: {'error': '$error'},
      );
    }
  }

  void _collectStderr(Process process) {
    process.stderr
        .transform(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (chunk, sink) {
              _appendStderrDiagnostics(chunk);
              sink.add(chunk);
            },
          ),
        )
        .transform(utf8.decoder)
        .listen((_) {}, onError: (Object error) => _failStream(process, 'stderr', error));
  }

  /// Routes a fault on either output stream of [process] – an undecodable stream
  /// is a provider fault, so it must never reach the isolate unhandled, and the
  /// turn must fail rather than wait for an answer the dead agent cannot send.
  /// Contained unless [process] is still the owned one and not already being
  /// torn down: ACP never cancels its stderr subscription, so a replaced process
  /// keeps one live and its own teardown kill can end a stream mid-character.
  /// The peer is closed ahead of [stop], which queues behind the lifecycle lock
  /// – a handshake-time fault would otherwise wait out `initializeTimeout`.
  void _failStream(Process process, String streamName, Object cause) {
    final failure = ProcessStreamException(streamName: streamName, cause: cause);
    if (!identical(currentProcess, process) || _stopping || _state == WorkerState.stopped) {
      _log.fine('Ignoring unowned or teardown-time $streamName fault: ${failure.message}');
      return;
    }
    _log.severe(failure.message);
    final completer = _activeTurnCompleter;
    if (completer != null && !completer.isCompleted) completer.completeError(failure);
    unawaited((_client?.close() ?? Future<void>.value()).catchError((Object _) {}));
    unawaited(stop().catchError((Object error) => _log.warning('Teardown after $streamName fault failed', error)));
  }

  Future<void> _closeSession(AcpClient client, String acpSessionId, {Duration? timeout}) async {
    try {
      await _awaitMaybeWithTimeout(client.closeSession(acpSessionId), timeout);
    } catch (error) {
      _log.warning('ACP session/close failed; continuing shutdown', error);
    }
  }

  Future<void> _cancelAndCloseActiveSession(AcpClient client) async {
    final activeSessionId = _activeAcpSessionId;
    if (activeSessionId == null) {
      return;
    }
    await _cancelSession(client, activeSessionId, timeout: const Duration(milliseconds: 250));
    await _closeSession(client, activeSessionId, timeout: const Duration(milliseconds: 250));
    _completeActiveTurn();
  }

  void _completeActiveTurn() {
    final completer = _activeTurnCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  Future<void> _cancelSession(AcpClient client, String acpSessionId, {Duration? timeout}) async {
    try {
      await _awaitMaybeWithTimeout(client.cancel(acpSessionId), timeout);
    } catch (error) {
      _log.fine('ACP session/cancel failed: $error');
    }
  }

  Future<void> _awaitMaybeWithTimeout(Future<void> operation, Duration? timeout) {
    return timeout == null ? operation : operation.timeout(timeout);
  }

  Future<void> _cleanupAfterStartupFailure() async {
    _state = WorkerState.stopped;
    final process = currentProcess;
    beginIntentionalProcessTeardown(process, _platformCapabilities);
    final client = _client;
    _client = null;
    final reverseCallHandlers = _reverseCallHandlers;
    if (client != null) {
      try {
        await client.close();
      } catch (_) {}
    }
    if (reverseCallHandlers != null) {
      await reverseCallHandlers.disposeTerminals();
      if (!reverseCallHandlers.ownsTerminals && identical(_reverseCallHandlers, reverseCallHandlers)) {
        _reverseCallHandlers = null;
      }
    }
    if (process != null) {
      await terminateOwnedProcess(
        label: 'acp',
        gracePeriod: _terminationGracePeriod,
        platformCapabilities: _platformCapabilities,
        process: process,
      );
    }
  }

  void _appendStderrDiagnostics(List<int> chunk) {
    if (chunk.isEmpty) return;
    final untruncatedLength = _stderrDiagnostics.length + chunk.length;
    if (!_stderrDiagnosticsTruncated && untruncatedLength <= retainedDiagnosticsLimitBytes) {
      _stderrDiagnostics = [..._stderrDiagnostics, ...chunk];
      return;
    }

    _stderrDiagnosticsTruncated = true;
    final capacity = retainedDiagnosticsLimitBytes - _diagnosticsTruncatedMarkerBytes;
    if (chunk.length >= capacity) {
      _stderrDiagnostics = List<int>.of(chunk.sublist(chunk.length - capacity));
      return;
    }
    final previousCapacity = capacity - chunk.length;
    final previousStart = _stderrDiagnostics.length > previousCapacity
        ? _stderrDiagnostics.length - previousCapacity
        : 0;
    _stderrDiagnostics = [..._stderrDiagnostics.sublist(previousStart), ...chunk];
  }
}
