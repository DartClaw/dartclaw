import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../bridge/bridge_events.dart';
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'package:dartclaw_config/dartclaw_config.dart'
    show ClaudeProviderOptions, HistoryConfig, PlatformCapabilities, UnsupportedCapabilityError;
import '../container/container_executor.dart';
import '../storage/atomic_write.dart';
import '../worker/worker_state.dart';
import 'agent_harness.dart';
import 'base_harness.dart';
import 'base_protocol_adapter.dart';
import 'claude_settings_builder.dart';
import 'claude_protocol_adapter.dart';
import 'claude_protocol.dart';
import 'conversation_history.dart';
import 'harness_config.dart';
import 'protocol_message.dart' as proto;
import 'process_lifecycle.dart';
import 'process_types.dart';
import 'tool_policy.dart';
// Claude CLI configuration

List<String> _buildClaudeArgs({
  String? model,
  String? effort,
  String? appendSystemPrompt,
  String? mcpConfigPath,
  String? permissionMode,
  String? settings,
  bool settingSourcesProject = false,
  bool skipNativePermissions = true,
}) => [
  '--print',
  '--input-format',
  'stream-json',
  '--output-format',
  'stream-json',
  '--verbose',
  '--include-partial-messages',
  '--no-session-persistence',
  if (permissionMode != null) ...['--permission-mode', permissionMode],
  if (permissionMode == null && skipNativePermissions) '--dangerously-skip-permissions',
  if (permissionMode != 'bypassPermissions' && permissionMode != 'dontAsk' && !skipNativePermissions) ...[
    '--permission-prompt-tool',
    'stdio',
  ],
  if (settingSourcesProject) ...['--setting-sources', 'project'],
  '--model',
  model ?? 'opus[1m]',
  if (effort != null) ...['--effort', effort],
  if (appendSystemPrompt != null) ...['--append-system-prompt', appendSystemPrompt],
  if (mcpConfigPath != null) ...['--mcp-config', mcpConfigPath],
  if (settings != null) ...['--settings', settings],
];

/// Env var forwarded from [_environment] to containerized spawns when present.
/// Set at the wiring layer for task runners only.
const _subagentModelEnvVar = 'CLAUDE_CODE_SUBAGENT_MODEL';
// ClaudeCodeHarness

/// Concrete [AgentHarness] that spawns the `claude` binary directly and speaks
/// its JSONL control protocol — no Deno/TypeScript layer required.
class ClaudeCodeHarness extends BaseHarness {
  final String claudeExecutable;
  final Map<String, String> _environment;
  final Map<String, dynamic> providerOptions;
  final ToolApprovalPolicy toolPolicy;
  final GuardChain? guardChain;
  final GuardAuditLogger? auditLogger;
  final HistoryConfig historyConfig;
  final ContainerExecutor? containerManager;
  final ClaudeProtocolAdapter _adapter;
  final Duration _killGracePeriod;
  final Duration _initializeTimeout;

  /// Platform policy used for executable lookup and process semantics.
  final PlatformCapabilities platformCapabilities;

  /// Memory handler callbacks. Used for `sdkMcpServers` fallback in chat mode
  /// (no MCP server). When `harnessConfig.mcpServerUrl` is set, memory tools
  /// are served via the `/mcp` HTTP endpoint instead.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemorySave;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemorySearch;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemoryRead;

  /// Callback fired when Claude Code's own permission layer denies a tool call.
  ///
  /// Receives the native tool name and an optional reason string. Wired by
  /// `HarnessWiring` to emit a [ToolPermissionDeniedEvent] on the EventBus.
  /// Null when permission-denied events are not being observed.
  final void Function(String toolName, String? reason)? onPermissionDenied;

  /// Invoked when a `PreCompact` hook callback is received.
  ///
  /// Parameters: `(sessionId, trigger)`. The wiring layer connects this to
  /// `EventBus.fire(CompactionStartingEvent(...))`.
  void Function(String sessionId, String trigger)? onCompactionStarting;

  /// Invoked when a `compact_boundary` system message is received on stdout.
  ///
  /// Parameters: `(trigger, preTokens)`. The wiring layer connects this to
  /// `EventBus.fire(CompactionCompletedEvent(...))`.
  void Function(String trigger, int? preTokens)? onCompactionCompleted;

  static final _log = Logger('ClaudeCodeHarness');

  String? _mcpConfigPath;
  String? _containerMcpConfigPath;
  int _turnsSinceStart = 0;
  String? _sessionId;
  Completer<Map<String, dynamic>>? _turnCompleter;
  late String _processWorkingDirectory;
  late String _hostProcessWorkingDirectory;
  String? _processModel;
  String? _processEffort;
  int? _processMaxTurns;

