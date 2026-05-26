import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show ClaudeSettingsBuilder, ContainerExecutor, intValue, stringValue;
import 'package:logging/logging.dart';

import 'workflow_cli_runner.dart';

/// [CliProvider] implementation for the Claude CLI one-shot runner.
///
/// Owns command construction, Claude stream-JSON parsing, and interactive
/// permission-mode rejection for the non-interactive workflow path.
class ClaudeCliProvider implements CliProvider {
  static final _log = Logger('ClaudeCliProvider');

  const ClaudeCliProvider();

  @override
  Future<WorkflowCliTurnResult> run(CliTurnRequest req) async {
    final command = _buildCommand(req);
    final resolvedWorkDir = resolveContainerWorkDir(req.workingDirectory, req.containerManager);

    final env = req.extraEnvironment == null || req.extraEnvironment!.isEmpty
        ? req.providerConfig.environment
        : {...req.providerConfig.environment, ...req.extraEnvironment!};

    final stopwatch = Stopwatch()..start();
    final process = await startCliProcess(
      executable: command.$1,
      arguments: command.$2,
      workingDirectory: resolvedWorkDir,
      environment: env,
      containerManager: req.containerManager,
      processStarter: req.processStarter,
    );
    await process.stdin.close();

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    await Future.wait([
      process.stdout.transform(utf8.decoder).forEach(stdoutBuffer.write),
      process.stderr.transform(utf8.decoder).forEach(stderrBuffer.write),
    ]);

    final exitCode = await process.exitCode;
    stopwatch.stop();

    if (exitCode != 0) {
      final stderr = stderrBuffer.toString().trim();
      throw StateError(
        'Workflow one-shot claude command failed with exit code $exitCode'
        '${stderr.isEmpty ? '' : ': $stderr'}',
      );
    }

    return _parse(stdoutBuffer.toString(), fallbackDuration: stopwatch.elapsed);
  }

  (String, List<String>) _buildCommand(CliTurnRequest req) {
    final taskPolicy = _ClaudeTaskPolicy(req.allowedTools, readOnly: req.readOnly);
    final options = _optionsWithTaskPolicy(req.providerConfig.options, taskPolicy);
    final configuredPermissionMode = ClaudeSettingsBuilder.buildPermissionMode(options);
    final permissionMode = _rejectInteractivePermissionMode(
      _permissionModeForTaskPolicy(configuredPermissionMode, taskPolicy),
      taskPolicy,
    );
    final settings = ClaudeSettingsBuilder.buildSettings(
      options,
      containerManager: req.containerManager,
      hostWorkingDirectory: req.workingDirectory,
    );
    if (taskPolicy.hasPolicy && settings != null && !_settingsIsJsonObject(settings)) {
      throw StateError(
        'Claude workflow one-shot task policy cannot be enforced with ${_settingsPolicyUnsupportedReason(settings)}.',
      );
    }
    final settingSourcesProject = req.containerManager == null;
    final args = <String>[
      '-p',
      '--output-format',
      'json',
      if (settingSourcesProject) ...['--setting-sources', 'project'],
      if (req.providerSessionId != null) ...['--resume', req.providerSessionId!],
      if (req.maxTurns != null) ...['--max-turns', '${req.maxTurns}'],
      if (req.jsonSchema != null) ...['--json-schema', jsonEncode(req.jsonSchema)],
      if (req.appendSystemPrompt != null && req.appendSystemPrompt!.trim().isNotEmpty) ...[
        '--append-system-prompt',
        req.appendSystemPrompt!,
      ],
      if (req.model != null && req.model!.trim().isNotEmpty) ...['--model', req.model!],
      if (req.effort != null && req.effort!.trim().isNotEmpty) ...['--effort', req.effort!],
      if (permissionMode != null) ...['--permission-mode', permissionMode] else '--dangerously-skip-permissions',
      if (settings != null) ...['--settings', settings],
      req.prompt,
    ];
    return (req.providerConfig.executable, args);
  }

