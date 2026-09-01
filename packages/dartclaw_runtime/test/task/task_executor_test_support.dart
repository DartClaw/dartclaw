// Shared setUp/tearDown harness for TaskExecutor-level tests.
//
// Used by task_executor_test.dart, retry_enforcement_test.dart, and
// budget_enforcement_test.dart to share the standard topology:
//   tempDir → sessions, messages, tasks, turns, collector → tearDown.
//
// Tests that need additional fields (kvService, workflow repos, goals) declare
// those locally on top of the shared base. Tests that need a different TaskService
// (e.g. one backed by a shared DB with workflow repos) may replace [tasks] and
// [collector] after calling [setUp]; pass [tasksDispose] to [tearDown] in that
// case so the harness doesn't double-dispose the default instance.
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show SqliteWorkflowRunRepository, WorkflowRun, WorkflowRunRepository, WorkflowStepExecutionRepository;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Blocks a step prompt carrying the `BLOCK_WORKFLOW_PROMPT` sentinel.
///
/// The shared double, not a local `Guard` subclass: what these suites prove is
/// that the turn loop calls `GuardChain.evaluateMessageReceived` and honours a
/// block, so the guard's own rule only has to be observable.
FakeGuard _workflowPromptGuard() => FakeGuard(
  name: 'workflow_prompt',
  category: 'content',
  evaluator: (context) =>
      context.hookPoint == 'messageReceived' && context.messageContent?.contains('BLOCK_WORKFLOW_PROMPT') == true
      ? GuardVerdict.block('Workflow prompt refused by the fixture guard')
      : GuardVerdict.pass(),
);

/// Shared topology harness for [TaskExecutor] tests.
///
/// Call [setUp] in the test group setUp hook and [tearDown] in tearDown.
/// Access [tempDir], [sessionsDir], [workspaceDir], [sessions], [messages],
/// [tasks], [turns], [collector] directly from tests.
///
/// Tests that need a workflow-aware [TaskService] may replace [tasks] and
/// [collector] after [setUp] returns, then pass a [tasksDispose] callback to
/// [tearDown] so the harness skips disposing the default instance.
final class TaskExecutorTestHarness {
  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late TaskService tasks;
  late TurnManager turns;
  late ArtifactCollector collector;
  late GuardChain workflowGuardChain;
  late TaskToolFilterGuard workflowToolFilterGuard;

  final List<ExecutionCoordinator> _ownedWorkflowCoordinators = [];

  /// Default [TaskService] created by [setUp], used for disposal tracking.
  late TaskService _defaultTasks;

  final AgentHarness worker;

  new(this.worker);

  Future<void> setUp({
    String tempPrefix = 'dartclaw_executor_test_',
    MessageService Function(String baseDir)? messageServiceFactory,
    TaskRepository Function(Database database)? taskRepositoryFactory,
  }) async {
    tempDir = Directory.systemTemp.createTempSync(tempPrefix);
    sessionsDir = p.join(tempDir.path, 'sessions');
    // Workspace must NOT be inside dataDir — ArtifactCollector excludes
    // files within dataDir to prevent collecting internal metadata.
    workspaceDir = Directory.systemTemp.createTempSync('${tempPrefix}ws_').path;
    Directory(sessionsDir).createSync(recursive: true);

    sessions = SessionService(baseDir: sessionsDir);
    messages = messageServiceFactory?.call(sessionsDir) ?? MessageService(baseDir: sessionsDir);
    final taskDatabase = sqlite3.openInMemory();
    _defaultTasks = TaskService(taskRepositoryFactory?.call(taskDatabase) ?? SqliteTaskRepository(taskDatabase));
    tasks = _defaultTasks;
    turns = TurnManager(
      turnLimits: const TurnLimitsConfig.defaults(),
      messages: messages,
      worker: worker,
      behavior: BehaviorFileService(workspaceDir: workspaceDir),
      sessions: sessions,
    );
    workflowToolFilterGuard = TaskToolFilterGuard();
    workflowGuardChain = GuardChain(guards: [_workflowPromptGuard(), workflowToolFilterGuard]);
    collector = ArtifactCollector(tasks: tasks, sessionsDir: sessionsDir, dataDir: tempDir.path);
  }

