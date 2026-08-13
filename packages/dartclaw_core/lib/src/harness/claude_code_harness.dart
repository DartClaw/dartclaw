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
import '../memory/memory_apply_schema.dart';
import '../storage/atomic_write.dart';
import '../worker/worker_state.dart';
import 'agent_harness.dart';
import 'base_harness.dart';
import 'base_protocol_adapter.dart';
import 'claude_settings_builder.dart';
import 'claude_protocol_adapter.dart';
import 'claude_protocol.dart';
import 'canonical_tool.dart';
import 'conversation_history.dart';
import 'harness_config.dart';
import 'harness_turn_context.dart';
import 'protocol_message.dart' as proto;
import 'process_lifecycle.dart';
import 'process_types.dart';
import 'tool_policy.dart';

part 'claude_code_harness_mcp.dart';

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

/// Concrete [AgentHarness] that spawns the `claude` binary directly and speaks
/// its JSONL control protocol — no Deno/TypeScript layer required.
class ClaudeCodeHarness extends BaseHarness with HarnessTurnContextStorage {
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

  /// Memory handlers exposed through the SDK fallback when no HTTP MCP server is configured.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemoryApply;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemoryObserve;
  final ContextualMemoryToolHandler? onContextualMemoryApply;
  final ContextualMemoryToolHandler? onContextualMemoryObserve;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemorySearch;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemoryRead;

  /// Called with the native tool name and reason when Claude denies tool use.
  final void Function(String toolName, String? reason)? onPermissionDenied;

  /// Called with the host session ID and trigger before compaction.
  ///
  /// The hook acknowledgement waits for this callback to settle. A callback
  /// failure is logged but does not prevent Claude from compacting.
  FutureOr<void> Function(String sessionId, String trigger)? onCompactionStarting;

  /// Called with the trigger and pre-compaction token count at the boundary.
  void Function(String trigger, int? preTokens)? onCompactionCompleted;

  static final _log = Logger('ClaudeCodeHarness');

  String? _mcpConfigPath;
  int _turnsSinceStart = 0;
  String? _conversationSessionId;
  String? _sessionId;
  String? _activeTurnSessionId;
  String? _activeAgentId;
  Completer<Map<String, dynamic>>? _turnCompleter;
  late String _processWorkingDirectory;
  late String _hostProcessWorkingDirectory;
  String? _processModel;
  String? _processEffort;
  String? _processAppendSystemPrompt;
  int? _processMaxTurns;

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
    this.onMemoryApply,
    this.onMemoryObserve,
    this.onContextualMemoryApply,
    this.onContextualMemoryObserve,
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
    // The spawn working directory must be container-side when containerized:
    // `start()` before any turn would otherwise exec with the untranslated
    // host cwd, which no container has, and die with exit 127.
    _processWorkingDirectory = _resolveWorkingDirectory(null);
    _hostProcessWorkingDirectory = cwd;
    _processModel = harnessConfig.model;
    _processEffort = harnessConfig.effort;
    _processAppendSystemPrompt = harnessConfig.appendSystemPrompt;
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

