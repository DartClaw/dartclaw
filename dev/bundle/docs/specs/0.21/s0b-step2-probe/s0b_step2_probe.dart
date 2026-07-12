// S0b step 2 probe — drives native-Windows `claude` (JSONL stream-json) and
// `codex app-server` (JSON-RPC) over raw process stdio, inspects line endings
// (CRLF vs LF) on the wire, and verifies a full prompt->response turn.
//
// SDK-only, single file (no pub deps). Run on the Windows VM, in a terminal
// where `claude` and `codex` are already installed and authenticated:
//
//   dart s0b_step2_probe.dart all          # or: claude | codex
//
// Spawn args and message shapes mirror dartclaw_core's ClaudeCodeHarness /
// CodexHarness + protocol adapters, so the evidence transfers to F09.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

int failures = 0;

void check(String what, bool ok) {
  stdout.writeln('${ok ? 'PASS' : 'FAIL'}: $what');
  if (!ok) failures++;
}

void info(String msg) => stdout.writeln('  $msg');

String trunc(String s, [int n = 300]) => s.length <= n ? s : '${s.substring(0, n)}...';

/// Verbatim replica of the production byte->line chain in dartclaw_core
/// base_harness.attachProcess / bridge/ndjson_channel.dart.
Stream<String> productionLineChain(Stream<List<int>> bytes) =>
    bytes.transform(utf8.decoder).transform(const LineSplitter()).where((l) => l.isNotEmpty);

class EndingStats {
  int crlf = 0, loneLf = 0, loneCr = 0;

  @override
  String toString() => 'CRLF: $crlf, lone LF: $loneLf, lone CR: $loneCr';
}

EndingStats endingStats(List<int> b) {
  final s = EndingStats();
  for (var i = 0; i < b.length; i++) {
    if (b[i] == 10) {
      if (i > 0 && b[i - 1] == 13) {
        s.crlf++;
      } else {
        s.loneLf++;
      }
    } else if (b[i] == 13 && (i + 1 >= b.length || b[i + 1] != 10)) {
      s.loneCr++;
    }
  }
  return s;
}

/// Resolves a command via `where`, preferring a real .exe over npm .cmd shims.
/// Returns the path and whether a shell is needed to spawn it (.cmd/.ps1).
Future<(String, bool)> resolveExe(String name) async {
  final r = await Process.run('where', [name], runInShell: true);
  final hits = (r.stdout as String).split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  if (hits.isEmpty) {
    throw StateError('`$name` not found on PATH');
  }
  final exe = hits.firstWhere((h) => h.toLowerCase().endsWith('.exe'), orElse: () => hits.first);
  return (exe, !exe.toLowerCase().endsWith('.exe'));
}

// --- claude: JSONL over stdio, single --print turn ---

Future<void> probeClaude() async {
  stdout.writeln('--- claude JSONL (stream-json) probe ---');
  final (exe, useShell) = await resolveExe('claude');
  info('executable: $exe${useShell ? ' (non-exe shim, spawning via shell)' : ''}');
  final ver = await Process.run(exe, ['--version'], runInShell: useShell);
  info('version: ${(ver.stdout as String).trim()}');

  // Mirrors ClaudeCodeHarness _buildClaudeArgs (fixed flags, default model/effort).
  final args = [
    '--print',
    '--input-format',
    'stream-json',
    '--output-format',
    'stream-json',
    '--verbose',
    '--include-partial-messages',
    '--no-session-persistence',
    '--dangerously-skip-permissions',
  ];
  final p = await Process.start(exe, args, runInShell: useShell);
  final stderrBuf = StringBuffer();
  p.stderr.transform(utf8.decoder).listen(stderrBuf.write);

  // Harness message shape (ClaudeProtocolAdapter.buildTurnRequest), LF-terminated.
  p.stdin.add(
    utf8.encode(
      '${jsonEncode({
        'type': 'user',
        'message': {'role': 'user', 'content': 'Reply with exactly: pong'},
      })}\n',
    ),
  );
  await p.stdin.flush();
  await p.stdin.close();

  final raw = <int>[];
  final drained = p.stdout.listen(raw.addAll).asFuture<void>();
  final exit = await p.exitCode.timeout(
    const Duration(seconds: 180),
    onTimeout: () {
      p.kill();
      return -99;
    },
  );
  await drained.catchError((_) {});

  info('stdout bytes: ${raw.length}; line endings on the wire: ${endingStats(raw)}');
  final lines = await productionLineChain(Stream.value(raw)).toList();
  final decoded = <Map<String, dynamic>>[];
  var parseErrors = 0;
  for (final l in lines) {
    try {
      decoded.add(jsonDecode(l) as Map<String, dynamic>);
    } catch (_) {
      parseErrors++;
      info('unparseable line: ${trunc(l)}');
    }
  }

  check('claude: process exited 0 (-99 = probe timeout)', exit == 0);
  check('claude: all ${lines.length} stdout lines parse as JSON', parseErrors == 0 && lines.isNotEmpty);
  check('claude: system/init message seen', decoded.any((m) => m['type'] == 'system'));
  final result = decoded.lastWhere((m) => m['type'] == 'result', orElse: () => const {});
  check('claude: result message with is_error=false', result['is_error'] == false);
  final text = decoded.where((m) => m['type'] == 'assistant').map((m) => jsonEncode(m['message'] ?? '')).join(' ');
  info('assistant said pong: ${text.toLowerCase().contains('pong')} (informational)');
  if (exit != 0 && stderrBuf.isNotEmpty) {
    info('stderr: ${trunc(stderrBuf.toString(), 600)}');
  }
}

