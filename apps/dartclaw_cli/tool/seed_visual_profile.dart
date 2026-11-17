import 'dart:io';

import 'package:args/args.dart';
import 'package:dartclaw_cli/src/commands/config_loader.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show resolveDatabaseDsn;
import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('config', mandatory: true)
    ..addOption('data-dir');
  try {
    final options = parser.parse(args);
    final configPath = resolveCliConfigPath(configPath: options.option('config'));
    if (!File(configPath).existsSync()) throw FileSystemException('Visual profile config not found', configPath);
    final dataDir = options.option('data-dir');
    final config = loadCliConfig(configPath: configPath, cliOverrides: {'data_dir': ?dataDir});
    final factory = postgresBackendFactory(
      config.database,
      resolveDsn: (database) =>
          resolveDatabaseDsn(database, credentials: CredentialRegistry(credentials: config.credentials)),
    );
    final backend = await factory(config.dartclawDbPath);
    try {
      await PostgresSchemaGate.prepare(backend, databaseIdentity: 'visual profile PostgreSQL');
      await seedVisualProfile(backend: backend, dataDir: config.server.dataDir);
    } finally {
      await backend.close();
    }
  } on Object catch (error) {
    stderr.writeln('Visual profile seed failed: $error');
    exitCode = 1;
  }
}

/// Adds the committed visual fixtures to a prepared [backend].
///
/// Existing fixtures keep their state across launches. Artifact paths follow [dataDir].
Future<void> seedVisualProfile({required DatabaseBackend backend, required String dataDir, DateTime? now}) async {
  final timestamp = now ?? DateTime.now();
  final root = p.normalize(p.absolute(dataDir));
  final executions = DatabaseAgentExecutionRepository(backend);
  final tasks = DatabaseTaskRepository(backend);
  final steps = DatabaseWorkflowStepExecutionRepository(backend);
  final runs = DatabaseWorkflowRunRepository(backend);
  final transactor = DatabaseExecutionRepositoryTransactor(backend);

  Future<void> writeArtifact(_TaskFixture fixture, {DateTime? createdAt}) async {
    final name = fixture.artifact;
    if (name == null) return;
    final path = p.join(root, 'tasks', fixture.id, 'artifacts', name);
    final existing = createdAt == null ? await tasks.getArtifactById(fixture.id) : null;
    if (createdAt == null) {
      if (existing == null ||
          existing.taskId != fixture.id ||
          existing.name != name ||
          existing.kind != ArtifactKind.document ||
          existing.path == path) {
        return;
      }
      createdAt = existing.createdAt;
    }
    if (!File(path).existsSync()) throw FileSystemException('Visual profile artifact not found', path);
    // PostgreSQL can outlive the launcher's temporary copy of the fixture files.
    if (existing != null) {
      await tasks.deleteArtifact(existing.id);
    }
    await tasks.insertArtifact(
      TaskArtifact(
        id: fixture.id,
        taskId: fixture.id,
        name: name,
        kind: ArtifactKind.document,
        path: path,
        createdAt: createdAt,
      ),
    );
  }

  Future<void> insertTask(
    _TaskFixture fixture,
    DateTime settledAt, {
    WorkflowRun? run,
    WorkflowDefinition? definition,
  }) async {
    if (await tasks.getById(fixture.id) != null) {
      await writeArtifact(fixture);
      return;
    }
    final startedAt = settledAt.subtract(const Duration(minutes: 1));
    final createdAt = startedAt.subtract(const Duration(seconds: 5));
    final execution = AgentExecution(
      id: fixture.id,
      sessionId: fixture.sessionId,
      startedAt: startedAt,
      completedAt: settledAt,
    );
    final stepIndex = definition == null ? null : _stepIndex(definition, fixture.stepId!);
    final step = stepIndex == null ? null : definition!.steps[stepIndex];
    final task =
        Task(
              id: fixture.id,
              title: fixture.title,
              description: fixture.description,
              acceptanceCriteria: fixture.acceptanceCriteria,
              createdAt: createdAt,
              agentExecutionId: execution.id,
              workflowRunId: run?.id,
              stepIndex: stepIndex,
            )
            .transition(TaskStatus.queued, now: createdAt)
            .transition(TaskStatus.running, now: startedAt)
            .transition(fixture.status, now: settledAt);

    await executions.create(execution);
    await tasks.insert(task);
    if (step != null) {
      await steps.create(
        WorkflowStepExecution(
          taskId: task.id,
          agentExecutionId: execution.id,
          workflowRunId: run!.id,
          stepIndex: stepIndex!,
          stepId: step.id,
          stepType: step.taskType.toJson(),
        ),
      );
    }
    await writeArtifact(fixture, createdAt: settledAt);
  }

  await transactor.transaction(() async {
    for (final (i, fixture) in _standaloneTasks.indexed) {
      await insertTask(fixture, timestamp.subtract(Duration(minutes: 20 - i * 3)));
    }

    for (final (i, fixture) in _workflows.indexed) {
      if (await runs.getById(fixture.id) != null) {
        for (final task in fixture.tasks) {
          await writeArtifact(task);
        }
        continue;
      }
      final sourcePath = 'workflows/${fixture.definition}.yaml';
      final source = embeddedWorkflowAssets[sourcePath];
      if (source == null) throw StateError('Visual profile workflow asset missing: $sourcePath');
      final definition = const WorkflowDefinitionParser().parse(source, sourcePath: sourcePath);
      final settledAt = timestamp.subtract(Duration(minutes: 10 - i * 3));
      final run = _workflowRun(fixture, definition, settledAt);
      await runs.insert(run);
      for (final (taskIndex, task) in fixture.tasks.indexed) {
        await insertTask(
          task,
          settledAt.subtract(Duration(minutes: fixture.tasks.length - taskIndex)),
          run: run,
          definition: definition,
        );
      }
    }
  });
}

