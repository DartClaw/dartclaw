import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show AgentExecution, WorkflowStepExecution;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGitGateway, InMemoryWorkflowStepExecutionRepository;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ArtifactKind,
        ContextExtractor,
        MessageService,
        OutputConfig,
        OutputFormat,
        SessionService,
        Task,
        TaskType,
        WorkflowStep,
        WorkflowTaskType;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

typedef ReviewProducer = ({String name, String stepId, String? summaryKey, String totalKey, String gatingKey});

const reviewSummaryProducers = <ReviewProducer>[
  (
    name: 'dartclaw-review',
    stepId: 'review-code',
    summaryKey: 'review_summary',
    totalKey: 'review-code.findings_count',
    gatingKey: 'review-code.gating_findings_count',
  ),
  (
    name: 'dartclaw-quick-review',
    stepId: 're-review',
    summaryKey: 'review_report_path',
    totalKey: 're-review.findings_count',
    gatingKey: 're-review.gating_findings_count',
  ),
  (
    name: 'dartclaw-architecture',
    stepId: 'architecture-review',
    summaryKey: null,
    totalKey: 'architecture-review.findings_count',
    gatingKey: 'architecture-review.gating_findings_count',
  ),
];

final class ContextExtractorTestHarness {
  late Directory tempDir;
  late String sessionsDir;
  late TaskService taskService;
  late SqliteAgentExecutionRepository agentExecutions;
  late InMemoryWorkflowStepExecutionRepository workflowStepExecutions;
  late MessageService messageService;
  late SessionService sessionService;
  late ContextExtractor extractor;

  void setUp() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_ctx_extractor_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    Directory(sessionsDir).createSync(recursive: true);

    final db = sqlite3.openInMemory();
    agentExecutions = SqliteAgentExecutionRepository(db);
    taskService = TaskService(
      SqliteTaskRepository(db),
      agentExecutionRepository: agentExecutions,
      executionTransactor: SqliteExecutionRepositoryTransactor(db),
    );
    workflowStepExecutions = InMemoryWorkflowStepExecutionRepository();
    sessionService = SessionService(baseDir: sessionsDir);
    messageService = MessageService(baseDir: sessionsDir);
    extractor = ContextExtractor(
      taskService: taskService,
      messageService: messageService,
      dataDir: tempDir.path,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
  }

  Future<void> tearDown() async {
    await taskService.dispose();
    await messageService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  }

  Future<Task> createTask() async {
    return taskService.create(
      id: 'task-1',
      title: 'Test task',
      description: 'Test',
      type: TaskType.research,
      autoStart: true,
    );
  }

  Future<Task> buildTask(
    String id, {
    String? sessionId,
    String? projectId,
    String? workflowRunId,
    String? worktreePath,
  }) async {
    await taskService.create(
      id: id,
      title: 'Test',
      description: 'Test',
      type: TaskType.research,
      autoStart: true,
      sessionId: sessionId,
      projectId: projectId,
      workflowRunId: workflowRunId,
    );
    if (worktreePath != null) {
      await taskService.updateFields(id, worktreeJson: {'path': worktreePath});
    }
    return (await taskService.get(id))!;
  }

  Future<Task> buildTaskWithWorktreeSource(String id, {String? branch, String? path}) async {
    final task = await buildTask(id);
    if (branch != null || path != null) {
      final worktreeJson = <String, dynamic>{'createdAt': '2026-01-01T00:00:00.000Z'};
      if (branch != null) worktreeJson['branch'] = branch;
      if (path != null) worktreeJson['path'] = path;
      await taskService.updateFields(task.id, worktreeJson: worktreeJson);
      return (await taskService.get(task.id))!;
    }
    return task;
  }

  WorkflowStep makeStep({String id = 'step1', Map<String, OutputConfig>? outputs}) {
    return WorkflowStep(id: id, name: 'Step 1', prompts: ['Do something'], outputs: outputs);
  }

  WorkflowStep worktreeSourceStep(String outputKey, String source) {
    return WorkflowStep(
      id: 'coding-step',
      name: 'Fix',
      taskType: WorkflowTaskType.agent,
      prompts: const ['Fix the bug'],
      outputs: {outputKey: OutputConfig(source: source)},
    );
  }

  WorkflowStep pathOutputStep(String key, {String id = 'step1'}) {
    // The canonical review-report key gets review-artifact resolution from its
    // preset (name-agnostic engine: no output-key-name magic). Other path keys
    // stay bare and fall back to the uniform `**/*` glob.
    return makeStep(
      id: id,
      outputs: {
        key: key == 'review_report_path'
            ? const OutputConfig(format: OutputFormat.path, schema: 'review_report_path')
            : const OutputConfig(format: OutputFormat.path),
      },
    );
  }