// --- codex: bidirectional JSON-RPC over stdio via app-server ---

Future<void> probeCodex() async {
  stdout.writeln('--- codex app-server JSON-RPC probe ---');
  final (exe, useShell) = await resolveExe('codex');
  info('executable: $exe${useShell ? ' (non-exe shim, spawning via shell)' : ''}');
  final ver = await Process.run(exe, ['--version'], runInShell: useShell);
  info('version: ${(ver.stdout as String).trim()}');

  final p = await Process.start(exe, ['app-server'], runInShell: useShell);
  final stderrBuf = StringBuffer();
  p.stderr.transform(utf8.decoder).listen(stderrBuf.write);

  final raw = <int>[];
  final out = p.stdout.asBroadcastStream();
  out.listen(raw.addAll);
  var parseErrors = 0;
  final messages = StreamIterator(
    productionLineChain(out).map((l) {
      try {
        return jsonDecode(l) as Map<String, dynamic>;
      } catch (_) {
        parseErrors++;
        info('unparseable line: ${trunc(l)}');
        return const <String, dynamic>{};
      }
    }),
  );

  void send(Map<String, dynamic> msg) {
    final s = jsonEncode(msg);
    info('>> ${trunc(s)}');
    p.stdin.add(utf8.encode('$s\n')); // harness writes LF-terminated JSON lines
  }

  // Pumps incoming messages (logging each) until one matches, or times out.
  Future<Map<String, dynamic>?> waitFor(
    bool Function(Map<String, dynamic>) pred, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    while (true) {
      final hasNext = await messages.moveNext().timeout(timeout, onTimeout: () => false);
      if (!hasNext) return null;
      final m = messages.current;
      info('<< ${trunc(jsonEncode(m))}');
      if (pred(m)) return m;
    }
  }

  // Sequence mirrors CodexHarness: initialize -> initialized -> thread/start -> turn/start.
  send({
    'id': 1,
    'method': 'initialize',
    'params': {
      'clientInfo': {'name': 'dartclaw-s0b-probe', 'version': '0.0.0'},
    },
  });
  final initResp = await waitFor((m) => m['id'] == 1);
  check('codex: initialize response received', initResp != null && initResp['error'] == null);

  send({'method': 'initialized', 'params': {}});

  send({'id': 2, 'method': 'thread/start', 'params': {}});
  final threadResp = await waitFor((m) => m['id'] == 2);
  check('codex: thread/start response received', threadResp != null && threadResp['error'] == null);
  final result = (threadResp?['result'] as Map?) ?? const {};
  final threadId = result['threadId'] ?? (result['thread'] as Map?)?['id'];
  info('threadId: $threadId');

  send({
    'id': 3,
    'method': 'turn/start',
    'params': {
      'input': [
        {'type': 'text', 'text': 'Reply with exactly: pong'},
      ],
      'threadId': ?threadId,
      'approvalPolicy': 'never',
      // turn/start expects camelCase sandboxPolicy variants (readOnly,
      // workspaceWrite, dangerFullAccess, externalSandbox) — NOT the kebab-case
      // form thread/start uses. Mirrors dartclaw_core codex_harness.dart:366.
      'sandboxPolicy': {'type': 'readOnly'},
    },
  });
  final turnEnd = await waitFor(
    (m) => m['method'] == 'turn/completed' || m['method'] == 'turn/failed' || (m['id'] == 3 && m['error'] != null),
    timeout: const Duration(seconds: 180),
  );
  check('codex: turn completed (not failed/timeout)', turnEnd != null && turnEnd['method'] == 'turn/completed');
  check('codex: all stdout lines parsed as JSON', parseErrors == 0);

  p.kill();
  await p.exitCode.timeout(const Duration(seconds: 10), onTimeout: () => -1);
  info('stdout bytes: ${raw.length}; line endings on the wire: ${endingStats(raw)}');
  if (stderrBuf.isNotEmpty) {
    info('stderr: ${trunc(stderrBuf.toString(), 600)}');
  }
}

Future<void> main(List<String> args) async {
  final what = args.isEmpty ? 'all' : args.first;
  stdout.writeln('S0b step 2 probe — native-Windows provider stdio');
  stdout.writeln(
    'arch: ${Platform.environment['PROCESSOR_ARCHITECTURE']}; '
    'OS: ${Platform.operatingSystemVersion.trim()}; dart: ${Platform.version}',
  );

  if (what == 'claude' || what == 'all') {
    try {
      await probeClaude();
    } catch (e) {
      check('claude probe ran to completion', false);
      info('error: $e');
    }
  }
  if (what == 'codex' || what == 'all') {
    try {
      await probeCodex();
    } catch (e) {
      check('codex probe ran to completion', false);
      info('error: $e');
    }
  }

  stdout.writeln(failures == 0 ? 'S0B2_PROBE_OK' : 'S0B2_PROBE_FAILED ($failures failures)');
  exit(failures == 0 ? 0 : 1);
}