  /// Builds a [TaskExecutor] wired to this harness's [tasks]/[sessions]/
  /// [messages]/[collector] plus any workflow-specific services a test needs.
  ///
  /// Collapses the per-test `TaskExecutor(services: TaskExecutorServices(...))`
  /// boilerplate: every collaborator beyond the shared topology is an optional
  /// named parameter, so a test only passes what it exercises (a worktree
  /// manager, a project service, etc.). Tests that reassign
  /// [tasks]/[collector] after [setUp] (e.g. to a workflow-aware [TaskService])
  /// get the replacement automatically.
  TaskExecutor buildWorkflowExecutor({
    WorktreeManager? worktreeManager,
    ProjectService? projectService,
    WorkflowRunRepository? workflowRunRepository,
    WorkflowStepExecutionRepository? workflowStepExecutionRepository,
    TaskEventRecorder? eventRecorder,
    TurnTraceService? traceService,
    KvService? kvService,
    EventBus? eventBus,
    TurnManager? turnManager,
    HarnessFactory? harnessFactory,
    Future<void> Function(String taskId)? onAutoAccept,
    TaskExecutorLimits limits = const TaskExecutorLimits(),
    ExecutionPolicyResolver? policyResolver,
    Duration pollInterval = const Duration(milliseconds: 10),
    String? currentDirectory,
  }) {
    final selectedTurns = turnManager ?? _buildWorkflowTurns();
    return TaskExecutor(
      services: TaskExecutorServices(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        artifactCollector: collector,
        worktreeManager: worktreeManager,
        projectService: projectService,
        workflowRunRepository: workflowRunRepository,
        workflowStepExecutionRepository: workflowStepExecutionRepository,
        eventRecorder: eventRecorder,
        traceService: traceService,
        kvService: kvService,
        eventBus: eventBus,
        policyResolver: policyResolver,
      ),
      runners: TaskExecutorRunners(turns: selectedTurns),
      limits: limits,
      onAutoAccept: onAutoAccept,
      pollInterval: pollInterval,
      currentDirectory: currentDirectory ?? workspaceDir,
    );
  }

  TurnManager _buildWorkflowTurns() {
    final primary = turns.executions.primary!;
    final coordinator = ExecutionCoordinator(
      providerCapacities: const {'claude': 1, 'codex': 1},
      primary: primary,
      admitExecution: (request) => primary.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primary.releaseAdmission,
      createWorker: (request) async => TurnRunner(
        turnLimits: const TurnLimitsConfig.defaults(),
        harness: worker,
        messages: messages,
        behavior: BehaviorFileService(workspaceDir: workspaceDir),
        sessions: sessions,
        guardChain: workflowGuardChain,
        taskToolFilterGuard: workflowToolFilterGuard,
        providerId: request.providerId,
        executionPolicy: request.policy,
      ),
    );
    _ownedWorkflowCoordinators.add(coordinator);
    return TurnManager.fromCoordinator(turnLimits: const TurnLimitsConfig.defaults(), coordinator: coordinator);
  }

  Future<void> tearDown({
    TaskExecutor? executor,
    Future<void> Function()? workerDispose,
    Future<void> Function()? tasksDispose,
  }) async {
    if (executor != null) await executor.stop();
    for (final coordinator in _ownedWorkflowCoordinators) {
      await coordinator.dispose();
    }
    _ownedWorkflowCoordinators.clear();
    if (tasksDispose != null) {
      // Test replaced the default TaskService — dispose both.
      if (!identical(tasks, _defaultTasks)) await _defaultTasks.dispose();
      await tasksDispose();
    } else {
      await _defaultTasks.dispose();
    }
    await messages.dispose();
    if (workerDispose != null) await workerDispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    final wsDir = Directory(workspaceDir);
    if (wsDir.existsSync()) wsDir.deleteSync(recursive: true);
  }
}

/// Polls [tasks] until [taskId] leaves the running/queued states (or any of
/// [until], when provided), bounded by [attempts] × [step].
///
/// The single sanctioned real-time wait in the executor suite: asynchronous
/// worker completion is not always observable through microtask draining.
/// Microtask-only waits should use `pumpEventQueue()` instead. Returns the final
/// task (may still be running if the bound elapses — callers assert on it).
Future<Task?> waitForTaskStatus(
  TaskService tasks,
  String taskId, {
  Set<TaskStatus> until = const {TaskStatus.review, TaskStatus.accepted, TaskStatus.failed},
  int attempts = 40,
  Duration step = const Duration(milliseconds: 10),
}) async {
  Task? task;
  for (var attempt = 0; attempt < attempts; attempt++) {
    task = await tasks.get(taskId);
    if (task != null && until.contains(task.status)) return task;
    await Future<void>.delayed(step);
  }
  return task;
}

