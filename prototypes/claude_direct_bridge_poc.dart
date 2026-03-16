// Proof-of-Concept: Dart → Claude CLI Direct Bridge (Option D+)
//
// Validates that Dart can speak the claude binary's JSONL protocol directly,
// without the Deno/TypeScript Agent SDK layer.
//
// Tests:
//   1. Spawn claude with stream-json I/O
//   2. Send user prompt, receive streaming text deltas
//   3. Handle control_request (tool approval) → control_response
//   4. Multi-turn conversation (follow-up after first turn)
//   5. Graceful shutdown
//
// Usage:
//   dart run prototypes/claude_direct_bridge_poc.dart
//
// Output is written to /tmp/claude_poc_log.txt (to avoid sandbox capture issues).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const _claudeArgs = [
  '--print',
  '--input-format', 'stream-json',
  '--output-format', 'stream-json',
  '--verbose',
  '--include-partial-messages',
  '--no-session-persistence',
  '--permission-prompt-tool', 'stdio', // Enables control_request for tool approval
  '--model', 'haiku',
];

/// Env vars to clear to prevent claude nesting detection.
const _envVarsToClear = ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS'];

/// Tool approval policy for the PoC.
enum ToolPolicy { allowAll, denyAll }

const _toolPolicy = ToolPolicy.allowAll;

// ---------------------------------------------------------------------------
// Logging — all output goes to a file to avoid sandbox capture issues
// ---------------------------------------------------------------------------

late IOSink _logSink;

void _log(String msg) {
  final ts = DateTime.now().toIso8601String().substring(11, 23);
  _logSink.writeln('[$ts] $msg');
}

// ---------------------------------------------------------------------------
// Event types from claude stdout
// ---------------------------------------------------------------------------

sealed class ClaudeEvent {}

class TextDelta extends ClaudeEvent {
  final String text;
  TextDelta(this.text);
}

class ToolRequest extends ClaudeEvent {
  final String requestId;
  final String subtype;
  final String? toolName;
  final Map<String, dynamic>? input;
  ToolRequest({required this.requestId, required this.subtype, this.toolName, this.input});
}

class TurnResult extends ClaudeEvent {
  final Map<String, dynamic> raw;
  TurnResult(this.raw);
}

class UnknownEvent extends ClaudeEvent {
  final String type;
  final Map<String, dynamic> raw;
  UnknownEvent(this.type, this.raw);
}

// ---------------------------------------------------------------------------
// Bridge
// ---------------------------------------------------------------------------

class ClaudeDirectBridge {
  final String executable;
  Process? _process;
  final _events = StreamController<ClaudeEvent>.broadcast();
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  bool _closed = false;
  int _controlRequestCount = 0;
  int _controlResponseCount = 0;
  int _textDeltaCount = 0;
  int _lineCount = 0;
  String? sessionId;

  ClaudeDirectBridge({this.executable = 'claude'});

  Stream<ClaudeEvent> get events => _events.stream;

  Future<void> start() async {
    // Build a clean env from parent, removing Claude nesting detection vars.
    // Use includeParentEnvironment: false to ensure removed vars are truly absent.
    final env = Map<String, String>.from(Platform.environment);
    for (final key in _envVarsToClear) {
      env.remove(key);
    }

    _log('Starting claude process...');
    _log('Executable: $executable');
    _log('Args: ${_claudeArgs.join(' ')}');
    _log('Env CLAUDECODE present: ${env.containsKey('CLAUDECODE')}');

    final process = await Process.start(executable, _claudeArgs, environment: env, includeParentEnvironment: false);
    _process = process;
    _log('Process started (pid: ${process.pid})');

    _stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.isNotEmpty)
        .listen(_handleLine, onError: (e) => _log('stdout error: $e'), onDone: () => _log('stdout stream closed'));

