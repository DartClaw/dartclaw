import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show CredentialRegistry, DartclawConfig, ProviderIdentity;
import 'package:dartclaw_core/dartclaw_core.dart'
    show EventBus, HarnessConfig, HarnessFactory, HarnessFactoryConfig, KvService, MessageService, SessionService;
import 'package:dartclaw_server/dartclaw_server.dart'
    show
        AssetResolver,
        ArtifactCollector,
        BehaviorFileService,
        HarnessPool,
        PromptScope,
        TaskExecutor,
        TaskService,
        TurnManager,
        TurnRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        SkillRegistryImpl,
        WorkflowDefinitionParser,
        WorkflowDefinitionValidator,
        WorkflowRegistry,
        WorkflowSource,
        WorkflowService,
        WorkflowTurnAdapter,
        WorkflowTurnOutcome;
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show SearchDbFactory, SqliteTaskRepository, SqliteWorkflowRunRepository, TaskDbFactory, openSearchDb, openTaskDb;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show Database;

import '../workflow_materializer.dart';
import '../workflow_skill_materializer.dart';

/// Minimal service graph for headless workflow execution.
///
/// Constructs only what [WorkflowService] + [TaskExecutor] need to run
/// workflows from the CLI. No HTTP server, no channels, no scheduling,
/// no template initialization.
class CliWorkflowWiring {
  final DartclawConfig config;
  final String dataDir;
  final String? skillsHomeDir;
  final HarnessFactory _harnessFactory;
  final SearchDbFactory _searchDbFactory;
  final TaskDbFactory _taskDbFactory;
  final AssetResolver assetResolver;

  late final EventBus eventBus;
  late final KvService kvService;
  late final SessionService sessionService;
  late final MessageService messageService;
  late final Database searchDb;
  late final Database taskDb;
  late final TaskService taskService;
  late final HarnessPool pool;
  late final TaskExecutor taskExecutor;
  late final SkillRegistryImpl skillRegistry;
  late final WorkflowRegistry registry;
  late final WorkflowService workflowService;
  late final BehaviorFileService behavior;

  late final CredentialRegistry _credentialRegistry;
  late final HarnessConfig _harnessConfig;

  CliWorkflowWiring({
    required this.config,
    required this.dataDir,
    this.skillsHomeDir,
    HarnessFactory? harnessFactory,
    SearchDbFactory? searchDbFactory,
    TaskDbFactory? taskDbFactory,
    AssetResolver? assetResolver,
  }) : _harnessFactory = harnessFactory ?? HarnessFactory(),
       _searchDbFactory = searchDbFactory ?? openSearchDb,
       _taskDbFactory = taskDbFactory ?? openTaskDb,
       assetResolver = assetResolver ?? AssetResolver();

