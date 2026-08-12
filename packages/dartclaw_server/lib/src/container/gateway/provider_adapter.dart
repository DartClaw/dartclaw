import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_bridge/dartclaw_bridge.dart';
import 'package:logging/logging.dart';

import 'gateway_models.dart';

/// What the gateway needs from a provider surface: it answers requests and owns
/// an upstream client it must release.
abstract interface class ProviderMediator implements GatewaySurfaceHandler {
  /// Why this adapter cannot mediate for a container right now, or `null` when
  /// it can.
  ///
  /// Read at authority registration so an unusable provider configuration is
  /// refused before a container exists – not discovered mid-turn, by which
  /// point the execution has already been admitted on a promise the host
  /// cannot keep. The reason is surfaced to operators, so it must name the
  /// remedy without naming any credential.
  String? get unavailableReason;

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

  /// How an operator configures the host credential this adapter injects.
  String get credentialRemediation;

  @override
  String? get unavailableReason {
    final key = _apiKey();
    if (key != null && key.isNotEmpty) return null;
    return 'containerized "$providerId" has no host-held credential to mediate with. $credentialRemediation';
  }

  /// Applies the provider's authentication to a host-to-provider request.
  void authenticate(HttpClientRequest request, String apiKey);

  /// How many provider-side network-reaching tools [body] declares, in this
  /// adapter's own protocol shape.
  ///
  /// These execute at the provider rather than in the container, so
  /// `network:none` cannot contain them and any containerized execution must be
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
    // Every container profile gets this check: `network:none` is applied to all
    // of them, so the provider pipe is the only egress any of them has.
    if (request.principal.containerProfile != null) {
      final declared = countNetworkTools(_decodeBody(rawBody));
      if (declared > 0) {
        throw GatewayDenied(
          status: 403,
          reason: 'containerized execution declared $declared provider-side network tool(s)',
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

  /// Decodes a request body so its tool declarations can be counted.
  ///
  /// A body the host cannot read is refused rather than forwarded: the network
  /// tool check is the only thing standing between a container and provider-run
  /// egress, and an undecodable body would silently count zero.
  static Object? _decodeBody(List<int> body) {
    if (body.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(body));
    } on FormatException {
      throw const GatewayDenied(
        status: 400,
        reason: 'request body is not decodable JSON, so its provider-side tool declarations cannot be checked',
      );
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
  /// redirect the request, hop-by-hop headers the host re-derives, and any
  /// framing the host did not apply — the body is forwarded as the plain JSON
  /// the tool check read, so a declared encoding would describe other bytes.
  static const _droppedRequestHeaders = {
    'authorization',
    'content-encoding',
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

  /// OAuth and setup-token logins are deliberately absent here: neither has a
  /// mediation contract that keeps the login material on the host, so
  /// containerized Claude supports host-held API-key mediation only.
  @override
  String get credentialRemediation =>
      'Set ANTHROPIC_API_KEY on the host for container execution, or select execution: host for this agent – '
      'OAuth and setup-token authentication are supported for host execution only.';

  @override
  void authenticate(HttpClientRequest request, String apiKey) {
    request.headers.set('x-api-key', apiKey);
  }

  /// Messages declares provider-hosted remote MCP connectors in a top-level
  /// `mcp_servers` array, separate from the client tools in `tools`.
  @override
  int countNetworkTools(Object? body) {
    var declared = _countNetworkToolFamilies(body);
    if (body is Map<Object?, Object?>) {
      final connectors = body['mcp_servers'];
      if (connectors is List<Object?>) declared += connectors.length;
    }
    return declared;
  }
}

/// OpenAI Responses mediation for containerized Codex.
final class OpenAiResponsesAdapter extends ProviderAdapter {
  OpenAiResponsesAdapter({required super.apiKey, Uri? upstream, super.client, super.providerId = 'codex'})
    : super(upstream: upstream ?? defaultUpstream);

  static final Uri defaultUpstream = Uri.https('api.openai.com');

  @override
  Set<String> get allowedPaths => const {'/v1/responses'};

  @override
  String get credentialRemediation =>
      'Set OPENAI_API_KEY on the host for container execution, or select execution: host for this agent.';

  @override
  void authenticate(HttpClientRequest request, String apiKey) {
    request.headers.set('authorization', 'Bearer $apiKey');
  }

  /// Responses has no `mcp_servers` array: it declares provider-hosted remote
  /// MCP connectors as an ordinary `tools` entry of `type: mcp` carrying a
  /// `server_url`. The match is exact on `type` alone – a client's own bridge
  /// tools are named `mcp__<server>__<tool>` and must keep passing.
  @override
  int countNetworkTools(Object? body) => _countNetworkToolFamilies(body, extra: (tool) => tool['type'] == 'mcp');
}

/// Provider-side tool families that reach the network on the caller's behalf.
///
/// Matching is by prefix because both providers version these identifiers
/// (`web_search_20250305`).
///
/// Deliberately no `mcp` prefix: a client's *own* MCP tools serialize as
/// ordinary tool declarations named `mcp__<server>__<tool>` and execute in the
/// container against the scoped bridge, which is exactly what a restricted
/// execution is supposed to use. Provider-hosted remote connectors – the ones
/// that really are an egress path `network:none` cannot see – are shaped
/// differently per protocol and are counted by each adapter.
const _networkToolPrefixes = {'web_search', 'web_fetch', 'code_execution', 'code_interpreter'};

/// Counts entries in the top-level `tools` array that name a network-reaching
/// tool family, plus any an adapter's [extra] protocol-specific test accepts.
///
/// Both protocols declare server-side tools there, keyed by `type` (and, for
/// Anthropic, `name`).
int _countNetworkToolFamilies(Object? body, {bool Function(Map<Object?, Object?> tool)? extra}) {
  if (body is! Map<Object?, Object?>) return 0;
  final tools = body['tools'];
  if (tools is! List<Object?>) return 0;
  var declared = 0;
  for (final tool in tools) {
    if (tool is! Map<Object?, Object?>) continue;
    final namesFamily = const ['type', 'name'].any((field) {
      final value = tool[field];
      return value is String && _networkToolPrefixes.any(value.startsWith);
    });
    if (namesFamily || (extra?.call(tool) ?? false)) declared++;
  }
  return declared;
}