WorkflowRun _workflowRun(_WorkflowFixture fixture, WorkflowDefinition definition, DateTime settledAt) {
  final approvalIndex = fixture.status == WorkflowRunStatus.awaitingApproval
      ? _stepIndex(definition, 'plan-approval')
      : null;
  final approval = approvalIndex == null ? null : definition.steps[approvalIndex];
  if (approval != null && approval.taskType != WorkflowTaskType.approval) {
    throw StateError('Visual profile requires ${approval.id} to be an approval step');
  }
  final approvalMeta = <String, dynamic>{
    if (approval != null) ...{
      '${approval.id}.status': 'pending',
      '${approval.id}.approval.status': 'pending',
      '${approval.id}.approval.message': 'Review the plan before any story is implemented: plan-summary.md',
      '${approval.id}.approval.requested_at': settledAt.toIso8601String(),
      '${approval.id}.tokenCount': 0,
    },
  };
  final context = WorkflowContext(data: {...fixture.context, ...approvalMeta}, variables: fixture.variables);
  return WorkflowRun(
    id: fixture.id,
    definitionName: definition.name,
    status: fixture.status,
    definitionJson: definition.toJson(),
    variablesJson: fixture.variables,
    contextJson: {
      ...context.toJson(),
      ...approvalMeta,
      if (approval != null) ...{'_approval.pending.stepId': approval.id, '_approval.pending.stepIndex': approvalIndex},
    },
    startedAt: settledAt.subtract(const Duration(minutes: 8)),
    updatedAt: settledAt,
    completedAt: fixture.status.terminal ? settledAt : null,
    currentStepIndex: switch (fixture.status) {
      WorkflowRunStatus.completed => definition.steps.length,
      WorkflowRunStatus.failed => _stepIndex(definition, fixture.tasks.last.stepId!),
      _ => approvalIndex! + 1,
    },
    errorMessage: approval == null ? fixture.errorMessage : 'approval required: ${approval.id}',
  );
}

int _stepIndex(WorkflowDefinition definition, String stepId) {
  final index = definition.steps.indexWhere((step) => step.id == stepId);
  if (index == -1) throw StateError('Visual profile step ${definition.name}/$stepId is missing');
  return index;
}

typedef _TaskFixture = ({
  String id,
  String sessionId,
  String title,
  String description,
  TaskStatus status,
  String? stepId,
  String? acceptanceCriteria,
  String? artifact,
});

