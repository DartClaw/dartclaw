import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_bridge/dartclaw_bridge.dart';
import 'package:logging/logging.dart';

import 'gateway_models.dart';

/// What the gateway needs from a provider surface: it answers requests and owns
/// an upstream client it must release.
abstract interface class ProviderMediator implements GatewaySurfaceHandler {
  Future<void> dispose();
}

/// Host-side provider mediation for one container authority's provider pipe.
///
/// An adapter owns its upstream, its protocol, and its credential. A container
/// cannot name a destination, supply its own authentication, or reach anything
/// this adapter does not already know how to talk to — the request shape is the
/// only thing that crosses.
///
/// `base` on purpose: credential injection and header stripping happen in
/// [handle], and a subclass that replaced it would quietly reopen the boundary.
/// Subclasses supply protocol details, never request flow.
abstract base class ProviderAdapter implements ProviderMediator {
  ProviderAdapter({
    required this.providerId,
    required this.upstream,
    required String? Function() apiKey,
    HttpClient? client,
  }) : _apiKey = apiKey,
       _client = client ?? HttpClient();

  static final _log = Logger('ProviderAdapter');

  /// Provider whose containerized clients this adapter serves.
  final String providerId;

  /// Fixed upstream origin, pinned when the adapter is built.
  final Uri upstream;

  final String? Function() _apiKey;
  final HttpClient _client;

  @override
  BridgeSurface get surface => BridgeSurface.provider;

  /// Request paths this provider's protocol defines. Anything else is refused.
  Set<String> get allowedPaths;

  /// Applies the provider's authentication to a host-to-provider request.
  void authenticate(HttpClientRequest request, String apiKey);

  /// How many provider-side network-reaching tools [body] declares.
  ///
  /// These execute at the provider rather than in the container, so
  /// `network:none` cannot contain them and a restricted execution must be
  /// refused before the request leaves the host. Only the count is returned:
  /// the declarations are container-authored strings and must not reach a log
  /// or an audit entry.
  int countNetworkTools(Object? body);

  @override
  Future<GatewayResponse> handle(GatewayRequest request) async {
    final path = _pathOnly(request.path);
    if (request.method.toUpperCase() != 'POST' || !allowedPaths.contains(path)) {
      throw GatewayDenied(status: 404, reason: 'path is not part of the $providerId provider surface');
    }

    final key = _apiKey();
    if (key == null || key.isEmpty) {
      throw GatewayDenied(status: 502, reason: 'no host credential is configured for provider "$providerId"');
    }

    final rawBody = await _collect(request);
    if (request.principal.isRestricted) {
      final declared = countNetworkTools(_tryDecode(rawBody));
      if (declared > 0) {
        throw GatewayDenied(
          status: 403,
          reason: 'restricted execution declared $declared provider-side network tool(s)',
        );
      }
    }

    final target = upstream.replace(path: path, query: _queryOnly(request.path));
    final outbound = await _client.openUrl(request.method, target);
    outbound.followRedirects = false;
    _copyHeaders(request.headers, outbound);
    // Injection happens last and unconditionally: a client-supplied credential
    // was already dropped by _copyHeaders, so nothing it sent can survive here.
    authenticate(outbound, key);
    outbound.contentLength = rawBody.length;
    outbound.add(rawBody);

    final response = await outbound.close();
    _log.fine('Gateway $providerId ${request.method} $path -> ${response.statusCode}');
    return GatewayResponse(status: response.statusCode, headers: _responseHeaders(response), body: response);
  }

  @override
  Future<void> dispose() async => _client.close(force: true);

  Future<List<int>> _collect(GatewayRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request.body) {
      bytes.addAll(chunk);
    }
    return bytes;
  }

  void _copyHeaders(Map<String, List<String>> headers, HttpClientRequest outbound) {
    for (final entry in headers.entries) {
      if (_droppedRequestHeaders.contains(entry.key)) continue;
      for (final value in entry.value) {
        outbound.headers.add(entry.key, value);
      }
    }
  }

  Map<String, List<String>> _responseHeaders(HttpClientResponse response) {
    final headers = <String, List<String>>{};
    response.headers.forEach((name, values) {
      if (_droppedResponseHeaders.contains(name.toLowerCase())) return;
      headers[name] = values;
    });
    return headers;
  }

  static Object? _tryDecode(List<int> body) {
    if (body.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(body));
    } on FormatException {
      return null;
    }
  }

  static String _pathOnly(String target) {
    final separator = target.indexOf('?');
    return separator == -1 ? target : target.substring(0, separator);
  }

  static String? _queryOnly(String target) {
    final separator = target.indexOf('?');
    return separator == -1 ? null : target.substring(separator + 1);
  }

  /// Client-supplied headers that must never reach the provider: credentials
  /// the container should not be able to choose, routing headers that could
  /// redirect the request, and hop-by-hop headers the host re-derives.
  static const _droppedRequestHeaders = {
    'authorization',
    'x-api-key',
    'openai-api-key',
    'api-key',
    'proxy-authorization',
    'cookie',
    'host',
    'connection',
    'keep-alive',
    'transfer-encoding',
    'upgrade',
    'te',
    'trailer',
    'content-length',
    'forwarded',
    'x-forwarded-host',
    'x-forwarded-for',
    'x-forwarded-proto',
  };

  static const _droppedResponseHeaders = {
    // The client decoded the body on the way in (`autoUncompress`), so keeping
    // the encoding headers would describe bytes that no longer exist.
    'content-encoding',
    'content-md5',
    'connection',
    'keep-alive',
    'transfer-encoding',
    'upgrade',
    'te',
    'trailer',
    'content-length',
    'set-cookie',
  };
}