  /// Constructs all services needed for headless workflow execution.
  ///
  /// Does not start an HTTP server, initialize templates, connect channels,
  /// or wire scheduling. Call [dispose] when done.
  Future<void> wire() async {
    eventBus = EventBus();
    final projectDirs = _workflowSkillProjectDirs(config);
    final resolvedAssets = assetResolver.resolve();
    final builtInSkillsSourceDir =
        resolvedAssets?.skillsDir ?? WorkflowSkillMaterializer.resolveBuiltInSkillsSourceDir();
    await WorkflowSkillMaterializer.materialize(
      activeHarnessTypes: _activeHarnessTypes(config),
      homeDir: skillsHomeDir,
      dataDir: dataDir,
      sourceDir: builtInSkillsSourceDir,
    );

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
    _credentialRegistry = CredentialRegistry(credentials: config.credentials, env: Platform.environment);
    _harnessConfig = HarnessConfig(
      maxTurns: config.agent.maxTurns,
      model: config.agent.model,
      effort: config.agent.effort,
    );

    final harness = _harnessFactory.create(
      defaultProviderId,
      HarnessFactoryConfig(
        cwd: Directory.current.path,
        executable: _resolveProviderExecutable(config, defaultProviderId),
        harnessConfig: _harnessConfig,
        providerOptions: _providerOptions(config, defaultProviderId),
        environment: _providerEnvironment(defaultProviderId, _credentialRegistry),
      ),
    );
    await harness.start();

    // Behavior service for TurnRunner
    behavior = BehaviorFileService(
      workspaceDir: config.workspaceDir,
      maxMemoryBytes: config.memory.maxBytes,
      compactInstructions: config.context.compactInstructions,
      identifierPreservation: config.context.identifierPreservation,
      identifierInstructions: config.context.identifierInstructions,
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

    final taskRunners = <TurnRunner>[await _buildTaskRunner(defaultProviderId)];
    final maxConcurrentTasks = _standaloneTaskRunnerCapacity(config);
    pool = HarnessPool(runners: [primaryRunner, ...taskRunners], maxConcurrentTasks: maxConcurrentTasks);

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
      identifierPreservation: config.context.identifierPreservation,
      identifierInstructions: config.context.identifierInstructions,
      budgetConfig: config.tasks.budget,
    );
    taskExecutor.start();

    // Workflow layer
    final workflowRunRepository = SqliteWorkflowRunRepository(taskDb);
    workflowService = WorkflowService(
      repository: workflowRunRepository,
      taskService: taskService,
      messageService: messageService,
      turnAdapter: WorkflowTurnAdapter(
        workflowWorkspaceDir: config.workflow.workspaceDir ?? p.join(dataDir, 'workflow-workspace'),
        reserveTurn: turns.reserveTurn,
        reserveTurnWithWorkflowWorkspaceDir: (sessionId, workflowWorkspaceDir) => turns.reserveTurn(
          sessionId,
          agentName: 'task',
          behaviorOverride: BehaviorFileService(
            workspaceDir: workflowWorkspaceDir,
            maxMemoryBytes: config.memory.maxBytes,
            compactInstructions: config.context.compactInstructions,
            identifierPreservation: config.context.identifierPreservation,
            identifierInstructions: config.context.identifierInstructions,
          ),
          promptScope: PromptScope.task,
        ),
        executeTurn: turns.executeTurn,
        waitForOutcome: (sessionId, turnId) async {
          final outcome = await turns.waitForOutcome(sessionId, turnId);
          return WorkflowTurnOutcome(status: outcome.status.name);
        },
        availableRunnerCount: () => turns.availableRunnerCount,
      ),
      eventBus: eventBus,
      kvService: kvService,
      dataDir: dataDir,
    );

    // Registry — materialize built-in workflows, then discover custom ones.
    skillRegistry = SkillRegistryImpl();
    skillRegistry.discover(
      projectDirs: projectDirs,
      workspaceDir: config.workspaceDir,
      dataDir: dataDir,
      builtInSkillsDir: builtInSkillsSourceDir,
    );
    final continuityProviders = pool.runners
        .where((r) => r.harness.supportsSessionContinuity)
        .map((r) => r.providerId)
        .toSet();
    registry = WorkflowRegistry(
      parser: WorkflowDefinitionParser(),
      validator: WorkflowDefinitionValidator(),
      continuityProviders: continuityProviders,
    );
    registry.skillRegistry = skillRegistry;
    await WorkflowMaterializer.materialize(workspaceDir: config.workspaceDir, assetResolver: assetResolver);
    await registry.loadFromDirectory(p.join(config.workspaceDir, 'workflows'), source: WorkflowSource.materialized);
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

  /// Ensures the pool contains task runners for every [providerIds] entry.
  ///
  /// Standalone workflow execution relies on task runners for agent-backed
  /// steps; without them, queued tasks never start in pool mode.
  Future<void> ensureTaskRunnersForProviders(Set<String> providerIds) async {
    for (final providerId in providerIds) {
      if (pool.hasTaskRunnerForProvider(providerId)) {
        continue;
      }
      pool.addRunner(await _buildTaskRunner(providerId));
    }
  }

  Future<TurnRunner> _buildTaskRunner(String providerId) async {
    final harness = _harnessFactory.create(
      providerId,
      HarnessFactoryConfig(
        cwd: Directory.current.path,
        executable: _resolveProviderExecutable(config, providerId),
        harnessConfig: _harnessConfig,
        providerOptions: _providerOptions(config, providerId),
        environment: _providerEnvironment(providerId, _credentialRegistry),
      ),
    );
    await harness.start();
    return TurnRunner(
      harness: harness,
      messages: messageService,
      behavior: behavior,
      sessions: sessionService,
      kv: kvService,
      eventBus: eventBus,
      providerId: providerId,
    );
  }
}

Set<String> _activeHarnessTypes(DartclawConfig config) {
  final harnessTypes = <String>{};

  void addProvider(String providerId) {
    final family = ProviderIdentity.family(providerId);
    if (family == 'claude' || family == 'codex') {
      harnessTypes.add(family);
    }
  }

  addProvider(config.agent.provider);
  for (final providerId in config.providers.entries.keys) {
    addProvider(providerId);
  }

  return harnessTypes;
}

List<String> _workflowSkillProjectDirs(DartclawConfig config) {
  if (config.projects.definitions.isEmpty) {
    return [Directory.current.path];
  }
  return config.projects.definitions.values.map((project) => p.join(config.projectsClonesDir, project.id)).toList();
}

int _standaloneTaskRunnerCapacity(DartclawConfig config) {
  final configuredProviders = <String>{config.agent.provider, ...config.providers.entries.keys};
  // Standalone workflows may need to provision an explicit provider that is
  // not the default (for example, built-in workflows target `claude` even
  // when the default provider is Codex). Reserve enough task-runner slots to
  // materialize the built-in provider families on demand.
  const minimumStandaloneCapacity = 3;
  final minimumCapacity = configuredProviders.length > minimumStandaloneCapacity
      ? configuredProviders.length
      : minimumStandaloneCapacity;
  if (config.tasks.maxConcurrent > minimumCapacity) {
    return config.tasks.maxConcurrent;
  }
  return minimumCapacity;
}

Map<String, String> _providerEnvironment(String providerId, CredentialRegistry registry) {
  final environment = Map<String, String>.from(Platform.environment)
    ..remove('ANTHROPIC_API_KEY')
    ..remove('OPENAI_API_KEY')
    ..remove('CODEX_API_KEY')
    ..remove('CLAUDE_CODE_SUBAGENT_MODEL');
  final apiKey = registry.getApiKey(providerId);
  if (apiKey != null) {
    for (final envVar in CredentialRegistry.envVarsFor(providerId)) {
      environment[envVar] = apiKey;
    }
  }
  return environment;
}

String _resolveProviderExecutable(DartclawConfig config, String providerId) {
  final entry = config.providers[providerId];
  if (entry != null) {
    return entry.executable;
  }
  return switch (ProviderIdentity.family(providerId)) {
    'claude' => config.server.claudeExecutable,
    'codex' => 'codex',
    _ => providerId,
  };
}

Map<String, dynamic> _providerOptions(DartclawConfig config, String providerId) =>
    config.providers[providerId]?.options ?? const <String, dynamic>{};
