import 'dart:async';
import 'dart:convert';

import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:stream_channel/stream_channel.dart';

import '../bridge/ndjson_channel.dart';
import 'acp_errors.dart';
import 'acp_reverse_call_handlers.dart';

/// Minimal ACP stdio JSON-RPC client.
final class AcpClient {
  final json_rpc.Peer _peer;
  final Future<void> _listenFuture;
  final bool _reverseCallsEnabled;

  AcpClient._(this._peer, this._listenFuture, {required bool reverseCallsEnabled})
    : _reverseCallsEnabled = reverseCallsEnabled;

  /// Creates and starts an ACP client over newline-delimited stdio JSON-RPC.
  factory AcpClient(
    Stream<List<int>> stdout,
    StreamSink<List<int>> stdin, {
    void Function(Map<String, dynamic> update)? onSessionUpdate,
    void Function(String line)? onMalformedLine,
    AcpReverseCallHandlers? reverseCallHandlers,
  }) {
    return AcpClient._start(
      ndjsonChannel(stdout, stdin),
      onSessionUpdate: onSessionUpdate,
      onMalformedLine: onMalformedLine,
      reverseCallHandlers: reverseCallHandlers,
    );
  }

  /// Creates and starts an ACP client over a string channel.
  factory AcpClient.fromChannel(
    StreamChannel<String> channel, {
    void Function(Map<String, dynamic> update)? onSessionUpdate,
    void Function(String line)? onMalformedLine,
    AcpReverseCallHandlers? reverseCallHandlers,
  }) {
    return AcpClient._start(
      channel,
      onSessionUpdate: onSessionUpdate,
      onMalformedLine: onMalformedLine,
      reverseCallHandlers: reverseCallHandlers,
    );
  }

  factory AcpClient._start(
    StreamChannel<String> channel, {
    void Function(Map<String, dynamic> update)? onSessionUpdate,
    void Function(String line)? onMalformedLine,
    AcpReverseCallHandlers? reverseCallHandlers,
  }) {
    final filteredChannel = _filterMalformedJson(channel, onMalformedLine);
    final peer = json_rpc.Peer(filteredChannel);
    _registerSessionUpdate(peer, onSessionUpdate);
    if (reverseCallHandlers == null) {
      _registerFailClosedReverseCalls(peer);
    } else {
      _registerReverseCalls(peer, reverseCallHandlers);
    }
    final listenFuture = peer.listen();
    return AcpClient._(peer, listenFuture, reverseCallsEnabled: reverseCallHandlers != null);
  }

  static StreamChannel<String> _filterMalformedJson(
    StreamChannel<String> channel,
    void Function(String line)? onMalformedLine,
  ) {
    return channel.changeStream((stream) {
      return stream.where((line) {
        try {
          final decoded = jsonDecode(line);
          return decoded is Map;
        } on FormatException {
          onMalformedLine?.call(line);
          return false;
        }
      });
    });
  }

  /// Performs ACP initialize with the currently supported host capability subset.
  Future<Map<String, dynamic>> initialize() async {
    final capabilities = _hostCapabilities();
    final result = await _sendMapRequest('initialize', {
      'protocolVersion': 1,
      'clientInfo': {'name': 'dartclaw', 'version': '0.18.0'},
      'capabilities': capabilities,
    });
    if (_authRequired(result)) {
      throw const AcpHarnessException(
        AcpHarnessErrorCode.authRequired,
        'ACP agent requires interactive authentication',
      );
    }
    return result;
  }

  /// Creates an ACP session and returns its ID.
  Future<String> createSession({required String cwd}) async {
    final result = await _sendMapRequest('session/new', {'cwd': cwd});
    return _stringField(result, const ['sessionId', 'session_id', 'id']) ?? 'default';
  }

  /// Sends a prompt and returns text plus optional token metadata.
  Future<AcpPromptResult> prompt({required String sessionId, required String text}) async {
    final result = await _sendMapRequest('session/prompt', {'sessionId': sessionId, 'prompt': text});
    if (_authRequired(result)) {
      throw const AcpHarnessException(
        AcpHarnessErrorCode.authRequired,
        'ACP agent requires interactive authentication',
      );
    }
    return AcpPromptResult(
      text: _stringField(result, const ['text', 'content', 'response']) ?? '',
      inputTokens: _intField(result, const ['input_tokens', 'inputTokens']),
      outputTokens: _intField(result, const ['output_tokens', 'outputTokens']),
      cacheReadTokens: _intField(result, const ['cache_read_tokens', 'cacheReadTokens']),
      cacheWriteTokens: _intField(result, const ['cache_write_tokens', 'cacheWriteTokens']),
      stopReason: _stringField(result, const ['stop_reason', 'stopReason']) ?? 'completed',
      sessionTitle: _stringField(result, const ['session_title', 'sessionTitle', 'title']),
      metadata: _metadata(result),
    );
  }

