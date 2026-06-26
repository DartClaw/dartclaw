import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_security/dartclaw_security.dart';

import 'json_rpc_utils.dart';
import 'outbound_mcp_errors.dart';
import 'outbound_mcp_transport.dart';

typedef OutboundMcpProcessStarter =
    Future<Process> Function(String executable, List<String> arguments, {Map<String, String> environment});

final class StdioMcpTransport implements OutboundMcpTransport {
  final Process _process;
  final StreamSubscription<List<int>> _stdoutSubscription;
  final StreamSubscription<List<int>> _stderrSubscription;
  var _nextId = 1;
  _PendingRequest? _pending;
  var _closed = false;
  String? _lastStderr;

  StdioMcpTransport._(this._process, this._stdoutSubscription, this._stderrSubscription);

  static Future<StdioMcpTransport> start(
    String command, {
    OutboundMcpProcessStarter processStarter = _defaultProcessStarter,
    Map<String, String> environment = const {},
  }) async {
    final parts = _splitCommand(command);
    if (parts.isEmpty) {
      throw const OutboundMcpException('invalid_command', 'Stdio MCP command is empty');
    }
    final process = await processStarter(parts.first, parts.skip(1).toList(), environment: environment);
    late StdioMcpTransport transport;
    // ignore: cancel_subscriptions - ownership transfers to StdioMcpTransport.close().
    final stdoutSubscription = process.stdout.listen((chunk) {
      transport._handleStdoutChunk(chunk);
    });
    // ignore: cancel_subscriptions - ownership transfers to StdioMcpTransport.close().
    final stderrSubscription = process.stderr.listen((chunk) {
      transport._lastStderr = utf8.decode(chunk, allowMalformed: true).trim();
    });
    transport = StdioMcpTransport._(process, stdoutSubscription, stderrSubscription);
    unawaited(
      process.exitCode.then((code) {
        transport._closed = true;
        transport._completePendingError(
          OutboundMcpException('connection_closed', 'Stdio MCP process exited with code $code'),
        );
      }),
    );
    return transport;
  }

  @override
  Future<Map<String, dynamic>> sendRequest(
    String method,
    Map<String, dynamic> params, {
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    if (_closed) {
      throw OutboundMcpException('connection_closed', _lastStderr ?? 'Stdio MCP process is closed');
    }
    if (_pending != null) {
      throw const OutboundMcpException('busy', 'Stdio MCP transport already has an in-flight request');
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending = _PendingRequest(id: id, maxResponseBytes: maxResponseBytes, completer: completer);
    _process.stdin.writeln(encodeJsonRpcRequest(id, method, params));
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending = null;
        throw OutboundMcpException('timeout', 'MCP request "$method" timed out');
      },
    );
  }

  @override
  Future<void> sendNotification(
    String method,
    Map<String, dynamic> params, {
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    if (_closed) {
      throw OutboundMcpException('connection_closed', _lastStderr ?? 'Stdio MCP process is closed');
    }
    if (_pending != null) {
      throw const OutboundMcpException('busy', 'Stdio MCP transport already has an in-flight request');
    }
    _process.stdin.writeln(encodeJsonRpcNotification(method, params));
  }

  @override
  Future<bool> ping({required Duration timeout, required int maxResponseBytes}) async {
    try {
      await sendRequest('tools/list', const {}, timeout: timeout, maxResponseBytes: maxResponseBytes);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _stdoutSubscription.cancel();
    await _stderrSubscription.cancel();
    _process.kill();
    await _process.stdin.close();
  }

  final List<int> _stdoutBuffer = [];

  void _handleStdoutChunk(List<int> chunk) {
    final pending = _pending;
    if (pending == null) return;
    _stdoutBuffer.addAll(chunk);
    if (_stdoutBuffer.length > pending.maxResponseBytes) {
      _stdoutBuffer.clear();
      _pending = null;
      pending.completer.completeError(
        const OutboundMcpException('response_too_large', 'MCP response exceeded receive size limit'),
      );
      return;
    }
    var newlineIndex = _stdoutBuffer.indexOf(10);
    while (newlineIndex != -1) {
      final lineBytes = _stdoutBuffer.sublist(0, newlineIndex);
      _stdoutBuffer.removeRange(0, newlineIndex + 1);
      _handleLineBytes(lineBytes);
      newlineIndex = _stdoutBuffer.indexOf(10);
    }
  }

  void _handleLineBytes(List<int> lineBytes) {
    final pending = _pending;
    if (pending == null) return;
    try {
      final line = utf8.decode(lineBytes);
      if (isJsonRpcServerMessage(line, maxResponseBytes: pending.maxResponseBytes)) {
        return;
      }
      _pending = null;
      pending.completer.complete(
        decodeJsonRpcResponse(line, expectedId: pending.id, maxResponseBytes: pending.maxResponseBytes),
      );
    } catch (error) {
      _pending = null;
      pending.completer.completeError(error);
    }
  }

  void _completePendingError(OutboundMcpException error) {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.completeError(error);
    }
  }
}

final class _PendingRequest {
  final int id;
  final int maxResponseBytes;
  final Completer<Map<String, dynamic>> completer;

  const _PendingRequest({required this.id, required this.maxResponseBytes, required this.completer});
}

Future<Process> _defaultProcessStarter(
  String executable,
  List<String> arguments, {
  Map<String, String> environment = const {},
}) {
  return SafeProcess.start(executable, arguments, env: EnvPolicy.minimal(extraEnvironment: environment));
}

List<String> _splitCommand(String command) {
  final parts = <String>[];
  final current = StringBuffer();
  String? quote;
  var escaped = false;

  for (var i = 0; i < command.length; i++) {
    final char = command[i];
    if (escaped) {
      current.write(char);
      escaped = false;
      continue;
    }
    if (char == r'\') {
      escaped = true;
      continue;
    }
    if (quote != null) {
      if (char == quote) {
        quote = null;
      } else {
        current.write(char);
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      continue;
    }
    if (char.trim().isEmpty) {
      if (current.isNotEmpty) {
        parts.add(current.toString());
        current.clear();
      }
      continue;
    }
    current.write(char);
  }

  if (escaped) {
    current.write(r'\');
  }
  if (quote != null) {
    throw const OutboundMcpException('invalid_command', 'Stdio MCP command has an unterminated quoted argument');
  }
  if (current.isNotEmpty) {
    parts.add(current.toString());
  }
  return parts;
}