/// A ready [Project] backed by a remote, seeded into a [FakeProjectService].
Project readyProject({
  String id = 'my-app',
  String remoteUrl = 'git@github.com:acme/my-app.git',
  String localPath = '/projects/my-app',
  String defaultBranch = 'main',
}) => Project(
  id: id,
  name: 'My App',
  remoteUrl: remoteUrl,
  localPath: localPath,
  defaultBranch: defaultBranch,
  status: ProjectStatus.ready,
  createdAt: DateTime.parse('2026-03-10T09:00:00Z'),
);

/// A project whose clone is still in progress.
Project cloningProject({String id = 'my-app'}) => Project(
  id: id,
  name: 'My App',
  remoteUrl: 'git@github.com:acme/my-app.git',
  localPath: '/projects/my-app',
  defaultBranch: 'main',
  status: ProjectStatus.cloning,
  createdAt: DateTime.parse('2026-03-10T09:00:00Z'),
);

/// A project whose clone failed, carrying [errorMessage].
Project erroredProject({String id = 'my-app', String errorMessage = 'Authentication denied'}) => Project(
  id: id,
  name: 'My App',
  remoteUrl: 'git@github.com:acme/my-app.git',
  localPath: '/projects/my-app',
  defaultBranch: 'main',
  status: ProjectStatus.error,
  errorMessage: errorMessage,
  createdAt: DateTime.parse('2026-03-10T09:00:00Z'),
);

/// Wraps a single ready project in a [FakeProjectService] that excludes the
/// synthetic local project and routes default lookups to [project].
FakeProjectService fakeProjectServiceFor(Project project) =>
    FakeProjectService(projects: [project], includeLocalProjectInGetAll: false, defaultProjectId: project.id);

const _gitTestEnv = {
  'GIT_AUTHOR_NAME': 'Test',
  'GIT_AUTHOR_EMAIL': 'test@test.com',
  'GIT_COMMITTER_NAME': 'Test',
  'GIT_COMMITTER_EMAIL': 'test@test.com',
};

/// Initializes a real temp git repo with one commit on [branch].
///
/// Collapses the repeated `git init` / `checkout -b` / `add` / `commit
/// --no-gpg-sign` fixtures. Writes `README.md` plus any [extraFiles]
/// (relPath -> contents), commits them on [branch], then optionally creates
/// [integrationBranch] off that commit and checks [branch] back out (the
/// "inline workflow branch present but not current" shape). The returned
/// [Directory] is the repo root; callers register their own teardown.
Future<Directory> initGitRepo({
  String branch = 'main',
  String prefix = 'task_executor_repo_',
  Map<String, String> extraFiles = const {},
  String? integrationBranch,
}) async {
  final repo = Directory.systemTemp.createTempSync(prefix);
  await Process.run('git', ['init', '-b', branch], workingDirectory: repo.path);
  File(p.join(repo.path, 'README.md')).writeAsStringSync('fixture\n');
  for (final entry in extraFiles.entries) {
    final file = File(p.join(repo.path, entry.key))..parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value);
  }
  await Process.run('git', ['add', '.'], workingDirectory: repo.path);
  await Process.run(
    'git',
    ['commit', '-m', 'init', '--no-gpg-sign'],
    workingDirectory: repo.path,
    environment: _gitTestEnv,
  );
  if (integrationBranch != null) {
    await Process.run('git', ['checkout', '-b', integrationBranch], workingDirectory: repo.path);
    await Process.run('git', ['checkout', branch], workingDirectory: repo.path);
  }
  return repo;
}

/// Workflow-DB-backed [TaskExecutor] topology shared by the task-executor test
/// suites (core lifecycle, workflow one-shot, worktree/git).
///
/// Wraps [TaskExecutorTestHarness] but replaces the simple in-memory
/// [TaskService] with one backed by a shared SQLite DB so workflow repo joins
/// (agent executions, workflow runs, step executions) resolve. Owns the shared
/// [KvService] and a workflow-aware [ArtifactCollector]. Call [setUp] in the
/// suite `setUp` hook and [tearDown] in `tearDown`; use [seedWorkflowExecution]
/// and [buildExecutor] for per-test wiring.
final class WorkflowTaskExecutorTestContext {
  new(this.worker) : _harness = TaskExecutorTestHarness(worker);

