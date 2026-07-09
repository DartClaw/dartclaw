// Shared test harness for WorkflowExecutor concern-focused test files.
//
// Each executor_*.dart file creates a [WorkflowExecutorHarness], calls its
// setUp/tearDown from the test setUp/tearDown hooks, and uses the helper
// factories directly on the harness instance.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart' show SessionType;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        BashStepPolicy,
        ContextExtractor,
        EventBus,
        GateEvaluator,
        KvService,
        MessageService,
        OutputConfig,
        SessionService,
        ProviderAuthPreflight,
        SkillIntrospector,
        StepExecutionContext,
        Task,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowExecutor,
        WorkflowGitIntegrationBranchResult,
        WorkflowGitPort,
        WorkflowGitPromotionResult,
        WorkflowGitPromotionSuccess,
        WorkflowGitPublishResult,
        WorkflowStartResolution,
        WorkflowLoop,
        WorkflowRoleDefaults,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowSkillPreflightConfig,
        WorkflowStep,
        WorkflowStepOutputTransformer,
        WorkflowTurnAdapter,
        WorkflowTurnOutcome;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService, WorkflowGitPortProcess;
import 'package:dartclaw_core/dartclaw_core.dart' show ProjectService;
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show
        SqliteAgentExecutionRepository,
        SqliteExecutionRepositoryTransactor,
        SqliteTaskRepository,
        SqliteWorkflowRunRepository,
        SqliteWorkflowStepExecutionRepository;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// A [ContextExtractor] whose [extract] always throws an unexpected (generic)
/// exception — neither [MissingArtifactFailure] nor [StateError]. Used to
/// exercise the dispatchers' generic extraction-failure handling, which must
/// fail the step/item (not silently proceed) on both the single-step and map paths.
final class ThrowingContextExtractor extends ContextExtractor {
  ThrowingContextExtractor({
    required super.taskService,
    required super.messageService,
    required super.dataDir,
    super.workflowStepExecutionRepository,
  });

  @override
  Future<Map<String, dynamic>> extract(WorkflowStep step, Task task, {Map<String, OutputConfig>? effectiveOutputs}) =>
      throw const FormatException('simulated unexpected extraction failure');
}

/// Shared harness for WorkflowExecutor component tests.
///
/// Call [setUp] / [tearDown] in each test file's setUp/tearDown hooks.
/// Provides [makeExecutor], [makeRun], [makeDefinition], [completeTask],
/// and [executeAndCaptureSingleTask] utilities.
final class WorkflowExecutorHarness {
  late Directory tempDir;
  late String sessionsDir;
  late Database db;
  late SqliteTaskRepository taskRepository;
  late TaskService taskService;
  late SessionService sessionService;
  late MessageService messageService;
  late KvService kvService;
  late SqliteWorkflowRunRepository repository;
  late SqliteAgentExecutionRepository agentExecutionRepository;
  late SqliteWorkflowStepExecutionRepository workflowStepExecutionRepository;
  late SqliteExecutionRepositoryTransactor executionRepositoryTransactor;
  late EventBus eventBus;
  late WorkflowExecutor executor;

  void setUp() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_wf_exec_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    Directory(sessionsDir).createSync(recursive: true);

