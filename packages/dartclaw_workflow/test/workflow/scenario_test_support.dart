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
  late _FakeTaskWorker _worker;
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
    harness._worker = _FakeTaskWorker();
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

  void setWorkerResponseText(String value) {
    _worker.responseText = value;
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

class _FakeTaskWorker implements AgentHarness {
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
