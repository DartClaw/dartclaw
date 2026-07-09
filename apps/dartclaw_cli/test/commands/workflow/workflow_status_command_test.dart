import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskType;

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_status_command.dart';
import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig, ServerConfig;
import 'package:dartclaw_config/dartclaw_config.dart' show WorkflowRunStatus;
import 'package:dartclaw_core/dartclaw_core.dart' show Task, TaskStatus, TaskType;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinition, WorkflowStep;
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show SqliteTaskRepository, SqliteWorkflowRunRepository, openTaskDbInMemory;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowRun;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';
import '../../helpers/fake_exit.dart';

void main() {
  group('WorkflowStatusCommand', () {
    test('name is status', () {
      expect(WorkflowStatusCommand().name, 'status');
    });

    test('description is set', () {
      expect(WorkflowStatusCommand().description, isNotEmpty);
    });

    test('has --json flag', () {
      expect(WorkflowStatusCommand().argParser.options.containsKey('json'), isTrue);
    });

    test('missing run ID throws UsageException', () {
      final output = <String>[];
      final command = WorkflowStatusCommand(writeLine: output.add, exitFn: fakeExit);
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      expect(() => runner.run(['status']), throwsA(isA<UsageException>()));
    });

    test('non-existent run ID prints error and exits 1', () async {
      final output = <String>[];
      final tmpDb = openTaskDbInMemory();
      addTearDown(tmpDb.close);

      final config = DartclawConfig(server: ServerConfig(dataDir: '/tmp/dartclaw-status-test'));

      final command = WorkflowStatusCommand(
        config: config,
        taskDbFactory: (_) => tmpDb,
        writeLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['status', '--standalone', 'nonexistent-run-id']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
      );
    });

    test('standalone mode discovers cwd-local .dartclaw config', () async {
      final workspace = Directory.systemTemp.createTempSync('workflow_status_dot_config_test_');
      final dataDir = Directory(p.join(workspace.path, '.dartclaw'))..createSync();
      addTearDown(() {
        if (workspace.existsSync()) workspace.deleteSync(recursive: true);
      });
      File(p.join(dataDir.path, 'dartclaw.yaml')).writeAsStringSync('''
data_dir: .
agent:
  provider: claude
''');
      final output = <String>[];
      final command = WorkflowStatusCommand(currentDirectory: workspace.path, writeLine: output.add, exitFn: fakeExit);
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['status', '--standalone', 'missing-run']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
      );

      expect(output, contains('Workflow run not found: missing-run'));
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
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
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
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
          writeLine: output.add,
          exitFn: fakeExit,
        );
        final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);
        await runner.run(['status', 'run-ap']);

        final joined = output.join('\n');
        expect(joined, contains('plan-approval'));
        expect(joined, contains('Review the plan before build.'));
        expect(joined, contains('workflow resume run-ap'));
        expect(joined, contains('workflow cancel run-ap'));
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
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
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

    group('approval pause context in status output', () {
      late Directory tempDir;
      late DartclawConfig config;

      setUp(() {
        tempDir = Directory.systemTemp.createTempSync('dartclaw_status_s03_test_');
        config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
      });

      tearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      Future<List<String>> runStatus(String runId, WorkflowRun run) async {
        final tmpDb = openTaskDbInMemory();
        addTearDown(tmpDb.close);
        final repo = SqliteWorkflowRunRepository(tmpDb);
        await repo.insert(run);

        final output = <String>[];
        final command = WorkflowStatusCommand(
          config: config,
          taskDbFactory: (_) => tmpDb,
          writeLine: output.add,
          exitFn: fakeExit,
        );
        final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);
        await runner.run(['status', '--standalone', runId]);
        return output;
      }

      WorkflowRun makeApprovalPausedRun({String runId = 'run-ap', String stepId = 'gate'}) {
        final def = WorkflowDefinition(
          name: 'approval-wf',
          description: '',
          steps: [
            WorkflowStep(id: stepId, name: 'Gate', taskType: WorkflowTaskType.approval, prompts: ['Approve?']),
            const WorkflowStep(id: 'next', name: 'Next', prompts: ['Continue']),
          ],
          variables: const {},
        );
        final now = DateTime.now();
        return WorkflowRun(
          id: runId,
          definitionName: 'approval-wf',
          status: WorkflowRunStatus.paused,
          startedAt: now,
          updatedAt: now,
          currentStepIndex: 1,
          definitionJson: def.toJson(),
          contextJson: {
            'data': <String, dynamic>{},
            'variables': <String, dynamic>{},
            '$stepId.approval.status': 'pending',
            '$stepId.approval.message': 'Please review before proceeding.',
            '$stepId.approval.requested_at': now.toIso8601String(),
            '_approval.pending.stepId': stepId,
            '_approval.pending.stepIndex': 0,
          },
        );
      }

      test('table output shows "paused (awaiting approval)" for approval-paused run', () async {
        final run = makeApprovalPausedRun();
        final output = await runStatus('run-ap', run);
        expect(output.any((l) => l.contains('awaiting approval')), isTrue);
      });

      test('table output includes pending step ID and approval message', () async {
        final run = makeApprovalPausedRun(stepId: 'review-gate');
        final output = await runStatus('run-ap', run);
        expect(output.any((l) => l.contains('review-gate')), isTrue);
        expect(output.any((l) => l.contains('Please review before proceeding.')), isTrue);
      });

      test('approval message is scrubbed of ANSI and control characters at the printer boundary', () async {
        final run = makeApprovalPausedRun();
        final injected = {...run.contextJson, 'gate.approval.message': 'all clear\x1b[2J\r\nAPPROVED: proceed\x07'};
        final output = await runStatus('run-ap', run.copyWith(contextJson: injected));
        final requestLine = output.firstWhere((l) => l.contains('Request:'));
        expect(requestLine, contains('all clear APPROVED: proceed'));
        expect(requestLine, isNot(contains('\x1b')));
        expect(requestLine, isNot(contains('\r')));
      });

      test('table output includes resume and cancel action hints', () async {
        final run = makeApprovalPausedRun();
        final output = await runStatus('run-ap', run);
        expect(output.any((l) => l.contains('resume')), isTrue);
        expect(output.any((l) => l.contains('cancel')), isTrue);
      });

      test('standalone table scrubs errorMessage of ANSI and control characters', () async {
        final def = WorkflowDefinition(
          name: 'plain-wf',
          description: '',
          steps: [
            const WorkflowStep(id: 's1', name: 'Step 1', prompts: ['Do it']),
          ],
          variables: const {},
        );
        final now = DateTime.now();
        final run = WorkflowRun(
          id: 'run-err',
          definitionName: 'plain-wf',
          status: WorkflowRunStatus.failed,
          startedAt: now,
          updatedAt: now,
          currentStepIndex: 0,
          definitionJson: def.toJson(),
          errorMessage: '\x1b[2J\r\nX',
        );
        final output = await runStatus('run-err', run);
        final errorLine = output.firstWhere((l) => l.contains('Error:'));
        expect(errorLine, endsWith('X'));
        expect(errorLine, isNot(contains('\x1b')));
        expect(errorLine, isNot(contains('\r')));
      });

      test('standalone task table scrubs a hostile task title before truncation', () async {
        final def = WorkflowDefinition(
          name: 'plain-wf',
          description: '',
          steps: [
            const WorkflowStep(id: 's1', name: 'Step 1', prompts: ['Do it']),
          ],
          variables: const {},
        );
        final now = DateTime.now();
        final run = WorkflowRun(
          id: 'run-title',
          definitionName: 'plain-wf',
          status: WorkflowRunStatus.completed,
          startedAt: now,
          updatedAt: now,
          currentStepIndex: 1,
          definitionJson: def.toJson(),
        );
        final tmpDb = openTaskDbInMemory();
        addTearDown(tmpDb.close);
        await SqliteWorkflowRunRepository(tmpDb).insert(run);
        await SqliteTaskRepository(tmpDb).insert(
          Task(
            id: 't1',
            title: 'evil\x1b[2J\r\ntitle\x07',
            description: '',
            type: TaskType.coding,
            status: TaskStatus.accepted,
            createdAt: now,
            workflowRunId: 'run-title',
            stepIndex: 0,
          ),
        );

        final output = <String>[];
        final command = WorkflowStatusCommand(
          config: config,
          taskDbFactory: (_) => tmpDb,
          writeLine: output.add,
          exitFn: fakeExit,
        );
        final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);
        await runner.run(['status', '--standalone', 'run-title']);

        final row = output.firstWhere((l) => l.contains('evil'));
        expect(row, contains('evil title'));
        expect(row, isNot(contains('\x1b')));
        expect(row, isNot(contains('\r')));
        expect(row, isNot(contains('\x07')));
      });

      test('non-approval paused run does NOT show approval context', () async {
        final def = WorkflowDefinition(
          name: 'plain-wf',
          description: '',
          steps: [
            const WorkflowStep(id: 's1', name: 'Step 1', prompts: ['Do it']),
          ],
          variables: const {},
        );
        final now = DateTime.now();
        final run = WorkflowRun(
          id: 'run-plain',
          definitionName: 'plain-wf',
          status: WorkflowRunStatus.paused,
          startedAt: now,
          updatedAt: now,
          currentStepIndex: 0,
          definitionJson: def.toJson(),
        );
        final output = await runStatus('run-plain', run);
        expect(output.any((l) => l.contains('awaiting approval')), isFalse);
        expect(output.any((l) => l.contains('Approval:')), isFalse);
      });
    });
  });
}
