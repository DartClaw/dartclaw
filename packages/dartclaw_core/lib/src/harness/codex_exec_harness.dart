import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import '../bridge/bridge_events.dart';
import '../worker/worker_state.dart';
import 'agent_harness.dart';
import 'codex_environment.dart';
import 'codex_exec_protocol_adapter.dart';
import 'codex_protocol_utils.dart';
import 'harness_config.dart';
import 'process_types.dart';
import 'protocol_message.dart' as proto;

/// Lightweight one-shot harness for `codex exec --json`.
class CodexExecHarness extends AgentHarness {
  /// Working directory used when no per-turn directory override is supplied.
  final String cwd;

  /// Codex executable path or binary name.
  final String codexExecutable;

  /// Sandbox mode passed to `codex exec`.
  final String sandboxMode;

  /// Maximum time allowed for a single turn.
  final Duration turnTimeout;

  /// Injectable process spawn callback.
  final ProcessFactory processFactory;

  /// Environment passed to each Codex subprocess.
  final Map<String, String> environment;

  /// Static Codex configuration shared with the app-server harness.
  final HarnessConfig harnessConfig;

  /// Exec-mode protocol adapter used for stdout parsing.
  final CodexExecProtocolAdapter adapter;

  static final _log = Logger('CodexExecHarness');

  WorkerState _state = WorkerState.stopped;
  Process? _activeProcess;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  Completer<Map<String, dynamic>>? _turnCompleter;
  Completer<void>? _processReadyCompleter;
  bool _cancelRequested = false;
  final StreamController<BridgeEvent> _eventsCtrl = StreamController<BridgeEvent>.broadcast();
  Future<void> _lock = Future<void>.value();

  /// Grace period after SIGTERM before escalating to SIGKILL.
  final Duration _killGracePeriod;

  CodexExecHarness({
    required this.cwd,
    this.codexExecutable = 'codex',
    this.sandboxMode = 'danger-full-access',
    this.turnTimeout = const Duration(seconds: 600),
    ProcessFactory? processFactory,
    Map<String, String>? environment,
    this.harnessConfig = const HarnessConfig(),
    CodexExecProtocolAdapter? adapter,
    Duration killGracePeriod = const Duration(seconds: 2),
  }) : processFactory = processFactory ?? Process.start,
       environment = environment ?? Platform.environment,
       adapter = adapter ?? CodexExecProtocolAdapter(),
       _killGracePeriod = killGracePeriod;

  @override
  PromptStrategy get promptStrategy => PromptStrategy.append;

  @override
  bool get supportsCostReporting => false;

  @override
  bool get supportsToolApproval => false;

  @override
  bool get supportsStreaming => false;

  @override
  bool get supportsCachedTokens => true;

  @override
  WorkerState get state => _state;

  @override
  Stream<BridgeEvent> get events => _eventsCtrl.stream;

  @override
  Future<void> start() => _withLock(() async {
    if (_state == WorkerState.busy) {
      throw StateError('Cannot start CodexExecHarness while busy');
    }
    _cancelRequested = false;
    _state = WorkerState.idle;
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
    late final Completer<Map<String, dynamic>> completer;
    await _withLock(() async {
      if (_state == WorkerState.busy) {
        throw StateError('CodexExecHarness is not idle (state: $_state)');
      }
      if (messages.isEmpty) {
        throw StateError('CodexExecHarness requires at least one message');
      }

      _state = WorkerState.busy;
      _cancelRequested = false;
      completer = Completer<Map<String, dynamic>>();
      _turnCompleter = completer;
      _processReadyCompleter = Completer<void>();
    });

    final codexEnvironment = CodexEnvironment(
      developerInstructions: _developerInstructions(systemPrompt),
      mcpServerUrl: harnessConfig.mcpServerUrl,
      mcpGatewayToken: harnessConfig.mcpGatewayToken,
    );
    await codexEnvironment.setup();
    final stderrLines = <String>[];
    final spawnSettled = Completer<void>();
    final prompt = codexStringifyMessageContent(messages.last['content']);
    final resolvedModel = model ?? harnessConfig.model;
    final args = <String>[
      'exec',
      '--json',
      '--full-auto',
      '--ephemeral',
      '--skip-git-repo-check',
      '--sandbox',
      sandboxMode,
      '--cd',
      directory ?? cwd,
      if (resolvedModel != null && resolvedModel.trim().isNotEmpty) ...['-m', resolvedModel],
      prompt,
    ];

    Future<void> cleanup() async {
      await _stdoutSub?.cancel();
      _stdoutSub = null;
      await _stderrSub?.cancel();
      _stderrSub = null;
      _activeProcess = null;
      _turnCompleter = null;
      if (_processReadyCompleter != null && !_processReadyCompleter!.isCompleted) {
        _processReadyCompleter!.complete();
      }
      _processReadyCompleter = null;
      _cancelRequested = false;
      if (_state != WorkerState.stopped) {
        _state = WorkerState.idle;
      }
      await codexEnvironment.cleanup();
    }

    unawaited(() async {
      try {
        final process = await processFactory(
          codexExecutable,
          args,
          workingDirectory: directory ?? cwd,
          environment: <String, String>{...environment, ...codexEnvironment.environmentOverrides()},
          includeParentEnvironment: false,
        );
        _activeProcess = process;
        if (_processReadyCompleter != null && !_processReadyCompleter!.isCompleted) {
          _processReadyCompleter!.complete();
        }
        if (_cancelRequested || completer.isCompleted) {
          process.kill(ProcessSignal.sigterm);
        }

        _stdoutSub = process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .where((line) => line.trim().isNotEmpty)
            .listen(_handleStdoutLine);
        _stderrSub = process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
          stderrLines.add(line);
          _log.fine('codex exec stderr: $line');
        });

        final exitCode = await process.exitCode;
        await Future<void>.delayed(Duration.zero);
        if (!completer.isCompleted) {
          if (exitCode != 0) {
            completer.complete({
              'stop_reason': 'error',
              'error': stderrLines.isEmpty ? 'codex exec exited with code $exitCode' : stderrLines.join('\n'),
            });
          } else {
            completer.complete(_minimalTurnResult());
          }
        }
      } catch (error) {
        if (!completer.isCompleted) {
          completer.complete({'stop_reason': 'error', 'error': 'codex exec failed to start: $error'});
        }
      } finally {
        if (!spawnSettled.isCompleted) {
          spawnSettled.complete();
        }
      }
    }());

