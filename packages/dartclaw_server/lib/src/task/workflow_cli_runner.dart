import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dartclaw_core/dartclaw_core.dart' show ContainerExecutor, EventBus, WorkflowCliTurnProgressEvent;
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'codex_profile_manager.dart';

typedef WorkflowCliProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

/// YAML-decoded provider configuration for workflow one-shot execution.
///
/// The [options] map is intentionally untyped because it mirrors authored
/// workflow/provider YAML directly; callers must normalize individual keys
/// before using them.
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
  /// Provider-owned conversation/session identifier returned by the CLI.
  final String providerSessionId;

  /// Raw assistant text returned by the provider after protocol parsing.
  final String responseText;

  /// Provider-enforced structured payload, when available.
  final Map<String, dynamic>? structuredOutput;

  /// Total input tokens reported by the provider for the turn.
  final int inputTokens;

  /// Total output tokens reported by the provider for the turn.
  final int outputTokens;

  /// Cache-read tokens reported by the provider for the turn.
  final int cacheReadTokens;

  /// Cache-write tokens reported by the provider for the turn.
  final int cacheWriteTokens;

  /// Fresh input tokens derived from provider telemetry normalization.
  final int newInputTokens;

  /// Reported cost, when the provider exposes it.
  final double? totalCostUsd;

  /// End-to-end turn duration, including process startup and parsing.
  final Duration duration;

  WorkflowCliTurnResult({
    required this.providerSessionId,
    required this.responseText,
    this.structuredOutput,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    required this.newInputTokens,
    this.totalCostUsd,
    this.duration = Duration.zero,
  });
}

class WorkflowCliRunner {
  static final _log = Logger('WorkflowCliRunner');

  final Map<String, WorkflowCliProviderConfig> providers;
  final Map<String, ContainerExecutor> containerManagers;
  final EventBus? _eventBus;
  final WorkflowCliProcessStarter _processStarter;
  final Uuid _uuid;

  /// Resolved Codex profile manager — non-null when any provider opted
  /// into `isolated_profile: true` and construction-time validation
  /// succeeded. Created eagerly (but only as a lightweight in-memory
  /// object, no I/O) so failures surface at startup rather than
  /// mid-workflow. `ensurePrepared()` is still called lazily on first
  /// use, with its own memoisation handling concurrent callers.
  final CodexProfileManager? _codexProfile;

  /// In-flight preparation future — memoised here so that multiple
  /// concurrent `executeTurn` invocations (parallel map iterations,
  /// multiple bound groups) share a single `ensurePrepared()` call.
  Future<void>? _codexPrepareFuture;

  WorkflowCliRunner({
    required this.providers,
    this.containerManagers = const <String, ContainerExecutor>{},
    EventBus? eventBus,
    WorkflowCliProcessStarter? processStarter,
    Uuid? uuid,
    String? dataDir,
    CodexProfileManager? codexProfile,
  }) : _processStarter = processStarter ?? _defaultProcessStarter,
       _eventBus = eventBus,
       _uuid = uuid ?? const Uuid(),
       _codexProfile = _resolveCodexProfile(providers: providers, dataDir: dataDir, preInjected: codexProfile);

  @visibleForTesting
  (String, List<String>) buildCodexCommandForTesting({
    required String prompt,
    String? providerSessionId,
    String? model,
    String? effort,
    Map<String, dynamic>? jsonSchema,
    required String schemaDirectory,
    ContainerExecutor? containerManager,
    String? appendSystemPrompt,
    String? sandboxOverride,
  }) {
    return _buildCodexCommand(
      prompt: prompt,
      providerSessionId: providerSessionId,
      model: model,
      effort: effort,
      jsonSchema: jsonSchema,
      schemaDirectory: schemaDirectory,
      containerManager: containerManager,
      appendSystemPrompt: appendSystemPrompt,
      sandboxOverride: sandboxOverride,
    ).command;
  }

  /// Builds (and validates) the Codex profile manager at construction
  /// time so opt-in mistakes fail loud at server startup instead of
  /// mid-workflow. Returns null when no provider opted into the
  /// isolated profile.
  ///
  /// Throws [ArgumentError] when the opt-in is on but either the
  /// materialisation root (`dataDir`) or the source credential is
  /// missing — both were silent-fallback footguns before.
  static CodexProfileManager? _resolveCodexProfile({
    required Map<String, WorkflowCliProviderConfig> providers,
    required String? dataDir,
    required CodexProfileManager? preInjected,
  }) {
    final optIn = providers.values.any((p) => _boolOption(p.options, 'isolated_profile'));
    if (!optIn) return null;

    final profile = preInjected ?? (dataDir == null ? null : CodexProfileManager.forDataDir(dataDir));
    if (profile == null) {
      throw ArgumentError.value(
        null,
        'dataDir',
        'WorkflowCliRunner: providers.codex.options.isolated_profile is true but no dataDir '
            'was supplied and no CodexProfileManager was pre-injected. Pass a dataDir or disable '
            'the isolated profile.',
      );
    }
    if (!profile.hasValidAuthSync()) {
      throw ArgumentError.value(
        profile.sourceAuthPath,
        'auth.json',
        'WorkflowCliRunner: isolated_profile is enabled but source auth.json was not found at '
            '${profile.sourceAuthPath}. Log in with `codex login` first, or disable the isolated '
            'profile.',
      );
    }
    return profile;
  }

