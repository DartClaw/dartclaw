import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show Task, TaskType;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

import '../helpers/factories.dart';

Task _makeTask({
  String title = 'Implement feature X',
  String description = 'Build it well.',
  String? acceptanceCriteria,
}) => Task(
  id: 'task-1',
  title: title,
  description: description,
  type: TaskType.coding,
  createdAt: DateTime.now(),
  acceptanceCriteria: acceptanceCriteria,
);

typedef _ApiCall = ({String method, Uri uri, Map<String, String> headers, String? body});
typedef _ApiRunner =
    Future<({int statusCode, String body})> Function(
      String method,
      Uri uri, {
      required Map<String, String> headers,
      String? body,
    });

_ApiRunner _recordingRunner(List<_ApiCall> calls, {List<({int statusCode, String body})> responses = const []}) {
  var index = 0;
  return (method, uri, {required headers, body}) async {
    calls.add((method: method, uri: uri, headers: headers, body: body));
    final response = responses[index++];
    return (statusCode: response.statusCode, body: response.body);
  };
}

void main() {
  group('PrCreator', () {
    test('returns PrCreationFailed when GitHub token credential is missing', () async {
      final creator = PrCreator();
      final result = await creator.create(
        project: makeProject(remoteUrl: 'git@github.com:u/my-app.git'),
        task: _makeTask(),
        branch: 'dartclaw/task-1',
      );

      expect(result, isA<PrCreationFailed>());
      final failed = result as PrCreationFailed;
      expect(failed.error, contains('credential'));
    });

    test('creates PR via GitHub REST API and returns html_url', () async {
      final calls = <_ApiCall>[];
      final creator = PrCreator(
        credentials: const CredentialsConfig(
          entries: {'github-main': CredentialEntry.githubToken(token: 'ghp_test', repository: 'u/my-app')},
        ),
        apiRunner: _recordingRunner(
          calls,
          responses: [(statusCode: 201, body: '{"html_url":"https://github.com/u/my-app/pull/42","number":42}')],
        ),
      );

      final result = await creator.create(
        project: makeProject(remoteUrl: 'git@github.com:u/my-app.git', credentialsRef: 'github-main'),
        task: _makeTask(),
        branch: 'dartclaw/task-1',
      );

      expect(result, isA<PrCreated>());
      expect((result as PrCreated).url, 'https://github.com/u/my-app/pull/42');
      expect(calls, hasLength(1));
      expect(calls.single.method, 'POST');
      expect(calls.single.uri.path, '/repos/u/my-app/pulls');
      expect(calls.single.headers['authorization'], 'Bearer ghp_test');
      final payload = jsonDecode(calls.single.body!) as Map<String, dynamic>;
      expect(payload['title'], 'Implement feature X');
      expect(payload['head'], 'dartclaw/task-1');
      expect(payload['base'], 'main');
      expect(payload['draft'], isNull);
    });

    test('includes draft=true in create payload when project.pr.draft is true', () async {
      final calls = <_ApiCall>[];
      final creator = PrCreator(
        credentials: const CredentialsConfig(
          entries: {'github-main': CredentialEntry.githubToken(token: 'ghp_test', repository: 'u/my-app')},
        ),
        apiRunner: _recordingRunner(
          calls,
          responses: [(statusCode: 201, body: '{"html_url":"https://github.com/u/my-app/pull/1","number":1}')],
        ),
      );

      await creator.create(
        project: makeProject(
          remoteUrl: 'https://github.com/u/my-app.git',
          credentialsRef: 'github-main',
          pr: const PrConfig(draft: true),
        ),
        task: _makeTask(),
        branch: 'dartclaw/task-1',
      );

      final payload = jsonDecode(calls.single.body!) as Map<String, dynamic>;
      expect(payload['draft'], isTrue);
    });

    test('applies labels through the issues labels endpoint', () async {
      final calls = <_ApiCall>[];
      final creator = PrCreator(
        credentials: const CredentialsConfig(
          entries: {'github-main': CredentialEntry.githubToken(token: 'ghp_test', repository: 'u/my-app')},
        ),
        apiRunner: _recordingRunner(
          calls,
          responses: [
            (statusCode: 201, body: '{"html_url":"https://github.com/u/my-app/pull/1","number":99}'),
            (statusCode: 200, body: '[{"name":"agent"},{"name":"automated"}]'),
          ],
        ),
      );

      final result = await creator.create(
        project: makeProject(
          remoteUrl: 'git@github.com:u/my-app.git',
          credentialsRef: 'github-main',
          pr: const PrConfig(labels: ['agent', 'automated']),
        ),
        task: _makeTask(),
        branch: 'dartclaw/task-1',
      );

      expect(result, isA<PrCreated>());
      expect(calls, hasLength(2));
      expect(calls[1].uri.path, '/repos/u/my-app/issues/99/labels');
      expect(jsonDecode(calls[1].body!)['labels'], ['agent', 'automated']);
    });

    test('returns PrCreationFailed when GitHub returns non-201 for PR creation', () async {
      final creator = PrCreator(
        credentials: const CredentialsConfig(
          entries: {'github-main': CredentialEntry.githubToken(token: 'ghp_test', repository: 'u/my-app')},
        ),
        apiRunner: (method, uri, {required headers, body}) async =>
            (statusCode: 422, body: '{"message":"A pull request already exists for dartclaw/task-1."}'),
      );

      final result = await creator.create(
        project: makeProject(remoteUrl: 'git@github.com:u/my-app.git', credentialsRef: 'github-main'),
        task: _makeTask(),
        branch: 'dartclaw/task-1',
      );

      expect(result, isA<PrCreationFailed>());
      final failed = result as PrCreationFailed;
      expect(failed.error, contains('HTTP 422'));
      expect(failed.details, contains('already exists'));
    });

    test('returns PrCreationFailed when label application fails', () async {
      final creator = PrCreator(
        credentials: const CredentialsConfig(
          entries: {'github-main': CredentialEntry.githubToken(token: 'ghp_test', repository: 'u/my-app')},
        ),
        apiRunner: _recordingRunner(
          [],
          responses: [
            (statusCode: 201, body: '{"html_url":"https://github.com/u/my-app/pull/1","number":1}'),
            (statusCode: 403, body: '{"message":"Resource not accessible by personal access token"}'),
          ],
        ),
      );

      final result = await creator.create(
        project: makeProject(
          remoteUrl: 'git@github.com:u/my-app.git',
          credentialsRef: 'github-main',
          pr: const PrConfig(labels: ['agent']),
        ),
        task: _makeTask(),
        branch: 'dartclaw/task-1',
      );

      expect(result, isA<PrCreationFailed>());
      final failed = result as PrCreationFailed;
      expect(failed.error, contains('labels'));
      expect(failed.details, contains('Created PR https://github.com/u/my-app/pull/1'));
    });

    test('PrCreationResult subtypes support exhaustive switch', () {
      PrCreationResult result = const PrCreated('https://example.com');
      final _ = switch (result) {
        PrCreated(:final url) => 'created: $url',
        PrGhNotFound(:final instructions) => 'manual: $instructions',
        PrCreationFailed(:final error, :final details) => 'failed: $error ($details)',
      };
    });
  });
}
