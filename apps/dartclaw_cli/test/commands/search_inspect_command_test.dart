import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/search_command.dart';
import 'package:dartclaw_cli/src/commands/search_inspect_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_client/dartclaw_client.dart';
import 'package:test/test.dart';

import '../helpers/fake_api_transport.dart';
import '../helpers/fake_exit.dart';

void main() {
  for (final corpus in ['memory', 'conversation']) {
    for (final json in [false, true]) {
      test('$corpus ${json ? 'JSON stays unchanged' : 'renders provenance and nullable evidence'}', () async {
        final response = {
          'corpus': corpus,
          'results': [
            {
              'documentId': 'doc',
              'chunkIndex': 0,
              'role': 'user',
              'snippet': 'bounded',
              'score': -.03,
              if (corpus == 'memory') 'locator': 'locator' else ...{'sessionId': 'session', 'messageId': 'message'},
            },
          ],
          'diagnostics': {
            'candidates': [
              {
                'documentId': 'doc',
                'chunkIndex': 0,
                'keywordRank': null,
                'vectorRank': 1,
                'keywordContribution': 0.0,
                'vectorContribution': .03,
                'fusedScore': .03,
                'sourceLayer': corpus,
              },
              {
                'documentId': 'keyword',
                'chunkIndex': 0,
                'keywordRank': 1,
                'vectorRank': null,
                'keywordContribution': .01,
                'vectorContribution': 0.0,
                'fusedScore': .01,
                'sourceLayer': corpus,
              },
            ],
            'unembeddedCount': 2,
            'degradations': [
              {'layer': corpus, 'reason': 'vector_unavailable'},
            ],
          },
        };
        final transport = FakeApiTransport(sendResponses: [jsonResponse(200, response)]);
        final output = <String>[];
        final command = SearchInspectCommand(
          apiClient: DartclawApiClient(
            baseUri: Uri.parse('http://localhost:3333'),
            token: 'fixture-token',
            transport: transport,
          ),
          writeLine: output.add,
        );
        await (DartclawRunner()..addCommand(SearchCommand(inspect: command))).run([
          'search',
          'inspect',
          '--corpus',
          corpus,
          '--query',
          ' needle ',
          '--limit',
          '3',
          if (json) '--json',
        ]);
        final request = transport.requests.single;
        expect(request.method, 'POST');
        expect(request.uri.path, '/api/search/inspect');
        expect(request.headers['authorization'], 'Bearer fixture-token');
        expect(jsonDecode(request.body!), {'corpus': corpus, 'query': ' needle ', 'limit': 3});
        if (json) {
          expect(jsonDecode(output.single), response);
        } else {
          final rendered = output.join('\n');
          for (final expected in [
            corpus == 'memory' ? 'locator' : 'session/message',
            'keyword=- vector=1',
            'keyword=1 vector=-',
            'contributions=0.0+0.03',
            'fused=0.03',
            corpus,
            'Unembedded: 2',
            'vector_unavailable',
          ]) {
            expect(rendered, contains(expected));
          }
        }
      });
    }
  }
  for (final arguments in [
    ['--corpus', 'other', '--query', 'x'],
    ['--corpus', 'memory', '--query', ' '],
    for (final limit in ['0', '21', '1.5', 'bad']) ['--corpus', 'memory', '--query', 'x', '--limit', limit],
  ]) {
    test('invalid flags are rejected without connecting: $arguments', () async {
      final transport = FakeApiTransport();
      final runner = DartclawRunner()
        ..addCommand(
          SearchCommand(
            inspect: SearchInspectCommand(
              apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
            ),
          ),
        );
      await expectLater(runner.run(['search', 'inspect', ...arguments]), throwsA(isA<UsageException>()));
      expect(transport.requests, isEmpty);
    });
  }
  for (final status in [400, 401, 503]) {
    test('API $status retains connected error and exit policy', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(status, {
            'error': {'code': 'FAIL', 'message': 'unavailable'},
          }),
        ],
      );
      final errors = <String>[];
      final runner = DartclawRunner()
        ..addCommand(
          SearchCommand(
            inspect: SearchInspectCommand(
              apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
              stderrLine: errors.add,
              exitFn: fakeExit,
            ),
          ),
        );
      await expectLater(
        runner.run(['search', 'inspect', '--corpus', 'memory', '--query', 'needle']),
        throwsA(
          isA<FakeExit>().having(
            (value) => value.code,
            'code',
            status == 400
                ? 5
                : status == 401
                ? 4
                : 6,
          ),
        ),
      );
      expect(errors.single, status == 401 ? contains('Authentication failed') : 'unavailable');
      expect(jsonDecode(transport.requests.single.body!)['limit'], 20);
    });
  }
  test('inspection is registered only on the root runtime CLI', () {
    expect(buildDartclawRunner().commands['search']!.subcommands.keys, containsAll(['inspect', 'download-model']));
    expect(buildDartclawWorkflowRunner().commands, isNot(contains('search')));
  });
}
