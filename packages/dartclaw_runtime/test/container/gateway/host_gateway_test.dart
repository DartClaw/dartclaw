import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_bridge/dartclaw_bridge.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:test/test.dart';

import 'gateway_test_support.dart';

void main() {
  group('HostGateway registration', () {
    test('rejects a provider it cannot mediate rather than admitting it unmediated', () {
      final gateway = HostGateway(providerAdapters: {'claude': _EchoAdapter()});

      expect(
        () => gateway.register(principal: principal(providerId: 'goose')),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('no host mediation adapter'))),
      );
    });

    test('rejects containerized Claude at admission when the host holds no credential', () {
      // The host CLI may well be logged in interactively, but nothing the
      // adapter can mediate with exists. Nothing may be admitted on that
      // promise, and the refusal must name both ways to fix it.
      final refusals = <({String providerId, String detail, String? remediation})>[];
      final gateway = HostGateway(
        providerAdapters: {'claude': AnthropicMessagesAdapter(credential: ProviderCredentialSource.apiKey(() => null))},
        onCredentialRefused: (providerId, detail, {remediation}) =>
            refusals.add((providerId: providerId, detail: detail, remediation: remediation)),
      );

      expect(
        () => gateway.register(principal: principal(providerId: 'claude')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('no host-held credential'),
              contains('claude setup-token'),
              contains('ANTHROPIC_API_KEY'),
              contains('execution: host'),
            ),
          ),
        ),
      );
      // Refused before any authority exists, and announced once, with the fix.
      expect(gateway.liveAuthorityCount, 0);
      expect(refusals.single.providerId, 'claude');
      expect(refusals.single.remediation, contains('claude setup-token'));
      expect(refusals.single.detail, isNot(contains('sk-ant')));
    });

    test('refuses a forced selection by naming the setting, not the other credential', () {
      final gateway = HostGateway(
        providerAdapters: {
          'claude': AnthropicMessagesAdapter(
            credential: ProviderCredentialSource(
              () => const CredentialResolution.unavailable(CredentialUnavailableReason.subscriptionAbsent),
            ),
          ),
        },
      );

      expect(
        () => gateway.register(principal: principal(providerId: 'claude')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('auth: subscription'),
              isNot(contains('ANTHROPIC_API_KEY')),
              // Host mode refuses a forced selection just the same, so naming it
              // here would send the operator to a documented dead end.
              isNot(contains('execution: host')),
            ),
          ),
        ),
      );
    });

    test('admits containerized Claude once a host API key exists', () {
      final gateway = HostGateway(
        providerAdapters: {
          'claude': AnthropicMessagesAdapter(credential: ProviderCredentialSource.apiKey(() => 'sk-ant-host')),
        },
      );

      expect(gateway.register(principal: principal(providerId: 'claude')).isRevoked, isFalse);
    });

    test('admits containerized Claude on a stored subscription credential alone', () {
      // The 0.24 rule was API-key-only; a subscription-mediated deployment must
      // now be admitted without one, or the secure boundary stays the
      // expensive one.
      final gateway = HostGateway(
        providerAdapters: {
          'claude': AnthropicMessagesAdapter(
            credential: ProviderCredentialSource(
              () => CredentialResolution.subscription(CredentialEntry.subscription(token: 'sk-ant-oat01-stored')),
            ),
          ),
        },
      );

      expect(gateway.register(principal: principal(providerId: 'claude')).isRevoked, isFalse);
    });

    test('starts an MCP surface only for an authority that has an allowlist', () {
      final gateway = HostGateway(providerAdapters: {'claude': _EchoAdapter()}, mcpHandler: McpProtocolHandler.new);

      expect(gateway.register(principal: principal()).requiredSurfaces, {BridgeSurface.provider});
      expect(gateway.register(principal: principal(), allowedMcpTools: {'web_search'}).requiredSurfaces, {
        BridgeSurface.provider,
        BridgeSurface.mcp,
      });
    });

    // The MCP endpoint the bridge scopes exists only once the server is
    // composed, but the *primary* lane's container authority is acquired during
    // harness wiring, before that. Resolving the handler at attach made a
    // containerized primary unbootable — `dartclaw serve` with containers on
    // died in wiring with "This runtime composed no server", and did so at the
    // 0.25 merge base too, so no containerized primary has ever started here.
    test('attaching an MCP surface does not resolve the endpoint the server owns', () {
      var resolved = 0;
      final gateway = HostGateway(
        providerAdapters: {'claude': _EchoAdapter()},
        mcpHandler: () {
          resolved++;
          throw StateError('This runtime composed no server');
        },
      );
      final authority = gateway.register(principal: principal(), allowedMcpTools: {'web_search'});
      final channel = FakeBridgeChannel();
      addTearDown(channel.close);

      expect(() => gateway.attach(authority, BridgeSurface.mcp, channel), returnsNormally);
      expect(resolved, 0, reason: 'the endpoint is reached on the first request, never at attach');
    });

    test('refuses a second pipe for a surface the authority already owns', () async {
      final gateway = HostGateway(providerAdapters: {'claude': _EchoAdapter()});
      final authority = gateway.register(principal: principal());
      final first = FakeBridgeChannel();
      addTearDown(first.close);
      gateway.attach(authority, BridgeSurface.provider, first);

      final second = FakeBridgeChannel();
      addTearDown(second.close);
      expect(
        () => gateway.attach(authority, BridgeSurface.provider, second),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('already owns'))),
      );
    });
  });

  group('HostGateway surface binding', () {
    test('answers a request on the pipe bound to its own surface', () async {
      final harness = await _GatewayHarness.start();
      addTearDown(harness.dispose);

      final exchange = await harness.provider.request(1, body: 'hello');

      expect(exchange.status, 200);
      expect(exchange.body, 'echo:hello');
      expect(exchange.isDenied, isFalse);
    });

    test('round-trips a non-ASCII body without corrupting it', () async {
      // A byte-wise decode still yields parseable JSON, so a mangled search
      // query or percent-decoded URL would reach the tool silently.
      final harness = await _GatewayHarness.start();
      addTearDown(harness.dispose);
      const payload = '{"q":"vad är väder – 北京? ☂"}';

      final exchange = await harness.provider.request(1, body: payload);

      expect(exchange.body, 'echo:$payload');
    });

    test('fails the pipe when the bridge claims a surface the host did not bind', () async {
      final gateway = HostGateway(providerAdapters: {'claude': _EchoAdapter()});
      final authority = gateway.register(principal: principal());
      final channel = FakeBridgeChannel();
      addTearDown(channel.close);
      final pipe = gateway.attach(authority, BridgeSurface.provider, channel);

      // An MCP handshake on the provider pipe: the surface is fixed host-side,
      // so this is a misdelivered process, not a negotiation.
      channel.emit(
        BridgeFrame(
          type: BridgeFrameType.handshake,
          metadata: {'version': bridgeProtocolVersion, 'surface': BridgeSurface.mcp.name},
        ),
      );
      await expectLater(pipe.ready, throwsA(isA<StateError>()));
      await pumpEventQueue();
      expect(pipe.isRevoked, isTrue);
      expect(channel.isClosed, isTrue);
    });

    test('fails the pipe closed on a protocol version mismatch', () async {
      final gateway = HostGateway(providerAdapters: {'claude': _EchoAdapter()});
      final authority = gateway.register(principal: principal());
      final channel = FakeBridgeChannel();
      addTearDown(channel.close);
      final pipe = gateway.attach(authority, BridgeSurface.provider, channel);

      channel.emit(
        BridgeFrame(
          type: BridgeFrameType.handshake,
          metadata: {'version': bridgeProtocolVersion + 1, 'surface': BridgeSurface.provider.name},
        ),
      );

      await expectLater(pipe.ready, throwsA(isA<StateError>()));
      expect(pipe.isRevoked, isTrue);
    });

    test('rejects a request that arrives before the handshake', () async {
      final gateway = HostGateway(providerAdapters: {'claude': _EchoAdapter()});
      final authority = gateway.register(principal: principal());
      final channel = FakeBridgeChannel();
      addTearDown(channel.close);
      final pipe = gateway.attach(authority, BridgeSurface.provider, channel);

      channel.emit(const BridgeFrame(type: BridgeFrameType.requestStart, requestId: 1));

      await expectLater(pipe.ready, throwsA(isA<StateError>()));
      expect(pipe.isRevoked, isTrue);
    });

    test('revokes the pipe on a malformed frame instead of resynchronizing', () async {
      final harness = await _GatewayHarness.start();
      addTearDown(harness.dispose);

      // A declared length far beyond the cap.
      harness.providerChannel.emitRaw([0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0]);
      await pumpEventQueue();

      expect(harness.providerPipe.isRevoked, isTrue);
      expect(harness.denials.single, contains('provider'));
    });

    test('rejects a reused request ID', () async {
      final harness = await _GatewayHarness.start();
      addTearDown(harness.dispose);

      harness.providerChannel.emit(
        const BridgeFrame(
          type: BridgeFrameType.requestStart,
          requestId: 7,
          metadata: {'method': 'POST', 'path': '/v1/messages'},
        ),
      );
      harness.providerChannel.emit(
        const BridgeFrame(
          type: BridgeFrameType.requestStart,
          requestId: 7,
          metadata: {'method': 'POST', 'path': '/v1/messages'},
        ),
      );
      await pumpEventQueue();

      expect(harness.providerPipe.isRevoked, isTrue);
    });

    test('refuses requests past the in-flight cap without disturbing open ones', () async {
      final adapter = _BlockingAdapter();
      final harness = await _GatewayHarness.start(adapter: adapter, limits: const BridgeLimits(maxInFlightRequests: 1));
      addTearDown(harness.dispose);

      harness.providerChannel.emit(
        const BridgeFrame(
          type: BridgeFrameType.requestStart,
          requestId: 1,
          metadata: {'method': 'POST', 'path': '/v1/messages'},
        ),
      );
      harness.providerChannel.emit(const BridgeFrame(type: BridgeFrameType.requestEnd, requestId: 1));
      await pumpEventQueue();

      final second = harness.provider.request(2);
      final denied = await second;
      expect(denied.isDenied, isTrue);
      expect(denied.status, 503);

      adapter.release('done');
      final first = await harness.provider.collect(1);
      expect(first.body, 'done');
    });

    test('cancelling one request leaves a concurrent one answerable', () async {
      final adapter = _BlockingAdapter();
      final harness = await _GatewayHarness.start(adapter: adapter);
      addTearDown(harness.dispose);

      for (final id in [1, 2]) {
        harness.providerChannel.emit(
          BridgeFrame(
            type: BridgeFrameType.requestStart,
            requestId: id,
            metadata: const {'method': 'POST', 'path': '/v1/messages'},
          ),
        );
        harness.providerChannel.emit(BridgeFrame(type: BridgeFrameType.requestEnd, requestId: id));
      }
      await pumpEventQueue();

      harness.providerChannel.emit(const BridgeFrame(type: BridgeFrameType.cancel, requestId: 1));
      await pumpEventQueue();
      adapter.release('ok');

      expect((await harness.provider.collect(2)).body, 'ok');
    });
  });

  group('HostGateway revocation', () {
    test('closes every pipe and refuses re-attachment after release', () async {
      final harness = await _GatewayHarness.start();
      addTearDown(harness.dispose);

      await harness.gateway.revoke(harness.authority);

      expect(harness.providerPipe.isRevoked, isTrue);
      expect(harness.providerChannel.isClosed, isTrue);
      expect(harness.gateway.liveAuthorityCount, 0);
      expect(
        () => harness.gateway.attach(harness.authority, BridgeSurface.provider, FakeBridgeChannel()),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('revoked'))),
      );
    });

    test('is idempotent so teardown can run on every failure path', () async {
      final harness = await _GatewayHarness.start();
      addTearDown(harness.dispose);

      await harness.gateway.revoke(harness.authority);
      await harness.gateway.revoke(harness.authority);

      expect(harness.providerChannel.closeCount, 1);
    });

    test('ignores frames written to a released pipe', () async {
      final harness = await _GatewayHarness.start();
      addTearDown(harness.dispose);
      await harness.gateway.revoke(harness.authority);

      harness.providerChannel.emit(
        const BridgeFrame(
          type: BridgeFrameType.requestStart,
          requestId: 99,
          metadata: {'method': 'POST', 'path': '/v1/messages'},
        ),
      );
      await pumpEventQueue();

      expect(harness.providerPipe.inFlightCount, 0);
    });

    test("a second authority's pipe cannot serve the first authority's principal", () async {
      final adapter = _PrincipalEchoAdapter();
      final gateway = HostGateway(providerAdapters: {'claude': adapter});
      final authorityA = gateway.register(principal: principal(sessionId: 'session-a'));
      final authorityB = gateway.register(principal: principal(sessionId: 'session-b'));
      final channelA = FakeBridgeChannel();
      final channelB = FakeBridgeChannel();
      addTearDown(channelA.close);
      addTearDown(channelB.close);
      gateway.attach(authorityA, BridgeSurface.provider, channelA);
      gateway.attach(authorityB, BridgeSurface.provider, channelB);
      await channelA.handshake(BridgeSurface.provider);
      await channelB.handshake(BridgeSurface.provider);

      await gateway.revoke(authorityA);

      // B replays A's captured request ID on its own pipe: identity comes from
      // the pipe, so it is answered as B and never as A.
      final replay = await channelB.request(1, body: 'x');
      expect(replay.body, 'session-b');
    });
  });

  group('HostGateway provider mediation', () {
    test('refuses a provider-side network tool declared by a workspace container', () async {
      // `network:none` applies to every profile, so the shipped default must
      // not be able to turn the credentialed pipe into arbitrary egress.
      final upstream = await _ForbiddenUpstream.start();
      addTearDown(upstream.close);
      final harness = await _GatewayHarness.start(
        adapter: AnthropicMessagesAdapter(
          credential: ProviderCredentialSource.apiKey(() => 'sk-ant-host'),
          upstream: upstream.uri,
        ),
      );
      addTearDown(harness.dispose);

      final exchange = await harness.provider.request(
        1,
        path: '/v1/messages',
        body: jsonEncode({
          'model': 'claude',
          'tools': [
            {'type': 'web_search_20250305'},
          ],
        }),
      );

      expect(harness.authority.principal.containerProfile, 'workspace');
      expect(exchange.isDenied, isTrue);
      expect(exchange.status, 403);
      expect(exchange.failure, contains('provider-side network tool'));
      expect(upstream.requestCount, 0);
    });
  });

  group('HostGateway terminal credential failure', () {
    const remediation = 'Provider "claude" has no credential configured – run `claude setup-token`.';

    test('ends the turn with the remediation and never passes the upstream answer through', () async {
      final adapter = _CredentialFailureAdapter(remediation);
      final harness = await _GatewayHarness.start(adapter: adapter);
      addTearDown(harness.dispose);

      final exchange = await harness.provider.request(1, path: '/v1/messages', body: '{}');

      expect(exchange.isDenied, isTrue);
      // The container is answered by the host, in the host's words: the whole
      // exchange is a `failure` frame carrying the remediation, so no upstream
      // status line or body reaches it.
      expect(exchange.failure, remediation);
      expect(exchange.status, 502);
      expect(harness.refusals.single.remediation, remediation);
    });

    test('tears the authority down through the release path so nothing more is mediated on it', () async {
      final released = <String>[];
      final adapter = _CredentialFailureAdapter(remediation);
      final harness = await _GatewayHarness.start(adapter: adapter, onCredentialUnusable: released.add);
      addTearDown(harness.dispose);

      await harness.provider.request(1, path: '/v1/messages', body: '{}');

      // The release path owns revocation, so the gateway must hand the authority
      // over rather than revoking it itself — a gateway-side revoke here would
      // leave the container running with nothing left to stop it.
      expect(released, [harness.authority.id]);
      expect(harness.authority.isRevoked, isFalse);
    });

    test('revokes the authority itself when no release path is wired', () async {
      final harness = await _GatewayHarness.start(adapter: _CredentialFailureAdapter(remediation));
      addTearDown(harness.dispose);

      await harness.provider.request(1, path: '/v1/messages', body: '{}');
      await pumpEventQueue();

      expect(harness.authority.isRevoked, isTrue);
      expect(harness.gateway.liveAuthorityCount, 0);
    });

    test('announces one authority once, however many requests hit the dead credential', () async {
      // Teardown is async, so without a latch each concurrent request would
      // announce the same dead credential again. Wiring a release that does not
      // revoke keeps both requests eligible, so only the latch can dedup them.
      final released = <String>[];
      final harness = await _GatewayHarness.start(
        adapter: _CredentialFailureAdapter(remediation),
        onCredentialUnusable: released.add,
      );
      addTearDown(harness.dispose);

      await Future.wait([
        harness.provider.request(1, path: '/v1/messages', body: '{}'),
        harness.provider.request(2, path: '/v1/messages', body: '{}'),
      ]);
      await pumpEventQueue();

      expect(harness.refusals, hasLength(1));
      expect(released, hasLength(1));
    });

    test('leaves the authority live for a refusal that is not a credential fault', () async {
      final harness = await _GatewayHarness.start(adapter: _RateLimitedAdapter());
      addTearDown(harness.dispose);

      final exchange = await harness.provider.request(1, path: '/v1/messages', body: '{}');

      expect(exchange.status, 429);
      expect(harness.authority.isRevoked, isFalse);
      expect(harness.refusals, isEmpty);
    });

    test('a plan restriction on a live subscription neither ends the authority nor pages the operator', () async {
      // 403 `permission_error` means authenticated but not permitted: the token
      // is fine and re-authenticating fixes nothing, so the container gets the
      // backend's own answer and the authority keeps mediating.
      final upstream = await _RefusingUpstream.start(
        status: 403,
        body: '{"type":"error","error":{"type":"permission_error"}}',
      );
      addTearDown(upstream.close);
      final harness = await _GatewayHarness.start(adapter: _subscriptionAdapter(upstream));
      addTearDown(harness.dispose);

      final exchange = await harness.provider.request(1, path: '/v1/messages', body: '{}');
      await pumpEventQueue();

      expect(exchange.status, 403);
      expect(exchange.isDenied, isFalse);
      expect(harness.refusals, isEmpty);
      expect(harness.authority.isRevoked, isFalse);
    });

    test('a 401 on the same subscription still ends the authority and reports the refusal', () async {
      final upstream = await _RefusingUpstream.start(
        status: 401,
        body: '{"type":"error","error":{"type":"authentication_error"}}',
      );
      addTearDown(upstream.close);
      final harness = await _GatewayHarness.start(adapter: _subscriptionAdapter(upstream));
      addTearDown(harness.dispose);

      final exchange = await harness.provider.request(1, path: '/v1/messages', body: '{}');
      await pumpEventQueue();

      expect(exchange.isDenied, isTrue);
      expect(harness.refusals.single.providerId, 'claude');
      expect(harness.authority.isRevoked, isTrue);
    });
  });
}

