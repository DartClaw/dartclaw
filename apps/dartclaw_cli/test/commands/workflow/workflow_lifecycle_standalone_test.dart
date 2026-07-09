import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/cli_workflow_wiring.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_cancel_command.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_pause_command.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_resume_command.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_retry_command.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_status_command.dart';
import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show HarnessFactory, WorkflowRunStatusChangedEvent;
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show SqliteWorkflowRunRepository, openTaskDb, openTaskDbInMemory;
import 'package:dartclaw_testing/dartclaw_testing.dart'
    show FakeAgentHarness, FakeProviderAuthPreflight, FakeSkillIntrospector;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinition, WorkflowRun, WorkflowRunStatus, WorkflowStep, WorkflowTaskType, skillProvisionerMarkerFile;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';
import '../../helpers/fake_exit.dart';

void main() {
  group('Standalone workflow lifecycle control', () {
    late Directory tempDir;
    late DartclawConfig config;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dartclaw_workflow_lifecycle_standalone_test_');
      config = DartclawConfig(
        agent: const AgentConfig(provider: 'claude'),
        server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      );
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('S01 resume --standalone advances an approval-paused run to completed (exit 0)', () async {
      final runId = await runToAwaitingApproval(config, approvalThenBash());

      final output = <String>[];
      final command = resumeCommand(config, output);
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['resume', runId, '--standalone']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 0)),
      );

      // The run advanced past the gate and executed the trailing bash step,
      // not merely flipped status.
      expect(output.any((line) => line.contains('post') && line.contains('completed')), isTrue, reason: '$output');
      expect(output.any((line) => line.contains('[workflow] Completed')), isTrue, reason: '$output');
      expect(await statusOf(config, runId), WorkflowRunStatus.completed);
    });

    test('S02 resume --standalone re-pauses at the next approval gate (exit 2)', () async {
      final runId = await runToAwaitingApproval(config, twoGates());

      final output = <String>[];
      final command = resumeCommand(config, output);
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['resume', runId, '--standalone']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 2)),
      );

      // Drove forward through the bash step and re-paused at the second gate.
      expect(output.any((line) => line.contains('mid') && line.contains('completed')), isTrue, reason: '$output');
      expect(await statusOf(config, runId), WorkflowRunStatus.awaitingApproval);
    });

    test('S03 cancel --standalone --feedback rejects an approval-paused run', () async {
      final runId = await runToAwaitingApproval(config, approvalThenBash());

      final output = <String>[];
      final command = WorkflowCancelCommand(
        config: config,
        apiClient: unreachableClient(),
        harnessFactory: fakeHarness(),
        runWorkflowSkillsBootstrap: false,
        providerAuthPreflight: FakeProviderAuthPreflight(),
        skillIntrospector: FakeSkillIntrospector(const {}),
        interrupts: noInterrupts,
        writeLine: output.add,
        stderrLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['cancel', runId, '--standalone', '--feedback', 'rejected: wrong approach']),
        throwsA(isA<FakeExit>()),
      );

      expect(output, contains('Workflow $runId cancelled (cancelled).'));

      final cancelled = await runOf(config, runId);
      expect(cancelled?.status, WorkflowRunStatus.cancelled);
      expect(cancelled?.contextJson['gate.approval.status'], 'rejected');
      expect(cancelled?.contextJson['gate.approval.feedback'], 'rejected: wrong approach');
    });

    test('S04 retry --standalone on a non-failed run is rejected cleanly (exit 1)', () async {
      final seed = await seedRun(WorkflowRunStatus.paused);
      final output = <String>[];
      final command = WorkflowRetryCommand(
        config: config,
        apiClient: unreachableClient(),
        harnessFactory: fakeHarness(),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => seed.db,
        runWorkflowSkillsBootstrap: false,
        providerAuthPreflight: FakeProviderAuthPreflight(),
        skillIntrospector: FakeSkillIntrospector(const {}),
        interrupts: noInterrupts,
        writeLine: output.add,
        stderrLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['retry', seed.runId, '--standalone']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
      );

      expect(output, contains('Cannot retry workflow in paused state (only failed workflows can be retried)'));
      expect(output.every(_looksLikeNoStackTrace), isTrue, reason: 'no Dart stack trace');
    });

    test('S05 resume --standalone on a stale running run is rejected cleanly (exit 1)', () async {
      final seed = await seedRun(WorkflowRunStatus.running);
      final output = <String>[];
      final command = WorkflowResumeCommand(
        config: config,
        apiClient: unreachableClient(),
        harnessFactory: fakeHarness(),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => seed.db,
        runWorkflowSkillsBootstrap: false,
        providerAuthPreflight: FakeProviderAuthPreflight(),
        skillIntrospector: FakeSkillIntrospector(const {}),
        interrupts: noInterrupts,
        writeLine: output.add,
        stderrLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['resume', seed.runId, '--standalone']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
      );

      expect(
        output,
        contains('Cannot resume workflow in running state (only paused or awaitingApproval workflows can be resumed)'),
      );
      expect(output.every(_looksLikeNoStackTrace), isTrue, reason: 'no Dart stack trace');
    });

    test('S06 lifecycle --standalone aborts against a reachable server unless --force', () async {
      final output = <String>[];
      final command = WorkflowResumeCommand(
        config: config,
        apiClient: reachableClient(),
        harnessFactory: fakeHarness(),
        runWorkflowSkillsBootstrap: false,
        providerAuthPreflight: FakeProviderAuthPreflight(),
        skillIntrospector: FakeSkillIntrospector(const {}),
        interrupts: noInterrupts,
        writeLine: output.add,
        stderrLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['resume', 'some-run', '--standalone']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
      );

      expect(output.any((line) => line.contains('A DartClaw server is running')), isTrue);
      expect(output.any((line) => line.contains('--force')), isTrue);
    });

    test('S06 --force overrides the reachable-server safety check', () async {
      final output = <String>[];
      final command = WorkflowResumeCommand(
        config: config,
        apiClient: reachableClient(),
        harnessFactory: fakeHarness(),
        runWorkflowSkillsBootstrap: false,
        providerAuthPreflight: FakeProviderAuthPreflight(),
        skillIntrospector: FakeSkillIntrospector(const {}),
        interrupts: noInterrupts,
        writeLine: output.add,
        stderrLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      // With --force the safety check is bypassed; wiring proceeds and the
      // missing run surfaces as a clean not-found rather than the abort.
      await expectLater(
        () => runner.run(['resume', 'missing-run', '--standalone', '--force']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
      );

      expect(output.any((line) => line.contains('Workflow run not found: missing-run')), isTrue, reason: '$output');
      expect(output.every((line) => !line.contains('A DartClaw server is running')), isTrue);
    });

    test('S07 status --standalone points approval hints at the zero-server lifecycle commands', () async {
      final seed = await seedApprovalPaused();
      final output = <String>[];
      final command = WorkflowStatusCommand(
        config: config,
        taskDbFactory: (_) => seed.db,
        writeLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['status', '--standalone', seed.runId]);

      expect(output.any((line) => line.contains('resume ${seed.runId} --standalone')), isTrue, reason: '$output');
      expect(output.any((line) => line.contains('cancel ${seed.runId} --standalone')), isTrue, reason: '$output');
      expect(output.every((line) => !line.contains('Start `dartclaw serve`')), isTrue, reason: '$output');
    });

    test('--force without --standalone is a usage error', () async {
      final command = resumeCommand(config, <String>[]);
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(() => runner.run(['resume', 'some-run', '--force']), throwsA(isA<UsageException>()));
    });

    test('S04 resume --standalone aborts before harness start when a referenced provider is logged out', () async {
      // The seeded run's bash step resolves to the default provider claude,
      // which the injected preflight reports unauthenticated. Resume must abort
      // with the friendly remediation before the harness start() (which throws)
      // is reached.
      final seed = await seedRun(WorkflowRunStatus.paused);
      final started = <_ThrowOnStartHarness>[];
      final factory = HarnessFactory()
        ..register('claude', (_) {
          final harness = _ThrowOnStartHarness();
          started.add(harness);
          return harness;
        });

      final output = <String>[];
      final command = WorkflowResumeCommand(
        config: config,
        apiClient: unreachableClient(),
        harnessFactory: factory,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => seed.db,
        runWorkflowSkillsBootstrap: false,
        providerAuthPreflight: FakeProviderAuthPreflight(unauthenticated: {'claude'}),
        skillIntrospector: FakeSkillIntrospector(const {}),
        interrupts: noInterrupts,
        writeLine: output.add,
        stderrLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['resume', seed.runId, '--standalone']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
      );

      expect(
        output.any((line) => line.contains('claude') && line.contains('not authenticated')),
        isTrue,
        reason: '$output',
      );
      expect(started.every((harness) => !harness.startCalled), isTrue, reason: 'no harness.start() before preflight');
    });

    test('cancel --standalone skips the auth gate and harness startup', () async {
      // Cancel never executes steps, so it must not route through the
      // referenced-provider auth preflight: a logged-out provider does not
      // block cancelling an approval-paused run.
      final runId = await runToAwaitingApproval(config, approvalThenBash());

      final preflight = FakeProviderAuthPreflight(unauthenticated: {'claude'});
      final started = <_ThrowOnStartHarness>[];
      final factory = HarnessFactory()
        ..register('claude', (_) {
          final harness = _ThrowOnStartHarness();
          started.add(harness);
          return harness;
        });
      final output = <String>[];
      final command = WorkflowCancelCommand(
        config: config,
        apiClient: unreachableClient(),
        harnessFactory: factory,
        runWorkflowSkillsBootstrap: false,
        providerAuthPreflight: preflight,
        skillIntrospector: FakeSkillIntrospector(const {}),
        interrupts: noInterrupts,
        writeLine: output.add,
        stderrLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(() => runner.run(['cancel', runId, '--standalone']), throwsA(isA<FakeExit>()));

      expect(preflight.probed, isEmpty, reason: 'cancel must not run the auth preflight');
      expect(
        started.every((harness) => !harness.startCalled),
        isTrue,
        reason: 'cancel executes no steps and must not start a harness',
      );
      expect(output.any((line) => line.contains('cancelled')), isTrue, reason: '$output');
      expect(await statusOf(config, runId), WorkflowRunStatus.cancelled);
    });

    test('cancel --standalone skips DC-native skill bootstrap even when enabled', () async {
      // Cancel only transitions persisted run state — it runs no steps, so it
      // must not provision DC-native skills even with the bootstrap enabled
      // (the production default). Otherwise a checkout whose version-pinned
      // asset dir was never downloaded hard-fails with SkillProvisionException
      // on a verb that needs no skills. The data-dir marker is the deterministic
      // signal that provisioning ran; with the override it is never written.
      final runId = await runToAwaitingApproval(config, approvalThenBash());

      final output = <String>[];
      final command = WorkflowCancelCommand(
        config: config,
        apiClient: unreachableClient(),
        harnessFactory: fakeHarness(),
        // Production default — the verb must force it off, not rely on the flag.
        runWorkflowSkillsBootstrap: true,
        providerAuthPreflight: FakeProviderAuthPreflight(),
        skillIntrospector: FakeSkillIntrospector(const {}),
        interrupts: noInterrupts,
        writeLine: output.add,
        stderrLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(() => runner.run(['cancel', runId, '--standalone']), throwsA(isA<FakeExit>()));

      expect(await statusOf(config, runId), WorkflowRunStatus.cancelled);
      expect(
        File(p.join(tempDir.path, skillProvisionerMarkerFile)).existsSync(),
        isFalse,
        reason: 'cancel must not provision DC-native skills',
      );
    });

    test('pause --standalone skips DC-native skill bootstrap even when enabled', () async {
      // Pause, like cancel, is a state-only transition. With the bootstrap
      // enabled (production default) it must still skip provisioning rather than
      // fail when the version-pinned asset dir is absent.
      final seed = await seedRun(WorkflowRunStatus.running);
      final output = <String>[];
      final command = WorkflowPauseCommand(
        config: config,
        apiClient: unreachableClient(),
        harnessFactory: fakeHarness(),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => seed.db,
        // Production default — the verb must force it off, not rely on the flag.
        runWorkflowSkillsBootstrap: true,
        providerAuthPreflight: FakeProviderAuthPreflight(),
        skillIntrospector: FakeSkillIntrospector(const {}),
        interrupts: noInterrupts,
        writeLine: output.add,
        stderrLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['pause', seed.runId, '--standalone']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 0)),
      );

      expect(output.any((line) => line.contains('paused')), isTrue, reason: '$output');
      expect(
        File(p.join(tempDir.path, skillProvisionerMarkerFile)).existsSync(),
        isFalse,
        reason: 'pause must not provision DC-native skills',
      );
    });

    test('TI05 pause --standalone on a non-running run is rejected cleanly (exit 1)', () async {
      final seed = await seedRun(WorkflowRunStatus.paused);
      final output = <String>[];
      final command = WorkflowPauseCommand(
        config: config,
        apiClient: unreachableClient(),
        harnessFactory: fakeHarness(),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => seed.db,
        runWorkflowSkillsBootstrap: false,
        providerAuthPreflight: FakeProviderAuthPreflight(),
        skillIntrospector: FakeSkillIntrospector(const {}),
        interrupts: noInterrupts,
        writeLine: output.add,
        stderrLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['pause', seed.runId, '--standalone']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
      );

      expect(output, contains('Cannot pause workflow in paused state (only running workflows can be paused)'));
    });
  });
}

