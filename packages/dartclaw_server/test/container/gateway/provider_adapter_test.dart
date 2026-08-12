import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

/// A sentinel that must appear only at the fake provider upstream.
const _hostCredential = 'sk-host-only-SENTINEL-2f9c';

void main() {
  late _FakeUpstream upstream;

  setUp(() async => upstream = await _FakeUpstream.start());
  tearDown(() async => upstream.close());

  group('AnthropicMessagesAdapter', () {
    test('injects the host credential and never lets it reach the caller', () async {
      final adapter = _anthropic(upstream);
      addTearDown(adapter.dispose);

      final response = await adapter.handle(_request(path: '/v1/messages', body: '{"model":"claude"}'));
      final body = await _read(response);

      expect(response.status, 200);
      expect(upstream.lastHeaders['x-api-key'], _hostCredential);
      expect(upstream.lastBody, '{"model":"claude"}');
      expect(body, isNot(contains(_hostCredential)));
      expect(jsonEncode(response.headers), isNot(contains(_hostCredential)));
    });

    test('strips a client-supplied credential instead of forwarding it', () async {
      final adapter = _anthropic(upstream);
      addTearDown(adapter.dispose);

      await adapter.handle(
        _request(
          path: '/v1/messages',
          body: '{}',
          headers: {
            'x-api-key': const ['sk-container-attempt'],
            'authorization': const ['Bearer sk-container-attempt'],
            'cookie': const ['session=abc'],
          },
        ),
      );

      expect(upstream.lastHeaders['x-api-key'], _hostCredential);
      expect(upstream.lastHeaders.containsKey('cookie'), isFalse);
      expect(upstream.lastHeaders['authorization'], isNull);
    });

    test('refuses a path outside the provider protocol', () async {
      final adapter = _anthropic(upstream);
      addTearDown(adapter.dispose);

      await expectLater(
        adapter.handle(_request(path: '/v1/files', body: '{}')),
        throwsA(isA<GatewayDenied>().having((e) => e.status, 'status', 404)),
      );
      expect(upstream.requestCount, 0, reason: 'the refusal must precede any outbound request');
    });

    test('refuses a method the provider protocol does not define', () async {
      final adapter = _anthropic(upstream);
      addTearDown(adapter.dispose);

      await expectLater(
        adapter.handle(_request(method: 'GET', path: '/v1/messages', body: '')),
        throwsA(isA<GatewayDenied>()),
      );
      expect(upstream.requestCount, 0);
    });

    test('drops the content encoding it already decoded', () async {
      final adapter = _anthropic(upstream);
      addTearDown(adapter.dispose);
      upstream.compressResponse = true;

      final response = await adapter.handle(_request(path: '/v1/messages', body: '{}'));
      final body = await _read(response);

      // The client gunzipped on the way in, so forwarding the encoding header
      // would describe bytes that no longer exist.
      expect(response.headers.keys.map((k) => k.toLowerCase()), isNot(contains('content-encoding')));
      expect(body, '{"ok":true}');
    });

    test('refuses a remote MCP connector for a restricted execution', () async {
      final adapter = _anthropic(upstream);
      addTearDown(adapter.dispose);

      await expectLater(
        adapter.handle(
          _request(
            path: '/v1/messages',
            profile: 'restricted',
            body: jsonEncode({
              'mcp_servers': [
                {'type': 'url', 'url': 'https://attacker.example/mcp'},
              ],
            }),
          ),
        ),
        throwsA(isA<GatewayDenied>().having((e) => e.status, 'status', 403)),
      );
      expect(upstream.requestCount, 0, reason: 'a provider-hosted connector is egress network:none cannot see');
    });

    test('keeps container-authored strings out of the denial reason', () async {
      final adapter = _anthropic(upstream);
      addTearDown(adapter.dispose);
      const injected = 'web_search_INJECTED_AUDIT_PAYLOAD';

      await expectLater(
        adapter.handle(
          _request(
            path: '/v1/messages',
            profile: 'restricted',
            body: jsonEncode({
              'tools': [
                {'type': injected},
              ],
            }),
          ),
        ),
        throwsA(
          isA<GatewayDenied>()
              .having((e) => e.reason, 'reason', isNot(contains(injected)))
              .having((e) => e.reason, 'reason', contains('1 provider-side network tool')),
        ),
      );
    });

    test('refuses provider-native web tools for a restricted execution', () async {
      final adapter = _anthropic(upstream);
      addTearDown(adapter.dispose);

      await expectLater(
        adapter.handle(
          _request(
            path: '/v1/messages',
            profile: 'restricted',
            body: jsonEncode({
              'model': 'claude',
              'tools': [
                {'type': 'web_search_20250305', 'name': 'web_search'},
              ],
            }),
          ),
        ),
        throwsA(
          isA<GatewayDenied>()
              .having((e) => e.status, 'status', 403)
              .having((e) => e.reason, 'reason', contains('provider-side network tool')),
        ),
      );
      expect(upstream.requestCount, 0, reason: 'network:none cannot contain a tool that runs at the provider');
    });

    test("a restricted execution's own scoped-bridge MCP tools are not provider-side web", () async {
      // Claude declares its bridge tools as ordinary client tools named
      // `mcp__<server>__<tool>`; they execute in the container against the
      // scoped bridge, which is exactly what a restricted execution is meant to
      // use. Counting them as provider-side egress 403s the whole request and
      // makes the approved-research path unreachable.
      final adapter = _anthropic(upstream);
      addTearDown(adapter.dispose);

      final response = await adapter.handle(
        _request(
          path: '/v1/messages',
          profile: 'restricted',
          body: jsonEncode({
            'model': 'claude',
            'tools': [
              {'name': 'mcp__dartclaw__web_fetch', 'input_schema': <String, dynamic>{}},
              {'name': 'mcp__dartclaw__brave_search', 'input_schema': <String, dynamic>{}},
            ],
          }),
        ),
      );

      expect(response.status, 200);
      expect(upstream.requestCount, 1);
    });

    test('refuses the same request for a workspace execution', () async {
      // Both profiles run under `network:none`, so the provider pipe is the
      // only egress either has: a workspace container that could declare
      // provider-run web tools would make the documented sole-egress property
      // false for the shipped default.
      final adapter = _anthropic(upstream);
      addTearDown(adapter.dispose);

      await expectLater(
        adapter.handle(
          _request(
            path: '/v1/messages',
            body: jsonEncode({
              'tools': [
                {'type': 'web_search_20250305'},
              ],
            }),
          ),
        ),
        throwsA(isA<GatewayDenied>().having((e) => e.status, 'status', 403)),
      );
      expect(upstream.requestCount, 0);
    });

    test('refuses a body it cannot decode instead of forwarding it unchecked', () async {
      final adapter = _anthropic(upstream);
      addTearDown(adapter.dispose);

      await expectLater(
        adapter.handle(
          _request(
            path: '/v1/messages',
            profile: 'restricted',
            rawBody: gzip.encode(
              utf8.encode(
                jsonEncode({
                  'tools': [
                    {'type': 'web_search_20250305'},
                  ],
                }),
              ),
            ),
            headers: {
              'content-encoding': const ['gzip'],
            },
          ),
        ),
        throwsA(isA<GatewayDenied>().having((e) => e.status, 'status', 400)),
      );
      expect(upstream.requestCount, 0, reason: 'a body the tool check cannot read must not reach the provider');
    });

    test('drops a client-declared request encoding', () async {
      final adapter = _anthropic(upstream);
      addTearDown(adapter.dispose);

      await adapter.handle(
        _request(
          path: '/v1/messages',
          body: '{}',
          headers: {
            'content-encoding': const ['gzip'],
          },
        ),
      );

      // The body is forwarded as the plain JSON the tool check read, so a
      // client-declared encoding would describe bytes that were never sent.
      expect(upstream.lastHeaders.containsKey('content-encoding'), isFalse);
    });

    test('preserves the query string on the pinned upstream', () async {
      final adapter = _anthropic(upstream);
      addTearDown(adapter.dispose);

      await adapter.handle(_request(path: '/v1/messages?beta=true', body: '{}'));

      expect(upstream.lastPath, '/v1/messages?beta=true');
    });

    test('fails closed when the host has no credential for the provider', () async {
      final adapter = AnthropicMessagesAdapter(apiKey: () => null, upstream: upstream.uri);
      addTearDown(adapter.dispose);

      await expectLater(
        adapter.handle(_request(path: '/v1/messages', body: '{}')),
        throwsA(isA<GatewayDenied>().having((e) => e.status, 'status', 502)),
      );
      expect(upstream.requestCount, 0);
    });
  });

  group('OpenAiResponsesAdapter', () {
    test('authenticates with a bearer token on its own protocol path', () async {
      final adapter = OpenAiResponsesAdapter(apiKey: () => _hostCredential, upstream: upstream.uri);
      addTearDown(adapter.dispose);

      final response = await adapter.handle(_request(path: '/v1/responses', body: '{"model":"gpt"}'));

      expect(response.status, 200);
      expect(upstream.lastHeaders['authorization'], 'Bearer $_hostCredential');
    });

    test('refuses the other provider\'s path', () async {
      final adapter = OpenAiResponsesAdapter(apiKey: () => _hostCredential, upstream: upstream.uri);
      addTearDown(adapter.dispose);

      await expectLater(
        adapter.handle(_request(path: '/v1/messages', body: '{}')),
        throwsA(isA<GatewayDenied>().having((e) => e.status, 'status', 404)),
      );
      expect(upstream.requestCount, 0);
    });

    test('refuses a restricted execution declaring the Responses web tool', () async {
      final adapter = OpenAiResponsesAdapter(apiKey: () => _hostCredential, upstream: upstream.uri);
      addTearDown(adapter.dispose);

      await expectLater(
        adapter.handle(
          _request(
            path: '/v1/responses',
            profile: 'restricted',
            body: jsonEncode({
              'tools': [
                {'type': 'web_search'},
              ],
            }),
          ),
        ),
        throwsA(isA<GatewayDenied>().having((e) => e.status, 'status', 403)),
      );
    });

    test('refuses a provider-hosted remote MCP connector', () async {
      // Responses has no `mcp_servers` array: a remote connector is an ordinary
      // `tools` entry, and counting only Anthropic's shape left this adapter
      // with an unchecked arbitrary-URL egress path.
      final adapter = OpenAiResponsesAdapter(apiKey: () => _hostCredential, upstream: upstream.uri);
      addTearDown(adapter.dispose);

      await expectLater(
        adapter.handle(
          _request(
            path: '/v1/responses',
            profile: 'restricted',
            body: jsonEncode({
              'tools': [
                {'type': 'mcp', 'server_url': 'https://attacker.example/mcp', 'require_approval': 'never'},
              ],
            }),
          ),
        ),
        throwsA(isA<GatewayDenied>().having((e) => e.status, 'status', 403)),
      );
      expect(upstream.requestCount, 0, reason: 'the refusal must precede any outbound request');
    });

    test("a restricted execution's own scoped-bridge MCP tools are not provider-side web", () async {
      // The connector match is exact on `type`; bridge tools carry `mcp__` in
      // their *name* and execute in the container, so a prefix match here would
      // 403 the approved-research path.
      final adapter = OpenAiResponsesAdapter(apiKey: () => _hostCredential, upstream: upstream.uri);
      addTearDown(adapter.dispose);

      final response = await adapter.handle(
        _request(
          path: '/v1/responses',
          profile: 'restricted',
          body: jsonEncode({
            'tools': [
              {'type': 'function', 'name': 'mcp__dartclaw__web_fetch'},
              {'type': 'function', 'name': 'mcp__dartclaw__brave_search'},
            ],
          }),
        ),
      );

      expect(response.status, 200);
      expect(upstream.requestCount, 1);
    });
  });
}

