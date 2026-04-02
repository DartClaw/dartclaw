import 'dart:async';
import 'dart:io';

import '../bridge/bridge_events.dart';
import 'package:logging/logging.dart';

import 'agent_harness.dart';
import 'base_harness.dart';
import 'codex_environment.dart';
import 'codex_exec_protocol_adapter.dart';
import 'codex_protocol_utils.dart';
import 'harness_config.dart';
import 'process_types.dart';
import 'protocol_message.dart' as proto;
import '../worker/worker_state.dart';

/// Lightweight one-shot harness for `codex exec --json`.
class CodexExecHarness extends BaseHarness {
  /// Codex executable path or binary name.
  final String codexExecutable;

  /// Sandbox mode passed to `codex exec`.
  final String sandboxMode;

  /// Environment passed to each Codex subprocess.
  final Map<String, String> environment;

  /// Exec-mode protocol adapter used for stdout parsing.
  final CodexExecProtocolAdapter adapter;

  static final _log = Logger('CodexExecHarness');

  Completer<Map<String, dynamic>>? _turnCompleter;
  Completer<void>? _processReadyCompleter;
  bool _cancelRequested = false;
  List<String>? _stderrLines;

  /// Grace period after SIGTERM before escalating to SIGKILL.
  final Duration _killGracePeriod;

  // ignore: use_super_parameters
  CodexExecHarness({
    required String cwd,
    this.codexExecutable = 'codex',
    this.sandboxMode = 'danger-full-access',
    Duration turnTimeout = const Duration(seconds: 600),
    ProcessFactory? processFactory,
    Map<String, String>? environment,
    HarnessConfig harnessConfig = const HarnessConfig(),
    CodexExecProtocolAdapter? adapter,
    Duration killGracePeriod = const Duration(seconds: 2),
  }) : environment = environment ?? Platform.environment,
       adapter = adapter ?? CodexExecProtocolAdapter(),
       _killGracePeriod = killGracePeriod,
       super(
         log: _log,
         cwd: cwd,
         turnTimeout: turnTimeout,
         maxRetries: 0,
         baseBackoff: Duration.zero,
         processFactory: processFactory ?? Process.start,
         commandProbe: Process.run,
         delayFactory: Future<void>.delayed,
         harnessConfig: harnessConfig,
       );

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
  Future<void> start() => startLifecycle(
    busyMessage: 'Cannot start CodexExecHarness while busy',
    beforeStart: () async {
      _cancelRequested = false;
    },
    start: () async {
      currentState = WorkerState.idle;
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
    late final Completer<Map<String, dynamic>> completer;
    await withLock(() async {
      if (currentState == WorkerState.busy) {
        throw StateError('CodexExecHarness is not idle (state: $currentState)');
      }
      if (messages.isEmpty) {
        throw StateError('CodexExecHarness requires at least one message');
      }

      currentState = WorkerState.busy;
      _cancelRequested = false;
      _stderrLines = <String>[];
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
    final spawnSettled = Completer<void>();
    final prompt = stringifyMessageContent(messages.last['content']);
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
      await cancelTrackedSubscriptions();
      currentProcess = null;
      _turnCompleter = null;
      if (_processReadyCompleter != null && !_processReadyCompleter!.isCompleted) {
        _processReadyCompleter!.complete();
      }
      _processReadyCompleter = null;
      _stderrLines = null;
      _cancelRequested = false;
      if (currentState != WorkerState.stopped) {
        currentState = WorkerState.idle;
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
        attachProcess(process, dropEmptyStdoutLines: true, watchForUnexpectedExit: false);
        if (_processReadyCompleter != null && !_processReadyCompleter!.isCompleted) {
          _processReadyCompleter!.complete();
        }
        if (_cancelRequested || completer.isCompleted) {
          process.kill(ProcessSignal.sigterm);
        }

        final exitCode = await process.exitCode;
        await Future<void>.delayed(Duration.zero);
        if (!completer.isCompleted) {
          if (exitCode != 0) {
            final stderrLines = _stderrLines ?? const <String>[];
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
      if (spawnSettled.isCompleted || currentProcess != null) {
        await cleanup();
      } else {
        unawaited(spawnSettled.future.then((_) => cleanup()));
      }
    }
  }

  @override
  Future<void> cancel() async {
    _cancelRequested = true;
    final process = currentProcess;
    if (process == null) {
      return;
    }
    process.kill(ProcessSignal.sigterm);
  }

  @override
  Future<void> stop() async {
    Completer<Map<String, dynamic>>? completer;
    await withLock(() async {
      completer = _turnCompleter;
      currentState = WorkerState.stopped;
    });

    final process = currentProcess;
    await cancel();
    if (completer != null && !completer!.isCompleted) {
      completer!.complete({'stop_reason': 'error', 'error': 'CodexExecHarness stopped'});
    }
    // Ensure the process actually exits after SIGTERM (cancel() already sent it).
    if (process != null) {
      await shutdownCurrentProcess(
        label: 'Codex exec',
        gracePeriod: _killGracePeriod,
        alreadySignalled: true,
        process: process,
      );
    }
  }

  @override
  void handleProcessStdoutLine(String line) {
    final message = adapter.parseLine(line);
    if (message == null) {
      return;
    }

    switch (message) {
      case proto.TextDelta(:final text):
        emitEvent(DeltaEvent(text));
      case proto.ToolUse(:final name, :final id, :final input):
        emitEvent(ToolUseEvent(toolName: name, toolId: id, input: input));
      case proto.ToolResult(:final toolId, :final output, :final isError):
        emitEvent(ToolResultEvent(toolId: toolId, output: output, isError: isError));
      case proto.TurnComplete(
        :final stopReason,
        :final inputTokens,
        :final outputTokens,
        :final cacheReadTokens,
        :final cacheWriteTokens,
      ):
        final completer = _turnCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.complete({
            'stop_reason': stopReason ?? 'end_turn',
            'input_tokens': inputTokens ?? 0,
            'output_tokens': outputTokens ?? 0,
            'cache_read_tokens': cacheReadTokens ?? 0,
            'cache_write_tokens': cacheWriteTokens ?? 0,
          });
        }
      case proto.ControlRequest():
      case proto.SystemInit():
        return;
    }
  }

  @override
  void handleProcessStderrLine(String line) {
    _stderrLines?.add(line);
    _log.fine('codex exec stderr: $line');
  }

  @override
  void handleUnexpectedProcessExit(int exitCode) {}

  Map<String, dynamic> _minimalTurnResult() {
    return <String, dynamic>{
      'stop_reason': 'end_turn',
      'input_tokens': 0,
      'output_tokens': 0,
      'cache_read_tokens': 0,
      'cache_write_tokens': 0,
    };
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