  WorkflowCliTurnResult _parse(String stdout, {required Duration fallbackDuration}) {
    final decoded = jsonDecode(stdout) as Map<String, dynamic>;
    final subtype = stringValue(decoded['subtype']);
    if (subtype == 'error_max_structured_output_retries' || subtype == 'error_max_turns') {
      _log.warning('Claude structured output fell back due to subtype "$subtype"');
    }
    return WorkflowCliTurnResult(
      providerSessionId: stringValue(decoded['session_id']) ?? '',
      responseText: stringValue(decoded['result']) ?? '',
      structuredOutput: decoded['structured_output'] is Map<String, dynamic>
          ? decoded['structured_output'] as Map<String, dynamic>
          : null,
      inputTokens: intValue(decoded['input_tokens']) ?? 0,
      outputTokens: intValue(decoded['output_tokens']) ?? 0,
      cacheReadTokens: intValue(decoded['cache_read_tokens']) ?? 0,
      cacheWriteTokens: intValue(decoded['cache_write_tokens']) ?? 0,
      newInputTokens: intValue(decoded['input_tokens']) ?? 0,
      totalCostUsd: (decoded['total_cost_usd'] as num?)?.toDouble(),
      duration: Duration(milliseconds: intValue(decoded['duration_ms']) ?? fallbackDuration.inMilliseconds),
    );
  }

  static String? _rejectInteractivePermissionMode(String? mode, _ClaudeTaskPolicy taskPolicy) {
    const interactive = {'acceptEdits', 'auto', 'default', 'plan'};
    if (mode != null && interactive.contains(mode)) {
      throw StateError(
        'Claude workflow one-shot mode does not support interactive permissionMode "$mode". '
        'Use a noninteractive mode or the long-lived harness path instead.',
      );
    }
    if (taskPolicy.hasPolicy && mode == 'bypassPermissions') {
      throw StateError(
        'Claude workflow one-shot task policy cannot be enforced with permissionMode "bypassPermissions".',
      );
    }
    return mode;
  }
}

String? _permissionModeForTaskPolicy(String? configured, _ClaudeTaskPolicy taskPolicy) {
  if (!taskPolicy.hasPolicy) return configured;
  return configured ?? 'dontAsk';
}

Map<String, dynamic> _optionsWithTaskPolicy(Map<String, dynamic> options, _ClaudeTaskPolicy taskPolicy) {
  if (!taskPolicy.hasPolicy) return options;
  final next = Map<String, dynamic>.from(options);
  final permissions = _normalizeMap(next['permissions']);
  final settingsPermissions = _settingsPermissions(next['settings']);
  final allow = taskPolicy.allowPatterns.toList()..sort();
  final deny = {
    ..._stringList(permissions['deny']),
    ..._stringList(settingsPermissions['deny']),
    ...taskPolicy.denyPatterns,
  }.toList()..sort();
  next['permissions'] = {'allow': allow, if (deny.isNotEmpty) 'deny': deny};
  final settingsWithoutPermissions = _settingsWithoutPermissions(next['settings']);
  if (settingsWithoutPermissions == null) {
    next.remove('settings');
  } else {
    next['settings'] = settingsWithoutPermissions;
  }
  if (taskPolicy.readOnly) {
    next['sandbox'] = {..._normalizeMap(next['sandbox']), 'enabled': true};
  }
  return next;
}

Map<String, dynamic> _normalizeMap(Object? value) {
  if (value is Map<String, dynamic>) return Map<String, dynamic>.from(value);
  if (value is Map) return value.map((key, value) => MapEntry('$key', value));
  return <String, dynamic>{};
}

List<String> _stringList(Object? value) {
  if (value is! List) return const <String>[];
  return value.whereType<String>().where((item) => item.trim().isNotEmpty).map((item) => item.trim()).toList();
}

Map<String, dynamic> _settingsPermissions(Object? settings) {
  final settingsMap = _settingsJsonMap(settings);
  if (settingsMap == null) return <String, dynamic>{};
  return _normalizeMap(settingsMap['permissions']);
}

Object? _settingsWithoutPermissions(Object? settings) {
  final settingsMap = _settingsJsonMap(settings);
  if (settingsMap == null) return settings;
  return Map<String, dynamic>.from(settingsMap)..remove('permissions');
}