bool _looksLikeNoStackTrace(String line) => !line.contains('#0') && !line.contains('package:');

/// A [FakeAgentHarness] whose [start] throws — stands in for a logged-out
/// provider. Records the attempt so a test can assert start() was never reached.
class _ThrowOnStartHarness extends FakeAgentHarness {
  @override
  Future<void> start() async {
    await super.start();
    throw StateError('harness start blew up (logged-out provider)');
  }
}

WorkflowResumeCommand resumeCommand(DartclawConfig config, List<String> output) {
  return WorkflowResumeCommand(
    config: config,
    apiClient: unreachableClient(),
    harnessFactory: fakeHarness(),
    runWorkflowSkillsBootstrap: false,
    providerAuthPreflight: FakeProviderAuthPreflight(),
    skillIntrospector: FakeSkillIntrospector(const {}),
    interrupts: noInterrupts,
    writeLine: output.add,
    stderrLine: output.add,
    exitFn: fakeExit,
  );
}

Future<WorkflowRunStatus?> statusOf(DartclawConfig config, String runId) async => (await runOf(config, runId))?.status;

Future<WorkflowRun?> runOf(DartclawConfig config, String runId) async {
  final db = openTaskDb(config.tasksDbPath);
  try {
    return await SqliteWorkflowRunRepository(db).getById(runId);
  } finally {
    db.close();
  }
}

