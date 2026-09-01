import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:test/test.dart';

/// A sentinel that must appear only at the fake provider upstream.
const _hostCredential = 'sk-host-only-SENTINEL-2f9c';

/// A stored `setup-token` sentinel, distinct from the API-key one.
const _hostSetupToken = 'sk-ant-oat01-SUBSCRIPTION-SENTINEL-7b31';

void main() {
  late _FakeUpstream upstream;

  setUp(() async => upstream = await _FakeUpstream.start());
  tearDown(() async => upstream.close());

  group('AnthropicMessagesAdapter subscription mediation', () {
    test('presents the stored setup-token as a Bearer under the OAuth beta', () async {
      final adapter = _anthropicSubscription(upstream);
      addTearDown(adapter.dispose);

      final response = await adapter.handle(_request(path: '/v1/messages', body: '{"model":"claude"}'));
      final body = await _read(response);

      expect(response.status, 200);
      expect(upstream.lastHeaders['authorization'], 'Bearer $_hostSetupToken');
      expect(upstream.lastHeaders['anthropic-beta'], contains(AnthropicMessagesAdapter.oauthBeta));
      expect(
        upstream.lastHeaders.containsKey('x-api-key'),
        isFalse,
        reason: 'exactly one credential goes upstream per authority',
      );
      expect(body, isNot(contains(_hostSetupToken)));
      expect(jsonEncode(response.headers), isNot(contains(_hostSetupToken)));
    });

    test('api-key mode adds no OAuth beta header', () async {
      final adapter = _anthropic(upstream);
      addTearDown(adapter.dispose);

      await adapter.handle(_request(path: '/v1/messages', body: '{}'));

      expect(upstream.lastHeaders['x-api-key'], _hostCredential);
      expect(upstream.lastHeaders.containsKey('authorization'), isFalse);
      expect(upstream.lastHeaders.containsKey('anthropic-beta'), isFalse);
    });

    test('drops a client-chosen credential and presents the host-held token instead', () async {
      final adapter = _anthropicSubscription(upstream);
      addTearDown(adapter.dispose);

      await adapter.handle(
        _request(
          path: '/v1/messages',
          body: '{}',
          headers: {
            'authorization': const ['Bearer container-chosen-token'],
            'x-api-key': const ['sk-ant-container-chosen'],
          },
        ),
      );

      expect(upstream.lastHeaders['authorization'], 'Bearer $_hostSetupToken');
      expect(upstream.lastHeaders.containsKey('x-api-key'), isFalse);
      final outbound = jsonEncode(upstream.lastHeaders);
      expect(outbound, isNot(contains('container-chosen-token')));
      expect(outbound, isNot(contains('sk-ant-container-chosen')));
    });

    test('a blank resolved secret fails closed instead of being injected', () async {
      // `CredentialResolution.isPresent` only asks whether a credential object
      // exists, so the adapter is what stops an empty secret reaching upstream.
      final adapter = AnthropicMessagesAdapter(
        credential: ProviderCredentialSource(() => CredentialResolution.apiKey('')),
        upstream: upstream.uri,
      );
      addTearDown(adapter.dispose);

      await expectLater(
        adapter.handle(_request(path: '/v1/messages', body: '{}')),
        throwsA(isA<GatewayDenied>().having((e) => e.status, 'status', 502)),
      );
      expect(upstream.requestCount, 0);
    });

    test('does not send the OAuth beta twice when the client already declared it', () async {
      final adapter = _anthropicSubscription(upstream);
      addTearDown(adapter.dispose);

      await adapter.handle(
        _request(
          path: '/v1/messages',
          body: '{}',
          headers: {
            'anthropic-beta': const [AnthropicMessagesAdapter.oauthBeta],
          },
        ),
      );

      final beta = upstream.lastHeaders['anthropic-beta']!;
      expect(AnthropicMessagesAdapter.oauthBeta.allMatches(beta), hasLength(1));
    });

    test("keeps the client's own beta declarations alongside the injected one", () async {
      // Replacing the header would silently drop capabilities the turn was
      // built around, and the CLI declares its own betas on every request.
      final adapter = _anthropicSubscription(upstream);
      addTearDown(adapter.dispose);

      await adapter.handle(
        _request(
          path: '/v1/messages',
          body: '{}',
          headers: {
            'anthropic-beta': const ['fine-grained-tool-streaming-2025-05-14'],
          },
        ),
      );

      expect(upstream.lastHeaders['anthropic-beta'], contains('fine-grained-tool-streaming-2025-05-14'));
      expect(upstream.lastHeaders['anthropic-beta'], contains(AnthropicMessagesAdapter.oauthBeta));
    });

    test('resolves per request, so a re-issued token is presented without a rebuild', () async {
      var token = 'sk-ant-oat01-first';
      final adapter = AnthropicMessagesAdapter(
        credential: ProviderCredentialSource(
          () => CredentialResolution.subscription(CredentialEntry.subscription(token: token)),
        ),
        upstream: upstream.uri,
      );
      addTearDown(adapter.dispose);

      await adapter.handle(_request(path: '/v1/messages', body: '{}'));
      expect(upstream.lastHeaders['authorization'], 'Bearer sk-ant-oat01-first');

      token = 'sk-ant-oat01-reissued';
      await adapter.handle(_request(path: '/v1/messages', body: '{}'));
      expect(upstream.lastHeaders['authorization'], 'Bearer sk-ant-oat01-reissued');
    });

    test('reports itself available on a subscription credential and unavailable without one', () {
      final subscription = _anthropicSubscription(upstream);
      addTearDown(subscription.dispose);
      final none = AnthropicMessagesAdapter(
        credential: ProviderCredentialSource.apiKey(() => null),
        upstream: upstream.uri,
      );
      addTearDown(none.dispose);

      expect(subscription.unavailableReason, isNull);
      expect(none.unavailableReason, contains('claude setup-token'));
    });

    test('injects what the awaited credential source returns, not its un-refreshed view', () async {
      // A rotating-token source refreshes inside the awaited hook; a request
      // that injected the synchronous admission view would present the token
      // the refresh was replacing.
      final adapter = AnthropicMessagesAdapter(credential: _RefreshingCredentialSource(), upstream: upstream.uri);
      addTearDown(adapter.dispose);

      await adapter.handle(_request(path: '/v1/messages', body: '{}'));

      expect(upstream.lastHeaders['authorization'], 'Bearer refreshed-token');
      expect(adapter.unavailableReason, isNull, reason: 'admission answers without waiting on a refresh');
    });
  });

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
      final adapter = AnthropicMessagesAdapter(
        credential: ProviderCredentialSource.apiKey(() => null),
        upstream: upstream.uri,
      );
      addTearDown(adapter.dispose);

      await expectLater(
        adapter.handle(_request(path: '/v1/messages', body: '{}')),
        throwsA(isA<GatewayDenied>().having((e) => e.status, 'status', 502)),
      );
      expect(upstream.requestCount, 0);
    });
  });

  group('ProviderAdapter header boundary', () {
    test('strips a client credential whatever case the header arrived in', () async {
      // The strip is asserted on `handle` itself rather than through the pipe:
      // the structural claim is that this adapter drops the header, and a
      // lowercase-only comparison here holds only for as long as every producer
      // happens to normalize first.
      final adapter = _anthropic(upstream);
      addTearDown(adapter.dispose);

      await adapter.handle(
        _request(
          path: '/v1/messages',
          body: '{}',
          headers: {
            'X-Api-Key': const ['sk-container-attempt'],
            'Authorization': const ['Bearer sk-container-attempt'],
            'Cookie': const ['session=abc'],
            'ChatGPT-Account-ID': const ['acct-container-chosen'],
          },
        ),
      );

      expect(upstream.lastHeaders['x-api-key'], _hostCredential);
      expect(upstream.lastHeaders.containsKey('cookie'), isFalse);
      expect(upstream.lastHeaders.containsKey('chatgpt-account-id'), isFalse);
      expect(jsonEncode(upstream.lastHeaders), isNot(contains('sk-container-attempt')));
    });

    test('drops the container-chosen account id when the host token carries none', () async {
      // The account header is only *set* when the resolved credential names an
      // account, so without the drop list a single-account store leaves the
      // container's own value as the one the backend reads.
      final adapter = OpenAiResponsesAdapter(
        credential: _CodexStoreSource(accessToken: _codexAccessToken, accountId: null),
        upstream: Uri.https('api.openai.com'),
        subscriptionUpstream: upstream.uri.replace(path: '/backend-api/codex'),
      );
      addTearDown(adapter.dispose);

      await adapter.handle(
        _request(
          path: '/v1/responses',
          body: '{}',
          headers: {
            'chatgpt-account-id': const ['acct-container-chosen'],
          },
        ),
      );

      expect(upstream.lastHeaders['authorization'], 'Bearer $_codexAccessToken');
      expect(upstream.lastHeaders.containsKey('chatgpt-account-id'), isFalse);
    });

    test('never writes a credential-bearing response header back down the pipe', () async {
      // The pipe is the only channel that enters a `network:none` container, so
      // an upstream, WAF, or error page reflecting the request `Authorization`
      // back would hand the host-held credential *into* the boundary.
      final adapter = _anthropicSubscription(upstream);
      addTearDown(adapter.dispose);
      upstream.responseHeaders = {
        'authorization': 'Bearer $_hostSetupToken',
        'x-api-key': _hostCredential,
        'proxy-authenticate': 'Basic realm="$_hostCredential"',
        'set-cookie': 'session=$_hostCredential',
        'x-request-id': 'req-1234',
      };

      final response = await adapter.handle(_request(path: '/v1/messages', body: '{}'));

      final returned = response.headers.keys.map((name) => name.toLowerCase()).toSet();
      expect(returned.intersection({'authorization', 'x-api-key', 'proxy-authenticate', 'set-cookie'}), isEmpty);
      expect(jsonEncode(response.headers), isNot(contains(_hostSetupToken)));
      expect(jsonEncode(response.headers), isNot(contains(_hostCredential)));
      // Positive control: an ordinary header still comes back, so the assertion
      // above is not passing on an empty header map.
      expect(returned, contains('x-request-id'));
    });
  });

  group('AnthropicMessagesAdapter upstream refusal', () {
    test('a refused subscription credential ends the authority instead of forwarding a 401', () async {
      // FR1 accepts a best-effort derived `setup-token` expiry *because* the
      // live refusal catches a wrong derivation. Forwarding it would leave the
      // container with a bare 401 and the authority mediating on a dead token.
      upstream.status = 401;
      upstream.responseBody = '{"type":"error","error":{"type":"authentication_error"}}';
      final adapter = _anthropicSubscription(upstream);
      addTearDown(adapter.dispose);

      await expectLater(
        adapter.handle(_request(path: '/v1/messages', body: '{}')),
        throwsA(
          isA<GatewayCredentialUnusable>()
              .having((failure) => failure.providerId, 'providerId', 'claude')
              .having((failure) => failure.remediation, 'remediation', contains('claude setup-token'))
              .having((failure) => failure.remediation, 'remediation', isNot(contains(_hostSetupToken))),
        ),
      );
    });

    test('a 403 permission_error is forwarded: the credential authenticated, the plan refused', () async {
      // Anthropic answers 403 `permission_error` for a plan or organization
      // restriction on a live token. Reading that as credential death would
      // destroy the authority mid-turn and send the operator to re-run
      // `claude setup-token` for a credential that works.
      upstream.status = 403;
      upstream.responseBody = '{"type":"error","error":{"type":"permission_error"}}';
      final adapter = _anthropicSubscription(upstream);
      addTearDown(adapter.dispose);

      final response = await adapter.handle(_request(path: '/v1/messages', body: '{}'));

      expect(response.status, 403);
      expect(await _read(response), contains('permission_error'));
    });

    test('a 403 the API answers with an authentication error is terminal', () async {
      upstream.status = 403;
      upstream.responseBody = '{"type":"error","error":{"type":"authentication_error"}}';
      final adapter = _anthropicSubscription(upstream);
      addTearDown(adapter.dispose);

      await expectLater(
        adapter.handle(_request(path: '/v1/messages', body: '{}')),
        throwsA(isA<GatewayCredentialUnusable>()),
      );
    });

    test('an api-key deployment still forwards the upstream answer unchanged', () async {
      // DartClaw tracks no lifetime for an operator-managed key, so a refusal
      // there is as likely to be about the request as about the credential —
      // tearing the authority down over one would be a false alarm.
      upstream.status = 401;
      upstream.responseBody = '{"type":"error","error":{"type":"authentication_error"}}';
      final adapter = _anthropic(upstream);
      addTearDown(adapter.dispose);

      final response = await adapter.handle(_request(path: '/v1/messages', body: '{}'));

      expect(response.status, 401);
      expect(await _read(response), contains('authentication_error'));
    });

    test('an unrelated upstream failure is forwarded, not read as a dead credential', () async {
      upstream.status = 500;
      upstream.responseBody = '{"type":"error","error":{"type":"api_error"}}';
      final adapter = _anthropicSubscription(upstream);
      addTearDown(adapter.dispose);

      final response = await adapter.handle(_request(path: '/v1/messages', body: '{}'));

      expect(response.status, 500);
    });
  });

  group('OpenAiResponsesAdapter', () {
    test('authenticates with a bearer token on its own protocol path', () async {
      final adapter = OpenAiResponsesAdapter(
        credential: ProviderCredentialSource.apiKey(() => _hostCredential),
        upstream: upstream.uri,
      );
      addTearDown(adapter.dispose);

      final response = await adapter.handle(_request(path: '/v1/responses', body: '{"model":"gpt"}'));

      expect(response.status, 200);
      expect(upstream.lastHeaders['authorization'], 'Bearer $_hostCredential');
    });

    test('refuses the other provider\'s path', () async {
      final adapter = OpenAiResponsesAdapter(
        credential: ProviderCredentialSource.apiKey(() => _hostCredential),
        upstream: upstream.uri,
      );
      addTearDown(adapter.dispose);

      await expectLater(
        adapter.handle(_request(path: '/v1/messages', body: '{}')),
        throwsA(isA<GatewayDenied>().having((e) => e.status, 'status', 404)),
      );
      expect(upstream.requestCount, 0);
    });

    test('refuses a restricted execution declaring the Responses web tool', () async {
      final adapter = OpenAiResponsesAdapter(
        credential: ProviderCredentialSource.apiKey(() => _hostCredential),
        upstream: upstream.uri,
      );
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
      final adapter = OpenAiResponsesAdapter(
        credential: ProviderCredentialSource.apiKey(() => _hostCredential),
        upstream: upstream.uri,
      );
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
      final adapter = OpenAiResponsesAdapter(
        credential: ProviderCredentialSource.apiKey(() => _hostCredential),
        upstream: upstream.uri,
      );
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

  group('OpenAiResponsesAdapter subscription mediation', () {
    late _CodexStoreSource source;
    late Uri backend;

    setUp(() {
      source = _CodexStoreSource(accessToken: _codexAccessToken, accountId: _codexAccountId);
      // The real ChatGPT backend carries a base path, so the fake one does too:
      // a target composed by replacing the upstream path would silently drop it.
      backend = upstream.uri.replace(path: '/backend-api/codex');
    });

    OpenAiResponsesAdapter subscriptionAdapter({void Function(CodexRejection)? onRejection}) => OpenAiResponsesAdapter(
      credential: source,
      upstream: Uri.https('api.openai.com'),
      subscriptionUpstream: backend,
      onRejection: onRejection,
    );

    test('reaches the pinned backend path with both headers read at request time', () async {
      final adapter = subscriptionAdapter();
      addTearDown(adapter.dispose);

      final response = await adapter.handle(_request(path: '/v1/responses', body: '{"model":"gpt-5-codex"}'));
      final body = await _read(response);

      expect(response.status, 200);
      expect(upstream.lastPath, '/backend-api/codex/responses');
      expect(upstream.lastHeaders['authorization'], 'Bearer $_codexAccessToken');
      expect(upstream.lastHeaders['chatgpt-account-id'], _codexAccountId);
      expect(upstream.lastHeaders['originator'], OpenAiResponsesAdapter.originator);
      expect(body, isNot(contains(_codexAccessToken)));
      expect(jsonEncode(response.headers), isNot(contains(_codexAccessToken)));
    });

    test('a store rotated between two requests presents two different bearers', () async {
      final adapter = subscriptionAdapter();
      addTearDown(adapter.dispose);

      await adapter.handle(_request(path: '/v1/responses', body: '{}'));
      final first = upstream.lastHeaders['authorization'];
      source.accessToken = 'sk-codex-ROTATED-SENTINEL-4d21';
      await adapter.handle(_request(path: '/v1/responses', body: '{}'));

      expect(first, 'Bearer $_codexAccessToken');
      expect(upstream.lastHeaders['authorization'], 'Bearer sk-codex-ROTATED-SENTINEL-4d21');
    });

    test('drops a container-chosen credential and presents the host-held one', () async {
      final adapter = subscriptionAdapter();
      addTearDown(adapter.dispose);

      await adapter.handle(
        _request(
          path: '/v1/responses',
          body: '{}',
          headers: {
            'authorization': const ['Bearer container-chosen-token'],
            'chatgpt-account-id': const ['acct-container-chosen'],
          },
        ),
      );

      expect(upstream.lastHeaders['authorization'], 'Bearer $_codexAccessToken');
      expect(upstream.lastHeaders['chatgpt-account-id'], _codexAccountId);
    });

    test('api-key mode keeps the Platform endpoint and its unchanged header', () async {
      final adapter = OpenAiResponsesAdapter(
        credential: ProviderCredentialSource.apiKey(() => _hostCredential),
        upstream: upstream.uri,
        subscriptionUpstream: Uri.https('chatgpt.com', '/backend-api/codex'),
      );
      addTearDown(adapter.dispose);

      await adapter.handle(_request(path: '/v1/responses', body: '{}'));

      expect(upstream.lastPath, '/v1/responses');
      expect(upstream.lastHeaders['authorization'], 'Bearer $_hostCredential');
      expect(upstream.lastHeaders.containsKey('chatgpt-account-id'), isFalse);
    });
  });

  group('OpenAiResponsesAdapter destination constraint', () {
    late _CodexStoreSource source;

    setUp(() => source = _CodexStoreSource(accessToken: _codexAccessToken, accountId: _codexAccountId));

    Future<void> expectRefused(GatewayRequest request) async {
      final adapter = OpenAiResponsesAdapter(
        credential: source,
        subscriptionUpstream: upstream.uri.replace(path: '/backend-api/codex'),
      );
      addTearDown(adapter.dispose);

      await expectLater(
        adapter.handle(request),
        throwsA(
          isA<GatewayDenied>().having(
            (denied) => denied.reason,
            'reason',
            allOf(isNot(contains(_codexAccessToken)), isNot(contains(_codexAccountId))),
          ),
        ),
      );
      expect(upstream.requestCount, 0, reason: 'no upstream connection is opened for a refused destination');
    }

    test('a path outside the provider surface is refused before any outbound call', () async {
      await expectRefused(_request(path: '/v1/chat/completions', body: '{}'));
    });

    test('a container-supplied absolute target naming another host is refused', () async {
      await expectRefused(_request(path: 'https://api.openai.com/v1/responses', body: '{}'));
    });

    test('a non-POST method on the allowed path is refused', () async {
      await expectRefused(_request(method: 'GET', path: '/v1/responses'));
    });

    test('a composed target outside the pinned origins is refused', () async {
      final adapter = _EscapingAdapter(credential: ProviderCredentialSource.apiKey(() => _hostCredential));
      addTearDown(adapter.dispose);

      await expectLater(
        adapter.handle(_request(path: '/v1/responses', body: '{}')),
        throwsA(
          isA<GatewayDenied>()
              .having((denied) => denied.status, 'status', 403)
              .having((denied) => denied.reason, 'reason', contains('pinned')),
        ),
      );
    });

    test('the pin admits only the backend the presented credential may reach', () {
      final adapter = OpenAiResponsesAdapter(
        credential: source,
        upstream: OpenAiResponsesAdapter.defaultUpstream,
        subscriptionUpstream: OpenAiResponsesAdapter.defaultSubscriptionUpstream,
      );
      addTearDown(adapter.dispose);

      // The two backends refuse each other's credential, so a fixed two-origin
      // allowlist would let a composition bug open a connection to the wrong
      // one — a subscription token to the Platform, or an API key to the
      // ChatGPT backend — instead of being refused before the socket.
      expect(adapter.pinnedOriginsFor(CredentialResolution.apiKey(_hostCredential)), {
        ProviderAdapter.originOf(OpenAiResponsesAdapter.defaultUpstream),
      });
      expect(
        adapter.pinnedOriginsFor(CredentialResolution.subscription(CredentialEntry.subscription(token: 'stored'))),
        {ProviderAdapter.originOf(OpenAiResponsesAdapter.defaultSubscriptionUpstream)},
      );
    });
  });

  group('OpenAiResponsesAdapter upstream classification', () {
    late _CodexStoreSource source;

    setUp(() => source = _CodexStoreSource(accessToken: _codexAccessToken, accountId: _codexAccountId));

    Future<CodexRejection?> classify({required int status, required String body, String requestBody = '{}'}) async {
      upstream.status = status;
      upstream.responseBody = body;
      CodexRejection? seen;
      final adapter = OpenAiResponsesAdapter(
        credential: source,
        subscriptionUpstream: upstream.uri.replace(path: '/backend-api/codex'),
        onRejection: (rejection) => seen = rejection,
      );
      addTearDown(adapter.dispose);

      final response = await adapter.handle(_request(path: '/v1/responses', body: requestBody));
      expect(response.status, status, reason: 'the refusal still reaches the container unchanged');
      expect(await _read(response), body);
      return seen;
    }

    test('a model rejection names the requested model and is not an auth fault', () async {
      final rejection = await classify(
        status: 400,
        body: '{"error":{"message":"The model gpt-5.1-codex is not supported for this account"}}',
        requestBody: '{"model":"gpt-5.1-codex"}',
      );

      expect(rejection?.kind, CodexRejectionKind.modelUnsupported);
      expect(rejection?.model, 'gpt-5.1-codex');
      expect(rejection?.describe(), contains('gpt-5.1-codex'));
    });

    test('a usage limit is neither re-authentication nor a contract break', () async {
      final rejection = await classify(status: 429, body: '{"error":{"type":"usage_limit_reached"}}');

      expect(rejection?.kind, CodexRejectionKind.usageLimit);
      expect(rejection?.describe(), isNot(contains('log in')));
    });

    test('an unclassified upstream error stays unclassified', () async {
      final rejection = await classify(status: 500, body: '{"error":{"message":"internal"}}');

      expect(rejection, isNull);
    });

    /// The same drive against the Platform lane an API key is mediated on.
    Future<CodexRejection?> classifyApiKey({
      required int status,
      required String body,
      String requestBody = '{}',
    }) async {
      upstream.status = status;
      upstream.responseBody = body;
      CodexRejection? seen;
      final adapter = OpenAiResponsesAdapter(
        credential: ProviderCredentialSource.apiKey(() => _hostCredential),
        upstream: upstream.uri,
        onRejection: (rejection) => seen = rejection,
      );
      addTearDown(adapter.dispose);

      final response = await adapter.handle(_request(path: '/v1/responses', body: requestBody));
      expect(response.status, status, reason: 'the Platform answer reaches the container unchanged');
      return seen;
    }

    test('an api-key refusal is not reported as a refused subscription credential', () async {
      // The classifier's whole vocabulary is about the ChatGPT backend, which an
      // API key never reaches. Reporting a revoked Platform key through it would
      // name the operator's *subscription* and send them to `dartclaw auth
      // codex` — a store this deployment does not present.
      expect(await classifyApiKey(status: 401, body: '{"error":{"type":"invalid_api_key"}}'), isNull);
    });

    test('an api-key deployment is silent for a usage limit and a rejected model, deliberately', () async {
      // Same two answers the tests above classify under a subscription, and the
      // silence here is the intended behavior, not an unclosed gap: every word
      // `CodexRejection.describe()` writes names the ChatGPT plan behind the
      // credential, so relaying a Platform quota or model refusal through it
      // would describe an account this deployment does not bill. Neither bucket
      // maps to a credential-health state either (`security_wiring.dart` maps
      // both to null), so what the silence costs is one wrongly-worded warning
      // line — the Platform's own answer still reaches the container unchanged.
      // Narrowing the gate means authoring a second, Platform-worded
      // vocabulary; don't, without a diagnostic worth the surface.
      expect(await classifyApiKey(status: 429, body: '{"error":{"type":"usage_limit_reached"}}'), isNull);
      expect(
        await classifyApiKey(
          status: 400,
          body: '{"error":{"message":"The model gpt-5.1-codex is not supported for this account"}}',
          requestBody: '{"model":"gpt-5.1-codex"}',
        ),
        isNull,
      );
    });
  });
}

AnthropicMessagesAdapter _anthropic(_FakeUpstream upstream) => AnthropicMessagesAdapter(
  credential: ProviderCredentialSource.apiKey(() => _hostCredential),
  upstream: upstream.uri,
);

AnthropicMessagesAdapter _anthropicSubscription(_FakeUpstream upstream) => AnthropicMessagesAdapter(
  credential: ProviderCredentialSource(
    () => CredentialResolution.subscription(CredentialEntry.subscription(token: _hostSetupToken)),
  ),
  upstream: upstream.uri,
);

/// A source whose token rotates behind an awaited refresh — the shape a
/// freshness-gated provider needs from the base class.
final class _RefreshingCredentialSource extends ProviderCredentialSource {
  new() : super(() => CredentialResolution.subscription(CredentialEntry.subscription(token: 'stale-token')));

  @override
  Future<CredentialResolution> present() async {
    await Future<void>.delayed(Duration.zero);
    return CredentialResolution.subscription(CredentialEntry.subscription(token: 'refreshed-token'));
  }
}

/// A sentinel ChatGPT access token, distinct from the API-key one.
const _codexAccessToken = 'sk-codex-SUBSCRIPTION-SENTINEL-9c02';
const _codexAccountId = 'acct-SENTINEL-31f8';

/// A dedicated Codex store whose token rotates behind the awaited hook.
final class _CodexStoreSource extends ProviderCredentialSource {
  new({required this.accessToken, required this.accountId})
    : super(
        // Admission asks whether a credential is configured, not which one:
        // the token it would present rotates before the request is injected.
        () => CredentialResolution.subscription(CredentialEntry.subscription(token: 'configured')),
      );

  String accessToken;

  /// Null reproduces a single-account store, where the host presents no account
  /// header at all.
  final String? accountId;

  @override
  Future<CredentialResolution> present() async => CodexSubscriptionResolution(
    CodexSubscriptionCredential(accessToken: accessToken, accountId: accountId, expiresAt: DateTime.now()),
  );
}

/// A protocol subclass that composes a target off its own pinned origin, so the
/// base guard is proven to refuse rather than merely to be unreachable.
final class _EscapingAdapter extends ProviderAdapter {
  new({required super.credential}) : super(providerId: 'codex', upstream: Uri.https('api.openai.com'));

  @override
  String get providerFamily => 'codex';

  @override
  Set<String> get allowedPaths => const {'/v1/responses'};

  @override
  Uri composeTarget(String path, String? query, CredentialResolution credential) => Uri.https('evil.example.com', path);

  @override
  void authenticate(HttpClientRequest request, CredentialResolution credential) {}

  @override
  int countNetworkTools(Object? body) => 0;
}

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
  new _(this._server);

  final HttpServer _server;

  var requestCount = 0;
  var compressResponse = false;
  var status = 200;
  var responseBody = '{"ok":true}';

  /// Headers this upstream writes onto every answer, so a fixture can reproduce
  /// an intermediary or error page reflecting a request header back.
  Map<String, String> responseHeaders = const {};
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
      request.response.statusCode = upstream.status;
      request.response.headers.contentType = ContentType.json;
      upstream.responseHeaders.forEach(request.response.headers.set);
      if (upstream.compressResponse) {
        request.response.headers.set('content-encoding', 'gzip');
        request.response.add(gzip.encode(utf8.encode(upstream.responseBody)));
      } else {
        request.response.write(upstream.responseBody);
      }
      await request.response.close();
    });
    return upstream;
  }

  Future<void> close() => _server.close(force: true);
}