    db = sqlite3.openInMemory();
    eventBus = EventBus();
    taskRepository = SqliteTaskRepository(db);
    agentExecutionRepository = SqliteAgentExecutionRepository(db, eventBus: eventBus);
    workflowStepExecutionRepository = SqliteWorkflowStepExecutionRepository(db);
    executionRepositoryTransactor = SqliteExecutionRepositoryTransactor(db);
    taskService = TaskService(
      taskRepository,
      agentExecutionRepository: agentExecutionRepository,
      executionTransactor: executionRepositoryTransactor,
      eventBus: eventBus,
    );
    repository = SqliteWorkflowRunRepository(db);
    sessionService = SessionService(baseDir: sessionsDir);
    messageService = MessageService(baseDir: sessionsDir);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));

    executor = makeExecutor();
  }

  Future<void> tearDown() async {
    await taskService.dispose();
    await messageService.dispose();
    await kvService.dispose();
    await eventBus.dispose();
    db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  }

  WorkflowExecutor makeExecutor({
    WorkflowTurnAdapter? turnAdapter,
    WorkflowStepOutputTransformer? outputTransformer,
    ProjectService? projectService,
    ContextExtractor? contextExtractor,
    String? dataDir,
    bool wirePersistence = true,
    Map<String, String>? hostEnvironment,
    List<String>? bashStepEnvAllowlist,
    List<String>? bashStepExtraStripPatterns,
    WorkflowGitPort? workflowGitPort,
    String? defaultWorkspaceRoot,
    SkillIntrospector? skillIntrospector,
    ProviderAuthPreflight? providerAuthPreflight,
    WorkflowSkillPreflightConfig skillPreflightConfig = const WorkflowSkillPreflightConfig(),
    WorkflowRoleDefaults? roleDefaults,
    Duration serializeRemainingSettleTimeout = const Duration(seconds: 30),
  }) {
    final effectiveDataDir = dataDir ?? tempDir.path;
    return WorkflowExecutor(
      executionContext: StepExecutionContext(
        taskService: taskService,
        eventBus: eventBus,
        kvService: kvService,
        repository: repository,
        gateEvaluator: GateEvaluator(),
        contextExtractor:
            contextExtractor ??
            ContextExtractor(
              taskService: taskService,
              messageService: messageService,
              dataDir: effectiveDataDir,
              workflowStepExecutionRepository: wirePersistence ? workflowStepExecutionRepository : null,
            ),
        turnAdapter: turnAdapter,
        outputTransformer: outputTransformer,
        skillIntrospector: skillIntrospector,
        providerAuthPreflight: providerAuthPreflight,
        skillPreflightConfig: skillPreflightConfig,
        workflowGitPort: workflowGitPort ?? WorkflowGitPortProcess(),
        taskRepository: wirePersistence ? taskRepository : null,
        agentExecutionRepository: wirePersistence ? agentExecutionRepository : null,
        workflowStepExecutionRepository: wirePersistence ? workflowStepExecutionRepository : null,
        executionTransactor: wirePersistence ? executionRepositoryTransactor : null,
        projectService: projectService,
        defaultWorkspaceRoot: defaultWorkspaceRoot,
      ),
      dataDir: effectiveDataDir,
      roleDefaults: roleDefaults,
      serializeRemainingSettleTimeout: serializeRemainingSettleTimeout,
      bashStepPolicy: hostEnvironment != null || bashStepEnvAllowlist != null || bashStepExtraStripPatterns != null
          ? BashStepPolicy(
              hostEnvironment: hostEnvironment,
              envAllowlist: bashStepEnvAllowlist ?? BashStepPolicy.defaultEnvAllowlist,
              extraStripPatterns: bashStepExtraStripPatterns ?? const <String>[],
            )
          : const BashStepPolicy(),
    );
  }

  WorkflowRun makeRun(WorkflowDefinition definition, {int stepIndex = 0}) {
    final now = DateTime.now();
    return WorkflowRun(
      id: 'run-1',
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: now,
      updatedAt: now,
      currentStepIndex: stepIndex,
      definitionJson: definition.toJson(),
    );
  }

  WorkflowDefinition makeDefinition({List<WorkflowStep>? steps, int? maxTokens, List<WorkflowLoop> loops = const []}) {
    return WorkflowDefinition(
      name: 'test-workflow',
      description: 'Test workflow',
      steps:
          steps ??
          [
            const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          ],
      loops: loops,
      maxTokens: maxTokens,
    );
  }

  /// Completes [taskId] after attaching a fresh task session carrying
  /// [outcomeContent] as an assistant message (so the executor's context
  /// extractor can read a `<step-outcome>` envelope). When [tokenCount] is
  /// provided, a matching `session_cost:<id>` KV entry is written so the
  /// run's token accounting observes it.
  Future<void> completeTaskWithOutcome(
    String taskId, {
    required String outcomeContent,
    TaskStatus finalStatus = TaskStatus.accepted,
    int? tokenCount,
  }) async {
    final session = await sessionService.createSession(type: SessionType.task);
    await taskService.updateFields(taskId, sessionId: session.id);
    if (tokenCount != null) {
      await kvService.set('session_cost:${session.id}', jsonEncode({'total_tokens': tokenCount}));
    }
    await messageService.insertMessage(sessionId: session.id, role: 'assistant', content: outcomeContent);
    await completeTask(taskId, status: finalStatus);
  }

  /// Overwrites the executor-created `WorkflowStepExecution.structuredOutput`
  /// for [taskId] with [envelope], standing in for what the no-tools finalizer
  /// turn persists. Call from the queued-task listener before completing the
  /// task so outcome/output resolution reads the envelope.
  Future<void> seedExecutionEnvelope(String taskId, Map<String, dynamic> envelope) async {
    final wse = await workflowStepExecutionRepository.getByTaskId(taskId);
    await workflowStepExecutionRepository.update(wse!.copyWith(structuredOutputJson: jsonEncode(envelope)));
  }

  /// Simulates task completion: queued → running → [review →] terminal.
  Future<void> completeTask(String taskId, {TaskStatus status = TaskStatus.accepted}) async {
    try {
      await taskService.transition(taskId, TaskStatus.running, trigger: 'test');
    } on StateError {
      // May already be running.
    }
    if (status == TaskStatus.accepted || status == TaskStatus.rejected) {
      try {
        await taskService.transition(taskId, TaskStatus.review, trigger: 'test');
      } on StateError {
        // May already be in review.
      }
    }
    await taskService.transition(taskId, status, trigger: 'test');
  }

  Future<Task> executeAndCaptureSingleTask({
    required WorkflowDefinition definition,
    required WorkflowContext context,
    String runId = 'run-capture',
  }) async {
    final run = makeRun(definition).copyWith(id: runId, variablesJson: context.variables);
    await repository.insert(run);

    final taskCompleter = Completer<Task>();
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      final task = await taskService.get(e.taskId);
      if (task != null && !taskCompleter.isCompleted) {
        taskCompleter.complete(task);
      }
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();
    return taskCompleter.future;
  }
}