Future<String> runToAwaitingApproval(DartclawConfig config, WorkflowDefinition definition) async {
  final wiring = CliWorkflowWiring(
    config: config,
    dataDir: config.server.dataDir,
    harnessFactory: fakeHarness(),
    runWorkflowSkillsBootstrap: false,
    providerAuthPreflight: FakeProviderAuthPreflight(),
    skillIntrospector: FakeSkillIntrospector(const {}),
  );
  await wiring.wire();
  try {
    // Event-driven settle (no real-time polling): subscribe before start so the
    // approval-pause transition can't be missed.
    final settled = Completer<void>();
    final sub = wiring.eventBus
        .on<WorkflowRunStatusChangedEvent>()
        .where((event) => event.newStatus == WorkflowRunStatus.awaitingApproval)
        .listen((_) {
          if (!settled.isCompleted) settled.complete();
        });
    final run = await wiring.workflowService.start(definition, const {});
    await settled.future.timeout(const Duration(seconds: 10));
    await sub.cancel();
    return run.id;
  } finally {
    await wiring.dispose();
  }
}

Future<({Database db, String runId})> seedRun(WorkflowRunStatus status) async {
  final db = openTaskDbInMemory();
  final now = DateTime.now();
  final run = WorkflowRun(
    id: 'seed-${status.name}',
    definitionName: 'seed-wf',
    status: status,
    startedAt: now,
    updatedAt: now,
    definitionJson: singleBashDefinition().toJson(),
    contextJson: const {'data': <String, dynamic>{}, 'variables': <String, dynamic>{}},
  );
  await SqliteWorkflowRunRepository(db).insert(run);
  return (db: db, runId: run.id);
}

