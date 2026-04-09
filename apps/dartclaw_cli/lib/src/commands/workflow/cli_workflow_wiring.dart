import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        DartclawConfig,
        EventBus,
        HarnessConfig,
        HarnessFactory,
        HarnessFactoryConfig,
        KvService,
        MessageService,
        SessionService,
        WorkflowDefinitionParser,
        WorkflowDefinitionValidator;
import 'package:dartclaw_server/dartclaw_server.dart'
    show
        ArtifactCollector,
        BehaviorFileService,
        HarnessPool,
        TaskExecutor,
        TaskService,
        TurnManager,
        TurnRunner,
        WorkflowRegistry,
        WorkflowService;
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show SearchDbFactory, SqliteTaskRepository, SqliteWorkflowRunRepository, TaskDbFactory, openSearchDb, openTaskDb;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show Database;

/// Minimal service graph for headless workflow execution.
///
/// Constructs only what [WorkflowService] + [TaskExecutor] need to run
/// workflows from the CLI. No HTTP server, no channels, no scheduling,
/// no template initialization.
class CliWorkflowWiring {
  final DartclawConfig config;
  final String dataDir;
  final HarnessFactory _harnessFactory;
  final SearchDbFactory _searchDbFactory;
  final TaskDbFactory _taskDbFactory;

  late final EventBus eventBus;
  late final KvService kvService;
  late final SessionService sessionService;
  late final MessageService messageService;
  late final Database searchDb;
  late final Database taskDb;
  late final TaskService taskService;
  late final HarnessPool pool;
  late final TaskExecutor taskExecutor;
  late final WorkflowRegistry registry;
  late final WorkflowService workflowService;

  CliWorkflowWiring({
    required this.config,
    required this.dataDir,
    HarnessFactory? harnessFactory,
    SearchDbFactory? searchDbFactory,
    TaskDbFactory? taskDbFactory,
  }) : _harnessFactory = harnessFactory ?? HarnessFactory(),
       _searchDbFactory = searchDbFactory ?? openSearchDb,
       _taskDbFactory = taskDbFactory ?? openTaskDb;

  /// Constructs all services needed for headless workflow execution.
  ///
  /// Does not start an HTTP server, initialize templates, connect channels,
  /// or wire scheduling. Call [dispose] when done.
  Future<void> wire() async {
    eventBus = EventBus();

    // Storage layer
    searchDb = _searchDbFactory(config.searchDbPath);
    taskDb = _taskDbFactory(config.tasksDbPath);
    kvService = KvService(filePath: config.kvPath);
    sessionService = SessionService(baseDir: config.sessionsDir, eventBus: eventBus);
    messageService = MessageService(baseDir: config.sessionsDir);

    await sessionService.getOrCreateMain();

    // Task layer
    final taskRepository = SqliteTaskRepository(taskDb);
    final taskServiceInst = TaskService(taskRepository, eventBus: eventBus);
    taskService = taskServiceInst;

    // Harness: minimal config — no MCP server, no container, no guards.
    final defaultProviderId = config.agent.provider;
    final executable = switch (config.providers[defaultProviderId]) {
      final entry? => entry.executable,
      null => config.server.claudeExecutable,
    };
    final harnessConfig = HarnessConfig(
      maxTurns: config.agent.maxTurns,
      model: config.agent.model,
      effort: config.agent.effort,
    );

    final harness = _harnessFactory.create(
      defaultProviderId,
      HarnessFactoryConfig(
        cwd: Directory.current.path,
        executable: executable,
        harnessConfig: harnessConfig,
      ),
    );
    await harness.start();

    // Behavior service for TurnRunner
    final behavior = BehaviorFileService(
      workspaceDir: config.workspaceDir,
      maxMemoryBytes: config.memory.maxBytes,
      compactInstructions: config.context.compactInstructions,
    );

    final primaryRunner = TurnRunner(
      harness: harness,
      messages: messageService,
      behavior: behavior,
      sessions: sessionService,
      kv: kvService,
      eventBus: eventBus,
      providerId: defaultProviderId,
    );

    // maxConcurrentTasks: 0 means no extra task runners — the primary runner
    // handles all turns. The workflow executor spawns steps sequentially.
    pool = HarnessPool(runners: [primaryRunner], maxConcurrentTasks: config.tasks.maxConcurrent);

    final turns = TurnManager.fromPool(pool: pool, sessions: sessionService);

    final artifactCollector = ArtifactCollector(
      tasks: taskService,
      messages: messageService,
      sessionsDir: config.sessionsDir,
      dataDir: dataDir,
      workspaceDir: config.workspaceDir,
    );

    taskExecutor = TaskExecutor(
      tasks: taskService,
      sessions: sessionService,
      messages: messageService,
      turns: turns,
      artifactCollector: artifactCollector,
      kvService: kvService,
      eventBus: eventBus,
      dataDir: dataDir,
      workspaceDir: config.workspaceDir,
      maxMemoryBytes: config.memory.maxBytes,
      compactInstructions: config.context.compactInstructions,
      budgetConfig: config.tasks.budget,
    );
    taskExecutor.start();

    // Workflow layer
    final workflowRunRepository = SqliteWorkflowRunRepository(taskDb);
    workflowService = WorkflowService(
      repository: workflowRunRepository,
      taskService: taskService,
      messageService: messageService,
      turnManager: turns,
      eventBus: eventBus,
      kvService: kvService,
      dataDir: dataDir,
    );

    // Registry — load built-in workflows, then discover custom ones.
    final continuityProviders = pool.runners
        .where((r) => r.harness.supportsSessionContinuity)
        .map((r) => r.providerId)
        .toSet();
    registry = WorkflowRegistry(
      parser: WorkflowDefinitionParser(),
      validator: WorkflowDefinitionValidator(),
      continuityProviders: continuityProviders,
    );
    registry.loadBuiltIn();
    await registry.loadFromDirectory(p.join(config.workspaceDir, 'workflows'));
    for (final projectDef in config.projects.definitions.values) {
      final projectCloneDir = p.join(config.projectsClonesDir, projectDef.id);
      await registry.loadFromDirectory(p.join(projectCloneDir, 'workflows'));
    }
  }

  /// Tears down all services in reverse construction order.
  Future<void> dispose() async {
    await workflowService.dispose();
    await taskExecutor.stop();
    await taskService.dispose();
    await pool.dispose();
    await kvService.dispose();
    searchDb.close();
    taskDb.close();
  }
}
