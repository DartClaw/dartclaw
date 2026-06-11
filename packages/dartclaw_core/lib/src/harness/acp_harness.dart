import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:dartclaw_security/dartclaw_security.dart';

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
  final ProcessFactory? _terminalProcessFactory;
  final GuardChain? guardChain;
  final AcpPermissionDecision? permissionDecision;
  final AcpReverseCallAuditSink? onReverseCallAudit;
  final int terminalOutputByteLimit;
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
    ProcessFactory? terminalProcessFactory,
    AcpProtocolAdapter? adapter,
    this.guardChain,
    this.permissionDecision,
    this.onReverseCallAudit,
    this.terminalOutputByteLimit = 65536,
    this.containerManager,
    Map<String, String>? environment,
  }) : _processFactory = processFactory ?? Process.start,
       _terminalProcessFactory = terminalProcessFactory,
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

    _stopping = false;
    _state = WorkerState.busy;
    try {
      final process = await _spawnProcess();
      _process = process;
      _collectStderr(process);
      _watchExit(process);
      final reverseCallHandlers = containerManager == null
          ? AcpReverseCallHandlers(
              cwd: cwd,
              guardChain: guardChain,
              permissionDecision: permissionDecision,
              onAudit: onReverseCallAudit,
              terminalProcessFactory: _terminalProcessFactory,
              baseEnvironment: environment,
              hostOutputByteLimit: terminalOutputByteLimit,
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
      await client.initialize();
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
    final client = await withLock(() async {
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

      _state = WorkerState.busy;
      _activeTurnCompleter = Completer<void>();
      _resetActiveMetadata();
      return client;
    });
    final timeout = Timer(turnTimeout, () {
      final activeSessionId = _activeAcpSessionId;
      if (activeSessionId != null) {
        unawaited(cancel());
      }
      final completer = _activeTurnCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.completeError(TimeoutException('ACP turn exceeded $turnTimeout'));
      }
    });

    try {
      final acpSessionId = await client.createSession(cwd: directory ?? cwd);
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
        final result = await Future.any([promptFuture, cancelOrCrashFuture]);
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
            : null;
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
      timeout.cancel();
      _activeAcpSessionId = null;
      _activeTurnCompleter = null;
      _resetActiveMetadata();
      if (_state != WorkerState.stopped && _state != WorkerState.crashed) {
        _state = WorkerState.idle;
      }
    }
  }

  @override
  Future<void> cancel() async {
    final activeSessionId = _activeAcpSessionId;
    final client = _client;
    if (activeSessionId == null || client == null) {
      return;
    }
    await _cancelSession(client, activeSessionId, timeout: const Duration(milliseconds: 250));
    _completeActiveTurn();
  }

  @override
  Future<void> resetSessionContinuity(String sessionId) async {}

  @override
  Future<void> stop() {
    _stopping = true;
    return withLock(_stopInternal);
  }

  Future<void> _stopInternal() async {
    if (_state == WorkerState.stopped) {
      return;
    }
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
    await _reverseCallHandlers?.disposeTerminals();
    _reverseCallHandlers = null;
    final process = _process;
    _process = null;
    if (process != null) {
      await _closeStdin(process);
      await killWithEscalation(process, label: 'acp', gracePeriod: const Duration(seconds: 2), log: _log);
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

  void _emitProtocolMessages(List<proto.ProtocolMessage> messages) {
    for (final message in messages) {
      switch (message) {
        case proto.TextDelta(:final text):
          _eventsController.add(DeltaEvent(text));
        case proto.ToolUse(:final name, :final id, :final input):
          _eventsController.add(ToolUseEvent(toolName: name, toolId: id, input: input));
        case proto.ToolResult(:final toolId, :final output, :final isError):
          _eventsController.add(ToolResultEvent(toolId: toolId, output: output, isError: isError));
        case proto.ProgressMessage(:final text, :final kind):
          _log.fine('ACP progress $kind: $text');
          _eventsController.add(ProviderProgressBridgeEvent(kind: kind, text: text));
        case proto.SessionMetadataUpdate(:final title, :final metadata):
          _recordSessionMetadata(title: title, metadata: metadata);
        case proto.ProtocolDiagnostic(:final message, :final method, :final updateType):
          _log.fine(
            'ACP diagnostic${method == null ? '' : ' method=$method'}'
            '${updateType == null ? '' : ' update=$updateType'}: $message',
          );
        case proto.TurnComplete():
          break;
        case proto.SystemInit(:final contextWindow):
          if (contextWindow != null) {
            _eventsController.add(SystemInitEvent(contextWindow: contextWindow));
          }
        case proto.ControlRequest():
        case proto.CompactBoundary():
        case proto.CompactionStarted():
        case proto.CompactionCompleted():
          break;
      }
    }
  }

  void _handleSessionUpdate(Map<String, dynamic> update) {
    final completer = _activeTurnCompleter;
    if (_activeAcpSessionId == null || (completer != null && completer.isCompleted)) {
      _log.fine('Ignoring stale ACP session/update after turn cancellation or completion');
      return;
    }
    _emitProtocolMessages(_adapter.messagesForSessionUpdate(update));
  }

  void _handleMalformedLine(String line) {
    _emitProtocolMessages(_adapter.parseLine(line));
  }

  void _recordSessionMetadata({String? title, required Map<String, dynamic> metadata}) {
    if (title != null && title.trim().isNotEmpty) {
      _activeSessionTitle = title.trim();
    }
    _activeMetadata.addAll(metadata);
    _activeInputTokens = _intFromMetadata(metadata, const ['input_tokens', 'inputTokens']) ?? _activeInputTokens;
    _activeOutputTokens = _intFromMetadata(metadata, const ['output_tokens', 'outputTokens']) ?? _activeOutputTokens;
    _activeCacheReadTokens =
        _intFromMetadata(metadata, const ['cache_read_tokens', 'cacheReadTokens']) ?? _activeCacheReadTokens;
    _activeCacheWriteTokens =
        _intFromMetadata(metadata, const ['cache_write_tokens', 'cacheWriteTokens']) ?? _activeCacheWriteTokens;
  }

  void _resetActiveMetadata() {
    _activeMetadata.clear();
    _activeSessionTitle = null;
    _activeInputTokens = null;
    _activeOutputTokens = null;
    _activeCacheReadTokens = null;
    _activeCacheWriteTokens = null;
  }

  static int? _intFromMetadata(Map<String, dynamic> metadata, List<String> keys) {
    for (final key in keys) {
      final value = metadata[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
    }
    return null;
  }

  Future<void> _cleanupAfterStartupFailure() async {
    _state = WorkerState.stopped;
    final client = _client;
    _client = null;
    final reverseCallHandlers = _reverseCallHandlers;
    _reverseCallHandlers = null;
    if (client != null) {
      try {
        await client.close();
      } catch (_) {}
    }
    await reverseCallHandlers?.disposeTerminals();
    final process = _process;
    _process = null;
    if (process != null) {
      await _closeStdin(process);
      await killWithEscalation(process, label: 'acp', gracePeriod: const Duration(seconds: 2), log: _log);
    }
  }

  Map<String, Object?> _diagnostics({int? exitCode}) {
    final diagnostics = <String, Object?>{};
    if (exitCode != null) {
      diagnostics['exit_code'] = exitCode;
    }
    if (_stdoutDiagnostics.isNotEmpty) {
      diagnostics['stdout'] = _stdoutDiagnostics.toString();
    }
    if (_stderrDiagnostics.isNotEmpty) {
      diagnostics['stderr'] = _stderrDiagnostics.toString();
    }
    return diagnostics;
  }

  Future<void> _closeStdin(Process process) async {
    try {
      await process.stdin.close();
    } catch (_) {}
  }

  String _promptText(Object? content, String systemPrompt) {
    final text = switch (content) {
      String value => value,
      List<Object?> values => values.map((value) => '$value').join('\n'),
      null => '',
      _ => '$content',
    };
    if (systemPrompt.trim().isEmpty) {
      return text;
    }
    return '$systemPrompt\n\n$text';
  }
}