/// A real Claude adapter on a stored `setup-token`, so the classification under
/// test is the shipped one rather than a stand-in.
AnthropicMessagesAdapter _subscriptionAdapter(_RefusingUpstream upstream) => AnthropicMessagesAdapter(
  credential: ProviderCredentialSource(
    () => CredentialResolution.subscription(CredentialEntry.subscription(token: 'sk-ant-oat01-LIVE-SENTINEL')),
  ),
  upstream: upstream.uri,
);

/// An upstream that answers every request with one configured refusal.
final class _RefusingUpstream {
  new _(this._server);

  final HttpServer _server;

  Uri get uri => Uri.parse('http://${InternetAddress.loopbackIPv4.address}:${_server.port}');

  static Future<_RefusingUpstream> start({required int status, required String body}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = status;
      request.response.write(body);
      await request.response.close();
    });
    return _RefusingUpstream._(server);
  }

  Future<void> close() => _server.close(force: true);
}

/// A provider upstream that must never be reached.
final class _ForbiddenUpstream {
  new _(this._server);

  final HttpServer _server;

  var requestCount = 0;

  Uri get uri => Uri.parse('http://${InternetAddress.loopbackIPv4.address}:${_server.port}');

  static Future<_ForbiddenUpstream> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstream = _ForbiddenUpstream._(server);
    server.listen((request) async {
      upstream.requestCount++;
      request.response.statusCode = 200;
      await request.response.close();
    });
    return upstream;
  }

  Future<void> close() => _server.close(force: true);
}