  /// Reads [key] from [options] as a bool.
  ///
  /// Accepts native `bool` as well as the YAML-string forms `"true"` /
  /// `"false"` (case-insensitive) since workflow authors often hand us
  /// options decoded from YAML which preserves scalars as strings. Any
  /// other shape logs a warning and falls back to `false` — don't
  /// silently misinterpret typos as "disabled".
  static bool _boolOption(Map<String, dynamic> options, String key) {
    final raw = options[key];
    if (raw == null) return false;
    if (raw is bool) return raw;
    if (raw is String) {
      final lower = raw.trim().toLowerCase();
      if (lower == 'true') return true;
      if (lower == 'false') return false;
      _log.warning('Ignoring unsupported string value "$raw" for boolean option "$key"; treating as false');
      return false;
    }
    _log.warning('Ignoring unsupported type ${raw.runtimeType} for boolean option "$key"; treating as false');
    return false;
  }

  /// Executes a one-shot turn for [provider].
  ///
  /// Supports only `claude` and `codex`. When [sandboxOverride] is provided it
  /// takes precedence over `providers[provider].options['sandbox']` after
  /// resolving the stricter effective sandbox. stdin is always closed
  /// immediately after spawn so Codex does not hang waiting for piped input.
  Future<WorkflowCliTurnResult> executeTurn({
    required String provider,
    required String prompt,
    required String workingDirectory,
    required String profileId,
    String? taskId,
    String? sessionId,
    String? providerSessionId,
    String? model,
    String? effort,
    int? maxTurns,
    Map<String, dynamic>? jsonSchema,
    String? appendSystemPrompt,
    String? sandboxOverride,
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
          sandboxOverride: sandboxOverride,
        ),
        _ => throw UnsupportedError('Workflow one-shot CLI is not implemented for provider "$provider"'),
      };
      final command = builtCommand.command;
      tempSchemaPath = builtCommand.tempSchemaPath;
      final resolvedWorkingDirectory = _resolveWorkingDirectory(workingDirectory, profileContainer);

      // Codex-only: when the isolated-profile opt-in is set and a manager
      // was injected at construction, prepare + layer in CODEX_HOME/HOME
      // overrides so this invocation sees the managed profile instead of
      // the user's `~/.codex` (bypassing the bloated global skill registry).
      final resolvedEnvironment = await _resolveProcessEnvironment(provider, providerConfig);