Future<({Database db, String runId})> seedApprovalPaused() async {
  final db = openTaskDbInMemory();
  final now = DateTime.now();
  const stepId = 'gate';
  final run = WorkflowRun(
    id: 'seed-approval',
    definitionName: 'approval-then-bash',
    status: WorkflowRunStatus.awaitingApproval,
    startedAt: now,
    updatedAt: now,
    currentStepIndex: 1,
    definitionJson: approvalThenBash().toJson(),
    contextJson: {
      'data': <String, dynamic>{},
      'variables': <String, dynamic>{},
      '$stepId.approval.status': 'pending',
      '$stepId.approval.message': 'Approve to continue?',
      '_approval.pending.stepId': stepId,
      '_approval.pending.stepIndex': 0,
    },
  );
  await SqliteWorkflowRunRepository(db).insert(run);
  return (db: db, runId: run.id);
}

Stream<void> Function() get noInterrupts =>
    () => const Stream<void>.empty();

HarnessFactory fakeHarness() {
  final factory = HarnessFactory();
  factory.register('claude', (_) => FakeAgentHarness());
  return factory;
}

DartclawApiClient unreachableClient() => DartclawApiClient(
  baseUri: Uri.parse('http://localhost:3333'),
  transport: FakeApiTransport(sendResponses: [jsonResponse(503, const <String, dynamic>{})]),
);

