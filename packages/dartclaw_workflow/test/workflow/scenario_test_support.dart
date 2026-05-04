import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

final class ScenarioTaskHarness {
  ScenarioTaskHarness._();

  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late EventBus eventBus;
  late SqliteTaskRepository taskRepository;
  late TaskService tasks;
  late ScriptedAgentWorker _worker;
  late TurnManager turns;
  late ArtifactCollector collector;
  late KvService kvService;
  late Database taskDb;
  late SqliteAgentExecutionRepository agentExecutions;
  late SqliteWorkflowRunRepository workflowRuns;
  late SqliteWorkflowStepExecutionRepository workflowStepExecutions;
  late SqliteExecutionRepositoryTransactor executionTransactor;

  static Future<ScenarioTaskHarness> create() async {
    final harness = ScenarioTaskHarness._();
    harness.tempDir = Directory.systemTemp.createTempSync('dartclaw_scenario_task_');
    harness.sessionsDir = p.join(harness.tempDir.path, 'sessions');
    harness.workspaceDir = Directory.systemTemp.createTempSync('dartclaw_scenario_ws_').path;
    Directory(harness.sessionsDir).createSync(recursive: true);

    harness.sessions = SessionService(baseDir: harness.sessionsDir);
    harness.messages = MessageService(baseDir: harness.sessionsDir);
    harness.taskDb = sqlite3.openInMemory();
    harness.eventBus = EventBus();
    harness.taskRepository = SqliteTaskRepository(harness.taskDb);
    harness.agentExecutions = SqliteAgentExecutionRepository(harness.taskDb);
    harness.workflowRuns = SqliteWorkflowRunRepository(harness.taskDb);
    harness.workflowStepExecutions = SqliteWorkflowStepExecutionRepository(harness.taskDb);
    harness.executionTransactor = SqliteExecutionRepositoryTransactor(harness.taskDb);
    harness.tasks = TaskService(
      harness.taskRepository,
      agentExecutionRepository: harness.agentExecutions,
      executionTransactor: harness.executionTransactor,
      eventBus: harness.eventBus,
    );
    harness._worker = ScriptedAgentWorker();
    harness.turns = TurnManager(
      messages: harness.messages,
      worker: harness._worker,
      behavior: BehaviorFileService(workspaceDir: harness.workspaceDir),
      sessions: harness.sessions,
    );
    harness.kvService = KvService(filePath: p.join(harness.tempDir.path, 'kv.json'));
    harness.collector = ArtifactCollector(
      tasks: harness.tasks,
      messages: harness.messages,
      sessionsDir: harness.sessionsDir,
      dataDir: harness.tempDir.path,
      workspaceDir: harness.workspaceDir,
    );
    return harness;
  }