  Map<String, OutputConfig> reviewOutputs(String stepId, {String pathKey = 'review_report_path'}) => {
    pathKey: const OutputConfig(format: OutputFormat.path),
    '$stepId.findings_count': const OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
    '$stepId.gating_findings_count': const OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
  };

  Map<String, OutputConfig> reviewCountOutputs(ReviewProducer producer, {bool includeSummary = false}) {
    final outputs = <String, OutputConfig>{
      producer.totalKey: const OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
      producer.gatingKey: const OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
    };
    if (includeSummary && producer.summaryKey != null) {
      outputs[producer.summaryKey!] = const OutputConfig(format: OutputFormat.json, schema: 'verdict');
    }
    return outputs;
  }

  ContextExtractor extractorWithGit(FakeGitGateway git, {String? dataDir}) {
    return ContextExtractor(
      taskService: taskService,
      messageService: messageService,
      dataDir: dataDir ?? tempDir.path,
      workflowGitPort: git,
    );
  }

  Future<Task> buildTaskWithContext(
    String taskId,
    Map<String, Object?> context, {
    String prefix = 'Done.',
    String suffix = '',
    String? projectId,
    String? workflowRunId,
    String? worktreePath,
  }) async {
    final session = await sessionService.getOrCreateMainSession();
    await messageService.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content: '$prefix\n\n<workflow-context>${jsonEncode(context)}</workflow-context>$suffix',
    );
    return buildTask(
      taskId,
      sessionId: session.id,
      projectId: projectId,
      workflowRunId: workflowRunId,
      worktreePath: worktreePath,
    );
  }

  Future<Map<String, dynamic>> extractStepFromContext(
    ContextExtractor extractor,
    WorkflowStep step,
    String taskId,
    Map<String, Object?> context, {
    String prefix = 'Done.',
    String suffix = '\n<step-outcome>{"status":"passed"}</step-outcome>',
    String? projectId,
    String? workflowRunId,
    String? worktreePath,
  }) async {
    final task = await buildTaskWithContext(
      taskId,
      context,
      prefix: prefix,
      suffix: suffix,
      projectId: projectId,
      workflowRunId: workflowRunId,
      worktreePath: worktreePath,
    );
    return extractor.extract(step, task);
  }

  Future<Map<String, dynamic>> extractPathOutputFromContext(
    ContextExtractor extractor,
    String outputKey,
    String taskId,
    Map<String, Object?> context, {
    String stepId = 'step1',
    String prefix = 'Done.',
    String suffix = '\n<step-outcome>{"status":"passed"}</step-outcome>',
    String? projectId,
    String? workflowRunId,
    String? worktreePath,
  }) {
    return extractStepFromContext(
      extractor,
      pathOutputStep(outputKey, id: stepId),
      taskId,
      context,
      prefix: prefix,
      suffix: suffix,
      projectId: projectId,
      workflowRunId: workflowRunId,
      worktreePath: worktreePath,
    );
  }

  Future<Map<String, dynamic>> extractPathOutputFromTask(
    ContextExtractor extractor,
    String outputKey,
    String taskId, {
    String? projectId,
    String? worktreePath,
  }) async {
    final task = await buildTask(taskId, projectId: projectId, worktreePath: worktreePath);
    return extractor.extract(pathOutputStep(outputKey), task);
  }

  Future<Task> buildTaskWithAssistantMessage(
    String taskId,
    String content, {
    String? projectId,
    String? workflowRunId,
    String? worktreePath,
  }) async {
    final session = await sessionService.getOrCreateMainSession();
    await messageService.insertMessage(sessionId: session.id, role: 'assistant', content: content);
    return buildTask(
      taskId,
      sessionId: session.id,
      projectId: projectId,
      workflowRunId: workflowRunId,
      worktreePath: worktreePath,
    );
  }

  Future<Task> buildTaskWithStructuredOutput(String taskId, String structuredOutputJson, {String? sessionId}) async {
    final agentExecutionId = 'ae-$taskId';
    final workflowRunId = 'wf-$taskId';
    await agentExecutions.create(AgentExecution(id: agentExecutionId));
    await taskService.create(
      id: taskId,
      title: 'Test',
      description: 'Test',
      type: TaskType.research,
      autoStart: true,
      agentExecutionId: agentExecutionId,
      workflowRunId: workflowRunId,
    );
    await workflowStepExecutions.create(
      WorkflowStepExecution(
        taskId: taskId,
        agentExecutionId: agentExecutionId,
        workflowRunId: workflowRunId,
        stepIndex: 0,
        stepId: 'step1',
        structuredOutputJson: structuredOutputJson,
      ),
    );
    if (sessionId != null) {
      await taskService.updateFields(taskId, sessionId: sessionId);
    }
    return (await taskService.get(taskId))!;
  }

  /// Seeds a task whose persisted `WorkflowStepExecution.structuredOutput` is
  /// [envelope] (an execution-envelope payload, e.g.
  /// `{outputs: {...}, step_outcome: {...}, _envelopeVersion: 1}`), mirroring
  /// what the finalizer turn writes. Supports the project/run/worktree fields the
  /// filesystem-claim resolution paths need.
  Future<Task> buildTaskWithEnvelope(
    String taskId,
    Map<String, dynamic> envelope, {
    String? sessionId,
    String? projectId,
    String? worktreePath,
    String? workflowRunId,
  }) async {
    final agentExecutionId = 'ae-$taskId';
    final runId = workflowRunId ?? 'wf-$taskId';
    await agentExecutions.create(AgentExecution(id: agentExecutionId));
    await taskService.create(
      id: taskId,
      title: 'Test',
      description: 'Test',
      type: TaskType.research,
      autoStart: true,
      agentExecutionId: agentExecutionId,
      workflowRunId: runId,
      projectId: projectId,
    );
    if (sessionId != null) {
      await taskService.updateFields(taskId, sessionId: sessionId);
    }
    if (worktreePath != null) {
      await taskService.updateFields(taskId, worktreeJson: {'path': worktreePath});
    }
    await workflowStepExecutions.create(
      WorkflowStepExecution(
        taskId: taskId,
        agentExecutionId: agentExecutionId,
        workflowRunId: runId,
        stepIndex: 0,
        stepId: 'step1',
        structuredOutputJson: jsonEncode(envelope),
      ),
    );
    return (await taskService.get(taskId))!;
  }

  File writeFile(String root, String relativePath, String content) {
    final file = File(p.join(root, relativePath));
    file.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  Directory createWorktree(String name) => Directory(p.join(tempDir.path, name))..createSync(recursive: true);

  Directory runtimeReviewsDir(String runId, {String? dataDir}) {
    return Directory(p.join(dataDir ?? tempDir.path, 'workflows', 'runs', runId, 'runtime-artifacts', 'reviews'))
      ..createSync(recursive: true);
  }

  String runtimeReviewPath(String runId, String fileName, {String? dataDir}) {
    return p.join(runtimeReviewsDir(runId, dataDir: dataDir).path, fileName);
  }

  String writeRuntimeReview(
    String runId,
    String fileName, {
    String content = '# Integrated Review\n',
    String? dataDir,
  }) {
    final path = runtimeReviewPath(runId, fileName, dataDir: dataDir);
    File(path).writeAsStringSync(content);
    return path;
  }

  /// The host-owned per-step artifacts dir the extractor captures review
  /// reports from: `<runtime-artifacts>/steps/<stepId>[-<mapIterationIndex>]`.
  Directory stepArtifactsDir(String runId, String stepId, {int? mapIterationIndex, String? dataDir}) {
    final dirName = mapIterationIndex == null ? stepId : '$stepId-$mapIterationIndex';
    return Directory(p.join(dataDir ?? tempDir.path, 'workflows', 'runs', runId, 'runtime-artifacts', 'steps', dirName))
      ..createSync(recursive: true);
  }

  /// Writes a review report into the host-owned step artifacts dir and returns
  /// its absolute path — the deterministic capture source.
  String writeStepReview(
    String runId,
    String stepId,
    String fileName, {
    String content = '# Council Review\n',
    int? mapIterationIndex,
    String? dataDir,
  }) {
    final dir = stepArtifactsDir(runId, stepId, mapIterationIndex: mapIterationIndex, dataDir: dataDir);
    final path = p.join(dir.path, fileName);
    File(path).writeAsStringSync(content);
    return path;
  }

  FakeGitGateway gitWithUntracked(Directory worktree, Iterable<String> paths) {
    final git = FakeGitGateway()..initWorktree(worktree.path);
    for (final path in paths) {
      git.addUntracked(worktree.path, path);
    }
    return git;
  }

  void writeWorktreeFile(Directory worktree, String relativePath, String content) {
    writeFile(worktree.path, relativePath, content);
  }

  Future<Task> createTaskWithArtifact({
    String taskId = 'task-1',
    required String name,
    required String content,
    ArtifactKind kind = ArtifactKind.document,
    String? artifactId,
  }) async {
    final task = taskId == 'task-1' ? await createTask() : await buildTask(taskId);
    final file = writeFile(p.join(tempDir.path, 'tasks', taskId, 'artifacts'), name, content);
    await taskService.addArtifact(
      id: artifactId ?? 'artifact-$taskId-${p.basename(name)}',
      taskId: taskId,
      name: name,
      kind: kind,
      path: file.path,
    );
    return task;
  }
}