    // The container sees the generated config through a bind mount, so the
    // host-side delete removes it from both sides at once.
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

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    String? agentId,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
  }) async {
    final desiredHostWorkingDirectory = _resolveHostWorkingDirectory(directory);
    final desiredWorkingDirectory = _resolveWorkingDirectory(directory);
    final desiredModel = _resolveProviderOption(model, harnessConfig.model);
    final desiredEffort = _resolveProviderOption(effort, harnessConfig.effort);
    final desiredAppendSystemPrompt = _resolveAppendSystemPrompt(systemPrompt);
    final desiredMaxTurns = _resolveMaxTurns(maxTurns);

    // First-use adoption: when the process was spawned with null effort/model
    // and the first ordinary turn supplies a non-null value, adopt it without restarting.
    // This prevents unnecessary restarts when governance.crowd_coding.effort
    // is set but agent.effort is not.
    if (agentId == null && _processEffort == null && desiredEffort != null) {
      _processEffort = desiredEffort;
    }
    if (agentId == null && _processModel == null && desiredModel != null) {
      _processModel = desiredModel;
    }

    final sessionChanged = _conversationSessionId != null && _conversationSessionId != sessionId;
    if (sessionChanged ||
        desiredWorkingDirectory != _processWorkingDirectory ||
        desiredHostWorkingDirectory != _hostProcessWorkingDirectory ||
        desiredModel != _processModel ||
        desiredEffort != _processEffort ||
        desiredAppendSystemPrompt != _processAppendSystemPrompt ||
        desiredMaxTurns != _processMaxTurns ||
        currentState == WorkerState.stopped) {
      await _restartForExecution(
        hostWorkingDirectory: desiredHostWorkingDirectory,
        workingDirectory: desiredWorkingDirectory,
        model: desiredModel,
        effort: desiredEffort,
        appendSystemPrompt: desiredAppendSystemPrompt,
        maxTurns: desiredMaxTurns,
        resetConversation: sessionChanged,
      );
    }

    await recoverFromCrash(_startWithCleanup);
    _conversationSessionId = sessionId;

    if (currentState != WorkerState.idle) {
      throw StateError('Harness is not idle (state: $currentState)');
    }
    currentState = WorkerState.busy;
    _activeTurnSessionId = sessionId;
    _activeAgentId = agentId;
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
      writeJsonLine(payload);

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
      _activeTurnSessionId = null;
      _activeAgentId = null;
    }
  }

  Future<void> _startInternal() async {
    _turnsSinceStart = 0;
    _conversationSessionId = null;
    final cm = containerManager;
    if (cm == null) {
      ProcessResult? claudeResult;
      try {
        claudeResult = await commandProbe(claudeExecutable, const ['--version']);
      } on ProcessException {
        // Reported through the same capability error as an invalid probe result.
      }
      if (claudeResult == null || claudeResult.exitCode != 0 || '${claudeResult.stdout}'.trim().isEmpty) {
        throw UnsupportedCapabilityError(
          capability: 'Claude harness executable',
          attemptedContext: '$claudeExecutable --version',
          remediation: 'Install "$claudeExecutable" and ensure it is available on PATH.',
        );
      }

      await _verifyAuth();
    } else {
      await cm.start();
      if (!await containerExecutableRuns(cm, _containerExecutable)) {
        throw UnsupportedCapabilityError(
          capability: 'Claude harness executable',
          attemptedContext: '$_containerExecutable --version (container ${cm.profileId})',
          remediation: 'Rebuild the DartClaw agent image so it ships a runnable claude binary.',
        );
      }
    }

    final env = Map<String, String>.from(_environment);
    for (final key in claudeNestingEnvVars) {
      env.remove(key);
    }

    // Containerized Claude reaches host MCP only through this authority's
    // scoped bridge, and identifies itself by the pipe rather than a bearer –
    // the shared operator token stays on the host. A null bridge URL means the
    // authority was granted no tools, so no MCP server is configured at all.
    final mcpUrl = cm == null ? harnessConfig.mcpServerUrl : cm.mcpBridgeUrl;
    final mcpToken = cm == null ? harnessConfig.mcpGatewayToken : null;
    String? mcpConfigPath;
    String? mcpConfigArgPath;
    if (mcpUrl != null) {
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final hostConfigPath = p.join(
        cm == null ? Directory.systemTemp.path : cm.generatedStateDir,
        'dartclaw-mcp-config-$suffix.json',
      );
      final configFile = File(hostConfigPath);
      final configJson = jsonEncode({
        'mcpServers': {
          'dartclaw': {
            'type': 'http',
            'url': mcpUrl,
            if (mcpToken != null) 'headers': {'Authorization': 'Bearer $mcpToken'},
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

      if (cm != null) {
        mcpConfigArgPath = cm.containerPathForHostPath(mcpConfigPath);
        if (mcpConfigArgPath == null) {
          throw StateError('Generated MCP config is not mounted in the container: $mcpConfigPath');
        }
      } else {
        mcpConfigArgPath = mcpConfigPath;
      }
    }

    final nativePermissionMode = ClaudeSettingsBuilder.buildPermissionMode(providerOptions);
    final nativeSettings = ClaudeSettingsBuilder.buildSettings(
      providerOptions,
      containerManager: containerManager,
      hostWorkingDirectory: _hostProcessWorkingDirectory,
    );
    final args = _buildClaudeArgs(
      model: _processModel ?? harnessConfig.model,
      effort: _processEffort ?? harnessConfig.effort,
      appendSystemPrompt: _processAppendSystemPrompt,
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
      // The container process gets no host environment: the provider
      // credential, the host login path, and the shared MCP bearer all stay
      // outside the boundary. `ANTHROPIC_BASE_URL` is set on the container
      // itself and points only at this authority's provider bridge.
      final containerEnv = <String, String>{
        ...claudeContainerHardeningEnvVars,
        // Satisfies the CLI's local auth gate only; the host adapter replaces
        // it with the real credential. Without any key the client refuses
        // before it ever reaches the provider bridge.
        'ANTHROPIC_API_KEY': containerClaudePlaceholderApiKey,
        // The image rootfs is read-only, so the default `$HOME/.claude` config
        // location is unwritable; point the CLI at the writable generated-state
        // mount instead, which is destroyed with the container.
        'CLAUDE_CONFIG_DIR': containerGeneratedStatePath,
        if (cm.profileId == 'restricted') 'CLAUDE_CODE_SIMPLE': '1',
      };
      process = await cm.exec(
        [_containerExecutable, ...args],
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

    await _sendInitialize();

    currentState = WorkerState.idle;
  }

  String _resolveWorkingDirectory(String? directory) {
    if (directory == null || directory.trim().isEmpty) {
      final cm = containerManager;
      if (cm == null) return cwd;
      // A restricted container deliberately mounts no workspace, so an unmapped
      // default cwd is the expected state. Falling back to the profile's own
      // working directory keeps a host path from crossing into the container.
      return cm.containerPathForHostPath(cwd) ?? cm.workingDir;
    }

    final cm = containerManager;
    if (cm == null) return directory;
    final translated = cm.containerPathForHostPath(directory);
    if (translated == null) {
      throw StateError('Requested working directory is not mounted in the container: $directory');
    }
    return translated;
  }

  String _resolveHostWorkingDirectory(String? directory) =>
      directory == null || directory.trim().isEmpty ? cwd : directory;

  /// The binary the container image ships, unless an absolute path was pinned.
  String get _containerExecutable => claudeExecutable.contains('/') ? claudeExecutable : containerClaudeExecutable;

  /// Provider-native web tools no containerized execution may use.
  ///
  /// They execute at the provider rather than in the container, so
  /// `network:none` cannot contain them, and every profile's provider pipe is
  /// mediated by a host adapter that refuses any request declaring them. This
  /// suppression keeps the client from asking at all; the bridged MCP grant is
  /// the only web path a container has.
  List<String> get _deniedNativeWebTools => containerManager == null ? const [] : const ['WebSearch', 'WebFetch'];

  String? _resolveProviderOption(String? override, String? fallback) {
    final trimmed = override?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    return fallback;
  }

  String? _resolveAppendSystemPrompt(String override) {
    if (override.trim().isNotEmpty) return override;
    return harnessConfig.appendSystemPrompt;
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
    required String? appendSystemPrompt,
    required int? maxTurns,
    bool resetConversation = false,
  }) async {
    await withLock(() async {
      if (currentState == WorkerState.busy) {
        throw StateError('Cannot change execution parameters while harness is busy');
      }
      if (_processWorkingDirectory == workingDirectory &&
          _hostProcessWorkingDirectory == hostWorkingDirectory &&
          _processModel == model &&
          _processEffort == effort &&
          _processAppendSystemPrompt == appendSystemPrompt &&
          _processMaxTurns == maxTurns &&
          !resetConversation &&
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
      if (_processAppendSystemPrompt != appendSystemPrompt) {
        changes.add('appendSystemPrompt changed');
      }
      if (_processMaxTurns != maxTurns) {
        changes.add('maxTurns: $_processMaxTurns -> $maxTurns');
      }
      if (resetConversation) {
        changes.add('logical session changed');
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
      _processAppendSystemPrompt = appendSystemPrompt;
      _processMaxTurns = maxTurns;
      await _startWithCleanup();
    });
  }

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
        // Malformed status is treated as unauthenticated.
      }
    }

    throw StateError(
      'No authentication configured. Either:\n'
      '  1. Export ANTHROPIC_API_KEY:  export ANTHROPIC_API_KEY=sk-ant-...\n'
      '  2. Use Claude CLI OAuth:     claude auth login\n'
      '  3. Use a setup token:        claude setup-token',
    );
  }

  Future<void> _sendInitialize() async {
    _initCompleter = Completer<Map<String, dynamic>>();

    final requestId = 'req_init_${DateTime.now().millisecondsSinceEpoch}';
    _log.info('Sending initialize (id: $requestId)...');

    final sdkMcpServers = _buildMemorySdkMcpServers();
    writeJsonLine(
      _adapter.buildInitializeRequest(
        requestId: requestId,
        hooks: {
          'PreToolUse': [
            {
              'hookCallbackIds': ['hook_pre_tool'],
              'timeout': 30,
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
          if (_deniedNativeWebTools.isNotEmpty)
            'disallowedTools': [...harnessConfig.disallowedTools, ..._deniedNativeWebTools],
          if (_processMaxTurns != null) 'maxTurns': _processMaxTurns,
        },
        // Gated on the boundary, not the URL: a container whose authority was
        // granted no tools has a null bridge URL, and must end up with *less*
        // exposure, not the SDK memory tools deny-by-default excluded.
        sdkMcpServers: containerManager == null && harnessConfig.mcpServerUrl == null && sdkMcpServers.isNotEmpty
            ? sdkMcpServers
            : null,
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

  Map<String, dynamic> _buildMemorySdkMcpServers() {
    final apply = onMemoryApply;
    final observe = onMemoryObserve;
    final search = onMemorySearch;
    final read = onMemoryRead;
    if (apply == null || observe == null || search == null || read == null) return {};

    return {
      'sdkMcpServers': {
        dartclawMcpServerName: {
          'type': 'sdk_mcp_server',
          'tools': [
            {
              'name': 'memory_observe',
              'description': 'Record a non-authoritative observation or runtime learning.',
              'input_schema': {
                'type': 'object',
                'properties': {
                  'text': {'type': 'string', 'maxLength': 65536, 'description': 'The text to record'},
                  'role': {
                    'type': 'string',
                    'enum': ['observation', 'learning'],
                    'description': 'Canonical capture role',
                  },
                },
                'required': ['text', 'role'],
                'additionalProperties': false,
              },
            },
            {
              'name': 'memory_apply',
              'description': 'Atomically add, revise, merge, or remove curated personal memory.',
              'input_schema': {
                'type': 'object',
                'properties': {
                  'expectedRevision': {'type': 'integer', 'minimum': 1},
                  'operations': {'type': 'array', 'minItems': 1, 'items': memoryApplyOperationSchema},
                },
                'required': ['expectedRevision', 'operations'],
                'additionalProperties': false,
              },
            },
            {
              'name': 'memory_search',
              'description': 'Search saved memories using natural language.',
              'input_schema': {
                'type': 'object',
                'properties': {
                  'query': {'type': 'string', 'description': 'Search query'},
                  'limit': {
                    'type': 'integer',
                    'description': 'Number of results (1-50, default 5)',
                    'default': 5,
                    'minimum': 1,
                    'maximum': 50,
                  },
                },
                'required': ['query'],
                'additionalProperties': false,
              },
            },
            {
              'name': 'memory_read',
              'description': 'Read canonical memory or a native knowledge source by stable selector.',
              'input_schema': {
                'type': 'object',
                'properties': {
                  'locator': {'type': 'string', 'description': 'Stable locator returned by memory_search'},
                  'role': {
                    'type': 'string',
                    'enum': ['topic', 'archive'],
                    'description': 'Topic-bearing canonical role',
                  },
                  'topic': {'type': 'string', 'description': 'Canonical topic slug'},
                  'limit': {
                    'type': 'integer',
                    'description': 'Number of records (1-50, default 5)',
                    'default': 5,
                    'minimum': 1,
                    'maximum': 50,
                  },
                },
                'oneOf': [
                  {
                    'required': ['locator'],
                    'not': {
                      'anyOf': [
                        {
                          'required': ['role'],
                        },
                        {
                          'required': ['topic'],
                        },
                      ],
                    },
                  },
                  {
                    'required': ['role', 'topic'],
                    'not': {
                      'required': ['locator'],
                    },
                  },
                ],
                'additionalProperties': false,
              },
            },
          ],
        },
      },
    };
  }

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
        unawaited(_handleControlRequest(requestId, subtype, data));

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

  Future<void> _handleControlRequest(String requestId, String subtype, Map<String, dynamic> data) async {
    switch (subtype) {
      case 'can_use_tool':
        final skipNativePermissions = _nativePermissionsSkipped;
        if (skipNativePermissions) {
          // Defensive dead code: --dangerously-skip-permissions suppresses
          // can_use_tool requests, and guard evaluation runs via PreToolUse hooks.
          _log.warning('Unexpected can_use_tool request while permissions are skipped');
          final toolUseId = data['tool_use_id'] as String?;
          writeJsonLine(_adapter.buildApprovalResponse(requestId, allow: false, toolUseId: toolUseId));
          return;
        }

        final allow = toolPolicy == ToolApprovalPolicy.allowAll;
        final toolUseId = data['tool_use_id'] as String?;
        writeJsonLine(_adapter.buildApprovalResponse(requestId, allow: allow, toolUseId: toolUseId));
        return;

      case 'hook_callback':
        await _handleHookCallback(requestId, data);
        return;

      case 'mcp_message':
        await _handleMcpMessage(requestId, data);
        return;

      default:
        writeJsonLine(_adapter.buildGenericResponse(requestId));
        return;
    }
  }

  void _writeSdkMcpLine(Map<String, dynamic> message) => writeJsonLine(message);

  Future<void> _handleHookCallback(String requestId, Map<String, dynamic> data) async {
    final hookInput = data['input'];
    if (hookInput is! Map<String, dynamic>) {
      _denyHook(requestId);
      return;
    }
    final hookEventName = hookInput['hook_event_name'];

    if (hookEventName == 'PreCompact') {
      if ((hookInput['session_id'] != null && hookInput['session_id'] is! String) ||
          (hookInput['trigger'] != null && hookInput['trigger'] is! String)) {
        _denyHook(requestId);
        return;
      }
      await _handlePreCompactCallback(requestId, hookInput);
      return;
    }

    if (hookEventName != 'PreToolUse' && hookEventName != 'PostToolUse' && hookEventName != 'PermissionDenied') {
      _denyHook(requestId);
      return;
    }

    final rawToolName = hookInput['tool_name'];
    if (rawToolName is! String || rawToolName.trim().isEmpty) {
      _denyHook(requestId);
      return;
    }

    if (hookEventName == 'PermissionDenied') {
      if (hookInput['reason'] != null && hookInput['reason'] is! String) {
        _denyHook(requestId);
        return;
      }
      _handlePermissionDeniedCallback(requestId, hookInput);
      return;
    }

    if (hookEventName == 'PostToolUse') {
      _handlePostToolUseCallback(requestId, hookInput);
      return;
    }

    final toolInput = hookInput['tool_input'];
    if (toolInput is! Map<String, dynamic> || (toolInput['env'] != null && toolInput['env'] is! Map<String, dynamic>)) {
      _denyHook(requestId);
      return;
    }

    unawaited(_handlePreToolUseCallback(requestId, hookInput));
  }

  void _denyHook(String requestId) {
    _tryWriteHookResponse(requestId, _adapter.buildHookResponse(requestId, allow: false));
  }

  Future<void> _handlePreCompactCallback(String requestId, Map<String, dynamic>? hookInput) async {
    final sessionId = _activeTurnSessionId ?? hookInput?['session_id'] as String? ?? _sessionId ?? '';
    final trigger = hookInput?['trigger'] as String? ?? 'auto';
    try {
      await onCompactionStarting?.call(sessionId, trigger);
    } catch (error, stackTrace) {
      _log.warning('Claude PreCompact observer failed for $requestId: $error', error, stackTrace);
    }
    _tryWriteHookResponse(requestId, _adapter.buildHookResponse(requestId, allow: true));
  }

  Future<void> _handlePreToolUseCallback(String requestId, Map<String, dynamic> hookInput) async {
    final rawToolName = hookInput['tool_name'] as String;
    emitEvent(ToolApprovalWaitEvent(requestId: requestId, toolName: rawToolName));
    final toolInput = hookInput['tool_input'] as Map<String, dynamic>;
    final canonicalTool = _adapter.mapToolName(rawToolName);
    final guardToolName = canonicalTool?.stableName ?? 'claude:$rawToolName';

    if (canonicalTool == null) {
      _log.warning('Falling back to unmapped Claude tool name: $rawToolName -> $guardToolName');
    }

    try {
      final chain = guardChain;
      if (chain != null) {
        final verdict = await chain.evaluateBeforeToolCall(
          guardToolName,
          toolInput,
          sessionId: _activeTurnSessionId,
          agentId: _activeAgentId,
          rawProviderToolName: rawToolName,
        );
        if (verdict.isBlock) {
          if (_tryWriteHookResponse(requestId, _adapter.buildHookResponse(requestId, allow: false))) {
            emitEvent(ToolApprovalResolvedEvent(requestId: requestId));
          }
          return;
        }
      }
    } catch (error, stackTrace) {
      _log.severe('Claude hook guard evaluation failed for $requestId: $error', error, stackTrace);
      if (_tryWriteHookResponse(requestId, _adapter.buildHookResponse(requestId, allow: false))) {
        emitEvent(ToolApprovalResolvedEvent(requestId: requestId));
      }
      return;
    }

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
      writeJsonLine(response);
      return true;
    } catch (error, stackTrace) {
      _log.severe('Failed to write Claude hook response for $requestId: $error', error, stackTrace);
      return false;
    }
  }

  void _handlePostToolUseCallback(String requestId, Map<String, dynamic> hookInput) {
    final toolName = hookInput['tool_name'] as String;
    final toolResponse = _parseToolResponse(hookInput['tool_response']);

    final success = toolResponse['error'] == null;
    try {
      auditLogger?.logPostToolUse(toolName: toolName, success: success, response: toolResponse);
    } catch (error, stackTrace) {
      _log.warning('Claude PostToolUse observer failed for $requestId: $error', error, stackTrace);
    }
    _tryWriteHookResponse(requestId, _adapter.buildHookResponse(requestId, allow: true));
  }

  void _handlePermissionDeniedCallback(String requestId, Map<String, dynamic> hookInput) {
    final toolName = hookInput['tool_name'] as String;
    final reason = hookInput['reason'] as String?;

    try {
      onPermissionDenied?.call(toolName, reason);
    } catch (error, stackTrace) {
      _log.warning('Claude PermissionDenied observer failed for $requestId: $error', error, stackTrace);
    }

    // Acknowledge receipt. The denial already occurred at Claude Code's layer;
    // DartClaw cannot override it — this is informational only.
    _tryWriteHookResponse(requestId, _adapter.buildHookResponse(requestId, allow: true));
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
}
