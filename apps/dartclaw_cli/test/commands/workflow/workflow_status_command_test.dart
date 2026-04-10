import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_status_command.dart';
import 'package:dartclaw_core/dartclaw_core.dart'
    show DartclawConfig, ServerConfig, WorkflowDefinition, WorkflowRun, WorkflowRunStatus, WorkflowStep;
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show SqliteWorkflowRunRepository, openTaskDbInMemory;
import 'package:test/test.dart';

class _FakeExit implements Exception {
  final int code;
  const _FakeExit(this.code);
}

Never _fakeExit(int code) => throw _FakeExit(code);

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
      final command = WorkflowStatusCommand(
        writeLine: output.add,
        exitFn: _fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      expect(
        () => runner.run(['status']),
        throwsA(isA<UsageException>()),
      );
    });

    test('non-existent run ID prints error and exits 1', () async {
      final output = <String>[];
      final tmpDb = openTaskDbInMemory();
      addTearDown(tmpDb.close);

      final config = DartclawConfig(
        server: ServerConfig(dataDir: '/tmp/dartclaw-status-test'),
      );

      final command = WorkflowStatusCommand(
        config: config,
        taskDbFactory: (_) => tmpDb,
        writeLine: output.add,
        exitFn: _fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['status', 'nonexistent-run-id']),
        throwsA(isA<_FakeExit>().having((e) => e.code, 'code', 1)),
      );
    });

    group('S03 (0.16.1): approval pause context in status output', () {
      late Directory tempDir;
      late DartclawConfig config;

      setUp(() {
        tempDir = Directory.systemTemp.createTempSync('dartclaw_status_s03_test_');
        config = DartclawConfig(
          server: ServerConfig(dataDir: tempDir.path),
        );
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
          exitFn: _fakeExit,
        );
        final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);
        await runner.run(['status', runId]);
        return output;
      }

      WorkflowRun makeApprovalPausedRun({String runId = 'run-ap', String stepId = 'gate'}) {
        final def = WorkflowDefinition(
          name: 'approval-wf',
          description: '',
          steps: [
            WorkflowStep(id: stepId, name: 'Gate', type: 'approval', prompts: ['Approve?']),
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

      test('table output includes resume and cancel action hints', () async {
        final run = makeApprovalPausedRun();
        final output = await runStatus('run-ap', run);
        expect(output.any((l) => l.contains('resume')), isTrue);
        expect(output.any((l) => l.contains('cancel')), isTrue);
      });

      test('non-approval paused run does NOT show approval context', () async {
        final def = WorkflowDefinition(
          name: 'plain-wf',
          description: '',
          steps: [const WorkflowStep(id: 's1', name: 'Step 1', prompts: ['Do it'])],
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