/// Anthropic Messages mediation for containerized Claude.
final class AnthropicMessagesAdapter extends ProviderAdapter {
  AnthropicMessagesAdapter({required super.apiKey, Uri? upstream, super.client, super.providerId = 'claude'})
    : super(upstream: upstream ?? defaultUpstream);

  static final Uri defaultUpstream = Uri.https('api.anthropic.com');

  @override
  Set<String> get allowedPaths => const {'/v1/messages', '/v1/messages/count_tokens'};

  @override
  void authenticate(HttpClientRequest request, String apiKey) {
    request.headers.set('x-api-key', apiKey);
  }

  @override
  int countNetworkTools(Object? body) => _countNetworkTools(body);
}

/// OpenAI Responses mediation for containerized Codex.
final class OpenAiResponsesAdapter extends ProviderAdapter {
  OpenAiResponsesAdapter({required super.apiKey, Uri? upstream, super.client, super.providerId = 'codex'})
    : super(upstream: upstream ?? defaultUpstream);

  static final Uri defaultUpstream = Uri.https('api.openai.com');

  @override
  Set<String> get allowedPaths => const {'/v1/responses'};

  @override
  void authenticate(HttpClientRequest request, String apiKey) {
    request.headers.set('authorization', 'Bearer $apiKey');
  }

  @override
  int countNetworkTools(Object? body) => _countNetworkTools(body);
}

/// Provider-side tool families that reach the network on the caller's behalf.
///
/// Matching is by prefix because both providers version these identifiers
/// (`web_search_20250305`). Remote-connector declarations are counted too: a
/// provider-hosted MCP connector is an egress path that `network:none` cannot
/// see, let alone contain.
const _networkToolPrefixes = {'web_search', 'web_fetch', 'mcp', 'code_execution', 'code_interpreter'};

/// Counts the provider-side network-reaching tools a request declares.
///
/// Both protocols declare server-side tools in a top-level `tools` array whose
/// entries carry a `type` (and, for Anthropic, a `name`); Anthropic also takes
/// remote connectors in a top-level `mcp_servers` array.
int _countNetworkTools(Object? body) {
  if (body is! Map) return 0;
  var declared = 0;
  final connectors = body['mcp_servers'];
  if (connectors is List) declared += connectors.length;
  final tools = body['tools'];
  if (tools is! List) return declared;
  for (final tool in tools) {
    if (tool is! Map) continue;
    final matches = const ['type', 'name'].any((field) {
      final value = tool[field];
      return value is String && _networkToolPrefixes.any(value.startsWith);
    });
    if (matches) declared++;
  }
  return declared;
}
