import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show PlatformCapabilities;
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';

import '../bridge/bridge_events.dart';
import '../container/container_executor.dart';
import '../worker/worker_state.dart';
import 'acp_client.dart';
import 'acp_errors.dart';
import 'acp_protocol_adapter.dart';
import 'acp_reverse_call_handlers.dart';
import 'agent_harness.dart';
import 'protocol_message.dart' as proto;
import 'process_lifecycle.dart';
import 'process_types.dart';

part 'acp_harness_presentation.dart';

/// Minimal subprocess-backed ACP harness.
final class AcpHarness with SequentialLock implements AgentHarness {
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

  final ProcessFactory _processFactory;
  final PlatformCapabilities _platformCapabilities;
  final Duration _terminationGracePeriod;
  final Duration _initializeTimeout;
  final GuardChain? guardChain;
  final AcpPermissionDecision? permissionDecision;
  final AcpReverseCallAuditSink? onReverseCallAudit;
  final StreamController<BridgeEvent> _eventsController = StreamController<BridgeEvent>.broadcast();
  final AcpProtocolAdapter _adapter;
  final StringBuffer _stdoutDiagnostics = StringBuffer();
  final StringBuffer _stderrDiagnostics = StringBuffer();
  final Map<String, dynamic> _activeMetadata = {};
  String? _activeSessionTitle;
  int? _activeInputTokens;
  int? _activeOutputTokens;
  int? _activeCacheReadTokens;
  int? _activeCacheWriteTokens;

  static final _log = Logger('AcpHarness');

  WorkerState _state = WorkerState.stopped;
  Process? _process;
  final Set<Process> _windowsTeardownPending = <Process>{};
  final Set<Process> _windowsExitObservedDuringTeardown = <Process>{};
  AcpClient? _client;
  String? _activeAcpSessionId;
  Completer<void>? _activeTurnCompleter;
  AcpReverseCallHandlers? _reverseCallHandlers;
  bool _stopping = false;
  bool _disposed = false;

