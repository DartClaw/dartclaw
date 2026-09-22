import 'package:dartclaw_cli/src/commands/workflow/api_workflow_connection.dart';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_status_command.dart';
import 'package:dartclaw_client/dartclaw_client.dart';
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';
import '../../helpers/fake_exit.dart';

void main() {
  group('WorkflowStatusCommand', () {
    test('has --json flag', () {
      expect(WorkflowStatusCommand().argParser.options.containsKey('json'), isTrue);
    });

    test('missing run ID throws UsageException', () {
      final output = <String>[];
      final command = WorkflowStatusCommand(writeLine: output.add, exitFn: fakeExit);
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      expect(() => runner.run(['status']), throwsA(isA<UsageException>()));
    });

    group('connected-mode table output', () {
      test('API table scrubs errorMessage of ANSI and control characters', () async {
        final transport = FakeApiTransport(
          sendResponses: [
            jsonResponse(200, {
              'id': 'run-1',
              'definitionName': 'demo-wf',
              'status': 'failed',
              'startedAt': '2026-06-01T10:00:00Z',
              'totalTokens': 0,
              'errorMessage': '\x1b[2J\r\nX',
              'steps': <Object>[],
            }),
          ],
        );
        final output = <String>[];
        final command = WorkflowStatusCommand(
          connection: ApiWorkflowConnection(
            apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
          ),
          writeLine: output.add,
          exitFn: fakeExit,
        );
        final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);
        await runner.run(['status', 'run-1']);

        final errorLine = output.firstWhere((l) => l.contains('Error:'));
        expect(errorLine, endsWith('X'));
        expect(errorLine, isNot(contains('\x1b')));
        expect(errorLine, isNot(contains('\r')));
      });

      test('awaitingApproval run explains the pause with pending step and resume guidance', () async {
        final transport = FakeApiTransport(
          sendResponses: [
            jsonResponse(200, {
              'id': 'run-ap',
              'definitionName': 'demo-wf',
              'status': 'awaitingApproval',
              'startedAt': '2026-06-01T10:00:00Z',
              'totalTokens': 0,
              'isApprovalPaused': true,
              'pendingApprovalStepId': 'plan-approval',
              'contextJson': {'plan-approval.approval.message': 'Review the plan before build.'},
              'steps': [
                {'id': 'plan-approval', 'name': 'Plan Approval', 'status': 'awaiting_approval'},
              ],
            }),
          ],
        );
        final output = <String>[];
        final command = WorkflowStatusCommand(
          connection: ApiWorkflowConnection(
            apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
          ),
          writeLine: output.add,
          exitFn: fakeExit,
        );
        final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);
        await runner.run(['status', 'run-ap']);

        final joined = output.join('\n');
        expect(joined, contains('plan-approval'));
        expect(joined, contains('Review the plan before build.'));
        expect(joined, contains('dartclaw resume run-ap'));
        expect(joined, contains('dartclaw cancel run-ap'));
      });

      test('needsInput hold on a non-approval step still surfaces its reason (context-key parity)', () async {
        // A needsInput agent step goes awaitingApproval and writes the reason to
        // the flat context key, but is not approval-typed — connected output must
        // still print it, matching the standalone synthesis.
        final transport = FakeApiTransport(
          sendResponses: [
            jsonResponse(200, {
              'id': 'run-ni',
              'definitionName': 'demo-wf',
              'status': 'awaitingApproval',
              'startedAt': '2026-06-01T10:00:00Z',
              'totalTokens': 0,
              'isApprovalPaused': true,
              'pendingApprovalStepId': 'build',
              'contextJson': {'build.approval.message': 'Need the target branch to proceed.'},
              'steps': [
                {'id': 'build', 'name': 'Build', 'status': 'awaiting_approval'},
              ],
            }),
          ],
        );
        final output = <String>[];
        final command = WorkflowStatusCommand(
          connection: ApiWorkflowConnection(
            apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
          ),
          writeLine: output.add,
          exitFn: fakeExit,
        );
        final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);
        await runner.run(['status', 'run-ni']);

        final joined = output.join('\n');
        expect(joined, contains('build'));
        expect(joined, contains('Need the target branch to proceed.'));
      });
    });
  });
}