/// One registered authority with a live provider pipe, ready to serve.
final class _GatewayHarness {
  new _(this.gateway, this.authority, this.providerChannel, this.providerPipe, this.denials, this.refusals);

  final HostGateway gateway;
  final GatewayAuthority authority;
  final FakeBridgeChannel providerChannel;
  final GatewayPipe providerPipe;
  final List<String> denials;
  final List<({String providerId, String detail, String? remediation})> refusals;

  FakeBridgeChannel get provider => providerChannel;

  static Future<_GatewayHarness> start({
    ProviderMediator? adapter,
    BridgeLimits limits = BridgeLimits.defaults,
    void Function(String authorityId)? onCredentialUnusable,
  }) async {
    final denials = <String>[];
    final refusals = <({String providerId, String detail, String? remediation})>[];
    final gateway = HostGateway(
      providerAdapters: {'claude': adapter ?? _EchoAdapter()},
      limits: limits,
      onDenied: (_, reason) => denials.add(reason),
      onCredentialRefused: (providerId, detail, {remediation}) =>
          refusals.add((providerId: providerId, detail: detail, remediation: remediation)),
      onCredentialUnusable: onCredentialUnusable == null
          ? null
          : (authority) async => onCredentialUnusable(authority.id),
    );
    final authority = gateway.register(principal: principal());
    final channel = FakeBridgeChannel(limits: limits);
    final pipe = gateway.attach(authority, BridgeSurface.provider, channel);
    await channel.handshake(BridgeSurface.provider);
    await authority.ready;
    return _GatewayHarness._(gateway, authority, channel, pipe, denials, refusals);
  }