DartclawApiClient reachableClient() => DartclawApiClient(
  baseUri: Uri.parse('http://localhost:3333'),
  transport: FakeApiTransport(
    sendResponses: [
      jsonResponse(200, const {'status': 'ok'}),
    ],
  ),
);

WorkflowDefinition approvalThenBash() => WorkflowDefinition(
  name: 'approval-then-bash',
  description: 'Approval gate followed by a bash step',
  steps: const [
    WorkflowStep(id: 'gate', name: 'Gate', taskType: WorkflowTaskType.approval, prompts: ['Approve to continue?']),
    WorkflowStep(id: 'post', name: 'Post', taskType: WorkflowTaskType.bash, prompts: ["printf 'post-step\\n'"]),
  ],
  variables: const {},
);

WorkflowDefinition twoGates() => WorkflowDefinition(
  name: 'two-gates',
  description: 'Two approval gates around a bash step',
  steps: const [
    WorkflowStep(id: 'gate1', name: 'Gate 1', taskType: WorkflowTaskType.approval, prompts: ['Approve 1?']),
    WorkflowStep(id: 'mid', name: 'Mid', taskType: WorkflowTaskType.bash, prompts: ["printf 'mid-step\\n'"]),
    WorkflowStep(id: 'gate2', name: 'Gate 2', taskType: WorkflowTaskType.approval, prompts: ['Approve 2?']),
  ],
  variables: const {},
);

WorkflowDefinition singleBashDefinition() => WorkflowDefinition(
  name: 'seed-wf',
  description: 'Minimal single-step workflow for guard-rejection seeding',
  steps: const [
    WorkflowStep(id: 's1', name: 'Step 1', taskType: WorkflowTaskType.bash, prompts: ["printf 'ok\\n'"]),
  ],
  variables: const {},
);