      final process = await _startProcess(
        executable: command.$1,
        arguments: command.$2,
        workingDirectory: resolvedWorkingDirectory,
        environment: resolvedEnvironment,
        containerManager: profileContainer,
      );
      // Close stdin immediately – Codex 0.120.0+ reads from stdin when a pipe
      // is detected, even when a prompt argument is provided. Without EOF the
      // process blocks on "Reading additional input from stdin…" indefinitely.
      await process.stdin.close();
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();
      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();
      final codexState = provider == 'codex' ? _CodexStreamState() : null;

      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              stdoutBuffer.writeln(line);
              if (provider == 'codex' && codexState != null) {
                _handleCodexLine(line, codexState, taskId: taskId, sessionId: sessionId, emitProgress: true);
              }
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!stdoutDone.isCompleted) {
                stdoutDone.completeError(error, stackTrace);
              }
            },
            onDone: () {
              if (!stdoutDone.isCompleted) {
                stdoutDone.complete();
              }
            },
            cancelOnError: true,
          );
      process.stderr
          .transform(utf8.decoder)
          .listen(
            stderrBuffer.write,
            onError: (Object error, StackTrace stackTrace) {
              if (!stderrDone.isCompleted) {
                stderrDone.completeError(error, stackTrace);
              }
            },
            onDone: () {
              if (!stderrDone.isCompleted) {
                stderrDone.complete();
              }
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
    String? sandboxOverride,
  }) {
    final sandboxDecision = _CodexSandboxDecision(
      defaultSandbox: providers['codex']?.options['sandbox']?.toString(),
      sandboxOverride: sandboxOverride,
    );
    final args = <String>[
      'exec',
      '--json',
      if (!sandboxDecision.hasExplicitSandbox) '--full-auto',
      '--skip-git-repo-check',
      '-c',
      'approval_policy="never"',
    ];
    if (model != null && model.trim().isNotEmpty) {
      args.addAll(['--model', model]);
    }
    if (effort != null && effort.trim().isNotEmpty) {
      args.addAll(['-c', 'model_reasoning_effort="$effort"']);
    }
    if (appendSystemPrompt != null && appendSystemPrompt.trim().isNotEmpty) {
      args.addAll(['-c', 'developer_instructions=${jsonEncode(appendSystemPrompt)}']);
    }
    if (sandboxDecision.sandbox != null) {
      args.addAll(['--sandbox', sandboxDecision.sandbox!]);
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
      newInputTokens: (decoded['input_tokens'] as num?)?.toInt() ?? 0,
      totalCostUsd: (decoded['total_cost_usd'] as num?)?.toDouble(),
      duration: Duration(milliseconds: (decoded['duration_ms'] as num?)?.toInt() ?? fallbackDuration.inMilliseconds),
    );
  }

  void _handleCodexLine(
    String line,
    _CodexStreamState state, {
    String? taskId,
    String? sessionId,
    bool emitProgress = false,
  }) {
    if (line.trim().isEmpty) return;

    Map<String, dynamic>? event;
    try {
      event = _mapValue(jsonDecode(line));
    } on FormatException {
      _log.fine('WorkflowCliRunner: ignoring non-JSON Codex stdout line: ${_previewText(line)}');
      return;
    }
    if (event == null) return;

    final type = event['type'] as String?;
    switch (type) {
      case 'thread.started':
        state.providerSessionId = (event['thread_id'] as String?) ?? state.providerSessionId;
        break;

      case 'turn.started':
        if (emitProgress) {
          _log.info(
            'WorkflowCliRunner: ${taskId == null ? 'workflow turn' : 'task $taskId'} '
            'started for codex thread '
            '${state.providerSessionId.isEmpty ? '<pending>' : state.providerSessionId}',
          );
        }
        break;

      case 'item.completed':
        final item = _mapValue(event['item']);
        if (item == null) break;
        final itemType = item['type'] as String?;
        if (itemType == 'agent_message' || itemType == 'agentMessage') {
          state.responseText = (item['text'] as String?) ?? (item['delta'] as String?) ?? state.responseText;
          if (emitProgress && state.responseText.trim().isNotEmpty) {
            _log.fine('WorkflowCliRunner: codex agent message completed: ${_previewText(state.responseText)}');
          }
        }
        break;

      case 'turn.completed':
        final usage = _mapValue(event['usage']);
        if (usage == null) break;

        _log.fine('WorkflowCliRunner: raw codex turn.completed usage payload: $usage');

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
            'WorkflowCliRunner: ${taskId == null ? 'workflow' : 'task $taskId'} '
            'turn ${state.turnCount} completed (+$deltaTokens tokens, cumulative $cumulativeTokens)',
          );
          _eventBus?.fire(
            WorkflowCliTurnProgressEvent(
              taskId: taskId ?? '',
              sessionId: sessionId ?? '',
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

  WorkflowCliTurnResult _buildCodexTurnResult(_CodexStreamState state, {required Duration fallbackDuration}) {
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

  WorkflowCliTurnResult _parseCodex(String stdout, {required Duration fallbackDuration}) {
    final state = _CodexStreamState();
    for (final line in const LineSplitter().convert(stdout)) {
      _handleCodexLine(line, state);
    }
    return _buildCodexTurnResult(state, fallbackDuration: fallbackDuration);
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

  int _codexOutputTokens(Map<String, dynamic> usage, {required int fallback}) {
    final outputTokens = _intValue(usage['output_tokens']) ?? fallback;
    final outputTokensDetails = _mapValue(usage['output_tokens_details']);
    final reasoningTokens = _intValue(outputTokensDetails?['reasoning_tokens']);
    if (reasoningTokens != null) {
      _log.fine(
        'WorkflowCliRunner: codex usage reported reasoning_tokens=$reasoningTokens '
        'inside output_tokens_details; treating it as part of output_tokens.',
      );
    }
    return outputTokens;
  }

  static String _previewText(String text, {int maxLength = 120}) {
    final singleLine = text.replaceAll('\n', ' ').trim();
    if (singleLine.length <= maxLength) {
      return singleLine;
    }
    return '${singleLine.substring(0, maxLength)}...';
  }

  Future<Map<String, String>> _resolveProcessEnvironment(
    String provider,
    WorkflowCliProviderConfig providerConfig,
  ) async {
    if (provider != 'codex' || !_boolOption(providerConfig.options, 'isolated_profile')) {
      return providerConfig.environment;
    }
    final profile = _codexProfile;
    if (profile == null) {
      // Unreachable in practice — if any provider opted in we validated
      // at construction. Belt-and-braces: don't produce a malformed env.
      throw StateError(
        'isolated_profile=true but no CodexProfileManager was resolved at construction; '
        'this is a bug in WorkflowCliRunner wiring.',
      );
    }
    // Memoise the in-flight preparation so parallel turns share a
    // single materialisation.
    await (_codexPrepareFuture ??= profile.ensurePrepared());
    // Profile overrides win — we want `CODEX_HOME` / `HOME` to always
    // point at the managed dir even if the user set them elsewhere.
    return {...providerConfig.environment, ...profile.envOverrides()};
  }

  static Future<Process> _defaultProcessStarter(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    return SafeProcess.start(
      executable,
      arguments,
      env: EnvPolicy.passthrough(environment: environment ?? const <String, String>{}),
      workingDirectory: workingDirectory,
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
