import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dartclaw_core/dartclaw_core.dart' show WorkflowCliTurnProgressEvent, stringValue;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'claude_cli_provider.dart' show resolveContainerWorkDir, startCliProcess;
import 'workflow_cli_runner.dart';

/// [CliProvider] implementation for the Codex CLI one-shot runner.
///
/// Owns command construction, JSONL streaming parse, temp-schema-file lifecycle,
/// and [WorkflowCliTurnProgressEvent] emission for multi-turn Codex runs.
class CodexCliProvider implements CliProvider {
  static final _log = Logger('CodexCliProvider');

  const CodexCliProvider();

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
    try {
      final process = await startCliProcess(
        executable: command.$1,
        arguments: command.$2,
        workingDirectory: resolvedWorkDir,
        environment: env,
        containerManager: req.containerManager,
        processStarter: req.processStarter,
      );
      // Close stdin immediately – Codex 0.120.0+ reads from stdin when a pipe
      // is detected, even when a prompt argument is provided. Without EOF the
      // process blocks on "Reading additional input from stdin…" indefinitely.
      await process.stdin.close();

      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();
      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();
      final codexState = _CodexStreamState();

      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              stdoutBuffer.writeln(line);
              _handleLine(line, codexState, req: req, emitProgress: true);
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!stdoutDone.isCompleted) stdoutDone.completeError(error, stackTrace);
            },
            onDone: () {
              if (!stdoutDone.isCompleted) stdoutDone.complete();
            },
            cancelOnError: true,
          );
      process.stderr
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

      final exitCode = await process.exitCode;
      await stdoutDone.future;
      await stderrDone.future;
      final stdout = stdoutBuffer.toString();
      final stderr = stderrBuffer.toString();
      stopwatch.stop();

      if (exitCode != 0) {
        // For Codex --json mode, the real error is often in stdout (as JSON
        // events like {"type":"error",...}), while stderr may only contain
        // informational messages like "Reading additional input from stdin...".
        final errorDetails = <String>[
          if (stderr.trim().isNotEmpty) stderr.trim(),
          if (stdout.trim().isNotEmpty)
            'stdout: ${stdout.trim().length > 500 ? '${stdout.trim().substring(0, 500)}…' : stdout.trim()}',
        ];
        throw StateError(
          'Workflow one-shot codex command failed with exit code $exitCode'
          '${errorDetails.isEmpty ? '' : ': ${errorDetails.join('; ')}'}',
        );
      }

      return _parseResult(stdout, fallbackDuration: stopwatch.elapsed);
    } finally {
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

  void _handleLine(String line, _CodexStreamState state, {required CliTurnRequest req, bool emitProgress = false}) {
    if (line.trim().isEmpty) return;

    Map<String, dynamic>? event;
    try {
      event = _mapValue(jsonDecode(line));
    } on FormatException {
      _log.fine('CodexCliProvider: ignoring non-JSON Codex stdout line: ${_previewText(line)}');
      return;
    }
    if (event == null) return;

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
        final usage = _mapValue(event['usage']);
        if (usage == null) break;

        _log.fine('CodexCliProvider: raw codex turn.completed usage payload: $usage');

        final previousCumulative = state.inputTokens + state.outputTokens;
        state.inputTokens = _intValue(usage['input_tokens']) ?? state.inputTokens;
        state.outputTokens = _codexOutputTokens(usage, fallback: state.outputTokens);
        state.cacheReadTokens =
            _intValue(usage['cache_read_tokens']) ?? _intValue(usage['cached_input_tokens']) ?? state.cacheReadTokens;
        state.cacheWriteTokens = _intValue(usage['cache_write_tokens']) ?? state.cacheWriteTokens;
        state.turnCount++;

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

      default:
        break;
    }
  }

  WorkflowCliTurnResult _parseResult(String stdout, {required Duration fallbackDuration}) {
    final state = _CodexStreamState();
    for (final line in const LineSplitter().convert(stdout)) {
      _handleLine(line, state, req: _parseReq, emitProgress: false);
    }
    return _buildTurnResult(state, fallbackDuration: fallbackDuration);
  }

  WorkflowCliTurnResult _buildTurnResult(_CodexStreamState state, {required Duration fallbackDuration}) {
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
    return WorkflowCliTurnResult(
      providerSessionId: state.providerSessionId,
      responseText: state.responseText,
      structuredOutput: structuredOutput,
      inputTokens: state.inputTokens,
      outputTokens: state.outputTokens,
      cacheReadTokens: state.cacheReadTokens,
      cacheWriteTokens: state.cacheWriteTokens,
      newInputTokens: math.max(0, state.inputTokens - state.cacheReadTokens),
      duration: fallbackDuration,
    );
  }

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

// Minimal req used for the post-parse pass – no event emission, no spawning.
final _parseReq = CliTurnRequest(
  prompt: '',
  workingDirectory: '',
  profileId: '',
  providerConfig: const WorkflowCliProviderConfig(executable: ''),
  containerManager: null,
  processStarter: (exe, args, {workingDirectory, environment}) => throw UnimplementedError(),
  uuid: const Uuid(),
  log: Logger('_codexParsePass'),
);

final class _CodexSandboxDecision {
  static const _rankBySandbox = <String, int>{'read-only': 0, 'workspace-write': 1, 'danger-full-access': 2};

  final String? sandbox;
  final bool hasExplicitSandbox;

  factory _CodexSandboxDecision({String? defaultSandbox, String? sandboxOverride}) {
    final normalizedDefault = _normalize(defaultSandbox);
    final normalizedOverride = _normalize(sandboxOverride);
    final resolvedSandbox = _resolve(normalizedDefault, normalizedOverride);
    assert(
      normalizedDefault == null ||
          normalizedOverride == null ||
          resolvedSandbox == _stricter(normalizedDefault, normalizedOverride),
      'Codex sandbox resolution must preserve the stricter authored sandbox value.',
    );
    return _CodexSandboxDecision._(resolvedSandbox);
  }

  const _CodexSandboxDecision._(this.sandbox) : hasExplicitSandbox = sandbox != null;

  static String? _normalize(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _resolve(String? defaultSandbox, String? sandboxOverride) {
    if (sandboxOverride == null) return defaultSandbox;
    if (defaultSandbox == null) return sandboxOverride;
    return _stricter(defaultSandbox, sandboxOverride);
  }

  static String _stricter(String left, String right) {
    if (left == right) return left;
    final leftRank = _rankBySandbox[left];
    final rightRank = _rankBySandbox[right];
    if (leftRank == null || rightRank == null) {
      throw StateError(
        'Unsupported Codex sandbox combination: default="$left", override="$right". '
        'Update _CodexSandboxDecision before adding new sandbox names.',
      );
    }
    return leftRank <= rightRank ? left : right;
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
}

class _CodexCommand {
  final (String, List<String>) command;
  final String? tempSchemaPath;

  const _CodexCommand(this.command, {this.tempSchemaPath});
}