    _stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _log('[stderr] $line'));

    unawaited(
      process.exitCode.then((code) {
        _log('Process exited with code $code');
        if (!_closed) close();
      }),
    );
  }

  /// Send the initialize control request. Must be called after start(), before sendMessage().
  /// Registers hooks and MCP servers with the claude binary.
  Future<void> initialize({String? systemPrompt}) async {
    final initCompleter = Completer<Map<String, dynamic>>();

    // Temporarily listen for the initialize response
    late StreamSubscription<ClaudeEvent> sub;
    sub = events.listen((event) {
      if (event is UnknownEvent && event.type == 'control_response') {
        sub.cancel();
        initCompleter.complete(event.raw);
      }
    });

    final requestId = 'req_init_${DateTime.now().millisecondsSinceEpoch}';
    _log('Sending initialize (id: $requestId)...');
    _writeLine({
      'type': 'control_request',
      'request_id': requestId,
      'request': {
        'subtype': 'initialize',
        'hooks': {
          'PreToolUse': [
            {
              'matcher': 'Bash',
              'hookCallbackIds': ['hook_bash_pre'],
              'timeout': 30,
            },
          ],
        },
        'systemPrompt': ?systemPrompt,
      },
    });

    final response = await initCompleter.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        sub.cancel();
        _log('Initialize timed out');
        return <String, dynamic>{};
      },
    );
    _log(
      'Initialize response: ${jsonEncode(response).length > 500 ? '${jsonEncode(response).substring(0, 500)}...' : jsonEncode(response)}',
    );
  }

  void _handleLine(String line) {
    _lineCount++;
    Map<String, dynamic> json;
    try {
      json = jsonDecode(line) as Map<String, dynamic>;
    } catch (e) {
      _log('PARSE ERROR on line $_lineCount: $e');
      _log('  Raw: ${line.length > 300 ? '${line.substring(0, 300)}...' : line}');
      return;
    }

    final type = json['type'] as String?;

    switch (type) {
      case 'system':
        _handleSystem(json);
      case 'assistant':
        _handleAssistant(json);
      case 'result':
        _log('RESULT event received');
        _events.add(TurnResult(json));
      case 'stream_event':
        _handleStreamEvent(json);
      case 'control_request':
        _handleControlRequest(json);
      case 'control_response':
        _events.add(UnknownEvent('control_response', json));
      default:
        _events.add(UnknownEvent(type ?? 'null', json));
    }
  }

  void _handleSystem(Map<String, dynamic> json) {
    final subtype = json['subtype'] as String?;
    _log('System event: $subtype');
    if (subtype == 'init') {
      sessionId = json['session_id'] as String?;
      _log('Session ID: $sessionId');
      final tools = json['tools'] as List?;
      _log('Available tools: ${tools?.length ?? 0}');
    }
  }

  void _handleStreamEvent(Map<String, dynamic> json) {
    // stream_event wraps the raw API streaming events (content_block_delta, etc.)
    final event = json['event'] as Map<String, dynamic>?;
    if (event == null) return;

    final eventType = event['type'] as String?;
    switch (eventType) {
      case 'content_block_delta':
        final delta = event['delta'] as Map<String, dynamic>?;
        if (delta == null) return;
        final deltaType = delta['type'] as String?;
        if (deltaType == 'text_delta') {
          final text = delta['text'] as String? ?? '';
          if (text.isNotEmpty) {
            _textDeltaCount++;
            _events.add(TextDelta(text));
          }
        } else if (deltaType == 'input_json_delta') {
          // Tool input streaming — log but don't emit
        }
      case 'content_block_start':
        final contentBlock = event['content_block'] as Map<String, dynamic>?;
        if (contentBlock != null && contentBlock['type'] == 'tool_use') {
          _log('Stream: tool_use start — ${contentBlock['name']}');
        }
      case 'content_block_stop':
        break; // Normal
      case 'message_start' || 'message_delta' || 'message_stop':
        break; // Message lifecycle
      default:
        break; // Ignore other stream events
    }
  }

  void _handleAssistant(Map<String, dynamic> json) {
    // With --include-partial-messages, 'assistant' events contain complete/partial
    // messages. We only use these for tool_use and tool_result metadata — text
    // deltas come from stream_event to avoid double-counting.
    final message = json['message'] as Map<String, dynamic>?;
    if (message == null) return;

    final content = message['content'];
    if (content is List) {
      for (final block in content) {
        if (block is Map<String, dynamic>) {
          final blockType = block['type'] as String?;
          if (blockType == 'tool_use') {
            final toolName = block['name'] as String? ?? 'unknown';
            final toolId = block['id'] as String? ?? '';
            _log('Tool use block: $toolName (id: $toolId)');
          } else if (blockType == 'tool_result') {
            final resultContent = block['content'] as String? ?? '';
            _log(
              'Tool result: ${resultContent.length > 100 ? '${resultContent.substring(0, 100)}...' : resultContent}',
            );
          }
        }
      }
    }
  }

  void _handleControlRequest(Map<String, dynamic> json) {
    _controlRequestCount++;
    final requestId = json['request_id'] as String? ?? '';
    final request = json['request'] as Map<String, dynamic>? ?? {};
    final subtype = request['subtype'] as String? ?? 'unknown';

    switch (subtype) {
      case 'can_use_tool':
        final toolName = request['tool_name'] as String?;
        final input = request['input'] as Map<String, dynamic>?;
        final toolUseId = request['tool_use_id'] as String?;
        _log('CONTROL REQUEST #$_controlRequestCount: can_use_tool (tool: $toolName, id: $requestId)');
        if (input != null && toolName == 'Bash') {
          _log('  Bash command: ${input['command']}');
        }
        _events.add(ToolRequest(requestId: requestId, subtype: subtype, toolName: toolName, input: input));
        final allow = _toolPolicy == ToolPolicy.allowAll;
        _sendToolResponse(requestId, allow: allow, toolUseId: toolUseId);

      case 'hook_callback':
        final callbackId = request['callback_id'] as String?;
        final hookInput = request['input'] as Map<String, dynamic>?;
        final hookEvent = hookInput?['hook_event_name'] as String?;
        final toolName = hookInput?['tool_name'] as String?;
        _log(
          'CONTROL REQUEST #$_controlRequestCount: hook_callback ($hookEvent, tool: $toolName, callback: $callbackId, id: $requestId)',
        );
        // Allow the hook and continue
        _sendHookResponse(requestId, allow: true);

      default:
        _log('CONTROL REQUEST #$_controlRequestCount: $subtype (id: $requestId)');
        // Generic allow response
        _writeLine({
          'type': 'control_response',
          'response': {'subtype': 'success', 'request_id': requestId, 'response': {}},
        });
        _controlResponseCount++;
    }
  }

  void _sendToolResponse(String requestId, {required bool allow, String? toolUseId}) {
    _controlResponseCount++;
    final response = {
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': requestId,
        'response': {'behavior': allow ? 'allow' : 'deny', 'toolUseID': ?toolUseId},
      },
    };
    _writeLine(response);
    _log('CONTROL RESPONSE #$_controlResponseCount: ${allow ? 'ALLOW' : 'DENY'} (id: $requestId)');
  }

  void _sendHookResponse(String requestId, {required bool allow}) {
    _controlResponseCount++;
    final response = {
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': requestId,
        'response': {
          'continue': true,
          'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': allow ? 'allow' : 'deny'},
        },
      },
    };
    _writeLine(response);
    _log('HOOK RESPONSE #$_controlResponseCount: ${allow ? 'ALLOW' : 'DENY'} (id: $requestId)');
  }

  void sendMessage(String text) {
    _log('>>> SEND: "${text.length > 100 ? '${text.substring(0, 100)}...' : text}"');
    _writeLine({
      'type': 'user',
      'message': {'role': 'user', 'content': text},
    });
  }

  void _writeLine(Map<String, dynamic> json) {
    final line = '${jsonEncode(json)}\n';
    _process?.stdin.add(utf8.encode(line));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    try {
      await _process?.stdin.close();
    } catch (_) {}
    _process?.kill();
    await _events.close();
  }

  void printStats() {
    _log('');
    _log('=== Bridge Stats ===');
    _log('NDJSON lines parsed:  $_lineCount');
    _log('Text delta events:    $_textDeltaCount');
    _log('Control requests:     $_controlRequestCount');
    _log('Control responses:    $_controlResponseCount');
    _log('Session ID:           $sessionId');
    _log('====================');
  }
}