  final AgentHarness worker;
  final TaskExecutorTestHarness _harness;

  TaskExecutorTestHarness get harness => _harness;

  late Database taskDb;
  late SqliteAgentExecutionRepository agentExecutions;
  late SqliteWorkflowRunRepository workflowRuns;
  late SqliteWorkflowStepExecutionRepository workflowStepExecutions;
  late SqliteExecutionRepositoryTransactor executionTransactor;
  late KvService kvService;
  late TaskExecutor executor;

  Directory get tempDir => _harness.tempDir;
  String get sessionsDir => _harness.sessionsDir;
  String get workspaceDir => _harness.workspaceDir;
  SessionService get sessions => _harness.sessions;
  MessageService get messages => _harness.messages;
  TaskService get tasks => _harness.tasks;
  TurnManager get turns => _harness.turns;
  ArtifactCollector get collector => _harness.collector;

  Future<void> setUp({
    String tempPrefix = 'dartclaw_task_executor_test_',
    MessageService Function(String baseDir)? messageServiceFactory,
  }) async {
    await _harness.setUp(tempPrefix: tempPrefix, messageServiceFactory: messageServiceFactory);
    taskDb = sqlite3.openInMemory();
    agentExecutions = SqliteAgentExecutionRepository(taskDb);
    workflowRuns = SqliteWorkflowRunRepository(taskDb);
    workflowStepExecutions = SqliteWorkflowStepExecutionRepository(taskDb);
    executionTransactor = SqliteExecutionRepositoryTransactor(taskDb);
    // Replace the harness's simple TaskService with one backed by the shared DB
    // (needed for workflow repo joins). tasksDispose in tearDown handles lifecycle.
    _harness.tasks = TaskService(
      SqliteTaskRepository(taskDb),
      agentExecutionRepository: agentExecutions,
      executionTransactor: executionTransactor,
    );
    kvService = KvService(filePath: p.join(_harness.tempDir.path, 'kv.json'));
    _harness.collector = ArtifactCollector(
      tasks: _harness.tasks,
      sessionsDir: _harness.sessionsDir,
      dataDir: _harness.tempDir.path,
    );
    executor = buildExecutor();
  }

  Future<void> tearDown({Future<void> Function()? workerDispose}) async {
    await kvService.dispose();
    await _harness.tearDown(executor: executor, workerDispose: workerDispose, tasksDispose: tasks.dispose);
  }

  /// Builds a [TaskExecutor] wired to this context's workflow-aware services.
  ///
  /// Collapses the per-test `TaskExecutor(services: TaskExecutorServices(...))`
  /// boilerplate; defaults [kvService]/[workflowRunRepository]/
  /// [workflowStepExecutionRepository] to this context's instances so callers
  /// pass only the collaborators they exercise.
  TaskExecutor buildExecutor({
    Future<void> Function(String taskId)? onAutoAccept,
    ProjectService? projectService,
    TaskEventRecorder? eventRecorder,
    TaskExecutorLimits limits = const TaskExecutorLimits(),
    TurnManager? turnManager,
    HarnessFactory? harnessFactory,
    EventBus? eventBus,
    ExecutionPolicyResolver? policyResolver,
    Duration pollInterval = const Duration(milliseconds: 10),
    String? currentDirectory,
  }) {
    return _harness.buildWorkflowExecutor(
      projectService: projectService,
      workflowRunRepository: workflowRuns,
      workflowStepExecutionRepository: workflowStepExecutions,
      eventRecorder: eventRecorder,
      kvService: kvService,
      eventBus: eventBus,
      turnManager: turnManager,
      harnessFactory: harnessFactory,
      onAutoAccept: onAutoAccept,
      limits: limits,
      policyResolver: policyResolver,
      pollInterval: pollInterval,
      currentDirectory: currentDirectory,
    );
  }

