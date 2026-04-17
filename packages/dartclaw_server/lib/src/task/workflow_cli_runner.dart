import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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
  final int newInputTokens;
  final double? totalCostUsd;
  final Duration duration;

  WorkflowCliTurnResult({
    required this.providerSessionId,
    required this.responseText,
    this.structuredOutput,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    int? newInputTokens,
    this.totalCostUsd,
    this.duration = Duration.zero,
  }) : newInputTokens = newInputTokens ?? math.max(0, inputTokens - cacheReadTokens);
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
    String? appendSystemPrompt,
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
          options: providerConfig.options,
          settingSourcesProject: profileContainer == null,
          containerManager: profileContainer,
          hostWorkingDirectory: workingDirectory,
          providerSessionId: providerSessionId,
          model: model,
          effort: effort,
          maxTurns: maxTurns,
          jsonSchema: jsonSchema,
          appendSystemPrompt: appendSystemPrompt,
        ),
        'codex' => _buildCodexCommand(
          prompt: prompt,
          providerSessionId: providerSessionId,
          model: model,
          effort: effort,
          jsonSchema: jsonSchema,
          schemaDirectory: workingDirectory,
          containerManager: profileContainer,
          appendSystemPrompt: appendSystemPrompt,
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
      // Close stdin immediately – Codex 0.120.0+ reads from stdin when a pipe
      // is detected, even when a prompt argument is provided. Without EOF the
      // process blocks on "Reading additional input from stdin…" indefinitely.
      await process.stdin.close();
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode;
      final stdout = await stdoutFuture;
      final stderr = await stderrFuture;
      stopwatch.stop();

      if (exitCode != 0) {
        // For Codex --json mode, the real error is often in stdout (as JSON
        // events like {"type":"error",...}), while stderr may only contain
        // informational messages like "Reading additional input from stdin...".
        final errorDetails = <String>[
          if (stderr.trim().isNotEmpty) stderr.trim(),
          if (stdout.trim().isNotEmpty && provider == 'codex')
            'stdout: ${stdout.trim().length > 500 ? '${stdout.trim().substring(0, 500)}…' : stdout.trim()}',
        ];
        throw StateError(
          'Workflow one-shot $provider command failed with exit code $exitCode'
          '${errorDetails.isEmpty ? '' : ': ${errorDetails.join('; ')}'}',
        );
      }

      return switch (provider) {
        'claude' => _parseClaude(stdout, fallbackDuration: stopwatch.elapsed),
        'codex' => _parseCodex(stdout, fallbackDuration: stopwatch.elapsed),
        _ => throw UnsupportedError('Unsupported provider "$provider"'),
      };
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
    required Map<String, dynamic> options,
    required bool settingSourcesProject,
    required ContainerExecutor? containerManager,
    required String hostWorkingDirectory,
    String? providerSessionId,
    String? model,
    String? effort,
    int? maxTurns,
    Map<String, dynamic>? jsonSchema,
    String? appendSystemPrompt,
  }) {
    final permissionMode = _claudePermissionMode(options);
    final settings = _claudeSettings(
      options,
      containerManager: containerManager,
      hostWorkingDirectory: hostWorkingDirectory,
    );
    final args = <String>[
      '-p',
      '--output-format',
      'json',
      if (settingSourcesProject) ...['--setting-sources', 'project'],
      if (providerSessionId != null) ...['--resume', providerSessionId],
      if (maxTurns != null) ...['--max-turns', '$maxTurns'],
      if (jsonSchema != null) ...['--json-schema', jsonEncode(jsonSchema)],
      if (appendSystemPrompt != null && appendSystemPrompt.trim().isNotEmpty) ...[
        '--append-system-prompt',
        appendSystemPrompt,
      ],
      if (model != null && model.trim().isNotEmpty) ...['--model', model],
      if (effort != null && effort.trim().isNotEmpty) ...['--effort', effort],
      if (permissionMode != null) ...['--permission-mode', permissionMode] else '--dangerously-skip-permissions',
      if (settings != null) ...['--settings', settings],
      prompt,
    ];
    return _WorkflowCliCommand((providers['claude']!.executable, args));
  }

  _WorkflowCliCommand _buildCodexCommand({
    required String prompt,
    String? providerSessionId,
    String? model,
    String? effort,
    Map<String, dynamic>? jsonSchema,
    required String schemaDirectory,
    required ContainerExecutor? containerManager,
    String? appendSystemPrompt,
  }) {
    final args = <String>['exec', '--json', '--full-auto', '--skip-git-repo-check'];
    if (model != null && model.trim().isNotEmpty) {
      args.addAll(['--model', model]);
    }
    if (effort != null && effort.trim().isNotEmpty) {
      args.addAll(['-c', 'model_reasoning_effort="$effort"']);
    }
    if (appendSystemPrompt != null && appendSystemPrompt.trim().isNotEmpty) {
      args.addAll(['-c', 'developer_instructions=${jsonEncode(appendSystemPrompt)}']);
    }
    final sandbox = providers['codex']?.options['sandbox']?.toString().trim();
    if (sandbox != null && sandbox.isNotEmpty) {
      args.addAll(['--sandbox', sandbox]);
    }
    // Codex 0.120.0+ removed --ask-for-approval; approval behavior is now
    // controlled by --full-auto (already set above) and --sandbox.
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
    return _WorkflowCliCommand(
      (providers['codex']!.executable, args),
      tempSchemaPath: schemaPath,
    );
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
            inputTokens = (usage['input_tokens'] as num?)?.toInt() ?? inputTokens;
            outputTokens = (usage['output_tokens'] as num?)?.toInt() ?? outputTokens;
            cacheReadTokens = (usage['cache_read_tokens'] as num?)?.toInt() ?? cacheReadTokens;
            cacheWriteTokens = (usage['cache_write_tokens'] as num?)?.toInt() ?? cacheWriteTokens;
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

  static String? _claudePermissionMode(Map<String, dynamic> options) {
    final raw = options['permissionMode'];
    if (raw == null) return null;
    if (raw is! String) {
      throw StateError('Unsupported Claude permissionMode "${raw.runtimeType}"');
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    const nonInteractive = {'bypassPermissions', 'dontAsk'};
    const interactive = {'acceptEdits', 'auto', 'default', 'plan'};
    if (interactive.contains(trimmed)) {
      throw StateError(
        'Claude workflow one-shot mode does not support interactive permissionMode "$trimmed". '
        'Use a noninteractive mode or the long-lived harness path instead.',
      );
    }
    if (!nonInteractive.contains(trimmed)) {
      throw StateError('Unsupported Claude permissionMode "$trimmed"');
    }
    return trimmed;
  }

  static String? _claudeSettings(
    Map<String, dynamic> options, {
    required ContainerExecutor? containerManager,
    required String hostWorkingDirectory,
  }) {
    final settings = <String, dynamic>{};

    final baseSettings = options['settings'];
    switch (baseSettings) {
      case null:
        break;
      case final String raw:
        final trimmed = raw.trim();
        if (trimmed.isEmpty) break;
        if (!options.containsKey('sandbox') && !options.containsKey('permissions')) {
          if (containerManager != null) {
            try {
              jsonDecode(trimmed);
            } on FormatException {
              final hostPath = p.isAbsolute(trimmed) ? trimmed : p.normalize(p.join(hostWorkingDirectory, trimmed));
              final translated = containerManager.containerPathForHostPath(hostPath);
              if (translated == null) {
                throw StateError('Claude settings path is not mounted in the container: $hostPath');
              }
              return translated;
            }
          }
          return trimmed;
        }
        if (options.containsKey('sandbox') || options.containsKey('permissions')) {
          try {
            final decoded = jsonDecode(trimmed);
            if (decoded is Map<String, dynamic>) {
              settings.addAll(decoded);
              break;
            }
            if (decoded is Map<dynamic, dynamic>) {
              settings.addAll(_stringifyDynamicMap(decoded));
              break;
            }
            _log.warning(
              'Claude workflow CLI options include raw "settings" plus structured "sandbox"/"permissions", '
              'but the raw settings JSON is not an object; structured settings are ignored.',
            );
            return trimmed;
          } on FormatException {
            if (containerManager != null) {
              final hostPath = p.isAbsolute(trimmed) ? trimmed : p.normalize(p.join(hostWorkingDirectory, trimmed));
              final translated = containerManager.containerPathForHostPath(hostPath);
              if (translated == null) {
                throw StateError('Claude settings path is not mounted in the container: $hostPath');
              }
              return translated;
            }
            _log.warning(
              'Claude workflow CLI options include settings path "$trimmed" plus structured '
              '"sandbox"/"permissions"; structured settings are ignored for path-based settings.',
            );
            return trimmed;
          }
        }
        return trimmed;
      case final Map<dynamic, dynamic> rawMap:
        settings.addAll(_stringifyDynamicMap(rawMap));
      default:
        _log.warning('Ignoring unsupported Claude settings option type: ${baseSettings.runtimeType}');
    }

    final sandbox = options['sandbox'];
    if (sandbox is Map<dynamic, dynamic>) {
      _deepMergeInto(settings, {'sandbox': _stringifyDynamicMap(sandbox)});
    } else if (sandbox != null) {
      _log.warning('Ignoring unsupported Claude sandbox option type: ${sandbox.runtimeType}');
    }

    final permissions = options['permissions'];
    if (permissions is Map<dynamic, dynamic>) {
      _deepMergeInto(settings, {'permissions': _stringifyDynamicMap(permissions)});
    } else if (permissions != null) {
      _log.warning('Ignoring unsupported Claude permissions option type: ${permissions.runtimeType}');
    }

    if (settings.isEmpty) return null;
    return jsonEncode(settings);
  }

  static Map<String, dynamic> _stringifyDynamicMap(Map<dynamic, dynamic> source) {
    return source.map((key, value) {
      final normalizedValue = switch (value) {
        final Map<dynamic, dynamic> nested => _stringifyDynamicMap(nested),
        final List<dynamic> list =>
          list.map((item) => item is Map<dynamic, dynamic> ? _stringifyDynamicMap(item) : item).toList(growable: false),
        _ => value,
      };
      return MapEntry(key.toString(), normalizedValue);
    });
  }

  static void _deepMergeInto(Map<String, dynamic> target, Map<String, dynamic> overlay) {
    for (final entry in overlay.entries) {
      final existing = target[entry.key];
      final incoming = entry.value;
      if (existing is Map<String, dynamic> && incoming is Map<String, dynamic>) {
        _deepMergeInto(existing, incoming);
      } else {
        target[entry.key] = incoming;
      }
    }
  }
}

class _WorkflowCliCommand {
  final (String, List<String>) command;
  final String? tempSchemaPath;

  const _WorkflowCliCommand(this.command, {this.tempSchemaPath});
}