  /// Creates an ACP harness.
  AcpHarness({
    required this.cwd,
    this.executable = 'goose',
    this.arguments = const <String>[],
    this.turnTimeout = const Duration(seconds: 600),
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
    if (_process != null) {
      throw StateError('Cannot start AcpHarness while previous process exit is unconfirmed');
    }
    if (_reverseCallHandlers?.ownsTerminals ?? false) {
      throw StateError('Cannot start AcpHarness while terminal process exit is unconfirmed');
    }

    _stopping = false;
    _state = WorkerState.busy;
    try {
      final process = await _spawnProcess();
      _windowsTeardownPending.remove(process);
      _windowsExitObservedDuringTeardown.remove(process);
      _process = process;
      _collectStderr(process);
      _watchExit(process);
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
      reverseCallHandlers?.bindTurn(sessionId: sessionId, effectiveDirectory: effectiveDirectory);
      _state = WorkerState.busy;
      _activeTurnCompleter = Completer<void>();
      _resetActiveMetadata();
      return (client: client, reverseCallHandlers: reverseCallHandlers);
    });
    final client = activeTurn.client;
    final deadline = DateTime.now().add(turnTimeout);

    try {
      final interruptedSession = _activeTurnCompleter!.future.then<String?>((_) => null);
      final acpSessionId = await Future.any<String?>([
        client.createSession(cwd: effectiveDirectory).then<String?>((sessionId) => sessionId),
        interruptedSession,
      ]).timeout(_remainingUntil(deadline));
      if (acpSessionId == null) {
        const result = AcpPromptResult(text: '', stopReason: 'cancelled');
        _emitProtocolMessages(_adapter.messagesForPromptResult(result));
        await stop();
        return const <String, dynamic>{
          'stop_reason': 'cancelled',
          'input_tokens': 0,
          'output_tokens': 0,
          'cache_read_tokens': 0,
          'cache_write_tokens': 0,
          'response': '',
        };
      }
      _activeAcpSessionId = acpSessionId;
      Map<String, dynamic>? response;
      var terminateAfterTurn = false;
      AcpHarnessException? promptError;
      try {
        final prompt = _promptText(messages.last['content'], systemPrompt);
        final promptFuture = client.prompt(sessionId: acpSessionId, text: prompt);
        final cancelOrCrashFuture = _activeTurnCompleter!.future.then(
          (_) => const AcpPromptResult(text: '', stopReason: 'cancelled'),
        );
        final result = await Future.any([promptFuture, cancelOrCrashFuture]).timeout(_remainingUntil(deadline));
        _emitProtocolMessages(_adapter.messagesForPromptResult(result));
        terminateAfterTurn = result.stopReason == 'cancelled';
        final sessionTitle = result.sessionTitle ?? _activeSessionTitle;
        response = <String, dynamic>{
          'stop_reason': result.stopReason,
          'input_tokens': result.inputTokens ?? _activeInputTokens ?? 0,
          'output_tokens': result.outputTokens ?? _activeOutputTokens ?? 0,
          'cache_read_tokens': result.cacheReadTokens ?? _activeCacheReadTokens ?? 0,
          'cache_write_tokens': result.cacheWriteTokens ?? _activeCacheWriteTokens ?? 0,
          'response': result.text,
          if (_activeMetadata.isNotEmpty) 'metadata': Map<String, dynamic>.from(_activeMetadata),
        };
        if (sessionTitle != null) {
          response['session_title'] = sessionTitle;
        }
      } on AcpHarnessException catch (error) {
        promptError = error;
        rethrow;
      } finally {
        final terminalCloseTimeout = terminateAfterTurn || promptError?.errorCode == AcpHarnessErrorCode.authRequired
            ? const Duration(milliseconds: 250)
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
    _beginIntentionalProcessTeardown(_process);
    return withLock(_stopInternal);
  }

  Future<void> _stopInternal() async {
    if (_state == WorkerState.stopped && _process == null && !(_reverseCallHandlers?.ownsTerminals ?? false)) {
      return;
    }
    final process = _process;
    _beginIntentionalProcessTeardown(process);
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
      await _closeStdin(process);
      final result = await killWithEscalation(
        process,
        label: 'acp',
        gracePeriod: _terminationGracePeriod,
        log: _log,
        platformCapabilities: _platformCapabilities,
      );
      _completeIntentionalProcessTeardown(process, result);
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
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.trim().isNotEmpty) {
        _stderrDiagnostics.writeln(line);
      }
    });
  }

  void _watchExit(Process process) {
    unawaited(
      process.exitCode.then((code) {
        final windowsTeardownPending = _windowsTeardownPending.contains(process);
        if (windowsTeardownPending) {
          _windowsExitObservedDuringTeardown.add(process);
        } else if (identical(_process, process)) {
          _process = null;
        }
        if (_stopping || _state == WorkerState.stopped) {
          return;
        }
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
      }),
    );
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
    final process = _process;
    _beginIntentionalProcessTeardown(process);
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
      await _closeStdin(process);
      final result = await killWithEscalation(
        process,
        label: 'acp',
        gracePeriod: _terminationGracePeriod,
        log: _log,
        platformCapabilities: _platformCapabilities,
      );
      _completeIntentionalProcessTeardown(process, result);
    }
  }

  void _beginIntentionalProcessTeardown(Process? process) {
    if (process != null && !_platformCapabilities.posixSignalsAvailable) {
      _windowsTeardownPending.add(process);
    }
  }

  void _completeIntentionalProcessTeardown(Process process, ProcessTerminationResult result) {
    _windowsTeardownPending.remove(process);
    final exitObserved = _windowsExitObservedDuringTeardown.remove(process);
    if (result.confirmsOwnershipRelease() || exitObserved) {
      if (identical(_process, process)) _process = null;
    }
  }

  Future<void> _closeStdin(Process process) async {
    try {
      await process.stdin.close();
    } catch (_) {}
  }
}