    final timeoutTimer = Timer(turnTimeout, () {
      if (completer.isCompleted) {
        return;
      }
      completer.complete({'stop_reason': 'error', 'error': 'Codex exec turn exceeded $turnTimeout'});
      unawaited(cancel());
    });

    try {
      return await completer.future;
    } finally {
      timeoutTimer.cancel();
      if (spawnSettled.isCompleted || _activeProcess != null) {
        await cleanup();
      } else {
        unawaited(spawnSettled.future.then((_) => cleanup()));
      }
    }
  }

  @override
  Future<void> cancel() async {
    _cancelRequested = true;
    final process = _activeProcess;
    if (process == null) {
      return;
    }
    process.kill(ProcessSignal.sigterm);
  }

  @override
  Future<void> stop() async {
    Completer<Map<String, dynamic>>? completer;
    await _withLock(() async {
      completer = _turnCompleter;
      _state = WorkerState.stopped;
    });

    final process = _activeProcess;
    await cancel();
    if (completer != null && !completer!.isCompleted) {
      completer!.complete({'stop_reason': 'error', 'error': 'CodexExecHarness stopped'});
    }
    // Ensure the process actually exits after SIGTERM.
    if (process != null) {
      await _killWithEscalation(process);
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    if (!_eventsCtrl.isClosed) {
      await _eventsCtrl.close();
    }
  }

  void _handleStdoutLine(String line) {
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
      case proto.TurnComplete(:final stopReason, :final inputTokens, :final outputTokens, :final cachedInputTokens):
        final completer = _turnCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.complete({
            'stop_reason': stopReason ?? 'end_turn',
            'input_tokens': inputTokens ?? 0,
            'output_tokens': outputTokens ?? 0,
            'cached_input_tokens': cachedInputTokens ?? 0,
          });
        }
      case proto.ControlRequest():
      case proto.SystemInit():
        return;
    }
  }

  Map<String, dynamic> _minimalTurnResult() {
    return <String, dynamic>{
      'stop_reason': 'end_turn',
      'input_tokens': 0,
      'output_tokens': 0,
      'cached_input_tokens': 0,
    };
  }

  /// Sends SIGTERM (via [cancel]), waits [_killGracePeriod], then escalates
  /// to SIGKILL. After SIGKILL, waits up to 1 additional second for confirmed
  /// exit.
  Future<void> _killWithEscalation(Process process) async {
    try {
      await process.exitCode.timeout(
        _killGracePeriod,
        onTimeout: () async {
          _log.warning(
            'Codex exec process did not exit within '
            '${_killGracePeriod.inSeconds}s after SIGTERM, sending SIGKILL',
          );
          if (!Platform.isWindows) {
            process.kill(ProcessSignal.sigkill);
          }
          return process.exitCode.timeout(
            const Duration(seconds: 1),
            onTimeout: () => -1,
          );
        },
      );
    } catch (e) {
      _log.fine('Error waiting for Codex exec process exit: $e');
    }
  }

  Future<T> _withLock<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    final next = _lock.catchError((_) {}).then((_) => operation());
    _lock = next.then<void>((_) {}, onError: (_) {});
    next.then(completer.complete, onError: completer.completeError);
    return completer.future;
  }

  String _developerInstructions(String systemPrompt) {
    final parts = <String>[
      if (harnessConfig.appendSystemPrompt != null && harnessConfig.appendSystemPrompt!.trim().isNotEmpty)
        harnessConfig.appendSystemPrompt!.trim(),
      if (systemPrompt.trim().isNotEmpty) systemPrompt.trim(),
    ];
    return parts.join('\n\n');
  }
}