  /// Completer for the initialize handshake response.
  Completer<Map<String, dynamic>>? _initCompleter;

  ClaudeCodeHarness({
    this.claudeExecutable = 'claude',
    required super.cwd,
    super.turnTimeout = const Duration(seconds: 600),
    super.maxRetries = 5,
    super.baseBackoff = const Duration(seconds: 5),
    ProcessFactory? processFactory,
    CommandProbe? commandProbe,
    DelayFactory? delayFactory,
    Map<String, String>? environment,
    Map<String, dynamic>? providerOptions,
    this.toolPolicy = ToolApprovalPolicy.allowAll,
    this.guardChain,
    this.auditLogger,
    this.onMemorySave,
    this.onMemorySearch,
    this.onMemoryRead,
    this.onPermissionDenied,
    super.harnessConfig = const HarnessConfig(),
    this.historyConfig = const HistoryConfig.defaults(),
    this.containerManager,
    ClaudeProtocolAdapter? protocolAdapter,
    Duration killGracePeriod = const Duration(seconds: 2),
    Duration initializeTimeout = const Duration(seconds: 10),
    PlatformCapabilities? platformCapabilities,
  }) : _environment = environment ?? Platform.environment,
       providerOptions = Map<String, dynamic>.unmodifiable(providerOptions ?? const <String, dynamic>{}),
       _adapter = protocolAdapter ?? ClaudeProtocolAdapter(),
       _killGracePeriod = killGracePeriod,
       _initializeTimeout = initializeTimeout,
       platformCapabilities = platformCapabilities ?? PlatformCapabilities(),
       super(
         log: _log,
         processFactory: processFactory ?? Process.start,
         commandProbe: commandProbe ?? Process.run,
         delayFactory: delayFactory ?? ((d) => Future<void>.delayed(d)),
       ) {
    _processWorkingDirectory = cwd;
    _hostProcessWorkingDirectory = cwd;
    _processModel = harnessConfig.model;
    _processEffort = harnessConfig.effort;
    _processMaxTurns = harnessConfig.maxTurns;
  }

  @override
  PromptStrategy get promptStrategy => PromptStrategy.append;

  @override
  bool get supportsCachedTokens => true;

  @override
  bool get supportsSessionContinuity => true;

  @override
  String skillActivationLine(String skill) => '/$skill';

  @override
  bool get supportsPreCompactHook => true;

  /// Session ID assigned by the claude binary after init.
  String? get sessionId => _sessionId;
  // Lifecycle

  @override
  Future<void> start() => startLifecycle(
    busyMessage: 'Cannot start: harness is busy',
    beforeStart: () async {
      isStopping = false;
    },
    start: _startWithCleanup,
  );

  Future<void> _startWithCleanup() async {
    try {
      await _startInternal();
    } catch (_) {
      try {
        await _stopInternal();
      } catch (cleanupError, cleanupStackTrace) {
        _log.warning('Claude startup cleanup failed', cleanupError, cleanupStackTrace);
      }
      rethrow;
    }
  }

  @override
  Future<void> cancel() async {
    final process = currentProcess;
    beginIntentionalProcessTeardown(process, platformCapabilities);
    await closeCurrentProcessStdin(process: process);
    if (process == null) return;
    if (platformCapabilities.posixSignalsAvailable) {
      process.kill();
    } else {
      final result = await killWithEscalation(
        process,
        label: 'Claude',
        gracePeriod: _killGracePeriod,
        platformCapabilities: platformCapabilities,
        log: _log,
      );
      completeIntentionalProcessTeardown(process, result, platformCapabilities);
    }
  }

  @override
  Future<void> stop() {
    // Set immediately (before lock) so the exitCode crash handler can
    // distinguish intentional shutdown from unexpected process exit.
    isStopping = true;
    beginIntentionalProcessTeardown(currentProcess, platformCapabilities);
    return withLock(_stopInternal);
  }

  @override
  Future<void> resetSessionContinuity(String sessionId) async {
    if (currentState == WorkerState.busy) {
      throw StateError('Cannot reset session continuity while a turn is in progress');
    }
    await stop();
    _sessionId = null;
    _turnsSinceStart = 0;
  }