const List<_TaskFixture> _standaloneTasks = [
  (
    id: '35deacb6-7c33-47db-8dc6-4bf1a2a68dc8',
    sessionId: '13fbb8b0-a1f5-4d08-b883-210ee58d4296',
    title: 'Review runtime output',
    description: 'Create a markdown summary of the seeded workspace status.',
    status: TaskStatus.accepted,
    stepId: null,
    acceptanceCriteria: 'Produce a concise markdown document.',
    artifact: 'answer.md',
  ),
  (
    id: '157dc0bb-7c00-4a3a-8d26-8a99d4b7aad6',
    sessionId: 'cfa9a4f8-c45c-4099-8352-7d3c06337134',
    title: 'Draft task review',
    description: 'Create a task without auto-start to inspect the draft flow.',
    status: TaskStatus.failed,
    stepId: null,
    acceptanceCriteria: 'Should provide a clear way to start the task.',
    artifact: null,
  ),
  (
    id: '8e7eeab8-8e32-4f14-8687-0378f4591b2e',
    sessionId: 'd546c143-18ad-4f1b-8fdd-c6548af7d54c',
    title: 'E2E Test Task',
    description: 'Summarize the README file and list key features',
    status: TaskStatus.review,
    stepId: null,
    acceptanceCriteria: null,
    artifact: null,
  ),
];

typedef _WorkflowFixture = ({
  String id,
  String definition,
  WorkflowRunStatus status,
  Map<String, String> variables,
  Map<String, dynamic> context,
  String? errorMessage,
  List<_TaskFixture> tasks,
});

const List<_WorkflowFixture> _workflows = [
  (
    id: '22222222-2222-4222-8222-222222222222',
    definition: 'implement-story',
    status: WorkflowRunStatus.completed,
    variables: {'FEATURE': 'Session export'},
    context: {
      'detect-spec-input.status': 'accepted',
      'step.spec.outcome': 'skipped',
      'implement.status': 'accepted',
      'integrated-review.status': 'accepted',
      'review-aggregate.status': 'accepted',
      'step.remediate.outcome': 'skipped',
      'step.re-review.outcome': 'skipped',
    },
    errorMessage: null,
    tasks: [
      (
        id: '42222222-2222-4222-8222-000000000010',
        sessionId: '52222222-2222-4222-8222-222222222222',
        title: 'implement-story · Ship',
        description: 'Record the completed implement-story run for session export and summarize what shipped.',
        status: TaskStatus.accepted,
        stepId: 'ship',
        acceptanceCriteria: null,
        artifact: 'session-export-spec.md',
      ),
    ],
  ),
  (
    id: '33333333-3333-4333-8333-333333333333',
    definition: 'code-review',
    status: WorkflowRunStatus.failed,
    variables: {'TARGET': 'Workflow card spacing'},
    context: {},
    errorMessage: 'Remediate Findings failed: the working tree contains conflicting changes.',
    tasks: [
      (
        id: '43333333-3333-4333-8333-000000000005',
        sessionId: '53333333-3333-4333-8333-333333333333',
        title: 'code-review · Review Code',
        description: 'Review the workflow card spacing and record the findings.',
        status: TaskStatus.accepted,
        stepId: 'review-code',
        acceptanceCriteria: null,
        artifact: 'workflow-card-review.md',
      ),
      (
        id: 'c27b0349-b3ef-44ee-b6ae-6fc004c662d0',
        sessionId: 'e1d6ace1-6849-4e24-95a6-f857953881d6',
        title: 'code-review · Remediate Findings',
        description: 'Remediate the issues from the workflow card spacing review.',
        status: TaskStatus.failed,
        stepId: 'remediate',
        acceptanceCriteria: null,
        artifact: null,
      ),
    ],
  ),
  (
    id: '11111111-1111-4111-8111-111111111111',
    definition: 'implement-prd',
    status: WorkflowRunStatus.awaitingApproval,
    variables: {'FEATURE': 'Welcome dashboard', 'PLAN_REVIEW': 'true'},
    context: {'plan': 'plan-summary.md'},
    errorMessage: null,
    tasks: [
      (
        id: '8d9f1f64-81a1-4ac1-be99-0dead1379c02',
        sessionId: 'a1977f79-dd7e-43ae-a971-ca13c08c7a17',
        title: 'implement-prd · Discover Plan State',
        description: 'Locate the planning documents for the welcome dashboard.',
        status: TaskStatus.accepted,
        stepId: 'discover-plan-state',
        acceptanceCriteria: null,
        artifact: null,
      ),
      (
        id: '41111111-1111-4111-8111-000000000010',
        sessionId: '51111111-1111-4111-8111-111111111111',
        title: 'implement-prd · Plan Stories and Specs',
        description: 'Write the implementation plan for the welcome dashboard.',
        status: TaskStatus.accepted,
        stepId: 'plan',
        acceptanceCriteria: null,
        artifact: 'plan-summary.md',
      ),
    ],
  ),
];
