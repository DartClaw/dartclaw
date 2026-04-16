import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show ContainerExecutor;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

typedef WorkflowCliProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

class WorkflowCliProviderConfig {
  final String executable;
  final Map<String, String> environment;
  final Map<String, dynamic> options;

  const WorkflowCliProviderConfig({
    required this.executable,
    this.environment = const <String, String>{},
    this.options = const <String, dynamic>{},
  });
}

class WorkflowCliTurnResult {
  final String providerSessionId;
  final String responseText;
  final Map<String, dynamic>? structuredOutput;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final double? totalCostUsd;
  final Duration duration;

  const WorkflowCliTurnResult({
    required this.providerSessionId,
    required this.responseText,
    this.structuredOutput,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.totalCostUsd,
    this.duration = Duration.zero,
  });
}

class WorkflowCliRunner {
  static final _log = Logger('WorkflowCliRunner');

  final Map<String, WorkflowCliProviderConfig> providers;
  final Map<String, ContainerExecutor> containerManagers;
  final WorkflowCliProcessStarter _processStarter;
  final Uuid _uuid;

  WorkflowCliRunner({
    required this.providers,
    this.containerManagers = const <String, ContainerExecutor>{},
    WorkflowCliProcessStarter? processStarter,
    Uuid? uuid,
  }) : _processStarter = processStarter ?? _defaultProcessStarter,
       _uuid = uuid ?? const Uuid();

  Future<WorkflowCliTurnResult> executeTurn({
    required String provider,
    required String prompt,
    required String workingDirectory,
    required String profileId,
    String? providerSessionId,
    String? model,
    String? effort,
    int? maxTurns,
    Map<String, dynamic>? jsonSchema,
  }) async {
    final providerConfig = providers[provider];
    if (providerConfig == null) {
      throw StateError('No workflow CLI provider config for "$provider"');
    }
    final profileContainer = containerManagers[profileId];

    final stopwatch = Stopwatch()..start();
    String? tempSchemaPath;
    try {
      final builtCommand = switch (provider) {
        'claude' => _buildClaudeCommand(
          prompt: prompt,
          providerSessionId: providerSessionId,
          model: model,
          effort: effort,
          maxTurns: maxTurns,
          jsonSchema: jsonSchema,
        ),
        'codex' => _buildCodexCommand(
          prompt: prompt,
          providerSessionId: providerSessionId,
          model: model,
          jsonSchema: jsonSchema,
          schemaDirectory: workingDirectory,
          containerManager: profileContainer,
        ),
        _ => throw UnsupportedError('Workflow one-shot CLI is not implemented for provider "$provider"'),
      };
      final command = builtCommand.command;
      tempSchemaPath = builtCommand.tempSchemaPath;
      final resolvedWorkingDirectory = _resolveWorkingDirectory(workingDirectory, profileContainer);

      final process = await _startProcess(
        executable: command.$1,
        arguments: command.$2,
        workingDirectory: resolvedWorkingDirectory,
        environment: providerConfig.environment,
        containerManager: profileContainer,
      );
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode;
      final stdout = await stdoutFuture;
      final stderr = await stderrFuture;
      stopwatch.stop();

      if (exitCode != 0) {
        throw StateError(
          'Workflow one-shot $provider command failed with exit code $exitCode'
          '${stderr.trim().isEmpty ? '' : ': ${stderr.trim()}'}',
        );
      }

      return switch (provider) {
        'claude' => _parseClaude(stdout, fallbackDuration: stopwatch.elapsed),
        'codex' => _parseCodex(stdout, fallbackDuration: stopwatch.elapsed),
        _ => throw UnsupportedError('Unsupported provider "$provider"'),
      };
    } finally {
      if (tempSchemaPath != null) {
        await File(tempSchemaPath).delete().catchError((Object error, StackTrace stackTrace) {
          _log.warning('Failed to delete temporary Codex schema file at $tempSchemaPath', error, stackTrace);
        });
      }
    }
  }

  Future<Process> _startProcess({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required Map<String, String> environment,
    required ContainerExecutor? containerManager,
  }) {
    if (containerManager != null) {
      final command = <String>[executable, ...arguments];
      return containerManager.exec(command, env: environment, workingDirectory: workingDirectory);
    }
    return _processStarter(executable, arguments, workingDirectory: workingDirectory, environment: environment);
  }

  String _resolveWorkingDirectory(String workingDirectory, ContainerExecutor? containerManager) {
    if (containerManager == null) {
      return workingDirectory;
    }
    final translated = containerManager.containerPathForHostPath(workingDirectory);
    if (translated == null) {
      throw StateError('Requested working directory is not mounted in the container: $workingDirectory');
    }
    return translated;
  }

  _WorkflowCliCommand _buildClaudeCommand({
    required String prompt,
    String? providerSessionId,
    String? model,
    String? effort,
    int? maxTurns,
    Map<String, dynamic>? jsonSchema,
  }) {
    final args = <String>[
      '-p',
      '--output-format',
      'json',
      if (providerSessionId != null) ...['--resume', providerSessionId],
      if (maxTurns != null) ...['--max-turns', '$maxTurns'],
      if (jsonSchema != null) ...['--json-schema', jsonEncode(jsonSchema)],
      if (model != null && model.trim().isNotEmpty) ...['--model', model],
      if (effort != null && effort.trim().isNotEmpty) ...['--effort', effort],
      '--dangerously-skip-permissions',
      prompt,
    ];
    return _WorkflowCliCommand((providers['claude']!.executable, args));
  }