  Future<void> _stopInternal() async {
    final process = currentProcess;
    final wasBusy = currentState == WorkerState.busy;
    bool? initialTerminationAccepted;
    if (wasBusy) {
      try {
        await closeCurrentProcessStdin(process: process);
        if (platformCapabilities.posixSignalsAvailable) {
          initialTerminationAccepted = process?.kill() ?? false;
        }
      } catch (e) {
        _log.fine('Failed to cancel during stop: $e');
      }
      await delayFactory(const Duration(milliseconds: 500));
    }
    currentState = WorkerState.stopped;
    await shutdownCurrentProcess(
      label: 'Claude',
      gracePeriod: _killGracePeriod,
      platformCapabilities: platformCapabilities,
      initialTerminationAccepted: initialTerminationAccepted,
      process: process,
    );

    final containerMcpPath = _containerMcpConfigPath;
    if (containerMcpPath != null) {
      try {
        await containerManager?.deleteFileInContainer(containerMcpPath);
      } catch (e) {
        _log.fine('Failed to delete container MCP config: $e');
      }
      _containerMcpConfigPath = null;
    }
    // Clean up MCP config temp file.
    final mcpPath = _mcpConfigPath;
    if (mcpPath != null) {
      try {
        await File(mcpPath).delete();
      } catch (e) {
        _log.fine('Failed to delete MCP config temp file: $e');
      }
      _mcpConfigPath = null;
    }
  }
  // turn()

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
    final desiredHostWorkingDirectory = _resolveHostWorkingDirectory(directory);
    final desiredWorkingDirectory = _resolveWorkingDirectory(directory);
    final desiredModel = _resolveModel(model);
    final desiredEffort = _resolveEffort(effort);
    final desiredMaxTurns = _resolveMaxTurns(maxTurns);

    // First-use adoption: when the process was spawned with null effort/model
    // and the first turn supplies a non-null value, adopt it without restarting.
    // This prevents unnecessary restarts when governance.crowd_coding.effort
    // is set but agent.effort is not.
    if (_processEffort == null && desiredEffort != null) {
      _processEffort = desiredEffort;
    }
    if (_processModel == null && desiredModel != null) {
      _processModel = desiredModel;
    }

    if (desiredWorkingDirectory != _processWorkingDirectory ||
        desiredHostWorkingDirectory != _hostProcessWorkingDirectory ||
        desiredModel != _processModel ||
        desiredEffort != _processEffort ||
        desiredMaxTurns != _processMaxTurns ||
        currentState == WorkerState.stopped) {
      await _restartForExecution(
        hostWorkingDirectory: desiredHostWorkingDirectory,
        workingDirectory: desiredWorkingDirectory,
        model: desiredModel,
        effort: desiredEffort,
        maxTurns: desiredMaxTurns,
      );
    }

    await recoverFromCrash(_startWithCleanup);

    if (currentState != WorkerState.idle) {
      throw StateError('Harness is not idle (state: $currentState)');
    }
    currentState = WorkerState.busy;
    _turnCompleter = Completer<Map<String, dynamic>>();