Map<String, dynamic>? _settingsJsonMap(Object? settings) {
  if (settings is Map<String, dynamic>) return Map<String, dynamic>.from(settings);
  if (settings is Map) return settings.map((key, value) => MapEntry('$key', value));
  if (settings is String) {
    final trimmed = settings.trimLeft();
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return null;
    try {
      final decoded = jsonDecode(settings);
      if (decoded is Map<String, dynamic>) return Map<String, dynamic>.from(decoded);
      if (decoded is Map) return decoded.map((key, value) => MapEntry('$key', value));
    } on FormatException catch (error, stackTrace) {
      ClaudeCliProvider._log.warning(
        'Ignoring malformed Claude settings JSON while merging task policy',
        error,
        stackTrace,
      );
      return null;
    }
  }
  return null;
}

bool _settingsIsJsonObject(String settings) {
  try {
    return jsonDecode(settings) is Map;
  } on FormatException {
    return false;
  }
}

String _settingsPolicyUnsupportedReason(String settings) {
  final trimmed = settings.trimLeft();
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return 'path-based settings';
  try {
    jsonDecode(settings);
  } on FormatException catch (error) {
    return 'malformed JSON settings: ${error.message}';
  }
  return 'non-object JSON settings';
}

final class _ClaudeTaskPolicy {
  _ClaudeTaskPolicy(List<String>? allowedTools, {required this.readOnly})
    : allowedTools =
          allowedTools?.where((tool) => tool.trim().isNotEmpty).map((tool) => tool.trim()).toSet() ?? const <String>{};

  final Set<String> allowedTools;
  final bool readOnly;

  bool get hasPolicy => readOnly || allowedTools.isNotEmpty;

  List<String> get allowPatterns {
    final tools = allowedTools;
    final patterns = <String>{};
    if (tools.isEmpty && !readOnly) return const <String>[];
    if (tools.contains('shell')) {
      patterns.addAll(readOnly ? _readOnlyShellAllowPatterns : const ['Bash(*)']);
    }
    if (_shouldGrantFileReads(tools)) {
      patterns.addAll(['Read(*)', 'Glob(*)', 'Grep(*)', 'LS(*)']);
    }
    if (!readOnly) {
      if (tools.contains('file_write')) patterns.add('Write(*)');
      if (tools.contains('file_edit')) patterns.addAll(['Edit(*)', 'MultiEdit(*)', 'NotebookEdit(*)']);
    }
    if (tools.contains('web_fetch')) patterns.addAll(['WebFetch(*)', 'WebSearch(*)']);
    if (tools.contains('mcp_call')) patterns.add('mcp__*');
    return patterns.toList()..sort();
  }

  List<String> get denyPatterns {
    if (!readOnly) return const <String>[];
    return const ['Edit(*)', 'MultiEdit(*)', 'NotebookEdit(*)', 'Write(*)'];
  }

  bool _shouldGrantFileReads(Set<String> tools) {
    if (!readOnly) return tools.contains('file_read');
    if (tools.isEmpty) return true;
    return tools.contains('file_read') || tools.contains('shell');
  }

  // Only repository status probes: broader file reads are granted separately,
  // but diff/log/blame content is not pulled into prompts by shell.
  static const _readOnlyShellAllowPatterns = [
    'Bash(git ls-files)',
    'Bash(git rev-parse --abbrev-ref HEAD)',
    'Bash(git rev-parse --show-toplevel)',
    'Bash(git status)',
    'Bash(git status --porcelain)',
    'Bash(git status --short)',
    'Bash(pwd)',
  ];
}

/// Translates [workingDirectory] from host path to container path when a
/// [containerManager] is present.
String resolveContainerWorkDir(String workingDirectory, ContainerExecutor? containerManager) {
  if (containerManager == null) return workingDirectory;
  final translated = containerManager.containerPathForHostPath(workingDirectory);
  if (translated == null) {
    throw StateError('Requested working directory is not mounted in the container: $workingDirectory');
  }
  return translated;
}

/// Spawns a CLI process via the [containerManager] exec path or the
/// [processStarter] function for host-side execution.
Future<Process> startCliProcess({
  required String executable,
  required List<String> arguments,
  required String workingDirectory,
  required Map<String, String> environment,
  required ContainerExecutor? containerManager,
  required WorkflowCliProcessStarter processStarter,
}) {
  if (containerManager != null) {
    final command = <String>[executable, ...arguments];
    return containerManager.exec(command, env: environment, workingDirectory: workingDirectory);
  }
  return processStarter(executable, arguments, workingDirectory: workingDirectory, environment: environment);
}
