@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/src/harness/codex_harness.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real Codex CLI honors the user input override and retains thread-start guidance after fresh-process resume',
    () async {
      final directory = Directory.systemTemp.createTempSync('codex_user_input_cli');
      addTearDown(() => directory.deleteSync(recursive: true));
      final home = Directory('${directory.path}/home')..createSync();
      final requests = <Map<String, dynamic>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
        requests.add(body);
        final index = requests.length;
        final response = {
          'id': 'resp_$index',
          'object': 'response',
          'created_at': 0,
          'status': 'completed',
          'model': body['model'] ?? 'gpt-6-sol',
          'output': [
            {
              'id': 'msg_$index',
              'type': 'message',
              'role': 'assistant',
              'content': [
                {'type': 'output_text', 'text': 'Probe complete.', 'annotations': []},
              ],
              'status': 'completed',
            },
          ],
          'usage': {'input_tokens': 10, 'output_tokens': 10, 'total_tokens': 20},
        };
        request.response.headers.contentType = ContentType('text', 'event-stream');
        for (final event in [
          'response.created',
          'response.output_item.added',
          'response.output_item.done',
          'response.completed',
        ]) {
          final data = switch (event) {
            'response.created' || 'response.completed' => {'type': event, 'response': response},
            _ => {'type': event, 'output_index': 0, 'item': (response['output'] as List).single},
          };
          request.response.write('event: $event\ndata: ${jsonEncode(data)}\n\n');
          await request.response.flush();
        }
        await request.response.close();
      });
      final config =
          '''
model = "gpt-6-sol"
model_provider = "mock"
approval_policy = "never"
sandbox_mode = "danger-full-access"
[model_providers.mock]
name = "Mock"
base_url = "http://127.0.0.1:${server.port}/v1"
env_key = "OPENAI_API_KEY"
wire_api = "responses"
[features]
plugins = false
[tools]
experimental_request_user_input = { enabled = true }
''';
      final configFile = File('${home.path}/config.toml')..writeAsStringSync(config);
      final argsSeen = <List<String>>[];
      CodexHarness makeHarness() => CodexHarness(
        cwd: directory.path,
        executable: 'codex',
        environment: {...Platform.environment, 'CODEX_HOME': home.path, 'OPENAI_API_KEY': 'mock-key'},
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) {
          argsSeen.add(List<String>.from(args));
          return Process.start(
            exe,
            args,
            workingDirectory: workingDirectory,
            environment: environment,
            includeParentEnvironment: includeParentEnvironment,
          );
        },
        turnTimeout: const Duration(seconds: 90),
      );

      final first = makeHarness();
      await first.start();
      final initial = await first.turn(
        sessionId: 'first',
        messages: const [
          {'role': 'user', 'content': 'Probe available tools.'},
        ],
        systemPrompt: 'Caller instructions',
        requestProviderSessionResume: true,
      );
      expect(initial.stopReason, 'completed', reason: '${initial.error}');
      final threadId = initial.providerSessionId;
      expect(threadId, isNotNull);
      await first.dispose();

      final resumed = makeHarness();
      addTearDown(resumed.dispose);
      await resumed.start();
      final second = await resumed.turn(
        sessionId: 'resumed',
        messages: const [
          {'role': 'user', 'content': 'Probe resumed tool list.'},
        ],
        systemPrompt: 'Caller instructions',
        providerSessionId: threadId,
      );
      expect(second.stopReason, 'completed', reason: '${second.error}');
      expect(argsSeen, hasLength(2));
      for (final args in argsSeen) {
        expect(args, containsAllInOrder(['-c', 'tools.experimental_request_user_input.enabled=false']));
      }
      expect(configFile.readAsStringSync(), config);
      expect(requests, hasLength(2));
      for (final request in requests) {
        final toolNames = (request['tools'] as List? ?? const []).whereType<Map<String, dynamic>>().map(
          (tool) => tool['name'],
        );
        expect(toolNames, isNot(contains('request_user_input')));
        final input = jsonEncode(request['input']);
        expect(input, contains('DartClaw cannot collect answers from native mid-turn question tools'));
        expect(input, contains('Caller instructions'));
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
