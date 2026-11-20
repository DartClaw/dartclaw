import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/api_workflow_connection.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_resume_command.dart';
import 'package:dartclaw_client/dartclaw_client.dart';
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';

void main() {
  for (final candidate in [null, 'candidate+/?&=']) {
    test(
      'connected resume ${candidate == null ? 'without a candidate' : 'sends the requested candidate unchanged'}',
      () async {
        final transport = FakeApiTransport(
          sendResponses: [
            jsonResponse(200, {'id': 'run-1', 'status': 'running'}),
          ],
        );
        final output = <String>[];
        final runner = CommandRunner<void>('dartclaw', 'test')
          ..addCommand(
            WorkflowResumeCommand(
              connection: ApiWorkflowConnection(
                apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
              ),
              writeLine: output.add,
            ),
          );

        await runner.run([
          'resume',
          'run-1',
          if (candidate != null) ...['--candidate', candidate],
        ]);

        final request = transport.requests.single;
        expect(request.method, 'POST');
        expect(request.uri.path, '/api/workflows/runs/run-1/resume');
        expect(request.uri.queryParameters, {'executionSurfaceCandidate': ?candidate});
        expect(output.single, 'Workflow run-1 resumed (running).');
      },
    );
  }

  test('standalone resume refuses the connected candidate option before opening the run', () async {
    final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(WorkflowResumeCommand());

    await expectLater(
      runner.run(['resume', 'run-1', '--standalone', '--candidate', 'candidate']),
      throwsA(isA<UsageException>().having((error) => error.message, 'message', '--candidate requires connected mode')),
    );
  });
}
