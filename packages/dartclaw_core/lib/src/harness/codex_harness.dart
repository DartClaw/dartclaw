import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';

import '../bridge/bridge_events.dart';
import '../worker/worker_state.dart';
import 'agent_harness.dart';
import 'codex_environment.dart';
import 'codex_protocol_adapter.dart';
import 'codex_protocol_utils.dart';
import 'codex_settings.dart';
import 'harness_config.dart';
import 'process_types.dart';
import 'protocol_message.dart' as proto;

/// Thin subprocess lifecycle manager for `codex app-server`.
class CodexHarness extends AgentHarness {
  /// Working directory for the Codex subprocess.
  final String cwd;

  /// Codex executable path or name.
  final String executable;

  /// Maximum time allowed for a single turn.
  final Duration turnTimeout;

  /// Maximum number of crash recovery attempts before the harness gives up.
  final int maxRetries;

  /// Base backoff applied before restarting after a crash.
  final Duration baseBackoff;

  /// Injectable process spawn callback.
  final ProcessFactory processFactory;

  /// Injectable command probe, used for binary availability checks.
  final CommandProbe commandProbe;

  /// Injectable delay callback used during shutdown.
  final DelayFactory delayFactory;

  /// Environment passed to the Codex subprocess.
  final Map<String, String> environment;

  /// Provider-agnostic configuration used to initialize the Codex worker.
  final HarnessConfig harnessConfig;

  /// Provider-specific options used for Codex request settings translation.
  final Map<String, dynamic> providerOptions;

  /// Optional guard chain used to evaluate approval requests.
  final GuardChain? guardChain;

  /// Codex protocol adapter used for all wire-format translation.
  final CodexProtocolAdapter adapter;

  static final _log = Logger('CodexHarness');

  WorkerState _state = WorkerState.stopped;
  Process? _process;
  int _crashCount = 0;
  final Map<String, String> _threadIds = <String, String>{};
  String? _activeSessionId;
  int _nextRequestId = 0;
  int _spawnGeneration = 0;
  Object? _initializeRequestId;
  Object? _threadStartRequestId;
  Completer<Map<String, dynamic>>? _initializeCompleter;
  Completer<String>? _threadStartCompleter;
  Completer<Map<String, dynamic>>? _turnCompleter;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  Future<void> _lock = Future<void>.value();
  final StreamController<BridgeEvent> _eventsCtrl = StreamController<BridgeEvent>.broadcast();
  CodexEnvironment? _environment;

  CodexHarness({
    required this.cwd,
    this.executable = 'codex',
    this.turnTimeout = const Duration(seconds: 600),
    this.maxRetries = 5,
    this.baseBackoff = const Duration(seconds: 5),
    ProcessFactory? processFactory,
    CommandProbe? commandProbe,
    DelayFactory? delayFactory,
    Map<String, String>? environment,
    this.harnessConfig = const HarnessConfig(),
    Map<String, dynamic>? providerOptions,
    this.guardChain,
    CodexProtocolAdapter? adapter,
  }) : processFactory = processFactory ?? Process.start,
       commandProbe = commandProbe ?? Process.run,
       delayFactory = delayFactory ?? Future<void>.delayed,
       environment = environment ?? Platform.environment,
       providerOptions = Map<String, dynamic>.unmodifiable(providerOptions ?? const <String, dynamic>{}),
       adapter = adapter ?? CodexProtocolAdapter();

  @override
  PromptStrategy get promptStrategy => PromptStrategy.append;

  @override
  bool get supportsCostReporting => false;

  @override
  bool get supportsCachedTokens => true;

  @override
  WorkerState get state => _state;

  @override
  Stream<BridgeEvent> get events => _eventsCtrl.stream;