  /// Seeds the agent-execution + workflow-run + step-execution rows that the
  /// executor reads workflow runtime state from for [taskId].
  Future<void> seedWorkflowExecution(
    String taskId, {
    String? agentExecutionId,
    required String workflowRunId,
    String stepId = 'plan',
    String stepType = 'coding',
    Map<String, dynamic>? git,
    Map<String, dynamic>? structuredSchema,
    Map<String, dynamic>? structuredOutput,
    List<String>? followUpPrompts,
    int? mapIterationIndex,
    int? mapIterationTotal,
    String? providerSessionId,
    String? workspaceDirOverride,
  }) async {
    final executionId = agentExecutionId ?? 'ae-$taskId';
    final existingExecution = await agentExecutions.get(executionId);
    if (existingExecution == null) {
      await agentExecutions.create(
        AgentExecution(id: executionId, provider: 'claude', workspaceDir: workspaceDirOverride ?? workspaceDir),
      );
    } else if (workspaceDirOverride != null && existingExecution.workspaceDir != workspaceDirOverride) {
      await agentExecutions.update(existingExecution.copyWith(workspaceDir: workspaceDirOverride));
    }
    final existingRun = await workflowRuns.getById(workflowRunId);
    if (existingRun == null) {
      final now = DateTime.now();
      await workflowRuns.insert(
        WorkflowRun(
          id: workflowRunId,
          definitionName: 'task-executor-test',
          status: WorkflowRunStatus.running,
          startedAt: now,
          updatedAt: now,
          definitionJson: const {'name': 'task-executor-test', 'steps': []},
          variablesJson: const {'PROJECT': '_local'},
        ),
      );
    }
    await workflowStepExecutions.create(
      WorkflowStepExecution(
        taskId: taskId,
        agentExecutionId: executionId,
        workflowRunId: workflowRunId,
        stepIndex: 0,
        stepId: stepId,
        stepType: stepType,
        gitJson: git == null ? null : jsonEncode(git),
        providerSessionId: providerSessionId,
        structuredSchemaJson: structuredSchema == null ? null : jsonEncode(structuredSchema),
        structuredOutputJson: structuredOutput == null ? null : jsonEncode(structuredOutput),
        followUpPromptsJson: followUpPrompts == null ? null : jsonEncode(followUpPrompts),
        mapIterationIndex: mapIterationIndex,
        mapIterationTotal: mapIterationTotal,
      ),
    );
  }
}

/// A minimal [AgentHarness] whose turn records the model/directory it was
/// invoked with, can be made to fail, and emits [responseText] as a single
/// delta. Shared by the task-executor suites.
class FakeTaskWorker implements AgentHarness {
  @override
  String skillActivationLine(String skill) => "Use the '$skill' skill.";

  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();

  String responseText = '';
  String? lastModel;

  /// Schema the last turn was handed, or null when none was forwarded.
  Map<String, dynamic>? lastOutputSchema;
  String? lastDirectory;
  int inputTokens = 0;
  int outputTokens = 0;
  int turnCallCount = 0;
  int cancelCallCount = 0;
  bool shouldFail = false;
  bool structuredOutputSupported = false;
  bool providerSessionResumeSupported = false;
  String? providerSessionId;
  Map<String, dynamic>? structuredOutput;

  /// When set, a single [ToolUseEvent] emitted before [responseText] on the next
  /// turn, then cleared — drives loop-detection sequencing tests.
  ToolUseEvent? toolToEmit;

  void Function(String sessionId)? onTurn;
  void Function(String sessionId, String? directory)? onTurnWithDirectory;
  Future<void> Function(String sessionId)? beforeComplete;

  @override
  bool get supportsCostReporting => true;

  @override
  bool get supportsToolApproval => true;

  @override
  bool get supportsStreaming => true;

  @override
  bool get supportsCachedTokens => false;

  @override
  bool get supportsSessionContinuity => false;

  @override
  bool get supportsPreCompactHook => false;

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  @override
  WorkerState get state => WorkerState.idle;

  @override
  bool get isRootProcessTerminationConfirmed => true;

  @override
  bool get supportsStructuredOutput => structuredOutputSupported;

  @override
  bool get supportsProviderSessionResume => providerSessionResumeSupported;

  @override
  Stream<BridgeEvent> get events => _eventsCtrl.stream;

  @override
  Future<void> start() async {}

