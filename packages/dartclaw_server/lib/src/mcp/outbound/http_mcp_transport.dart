import 'dart:async';
import 'dart:convert';
import 'dart:io' show InternetAddress;

import 'package:dartclaw_config/dartclaw_config.dart' show McpNetworkClass;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../web_fetch_tool.dart';
import 'json_rpc_utils.dart';
import 'outbound_mcp_errors.dart';
import 'outbound_mcp_transport.dart';

final class HttpMcpTransport implements OutboundMcpTransport {
  static const _protocolVersion = '2025-03-26';
  static final _log = Logger('HttpMcpTransport');

  final Uri _url;
  final http.Client _client;
  final Set<String> _allowedRedirectHosts;
  final bool _requireTls;
  final McpNetworkClass _networkClass;
  final String? _credentialSecret;
  var _nextId = 1;
  String? _sessionId;
  String? _negotiatedProtocolVersion;

  HttpMcpTransport(
    String url, {
    http.Client? client,
    Iterable<String>? allowedRedirectHosts,
    bool requireTls = false,
    McpNetworkClass networkClass = McpNetworkClass.local,
    String? credentialSecret,
  }) : _url = Uri.parse(url),
       _client = client ?? http.Client(),
       _allowedRedirectHosts = Set.unmodifiable(allowedRedirectHosts ?? const []),
       _requireTls = requireTls,
       _networkClass = networkClass,
       _credentialSecret = credentialSecret {
    if (_credentialSecret != null && _url.scheme != 'https') {
      _log.warning(
        'MCP credential for "${_url.host}" will be sent over plain HTTP - '
        'cleartext bearer token to an unauthenticated endpoint',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> sendRequest(
    String method,
    Map<String, dynamic> params, {
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    final deadline = Stopwatch()..start();
    _verifyTls();
    await _verifyNetworkPolicy(_url);
    final id = _nextId++;
    final request = http.Request('POST', _url)
      ..headers.addAll(_headers(includeProtocolVersion: method != 'initialize'))
      ..body = encodeJsonRpcRequest(id, method, params)
      ..followRedirects = false;
    final response = await _client
        .send(request)
        .timeout(
          timeout,
          onTimeout: () {
            throw OutboundMcpException('timeout', 'MCP HTTP request "$method" timed out');
          },
        );
    _rejectUnsafeRedirect(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OutboundMcpException('http_error', 'MCP HTTP server returned ${response.statusCode}');
    }
    _captureSession(response);
    final remainingTimeout = _remainingTimeout(timeout, deadline, 'MCP HTTP request "$method" timed out');
    if (response.headers['content-type']?.toLowerCase().contains('text/event-stream') ?? false) {
      final result = await _decodeSseStream(
        response.stream,
        expectedId: id,
        timeout: remainingTimeout,
        maxResponseBytes: maxResponseBytes,
      );
      if (method == 'initialize') {
        _captureProtocolVersion(result);
      }
      return result;
    }
    final bytes = await _readStreamBytes(
      response.stream,
      timeout: remainingTimeout,
      maxResponseBytes: maxResponseBytes,
    );
    final body = utf8.decode(bytes);
    final result = decodeJsonRpcResponse(body, expectedId: id, maxResponseBytes: maxResponseBytes);
    if (method == 'initialize') {
      _captureProtocolVersion(result);
    }
    return result;
  }

  @override
  Future<void> sendNotification(
    String method,
    Map<String, dynamic> params, {
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    final deadline = Stopwatch()..start();
    _verifyTls();
    await _verifyNetworkPolicy(_url);
    final request = http.Request('POST', _url)
      ..headers.addAll(_headers(includeProtocolVersion: true))
      ..body = encodeJsonRpcNotification(method, params)
      ..followRedirects = false;
    final response = await _client
        .send(request)
        .timeout(
          timeout,
          onTimeout: () {
            throw OutboundMcpException('timeout', 'MCP HTTP notification "$method" timed out');
          },
        );
    _rejectUnsafeRedirect(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OutboundMcpException('http_error', 'MCP HTTP server returned ${response.statusCode}');
    }
    _captureSession(response);
    await _readStreamBytes(
      response.stream,
      timeout: _remainingTimeout(timeout, deadline, 'MCP HTTP notification "$method" timed out'),
      maxResponseBytes: maxResponseBytes,
    );
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
    _client.close();
  }

  Map<String, String> _headers({required bool includeProtocolVersion}) {
    return {
      'content-type': 'application/json',
      'accept': 'application/json, text/event-stream',
      if (_credentialSecret case final secret?) 'authorization': 'Bearer $secret',
      'mcp-session-id': ?_sessionId,
      if (includeProtocolVersion) 'mcp-protocol-version': _negotiatedProtocolVersion ?? _protocolVersion,
    };
  }

  void _captureSession(http.StreamedResponse response) {
    _sessionId = response.headers['mcp-session-id'] ?? _sessionId;
  }

  void _captureProtocolVersion(Map<String, dynamic> result) {
    final protocolVersion = result['protocolVersion'];
    _negotiatedProtocolVersion = protocolVersion is String ? protocolVersion : _protocolVersion;
  }

  void _verifyTls() {
    if (!_requireTls || _url.scheme == 'https') return;
    if (_isLoopbackHost(_url.host)) return;
    throw OutboundMcpException('tls_required', 'MCP HTTP egress requires HTTPS for ${_url.host}');
  }

  // Loopback traffic never leaves the host, so TLS adds nothing there. Literal
  // hosts only – no DNS resolution – so a name that merely resolves to
  // 127.0.0.1 stays rejected (fails closed against rebinding).
  static bool _isLoopbackHost(String host) {
    if (host.toLowerCase() == 'localhost') return true;
    return InternetAddress.tryParse(host)?.isLoopback ?? false;
  }

  void _rejectUnsafeRedirect(http.StreamedResponse response) {
    if (response.statusCode < 300 || response.statusCode >= 400) return;
    final location = response.headers['location'];
    if (location == null) {
      throw const OutboundMcpException('redirect_denied', 'MCP HTTP redirect missing Location header');
    }
    final redirectUri = _url.resolve(location);
    if (_networkClass == McpNetworkClass.public) {
      throw const OutboundMcpException('redirect_denied', 'MCP HTTP redirects are not followed');
    }
    final allowedHosts = _allowedRedirectHosts.isEmpty ? {_url.host} : _allowedRedirectHosts;
    if (!allowedHosts.contains(redirectUri.host)) {
      throw OutboundMcpException(
        'redirect_denied',
        'MCP HTTP redirect denied: host "${redirectUri.host}" is not allowlisted',
      );
    }
    throw const OutboundMcpException('redirect_denied', 'MCP HTTP redirects are not followed');
  }

  Future<void> _verifyNetworkPolicy(Uri uri) async {
    if (_networkClass != McpNetworkClass.public) return;
    final error = await WebFetchTool.checkSsrfPolicy(uri);
    if (error != null) {
      throw OutboundMcpException('network_denied', 'MCP HTTP egress denied by network_class=public: $error');
    }
  }
}

Duration _remainingTimeout(Duration timeout, Stopwatch deadline, String message) {
  final remaining = timeout - deadline.elapsed;
  if (remaining <= Duration.zero) {
    throw OutboundMcpException('timeout', message);
  }
  return remaining;
}

Future<List<int>> _readStreamBytes(
  Stream<List<int>> stream, {
  required Duration timeout,
  required int maxResponseBytes,
}) {
  final completer = Completer<List<int>>();
  final bytes = <int>[];
  late StreamSubscription<List<int>> subscription;
  late Timer deadline;

  void fail(Object error) {
    if (completer.isCompleted) return;
    deadline.cancel();
    unawaited(subscription.cancel());
    completer.completeError(error);
  }

  deadline = Timer(timeout, () {
    fail(const OutboundMcpException('timeout', 'MCP HTTP response timed out'));
  });
  subscription = stream.listen(
    (chunk) {
      bytes.addAll(chunk);
      if (bytes.length > maxResponseBytes) {
        fail(const OutboundMcpException('response_too_large', 'MCP response exceeded receive size limit'));
      }
    },
    onError: fail,
    onDone: () {
      if (completer.isCompleted) return;
      deadline.cancel();
      completer.complete(bytes);
    },
  );
  return completer.future;
}

Future<Map<String, dynamic>> _decodeSseStream(
  Stream<List<int>> stream, {
  required int expectedId,
  required Duration timeout,
  required int maxResponseBytes,
}) async {
  final completer = Completer<Map<String, dynamic>>();
  var receivedBytes = 0;
  var buffer = '';
  late StreamSubscription<List<int>> subscription;
  late Timer deadline;

  void fail(Object error) {
    if (completer.isCompleted) return;
    deadline.cancel();
    unawaited(subscription.cancel());
    completer.completeError(error);
  }

  void complete(Map<String, dynamic> result) {
    if (completer.isCompleted) return;
    deadline.cancel();
    unawaited(subscription.cancel());
    completer.complete(result);
  }

  deadline = Timer(timeout, () {
    fail(const OutboundMcpException('timeout', 'MCP SSE response timed out'));
  });
  subscription = stream.listen(
    (chunk) {
      try {
        receivedBytes += chunk.length;
        if (receivedBytes > maxResponseBytes) {
          fail(const OutboundMcpException('response_too_large', 'MCP response exceeded receive size limit'));
          return;
        }
        buffer += utf8.decode(chunk, allowMalformed: true).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
        var frameEnd = buffer.indexOf('\n\n');
        while (frameEnd != -1) {
          final frame = buffer.substring(0, frameEnd);
          buffer = buffer.substring(frameEnd + 2);
          final data = _sseFrameData(frame);
          if (data != null) {
            if (isJsonRpcServerMessage(data, maxResponseBytes: maxResponseBytes)) {
              frameEnd = buffer.indexOf('\n\n');
              continue;
            }
            complete(decodeJsonRpcResponse(data, expectedId: expectedId, maxResponseBytes: maxResponseBytes));
            return;
          }
          frameEnd = buffer.indexOf('\n\n');
        }
      } catch (error) {
        fail(error);
      }
    },
    onError: fail,
    onDone: () {
      fail(const OutboundMcpException('malformed_response', 'MCP SSE response did not contain a JSON-RPC response'));
    },
  );
  return completer.future;
}

String? _sseFrameData(String frame) {
  final dataLines = <String>[];
  for (final line in frame.split('\n')) {
    if (line.startsWith('data:')) {
      dataLines.add(line.substring(5).trimLeft());
    }
  }
  final data = dataLines.join('\n').trim();
  return data.isEmpty ? null : data;
}