  Future<void> dispose() => gateway.dispose();
}

/// Stands in for the adapter's upstream classification: the host-held
/// credential is gone and no retry repairs it.
final class _CredentialFailureAdapter implements ProviderMediator {
  new(this.remediation);

  final String remediation;

  @override
  BridgeSurface get surface => BridgeSurface.provider;

  @override
  Future<GatewayResponse> handle(GatewayRequest request) async {
    await request.readBody(maxBytes: 4096);
    throw GatewayCredentialUnusable(providerId: 'claude', remediation: remediation);
  }

  @override
  String? get unavailableReason => null;

  @override
  String? get credentialRemediation => null;

  @override
  Future<void> dispose() async {}
}

/// A usage limit: transient, not a credential fault, so the authority lives on.
final class _RateLimitedAdapter implements ProviderMediator {
  @override
  BridgeSurface get surface => BridgeSurface.provider;

  @override
  Future<GatewayResponse> handle(GatewayRequest request) async {
    await request.readBody(maxBytes: 4096);
    throw const GatewayDenied(status: 429, reason: 'provider usage limit reached');
  }

  @override
  String? get unavailableReason => null;

  @override
  String? get credentialRemediation => null;

  @override
  Future<void> dispose() async {}
}

/// Echoes the request body, standing in for a provider upstream.
final class _EchoAdapter implements ProviderMediator {
  @override
  BridgeSurface get surface => BridgeSurface.provider;

