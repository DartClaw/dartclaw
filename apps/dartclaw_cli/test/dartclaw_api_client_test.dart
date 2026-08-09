import 'dart:convert';

import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig, GatewayConfig, ServerConfig;
import 'package:test/test.dart';

import 'helpers/fake_api_transport.dart';

void main() {
  group('DartclawApiClient', () {
    test('resolveServerUri defaults to loopback config port', () {
      final config = DartclawConfig(server: ServerConfig(port: 4123));
      final uri = DartclawApiClient.resolveServerUri(config: config);
      expect(uri.toString(), 'http://localhost:4123');
    });

    test('resolveServerUri accepts explicit remote server overrides', () {
      final config = DartclawConfig(server: ServerConfig(port: 4123));
      final uri = DartclawApiClient.resolveServerUri(config: config, serverOverride: 'https://example.com:4000');
      expect(uri.toString(), 'https://example.com:4000');
    });

    test('resolveServerUri keeps the remote default port when an explicit scheme override omits one', () {
      final config = DartclawConfig(server: ServerConfig(port: 4123));
      final uri = DartclawApiClient.resolveServerUri(config: config, serverOverride: 'https://example.com');
      expect(uri.toString(), 'https://example.com');
      expect(uri.port, 443);
    });

    test('request includes bearer token when present', () async {
      final transport = FakeApiTransport(
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
      final transport = FakeApiTransport(
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

    test('tokenOverride forces bearer auth even when local config auth_mode is none', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          _jsonResponse(200, {'ok': true}),
        ],
      );
      final config = DartclawConfig(
        server: ServerConfig(dataDir: '/tmp/dartclaw-api-client-remote-token'),
        gateway: const GatewayConfig(authMode: 'none'),
      );
      final client = DartclawApiClient.fromConfig(config: config, tokenOverride: 'remote-token', transport: transport);

      await client.get('/api/tasks');

      expect(transport.requests.single.headers['authorization'], 'Bearer remote-token');
    });

    test('401 responses produce token guidance without leaking the token', () async {
      final transport = FakeApiTransport(
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

    test('404 responses preserve a server error message when provided', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          _jsonResponse(404, {
            'error': {'code': 'NOT_FOUND', 'message': 'Restart the server before running this job.'},
          }),
        ],
      );
      final client = DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport);

      expect(
        () => client.postObject('/api/scheduling/jobs/new-job/run'),
        throwsA(
          isA<DartclawApiException>()
              .having((error) => error.message, 'message', 'Restart the server before running this job.')
              .having((error) => error.code, 'code', 'NOT_FOUND'),
        ),
      );
    });

    for (final body in ['Not Found', '<html><body>Not Found</body></html>']) {
      test('non-JSON 404 response uses compatibility guidance for ${body.startsWith('<') ? 'HTML' : 'text'}', () {
        final transport = FakeApiTransport(
          sendResponses: [ApiResponse(statusCode: 404, headers: const {}, body: Stream.value(utf8.encode(body)))],
        );
        final client = DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport);

        expect(
          () => client.get('/api/newer-endpoint'),
          throwsA(
            isA<DartclawApiException>()
                .having((error) => error.statusCode, 'statusCode', 404)
                .having((error) => error.message, 'message', contains('versions may be out of sync')),
          ),
        );
      });
    }

    test('probeHealth treats 401 as reachable when requested', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          _jsonResponse(401, {'error': 'Unauthorized'}),
        ],
      );
      final client = DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport);

      final reachable = await client.probeHealth();

      expect(reachable, isTrue);
    });

    test('streamEvents parses multi-line data frames', () async {
      final transport = FakeApiTransport(
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
      final transport = FakeApiTransport(
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

ApiResponse _jsonResponse(int statusCode, Object body) {
  return ApiResponse(
    statusCode: statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
    body: Stream.value(utf8.encode(jsonEncode(body))),
  );
}
