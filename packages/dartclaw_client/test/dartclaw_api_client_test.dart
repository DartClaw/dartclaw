import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_client/dartclaw_client.dart';
import 'package:test/test.dart';

void main() {
  group('DartclawApiClient', () {
    test('connection refused carries a transport code without HTTP status', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final client = DartclawApiClient(baseUri: Uri.parse('http://127.0.0.1:$port'));

      await expectLater(
        client.get('/health'),
        throwsA(
          isA<DartclawApiException>()
              .having((error) => error.code, 'code', 'CONNECTION_REFUSED')
              .having((error) => error.statusCode, 'statusCode', isNull),
        ),
      );
    });

    test('getObject keeps default 2xx acceptance but can require an exact status', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          _jsonResponse(201, {'ok': true}),
          _jsonResponse(201, {'ok': true}),
        ],
      );
      final client = DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport);
      expect(await client.getObject('/health'), {'ok': true});
      await expectLater(
        client.getObject('/health', expectedStatusCode: 200),
        throwsA(
          isA<DartclawApiException>()
              .having((e) => e.code, 'code', 'INVALID_RESPONSE')
              .having((e) => e.statusCode, 'statusCode', 201),
        ),
      );
    });

    test('request carries the bearer token and returns the decoded JSON body', () async {
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

      final body = await client.get('/api/tasks');

      expect(transport.requests.single.headers['authorization'], 'Bearer secret-token');
      expect(body, {'ok': true});
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
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('dartclaw token show'),
                  contains('dartclaw token rotate'),
                  contains('gateway.token'),
                  contains('--token'),
                ),
              )
              .having((e) => e.message, 'message', isNot(contains('secret-token')))
              .having((e) => e.statusCode, 'statusCode', 401),
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

class FakeApiTransport implements ApiTransport {
  final Queue<ApiResponse> _sendResponses;
  final Queue<ApiResponse> _streamResponses;
  final List<ApiRequest> requests = <ApiRequest>[];

  new({List<ApiResponse> sendResponses = const [], List<ApiResponse> streamResponses = const []})
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