    try {
      final messageContent = messages.last['content'];
      final messageText = messageContent is String ? messageContent : messageContent?.toString() ?? '';

      // Inject replay-safe conversation history on cold process (first turn after
      // start/restart) when prior messages exist.
      String effectiveMessage;
      if (_turnsSinceStart == 0 && messages.length > 1) {
        final priorMessages = messages.sublist(0, messages.length - 1);
        final historyBlock = buildReplaySafeHistory(priorMessages, historyConfig);
        if (historyBlock.isNotEmpty) {
          _log.info(
            'Injecting conversation history: '
            '${priorMessages.length} prior messages, '
            '${historyBlock.length} chars',
          );
          effectiveMessage = '$historyBlock\n\n$messageText';
        } else {
          effectiveMessage = messageText;
        }
      } else {
        effectiveMessage = messageText;
      }

      final payload = _adapter.buildTurnRequest(
        message: effectiveMessage,
        systemPrompt: promptStrategy == PromptStrategy.replace && systemPrompt.isNotEmpty ? systemPrompt : null,
        resume: resume,
      );
      _writeLine(payload);

      final result = await _turnCompleter!.future.timeout(
        turnTimeout,
        onTimeout: () async {
          _log.warning('Turn timeout exceeded, stopping Claude...');
          await stop();
          throw TimeoutException('Claude turn exceeded $turnTimeout');
        },
      );
      if (currentState != WorkerState.stopped) {
        crashCount = 0;
        currentState = WorkerState.idle;
      }
      _turnsSinceStart++;
      return result;
    } catch (e) {
      if (currentState != WorkerState.crashed && currentState != WorkerState.stopped) {
        currentState = WorkerState.idle;
      }
      rethrow;
    } finally {
      _turnCompleter = null;
    }
  }
  // Internal: start, auth, handshake

  Future<void> _startInternal() async {
    _turnsSinceStart = 0;
    final cm = containerManager;
    if (cm == null) {
      ProcessResult claudeResult;
      try {
        claudeResult = await commandProbe(claudeExecutable, const ['--version']);
      } on ProcessException {
        throw UnsupportedCapabilityError(
          capability: 'Claude harness executable',
          attemptedContext: '$claudeExecutable --version',
          remediation: 'Install "$claudeExecutable" and ensure it is available on PATH.',
        );
      }
      if (claudeResult.exitCode != 0 || '${claudeResult.stdout}'.trim().isEmpty) {
        throw UnsupportedCapabilityError(
          capability: 'Claude harness executable',
          attemptedContext: '$claudeExecutable --version',
          remediation: 'Install "$claudeExecutable" and ensure it is available on PATH.',
        );
      }

      // Verify authentication.
      await _verifyAuth();
    }

    // Build clean env: inherit parent env, strip nesting-detection vars.
    final env = Map<String, String>.from(_environment);
    for (final key in claudeNestingEnvVars) {
      env.remove(key);
    }

    // Write MCP config temp file if internal MCP server is configured.
    final mcpUrl = harnessConfig.mcpServerUrl;
    final mcpToken = harnessConfig.mcpGatewayToken;
    String? mcpConfigPath;
    String? mcpConfigArgPath;
    if (mcpUrl != null && mcpToken != null) {
      final suffix = DateTime.now().microsecondsSinceEpoch;
      late final String hostConfigPath;
      if (cm != null) {
        final tempDir = Directory(p.join(cwd, '.agent_temp'));
        await tempDir.create(recursive: true);
        hostConfigPath = p.join(tempDir.path, 'dartclaw-mcp-config-$suffix.json');
      } else {
        hostConfigPath = p.join(Directory.systemTemp.path, 'dartclaw-mcp-config-$suffix.json');
      }
      final configFile = File(hostConfigPath);
      final configJson = jsonEncode({
        'mcpServers': {
          'dartclaw': {
            'type': 'http',
            'url': mcpUrl,
            'headers': {'Authorization': 'Bearer $mcpToken'},
          },
        },
      });
      // Create empty, tighten to owner-only, THEN write credentials — the
      // file must never hold the bearer token at default permissions.
      await configFile.create(exclusive: true);
      mcpConfigPath = configFile.path;
      _mcpConfigPath = mcpConfigPath;
      await chmodOwnerOnly(configFile.path);
      await configFile.writeAsString(configJson, flush: true);
      _log.fine('Wrote MCP config to $mcpConfigPath');
    }

    if (cm != null) {
      await cm.start();
      if (mcpConfigPath != null) {
        final filename = p.basename(mcpConfigPath);
        if (cm.hasProjectMount) {
          mcpConfigArgPath = p.posix.join('/project', '.agent_temp', filename);
        } else {
          mcpConfigArgPath = p.posix.join('/tmp', filename);
          _containerMcpConfigPath = mcpConfigArgPath;
          await cm.copyFileToContainer(mcpConfigPath, mcpConfigArgPath);
        }
      }
    } else {
      mcpConfigArgPath = mcpConfigPath;
    }

    // Spawn claude process: containerized or direct.
    final nativePermissionMode = ClaudeSettingsBuilder.buildPermissionMode(providerOptions);
    final nativeSettings = ClaudeSettingsBuilder.buildSettings(
      providerOptions,
      containerManager: containerManager,
      hostWorkingDirectory: _hostProcessWorkingDirectory,
    );
    final args = _buildClaudeArgs(
      model: _processModel ?? harnessConfig.model,
      effort: _processEffort ?? harnessConfig.effort,
      appendSystemPrompt: harnessConfig.appendSystemPrompt,
      mcpConfigPath: mcpConfigArgPath,
      permissionMode: nativePermissionMode,
      settings: nativeSettings,
      settingSourcesProject: cm == null && ClaudeProviderOptions.useProjectSettingSources(providerOptions),
      // Restricted containers keep native permission prompts enabled so tool
      // requests still flow through the provider permission channel.
      skipNativePermissions: nativePermissionMode == null && cm?.profileId != 'restricted',
    );
    final Process process;
    if (cm != null) {
      final containerExecutable = claudeExecutable.contains('/') ? claudeExecutable : containerClaudeExecutable;
      final containerEnv = <String, String>{
        ...claudeHardeningEnvVars,
        if (cm.profileId == 'restricted') 'CLAUDE_CODE_SIMPLE': '1',
        _subagentModelEnvVar: ?_environment[_subagentModelEnvVar],
      };
      process = await cm.exec(
        [containerExecutable, ...args],
        workingDirectory: _processWorkingDirectory,
        env: containerEnv,
      );
    } else {
      process = await processFactory(
        claudeExecutable,
        args,
        workingDirectory: _processWorkingDirectory,
        environment: env,
        includeParentEnvironment: false,
      );
    }

    final generation = attachProcess(
      process,
      dropEmptyStdoutLines: true,
      onStdoutError: (error) => _log.warning('stdout error: $error'),
    );
    _log.info('Claude process spawned (generation: $generation, pid: ${process.pid})');

    // Initialize handshake.
    await _sendInitialize();

    currentState = WorkerState.idle;
  }

  String _resolveWorkingDirectory(String? directory) {
    if (directory == null || directory.trim().isEmpty) {
      final cm = containerManager;
      return cm?.containerPathForHostPath(cwd) ?? cwd;
    }

    final cm = containerManager;
    if (cm == null) return directory;
    final translated = cm.containerPathForHostPath(directory);
    if (translated == null) {
      throw StateError('Requested working directory is not mounted in the container: $directory');
    }
    return translated;
  }

  String _resolveHostWorkingDirectory(String? directory) {
    if (directory == null || directory.trim().isEmpty) {
      return cwd;
    }
    return directory;
  }

  String? _resolveModel(String? override) {
    final trimmed = override?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    return harnessConfig.model;
  }

  String? _resolveEffort(String? override) {
    final trimmed = override?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    return harnessConfig.effort;
  }

  int? _resolveMaxTurns(int? override) => override ?? harnessConfig.maxTurns;

  bool get _nativePermissionsSkipped {
    final permissionMode = ClaudeSettingsBuilder.buildPermissionMode(providerOptions);
    if (permissionMode != null) {
      return permissionMode == 'bypassPermissions' || permissionMode == 'dontAsk';
    }
    return containerManager?.profileId != 'restricted';
  }

  Future<void> _restartForExecution({
    required String hostWorkingDirectory,
    required String workingDirectory,
    required String? model,
    required String? effort,
    required int? maxTurns,
  }) async {
    await withLock(() async {
      if (currentState == WorkerState.busy) {
        throw StateError('Cannot change working directory, model, or effort while harness is busy');
      }
      if (_processWorkingDirectory == workingDirectory &&
          _hostProcessWorkingDirectory == hostWorkingDirectory &&
          _processModel == model &&
          _processEffort == effort &&
          _processMaxTurns == maxTurns &&
          currentState != WorkerState.stopped) {
        return;
      }
      final changes = <String>[];
      if (_processWorkingDirectory != workingDirectory) {
        changes.add('workingDirectory: $_processWorkingDirectory -> $workingDirectory');
      }
      if (_hostProcessWorkingDirectory != hostWorkingDirectory) {
        changes.add('hostWorkingDirectory: $_hostProcessWorkingDirectory -> $hostWorkingDirectory');
      }
      if (_processModel != model) {
        changes.add('model: $_processModel -> $model');
      }
      if (_processEffort != effort) {
        changes.add('effort: $_processEffort -> $effort');
      }
      if (_processMaxTurns != maxTurns) {
        changes.add('maxTurns: $_processMaxTurns -> $maxTurns');
      }
      if (changes.isNotEmpty) {
        _log.warning('Restarting harness due to parameter change: ${changes.join(', ')}');
      }
      await _stopInternal();
      if (currentProcess != null) {
        throw StateError('Cannot restart harness because the previous process did not exit');
      }
      _processWorkingDirectory = workingDirectory;
      _hostProcessWorkingDirectory = hostWorkingDirectory;
      _processModel = model;
      _processEffort = effort;
      _processMaxTurns = maxTurns;
      await _startWithCleanup();
    });
  }

  /// Verifies that ANTHROPIC_API_KEY or Claude CLI OAuth session is available.
  Future<void> _verifyAuth() async {
    final hasApiKey = _environment['ANTHROPIC_API_KEY']?.trim().isNotEmpty ?? false;
    if (hasApiKey) return;

    final result = await commandProbe(claudeExecutable, ['auth', 'status']);
    if (result.exitCode == 0) {
      try {
        final status = jsonDecode(result.stdout as String) as Map<String, dynamic>;
        if (status['loggedIn'] == true) {
          _log.info('Using Claude CLI OAuth auth (${status['authMethod']})');
          return;
        }
      } on FormatException {
        // JSON parse failed — fall through to error.
      }
    }

    throw StateError(
      'No authentication configured. Either:\n'
      '  1. Export ANTHROPIC_API_KEY:  export ANTHROPIC_API_KEY=sk-ant-...\n'
      '  2. Use Claude CLI OAuth:     claude auth login\n'
      '  3. Use a setup token:        claude setup-token',
    );
  }

  /// Sends the initialize control_request and waits for the response.
  Future<void> _sendInitialize() async {
    _initCompleter = Completer<Map<String, dynamic>>();

    final requestId = 'req_init_${DateTime.now().millisecondsSinceEpoch}';
    _log.info('Sending initialize (id: $requestId)...');

    final sdkMcpServers = _buildMemorySdkMcpServers();
    _writeLine(
      _adapter.buildInitializeRequest(
        requestId: requestId,
        hooks: {
          'PreToolUse': [
            {
              'matcher': null,
              'hookCallbackIds': ['hook_pre_tool'],
              'timeout': 30,
              // Limit callbacks to tools that guards evaluate, reducing unnecessary
              // JSONL round-trips for tools like Glob, Grep, WebSearch, etc.
              // (Claude Code v2.1.91+ if: filtering)
              'if': {
                'toolName': {
                  r'$in': ['Bash', 'Write', 'Edit', 'Read', 'MultiEdit'],
                },
              },
            },
          ],
          'PostToolUse': [
            {
              'matcher': null,
              'hookCallbackIds': ['hook_post_tool'],
              'timeout': 10,
              // PostToolUse intentionally unfiltered — DartClaw audits ALL tool
              // completions for observability.
            },
          ],
          'PermissionDenied': [
            {
              'matcher': null,
              'hookCallbackIds': ['hook_permission_denied'],
              'timeout': 10,
            },
          ],
          'PreCompact': [
            {
              'matcher': null,
              'hookCallbackIds': ['hook_pre_compact'],
              'timeout': 10,
            },
          ],
        },
        initializeFields: {
          ...harnessConfig.toInitializeFields(),
          if (_processMaxTurns != null) 'maxTurns': _processMaxTurns,
        },
        sdkMcpServers: harnessConfig.mcpServerUrl == null && sdkMcpServers.isNotEmpty ? sdkMcpServers : null,
      ),
    );

    try {
      await _initCompleter!.future.timeout(_initializeTimeout);
      _log.info('Initialize handshake complete');
    } on TimeoutException {
      _log.severe('Initialize handshake timed out');
      throw StateError('Initialize handshake timed out after ${_initializeTimeout.inSeconds}s');
    }
  }

  /// Builds `sdkMcpServers` map for memory tools in chat mode (no MCP server).
  Map<String, dynamic> _buildMemorySdkMcpServers() {
    final save = onMemorySave;
    final search = onMemorySearch;
    final read = onMemoryRead;
    if (save == null || search == null || read == null) return {};

    return {
      'sdkMcpServers': {
        'dartclaw-memory': {
          'type': 'sdk_mcp_server',
          'tools': [
            {
              'name': 'memory_save',
              'description': 'Save a fact, preference, or piece of knowledge to persistent memory.',
              'input_schema': {
                'type': 'object',
                'properties': {
                  'text': {'type': 'string', 'description': 'The text to save'},
                  'category': {'type': 'string', 'description': 'Category (e.g. preferences, project)'},
                },
                'required': ['text'],
              },
            },
            {
              'name': 'memory_search',
              'description': 'Search saved memories using natural language.',
              'input_schema': {
                'type': 'object',
                'properties': {
                  'query': {'type': 'string', 'description': 'Search query'},
                  'limit': {'type': 'number', 'description': 'Max results (default 5)'},
                },
                'required': ['query'],
              },
            },
            {
              'name': 'memory_read',
              'description': 'Read the full contents of MEMORY.md.',
              'input_schema': {'type': 'object', 'properties': <String, dynamic>{}},
            },
          ],
        },
      },
    };
  }
  // JSONL message routing

  @override
  void handleProcessStdoutLine(String line) {
    // First check for control_response (handled before protocol parsing, needed
    // for the initialize handshake).
    if (_initCompleter != null && !_initCompleter!.isCompleted) {
      final json = decodeJsonObject(line);
      if (json != null && stringValue(json['type']) == 'control_response') {
        _initCompleter!.complete(json);
        return;
      }
      if (json == null) {
        // Not a control_response JSON — fall through to normal parsing.
        _log.fine('Non-JSON or non-control_response line during init');
      }
    }

    final msg = _adapter.parseLine(line);
    if (msg == null) return;

    switch (msg) {
      case proto.TextDelta(:final text):
        emitEvent(DeltaEvent(text));

      case proto.ToolUse(:final name, :final id, :final input):
        emitEvent(ToolUseEvent(toolName: name, toolId: id, input: input));

      case proto.ToolResult(:final toolId, :final output, :final isError):
        emitEvent(ToolResultEvent(toolId: toolId, output: output, isError: isError));

      case proto.ProgressMessage():
      case proto.SessionMetadataUpdate():
      case proto.ProtocolDiagnostic():
        break;

      case proto.ControlRequest(:final requestId, :final subtype, :final data):
        _handleControlRequest(requestId, subtype, data);

      case proto.TurnComplete(
        :final stopReason,
        :final costUsd,
        :final durationMs,
        :final inputTokens,
        :final outputTokens,
        :final cacheReadTokens,
        :final cacheWriteTokens,
      ):
        if (_turnCompleter != null && !_turnCompleter!.isCompleted) {
          final isError = stopReason == 'error';
          final result = <String, dynamic>{
            'stop_reason': stopReason,
            'is_error': isError,
            'total_cost_usd': costUsd,
            'duration_ms': durationMs,
            'input_tokens': inputTokens,
            'output_tokens': outputTokens,
            'cache_read_tokens': cacheReadTokens ?? 0,
            'cache_write_tokens': cacheWriteTokens ?? 0,
          };
          if (isError) {
            final decoded = decodeJsonObject(line);
            final detail = stringValue(decoded?['result']);
            if (detail != null && detail.isNotEmpty) {
              result['error'] = detail;
            }
          }
          _log.info('Terminal result: is_error=$isError');
          _turnCompleter!.complete(result);
        }

      case proto.SystemInit(:final sessionId, :final toolCount, :final contextWindow):
        _sessionId = sessionId;
        _log.info('Session init: id=$sessionId, tools=$toolCount, contextWindow=$contextWindow');
        if (contextWindow != null) {
          emitEvent(SystemInitEvent(contextWindow: contextWindow));
        }

      case proto.CompactBoundary(:final trigger, :final preTokens):
        _log.info('Compact boundary: trigger=$trigger, preTokens=$preTokens');
        onCompactionCompleted?.call(trigger, preTokens);

      case proto.CompactionStarted():
      case proto.CompactionCompleted():
        // Codex-only compaction protocol messages — not produced by Claude Code harness
        break;
    }
  }

  @override
  void handleProcessStderrLine(String line) {
    _log.warning('[claude stderr] $line');
  }

  @override
  void handleUnexpectedProcessExit(int exitCode) {
    if (currentState == WorkerState.stopped || isStopping) {
      return;
    }
    _log.warning('Claude process exited unexpectedly: exit code $exitCode');
    if (currentState != WorkerState.crashed) {
      currentState = WorkerState.crashed;
      crashCount++;
    }
    final turnCompleter = _turnCompleter;
    if (turnCompleter != null && !turnCompleter.isCompleted) {
      turnCompleter.completeError(StateError('Claude process exited with code $exitCode'));
    }
  }
  // Control request handling

  void _handleControlRequest(String requestId, String subtype, Map<String, dynamic> data) {
    switch (subtype) {
      case 'can_use_tool':
        final skipNativePermissions = _nativePermissionsSkipped;
        if (skipNativePermissions) {
          // Defensive dead code: --dangerously-skip-permissions suppresses
          // can_use_tool requests, and guard evaluation runs via PreToolUse hooks.
          _log.warning('Unexpected can_use_tool request while permissions are skipped');
          final toolUseId = data['tool_use_id'] as String?;
          _writeLine(_adapter.buildApprovalResponse(requestId, allow: false, toolUseId: toolUseId));
          return;
        }

        final allow = toolPolicy == ToolApprovalPolicy.allowAll;
        final toolUseId = data['tool_use_id'] as String?;
        _writeLine(_adapter.buildApprovalResponse(requestId, allow: allow, toolUseId: toolUseId));
        return;

      case 'hook_callback':
        _handleHookCallback(requestId, data);
        return;

      default:
        _writeLine(_adapter.buildGenericResponse(requestId));
        return;
    }
  }

  /// Routes hook_callback by event type: PreToolUse (guard + credential strip),
  /// PostToolUse (audit logging), or PreCompact (compaction notification).
  void _handleHookCallback(String requestId, Map<String, dynamic> data) {
    final hookInput = data['input'] as Map<String, dynamic>?;
    final hookEventName = hookInput?['hook_event_name'] as String?;

    if (hookEventName == 'PreCompact') {
      _handlePreCompactCallback(requestId, hookInput);
      return;
    }

    if (hookEventName == 'PostToolUse') {
      _handlePostToolUseCallback(requestId, hookInput);
      return;
    }

    if (hookEventName == 'PermissionDenied') {
      _handlePermissionDeniedCallback(requestId, hookInput);
      return;
    }

    // PreToolUse (default path)
    unawaited(_handlePreToolUseCallback(requestId, hookInput));
  }

  /// Handles the `PreCompact` hook callback: invokes [onCompactionStarting]
  /// and responds with `allow: true` (compaction is non-blocking).
  void _handlePreCompactCallback(String requestId, Map<String, dynamic>? hookInput) {
    final sessionId = hookInput?['session_id'] as String? ?? _sessionId ?? '';
    final trigger = hookInput?['trigger'] as String? ?? 'auto';
    onCompactionStarting?.call(sessionId, trigger);
    _writeLine(_adapter.buildHookResponse(requestId, allow: true));
  }

  Future<void> _handlePreToolUseCallback(String requestId, Map<String, dynamic>? hookInput) async {
    final rawToolName = hookInput?['tool_name'] as String? ?? '';
    emitEvent(ToolApprovalWaitEvent(requestId: requestId, toolName: rawToolName));
    final toolInput = hookInput?['tool_input'] as Map<String, dynamic>? ?? {};
    final canonicalTool = _adapter.mapToolName(rawToolName);
    final guardToolName = canonicalTool?.stableName ?? 'claude:$rawToolName';

    if (canonicalTool == null) {
      _log.warning('Falling back to unmapped Claude tool name: $rawToolName -> $guardToolName');
    }

    // Guard evaluation
    final chain = guardChain;
    if (chain != null) {
      final verdict = await chain.evaluateBeforeToolCall(
        guardToolName,
        toolInput,
        sessionId: _sessionId,
        rawProviderToolName: rawToolName,
      );
      if (verdict.isBlock) {
        if (_tryWriteHookResponse(requestId, _adapter.buildHookResponse(requestId, allow: false))) {
          emitEvent(ToolApprovalResolvedEvent(requestId: requestId));
        }
        return;
      }
    }

    // Credential stripping for Bash tool
    final envMap = toolInput['env'] as Map<String, dynamic>?;
    if (envMap != null && envMap.containsKey('ANTHROPIC_API_KEY')) {
      final sanitizedEnv = Map<String, dynamic>.from(envMap)..remove('ANTHROPIC_API_KEY');
      final updatedInput = Map<String, dynamic>.from(toolInput)..['env'] = sanitizedEnv;
      _log.info('Stripped ANTHROPIC_API_KEY from bash env');
      if (_tryWriteHookResponse(requestId, _adapter.buildCredentialStripResponse(requestId, updatedInput))) {
        emitEvent(ToolApprovalResolvedEvent(requestId: requestId));
      }
      return;
    }

    if (_tryWriteHookResponse(requestId, _adapter.buildHookResponse(requestId, allow: true))) {
      emitEvent(ToolApprovalResolvedEvent(requestId: requestId));
    }
  }

  bool _tryWriteHookResponse(String requestId, Map<String, dynamic> response) {
    try {
      _writeLine(response);
      return true;
    } catch (error, stackTrace) {
      _log.severe('Failed to write Claude hook response for $requestId: $error', error, stackTrace);
      return false;
    }
  }

  void _handlePostToolUseCallback(String requestId, Map<String, dynamic>? hookInput) {
    final toolName = hookInput?['tool_name'] as String? ?? 'unknown';
    final toolResponse = _parseToolResponse(hookInput?['tool_response']);

    final success = toolResponse['error'] == null;
    auditLogger?.logPostToolUse(toolName: toolName, success: success, response: toolResponse);

    _writeLine(_adapter.buildHookResponse(requestId, allow: true));
  }

  void _handlePermissionDeniedCallback(String requestId, Map<String, dynamic>? hookInput) {
    final toolName = hookInput?['tool_name'] as String? ?? '';
    final reason = hookInput?['reason'] as String?;

    onPermissionDenied?.call(toolName, reason);

    // Acknowledge receipt. The denial already occurred at Claude Code's layer;
    // DartClaw cannot override it — this is informational only.
    _writeLine(_adapter.buildHookResponse(requestId, allow: true));
  }

  static Map<String, dynamic> _parseToolResponse(Object? raw) {
    try {
      if (raw is Map) return mapValue(raw) ?? <String, dynamic>{};
      if (raw is String) return decodeJsonObject(raw) ?? <String, dynamic>{};
    } catch (e) {
      _log.fine('Tool response parse failed: $e');
    }
    return <String, dynamic>{};
  }
  // Helpers

  void _writeLine(Map<String, dynamic> json) {
    writeJsonLine(json);
  }
}
