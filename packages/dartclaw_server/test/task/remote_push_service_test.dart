import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

import '../helpers/factories.dart';

typedef _PushRunner =
    Future<({int exitCode, String stdout, String stderr})> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

_PushRunner _fakeRunner({int exitCode = 0, String stdout = '', String stderr = ''}) {
  return (executable, arguments, {workingDirectory, environment}) async =>
      (exitCode: exitCode, stdout: stdout, stderr: stderr);
}

_PushRunner _recordingRunner(
  List<({String executable, List<String> arguments, String? workingDirectory, Map<String, String>? environment})>
  calls, {
  int exitCode = 0,
  String stderr = '',
}) {
  return (executable, arguments, {workingDirectory, environment}) async {
    calls.add((
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    ));
    return (exitCode: exitCode, stdout: '', stderr: stderr);
  };
}

void main() {
  group('RemotePushService', () {
    test('returns PushSuccess on exit code 0', () async {
      final service = RemotePushService(processRunner: _fakeRunner());
      final result = await service.push(project: makeProject(), branch: 'dartclaw/task-1');
      expect(result, isA<PushSuccess>());
    });

    test('returns PushAuthFailure when stderr contains "Permission denied"', () async {
      final service = RemotePushService(
        processRunner: _fakeRunner(exitCode: 128, stderr: 'Permission denied (publickey).'),
      );
      final result = await service.push(project: makeProject(), branch: 'dartclaw/task-1');
      expect(result, isA<PushAuthFailure>());
      final failure = result as PushAuthFailure;
      expect(failure.details, contains('Authentication denied'));
    });

    test('returns PushAuthFailure when stderr contains "Authentication failed"', () async {
      final service = RemotePushService(
        processRunner: _fakeRunner(exitCode: 128, stderr: 'remote: Authentication failed for ...'),
      );
      final result = await service.push(project: makeProject(), branch: 'dartclaw/task-1');
      expect(result, isA<PushAuthFailure>());
    });

    test('returns PushAuthFailure when stderr contains "could not read Username"', () async {
      final service = RemotePushService(
        processRunner: _fakeRunner(exitCode: 128, stderr: 'fatal: could not read Username for https://...'),
      );
      final result = await service.push(project: makeProject(), branch: 'dartclaw/task-1');
      expect(result, isA<PushAuthFailure>());
    });

    test('returns PushRejected when stderr contains "rejected"', () async {
      final service = RemotePushService(
        processRunner: _fakeRunner(
          exitCode: 1,
          stderr: '! [rejected] dartclaw/task-1 -> dartclaw/task-1 (non-fast-forward)',
        ),
      );
      final result = await service.push(project: makeProject(), branch: 'dartclaw/task-1');
      expect(result, isA<PushRejected>());
    });

    test('returns PushRejected when stderr contains "non-fast-forward"', () async {
      final service = RemotePushService(
        processRunner: _fakeRunner(
          exitCode: 1,
          stderr: 'Updates were rejected because the remote contains work (non-fast-forward).',
        ),
      );
      final result = await service.push(project: makeProject(), branch: 'dartclaw/task-1');
      expect(result, isA<PushRejected>());
    });

    test('returns PushError on generic non-zero exit', () async {
      final service = RemotePushService(
        processRunner: _fakeRunner(exitCode: 128, stderr: 'fatal: repository not found'),
      );
      final result = await service.push(project: makeProject(), branch: 'dartclaw/task-1');
      expect(result, isA<PushError>());
      final error = result as PushError;
      expect(error.message, contains('repository not found'));
    });

    test('calls git push with correct args', () async {
      final calls =
          <({String executable, List<String> arguments, String? workingDirectory, Map<String, String>? environment})>[];
      final service = RemotePushService(processRunner: _recordingRunner(calls));

      await service.push(
        project: makeProject(localPath: '/data/my-app'),
        branch: 'dartclaw/task-1',
      );

      expect(calls, hasLength(1));
      expect(calls.single.executable, 'git');
      expect(calls.single.arguments, ['push', 'origin', 'dartclaw/task-1']);
      expect(calls.single.workingDirectory, '/data/my-app');
    });

    test('auth failure does not expose credential values in result', () async {
      final project = makeProject(credentialsRef: 'my-secret-key');
      final service = RemotePushService(
        processRunner: _fakeRunner(exitCode: 128, stderr: 'Permission denied (publickey).'),
      );
      final result = await service.push(project: project, branch: 'dartclaw/task-1');
      expect(result, isA<PushAuthFailure>());
      // Details should reference the credential name, not any secret value.
      final details = (result as PushAuthFailure).details;
      expect(details, contains('my-secret-key'));
      // No actual key/token values should appear (no real values in test, so just check format).
      expect(details, isNot(contains('actual-secret')));
    });

    test('PushResult subtypes support exhaustive switch', () {
      // Compile-time check that sealed class is exhaustive.
      PushResult result = const PushSuccess();
      final _ = switch (result) {
        PushSuccess() => 'success',
        PushAuthFailure(:final details) => 'auth: $details',
        PushRejected(:final reason) => 'rejected: $reason',
        PushError(:final message) => 'error: $message',
      };
    });
  });
}