  _WorkflowCliCommand _buildCodexCommand({
    required String prompt,
    String? providerSessionId,
    String? model,
    Map<String, dynamic>? jsonSchema,
    required String schemaDirectory,
    required ContainerExecutor? containerManager,
  }) {
    final args = <String>['exec', '--json', '--full-auto', '--skip-git-repo-check'];
    if (model != null && model.trim().isNotEmpty) {
      args.addAll(['--model', model]);
    }
    final sandbox = providers['codex']?.options['sandbox']?.toString().trim();
    if (sandbox != null && sandbox.isNotEmpty) {
      args.addAll(['--sandbox', sandbox]);
    }
    final approval = providers['codex']?.options['approval']?.toString().trim();
    if (approval != null && approval.isNotEmpty) {
      args.addAll(['--ask-for-approval', approval]);
    }
    String? schemaPath;
    if (jsonSchema != null) {
      final hostSchemaPath = p.join(schemaDirectory, '.dartclaw-codex-schema-${_uuid.v4()}.json');
      File(hostSchemaPath).writeAsStringSync(jsonEncode(jsonSchema));
      final commandSchemaPath = switch (containerManager) {
        null => hostSchemaPath,
        _ => containerManager.containerPathForHostPath(hostSchemaPath),
      };
      if (commandSchemaPath == null) {
        throw StateError('Temporary Codex schema path is not mounted in the container: $hostSchemaPath');
      }
      schemaPath = hostSchemaPath;
      args.addAll(['--output-schema', commandSchemaPath]);
    }
    if (providerSessionId != null && providerSessionId.isNotEmpty) {
      args.addAll(['resume', providerSessionId]);
    }
    args.add(prompt);
    return _WorkflowCliCommand((providers['codex']!.executable, args), tempSchemaPath: schemaPath);
  }

  WorkflowCliTurnResult _parseClaude(String stdout, {required Duration fallbackDuration}) {
    final decoded = jsonDecode(stdout) as Map<String, dynamic>;
    final subtype = decoded['subtype'] as String?;
    if (subtype == 'error_max_structured_output_retries' || subtype == 'error_max_turns') {
      _log.warning('Claude structured output fell back due to subtype "$subtype"');
    }
    return WorkflowCliTurnResult(
      providerSessionId: (decoded['session_id'] as String?) ?? '',
      responseText: (decoded['result'] as String?) ?? '',
      structuredOutput: decoded['structured_output'] is Map<String, dynamic>
          ? decoded['structured_output'] as Map<String, dynamic>
          : null,
      inputTokens: (decoded['input_tokens'] as num?)?.toInt() ?? 0,
      outputTokens: (decoded['output_tokens'] as num?)?.toInt() ?? 0,
      cacheReadTokens: (decoded['cache_read_tokens'] as num?)?.toInt() ?? 0,
      cacheWriteTokens: (decoded['cache_write_tokens'] as num?)?.toInt() ?? 0,
      totalCostUsd: (decoded['total_cost_usd'] as num?)?.toDouble(),
      duration: Duration(milliseconds: (decoded['duration_ms'] as num?)?.toInt() ?? fallbackDuration.inMilliseconds),
    );
  }

  WorkflowCliTurnResult _parseCodex(String stdout, {required Duration fallbackDuration}) {
    String providerSessionId = '';
    String responseText = '';
    int inputTokens = 0;
    int outputTokens = 0;
    int cacheReadTokens = 0;
    int cacheWriteTokens = 0;

    for (final line in const LineSplitter().convert(stdout)) {
      if (line.trim().isEmpty) continue;
      final event = jsonDecode(line) as Map<String, dynamic>;
      final type = event['type'] as String?;
      switch (type) {
        case 'thread.started':
          providerSessionId = (event['thread_id'] as String?) ?? providerSessionId;
        case 'item.completed':
          final item = event['item'];
          if (item is Map<String, dynamic>) {
            final itemType = item['type'] as String?;
            if (itemType == 'agent_message' || itemType == 'agentMessage') {
              responseText = (item['text'] as String?) ?? (item['delta'] as String?) ?? responseText;
            }
          }
        case 'turn.completed':
          final usage = event['usage'];
          if (usage is Map<String, dynamic>) {
            inputTokens += (usage['input_tokens'] as num?)?.toInt() ?? 0;
            outputTokens += (usage['output_tokens'] as num?)?.toInt() ?? 0;
            cacheReadTokens += (usage['cache_read_tokens'] as num?)?.toInt() ?? 0;
            cacheWriteTokens += (usage['cache_write_tokens'] as num?)?.toInt() ?? 0;
          }
      }
    }

    Map<String, dynamic>? structuredOutput;
    final trimmed = responseText.trim();
    if (trimmed.startsWith('{')) {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        structuredOutput = decoded;
      }
    }

    return WorkflowCliTurnResult(
      providerSessionId: providerSessionId,
      responseText: responseText,
      structuredOutput: structuredOutput,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadTokens: cacheReadTokens,
      cacheWriteTokens: cacheWriteTokens,
      duration: fallbackDuration,
    );
  }

  static Future<Process> _defaultProcessStarter(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    return Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
    );
  }
}

class _WorkflowCliCommand {
  final (String, List<String>) command;
  final String? tempSchemaPath;

  const _WorkflowCliCommand(this.command, {this.tempSchemaPath});
}
