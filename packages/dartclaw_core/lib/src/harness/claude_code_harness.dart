import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../bridge/bridge_events.dart';
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../config/history_config.dart';
import '../container/container_manager.dart';
import '../worker/worker_state.dart';
import 'agent_harness.dart';
import 'base_harness.dart';
import 'base_protocol_adapter.dart';
import 'claude_protocol_adapter.dart';
import 'claude_protocol.dart';
import 'conversation_history.dart';
import 'harness_config.dart';
import 'protocol_message.dart' as proto;
import 'process_types.dart';
import 'tool_policy.dart';

// ---------------------------------------------------------------------------
// Claude CLI configuration
// ---------------------------------------------------------------------------

List<String> _buildClaudeArgs({
  String? model,
  String? effort,
  String? appendSystemPrompt,
  String? mcpConfigPath,
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
  if (skipNativePermissions) '--dangerously-skip-permissions' else ...['--permission-prompt-tool', 'stdio'],
  if (settingSourcesProject) ...['--setting-sources', 'project'],
  '--model',
  model ?? 'opus[1m]',
  if (effort != null) ...['--effort', effort],
  if (appendSystemPrompt != null) ...['--append-system-prompt', appendSystemPrompt],
  if (mcpConfigPath != null) ...['--mcp-config', mcpConfigPath],
];

/// Env var forwarded from [_environment] to containerized spawns when present.
/// Set at the wiring layer for task runners only.
const _subagentModelEnvVar = 'CLAUDE_CODE_SUBAGENT_MODEL';

// ---------------------------------------------------------------------------
// ClaudeCodeHarness
// ---------------------------------------------------------------------------

/// Concrete [AgentHarness] that spawns the `claude` binary directly and speaks
/// its JSONL control protocol — no Deno/TypeScript layer required.
class ClaudeCodeHarness extends BaseHarness {
  final String claudeExecutable;
  final Map<String, String> _environment;
  final ToolApprovalPolicy toolPolicy;
  final GuardChain? guardChain;
  final GuardAuditLogger? auditLogger;
  final HistoryConfig historyConfig;
  final ContainerManager? containerManager;
  final ClaudeProtocolAdapter _adapter;
  final Duration _killGracePeriod;

  /// Memory handler callbacks. Used for `sdkMcpServers` fallback in chat mode
  /// (no MCP server). When `harnessConfig.mcpServerUrl` is set, memory tools
  /// are served via the `/mcp` HTTP endpoint instead.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemorySave;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemorySearch;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemoryRead;

  static final _log = Logger('ClaudeCodeHarness');

  String? _mcpConfigPath;
  String? _containerMcpConfigPath;
  int _turnsSinceStart = 0;
  String? _sessionId;
  Completer<Map<String, dynamic>>? _turnCompleter;
  late String _processWorkingDirectory;
  String? _processModel;
  String? _processEffort;
  int? _processMaxTurns;

  /// Completer for the initialize handshake response.
  Completer<Map<String, dynamic>>? _initCompleter;

  // ignore: use_super_parameters
  ClaudeCodeHarness({
    this.claudeExecutable = 'claude',
    required String cwd,
    Duration turnTimeout = const Duration(seconds: 600),
    int maxRetries = 5,
    Duration baseBackoff = const Duration(seconds: 5),
    ProcessFactory? processFactory,
    CommandProbe? commandProbe,
    DelayFactory? delayFactory,
    Map<String, String>? environment,
    this.toolPolicy = ToolApprovalPolicy.allowAll,
    this.guardChain,
    this.auditLogger,
    this.onMemorySave,
    this.onMemorySearch,
    this.onMemoryRead,
    HarnessConfig harnessConfig = const HarnessConfig(),
    this.historyConfig = const HistoryConfig.defaults(),
    this.containerManager,
    ClaudeProtocolAdapter? protocolAdapter,
    Duration killGracePeriod = const Duration(seconds: 2),
  }) : _environment = environment ?? Platform.environment,
       _adapter = protocolAdapter ?? ClaudeProtocolAdapter(),
       _killGracePeriod = killGracePeriod,
       super(
         log: _log,
         cwd: cwd,
         turnTimeout: turnTimeout,
         maxRetries: maxRetries,
         baseBackoff: baseBackoff,
         processFactory: processFactory ?? Process.start,
         commandProbe: commandProbe ?? Process.run,
         delayFactory: delayFactory ?? ((d) => Future<void>.delayed(d)),
         harnessConfig: harnessConfig,
       ) {
    _processWorkingDirectory = cwd;
    _processModel = harnessConfig.model;
    _processEffort = harnessConfig.effort;
    _processMaxTurns = harnessConfig.maxTurns;
  }

  @override
  PromptStrategy get promptStrategy => PromptStrategy.append;

  @override
  bool get supportsCachedTokens => true;

  /// Session ID assigned by the claude binary after init.
  String? get sessionId => _sessionId;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  Future<void> start() => startLifecycle(
    busyMessage: 'Cannot start: harness is busy',
    beforeStart: () async {
      isStopping = false;
    },
    start: _startInternal,
  );

  @override
  Future<void> cancel() async {
    // JSONL protocol has no cancel command — close stdin and SIGTERM.
    await closeCurrentProcessStdin();
    currentProcess?.kill();
  }

  @override
  Future<void> stop() {
    // Set immediately (before lock) so the exitCode crash handler can
    // distinguish intentional shutdown from unexpected process exit.
    isStopping = true;
    return withLock(_stopInternal);
  }

  Future<void> _stopInternal() async {
    final process = currentProcess;
    final wasBusy = currentState == WorkerState.busy;
    if (wasBusy) {
      try {
        await cancel();
      } catch (e) {
        _log.fine('Failed to cancel during stop: $e');
      }
      await delayFactory(const Duration(milliseconds: 500));
    }
    currentState = WorkerState.stopped;
    await shutdownCurrentProcess(
      label: 'Claude',
      gracePeriod: _killGracePeriod,
      alreadySignalled: wasBusy,
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

  // -------------------------------------------------------------------------
  // turn()
  // -------------------------------------------------------------------------

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
        desiredModel != _processModel ||
        desiredEffort != _processEffort ||
        desiredMaxTurns != _processMaxTurns ||
        currentState == WorkerState.stopped) {
      await _restartForExecution(
        workingDirectory: desiredWorkingDirectory,
        model: desiredModel,
        effort: desiredEffort,
        maxTurns: desiredMaxTurns,
      );
    }

    await recoverFromCrash(_startInternal);

    if (currentState != WorkerState.idle) {
      throw StateError('Harness is not idle (state: $currentState)');
    }
    currentState = WorkerState.busy;

    Timer? timeoutTimer;
    timeoutTimer = Timer(turnTimeout, () async {
      _log.warning('Turn timeout exceeded, cancelling...');
      try {
        await cancel();
      } catch (e) {
        _log.fine('Failed to cancel during turn timeout: $e');
      }
      await delayFactory(const Duration(seconds: 5));
      currentProcess?.kill();
    });

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

      final result = await _turnCompleter!.future;
      timeoutTimer.cancel();
      if (currentState != WorkerState.stopped) {
        crashCount = 0;
        currentState = WorkerState.idle;
      }
      _turnsSinceStart++;
      return result;
    } catch (e) {
      timeoutTimer.cancel();
      if (currentState != WorkerState.crashed && currentState != WorkerState.stopped) {
        currentState = WorkerState.idle;
      }
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // Internal: start, auth, handshake
  // -------------------------------------------------------------------------

  Future<void> _startInternal() async {
    _turnsSinceStart = 0;
    final cm = containerManager;
    if (cm == null) {
      // Check claude binary.
      final claudeResult = await commandProbe(claudeExecutable, ['--version']);
      if (claudeResult.exitCode != 0) {
        throw StateError('claude binary not found at $claudeExecutable');
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
      await configFile.writeAsString(configJson, flush: true);
      // Set 0600 permissions (owner read/write only).
      await Process.run('chmod', ['600', configFile.path]);
      mcpConfigPath = configFile.path;
      _mcpConfigPath = mcpConfigPath;
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
          await cm.copyFileToContainer(mcpConfigPath, mcpConfigArgPath);
          _containerMcpConfigPath = mcpConfigArgPath;
        }
      }
    } else {
      mcpConfigArgPath = mcpConfigPath;
    }

    // Spawn claude process: containerized or direct.
    final args = _buildClaudeArgs(
      model: _processModel ?? harnessConfig.model,
      effort: _processEffort ?? harnessConfig.effort,
      appendSystemPrompt: harnessConfig.appendSystemPrompt,
      mcpConfigPath: mcpConfigArgPath,
      settingSourcesProject: cm == null,
      // Restricted containers keep native permission prompts enabled so tool
      // requests still flow through the provider permission channel.
      skipNativePermissions: cm?.profileId != 'restricted',
    );
    final Process process;
    if (cm != null) {
      final containerExecutable = claudeExecutable.contains('/')
          ? claudeExecutable
          : ContainerManager.containerClaudeExecutable;
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

  Future<void> _restartForExecution({
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
      _processWorkingDirectory = workingDirectory;
      _processModel = model;
      _processEffort = effort;
      _processMaxTurns = maxTurns;
      await _startInternal();
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
      '  2. Use Claude CLI OAuth:     claude login\n'
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
            },
          ],
          'PostToolUse': [
            {
              'matcher': null,
              'hookCallbackIds': ['hook_post_tool'],
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
      await _initCompleter!.future.timeout(const Duration(seconds: 10));
      _log.info('Initialize handshake complete');
    } on TimeoutException {
      _log.severe('Initialize handshake timed out — killing process');
      currentProcess?.kill();
      currentProcess = null;
      throw StateError('Initialize handshake timed out after 10s');
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

  // -------------------------------------------------------------------------
  // JSONL message routing
  // -------------------------------------------------------------------------

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
          _turnCompleter!.complete({
            'stop_reason': stopReason,
            'total_cost_usd': costUsd,
            'duration_ms': durationMs,
            'input_tokens': inputTokens,
            'output_tokens': outputTokens,
            'cache_read_tokens': cacheReadTokens ?? 0,
            'cache_write_tokens': cacheWriteTokens ?? 0,
          });
        }

      case proto.SystemInit(:final sessionId, :final toolCount, :final contextWindow):
        _sessionId = sessionId;
        _log.info('Session init: id=$sessionId, tools=$toolCount, contextWindow=$contextWindow');
        if (contextWindow != null) {
          emitEvent(SystemInitEvent(contextWindow: contextWindow));
        }
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

  // -------------------------------------------------------------------------
  // Control request handling
  // -------------------------------------------------------------------------

  void _handleControlRequest(String requestId, String subtype, Map<String, dynamic> data) {
    switch (subtype) {
      case 'can_use_tool':
        final skipNativePermissions = containerManager?.profileId != 'restricted';
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

  /// Routes hook_callback by event type: PreToolUse (guard + credential strip)
  /// or PostToolUse (audit logging).
  void _handleHookCallback(String requestId, Map<String, dynamic> data) {
    final hookInput = data['input'] as Map<String, dynamic>?;
    final hookEventName = hookInput?['hook_event_name'] as String?;

    if (hookEventName == 'PostToolUse') {
      _handlePostToolUseCallback(requestId, hookInput);
      return;
    }

    // PreToolUse (default path)
    unawaited(_handlePreToolUseCallback(requestId, hookInput));
  }

  Future<void> _handlePreToolUseCallback(String requestId, Map<String, dynamic>? hookInput) async {
    final rawToolName = hookInput?['tool_name'] as String? ?? '';
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
        _writeLine(_adapter.buildHookResponse(requestId, allow: false));
        return;
      }
    }

    // Credential stripping for Bash tool
    final envMap = toolInput['env'] as Map<String, dynamic>?;
    if (envMap != null && envMap.containsKey('ANTHROPIC_API_KEY')) {
      final sanitizedEnv = Map<String, dynamic>.from(envMap)..remove('ANTHROPIC_API_KEY');
      final updatedInput = Map<String, dynamic>.from(toolInput)..['env'] = sanitizedEnv;
      _log.info('Stripped ANTHROPIC_API_KEY from bash env');
      _writeLine(_adapter.buildCredentialStripResponse(requestId, updatedInput));
      return;
    }

    _writeLine(_adapter.buildHookResponse(requestId, allow: true));
  }

  void _handlePostToolUseCallback(String requestId, Map<String, dynamic>? hookInput) {
    final toolName = hookInput?['tool_name'] as String? ?? 'unknown';
    final toolResponse = _parseToolResponse(hookInput?['tool_response']);

    final success = toolResponse['error'] == null;
    auditLogger?.logPostToolUse(toolName: toolName, success: success, response: toolResponse);

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

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  void _writeLine(Map<String, dynamic> json) {
    writeJsonLine(json);
  }
}