  /// Requests cancellation for an active ACP session.
  Future<void> cancel(String sessionId) async {
    await _peer.sendRequest('session/cancel', {'sessionId': sessionId});
  }

  /// Closes an ACP session.
  Future<void> closeSession(String sessionId) async {
    await _peer.sendRequest('session/close', {'sessionId': sessionId});
  }

  /// Closes the JSON-RPC peer.
  Future<void> close() async {
    if (!_peer.isClosed) {
      await _peer.close();
    }
    try {
      await _listenFuture;
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _sendMapRequest(String method, Map<String, Object?> params) async {
    final result = await _peer.sendRequest(method, params);
    if (result is Map<String, dynamic>) return result;
    if (result is Map) return Map<String, dynamic>.from(result);
    return const <String, dynamic>{};
  }

  static void _registerSessionUpdate(json_rpc.Peer peer, void Function(Map<String, dynamic> update)? onSessionUpdate) {
    peer.registerMethod('session/update', (params) {
      final value = params.value;
      if (value is Map) {
        onSessionUpdate?.call(Map<String, dynamic>.from(value));
      } else {
        onSessionUpdate?.call(const <String, dynamic>{});
      }
      return const <String, dynamic>{};
    });
  }

  static void _registerFailClosedReverseCalls(json_rpc.Peer peer) {
    for (final method in [
      'fs/read_text_file',
      'fs/write_text_file',
      'terminal/create',
      'terminal/output',
      'terminal/wait_for_exit',
      'terminal/kill',
      'terminal/release',
      'session/request_permission',
    ]) {
      peer.registerMethod(method, (_) {
        throw json_rpc.RpcException(-32600, 'ACP reverse-call "$method" is unsupported by this host');
      });
    }
  }

  static void _registerReverseCalls(json_rpc.Peer peer, AcpReverseCallHandlers handlers) {
    peer
      ..registerMethod('fs/read_text_file', handlers.readTextFile)
      ..registerMethod('fs/write_text_file', handlers.writeTextFile)
      ..registerMethod('terminal/create', handlers.createTerminal)
      ..registerMethod('terminal/output', handlers.terminalOutput)
      ..registerMethod('terminal/wait_for_exit', handlers.waitForExit)
      ..registerMethod('terminal/kill', handlers.killTerminal)
      ..registerMethod('terminal/release', handlers.releaseTerminal)
      ..registerMethod('session/request_permission', handlers.requestPermission);
  }

  Map<String, dynamic> _hostCapabilities() {
    return {
      'fs': {'readTextFile': _reverseCallsEnabled, 'writeTextFile': _reverseCallsEnabled},
      'terminal': {'create': _reverseCallsEnabled},
    };
  }

  static bool _authRequired(Map<String, dynamic> result) {
    if (result['authRequired'] == true || result['auth_required'] == true) return true;
    final auth = result['auth'];
    if (auth is Map) {
      final status = auth['status']?.toString().toLowerCase();
      return auth['required'] == true || status == 'required' || status == 'needs_authentication';
    }
    final authentication = result['authentication'];
    if (authentication is Map) {
      final status = authentication['status']?.toString().toLowerCase();
      return authentication['required'] == true || status == 'required' || status == 'needs_authentication';
    }
    return false;
  }

  static String? _stringField(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return null;
  }

  static int? _intField(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
    }
    return null;
  }

  static Map<String, dynamic> _metadata(Map<String, dynamic> result) {
    final metadata = <String, dynamic>{};
    for (final key in const ['sessionTitle', 'session_title', 'title', 'metadata']) {
      final value = result[key];
      if (value is Map) {
        metadata.addAll(Map<String, dynamic>.from(value));
      }
    }
    return metadata;
  }
}

/// Minimal prompt result returned by [AcpClient.prompt].
final class AcpPromptResult {
  /// Response text.
  final String text;

  /// Input token count, when reported.
  final int? inputTokens;

  /// Output token count, when reported.
  final int? outputTokens;

  /// Cache-read token count, when reported.
  final int? cacheReadTokens;

  /// Cache-write token count, when reported.
  final int? cacheWriteTokens;

  /// Stop reason.
  final String stopReason;

  /// Session title metadata, when reported.
  final String? sessionTitle;

  /// Additional ACP metadata that maps to existing host surfaces when present.
  final Map<String, dynamic> metadata;

  /// Creates a prompt result.
  const AcpPromptResult({
    required this.text,
    this.inputTokens,
    this.outputTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    required this.stopReason,
    this.sessionTitle,
    this.metadata = const <String, dynamic>{},
  });
}
