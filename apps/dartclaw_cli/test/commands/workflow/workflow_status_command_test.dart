import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow/api_workflow_connection.dart';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_status_command.dart';
import 'package:dartclaw_client/dartclaw_client.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show FileExecutionStore;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show DartclawConfig, ServerConfig, WorkflowRunStatus;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show FileWorkflowRunRepository, WorkflowDefinition, WorkflowRun, WorkflowStep;
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

    test('standalone status reads a persisted run with no database connection configured', () async {
      final directory = Directory.systemTemp.createTempSync('workflow_status_file_');
      addTearDown(() => directory.deleteSync(recursive: true));
      final config = DartclawConfig(server: ServerConfig(dataDir: directory.path));
      final definition = WorkflowDefinition(
        name: 'local-review',
        description: 'Review a local change',
        steps: const [
          WorkflowStep(id: 'review', name: 'Review', prompts: ['Review the change']),
        ],
      );
      final now = DateTime.utc(2026, 6, 1);
      final store = await FileExecutionStore.open(config.standaloneExecutionPath);
      await FileWorkflowRunRepository(store).insert(
        WorkflowRun(
          id: 'local-1',
          definitionName: definition.name,
          status: WorkflowRunStatus.completed,
          startedAt: now,
          updatedAt: now,
          currentStepIndex: 1,
          definitionJson: definition.toJson(),
        ),
      );
      await store.close();

      final output = <String>[];
      final command = WorkflowStatusCommand(config: config, writeLine: output.add, exitFn: fakeExit);
      await (CommandRunner<void>(
        'dartclaw',
        'test',
      )..addCommand(command)).run(['status', '--standalone', '--json', 'local-1']);

      final result = jsonDecode(output.single) as Map<String, dynamic>;
      expect(result['id'], 'local-1');
      expect(result['status'], 'completed');
      expect(result['steps'], isEmpty);
      expect(config.database.url, isNull);
    });

    test('standalone status reports absent local state without opening PostgreSQL', () async {
      final directory = Directory.systemTemp.createTempSync('workflow_status_absent_');
      addTearDown(() => directory.deleteSync(recursive: true));
      final config = DartclawConfig(server: ServerConfig(dataDir: directory.path));
      final output = <String>[];
      final command = WorkflowStatusCommand(config: config, writeLine: output.add, exitFn: fakeExit);

      await expectLater(
        (CommandRunner<void>('dartclaw', 'test')..addCommand(command)).run(['status', '--standalone', 'old-1']),
        throwsA(isA<FakeExit>().having((error) => error.code, 'code', 1)),
      );

      expect(output.single, contains('Existing PostgreSQL runs are not imported'));
      expect(File(config.standaloneExecutionPath).existsSync(), isFalse);
    });

    group('connected-mode table output', () {
      test('accounting stop recommends retry while an execution pause recommends resume', () async {
        for (final status in ['failed', 'paused']) {
          final cause = status == 'failed'
              ? "Workflow accounting unavailable for step 'work'; token usage is incomplete."
              : 'shell exited 7';
          final transport = FakeApiTransport(
            sendResponses: [
              jsonResponse(200, {
                'id': 'run-correction',
                'definitionName': 'demo-wf',
                'status': status,
                'startedAt': '2026-06-01T10:00:00Z',
                'totalTokens': 30,
                'tokenUsageComplete': false,
                'errorMessage': cause,
                'steps': [
                  {
                    'id': 'work',
                    'name': 'Work',
                    'status': status == 'failed' ? 'completed' : 'failed',
                    'tokenCount': null,
                  },
                  {'id': 'zero', 'name': 'Zero', 'status': 'completed', 'tokenCount': 0},
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
          await (CommandRunner<void>('dartclaw', 'test')..addCommand(command)).run(['status', 'run-correction']);
          final text = output.join('\n');
          expect(text, contains(cause));
          expect(text, contains('30 (incomplete lower bound)'));
          expect(output.any((line) => line.contains('Work') && line.contains('unavailable')), isTrue);
          expect(output.singleWhere((line) => line.contains('Zero')), contains('  0'));
          expect(text, isNot(contains('Approval:')));
          expect(text, contains(status == 'failed' ? 'retry run-correction' : 'resume run-correction'));
        }
      });

      test('error policy status shows cause, failed step, and matching recovery command', () async {
        for (final status in ['failed', 'paused', 'completed']) {
          final transport = FakeApiTransport(
            sendResponses: [
              jsonResponse(200, {
                'id': 'run-error',
                'definitionName': 'demo-wf',
                'status': status,
                'startedAt': '2026-06-01T10:00:00Z',
                'totalTokens': 0,
                'errorMessage': status == 'completed' ? null : 'shell exited 7',
                'steps': [
                  {'id': 'shell', 'name': 'Shell', 'status': 'failed', 'reason': 'shell exited 7'},
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
          await (CommandRunner<void>('dartclaw', 'test')..addCommand(command)).run(['status', 'run-error']);
          final text = output.join('\n');
          expect(text, contains('failed'));
          expect(text, contains('shell exited 7'));
          expect(text, isNot(contains('Approval:')));
          if (status == 'failed') expect(text, contains('retry run-error'));
          if (status == 'paused') expect(text, contains('resume run-error'));
        }
      });

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
