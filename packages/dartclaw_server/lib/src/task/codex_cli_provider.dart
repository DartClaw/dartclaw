import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dartclaw_core/dartclaw_core.dart' show WorkflowCliTurnProgressEvent, stringValue;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'claude_cli_provider.dart' show resolveContainerWorkDir, startCliProcess;
import 'cli_process_supervisor.dart';
import 'workflow_cli_runner.dart';

part 'codex_cli_provider_types.dart';

/// [CliProvider] implementation for the Codex CLI one-shot runner.
///
/// Owns command construction, JSONL streaming parse, temp-schema-file lifecycle,
/// and [WorkflowCliTurnProgressEvent] emission for multi-turn Codex runs.
class CodexCliProvider extends ProcessBackedCliProvider {
  static final _log = Logger('CodexCliProvider');

  CodexCliProvider({
    super.platformCapabilities,
    super.terminationGracePeriod,
    super.outputDrainGracePeriod,
    this.maxOutputBytes = CliProcessSupervisor.defaultOutputLimitBytes,
  });

  final int maxOutputBytes;

  static const _maxUsageEntries = 512;

  final Map<String, _CodexUsageSnapshot> _usageByRequestKey = <String, _CodexUsageSnapshot>{};

  @override
  Future<WorkflowCliTurnResult> run(CliTurnRequest req) async {
    final built = _buildCommand(req);
    final command = built.command;
    final String? tempSchemaPath = built.tempSchemaPath;
    final resolvedWorkDir = resolveContainerWorkDir(req.workingDirectory, req.containerManager);

    final env = req.extraEnvironment == null || req.extraEnvironment!.isEmpty
        ? req.providerConfig.environment
        : {...req.providerConfig.environment, ...req.extraEnvironment!};

    final stopwatch = Stopwatch()..start();
    Process? process;
    CliProcessSupervisor? supervisor;
    try {
      process = await startCliProcess(
        executable: command.$1,
        arguments: command.$2,
        workingDirectory: resolvedWorkDir,
        environment: env,
        containerManager: req.containerManager,
        processStarter: req.processStarter,
      );
      trackInflightProcess(process);
      supervisor = CliProcessSupervisor(
        process: process,
        provider: 'codex',
        stepName: req.stepName,
        stallTimeout: req.stallTimeout,
        stallAction: req.stallAction,
        stepTimeout: req.stepTimeout,
        eventBus: req.eventBus,
        log: req.log,
        processTerminator: () => terminateInflightProcess(process!),
        externalCancellation: inflightCancellation(process),
        platformCapabilities: platformCapabilities,
        terminationGrace: terminationGracePeriod,
        outputDrainGrace: outputDrainGracePeriod,
        maxOutputBytes: maxOutputBytes,
      )..start();
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();
      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();
      final codexState = _CodexStreamState();
      var terminalResultRecorded = false;

      final stdoutSubscription = supervisor
          .limitOutput(process.stdout, streamName: 'stdout')
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              stdoutBuffer.writeln(line);
              if (_handleLine(line, codexState, req: req, emitProgress: true)) {
                supervisor?.recordParsedOutput();
              }
              if (!terminalResultRecorded && codexState.terminalResultRecorded) {
                terminalResultRecorded = true;
                supervisor?.recordTerminalResult();
              }
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!stdoutDone.isCompleted) stdoutDone.completeError(error, stackTrace);
            },
            onDone: () {
              if (!stdoutDone.isCompleted) stdoutDone.complete();
            },
            cancelOnError: true,
          );
      final stderrSubscription = supervisor
          .limitOutput(process.stderr, streamName: 'stderr')
          .transform(utf8.decoder)
          .listen(
            stderrBuffer.write,
            onError: (Object error, StackTrace stackTrace) {
              if (!stderrDone.isCompleted) stderrDone.completeError(error, stackTrace);
            },
            onDone: () {
              if (!stderrDone.isCompleted) stderrDone.complete();
            },
            cancelOnError: true,
          );
      cancelFutureStartedProcessIfRequested(process);
      // Close stdin immediately – Codex 0.120.0+ reads from stdin when a pipe
      // is detected, even when a prompt argument is provided. Without EOF the
      // process blocks on "Reading additional input from stdin…" indefinitely.
      try {
        await process.stdin.close();
      } catch (_) {
        if (cancellationRequestedFor(process)) {
          final termination = await waitForInflightTermination(process);
          final exitCode = termination?.exitConfirmed == true ? await process.exitCode : -1;
          await waitForCliOutputDrain(
            supervisor: supervisor,
            stdoutDone: stdoutDone.future,
            stderrDone: stderrDone.future,
            cancelSubscriptions: () async {
              await Future.wait([stdoutSubscription.cancel(), stderrSubscription.cancel()], eagerError: false);
            },
          );
          stopwatch.stop();
          final stdout = stdoutBuffer.toString();
          if (_hasCodexFailureEvidence(stdout, stderrBuffer.toString())) {
            throw _codexNonZeroExitError(exitCode, stdout, stderrBuffer.toString());
          }
          return WorkflowCliTurnResult.cancelled(duration: stopwatch.elapsed);
        }
        rethrow;
      }

      final exitCode = await supervisor.waitForExitCode();
      await waitForCliOutputDrain(
        supervisor: supervisor,
        stdoutDone: stdoutDone.future,
        stderrDone: stderrDone.future,
        cancelSubscriptions: () async {
          await Future.wait([stdoutSubscription.cancel(), stderrSubscription.cancel()], eagerError: false);
        },
      );
      supervisor.stop();
      final stdout = stdoutBuffer.toString();
      final stderr = stderrBuffer.toString();
      stopwatch.stop();

      final hasProviderFailureEvidence = _hasCodexFailureEvidence(stdout, stderr);
      final cancellationResult = cancellationResultForExit(
        process: process,
        supervisor: supervisor,
        duration: stopwatch.elapsed,
        hasProviderFailureEvidence: hasProviderFailureEvidence,
      );
      if (cancellationResult != null) return cancellationResult;
      if (exitCode != 0) {
        if (hasProviderFailureEvidence || shouldThrowForNonZeroExit(process, supervisor)) {
          throw _codexNonZeroExitError(exitCode, stdout, stderr);
        }
      }

      return _parseResult(stdout, req: req, fallbackDuration: stopwatch.elapsed);
    } finally {
      supervisor?.stop();
      final activeProcess = process;
      if (activeProcess != null) {
        finishInflightRun(activeProcess);
      }
      if (tempSchemaPath != null) {
        try {
          await File(tempSchemaPath).delete();
        } catch (error, stackTrace) {
          _log.warning('Failed to delete temporary Codex schema file at $tempSchemaPath', error, stackTrace);
        }
      }
    }
  }

  /// Exposed for command-vector assertions without spawning a process.
  /// Called from [WorkflowCliRunner.buildCodexCommandForTesting].
  (String, List<String>) buildCommandForTesting({
    required String prompt,
    String? providerSessionId,
    String? model,
    String? effort,
    Map<String, dynamic>? jsonSchema,
    required String schemaDirectory,
    required WorkflowCliProviderConfig providerConfig,
    String? appendSystemPrompt,
    String? sandboxOverride,
  }) {
    final req = CliTurnRequest(
      prompt: prompt,
      workingDirectory: schemaDirectory,
      profileId: '',
      providerSessionId: providerSessionId,
      model: model,
      effort: effort,
      jsonSchema: jsonSchema,
      appendSystemPrompt: appendSystemPrompt,
      sandboxOverride: sandboxOverride,
      providerConfig: providerConfig,
      containerManager: null,
      processStarter: (exe, args, {workingDirectory, environment}) => throw UnimplementedError(),
      uuid: const Uuid(),
      log: _log,
    );
    return _buildCommand(req).command;
  }

  StateError _codexNonZeroExitError(int exitCode, String stdout, String stderr) {
    // For Codex --json mode, the real error is often in stdout (as JSON events
    // like {"type":"error",...}), while stderr may only contain informational
    // messages like "Reading additional input from stdin...".
    final errorDetails = <String>[
      if (stderr.trim().isNotEmpty) stderr.trim(),
      if (stdout.trim().isNotEmpty)
        'stdout: ${stdout.trim().length > 500 ? '${stdout.trim().substring(0, 500)}…' : stdout.trim()}',
    ];
    return StateError(
      'Workflow one-shot codex command failed with exit code $exitCode'
      '${errorDetails.isEmpty ? '' : ': ${errorDetails.join('; ')}'}',
    );
  }

  bool _hasCodexFailureEvidence(String stdout, String stderr) {
    for (final line in const LineSplitter().convert(stdout)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is! Map<String, dynamic>) continue;
        final type = stringValue(decoded['type']);
        if (type == 'error' || type == 'turn.failed') return true;
      } on FormatException {
        continue;
      }
    }
    return hasNonBenignStderr(stderr, _codexBenignStderrLines);
  }

  // Codex prints this to stderr while draining a piped stdin; it is not a
  // failure signal. Everything else on stderr is treated as genuine evidence
  // so a stderr-only provider error is never masked as a cancellation.
  static const List<String> _codexBenignStderrLines = [
    'Reading additional input from stdin...',
    'Reading additional input from stdin…',
  ];

  _CodexCommand _buildCommand(CliTurnRequest req) {
    // Codex CLI has no tool-allowlist flag. Sandbox and approval policy are
    // the enforcement levers, so allowedTools is advisory for Codex.
    final requestedAllowedTools = req.allowedTools?.where((tool) => tool.trim().isNotEmpty).toList(growable: false);
    if (requestedAllowedTools != null && requestedAllowedTools.isNotEmpty && !req.readOnly) {
      _log.fine('Codex one-shot ignores workflow allowedTools: $requestedAllowedTools');
    }
    final sandboxDecision = _CodexSandboxDecision(
      defaultSandbox: req.providerConfig.options['sandbox']?.toString(),
      sandboxOverride: req.readOnly ? 'read-only' : req.sandboxOverride,
    );
    final args = <String>[
      'exec',
      '--json',
      if (!sandboxDecision.hasExplicitSandbox) '--full-auto',
      '--skip-git-repo-check',
      '-c',
      'approval_policy="never"',
    ];
    if (req.model != null && req.model!.trim().isNotEmpty) {
      args.addAll(['--model', req.model!]);
    }
    if (req.effort != null && req.effort!.trim().isNotEmpty) {
      args.addAll(['-c', 'model_reasoning_effort="${req.effort}"']);
    }
    if (req.appendSystemPrompt != null && req.appendSystemPrompt!.trim().isNotEmpty) {
      args.addAll(['-c', 'developer_instructions=${jsonEncode(req.appendSystemPrompt)}']);
    }
    if (sandboxDecision.sandbox != null) {
      args.addAll(['--sandbox', sandboxDecision.sandbox!]);
    }
    // Codex 0.120.0+ removed --ask-for-approval; approval behavior is now
    // controlled by --full-auto (already set above) and --sandbox.
    String? schemaPath;
    if (req.jsonSchema != null) {
      final hostSchemaPath = p.join(req.workingDirectory, '.dartclaw-codex-schema-${req.uuid.v4()}.json');
      File(hostSchemaPath).writeAsStringSync(jsonEncode(req.jsonSchema));
      final commandSchemaPath = switch (req.containerManager) {
        null => hostSchemaPath,
        _ => req.containerManager!.containerPathForHostPath(hostSchemaPath),
      };
      if (commandSchemaPath == null) {
        throw StateError('Temporary Codex schema path is not mounted in the container: $hostSchemaPath');
      }
      schemaPath = hostSchemaPath;
      args.addAll(['--output-schema', commandSchemaPath]);
    }
    if (req.providerSessionId != null && req.providerSessionId!.isNotEmpty) {
      args.addAll(['resume', req.providerSessionId!]);
    }
    args.add(req.prompt);
    return _CodexCommand((req.providerConfig.executable, args), tempSchemaPath: schemaPath);
  }

  bool _handleLine(String line, _CodexStreamState state, {required CliTurnRequest req, bool emitProgress = false}) {
    if (line.trim().isEmpty) return false;

    Map<String, dynamic>? event;
    try {
      event = _mapValue(jsonDecode(line));
    } on FormatException {
      _log.fine('CodexCliProvider: ignoring non-JSON Codex stdout line: ${_previewText(line)}');
      return false;
    }
    if (event == null) return false;

    final type = stringValue(event['type']);
    switch (type) {
      case 'thread.started':
        state.providerSessionId = stringValue(event['thread_id']) ?? state.providerSessionId;
        break;

      case 'turn.started':
        if (emitProgress) {
          _log.info(
            'CodexCliProvider: ${req.taskId == null ? 'workflow turn' : 'task ${req.taskId}'} '
            'started for codex thread '
            '${state.providerSessionId.isEmpty ? '<pending>' : state.providerSessionId}',
          );
        }
        break;

      case 'item.started':
      case 'item.updated':
        break;

      case 'item.completed':
        final item = _mapValue(event['item']);
        if (item == null) break;
        final itemType = stringValue(item['type']);
        if (itemType == 'agent_message' || itemType == 'agentMessage') {
          state.responseText = stringValue(item['text']) ?? stringValue(item['delta']) ?? state.responseText;
          if (emitProgress && state.responseText.trim().isNotEmpty) {
            _log.fine('CodexCliProvider: codex agent message completed: ${_previewText(state.responseText)}');
          }
        }
        break;

      case 'turn.completed':
        final previousCumulative = state.inputTokens + state.outputTokens;
        state.turnCount++;
        state.terminalResultRecorded = true;

        final usage = _mapValue(event['usage']);
        if (usage != null) {
          _log.fine('CodexCliProvider: raw codex turn.completed usage payload: $usage');
          state.inputTokens = _intValue(usage['input_tokens']) ?? state.inputTokens;
          state.outputTokens = _codexOutputTokens(usage, fallback: state.outputTokens);
          state.cacheReadTokens =
              _intValue(usage['cache_read_tokens']) ?? _intValue(usage['cached_input_tokens']) ?? state.cacheReadTokens;
          state.cacheWriteTokens = _intValue(usage['cache_write_tokens']) ?? state.cacheWriteTokens;
        }

        if (emitProgress) {
          final cumulativeTokens = state.inputTokens + state.outputTokens;
          final deltaTokens = math.max(0, cumulativeTokens - previousCumulative);
          _log.info(
            'CodexCliProvider: ${req.taskId == null ? 'workflow' : 'task ${req.taskId}'} '
            'turn ${state.turnCount} completed (+$deltaTokens tokens, cumulative $cumulativeTokens)',
          );
          req.eventBus?.fire(
            WorkflowCliTurnProgressEvent(
              taskId: req.taskId ?? '',
              sessionId: req.sessionId ?? '',
              provider: 'codex',
              turnIndex: state.turnCount,
              cumulativeTokens: cumulativeTokens,
              inputTokens: state.inputTokens,
              outputTokens: state.outputTokens,
              cacheReadTokens: state.cacheReadTokens,
              cacheWriteTokens: state.cacheWriteTokens,
              timestamp: DateTime.now(),
            ),
          );
        }
        break;

      case 'turn.failed':
      case 'error':
        break;

      default:
        return false;
    }
    return true;
  }

  WorkflowCliTurnResult _parseResult(String stdout, {required CliTurnRequest req, required Duration fallbackDuration}) {
    final state = _CodexStreamState();
    for (final line in const LineSplitter().convert(stdout)) {
      _handleLine(line, state, req: req, emitProgress: false);
    }
    return _buildTurnResult(state, req: req, fallbackDuration: fallbackDuration);
  }

  WorkflowCliTurnResult _buildTurnResult(
    _CodexStreamState state, {
    required CliTurnRequest req,
    required Duration fallbackDuration,
  }) {
    Map<String, dynamic>? structuredOutput;
    final trimmed = state.responseText.trim();
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          structuredOutput = decoded;
        }
      } on FormatException {
        _log.fine(
          'Codex one-shot response began with "{" but was not a standalone JSON object; '
          'leaving responseText unparsed for downstream workflow-context extraction.',
        );
      }
    }
    final currentUsage = _CodexUsageSnapshot.fromState(state);
    final usageKey = _usageKey(req, state);
    final previousUsage = switch (usageKey) {
      final String key => _usageByRequestKey[key] ?? _initialUsageBaseline(req, state),
      _ => const _CodexUsageSnapshot(),
    };
    if (usageKey != null) {
      // LRU-on-write with a size cap: the provider is a long-lived pooled
      // singleton, so without eviction every session leaves a permanent entry.
      _usageByRequestKey.remove(usageKey);
      _usageByRequestKey[usageKey] = currentUsage;
      while (_usageByRequestKey.length > _maxUsageEntries) {
        _usageByRequestKey.remove(_usageByRequestKey.keys.first);
      }
    }

    return WorkflowCliTurnResult(
      providerSessionId: state.providerSessionId,
      responseText: state.responseText,
      structuredOutput: structuredOutput,
      inputTokens: _usageDelta(currentUsage.inputTokens, previousUsage.inputTokens),
      outputTokens: _usageDelta(currentUsage.outputTokens, previousUsage.outputTokens),
      cacheReadTokens: _usageDelta(currentUsage.cacheReadTokens, previousUsage.cacheReadTokens),
      cacheWriteTokens: _usageDelta(currentUsage.cacheWriteTokens, previousUsage.cacheWriteTokens),
      newInputTokens: _usageDelta(currentUsage.newInputTokens, previousUsage.newInputTokens),
      duration: fallbackDuration,
    );
  }

  _CodexUsageSnapshot _initialUsageBaseline(CliTurnRequest req, _CodexStreamState state) {
    final providerSessionId = _effectiveProviderSessionId(req, state);
    final requestedProviderSessionId = req.providerSessionId?.trim();
    if (providerSessionId.isEmpty || requestedProviderSessionId == null || requestedProviderSessionId.isEmpty) {
      return const _CodexUsageSnapshot();
    }
    if (providerSessionId != requestedProviderSessionId) {
      return const _CodexUsageSnapshot();
    }
    return _CodexUsageSnapshot.fromBaseline(req.usageBaseline);
  }

  String? _usageKey(CliTurnRequest req, _CodexStreamState state) {
    final providerSessionId = _effectiveProviderSessionId(req, state);
    if (providerSessionId.isEmpty) {
      return null;
    }
    return '${req.sessionId ?? ''}\u0000$providerSessionId';
  }

  String _effectiveProviderSessionId(CliTurnRequest req, _CodexStreamState state) {
    final parsed = state.providerSessionId.trim();
    if (parsed.isNotEmpty) {
      return parsed;
    }
    return req.providerSessionId?.trim() ?? '';
  }

  int _usageDelta(int current, int previous) => current >= previous ? current - previous : current;

  int _codexOutputTokens(Map<String, dynamic> usage, {required int fallback}) {
    final outputTokens = _intValue(usage['output_tokens']) ?? fallback;
    final outputTokensDetails = _mapValue(usage['output_tokens_details']);
    final reasoningTokens = _intValue(outputTokensDetails?['reasoning_tokens']);
    if (reasoningTokens != null) {
      _log.fine(
        'CodexCliProvider: codex usage reported reasoning_tokens=$reasoningTokens '
        'inside output_tokens_details; treating it as part of output_tokens.',
      );
    }
    return outputTokens;
  }

  static Map<String, dynamic>? _mapValue(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  static int? _intValue(Object? value) {
    return switch (value) {
      int() => value,
      num() => value.toInt(),
      String() => int.tryParse(value),
      _ => null,
    };
  }

  static String _previewText(String text, {int maxLength = 120}) {
    final singleLine = text.replaceAll('\n', ' ').trim();
    if (singleLine.length <= maxLength) return singleLine;
    return '${singleLine.substring(0, maxLength)}...';
  }
}

