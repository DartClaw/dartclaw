import 'dart:collection';
import 'dart:convert';

import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig, GatewayConfig, ServerConfig;
import 'package:test/test.dart';

void main() {
  group('DartclawApiClient', () {
    test('resolveServerUri defaults to loopback config port', () {
      final config = DartclawConfig(server: ServerConfig(port: 4123));
      final uri = DartclawApiClient.resolveServerUri(config: config);
      expect(uri.toString(), 'http://localhost:4123');
    });

    test('resolveServerUri rejects non-loopback hosts', () {
      final config = DartclawConfig(server: ServerConfig(port: 4123));
      expect(
        () => DartclawApiClient.resolveServerUri(config: config, serverOverride: 'https://example.com:4000'),
        throwsArgumentError,
      );
    });

    test('request includes bearer token when present', () async {
      final transport = _FakeTransport(
        sendResponses: [
          _jsonResponse(200, {'ok': true}),
        ],
      );
      final client = DartclawApiClient(
        baseUri: Uri.parse('http://localhost:3333'),
        token: 'secret-token',
        transport: transport,
      );

      await client.get('/api/tasks');

      expect(transport.requests.single.headers['authorization'], 'Bearer secret-token');
    });

    test('request omits bearer token when auth mode is none', () async {
      final transport = _FakeTransport(
        sendResponses: [
          _jsonResponse(200, {'ok': true}),
        ],
      );
      final config = DartclawConfig(
        server: ServerConfig(dataDir: '/tmp/dartclaw-api-client-auth-none'),
        gateway: const GatewayConfig(authMode: 'none'),
      );
      final client = DartclawApiClient.fromConfig(config: config, transport: transport);

      await client.get('/api/tasks');

      expect(transport.requests.single.headers.containsKey('authorization'), isFalse);
    });

    test('401 responses produce token guidance without leaking the token', () async {
      final transport = _FakeTransport(
        sendResponses: [
          _jsonResponse(401, {
            'error': {'code': 'AUTH_REQUIRED', 'message': 'Unauthorized'},
          }),
        ],
      );
      final client = DartclawApiClient(
        baseUri: Uri.parse('http://localhost:3333'),
        token: 'secret-token',
        transport: transport,
      );

      expect(
        () => client.get('/api/tasks'),
        throwsA(
          isA<DartclawApiException>()
              .having((e) => e.message, 'message', contains('token'))
              .having((e) => e.message, 'message', isNot(contains('secret-token'))),
        ),
      );
    });

    test('probeHealth treats 401 as reachable when requested', () async {
      final transport = _FakeTransport(
        sendResponses: [
          _jsonResponse(401, {'error': 'Unauthorized'}),
        ],
      );
      final client = DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport);

      final reachable = await client.probeHealth();

      expect(reachable, isTrue);
    });

    test('streamEvents parses multi-line data frames', () async {
      final transport = _FakeTransport(
        streamResponses: [
          ApiResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: Stream.fromIterable([
              utf8.encode('data: {"type":"connected",\n'),
              utf8.encode('data: "runId":"run-1"}\n\n'),
            ]),
          ),
        ],
      );
      final client = DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport);

      final events = await client.streamEvents('/events').take(1).toList();

      expect(events.single['type'], 'connected');
      expect(events.single['runId'], 'run-1');
    });

    test('streamEvents reconnects after a disconnect when the callback allows it', () async {
      final transport = _FakeTransport(
        streamResponses: [
          ApiResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: const Stream.empty(),
          ),
          ApiResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: Stream.value(utf8.encode('data: {"type":"workflow_status_changed","newStatus":"completed"}\n\n')),
          ),
        ],
      );
      final client = DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport);
      final attempts = <int>[];

      final events = await client
          .streamEvents(
            '/events',
            onDisconnect: (attempt) async {
              attempts.add(attempt);
              return attempt == 1;
            },
          )
          .take(1)
          .toList();

      expect(attempts, [1]);
      expect(events.single['newStatus'], 'completed');
    });
  });
}

class _FakeTransport implements ApiTransport {
  final Queue<ApiResponse> _sendResponses;
  final Queue<ApiResponse> _streamResponses;
  final List<ApiRequest> requests = <ApiRequest>[];

  _FakeTransport({List<ApiResponse> sendResponses = const [], List<ApiResponse> streamResponses = const []})
    : _sendResponses = Queue<ApiResponse>.of(sendResponses),
      _streamResponses = Queue<ApiResponse>.of(streamResponses);

  @override
  Future<ApiResponse> send(ApiRequest request) async {
    requests.add(request);
    return _sendResponses.removeFirst();
  }

  @override
  Future<ApiResponse> openStream(ApiRequest request) async {
    requests.add(request);
    return _streamResponses.removeFirst();
  }
}

ApiResponse _jsonResponse(int statusCode, Object body) {
  return ApiResponse(
    statusCode: statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
    body: Stream.value(utf8.encode(jsonEncode(body))),
  );
}
