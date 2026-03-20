import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../bridge/bridge_events.dart';
import '../container/container_manager.dart';
import '../worker/worker_state.dart';
import 'agent_harness.dart';
import 'claude_protocol.dart';
import 'harness_config.dart';
import 'process_types.dart';
import 'tool_policy.dart';

// ---------------------------------------------------------------------------
// Claude CLI configuration
// ---------------------------------------------------------------------------

List<String> _buildClaudeArgs({String? model, String? effort, String? appendSystemPrompt, String? mcpConfigPath}) => [
  '--print',
  '--input-format',
  'stream-json',
  '--output-format',
  'stream-json',
  '--verbose',
  '--include-partial-messages',
  '--no-session-persistence',
  '--permission-prompt-tool',
  'stdio',
  '--model',
  model ?? 'opus[1m]',
  if (effort != null) ...['--effort', effort],
  if (appendSystemPrompt != null) ...['--append-system-prompt', appendSystemPrompt],
  if (mcpConfigPath != null) ...['--mcp-config', mcpConfigPath],
];

// ---------------------------------------------------------------------------
// ClaudeCodeHarness
// ---------------------------------------------------------------------------

/// Concrete [AgentHarness] that spawns the `claude` binary directly and speaks
/// its JSONL control protocol — no Deno/TypeScript layer required.
class ClaudeCodeHarness implements AgentHarness {
  final String claudeExecutable;
  final String cwd;
  final Duration turnTimeout;
  final int maxRetries;
  final Duration baseBackoff;
  final ProcessFactory _processFactory;
  final CommandProbe _commandProbe;
  final DelayFactory _delayFactory;
  final Map<String, String> _environment;
  final ToolApprovalPolicy toolPolicy;
  final GuardChain? guardChain;
  final GuardAuditLogger? auditLogger;
  final HarnessConfig harnessConfig;
  final ContainerManager? containerManager;

  /// Memory handler callbacks. Used for `sdkMcpServers` fallback in chat mode
  /// (no MCP server). When `harnessConfig.mcpServerUrl` is set, memory tools
  /// are served via the `/mcp` HTTP endpoint instead.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemorySave;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemorySearch;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemoryRead;

  static final _log = Logger('ClaudeCodeHarness');

  WorkerState _state = WorkerState.stopped;
  String? _mcpConfigPath;
  String? _containerMcpConfigPath;
  int _crashCount = 0;
  int _spawnGeneration = 0;
  Process? _process;
  String? _sessionId;
  Completer<Map<String, dynamic>>? _turnCompleter;
  late String _processWorkingDirectory;
  String? _processModel;
  String? _processEffort;

  /// Serializes mutating lifecycle ops.
  Future<void> _lock = Future<void>.value();

  /// Stable broadcast stream that survives process restarts.
  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();

  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  /// Completer for the initialize handshake response.
  Completer<Map<String, dynamic>>? _initCompleter;

  ClaudeCodeHarness({
    this.claudeExecutable = 'claude',
    required this.cwd,
    this.turnTimeout = const Duration(seconds: 600),
    this.maxRetries = 5,
    this.baseBackoff = const Duration(seconds: 5),
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
    this.harnessConfig = const HarnessConfig(),
    this.containerManager,
  }) : _processFactory = processFactory ?? Process.start,
       _commandProbe = commandProbe ?? Process.run,
       _delayFactory = delayFactory ?? ((d) => Future<void>.delayed(d)),
       _environment = environment ?? Platform.environment {
    _processWorkingDirectory = cwd;
    _processModel = harnessConfig.model;
    _processEffort = harnessConfig.effort;
  }

  @override
  PromptStrategy get promptStrategy => PromptStrategy.append;

  @override
  WorkerState get state => _state;

  @override
  Stream<BridgeEvent> get events => _eventsCtrl.stream;

  /// Session ID assigned by the claude binary after init.
  String? get sessionId => _sessionId;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  Future<void> start() => _withLock(() async {
    if (_state == WorkerState.idle) return;
    if (_state == WorkerState.busy) {
      throw StateError('Cannot start: harness is busy');
    }
    await _startInternal();
  });