  @override
  Future<GatewayResponse> handle(GatewayRequest request) async {
    final body = await request.readBody(maxBytes: 4096);
    return GatewayResponse(status: 200, body: Stream.value(utf8.encode('echo:$body')));
  }

  @override
  String? get unavailableReason => null;

  @override
  String? get credentialRemediation => null;

  @override
  Future<void> dispose() async {}
}

/// Answers with the calling principal's session, proving pipe-bound identity.
final class _PrincipalEchoAdapter implements ProviderMediator {
  @override
  BridgeSurface get surface => BridgeSurface.provider;

  @override
  Future<GatewayResponse> handle(GatewayRequest request) async {
    await request.readBody(maxBytes: 4096);
    return GatewayResponse(status: 200, body: Stream.value(utf8.encode(request.principal.sessionId)));
  }

  @override
  String? get unavailableReason => null;

  @override
  String? get credentialRemediation => null;

  @override
  Future<void> dispose() async {}
}

/// Holds every request open until released, for concurrency probes.
final class _BlockingAdapter implements ProviderMediator {
  final Completer<String> _gate = Completer<String>();

  void release(String body) => _gate.complete(body);

  @override
  BridgeSurface get surface => BridgeSurface.provider;

  @override
  Future<GatewayResponse> handle(GatewayRequest request) async {
    await request.readBody(maxBytes: 4096);
    final body = await _gate.future;
    return GatewayResponse(status: 200, body: Stream.value(utf8.encode(body)));
  }

  @override
  String? get unavailableReason => null;

  @override
  String? get credentialRemediation => null;

  @override
  Future<void> dispose() async {}
}