AnthropicMessagesAdapter _anthropic(_FakeUpstream upstream) =>
    AnthropicMessagesAdapter(apiKey: () => _hostCredential, upstream: upstream.uri);

GatewayRequest _request({
  String method = 'POST',
  required String path,
  String body = '',
  List<int>? rawBody,
  String profile = 'workspace',
  Map<String, List<String>> headers = const {},
}) {
  final bytes = rawBody ?? utf8.encode(body);
  return GatewayRequest(
    principal: GatewayPrincipal(
      sessionId: 'session-a',
      providerId: 'claude',
      policy: ExecutionPolicy.container(profile),
    ),
    method: method,
    path: path,
    headers: headers,
    body: bytes.isEmpty ? const Stream<List<int>>.empty() : Stream.value(bytes),
  );
}

Future<String> _read(GatewayResponse response) async =>
    utf8.decode((await response.body.toList()).expand((chunk) => chunk).toList());

/// Stands in for the provider API, recording exactly what the host sent.
final class _FakeUpstream {
  _FakeUpstream._(this._server);

  final HttpServer _server;

  var requestCount = 0;
  var compressResponse = false;
  String lastPath = '';
  String lastBody = '';
  Map<String, String> lastHeaders = {};

  Uri get uri => Uri.parse('http://${InternetAddress.loopbackIPv4.address}:${_server.port}');

  static Future<_FakeUpstream> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstream = _FakeUpstream._(server);
    server.listen((request) async {
      upstream.requestCount++;
      upstream.lastPath = request.uri.hasQuery ? '${request.uri.path}?${request.uri.query}' : request.uri.path;
      upstream.lastBody = await utf8.decoder.bind(request).join();
      final headers = <String, String>{};
      request.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(','));
      upstream.lastHeaders = headers;
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      if (upstream.compressResponse) {
        request.response.headers.set('content-encoding', 'gzip');
        request.response.add(gzip.encode(utf8.encode('{"ok":true}')));
      } else {
        request.response.write('{"ok":true}');
      }
      await request.response.close();
    });
    return upstream;
  }

  Future<void> close() => _server.close(force: true);
}
