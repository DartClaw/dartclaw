@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../../packages/dartclaw_core/test/storage/postgres_live_support.dart';
import '../../tool/seed_visual_profile.dart';

void main() {
  final now = DateTime.utc(2026, 4, 15, 12);
  late String dataDir;

  setUpAll(() async {
    final runner = (await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_cli/src/runner.dart')))!;
    dataDir = p.normalize(p.join(p.dirname(p.fromUri(runner)), '../../../../dev/testing/profiles/visual/data'));
  });

  test('seeds all task and run states and links every committed artifact and task session', () async {
    await withPostgresBackend((backend, namespace) async {
      await PostgresSchemaGate.prepare(backend, databaseIdentity: namespace);
      await seedVisualProfile(backend: backend, dataDir: dataDir, now: now);

      final taskRepository = DatabaseTaskRepository(backend);
      final runRepository = DatabaseWorkflowRunRepository(backend);
      final stepRepository = DatabaseWorkflowStepExecutionRepository(backend);
      final executionRepository = DatabaseAgentExecutionRepository(backend);
      final tasks = await taskRepository.list();
      final runs = await runRepository.list();
      final tasksById = {for (final task in tasks) task.id: task};

      expect(
        {for (final task in tasks.where((task) => task.workflowRunId == null)) task.id: task.status},
        {
          '35deacb6-7c33-47db-8dc6-4bf1a2a68dc8': TaskStatus.accepted,
          '157dc0bb-7c00-4a3a-8d26-8a99d4b7aad6': TaskStatus.failed,
          '8e7eeab8-8e32-4f14-8687-0378f4591b2e': TaskStatus.review,
        },
      );
      expect(tasks, hasLength(8));
      expect(
        runs.map((run) => run.status),
        unorderedEquals([WorkflowRunStatus.completed, WorkflowRunStatus.failed, WorkflowRunStatus.awaitingApproval]),
      );

      final sessions = await _taskSessions(dataDir);
      expect(sessions.keys, unorderedEquals(tasksById.keys));
      expect(
        (await executionRepository.list()).map((execution) => execution.id),
        unorderedEquals(tasks.map((task) => task.agentExecutionId)),
      );
      for (final task in tasks) {
        final execution = await executionRepository.get(task.agentExecutionId!);
        expect(execution?.sessionId, sessions[task.id]!.id, reason: task.id);
        expect(task.sessionId, execution?.sessionId, reason: task.id);
        expect(task.createdAt.isBefore(task.startedAt!), isTrue, reason: task.id);
        expect(task.startedAt!.isBefore(now), isTrue, reason: task.id);
        if (task.status.terminal) {
          expect(task.completedAt!.isAfter(task.startedAt!), isTrue, reason: task.id);
          expect(task.completedAt!.isAfter(now), isFalse, reason: task.id);
        } else {
          expect(task.completedAt, isNull, reason: task.id);
        }
      }

      final messages = MessageService(baseDir: p.join(dataDir, 'sessions'));
      try {
        for (final task in tasks.where((task) => task.workflowRunId == null)) {
          final first = (await messages.getMessages(task.sessionId!)).first;
          expect(first.content, startsWith('## Task: ${task.title}\n\n${task.description}'));
        }
      } finally {
        await messages.dispose();
      }

      final artifactDirectories = Directory(p.join(dataDir, 'tasks')).listSync().whereType<Directory>();
      final artifactsByTask = <String, List<TaskArtifact>>{};
      for (final task in tasks) {
        artifactsByTask[task.id] = await taskRepository.listArtifactsByTask(task.id);
      }
      expect(
        artifactDirectories.map((directory) => p.basename(directory.path)),
        unorderedEquals(artifactsByTask.entries.where((e) => e.value.isNotEmpty).map((e) => e.key)),
      );
      for (final directory in artifactDirectories) {
        final artifacts = artifactsByTask[p.basename(directory.path)]!;
        final paths = Directory(p.join(directory.path, 'artifacts'))
            .listSync()
            .whereType<File>()
            .map((file) => file.path);
        expect(artifacts.map((artifact) => artifact.path), unorderedEquals(paths));
        for (final artifact in artifacts) {
          expect(artifact.name, p.basename(artifact.path));
          expect(artifact.kind, ArtifactKind.document);
          expect(File(artifact.path).existsSync(), isTrue);
        }
      }

      for (final run in runs) {
        final definition = WorkflowDefinition.fromJson(run.definitionJson);
        final sourcePath = 'workflows/${run.definitionName}.yaml';
        final builtIn = const WorkflowDefinitionParser().parse(
          embeddedWorkflowAssets[sourcePath]!,
          sourcePath: sourcePath,
        );
        expect(definition.toJson(), builtIn.toJson());
        final stepTasks = await taskRepository.listByWorkflowRunIds([run.id]);
        final steps = await stepRepository.listByRunId(run.id);
        final expectedStatuses = switch (run.status) {
          WorkflowRunStatus.completed => [TaskStatus.accepted],
          WorkflowRunStatus.failed => [TaskStatus.accepted, TaskStatus.failed],
          WorkflowRunStatus.awaitingApproval => [TaskStatus.accepted, TaskStatus.accepted],
          _ => fail('Unexpected workflow status ${run.status}'),
        };
        expect(stepTasks.map((task) => task.status), unorderedEquals(expectedStatuses));
        expect(steps.map((step) => step.taskId), unorderedEquals(stepTasks.map((task) => task.id)));
        for (final step in steps) {
          final task = tasksById[step.taskId]!;
          final storedStep = definition.steps[step.stepIndex];
          expect(step.stepId, storedStep.id);
          expect(step.stepType, storedStep.taskType.toJson());
          expect(task.stepIndex, step.stepIndex);
          expect(task.agentExecutionId, step.agentExecutionId);
          expect(task.workflowRunId, step.workflowRunId);
          expect(
            stepStatusFromTask(run, step.stepIndex, task, stepId: step.stepId),
            task.status == TaskStatus.failed ? 'failed' : 'completed',
          );
        }
        expect(run.startedAt.isBefore(run.updatedAt), isTrue);
        expect(run.updatedAt.isAfter(now), isFalse);
        if (run.status.terminal) expect(run.completedAt, run.updatedAt);
        if (run.status == WorkflowRunStatus.failed) expect(run.errorMessage, isNotEmpty);
        if (run.status == WorkflowRunStatus.awaitingApproval) {
          const stepId = 'plan-approval';
          expect(run.definitionName, 'implement-prd');
          expect(run.variablesJson['PLAN_REVIEW'], 'true');
          expect(run.completedAt, isNull);
          expect(run.errorMessage, 'approval required: plan-approval');
          final index = run.contextJson['_approval.pending.stepIndex'] as int;
          expect(run.contextJson['_approval.pending.stepId'], stepId);
          expect(run.currentStepIndex, index + 1);
          expect(definition.steps[index].id, stepId);
          expect(definition.steps[index].taskType, WorkflowTaskType.approval);
          expect(steps.map((step) => step.stepIndex), everyElement(lessThan(index)));
          expect(run.contextJson['$stepId.status'], 'pending');
          expect(run.contextJson['$stepId.approval.status'], 'pending');
          expect(run.contextJson['$stepId.tokenCount'], 0);
          expect(run.contextJson['$stepId.approval.requested_at'], run.updatedAt.toIso8601String());
          expect(
            workflowContextValue(run, '$stepId.approval.message'),
            'Review the plan before any story is implemented: plan-summary.md',
          );
        }
      }

      await seedVisualProfile(backend: backend, dataDir: dataDir, now: now.add(const Duration(days: 1)));
      expect(
        (await taskRepository.list()).map((task) => task.toJson()),
        unorderedEquals(tasks.map((task) => task.toJson())),
      );
      expect((await runRepository.list()).map((run) => run.toJson()), unorderedEquals(runs.map((run) => run.toJson())));
      for (final entry in artifactsByTask.entries) {
        expect(
          (await taskRepository.listArtifactsByTask(entry.key)).map((artifact) => artifact.toJson()),
          unorderedEquals(entry.value.map((artifact) => artifact.toJson())),
        );
      }
    });
  });

  test('reusing PostgreSQL with a fresh profile directory keeps artifact files reachable', () async {
    final firstDataDir = await Directory.systemTemp.createTemp('dartclaw-visual-seed-');
    addTearDown(() async {
      if (await firstDataDir.exists()) await firstDataDir.delete(recursive: true);
    });
    final source = Directory(p.join(dataDir, 'tasks'));
    for (final artifact in source.listSync(recursive: true).whereType<File>()) {
      final target = File(p.join(firstDataDir.path, 'tasks', p.relative(artifact.path, from: source.path)));
      await target.parent.create(recursive: true);
      await artifact.copy(target.path);
    }

    await withPostgresBackend((backend, namespace) async {
      await PostgresSchemaGate.prepare(backend, databaseIdentity: namespace);
      await seedVisualProfile(backend: backend, dataDir: firstDataDir.path, now: now);

      final tasks = DatabaseTaskRepository(backend);
      final runs = DatabaseWorkflowRunRepository(backend);
      final firstTasks = await tasks.list();
      final firstRuns = await runs.list();
      final firstArtifacts = [for (final task in firstTasks) ...await tasks.listArtifactsByTask(task.id)];
      expect(firstArtifacts, isNotEmpty);
      await firstDataDir.delete(recursive: true);
      await seedVisualProfile(backend: backend, dataDir: dataDir, now: now.add(const Duration(days: 1)));

      expect(
        (await tasks.list()).map((task) => task.toJson()),
        unorderedEquals(firstTasks.map((task) => task.toJson())),
      );
      expect((await runs.list()).map((run) => run.toJson()), unorderedEquals(firstRuns.map((run) => run.toJson())));
      final artifacts = [for (final task in firstTasks) ...await tasks.listArtifactsByTask(task.id)];
      expect(
        artifacts.map((artifact) => artifact.toJson()),
        unorderedEquals(
          firstArtifacts.map((artifact) {
            final path = p.join(dataDir, p.relative(artifact.path, from: firstDataDir.path));
            expect(File(path).existsSync(), isTrue);
            return {...artifact.toJson(), 'path': path};
          }),
        ),
      );
    });
  });

  test('a missing seed column fails with PostgreSQL SQLSTATE 42703 and rolls back all writes', () async {
    await withPostgresBackend((backend, namespace) async {
      await PostgresSchemaGate.prepare(backend, databaseIdentity: namespace);
      await backend.execute('ALTER TABLE task_artifacts RENAME COLUMN name TO renamed_name');
      try {
        await expectLater(
          seedVisualProfile(backend: backend, dataDir: dataDir, now: now),
          throwsA(isA<StorageQueryException>().having((error) => error.sqlState, 'undefined column', '42703')),
        );
      } finally {
        await backend.execute('ALTER TABLE task_artifacts RENAME COLUMN renamed_name TO name');
      }
      expect(await DatabaseTaskRepository(backend).list(), isEmpty);
      expect(await DatabaseAgentExecutionRepository(backend).list(), isEmpty);
      expect(await DatabaseWorkflowRunRepository(backend).list(), isEmpty);
    });
  });
}

Future<Map<String, Session>> _taskSessions(String dataDir) async {
  final taskSessions = <String, Session>{};
  final baseDir = p.join(dataDir, 'sessions');
  for (final directory in Directory(baseDir).listSync().whereType<Directory>()) {
    final file = File(p.join(directory.path, 'meta.json'));
    if (!file.existsSync()) continue;
    final metadata = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final key = metadata['channelKey'];
    if (key is! String || !key.startsWith('agent:main:task:')) continue;
    final id = SessionKey.parse(key).identifiers;
    final session = Session.fromJson(metadata);
    expect(session.id, p.basename(directory.path));
    expect(session.type, SessionType.task);
    expect(taskSessions, isNot(contains(id)), reason: key);
    taskSessions[id] = session;
  }
  return taskSessions;
}