  @override
  Future<TurnResult> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    String? agentId,
    Map<String, dynamic>? mcpServers,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? directory,
    String? model,
    String? effort,
    String? systemPromptOverride,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
  }) async {
    turnCallCount++;
    onTurn?.call(sessionId);
    onTurnWithDirectory?.call(sessionId, directory);
    lastModel = model;
    lastDirectory = directory;
    lastOutputSchema = outputSchema;
    final waitFor = beforeComplete;
    if (waitFor != null) {
      await waitFor(sessionId);
    }
    if (shouldFail) {
      throw StateError('simulated crash');
    }
    final tool = toolToEmit;
    if (tool != null) {
      _eventsCtrl.add(tool);
      toolToEmit = null;
    }
    if (responseText.isNotEmpty) {
      _eventsCtrl.add(DeltaEvent(responseText));
    }
    // Yield so the broadcast subscriber consumes the events before the turn
    // future resolves. Any `await` executed earlier in this turn (a
    // `beforeComplete` hook) reorders the two otherwise, and the runner then
    // accumulates nothing and persists an empty assistant message.
    await Future<void>.microtask(() {});
    return TurnResult(
      providerSessionId: this.providerSessionId,
      structuredOutput: structuredOutput,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
    );
  }

  @override
  Future<void> resetSessionContinuity(String sessionId) async {}

  @override
  Future<void> cancel() async {
    cancelCallCount++;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (!_eventsCtrl.isClosed) {
      await _eventsCtrl.close();
    }
  }
}

/// A [WorktreeManager] that materializes each worktree as a real (empty)
/// directory under [root], so a test can assert on its contents.
class MaterializingWorktreeManager extends WorktreeManager {
  new(this.root) : super(dataDir: root, processRunner: RecordingGitRunner().run);

  final String root;

  @override
  Future<WorktreeInfo> create(
    String taskId, {
    String? baseRef,
    Project? project,
    bool createBranch = true,
    Map<String, dynamic>? existingWorktreeJson,
  }) async {
    final path = p.join(root, 'worktrees', taskId);
    Directory(path).createSync(recursive: true);
    return WorktreeInfo(
      path: path,
      branch: createBranch ? 'dartclaw/task-$taskId' : (baseRef ?? 'main'),
      createdAt: DateTime.now(),
    );
  }
}

/// Records the create()/baseRef/createBranch a worktree request carried and
/// returns a synthetic worktree.
class CapturingWorktreeManager extends WorktreeManager {
  new() : super(dataDir: '/tmp', processRunner: RecordingGitRunner().run);

  String? lastBaseRef;
  Project? lastProject;
  bool? lastCreateBranch;
  int createCallCount = 0;

