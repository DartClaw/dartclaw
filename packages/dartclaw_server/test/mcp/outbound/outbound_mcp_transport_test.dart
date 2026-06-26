import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_config/dartclaw_config.dart' show McpNetworkClass;
import 'package:dartclaw_server/src/mcp/outbound/http_mcp_transport.dart';
import 'package:dartclaw_server/src/mcp/outbound/stdio_mcp_transport.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show CapturingFakeProcess;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('outbound MCP transports', () {
    test('S01 stdio transport completes initialize/tools/list/tools/call over NDJSON JSON-RPC', () async {
      late CapturingFakeProcess process;
      final transport = await StdioMcpTransport.start(
        'fake-mcp "--profile=local test"',
        processStarter: (executable, arguments, {environment = const {}}) async {
          process = CapturingFakeProcess();
          expect(executable, 'fake-mcp');
          expect(arguments, ['--profile=local test']);
          expect(environment, isEmpty);
          return process;
        },
      );

      final initialize = transport.sendRequest(
        'initialize',
        const {},
        timeout: const Duration(milliseconds: 200),
        maxResponseBytes: 1024,
      );
      await _respondToNext(process, {
        'protocolVersion': '2025-03-26',
        'serverInfo': {'name': 'fake'},
      });
      expect(await initialize, containsPair('protocolVersion', '2025-03-26'));

      await transport.sendNotification(
        'notifications/initialized',
        const {},
        timeout: const Duration(milliseconds: 200),
        maxResponseBytes: 1024,
      );

      final list = transport.sendRequest(
        'tools/list',
        const {},
        timeout: const Duration(milliseconds: 200),
        maxResponseBytes: 1024,
      );
      await _respondToNext(process, {
        'tools': [
          {'name': 'echo'},
        ],
      });
      expect((await list)['tools'], hasLength(1));

      final call = transport.sendRequest(
        'tools/call',
        {
          'name': 'echo',
          'arguments': {'text': 'hi'},
        },
        timeout: const Duration(milliseconds: 200),
        maxResponseBytes: 1024,
      );
      await _respondToNext(process, {
        'content': [
          {'type': 'text', 'text': 'hi'},
        ],
      });
      expect(((await call)['content'] as List).single['text'], 'hi');
      expect(process.capturedStdinJson.map((request) => request['method']), [
        'initialize',
        'notifications/initialized',
        'tools/list',
        'tools/call',
      ]);
      expect(process.capturedStdinJson[1], isNot(contains('id')));
      await transport.close();
    });

    test('S06 stdio transport rejects malformed, wrong-id, and missing-result responses', () async {
      late CapturingFakeProcess process;
      final transport = await StdioMcpTransport.start(
        'fake-mcp',
        processStarter: (executable, arguments, {environment = const {}}) async {
          process = CapturingFakeProcess();
          return process;
        },
      );

      Future<void> expectProtocolFailure(Map<String, dynamic> response) async {
        final call = transport.sendRequest(
          'tools/call',
          const {},
          timeout: const Duration(milliseconds: 200),
          maxResponseBytes: 1024,
        );
        while (process.capturedStdinJson.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        process.emitStdout(jsonEncode(response));
        await expectLater(call, throwsA(predicate((error) => error.toString().contains('malformed_response'))));
      }

      await expectProtocolFailure({
        'id': 1,
        'result': {'content': []},
      });
      await expectProtocolFailure({
        'jsonrpc': '2.0',
        'id': 999,
        'result': {'content': []},
      });
      await expectProtocolFailure({'jsonrpc': '2.0', 'id': 3});
      await transport.close();
    });

    test('S06 stdio transport ignores notifications before the matching response', () async {
      late CapturingFakeProcess process;
      final transport = await StdioMcpTransport.start(
        'fake-mcp',
        processStarter: (executable, arguments, {environment = const {}}) async {
          process = CapturingFakeProcess();
          return process;
        },
      );

      final call = transport.sendRequest(
        'tools/call',
        const {},
        timeout: const Duration(milliseconds: 200),
        maxResponseBytes: 1024,
      );
      while (process.capturedStdinJson.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      final id = process.capturedStdinJson.last['id'];
      process
        ..emitStdout(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'notifications/progress',
            'params': {'progress': 1},
          }),
        )
        ..emitStdout(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'result': {'content': []},
          }),
        );

      expect(await call, containsPair('content', isEmpty));
      await transport.close();
    });

    test('S06 stdio transport rejects oversized response before a full line is buffered', () async {
      late CapturingFakeProcess process;
      final transport = await StdioMcpTransport.start(
        'fake-mcp',
        processStarter: (executable, arguments, {environment = const {}}) async {
          process = CapturingFakeProcess();
          return process;
        },
      );

      final call = transport.sendRequest(
        'tools/call',
        const {},
        timeout: const Duration(milliseconds: 200),
        maxResponseBytes: 16,
      );
      while (process.capturedStdinJson.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      process.emitStdout('{"jsonrpc":"2.0","id":1,"result":{');

      await expectLater(call, throwsA(predicate((error) => error.toString().contains('response_too_large'))));
      await transport.close();
    });

    test('S02 HTTP transport completes Streamable HTTP JSON-RPC round-trip', () async {
      final methods = <String>[];
      final transport = HttpMcpTransport(
        'http://localhost/mcp',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          methods.add(body['method'] as String);
          expect(request.headers['accept'], 'application/json, text/event-stream');
          final result = switch (body['method']) {
            'initialize' => {
              'protocolVersion': '2025-03-26',
              'serverInfo': {'name': 'fake'},
            },
            'tools/list' => {
              'tools': [
                {'name': 'echo'},
              ],
            },
            'tools/call' => {
              'content': [
                {'type': 'text', 'text': (body['params'] as Map)['arguments']['text']},
              ],
            },
            _ => <String, dynamic>{},
          };
          return http.Response(jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}), 200);
        }),
      );

      await transport.sendRequest(
        'initialize',
        const {},
        timeout: const Duration(milliseconds: 50),
        maxResponseBytes: 1024,
      );
      await transport.sendRequest(
        'tools/list',
        const {},
        timeout: const Duration(milliseconds: 50),
        maxResponseBytes: 1024,
      );
      final result = await transport.sendRequest(
        'tools/call',
        {
          'name': 'echo',
          'arguments': {'text': 'hi'},
        },
        timeout: const Duration(milliseconds: 50),
        maxResponseBytes: 1024,
      );

      expect(methods, ['initialize', 'tools/list', 'tools/call']);
      expect((result['content'] as List).single['text'], 'hi');
      await transport.close();
    });

    test('S02 HTTP transport replays session and protocol headers and decodes SSE response frames', () async {
      final methods = <String>[];
      final transport = HttpMcpTransport(
        'http://localhost/mcp',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final method = body['method'] as String;
          methods.add(method);
          expect(request.headers['accept'], 'application/json, text/event-stream');
          if (method == 'initialize') {
            expect(request.headers, isNot(contains('mcp-session-id')));
            expect(request.headers, isNot(contains('mcp-protocol-version')));
            return http.Response(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': body['id'],
                'result': {
                  'protocolVersion': '2025-03-26',
                  'serverInfo': {'name': 'fake'},
                },
              }),
              200,
              headers: {'content-type': 'application/json', 'mcp-session-id': 'session-1'},
            );
          }
          expect(request.headers['mcp-session-id'], 'session-1');
          expect(request.headers['mcp-protocol-version'], '2025-03-26');
          if (method == 'notifications/initialized') {
            expect(body, isNot(contains('id')));
            return http.Response('', 202);
          }
          return http.Response(
            'event: message\n'
            'data: ${jsonEncode({
              'jsonrpc': '2.0',
              'method': 'notifications/progress',
              'params': {'progress': 1},
            })}\n\n'
            'event: message\n'
            'data: ${jsonEncode({
              'jsonrpc': '2.0',
              'id': body['id'],
              'result': {
                'tools': [
                  {'name': 'echo'},
                ],
              },
            })}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );

      await transport.sendRequest(
        'initialize',
        const {},
        timeout: const Duration(milliseconds: 50),
        maxResponseBytes: 2048,
      );
      await transport.sendNotification(
        'notifications/initialized',
        const {},
        timeout: const Duration(milliseconds: 50),
        maxResponseBytes: 2048,
      );
      final result = await transport.sendRequest(
        'tools/list',
        const {},
        timeout: const Duration(milliseconds: 50),
        maxResponseBytes: 2048,
      );

      expect(methods, ['initialize', 'notifications/initialized', 'tools/list']);
      expect((result['tools'] as List).single['name'], 'echo');
      await transport.close();
    });

    test('S02 HTTP transport completes when an open SSE stream emits the matching response', () async {
      final streams = <StreamController<List<int>>>[];
      final transport = HttpMcpTransport(
        'http://localhost/mcp',
        client: MockClient.streaming((request, bodyStream) async {
          final requestBody = await utf8.decodeStream(bodyStream);
          final body = jsonDecode(requestBody) as Map<String, dynamic>;
          final controller = StreamController<List<int>>();
          streams.add(controller);
          scheduleMicrotask(() {
            controller.add(
              utf8.encode(
                'event: message\n'
                'data: ${jsonEncode({
                  'jsonrpc': '2.0',
                  'id': body['id'],
                  'result': {
                    'content': [
                      {'type': 'text', 'text': 'hi'},
                    ],
                  },
                })}\n\n',
              ),
            );
          });
          return http.StreamedResponse(controller.stream, 200, headers: {'content-type': 'text/event-stream'});
        }),
      );

      final result = await transport.sendRequest(
        'tools/call',
        const {},
        timeout: const Duration(milliseconds: 200),
        maxResponseBytes: 2048,
      );

      expect(((result['content'] as List).single as Map)['text'], 'hi');
      expect(streams.single.isClosed, isFalse);
      await streams.single.close();
      await transport.close();
    });

    test('S06 HTTP transport times out open SSE streams that never emit the matching response', () async {
      Timer? keepaliveTimer;
      StreamController<List<int>>? stream;
      final transport = HttpMcpTransport(
        'http://localhost/mcp',
        client: MockClient.streaming((request, bodyStream) async {
          await bodyStream.drain<void>();
          final controller = StreamController<List<int>>();
          stream = controller;
          keepaliveTimer = Timer.periodic(const Duration(milliseconds: 2), (_) {
            if (!controller.isClosed) {
              controller.add(
                utf8.encode(
                  'event: message\n'
                  'data: ${jsonEncode({
                    'jsonrpc': '2.0',
                    'method': 'notifications/progress',
                    'params': {'progress': 1},
                  })}\n\n',
                ),
              );
            }
          });
          return http.StreamedResponse(controller.stream, 200, headers: {'content-type': 'text/event-stream'});
        }),
      );

      await expectLater(
        transport.sendRequest(
          'tools/call',
          const {},
          timeout: const Duration(milliseconds: 20),
          maxResponseBytes: 4096,
        ),
        throwsA(predicate((error) => error.toString().contains('timeout'))),
      );

      keepaliveTimer?.cancel();
      await stream?.close();
      await transport.close();
    });

    test('S06 HTTP transport times out trickling JSON responses before stream close', () async {
      Timer? trickleTimer;
      StreamController<List<int>>? stream;
      final transport = HttpMcpTransport(
        'http://localhost/mcp',
        client: MockClient.streaming((request, bodyStream) async {
          await bodyStream.drain<void>();
          final controller = StreamController<List<int>>();
          stream = controller;
          trickleTimer = Timer.periodic(const Duration(milliseconds: 2), (_) {
            if (!controller.isClosed) {
              controller.add(utf8.encode(' '));
            }
          });
          return http.StreamedResponse(controller.stream, 200, headers: {'content-type': 'application/json'});
        }),
      );

      await expectLater(
        transport.sendRequest(
          'tools/call',
          const {},
          timeout: const Duration(milliseconds: 20),
          maxResponseBytes: 4096,
        ),
        throwsA(predicate((error) => error.toString().contains('timeout'))),
      );

      trickleTimer?.cancel();
      await stream?.close();
      await transport.close();
    });

    test('S06 HTTP transport times out trickling notification responses before stream close', () async {
      Timer? trickleTimer;
      StreamController<List<int>>? stream;
      final transport = HttpMcpTransport(
        'http://localhost/mcp',
        client: MockClient.streaming((request, bodyStream) async {
          await bodyStream.drain<void>();
          final controller = StreamController<List<int>>();
          stream = controller;
          trickleTimer = Timer.periodic(const Duration(milliseconds: 2), (_) {
            if (!controller.isClosed) {
              controller.add(utf8.encode(' '));
            }
          });
          return http.StreamedResponse(controller.stream, 202, headers: {'content-type': 'application/json'});
        }),
      );

      await expectLater(
        transport.sendNotification(
          'notifications/initialized',
          const {},
          timeout: const Duration(milliseconds: 20),
          maxResponseBytes: 4096,
        ),
        throwsA(predicate((error) => error.toString().contains('timeout'))),
      );

      trickleTimer?.cancel();
      await stream?.close();
      await transport.close();
    });

    test('S03 HTTP transport rejects non-TLS endpoints when TLS is required', () async {
      final transport = HttpMcpTransport(
        'http://localhost/mcp',
        requireTls: true,
        client: MockClient((request) async {
          fail('request must not be sent when TLS is required');
        }),
      );

      await expectLater(
        transport.sendRequest(
          'tools/call',
          const {},
          timeout: const Duration(milliseconds: 50),
          maxResponseBytes: 1024,
        ),
        throwsA(predicate((error) => error.toString().contains('tls_required'))),
      );
      await transport.close();
    });

    test('S03 HTTP transport denies redirects to non-allowlisted hosts without resending body', () async {
      var requests = 0;
      final transport = HttpMcpTransport(
        'https://allowed.example/mcp',
        allowedRedirectHosts: const ['allowed.example'],
        requireTls: true,
        client: MockClient((request) async {
          requests++;
          return http.Response('', 302, headers: {'location': 'https://evil.example/mcp'});
        }),
      );

      await expectLater(
        transport.sendRequest(
          'tools/call',
          {
            'name': 'echo',
            'arguments': {'secret': 'do-not-forward'},
          },
          timeout: const Duration(milliseconds: 50),
          maxResponseBytes: 1024,
        ),
        throwsA(predicate((error) => error.toString().contains('redirect_denied'))),
      );
      expect(requests, 1);
      await transport.close();
    });

    test('S-01 stdio transport does not receive credentials by default', () async {
      late List<String> capturedArguments;
      late Map<String, String> capturedEnvironment;
      final transport = await StdioMcpTransport.start(
        'fake-mcp --stdio',
        processStarter: (executable, arguments, {environment = const {}}) async {
          capturedArguments = arguments;
          capturedEnvironment = environment;
          return CapturingFakeProcess();
        },
      );

      expect(capturedArguments, ['--stdio']);
      expect(capturedArguments.join(' '), isNot(contains('secret-token')));
      expect(capturedEnvironment, isEmpty);
      await transport.close();
    });

    test('S-01 HTTP transport applies bearer credential header without adding it to the body', () async {
      late http.BaseRequest captured;
      final transport = HttpMcpTransport(
        'https://allowed.example/mcp',
        requireTls: true,
        credentialSecret: 'secret-token',
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'result': {'tools': []},
            }),
            200,
          );
        }),
      );

      await transport.sendRequest(
        'tools/list',
        const {},
        timeout: const Duration(milliseconds: 50),
        maxResponseBytes: 1024,
      );

      expect(captured.headers['authorization'], 'Bearer secret-token');
      expect((captured as http.Request).body, isNot(contains('secret-token')));
      await transport.close();
    });

    test('ARCH-002 public HTTP transport rejects blocked-range host before sending request', () async {
      final transport = HttpMcpTransport(
        'https://127.0.0.1/mcp',
        requireTls: true,
        networkClass: McpNetworkClass.public,
        client: MockClient((request) async {
          fail('request must not be sent to a blocked public-network host');
        }),
      );

      await expectLater(
        transport.sendRequest(
          'tools/list',
          const {},
          timeout: const Duration(milliseconds: 50),
          maxResponseBytes: 1024,
        ),
        throwsA(predicate((error) => error.toString().contains('network_denied'))),
      );
      await transport.close();
    });
  });
}

Future<void> _respondToNext(CapturingFakeProcess process, Map<String, dynamic> result) async {
  while (process.capturedStdinJson.isEmpty) {
    await Future<void>.delayed(Duration.zero);
  }
  final request = process.capturedStdinJson.last;
  process.emitStdout(jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}));
}
