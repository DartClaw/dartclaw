import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_bridge/dartclaw_bridge.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
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

    test('rejects containerized Claude at admission when the host holds no API key', () {
      // OAuth/setup-token: the host CLI is logged in, but no key exists for the
      // adapter to mediate with. Nothing may be admitted on that promise.
      final gateway = HostGateway(providerAdapters: {'claude': AnthropicMessagesAdapter(apiKey: () => null)});

      expect(
        () => gateway.register(principal: principal(providerId: 'claude')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('no host-held credential'),
              contains('ANTHROPIC_API_KEY'),
              contains('execution: host'),
              contains('OAuth'),
            ),
          ),
        ),
      );
      expect(gateway.liveAuthorityCount, 0);
    });

    test('admits containerized Claude once a host API key exists', () {
      final gateway = HostGateway(providerAdapters: {'claude': AnthropicMessagesAdapter(apiKey: () => 'sk-ant-host')});

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
}

/// One registered authority with a live provider pipe, ready to serve.
final class _GatewayHarness {
  _GatewayHarness._(this.gateway, this.authority, this.providerChannel, this.providerPipe, this.denials);

  final HostGateway gateway;
  final GatewayAuthority authority;
  final FakeBridgeChannel providerChannel;
  final GatewayPipe providerPipe;
  final List<String> denials;

  FakeBridgeChannel get provider => providerChannel;

  static Future<_GatewayHarness> start({ProviderMediator? adapter, BridgeLimits limits = BridgeLimits.defaults}) async {
    final denials = <String>[];
    final gateway = HostGateway(
      providerAdapters: {'claude': adapter ?? _EchoAdapter()},
      limits: limits,
      onDenied: (_, reason) => denials.add(reason),
    );
    final authority = gateway.register(principal: principal());
    final channel = FakeBridgeChannel(limits: limits);
    final pipe = gateway.attach(authority, BridgeSurface.provider, channel);
    await channel.handshake(BridgeSurface.provider);
    await authority.ready;
    return _GatewayHarness._(gateway, authority, channel, pipe, denials);
  }

  Future<void> dispose() => gateway.dispose();
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
  Future<void> dispose() async {}
}