  @override
  Future<WorktreeInfo> create(
    String taskId, {
    String? baseRef,
    Project? project,
    bool createBranch = true,
    Map<String, dynamic>? existingWorktreeJson,
  }) async {
    createCallCount++;
    lastBaseRef = baseRef;
    lastProject = project;
    lastCreateBranch = createBranch;
    return WorktreeInfo(
      path: '/tmp/worktrees/$taskId',
      branch: createBranch ? 'dartclaw/task-$taskId' : (baseRef ?? 'main'),
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<void> cleanup(String taskId, {Project? project}) async {}
}

/// A [WorktreeManager] whose create() blocks on [_gate] — used to prove
/// concurrent shared-workflow dispatch coalesces into a single create call.
class BlockingWorktreeManager extends WorktreeManager {
  new(this._gate) : super(dataDir: '/tmp', processRunner: RecordingGitRunner().run);

  final Completer<void> _gate;
  int createCallCount = 0;

  @override
  Future<WorktreeInfo> create(
    String taskId, {
    String? baseRef,
    Project? project,
    bool createBranch = true,
    Map<String, dynamic>? existingWorktreeJson,
  }) async {
    createCallCount++;
    await _gate.future;
    return WorktreeInfo(
      path: '/tmp/worktrees/$taskId',
      branch: createBranch ? 'dartclaw/task-$taskId' : (baseRef ?? 'main'),
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<void> cleanup(String taskId, {Project? project}) async {}
}

/// A [WorktreeManager] that always returns a fixed [path] — used to point the
/// executor at a pre-seeded worktree directory.
class StaticPathWorktreeManager extends WorktreeManager {
  new(this.path) : super(dataDir: '/tmp', processRunner: RecordingGitRunner().run);

  final String path;

  @override
  Future<WorktreeInfo> create(
    String taskId, {
    String? baseRef,
    Project? project,
    bool createBranch = true,
    Map<String, dynamic>? existingWorktreeJson,
  }) async {
    return WorktreeInfo(
      path: path,
      branch: createBranch ? 'dartclaw/task-$taskId' : (baseRef ?? 'main'),
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<void> cleanup(String taskId, {Project? project}) async {}
}

/// Captures the prompt scope / behavior override / directory the executor
/// routed a turn with, without driving a real harness.
class CapturingTurnManager extends TurnManager {
  new(MessageService messages, AgentHarness worker) : this._(_CapturingTurnRunner(messages, worker));

  new _(this._runner)
    : super.fromCoordinator(
        turnLimits: const TurnLimitsConfig.defaults(),
        coordinator: ExecutionCoordinator(
          providerCapacities: const {},
          primary: _runner,
          allowPrimaryBackgroundFallback: true,
          admitExecution: (request) => _runner.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
          releaseAdmission: _runner.releaseAdmission,
          createWorker: (_) => throw StateError('Worker execution is disabled'),
        ),
      );

  final _CapturingTurnRunner _runner;

  PromptScope? get lastPromptScope => _runner.lastPromptScope;
  BehaviorFileService? get lastBehaviorOverride => _runner.lastBehaviorOverride;
  String? get lastTaskId => _runner.lastTaskId;
  String? get lastDirectory => _runner.lastDirectory;
  List<String>? get lastAllowedTools => _runner.lastAllowedTools;
  bool get lastReadOnly => _runner.lastReadOnly;
}

final class _CapturingTurnRunner extends TurnRunner {
  new(MessageService messages, AgentHarness worker)
    : super(
        turnLimits: const TurnLimitsConfig.defaults(),
        messages: messages,
        harness: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/dartclaw-scope-test'),
      );

  PromptScope? lastPromptScope;
  BehaviorFileService? lastBehaviorOverride;
  String? lastTaskId;
  String? lastDirectory;
  List<String>? lastAllowedTools;
  bool lastReadOnly = false;

  @override
  Future<String> reserveAdmittedTurn(
    String sessionId, {
    String agentName = 'main',
    String? directory,
    String? model,
    String? effort,
    String? systemPromptOverride,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? taskId,
    bool isHumanInput = false,
    BehaviorFileService? behaviorOverride,
    List<String>? allowedTools,
    bool readOnly = false,
    PromptScope? promptScope,
    Duration? turnTimeout,
  }) async {
    lastDirectory = directory;
    lastPromptScope = promptScope;
    lastBehaviorOverride = behaviorOverride;
    lastTaskId = taskId;
    lastAllowedTools = allowedTools;
    lastReadOnly = readOnly;
    return 'scope-turn';
  }

  @override
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
  }) {}

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async => TurnOutcome(
    turnId: turnId,
    sessionId: sessionId,
    status: TurnStatus.completed,
    responseText: 'Done.',
    completedAt: DateTime.now(),
  );

  @override
  Future<void> waitForExecutionSettled(String sessionId, String turnId) async {}
}

/// A [TurnManager] that throws [BusyTurnException] on its first reserve and
/// succeeds thereafter — proves the executor waits out shared-harness
/// contention rather than failing the task.
class BusyOnceTurnManager extends TurnManager {
  new(MessageService messages, AgentHarness worker)
    : super(
        turnLimits: const TurnLimitsConfig.defaults(),
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/dartclaw-task-executor-test'),
      );

  bool _busyOnce = true;

  @override
  Iterable<String> get activeSessionIds => const <String>[];

  @override
  Future<String> reserveTurn(
    String sessionId, {
    String agentName = 'main',
    String? directory,
    String? model,
    String? effort,
    String? systemPromptOverride,
    ExecutionPolicy? workerPolicy,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? taskId,
    bool isHumanInput = false,
    BehaviorFileService? behaviorOverride,
    PromptScope? promptScope,
    List<String>? allowedTools,
    bool readOnly = false,
    Duration? turnTimeout,
  }) async {
    if (_busyOnce) {
      _busyOnce = false;
      throw BusyTurnException('shared harness busy', isSameSession: false);
    }

    return 'busy-once-turn';
  }

  @override
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
  }) {}

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async {
    return TurnOutcome(turnId: turnId, sessionId: sessionId, status: TurnStatus.completed, completedAt: DateTime.now());
  }
}