class _CodexStreamState {
  String providerSessionId = '';
  String responseText = '';
  int inputTokens = 0;
  int outputTokens = 0;
  int cacheReadTokens = 0;
  int cacheWriteTokens = 0;
  int turnCount = 0;
  bool terminalResultRecorded = false;
}

final class _CodexUsageSnapshot {
  final int inputTokens;
  final int newInputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

  const _CodexUsageSnapshot({
    this.inputTokens = 0,
    this.newInputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
  });

  factory _CodexUsageSnapshot.fromState(_CodexStreamState state) {
    final newInputTokens = math.max(0, state.inputTokens - state.cacheReadTokens);
    return _CodexUsageSnapshot(
      inputTokens: state.inputTokens,
      newInputTokens: newInputTokens,
      outputTokens: state.outputTokens,
      cacheReadTokens: state.cacheReadTokens,
      cacheWriteTokens: state.cacheWriteTokens,
    );
  }

  factory _CodexUsageSnapshot.fromBaseline(WorkflowCliUsageBaseline baseline) => _CodexUsageSnapshot(
    inputTokens: baseline.inputTokens + baseline.cacheReadTokens,
    newInputTokens: baseline.inputTokens,
    outputTokens: baseline.outputTokens,
    cacheReadTokens: baseline.cacheReadTokens,
    cacheWriteTokens: baseline.cacheWriteTokens,
  );
}

class _CodexCommand {
  final (String, List<String>) command;
  final String? tempSchemaPath;

  const _CodexCommand(this.command, {this.tempSchemaPath});
}