  @override
  Future<void> start() => _withLock(() async {
    if (_state == WorkerState.idle) {
      return;
    }
    if (_state == WorkerState.busy) {
      throw StateError('Cannot start CodexHarness while busy');
    }

    await _cleanupEnvironment();
    await _verifyExecutable();
    _environment = CodexEnvironment(
      developerInstructions: harnessConfig.appendSystemPrompt ?? '',
      mcpServerUrl: harnessConfig.mcpServerUrl,
      mcpGatewayToken: harnessConfig.mcpGatewayToken,
    );

    try {
      await _environment!.setup();
      await _spawnProcess();
      await _initialize();
      _state = WorkerState.idle;
    } catch (_) {
      await _cleanupStartupFailure();
      rethrow;
    }
  });

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
  }) async {
    while (_state == WorkerState.crashed) {
      if (_crashCount > maxRetries) {
        throw StateError('Harness unavailable: max retries exceeded');
      }
      final backoff = baseBackoff * pow(2, _crashCount - 1).toInt();
      await delayFactory(backoff);
      await _withLock(() async {
        if (_state == WorkerState.stopped) {
          throw StateError('Harness stopped during backoff');
        }
        if (_state == WorkerState.crashed) {
          try {
            await _restartAfterCrash();
          } catch (_) {
            if (_state != WorkerState.crashed) {
              rethrow;
            }
          }
        }
      });
    }

    if (_state != WorkerState.idle) {
      throw StateError('CodexHarness is not idle (state: $_state)');
    }
    if (_process == null) {
      throw StateError('CodexHarness has not completed startup');
    }
    if (messages.isEmpty) {
      throw StateError('CodexHarness requires at least one message');
    }

    _state = WorkerState.busy;
    _activeSessionId = sessionId;
    _turnCompleter = Completer<Map<String, dynamic>>();
    Timer? timeoutTimer;
    final stopwatch = Stopwatch();

    try {
      final threadId = _threadIds[sessionId] ?? await _startThread(sessionId);
      timeoutTimer = Timer(turnTimeout, () {
        final completer = _turnCompleter;
        if (completer == null || completer.isCompleted) {
          return;
        }
        completer.completeError(TimeoutException('Codex turn exceeded $turnTimeout'));
        unawaited(cancel());
      });

      final previousMessages = messages.length > 1
          ? messages.sublist(0, messages.length - 1)
          : const <Map<String, dynamic>>[];
      final payload = adapter.buildTurnRequest(
        message: codexStringifyMessageContent(messages.last['content']),
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
      stopwatch.start();
      _writeLine(payload);

      final result = await _turnCompleter!.future;
      if (stopwatch.isRunning) {
        stopwatch.stop();
      }
      result['duration_ms'] ??= stopwatch.elapsedMilliseconds;
      if (_state != WorkerState.stopped && _state != WorkerState.crashed) {
        _crashCount = 0;
        _state = WorkerState.idle;
      }
      return result;
    } catch (_) {
      if (stopwatch.isRunning) {
        stopwatch.stop();
      }
      if (_state != WorkerState.stopped && _state != WorkerState.crashed) {
        _state = WorkerState.idle;
      }
      rethrow;
    } finally {
      timeoutTimer?.cancel();
      _turnCompleter = null;
      _activeSessionId = null;
    }
  }

  @override
  Future<void> cancel() async {
    final process = _process;
    if (process == null) {
      return;
    }
    try {
      await process.stdin.close();
    } catch (_) {}
    process.kill(ProcessSignal.sigterm);
  }

  @override
  Future<void> stop() => _withLock(_stopInternal);

  Future<void> _stopInternal() async {
    if (_state == WorkerState.busy) {
      await cancel();
      await delayFactory(const Duration(milliseconds: 50));
    }

    _state = WorkerState.stopped;
    _threadIds.clear();
    _completePendingWithError(StateError('CodexHarness stopped'));

    await _stdoutSub?.cancel();
    _stdoutSub = null;
    await _stderrSub?.cancel();
    _stderrSub = null;

    final process = _process;
    _process = null;
    if (process == null) {
      await _cleanupEnvironment();
      return;
    }

    try {
      await process.stdin.close();
    } catch (_) {}
    process.kill(ProcessSignal.sigterm);
    await _cleanupEnvironment();
  }

  @override
  Future<void> dispose() async {
    await stop();
    if (!_eventsCtrl.isClosed) {
      await _eventsCtrl.close();
    }
  }

  Future<void> _verifyExecutable() async {
    final result = await commandProbe(executable, const ['--version']);
    if (result.exitCode != 0) {
      throw StateError('codex binary not found at $executable');
    }
  }

  Future<void> _spawnProcess() async {
    final spawnEnvironment = <String, String>{...environment, ...?_environment?.environmentOverrides()};
    final process = await processFactory(
      executable,
      const [
        // App-server mode must keep approval prompts active. `--yolo` would
        // bypass the only guard-chain interception point for Codex tool calls.
        'app-server',
      ],
      workingDirectory: cwd,
      environment: spawnEnvironment,
      includeParentEnvironment: false,
    );

    final generation = ++_spawnGeneration;
    _process = process;

    _stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.trim().isNotEmpty)
        .listen(_handleLine);

    _stderrSub = process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((_) {});

    unawaited(
      process.exitCode.then((code) {
        if (generation != _spawnGeneration) {
          return;
        }
        if (_state == WorkerState.stopped) {
          return;
        }
        _threadIds.clear();
        _state = WorkerState.crashed;
        _crashCount++;
        _completePendingWithError(StateError('Codex process exited with code $code'));
      }),
    );
  }

  Future<void> _restartAfterCrash() async {
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    await _stderrSub?.cancel();
    _stderrSub = null;
    _process = null;
    _threadIds.clear();
    await _spawnProcess();
    await _initialize();
    _state = WorkerState.idle;
  }

  Future<void> _cleanupStartupFailure() async {
    _state = WorkerState.stopped;
    _threadIds.clear();
    _completePendingWithError(StateError('CodexHarness startup failed'));

    await _stdoutSub?.cancel();
    _stdoutSub = null;
    await _stderrSub?.cancel();
    _stderrSub = null;

    final process = _process;
    _process = null;
    if (process != null) {
      try {
        await process.stdin.close();
      } catch (_) {}
      process.kill(ProcessSignal.sigterm);
    }

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
    await _initializeCompleter!.future;
    _writeLine(adapter.buildInitializedNotification());
  }

  Future<String> _startThread(String sessionId) async {
    final id = _nextJsonRpcId();
    _threadStartRequestId = id;
    _threadStartCompleter = Completer<String>();
    _writeLine(
      adapter.buildThreadStartRequest(id: id, params: <String, dynamic>{'thread_id': '$sessionId-thread-$id'}),
    );
    final threadId = await _threadStartCompleter!.future;
    _threadIds[sessionId] = threadId;
    return threadId;
  }

  void _handleLine(String line) {
    _handlePendingResponse(line);

    final message = adapter.parseLine(line);
    if (message == null) {
      return;
    }

    switch (message) {
      case proto.TextDelta(:final text):
        _eventsCtrl.add(DeltaEvent(text));

      case proto.ToolUse(:final name, :final id, :final input):
        _eventsCtrl.add(ToolUseEvent(toolName: name, toolId: id, input: input));

      case proto.ToolResult(:final toolId, :final output, :final isError):
        _eventsCtrl.add(ToolResultEvent(toolId: toolId, output: output, isError: isError));

      case proto.ControlRequest(:final requestId, :final subtype, :final data):
        unawaited(_dispatchControlRequest(requestId, subtype, data, sessionId: _activeSessionId));

      case proto.TurnComplete(:final stopReason, :final inputTokens, :final outputTokens, :final cachedInputTokens):
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
            result['cached_input_tokens'] = cachedInputTokens ?? 0;
          }
          completer.complete(result);
        }

      case proto.SystemInit(:final contextWindow):
        if (contextWindow != null) {
          _eventsCtrl.add(SystemInitEvent(contextWindow: contextWindow));
        }
    }
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
      _tryWriteApprovalResponse(requestId, allow: false, reason: 'Approval handler error: $error');
    }
  }

  Future<void> _handleApprovalRequest(String requestId, Map<String, dynamic> data, {String? sessionId}) async {
    final rawToolName = data['tool_name'] as String? ?? '';
    final providerToolInput = Map<String, dynamic>.from(codexMapValue(data['tool_input']) ?? const <String, dynamic>{});
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
          _tryWriteApprovalResponse(requestId, allow: false, reason: verdict.message);
          return;
        }
      } catch (error, stackTrace) {
        _log.severe('GuardChain evaluation failed for Codex approval $requestId: $error', error, stackTrace);
        _tryWriteApprovalResponse(requestId, allow: false, reason: 'Guard evaluation failed: $error');
        return;
      }
    }

    _tryWriteApprovalResponse(requestId, allow: true);
  }

  void _handlePendingResponse(String line) {
    final decoded = codexDecodeJsonObject(line);
    if (decoded == null) {
      return;
    }

    final id = decoded['id'];
    final result = codexMapValue(decoded['result']);
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
      final threadId = result?['thread_id'] ?? result?['id'];
      if (error != null) {
        _threadStartCompleter!.completeError(StateError('Codex thread/start failed: $error'));
      } else if (threadId is String && threadId.isNotEmpty) {
        _threadStartCompleter!.complete(threadId);
      } else {
        _threadStartCompleter!.completeError(StateError('Codex thread/start response missing thread_id or id'));
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

  void _tryWriteApprovalResponse(String requestId, {required bool allow, String? reason}) {
    try {
      _writeLine(adapter.buildApprovalResponse(requestId, allow: allow, reason: reason));
    } catch (error, stackTrace) {
      _log.severe('Failed to write Codex approval response for $requestId: $error', error, stackTrace);
    }
  }

  void _writeLine(Map<String, dynamic> message) {
    final process = _process;
    if (process == null) {
      throw StateError('Codex process is not running');
    }
    process.stdin.add(utf8.encode('${jsonEncode(message)}\n'));
  }

  static String? _inferFileChangeKind(Map<String, dynamic> toolInput) {
    final directKind = toolInput['kind'];
    if (directKind is String && directKind.isNotEmpty) {
      return directKind;
    }

    final changes = toolInput['changes'];
    if (changes is List) {
      for (final change in changes) {
        final changeMap = codexMapValue(change);
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
    _stripOpenAiApiKey(guardToolInput);

    if (rawToolName != 'file_change') {
      return guardToolInput;
    }

    final primaryChange = _primaryFileChange(guardToolInput);
    final filePath = codexStringValue(guardToolInput['path']) ?? codexStringValue(primaryChange?['path']);
    if (filePath != null && filePath.isNotEmpty) {
      guardToolInput['file_path'] = filePath;
    }

    final kind = codexStringValue(guardToolInput['kind']) ?? codexStringValue(primaryChange?['kind']);
    if (kind != null && kind.isNotEmpty) {
      guardToolInput['kind'] = kind;
    }

    final oldString =
        codexStringValue(guardToolInput['old_string']) ??
        codexStringValue(guardToolInput['old_text']) ??
        codexStringValue(primaryChange?['old_string']) ??
        codexStringValue(primaryChange?['old_text']);
    if (oldString != null) {
      guardToolInput['old_string'] = oldString;
    }

    final newString =
        codexStringValue(guardToolInput['new_string']) ??
        codexStringValue(guardToolInput['new_text']) ??
        codexStringValue(primaryChange?['new_string']) ??
        codexStringValue(primaryChange?['new_text']);
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
      final changeMap = codexMapValue(change);
      if (changeMap != null) {
        return changeMap;
      }
    }

    return null;
  }

  static void _stripOpenAiApiKey(Map<String, dynamic> toolInput) {
    final envMap = codexMapValue(toolInput['env']);
    if (envMap == null || !envMap.containsKey('OPENAI_API_KEY')) {
      return;
    }

    toolInput['env'] = Map<String, dynamic>.from(envMap)..remove('OPENAI_API_KEY');
    _log.info('Stripped OPENAI_API_KEY from Codex approval input env');
  }

  static String? _extractTurnFailedError(String line) {
    final decoded = codexDecodeJsonObject(line);
    final params = codexMapValue(decoded?['params']);
    final error = params?['error'];

    if (error is String && error.isNotEmpty) {
      return error;
    }

    final errorMap = codexMapValue(error);
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

  Future<T> _withLock<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    final next = _lock.catchError((_) {}).then((_) => operation());
    _lock = next.then<void>((_) {}, onError: (_) {});
    next.then(completer.complete, onError: completer.completeError);
    return completer.future;
  }
}
