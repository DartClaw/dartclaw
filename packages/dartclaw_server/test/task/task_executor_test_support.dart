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
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_server/dartclaw_server.dart' hide TurnManager;
import 'package:dartclaw_server/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowRun, WorkflowRunRepository, WorkflowRunStatus;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

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

  /// Default [TaskService] created by [setUp], used for disposal tracking.
  late TaskService _defaultTasks;

  final AgentHarness worker;

  TaskExecutorTestHarness(this.worker);

  Future<void> setUp({String tempPrefix = 'dartclaw_executor_test_'}) async {
    tempDir = Directory.systemTemp.createTempSync(tempPrefix);
    sessionsDir = p.join(tempDir.path, 'sessions');
    // Workspace must NOT be inside dataDir — ArtifactCollector excludes
    // files within dataDir to prevent collecting internal metadata.
    workspaceDir = Directory.systemTemp.createTempSync('${tempPrefix}ws_').path;
    Directory(sessionsDir).createSync(recursive: true);

    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    _defaultTasks = TaskService(SqliteTaskRepository(sqlite3.openInMemory()));
    tasks = _defaultTasks;
    turns = TurnManager(
      messages: messages,
      worker: worker,
      behavior: BehaviorFileService(workspaceDir: workspaceDir),
      sessions: sessions,
    );
    collector = ArtifactCollector(
      tasks: tasks,
      messages: messages,
      sessionsDir: sessionsDir,
      dataDir: tempDir.path,
      workspaceDir: workspaceDir,
    );
  }

  /// Builds a [TaskExecutor] wired to this harness's [tasks]/[sessions]/
  /// [messages]/[collector] plus any workflow-specific services a test needs.
  ///
  /// Collapses the per-test `TaskExecutor(services: TaskExecutorServices(...))`
  /// boilerplate: every collaborator beyond the shared topology is an optional
  /// named parameter, so a test only passes what it exercises (a worktree
  /// manager, a project service, a CLI runner, etc.). Tests that reassign
  /// [tasks]/[collector] after [setUp] (e.g. to a workflow-aware [TaskService])
  /// get the replacement automatically.
  TaskExecutor buildWorkflowExecutor({
    WorktreeManager? worktreeManager,
    ProjectService? projectService,
    WorkflowCliRunner? workflowCliRunner,
    WorkflowRunRepository? workflowRunRepository,
    WorkflowStepExecutionRepository? workflowStepExecutionRepository,
    TaskEventRecorder? eventRecorder,
    TurnTraceService? traceService,
    KvService? kvService,
    EventBus? eventBus,
    TurnManager? turnManager,
    SpawnTaskRunner? onSpawnNeeded,
    Future<void> Function(String taskId)? onAutoAccept,
    TaskExecutorLimits limits = const TaskExecutorLimits(),
    Duration pollInterval = const Duration(milliseconds: 10),
  }) {
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
      ),
      runners: TaskExecutorRunners(turns: turnManager ?? turns, workflowCliRunner: workflowCliRunner),
      limits: limits,
      onSpawnNeeded: onSpawnNeeded,
      onAutoAccept: onAutoAccept,
      pollInterval: pollInterval,
    );
  }

  Future<void> tearDown({
    TaskExecutor? executor,
    Future<void> Function()? workerDispose,
    Future<void> Function()? tasksDispose,
  }) async {
    if (executor != null) await executor.stop();
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
/// The single sanctioned real-time wait in the executor suite: workflow
/// one-shot tasks drive a real `/bin/sh` subprocess whose completion is not
/// observable through microtask draining. Microtask-only waits should use
/// `pumpEventQueue()` instead. Returns the final task (may still be running if
/// the bound elapses — callers assert on the returned status).
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

/// Standard provider map used by workflow-CLI test runners.
const _testCliProviders = {
  'claude': WorkflowCliProviderConfig(executable: 'claude'),
  'codex': WorkflowCliProviderConfig(executable: 'codex'),
};

/// Builds a [WorkflowCliRunner] whose subprocess prints whatever JSON
/// [payloadFor] returns for the given argument list, via `/bin/sh printf`.
///
/// Collapses the ~12 bespoke `processStarter:` closures that all shell out to
/// `Process.start('/bin/sh', ['-lc', "printf '%s' '<json>'"])`. [payloadFor]
/// receives the CLI args so a test can branch on, e.g., `--json-schema`.
/// [onArgs] captures the args for assertions; [providers] defaults to claude+codex.
WorkflowCliRunner echoCliRunner(
  String Function(List<String> args) payloadFor, {
  Map<String, WorkflowCliProviderConfig> providers = _testCliProviders,
  void Function(String executable, List<String> args)? onArgs,
}) {
  return WorkflowCliRunner(
    providers: providers,
    processStarter: (exe, args, {workingDirectory, environment}) async {
      onArgs?.call(exe, List<String>.from(args));
      final escaped = payloadFor(args).replaceAll("'", "'\\''");
      return Process.start('/bin/sh', ['-lc', "printf '%s' '$escaped'"]);
    },
  );
}

/// A [WorkflowCliRunner] that always echoes a minimal successful turn payload.
///
/// For tasks that only need the workflow one-shot path to complete, not to
/// assert on its output.
WorkflowCliRunner successCliRunner({String sessionId = 'cli-session-success'}) =>
    echoCliRunner((_) => jsonEncode({'session_id': sessionId, 'result': 'Done.'}));

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
  WorkflowTaskExecutorTestContext(this.worker) : _harness = TaskExecutorTestHarness(worker);

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

  Future<void> setUp({String tempPrefix = 'dartclaw_task_executor_test_'}) async {
    await _harness.setUp(tempPrefix: tempPrefix);
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
      messages: _harness.messages,
      sessionsDir: _harness.sessionsDir,
      dataDir: _harness.tempDir.path,
      workspaceDir: _harness.workspaceDir,
    );
    executor = TaskExecutor(
      services: TaskExecutorServices(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        artifactCollector: collector,
        workflowRunRepository: workflowRuns,
        workflowStepExecutionRepository: workflowStepExecutions,
      ),
      runners: TaskExecutorRunners(turns: turns),
      pollInterval: const Duration(milliseconds: 10),
    );
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
    WorkflowCliRunner? workflowCliRunner,
    TaskEventRecorder? eventRecorder,
    TaskExecutorLimits limits = const TaskExecutorLimits(),
    Duration pollInterval = const Duration(milliseconds: 10),
  }) {
    return TaskExecutor(
      services: TaskExecutorServices(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        artifactCollector: collector,
        workflowRunRepository: workflowRuns,
        workflowStepExecutionRepository: workflowStepExecutions,
        kvService: kvService,
        projectService: projectService,
        eventRecorder: eventRecorder,
      ),
      runners: TaskExecutorRunners(turns: turns, workflowCliRunner: workflowCliRunner),
      limits: limits,
      onAutoAccept: onAutoAccept,
      pollInterval: pollInterval,
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
    Map<String, dynamic>? externalArtifactMount,
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
        externalArtifactMount: externalArtifactMount == null ? null : jsonEncode(externalArtifactMount),
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
  String? lastDirectory;
  int inputTokens = 0;
  int outputTokens = 0;
  bool shouldFail = false;

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
  Stream<BridgeEvent> get events => _eventsCtrl.stream;

  @override
  Future<void> start() async {}

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
  }) async {
    onTurn?.call(sessionId);
    onTurnWithDirectory?.call(sessionId, directory);
    lastModel = model;
    lastDirectory = directory;
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
    return <String, dynamic>{'input_tokens': inputTokens, 'output_tokens': outputTokens};
  }

  @override
  Future<void> resetSessionContinuity(String sessionId) async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (!_eventsCtrl.isClosed) {
      await _eventsCtrl.close();
    }
  }
}