  @override
  Future<void> cancel() async {
    // JSONL protocol has no cancel command — close stdin and SIGTERM.
    try {
      await _process?.stdin.close();
    } catch (_) {}
    _process?.kill();
  }

  @override
  Future<void> stop() => _withLock(_stopInternal);

  Future<void> _stopInternal() async {
    if (_state == WorkerState.busy) {
      try {
        await cancel();
      } catch (_) {}
      await _delayFactory(const Duration(milliseconds: 500));
    }
    _state = WorkerState.stopped;
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    await _stderrSub?.cancel();
    _stderrSub = null;
    try {
      await _process?.stdin.close();
    } catch (_) {}
    _process?.kill();
    _process = null;
    final containerMcpPath = _containerMcpConfigPath;
    if (containerMcpPath != null) {
      try {
        await containerManager?.deleteFileInContainer(containerMcpPath);
      } catch (_) {}
      _containerMcpConfigPath = null;
    }
    // Clean up MCP config temp file.
    final mcpPath = _mcpConfigPath;
    if (mcpPath != null) {
      try {
        await File(mcpPath).delete();
      } catch (_) {}
      _mcpConfigPath = null;
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    if (!_eventsCtrl.isClosed) await _eventsCtrl.close();
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
  }) async {
    final desiredWorkingDirectory = _resolveWorkingDirectory(directory);
    final desiredModel = _resolveModel(model);
    final desiredEffort = _resolveEffort(effort);
    if (desiredWorkingDirectory != _processWorkingDirectory ||
        desiredModel != _processModel ||
        desiredEffort != _processEffort ||
        _state == WorkerState.stopped) {
      await _restartForExecution(workingDirectory: desiredWorkingDirectory, model: desiredModel, effort: desiredEffort);
    }

    // Crash restart with exponential backoff.
    if (_state == WorkerState.crashed) {
      if (_crashCount > maxRetries) {
        throw StateError('Harness unavailable: max retries exceeded');
      }
      final backoff = baseBackoff * pow(2, _crashCount - 1).toInt();
      await _delayFactory(backoff);
      await _withLock(() async {
        if (_state == WorkerState.stopped) {
          throw StateError('Harness stopped during backoff');
        }
        if (_state == WorkerState.crashed) await _startInternal();
      });
    }

    if (_state != WorkerState.idle) {
      throw StateError('Harness is not idle (state: $_state)');
    }
    _state = WorkerState.busy;

    Timer? timeoutTimer;
    timeoutTimer = Timer(turnTimeout, () async {
      _log.warning('Turn timeout exceeded, cancelling...');
      try {
        await cancel();
      } catch (_) {}
      await _delayFactory(const Duration(seconds: 5));
      _process?.kill();
    });

    _turnCompleter = Completer<Map<String, dynamic>>();

    try {
      // Build the user message payload. The claude binary manages its own
      // history within the subprocess session, so we send the last user
      // message plus the system prompt (injected each turn since the binary
      // doesn't persist it across turn boundaries).
      final payload = <String, dynamic>{
        'type': 'user',
        'message': {'role': 'user', 'content': messages.last['content']},
      };
      // Only send system_prompt for replace-mode harnesses (append-mode uses CLI flag)
      if (promptStrategy == PromptStrategy.replace && systemPrompt.isNotEmpty) {
        payload['system_prompt'] = systemPrompt;
      }
      if (resume) {
        payload['resume'] = true;
      }
      _writeLine(payload);

      final result = await _turnCompleter!.future;
      timeoutTimer.cancel();
      if (_state != WorkerState.stopped) {
        _crashCount = 0;
        _state = WorkerState.idle;
      }
      return result;
    } catch (e) {
      timeoutTimer.cancel();
      if (_state != WorkerState.crashed && _state != WorkerState.stopped) {
        _state = WorkerState.idle;
      }
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // Internal: start, auth, handshake
  // -------------------------------------------------------------------------

  Future<void> _startInternal() async {
    final cm = containerManager;
    if (cm == null) {
      // Check claude binary.
      final claudeResult = await _commandProbe(claudeExecutable, ['--version']);
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
    );
    final Process process;
    if (cm != null) {
      final containerExecutable = claudeExecutable.contains('/')
          ? claudeExecutable
          : ContainerManager.containerClaudeExecutable;
      // Restricted containers use simple mode — disables MCP, hooks, CLAUDE.md
      final containerEnv = cm.profileId == 'restricted' ? {'CLAUDE_CODE_SIMPLE': '1'} : null;
      process = await cm.exec(
        [containerExecutable, ...args],
        workingDirectory: _processWorkingDirectory,
        env: containerEnv,
      );
    } else {
      process = await _processFactory(
        claudeExecutable,
        args,
        workingDirectory: _processWorkingDirectory,
        environment: env,
        includeParentEnvironment: false,
      );
    }

    final generation = ++_spawnGeneration;
    _process = process;

    // Listen to stdout lines → parse JSONL → route messages.
    _stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.isNotEmpty)
        .listen(_handleLine, onError: (Object e) => _log.warning('stdout error: $e'));

    // Capture stderr.
    _stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _log.warning('[claude stderr] $line'));

    // Crash detection via process exit.
    unawaited(
      process.exitCode.then((code) {
        if (generation != _spawnGeneration) return;
        if (_state == WorkerState.stopped) return;
        _log.warning('Claude process exited unexpectedly: exit code $code');
        if (_state != WorkerState.crashed) {
          _state = WorkerState.crashed;
          _crashCount++;
        }
        // Complete any pending turn with an error.
        if (_turnCompleter != null && !_turnCompleter!.isCompleted) {
          _turnCompleter!.completeError(StateError('Claude process exited with code $code'));
        }
      }),
    );

    // Initialize handshake.
    await _sendInitialize();

    _state = WorkerState.idle;
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

  Future<void> _restartForExecution({
    required String workingDirectory,
    required String? model,
    required String? effort,
  }) async {
    await _withLock(() async {
      if (_state == WorkerState.busy) {
        throw StateError('Cannot change working directory, model, or effort while harness is busy');
      }
      if (_processWorkingDirectory == workingDirectory &&
          _processModel == model &&
          _processEffort == effort &&
          _state != WorkerState.stopped) {
        return;
      }
      await _stopInternal();
      _processWorkingDirectory = workingDirectory;
      _processModel = model;
      _processEffort = effort;
      await _startInternal();
    });
  }

  /// Verifies that ANTHROPIC_API_KEY or Claude CLI OAuth session is available.
  Future<void> _verifyAuth() async {
    final hasApiKey = _environment['ANTHROPIC_API_KEY']?.trim().isNotEmpty ?? false;
    if (hasApiKey) return;

    final result = await _commandProbe(claudeExecutable, ['auth', 'status']);
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

    final initRequest = <String, dynamic>{
      'subtype': 'initialize',
      'hooks': {
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
      // Memory tools via sdkMcpServers fallback for chat mode (no MCP server).
      // When mcpServerUrl is set (serve command), tools come from /mcp instead.
      if (harnessConfig.mcpServerUrl == null) ..._buildMemorySdkMcpServers(),
      ...harnessConfig.toInitializeFields(),
    };

    _writeLine({'type': 'control_request', 'request_id': requestId, 'request': initRequest});

    try {
      await _initCompleter!.future.timeout(const Duration(seconds: 10));
      _log.info('Initialize handshake complete');
    } on TimeoutException {
      _log.severe('Initialize handshake timed out — killing process');
      _process?.kill();
      _process = null;
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

  void _handleLine(String line) {
    // First check for control_response (not handled by parseJsonlLine, needed
    // for the initialize handshake).
    if (_initCompleter != null && !_initCompleter!.isCompleted) {
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        if (json['type'] == 'control_response') {
          _initCompleter!.complete(json);
          return;
        }
      } catch (_) {
        // Fall through to normal parsing.
      }
    }

    final msg = parseJsonlLine(line);
    if (msg == null) return;

    switch (msg) {
      case StreamTextDelta(:final text):
        _eventsCtrl.add(DeltaEvent(text));

      case ToolUseBlock(:final name, :final id, :final input):
        _eventsCtrl.add(ToolUseEvent(toolName: name, toolId: id, input: input));

      case ToolResultBlock(:final toolId, :final output, :final isError):
        _eventsCtrl.add(ToolResultEvent(toolId: toolId, output: output, isError: isError));

      case ControlRequest(:final requestId, :final subtype, :final data):
        _handleControlRequest(requestId, subtype, data);

      case TurnResult(:final stopReason, :final costUsd, :final durationMs, :final inputTokens, :final outputTokens):
        if (_turnCompleter != null && !_turnCompleter!.isCompleted) {
          _turnCompleter!.complete({
            'stop_reason': stopReason,
            'total_cost_usd': costUsd,
            'duration_ms': durationMs,
            'input_tokens': inputTokens,
            'output_tokens': outputTokens,
          });
        }

      case SystemInit(:final sessionId, :final toolCount, :final contextWindow):
        _sessionId = sessionId;
        _log.info('Session init: id=$sessionId, tools=$toolCount, contextWindow=$contextWindow');
        if (contextWindow != null) {
          _eventsCtrl.add(SystemInitEvent(contextWindow: contextWindow));
        }
    }
  }

  // -------------------------------------------------------------------------
  // Control request handling
  // -------------------------------------------------------------------------

  void _handleControlRequest(String requestId, String subtype, Map<String, dynamic> data) {
    switch (subtype) {
      case 'can_use_tool':
        final allow = toolPolicy == ToolApprovalPolicy.allowAll;
        final toolUseId = data['tool_use_id'] as String?;
        _writeLine(buildToolResponse(requestId, allow: allow, toolUseId: toolUseId));

      case 'hook_callback':
        _handleHookCallback(requestId, data);

      default:
        _writeLine(buildGenericResponse(requestId));
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
    final toolName = hookInput?['tool_name'] as String? ?? '';
    final toolInput = hookInput?['tool_input'] as Map<String, dynamic>? ?? {};

    // Guard evaluation
    final chain = guardChain;
    if (chain != null) {
      final verdict = await chain.evaluateBeforeToolCall(toolName, toolInput, sessionId: _sessionId);
      if (verdict.isBlock) {
        _writeLine(buildHookResponse(requestId, allow: false));
        return;
      }
    }

    // Credential stripping for Bash tool
    final envMap = toolInput['env'] as Map<String, dynamic>?;
    if (envMap != null && envMap.containsKey('ANTHROPIC_API_KEY')) {
      final sanitizedEnv = Map<String, dynamic>.from(envMap)..remove('ANTHROPIC_API_KEY');
      final updatedInput = Map<String, dynamic>.from(toolInput)..['env'] = sanitizedEnv;
      _log.info('Stripped ANTHROPIC_API_KEY from bash env');
      _writeLine({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': requestId,
          'response': {
            'continue': true,
            'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'updatedInput': updatedInput},
          },
        },
      });
      return;
    }

    _writeLine(buildHookResponse(requestId, allow: true));
  }

  void _handlePostToolUseCallback(String requestId, Map<String, dynamic>? hookInput) {
    final toolName = hookInput?['tool_name'] as String? ?? 'unknown';
    final toolResponse = _parseToolResponse(hookInput?['tool_response']);

    final success = toolResponse['error'] == null;
    auditLogger?.logPostToolUse(toolName: toolName, success: success, response: toolResponse);

    _writeLine(buildHookResponse(requestId, allow: true));
  }

  static Map<String, dynamic> _parseToolResponse(Object? raw) {
    try {
      if (raw is Map) return Map<String, dynamic>.from(raw);
      if (raw is String) return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {}
    return <String, dynamic>{};
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  void _writeLine(Map<String, dynamic> json) {
    final line = '${jsonEncode(json)}\n';
    _process?.stdin.add(utf8.encode(line));
  }

  /// Chains [fn] after the current lifecycle lock, preventing concurrent
  /// mutations.
  Future<T> _withLock<T>(Future<T> Function() fn) {
    final completer = Completer<T>();
    final next = _lock.catchError((_) {}).then((_) => fn());
    _lock = next.then<void>((_) {}, onError: (_) {});
    next.then(completer.complete, onError: completer.completeError);
    return completer.future;
  }
}
