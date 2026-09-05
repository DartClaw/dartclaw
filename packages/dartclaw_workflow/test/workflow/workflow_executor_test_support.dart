// Shared test harness for WorkflowExecutor concern-focused test files.
//
// Each executor_*.dart file creates a [WorkflowExecutorHarness], calls its
// setUp/tearDown from the test setUp/tearDown hooks, and uses the helper
// factories directly on the harness instance.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        BashStepPolicy,
        ContextExtractor,
        ExecutableLookupExecutor,
        EventBus,
        GateEvaluator,
        KvService,
        MessageService,
        OutputConfig,
        SessionService,
        SqliteWorkflowRunRepository,
        ProviderAuthPreflight,
        SkillIntrospector,
        StepExecutionContext,
        executionEnvelopeStepOutcomeKey,
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
        WorkflowSkillPreflightConfig,
        WorkflowStep,
        WorkflowTurnAdapter,
        WorkflowTurnOutcome,
        executionEnvelopeMarkerKey,
        executionEnvelopeOutputsKey,
        executionEnvelopeVersion;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show TaskService, WorkflowGitPortProcess;
import 'package:dartclaw_core/dartclaw_core.dart' show ProjectService;
import 'package:dartclaw_core/dartclaw_core.dart'
    show
        SqliteAgentExecutionRepository,
        SqliteExecutionRepositoryTransactor,
        SqliteTaskRepository,
        SqliteWorkflowStepExecutionRepository;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// A [ContextExtractor] whose [extract] always throws an unexpected (generic)
/// exception — neither [MissingArtifactFailure] nor [StateError]. Used to
/// exercise the dispatchers' generic extraction-failure handling, which must
/// fail the step/item (not silently proceed) on both the single-step and map paths.
final class ThrowingContextExtractor extends ContextExtractor {
  new({
    required super.taskService,
    required super.messageService,
    required super.dataDir,
    super.workflowStepExecutionRepository,
  });

  @override
  Future<Map<String, dynamic>> extract(WorkflowStep step, Task task, {Map<String, OutputConfig>? effectiveOutputs}) =>
      throw const FormatException('simulated unexpected extraction failure');
}

/// A [ContextExtractor] whose first [failures] extractions throw [error] before
/// it delegates to the real one. Injects a post-extraction validation failure
/// with a chosen exception type, which is what the step-retry comparison keys
/// on for that arm.
final class FailFirstContextExtractor extends ContextExtractor {
  new({
    required this.error,
    this.failures = 1,
    required super.taskService,
    required super.messageService,
    required super.dataDir,
    super.workflowStepExecutionRepository,
  });

  final Object error;
  final int failures;
  int _calls = 0;

  @override
  Future<Map<String, dynamic>> extract(WorkflowStep step, Task task, {Map<String, OutputConfig>? effectiveOutputs}) {
    if (_calls++ < failures) throw error;
    return super.extract(step, task, effectiveOutputs: effectiveOutputs);
  }
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
    PlatformCapabilities? platformCapabilities,
    ExecutableLookupExecutor? executableLookupExecutor,
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
        platformCapabilities: platformCapabilities,
        executableLookupExecutor: executableLookupExecutor,
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

  /// Completes [taskId] after attaching a fresh task session and seeding the
  /// execution envelope its finalizer turn would have persisted: [outputs] as
  /// the declared outputs, and [outcome]/[reason] as the step outcome.
  ///
  /// [outcomeContent] is an assistant message for the one step kind that still
  /// speaks the inline `<step-outcome>` tag — an `emitsOwnOutcome` step, whose
  /// envelope carries no `step_outcome`. Every other step resolves its outcome
  /// from the seeded envelope. When [tokenCount] is provided, a matching
  /// `session_cost:<id>` KV entry is written so the run's token accounting
  /// observes it.
  Future<void> completeTaskWithOutcome(
    String taskId, {
    String? outcome,
    String reason = '',
    Map<String, dynamic> outputs = const {},
    String? outcomeContent,
    TaskStatus finalStatus = TaskStatus.accepted,
    int? tokenCount,
  }) async {
    final session = await sessionService.createSession(type: SessionType.task);
    await taskService.updateFields(taskId, sessionId: session.id);
    if (tokenCount != null) {
      await kvService.set('session_cost:${session.id}', jsonEncode({'total_tokens': tokenCount}));
    }
    if (outcomeContent != null) {
      await messageService.insertMessage(sessionId: session.id, role: 'assistant', content: outcomeContent);
    }
    if (outcome != null || outputs.isNotEmpty) {
      await seedExecutionEnvelope(taskId, {
        executionEnvelopeOutputsKey: outputs,
        if (outcome != null) executionEnvelopeStepOutcomeKey: {'outcome': outcome, 'reason': reason},
        executionEnvelopeMarkerKey: executionEnvelopeVersion,
      });
    }
    await completeTask(taskId, status: finalStatus);
  }

  /// Seeds the step outcome a step's finalizer envelope would carry.
  Future<void> seedStepOutcome(String taskId, {required String outcome, String reason = ''}) =>
      seedExecutionEnvelope(taskId, {
        executionEnvelopeOutputsKey: const <String, dynamic>{},
        executionEnvelopeStepOutcomeKey: {'outcome': outcome, 'reason': reason},
        executionEnvelopeMarkerKey: executionEnvelopeVersion,
      });

  /// Seeds the declared-output envelope a step's finalizer turn would persist,
  /// so [outputs] reach workflow context through the normal extraction path.
  Future<void> seedDeclaredOutputs(String taskId, Map<String, dynamic> outputs) => seedExecutionEnvelope(taskId, {
    executionEnvelopeOutputsKey: outputs,
    executionEnvelopeMarkerKey: executionEnvelopeVersion,
  });

  /// The step id the executor recorded for [taskId], or null when unpersisted.
  Future<String?> stepIdForTask(String taskId) async =>
      (await workflowStepExecutionRepository.getByTaskId(taskId))?.stepId;

  /// Attaches a worktree to [taskId] so the dispatcher derives `<stepId>.branch`
  /// and `<stepId>.worktree_path` the way it does in production.
  Future<void> attachWorktree(String taskId) async {
    // A task that already settled cannot take field updates; skipping keeps the
    // helper usable from a listener that also sees terminal transitions.
    final task = await taskService.get(taskId);
    if (task == null || task.status.terminal) return;
    await taskService.updateFields(
      taskId,
      worktreeJson: {
        'path': p.join(tempDir.path, 'worktrees', taskId),
        'branch': 'story-branch-$taskId',
        'createdAt': DateTime.now().toIso8601String(),
      },
    );
  }

  /// Seeds a failed merge-resolve result when [taskId] belongs to a synthetic
  /// merge-resolve step, so the coordinator reads `merge_resolve.*` through the
  /// step's declared outputs. Any other task is left alone – a coding step's
  /// `<id>.branch` is produced by the dispatcher from the task's worktree.
  Future<void> seedMergeResolveFailure(String taskId) async {
    final stepId = await stepIdForTask(taskId);
    // An unresolvable step id means the executor's persistence ordering moved and
    // this helper would stop injecting anything — fail rather than pass vacuously.
    if (stepId == null) throw StateError('no persisted step execution for task $taskId');
    if (!stepId.startsWith('_merge_resolve_')) return;
    await seedDeclaredOutputs(taskId, const {
      'merge_resolve.outcome': 'failed',
      'merge_resolve.error_message': 'simulated failure',
      'merge_resolve.resolution_summary': '',
    });
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
    executeTurn: (sessionId, turnId, messages, {required source}) {},
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