/// Records the create()/baseRef/createBranch a worktree request carried and
/// returns a synthetic worktree.
class CapturingWorktreeManager extends WorktreeManager {
  CapturingWorktreeManager()
    : super(
        dataDir: '/tmp',
        processRunner: (executable, arguments, {workingDirectory}) async => ProcessResult(0, 0, '', ''),
      );

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
  BlockingWorktreeManager(this._gate)
    : super(
        dataDir: '/tmp',
        processRunner: (executable, arguments, {workingDirectory}) async => ProcessResult(0, 0, '', ''),
      );

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
  StaticPathWorktreeManager(this.path)
    : super(
        dataDir: '/tmp',
        processRunner: (executable, arguments, {workingDirectory}) async => ProcessResult(0, 0, '', ''),
      );

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
  CapturingTurnManager(MessageService messages, AgentHarness worker)
    : super(
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/dartclaw-scope-test'),
      );

  PromptScope? lastPromptScope;

  BehaviorFileService? lastBehaviorOverride;
  String? lastTaskId;

  String? lastDirectory;

  @override
  Iterable<String> get activeSessionIds => const <String>[];

  @override
  Future<String> reserveTurn(
    String sessionId, {
    String agentName = 'main',
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    String? taskId,
    bool isHumanInput = false,
    BehaviorFileService? behaviorOverride,
    PromptScope? promptScope,
    List<String>? allowedTools,
    bool readOnly = false,
  }) async {
    lastDirectory = directory;
    lastPromptScope = promptScope;
    lastBehaviorOverride = behaviorOverride;
    lastTaskId = taskId;
    return 'scope-turn';
  }

  @override
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
    bool resume = false,
  }) {}

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async {
    return TurnOutcome(
      turnId: turnId,
      sessionId: sessionId,
      status: TurnStatus.completed,
      responseText: 'Done.',
      completedAt: DateTime.now(),
    );
  }
}

/// A [TurnManager] that throws [BusyTurnException] on its first reserve and
/// succeeds thereafter — proves the executor waits out shared-harness
/// contention rather than failing the task.
class BusyOnceTurnManager extends TurnManager {
  BusyOnceTurnManager(MessageService messages, AgentHarness worker)
    : super(
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
    int? maxTurns,
    String? taskId,
    bool isHumanInput = false,
    BehaviorFileService? behaviorOverride,
    PromptScope? promptScope,
    List<String>? allowedTools,
    bool readOnly = false,
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
    bool resume = false,
  }) {}

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async {
    return TurnOutcome(turnId: turnId, sessionId: sessionId, status: TurnStatus.completed, completedAt: DateTime.now());
  }
}