/// Builds a [WorkflowTurnAdapter] whose turn primitives are the standard
/// no-op fakes shared by the executor component suites: [reserveTurn] yields a
/// fixed turn id, [executeTurn] is a no-op, and [waitForOutcome] reports a
/// `completed` turn. Git seams default to a successful integration-branch
/// bootstrap and successful promotion; pass [initializeWorkflowGit],
/// [promoteWorkflowBranch], or [cleanupWorkflowGit] to override a specific
/// seam (e.g. a conflict/error promotion or a cleanup-call recorder).
///
/// The remaining seams ([resolveStartContext], [publishWorkflowBranch],
/// [cleanupWorktreeForRetry], [captureWorkflowBranchSha],
/// [captureAndCleanWorktreeForRetry], [runResolverAttemptUnderLock]) are plain
/// pass-throughs: left null unless overridden, so merge-resolve / publish /
/// start-context suites can supply just the seam they exercise without
/// re-inlining the no-op turn primitives or the git-bootstrap default.
WorkflowTurnAdapter standardTurnAdapter({
  String turnId = 'turn-1',
  String integrationBranch = 'dartclaw/integration/test',
  String? workflowWorkspaceDir,
  Future<WorkflowStartResolution> Function(
    WorkflowDefinition definition,
    Map<String, String> variables, {
    String? projectId,
    bool allowDirtyLocalPath,
  })?
  resolveStartContext,
  Future<WorkflowGitIntegrationBranchResult> Function({
    required String runId,
    required String projectId,
    required String baseRef,
    required bool perMapItem,
  })?
  initializeWorkflowGit,
  Future<WorkflowGitPromotionResult> Function({
    required String runId,
    required String projectId,
    required String branch,
    required String integrationBranch,
    required String strategy,
    String? storyId,
  })?
  promoteWorkflowBranch,
  Future<WorkflowGitPublishResult> Function({required String runId, required String projectId, required String branch})?
  publishWorkflowBranch,
  Future<void> Function({
    required String runId,
    required String projectId,
    required String status,
    required bool preserveWorktrees,
  })?
  cleanupWorkflowGit,
  Future<String?> Function({required String projectId, required String branch, required String preAttemptSha})?
  cleanupWorktreeForRetry,
  Future<String?> Function({required String projectId, required String branch})? captureWorkflowBranchSha,
  Future<({String? sha, bool isDirty, String? cleanupError})> Function({
    required String projectId,
    required String branch,
    String? preAttemptSha,
  })?
  captureAndCleanWorktreeForRetry,
  Future<T> Function<T>({required String projectId, required Future<T> Function() body})? runResolverAttemptUnderLock,
}) {
  return WorkflowTurnAdapter(
    reserveTurn: (_) => Future.value(turnId),
    executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
    waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
    workflowWorkspaceDir: workflowWorkspaceDir,
    resolveStartContext: resolveStartContext,
    initializeWorkflowGit:
        initializeWorkflowGit ??
        ({required runId, required projectId, required baseRef, required perMapItem}) async =>
            WorkflowGitIntegrationBranchResult(integrationBranch: integrationBranch),
    promoteWorkflowBranch:
        promoteWorkflowBranch ??
        ({
          required runId,
          required projectId,
          required branch,
          required integrationBranch,
          required strategy,
          String? storyId,
        }) async => const WorkflowGitPromotionSuccess(commitSha: 'abc123'),
    publishWorkflowBranch: publishWorkflowBranch,
    cleanupWorkflowGit: cleanupWorkflowGit,
    cleanupWorktreeForRetry: cleanupWorktreeForRetry,
    captureWorkflowBranchSha: captureWorkflowBranchSha,
    captureAndCleanWorktreeForRetry: captureAndCleanWorktreeForRetry,
    runResolverAttemptUnderLock: runResolverAttemptUnderLock,
  );
}