// ---------------------------------------------------------------------------
// Main — PoC test harness
// ---------------------------------------------------------------------------

Future<void> main() async {
  final logFile = File('/tmp/claude_poc_log.txt');
  _logSink = logFile.openWrite();
  _log('=== Claude Direct Bridge PoC ===');
  _log('Log file: ${logFile.path}');

  try {
    final claudePath = await _resolveClaudePath();
    _log('Resolved claude: $claudePath');

    final bridge = ClaudeDirectBridge(executable: claudePath);

    final textBuffer = StringBuffer();
    var turnComplete = Completer<void>();
    var toolRequestsSeen = 0;

    bridge.events.listen((event) {
      switch (event) {
        case TextDelta(:final text):
          textBuffer.write(text);
        case ToolRequest(:final toolName, :final input):
          toolRequestsSeen++;
          _log('[TOOL USE: $toolName${input != null && toolName == 'Bash' ? ' → ${input['command']}' : ''}]');
        case TurnResult(:final raw):
          final stopReason = raw['stop_reason'] as String?;
          final cost = raw['total_cost_usd'];
          final durationMs = raw['duration_ms'];
          _log('TURN COMPLETE (stop: $stopReason, cost: \$$cost, duration: ${durationMs}ms)');
          _log('Response text: "${textBuffer.toString()}"');
          if (!turnComplete.isCompleted) turnComplete.complete();
        case UnknownEvent(:final type):
          if (type != 'assistant') _log('[Unknown event: $type]');
      }
    });

    await bridge.start();

    // Send initialize handshake — registers hooks and enables control_request flow
    await bridge.initialize(systemPrompt: 'You are a test assistant. Be very brief. Follow instructions exactly.');

    // --- Turn 1: Simple prompt ---
    _log('');
    _log('========== TURN 1: Simple prompt (no tool use expected) ==========');
    textBuffer.clear();
    turnComplete = Completer<void>();
    toolRequestsSeen = 0;

    bridge.sendMessage('What is 2 + 2? Reply with ONLY the number, nothing else.');

    await turnComplete.future.timeout(const Duration(seconds: 30), onTimeout: () => _log('TIMEOUT: Turn 1 after 30s'));
    _log('Turn 1 result: text="${textBuffer.toString()}", tools=$toolRequestsSeen');

    // --- Turn 2: Tool use ---
    _log('');
    _log('========== TURN 2: Bash tool use ==========');
    textBuffer.clear();
    turnComplete = Completer<void>();
    toolRequestsSeen = 0;

    bridge.sendMessage('Use the Bash tool to run: echo "hello from dartclaw poc"');

    await turnComplete.future.timeout(const Duration(seconds: 60), onTimeout: () => _log('TIMEOUT: Turn 2 after 60s'));
    _log('Turn 2 result: text="${textBuffer.toString()}", tools=$toolRequestsSeen');

    // --- Turn 3: Multi-turn verification ---
    _log('');
    _log('========== TURN 3: Multi-turn follow-up ==========');
    textBuffer.clear();
    turnComplete = Completer<void>();
    toolRequestsSeen = 0;

    bridge.sendMessage('What was the output of the bash command you just ran? Reply briefly.');

    await turnComplete.future.timeout(const Duration(seconds: 30), onTimeout: () => _log('TIMEOUT: Turn 3 after 30s'));
    _log('Turn 3 result: text="${textBuffer.toString()}", tools=$toolRequestsSeen');

    bridge.printStats();
    await bridge.close();
  } catch (e, st) {
    _log('FATAL ERROR: $e');
    _log('Stack: $st');
  } finally {
    _log('');
    _log('PoC complete.');
    await _logSink.flush();
    await _logSink.close();
    // Print log file location to actual stdout so caller can find it
    print('Log written to: ${logFile.path}');
    exit(0);
  }
}

Future<String> _resolveClaudePath() async {
  final envPath = Platform.environment['CLAUDE_EXECUTABLE'];
  if (envPath != null && envPath.isNotEmpty) return envPath;

  try {
    final result = await Process.run('/usr/bin/which', ['claude']);
    final path = (result.stdout as String).trim();
    if (result.exitCode == 0 && path.isNotEmpty) return path;
  } catch (_) {}

  for (final path in ['${Platform.environment['HOME']}/.local/bin/claude', '/usr/local/bin/claude']) {
    if (await File(path).exists()) return path;
  }

  throw StateError('claude binary not found');
}