  TaskExecutor buildExecutor({
    Future<void> Function(String taskId)? onAutoAccept,
    ProjectService? projectService,
    WorkflowCliRunner? workflowCliRunner,
    TaskEventRecorder? eventRecorder,
    WorktreeManager? worktreeManager,
    Duration pollInterval = const Duration(milliseconds: 10),
  }) {
    final namedArgs = <Symbol, dynamic>{
      #tasks: tasks,
      #sessions: sessions,
      #messages: messages,
      #turns: turns,
      #artifactCollector: collector,
      #workflowRunRepository: workflowRuns,
      #workflowStepExecutionRepository: workflowStepExecutions,
      #kvService: kvService,
      #pollInterval: pollInterval,
    };
    if (onAutoAccept != null) {
      namedArgs[#onAutoAccept] = onAutoAccept;
    }
    if (projectService != null) {
      namedArgs[#projectService] = projectService;
    }
    if (workflowCliRunner != null) {
      namedArgs[#workflowCliRunner] = workflowCliRunner;
    }
    if (eventRecorder != null) {
      namedArgs[#eventRecorder] = eventRecorder;
    }
    if (worktreeManager != null) {
      namedArgs[#worktreeManager] = worktreeManager;
    }
    return Function.apply(TaskExecutor.new, const [], namedArgs) as TaskExecutor;
  }

  /// Direct access to the scripted worker so component tests can `enqueue`
  /// per-turn responses without the legacy single-response fields.
  ScriptedAgentWorker get worker => _worker;

  void setWorkerResponseText(String value) {
    _worker.responseText = value;
  }

  /// Auto-drives a freshly-queued task through running → review → accepted.
  ///
  /// Installs a subscription on [TaskStatusChangedEvent] that mirrors the
  /// minimal state machine the real TaskService invokes on happy-path
  /// completion. Returns the subscription so tests can cancel it during
  /// tearDown.
  ///
  /// This is the component-tier equivalent of the per-test "listen for queued
  /// then transition" boilerplate that appears at the top of every scenario.
  StreamSubscription<TaskStatusChangedEvent> autoAcceptQueuedTasks({FutureOr<void> Function(Task task)? onQueued}) {
    return eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((event) async {
      final task = await tasks.get(event.taskId);
      if (task == null) return;
      await onQueued?.call(task);
      try {
        await tasks.transition(event.taskId, TaskStatus.running, trigger: 'test');
      } on StateError {
        // Task may already be running.
      }
      try {
        await tasks.transition(event.taskId, TaskStatus.review, trigger: 'test');
      } on StateError {
        // Task may already be in review.
      }
      await tasks.transition(event.taskId, TaskStatus.accepted, trigger: 'test');
    });
  }

  void writeRelativeOnTurn(String relativePath, {String content = ''}) {
    _worker.onTurnWithDirectory = (_, directory) {
      final root = directory ?? workspaceDir;
      final file = File(p.join(root, relativePath));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(content);
    };
  }

  StepExecutionContext buildExecutionContext({
    required WorkflowRun run,
    required WorkflowDefinition definition,
    required WorkflowContext workflowContext,
    WorkflowTurnAdapter? turnAdapter,
    WorkflowStepOutputTransformer? outputTransformer,
    WorkflowGitPort? workflowGitPort,
  }) {
    return StepExecutionContext(
      taskService: tasks,
      eventBus: eventBus,
      kvService: kvService,
      repository: workflowRuns,
      gateEvaluator: GateEvaluator(),
      contextExtractor: ContextExtractor(
        taskService: tasks,
        messageService: messages,
        dataDir: tempDir.path,
        workflowStepExecutionRepository: workflowStepExecutions,
        workflowGitPort: workflowGitPort,
      ),
      turnAdapter: turnAdapter,
      outputTransformer: outputTransformer,
      taskRepository: taskRepository,
      agentExecutionRepository: agentExecutions,
      workflowStepExecutionRepository: workflowStepExecutions,
      executionTransactor: executionTransactor,
      dataDir: tempDir.path,
      workflowGitPort: workflowGitPort,
      run: run,
      definition: definition,
      workflowContext: workflowContext,
    );
  }

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
          definitionName: 'scenario-test',
          status: WorkflowRunStatus.running,
          startedAt: now,
          updatedAt: now,
          definitionJson: const {'name': 'scenario-test', 'steps': []},
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

  Future<Project> createProjectRepo(String projectId, {String defaultBranch = 'main'}) async {
    final projectDir = Directory(p.join(tempDir.path, 'projects', projectId))..createSync(recursive: true);
    await Process.run('git', ['init', '-b', defaultBranch], workingDirectory: projectDir.path);
    File(p.join(projectDir.path, 'README.md')).writeAsStringSync('fixture\n');
    await Process.run('git', ['add', 'README.md'], workingDirectory: projectDir.path);
    await Process.run(
      'git',
      ['commit', '-m', 'init', '--no-gpg-sign'],
      workingDirectory: projectDir.path,
      environment: const {
        'GIT_AUTHOR_NAME': 'Scenario Test',
        'GIT_AUTHOR_EMAIL': 'scenario@test.com',
        'GIT_COMMITTER_NAME': 'Scenario Test',
        'GIT_COMMITTER_EMAIL': 'scenario@test.com',
      },
    );
    return Project(
      id: projectId,
      name: projectId,
      remoteUrl: 'git@github.com:dartclaw/$projectId.git',
      localPath: projectDir.path,
      defaultBranch: defaultBranch,
      status: ProjectStatus.ready,
      createdAt: DateTime.parse('2026-03-10T09:00:00Z'),
    );
  }

  Future<void> dispose() async {
    await tasks.dispose();
    await messages.dispose();
    await kvService.dispose();
    await eventBus.dispose();
    await _worker.dispose();
    taskDb.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
    final workspace = Directory(workspaceDir);
    if (workspace.existsSync()) {
      workspace.deleteSync(recursive: true);
    }
  }

  Future<Map<String, dynamic>> readSessionKeyIndex() async {
    final raw = await File('$sessionsDir/.session_keys.json').readAsString();
    return jsonDecode(raw) as Map<String, dynamic>;
  }
}

({String repoDir, FakeGitGateway git}) createArtifactRepo(String baseDir, {required Iterable<String> paths}) {
  final repoDir = Directory(p.join(baseDir, 'projects', 'proj'))..createSync(recursive: true);
  final git = FakeGitGateway()..initWorktree(repoDir.path);
  for (final path in paths) {
    File(p.join(repoDir.path, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(path);
    git.addUntracked(repoDir.path, path, content: path);
  }
  return (repoDir: repoDir.path, git: git);
}

WorkflowCliRunner successWorkflowCliRunner({String sessionId = 'cli-session-success'}) {
  return WorkflowCliRunner(
    providers: const {
      'claude': WorkflowCliProviderConfig(executable: 'claude'),
      'codex': WorkflowCliProviderConfig(executable: 'codex'),
    },
    processStarter: (exe, args, {workingDirectory, environment}) async {
      final payload = jsonEncode({'session_id': sessionId, 'result': 'Done.'});
      return Process.start('/bin/sh', ['-lc', "printf '%s' '${payload.replaceAll("'", "'\\''")}'"]);
    },
  );
}

final class StaticPathWorktreeManager extends WorktreeManager {
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

/// Declarative one-off response for [ScriptedAgentWorker.enqueue].
///
/// Each turn consumes the next queued response in FIFO order. When the queue
/// is empty the worker falls back to the legacy single-response fields
/// ([ScriptedAgentWorker.responseText] etc.) for backward compatibility with
/// existing scenarios.
final class ScriptedResponse {
  /// Text streamed as a [DeltaEvent] before the turn returns.
  final String assistantContent;

  /// Usage payload returned from `turn()` — keys mirror what the real
  /// Codex/Claude harnesses expose (`input_tokens`, `cached_input_tokens`,
  /// `output_tokens`).
  final Map<String, dynamic> usage;

  /// When non-null the turn waits this long before returning. Useful for
  /// activity-watchdog / hang-detection tests.
  final Duration? delay;

  /// When true the turn throws instead of returning — simulates a mid-turn
  /// provider crash.
  final bool crash;

  /// Error to throw when [crash] is true. Defaults to a generic StateError.
  final Object? crashError;

  /// When true the turn never returns (emits nothing, awaits forever). Tests
  /// that want a bounded hang should prefer [delay] with a finite duration.
  final bool hang;

  /// Optional side effect executed once the turn has been invoked but before
  /// the response is streamed. Typical use: write a file into the worktree
  /// to simulate the agent's on-disk effect.
  final FutureOr<void> Function(String sessionId, String? directory)? onInvoked;

  const ScriptedResponse({
    this.assistantContent = '',
    this.usage = const {},
    this.delay,
    this.crash = false,
    this.crashError,
    this.hang = false,
    this.onInvoked,
  });
}

/// Scriptable [AgentHarness] double for component / scenario tests.
///
/// Usage patterns:
///  1. Legacy single-response: set [responseText] / [shouldFail]. Every turn
///     returns the same content. Kept for scenarios that only need one turn.
///  2. FIFO-queued responses: call [enqueue] per turn. Each call to [turn]
///     consumes the next entry. This is the preferred mode for component
///     tests exercising retry / multi-turn sequences.
///  3. Hybrid: queue a few responses; leftover turns fall through to the
///     legacy fields (useful for "first attempt crashes, everything after
///     succeeds" patterns).
class ScriptedAgentWorker implements AgentHarness {
  @override
  String skillActivationLine(String skill) => "Use the '$skill' skill.";

  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();

  String responseText = '';
  String? lastModel;
  String? lastDirectory;
  int inputTokens = 0;
  int outputTokens = 0;
  bool shouldFail = false;
  void Function(String sessionId)? onTurn;
  void Function(String sessionId, String? directory)? onTurnWithDirectory;
  Future<void> Function(String sessionId)? beforeComplete;

  /// Number of times `turn()` has been invoked — useful for retry assertions.
  int turnCount = 0;

  /// FIFO queue of scripted responses. Consumed left-to-right per `turn()`.
  final List<ScriptedResponse> _queue = [];

  /// Add a response to the end of the queue.
  void enqueue(ScriptedResponse response) => _queue.add(response);

  /// Convenience: enqueue a plain assistant content response.
  void enqueueContent(String content, {Map<String, dynamic> usage = const {}, Duration? delay}) {
    enqueue(ScriptedResponse(assistantContent: content, usage: usage, delay: delay));
  }

  /// Convenience: enqueue a crash-then-success pattern. Produces [retries]
  /// crash responses followed by one success response.
  void enqueueCrashThenSuccess({
    required String successContent,
    int retries = 1,
    Object? crashError,
    Map<String, dynamic> successUsage = const {},
  }) {
    for (var i = 0; i < retries; i++) {
      enqueue(ScriptedResponse(crash: true, crashError: crashError));
    }
    enqueue(ScriptedResponse(assistantContent: successContent, usage: successUsage));
  }

  /// Number of responses still queued.
  int get remainingResponses => _queue.length;

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
    turnCount++;
    onTurn?.call(sessionId);
    onTurnWithDirectory?.call(sessionId, directory);
    lastModel = model;
    lastDirectory = directory;
    final waitFor = beforeComplete;
    if (waitFor != null) {
      await waitFor(sessionId);
    }

    // Scripted-queue path: takes precedence over legacy single-response fields
    // when a response is queued for this turn.
    if (_queue.isNotEmpty) {
      final response = _queue.removeAt(0);
      await response.onInvoked?.call(sessionId, directory);
      if (response.hang) {
        // Await indefinitely — caller is expected to cancel the surrounding
        // task or fail the test on watchdog.
        await Completer<void>().future;
      }
      if (response.delay != null) {
        await Future<void>.delayed(response.delay!);
      }
      if (response.crash) {
        throw response.crashError ?? StateError('simulated crash');
      }
      if (response.assistantContent.isNotEmpty) {
        _eventsCtrl.add(DeltaEvent(response.assistantContent));
      }
      return Map<String, dynamic>.from(response.usage);
    }

    if (shouldFail) {
      throw StateError('simulated crash');
    }
    if (responseText.isNotEmpty) {
      _eventsCtrl.add(DeltaEvent(responseText));
    }
    return <String, dynamic>{'input_tokens': inputTokens, 'output_tokens': outputTokens};
  }

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
