import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show CredentialRegistry, DartclawConfig, ProviderIdentity;
import 'package:dartclaw_core/dartclaw_core.dart'
    show
        ArtifactKind,
        EventBus,
        HarnessConfig,
        HarnessFactory,
        HarnessFactoryConfig,
        KvService,
        MessageService,
        SessionService,
        Task;
import 'package:dartclaw_security/dartclaw_security.dart' show SafeProcess, normalizeGitRefOperand;
import 'package:dartclaw_server/dartclaw_server.dart'
    show
        AssetResolver,
        ArtifactCollector,
        BehaviorFileService,
        DiffGenerator,
        GitCredentialPlan,
        HarnessPool,
        ProjectServiceImpl,
        PromptScope,
        RemotePushService,
        resolveGitCredentialPlan,
        TaskCancellationSubscriber,
        TaskEventRecorder,
        WorkflowCliProviderConfig,
        WorkflowCliRunner,
        TaskExecutor,
        TaskExecutorLimits,
        TaskExecutorRunners,
        TaskExecutorServices,
        WorktreeManager,
        WorkflowGitPortProcess,
        TaskService,
        TurnManager,
        TurnRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        SkillRegistryImpl,
        ProcessRunner,
        WorkspaceSkillInventory,
        WorkspaceSkillLinker,
        WorkflowDefinitionParser,
        WorkflowDefinitionValidator,
        WorkflowRegistry,
        WorkflowRoleDefault,
        WorkflowRoleDefaults,
        WorkflowSource,
        WorkflowStepOutputTransformer,
        WorkflowService,
        WorkflowGitIntegrationBranchResult,
        WorkflowGitPublishResult,
        WorkflowPublishStatus,
        WorkflowStartResolution,
        WorkflowTurnAdapter,
        WorkflowTurnOutcome;
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show
        SearchDbFactory,
        SqliteAgentExecutionRepository,
        SqliteExecutionRepositoryTransactor,
        SqliteTaskRepository,
        SqliteWorkflowStepExecutionRepository,
        SqliteWorkflowRunRepository,
        TaskDbFactory,
        TaskEventService,
        openSearchDb,
        openTaskDb;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show Database;

import '../workflow_materializer.dart';
import '../workflow_skill_source_resolver.dart';
import 'andthen_skill_bootstrap.dart';
import 'credential_preflight.dart';
import 'project_definition_paths.dart';
import 'workflow_git_support.dart';
import 'workflow_local_path_preflight.dart';

part 'cli_workflow_wiring_adapter.dart';
part 'cli_workflow_wiring_git.dart';

/// Outcome of a standalone-mode pull-request creation hook.
///
/// Mirrors the three-state contract used by the server-backed publish path
/// (`success`, `manual`, `failed`). [CliWorkflowWiring.prCreator] returns one
/// of these after a successful branch push; the value is threaded through
/// `WorkflowGitPublishResult.prUrl` into the workflow context as
/// `publish.pr_url`.
class CliWorkflowPrResult {
  final WorkflowPublishStatus status;
  final String prUrl;
  final String? error;

  const CliWorkflowPrResult({required this.status, required this.prUrl, this.error});
}

/// Optional PR-creation hook for standalone CLI workflow runs.
///
/// Production `CliWorkflowWiring` does not pass a creator: the standalone
/// publish path pushes the branch and returns `publish.pr_url == ''`, leaving
/// PR creation to the operator. Tests (and alternative standalone entry
/// points) can inject a creator — e.g. one that shells out to `gh pr create`
/// — to exercise the full publish → context → consumer pipeline end to end.
typedef CliWorkflowPrCreator =
    Future<CliWorkflowPrResult> Function({required String runId, required String projectId, required String branch});

String? _assetResolverHome(Map<String, String>? environment) {
  final env = environment ?? Platform.environment;
  final home = env['HOME']?.trim();
  if (home != null && home.isNotEmpty) return home;
  final userProfile = env['USERPROFILE']?.trim();
  return userProfile == null || userProfile.isEmpty ? null : userProfile;
}

/// Minimal service graph for headless workflow execution.
///
/// Constructs only what [WorkflowService] + [TaskExecutor] need to run
/// workflows from the CLI. No HTTP server, no channels, no scheduling,
/// no template initialization.
class CliWorkflowWiring {
  final DartclawConfig config;
  final String dataDir;
  final String runtimeCwd;
  final Map<String, String> environment;
  final HarnessFactory _harnessFactory;
  final SearchDbFactory _searchDbFactory;
  final TaskDbFactory _taskDbFactory;
  final AssetResolver assetResolver;
  final WorkflowStepOutputTransformer? workflowStepOutputTransformer;
  final bool runAndthenSkillsBootstrap;
  final ProcessRunner? skillProvisionerProcessRunner;
  final RemotePushService? remotePushServiceOverride;

  /// When true, the live source tree wins over the installed asset cache for
  /// both built-in skill provisioning and workflow YAML materialization. The
  /// maintainer profile (`dev/tools/dartclaw-workflows/run.sh`) sets this so
  /// edits to checked-out skills/YAMLs take effect without pruning
  /// `~/.dartclaw/assets/v<version>/` by hand.
  final bool preferSourceTreeAssets;

  /// Optional hook invoked after a successful standalone publish push to
  /// create a pull request; null by default (production behavior).
  final CliWorkflowPrCreator? prCreator;

  late final EventBus eventBus;
  late final KvService kvService;
  late final SessionService sessionService;
  late final MessageService messageService;
  late final Database searchDb;
  late final Database taskDb;
  late final TaskService taskService;
  late final WorktreeManager worktreeManager;
  late final HarnessPool pool;
  late final TaskExecutor taskExecutor;
  late final TaskCancellationSubscriber taskCancellationSubscriber;
  late final SkillRegistryImpl skillRegistry;
  late final WorkflowRegistry registry;
  late final WorkflowService workflowService;
  late final WorkflowCliRunner workflowCliRunner;
  late final BehaviorFileService behavior;
  late final ProjectServiceImpl projectService;
  late final RemotePushService remotePushService;

  late final CredentialRegistry _credentialRegistry;
  late final HarnessConfig _harnessConfig;

  CliWorkflowWiring({
    required this.config,
    required this.dataDir,
    String? runtimeCwd,
    Map<String, String>? environment,
    HarnessFactory? harnessFactory,
    SearchDbFactory? searchDbFactory,
    TaskDbFactory? taskDbFactory,
    AssetResolver? assetResolver,
    this.workflowStepOutputTransformer,
    this.runAndthenSkillsBootstrap = true,
    this.skillProvisionerProcessRunner,
    this.remotePushServiceOverride,
    this.prCreator,
    this.preferSourceTreeAssets = false,
  }) : runtimeCwd = runtimeCwd ?? Directory.current.path,
       environment = environment ?? Platform.environment,
       _harnessFactory = harnessFactory ?? HarnessFactory(),
       _searchDbFactory = searchDbFactory ?? openSearchDb,
       _taskDbFactory = taskDbFactory ?? openTaskDb,
       assetResolver = assetResolver ?? AssetResolver(homeDir: _assetResolverHome(environment));

  Future<void> _materializeWorkflowSkillsForWorktree(String worktreePath, WorkspaceSkillLinker linker) async {
    final inventory = WorkspaceSkillInventory.fromDataDir(dataDir);
    linker.materialize(
      dataDir: dataDir,
      workspaceDir: worktreePath,
      skillNames: inventory.skillNames,
      agentMdNames: inventory.agentMdNames,
      agentTomlNames: inventory.agentTomlNames,
    );
  }

  /// Constructs all services needed for headless workflow execution.
  ///
  /// Does not start an HTTP server, initialize templates, connect channels,
  /// or wire scheduling. Call [dispose] when done.
  Future<void> wire() async {
    final ctx = await _wirePrelude();
    await _wireStorage();
    final taskHandles = await _wireTaskLayer(ctx);
    final wiredCtx = await _wireHarness(ctx, taskHandles);
    await _wireWorkflowService(wiredCtx, taskHandles);
    await _wireWorkflowRegistry(wiredCtx);
  }

  Future<_CliWorkflowWiringCtx> _wirePrelude() async {
    final wiringLog = Logger('CliWorkflowWiring');
    final preflight = CredentialPreflight.validate(config, environment);
    for (final warning in preflight.warnings) {
      wiringLog.warning(warning);
    }
    if (preflight.hasHardErrors) {
      throw CredentialPreflightException(preflight.hardErrors);
    }
    eventBus = EventBus();
    final workspaceSkillLinker = WorkspaceSkillLinker();
    final projectDirs = workflowSkillProjectDirs(config, fallbackCwd: runtimeCwd);
    final resolvedAssets = assetResolver.resolve();
    final assetSkillsDir = resolvedAssets?.skillsDir;
    final sourceSkillsDir = WorkflowSkillSourceResolver.resolveBuiltInSkillsSourceDir();
    final builtInSkillsSourceDir = preferSourceTreeAssets
        ? (sourceSkillsDir ?? assetSkillsDir)
        : (assetSkillsDir ?? sourceSkillsDir);
    if (runAndthenSkillsBootstrap) {
      await bootstrapWorkflowSkills(
        config: config,
        dataDir: dataDir,
        builtInSkillsSourceDir: builtInSkillsSourceDir,
        fallbackWorkspaceDir: runtimeCwd,
        environment: environment,
        processRunner: skillProvisionerProcessRunner,
      );
    }
    final dataDirSkillRoots = workflowDataDirSkillRoots(dataDir);
    final userSkillRoots = workflowOptionalUserSkillRoots(environment);
    skillRegistry = SkillRegistryImpl();
    skillRegistry.discover(
      projectDirs: projectDirs,
      workspaceDir: config.workspaceDir,
      dataDir: dataDir,
      builtInSkillsDir: builtInSkillsSourceDir,
      dataDirClaudeSkillsDir: dataDirSkillRoots.claudeSkillsDir,
      dataDirAgentsSkillsDir: dataDirSkillRoots.agentsSkillsDir,
      userClaudeSkillsDir: userSkillRoots?.claudeSkillsDir,
      userAgentsSkillsDir: userSkillRoots?.agentsSkillsDir,
    );
    _credentialRegistry = CredentialRegistry(credentials: config.credentials, env: environment);
    _harnessConfig = HarnessConfig(
      maxTurns: config.agent.maxTurns,
      model: config.agent.model,
      effort: config.agent.effort,
    );
    return _CliWorkflowWiringCtx(workspaceSkillLinker: workspaceSkillLinker);
  }

  Future<void> _wireStorage() async {
    searchDb = _searchDbFactory(config.searchDbPath);
    taskDb = _taskDbFactory(config.tasksDbPath);
    kvService = KvService(filePath: config.kvPath);
    sessionService = SessionService(baseDir: config.sessionsDir, eventBus: eventBus);
    messageService = MessageService(baseDir: config.sessionsDir);
    await sessionService.getOrCreateMainSession();
    projectService = ProjectServiceImpl(
      dataDir: dataDir,
      projectConfig: config.projects,
      credentials: config.credentials,
      eventBus: eventBus,
    );
    await projectService.initialize();
    remotePushService =
        remotePushServiceOverride ?? RemotePushService(credentials: config.credentials, dataDir: dataDir);
  }

  Future<_TaskHandles> _wireTaskLayer(_CliWorkflowWiringCtx ctx) async {
    final agentExecutionRepository = SqliteAgentExecutionRepository(taskDb, eventBus: eventBus);
    final workflowStepExecutionRepository = SqliteWorkflowStepExecutionRepository(taskDb);
    final executionRepositoryTransactor = SqliteExecutionRepositoryTransactor(taskDb);
    final taskRepository = SqliteTaskRepository(taskDb);
    final workflowRunRepository = SqliteWorkflowRunRepository(taskDb);
    final taskEventRecorder = TaskEventRecorder(eventService: TaskEventService(taskDb), eventBus: eventBus);
    taskService = TaskService(
      taskRepository,
      agentExecutionRepository: agentExecutionRepository,
      executionTransactor: executionRepositoryTransactor,
      eventBus: eventBus,
      eventRecorder: taskEventRecorder,
    );
    worktreeManager = WorktreeManager(
      dataDir: dataDir,
      baseRef: config.tasks.worktreeBaseRef,
      staleTimeoutHours: config.tasks.worktreeStaleTimeoutHours,
      worktreesDir: p.join(config.workspaceDir, '.dartclaw', 'worktrees'),
      taskLookup: taskService.get,
      projectLookup: projectService.get,
      skillMaterializer: (worktreePath) =>
          _materializeWorkflowSkillsForWorktree(worktreePath, ctx.workspaceSkillLinker),
    );
    await worktreeManager.detectStaleWorktrees();
    return _TaskHandles(
      agentExecutionRepository: agentExecutionRepository,
      workflowStepExecutionRepository: workflowStepExecutionRepository,
      executionRepositoryTransactor: executionRepositoryTransactor,
      taskRepository: taskRepository,
      workflowRunRepository: workflowRunRepository,
      taskEventRecorder: taskEventRecorder,
    );
  }

  Future<_CliWorkflowWiringCtx> _wireHarness(_CliWorkflowWiringCtx ctx, _TaskHandles taskHandles) async {
    final wiringLog = Logger('CliWorkflowWiring');
    final defaultProviderId = config.agent.provider;
    final providerEntry = config.providers[defaultProviderId];
    wiringLog.info(
      'Provider "$defaultProviderId": entry=${providerEntry != null ? providerEntry.toString() : "null"}, '
      'options=${providerEntry?.options}',
    );
    final harness = _harnessFactory.create(
      defaultProviderId,
      HarnessFactoryConfig(
        cwd: runtimeCwd,
        executable: _resolveProviderExecutable(config, defaultProviderId),
        harnessConfig: _harnessConfig,
        providerOptions: _providerOptions(config, defaultProviderId),
        environment: _providerEnvironment(defaultProviderId, _credentialRegistry),
      ),
    );
    await harness.start();
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
    final maxConcurrentTasks = _standaloneTaskRunnerCapacity(config);
    // Spawn up to the default provider's configured `pool_size` task runners
    // at wire time (bounded by the pool's overall task capacity). Previously
    // only a single task runner was spawned eagerly — subsequent slots were
    // reserved on the pool but never filled, so `HarnessPool.availableCount`
    // was capped at 1. That silently serialised workflows that declared
    // `max_parallel > 1` (e.g. `plan-and-implement` foreach), because the
    // executor's `effectiveConcurrency(poolAvailable)` path saw `poolAvailable`
    // drop to 0 whenever the single live runner was busy.
    final desiredDefaultRunners = providerEntry?.poolSize ?? 0;
    final defaultRunnersToSpawn = desiredDefaultRunners > 0
        ? (desiredDefaultRunners > maxConcurrentTasks ? maxConcurrentTasks : desiredDefaultRunners)
        : 1;
    final taskRunners = <TurnRunner>[];
    for (var i = 0; i < defaultRunnersToSpawn; i++) {
      taskRunners.add(await _buildTaskRunner(defaultProviderId));
    }
    wiringLog.info(
      'Spawned $defaultRunnersToSpawn task runner(s) for default provider "$defaultProviderId" '
      '(pool_size=${providerEntry?.poolSize ?? "(unset, default 1)"}, '
      'maxConcurrentTasks=$maxConcurrentTasks)',
    );
    pool = HarnessPool(runners: [primaryRunner, ...taskRunners], maxConcurrentTasks: maxConcurrentTasks);
    final turns = TurnManager.fromPool(pool: pool, sessions: sessionService);
    taskCancellationSubscriber = TaskCancellationSubscriber(tasks: taskService, turns: turns);
    taskCancellationSubscriber.subscribe(eventBus);
    final artifactCollector = ArtifactCollector(
      tasks: taskService,
      messages: messageService,
      sessionsDir: config.sessionsDir,
      dataDir: dataDir,
      workspaceDir: config.workspaceDir,
      diffGenerator: DiffGenerator(projectDir: runtimeCwd),
      projectService: projectService,
    );
    workflowCliRunner = WorkflowCliRunner(
      providers: {
        for (final providerId in <String>{config.agent.provider, ...config.providers.entries.keys})
          providerId: WorkflowCliProviderConfig(
            executable: _resolveProviderExecutable(config, providerId),
            environment: _providerEnvironment(providerId, _credentialRegistry),
            options: _providerOptions(config, providerId),
          ),
      },
      eventBus: eventBus,
    );
    taskExecutor = TaskExecutor(
      services: TaskExecutorServices(
        tasks: taskService,
        sessions: sessionService,
        messages: messageService,
        artifactCollector: artifactCollector,
        worktreeManager: worktreeManager,
        workflowStepExecutionRepository: taskHandles.workflowStepExecutionRepository,
        workflowRunRepository: taskHandles.workflowRunRepository,
        kvService: kvService,
        eventBus: eventBus,
        eventRecorder: taskHandles.taskEventRecorder,
        projectService: projectService,
      ),
      runners: TaskExecutorRunners(turns: turns, workflowCliRunner: workflowCliRunner),
      limits: TaskExecutorLimits(
        maxMemoryBytes: config.memory.maxBytes,
        compactInstructions: config.context.compactInstructions,
        identifierPreservation: config.context.identifierPreservation,
        identifierInstructions: config.context.identifierInstructions,
        budgetConfig: config.tasks.budget,
      ),
      dataDir: dataDir,
      workspaceRoot: config.workspaceDir,
    );
    taskExecutor.start();
    return ctx.withTurns(turns);
  }

  WorkflowRoleDefaults _buildWorkflowRoleDefaults() {
    return WorkflowRoleDefaults(
      workflow: WorkflowRoleDefault(
        provider: config.workflow.defaults.workflow.provider,
        model: config.workflow.defaults.workflow.model,
        effort: config.workflow.defaults.workflow.effort,
      ),
      planner: WorkflowRoleDefault(
        provider: config.workflow.defaults.planner.provider,
        model: config.workflow.defaults.planner.model,
        effort: config.workflow.defaults.planner.effort,
      ),
      executor: WorkflowRoleDefault(
        provider: config.workflow.defaults.executor.provider,
        model: config.workflow.defaults.executor.model,
        effort: config.workflow.defaults.executor.effort,
      ),
      reviewer: WorkflowRoleDefault(
        provider: config.workflow.defaults.reviewer.provider,
        model: config.workflow.defaults.reviewer.model,
        effort: config.workflow.defaults.reviewer.effort,
      ),
    );
  }

  Future<void> _wireWorkflowService(_CliWorkflowWiringCtx ctx, _TaskHandles taskHandles) async {
    final workflowRoleDefaults = _buildWorkflowRoleDefaults();
    workflowService = WorkflowService(
      repository: taskHandles.workflowRunRepository,
      taskService: taskService,
      messageService: messageService,
      bashStepEnvAllowlist: config.security.bashStep.envAllowlist,
      bashStepExtraStripPatterns: config.security.bashStep.extraStripPatterns,
      taskRepository: taskHandles.taskRepository,
      agentExecutionRepository: taskHandles.agentExecutionRepository,
      workflowStepExecutionRepository: taskHandles.workflowStepExecutionRepository,
      executionRepositoryTransactor: taskHandles.executionRepositoryTransactor,
      projectService: projectService,
      workflowGitPort: WorkflowGitPortProcess(worktreeManager: worktreeManager),
      roleDefaults: workflowRoleDefaults,
      structuredOutputFallbackRecorder: taskHandles.taskEventRecorder.recordStructuredOutputFallbackUsed,
      skillRegistry: skillRegistry,
      hydrateWorkflowWorktreeBinding: taskExecutor.hydrateWorkflowSharedWorktreeBinding,
      turnAdapter: _buildWorkflowTurnAdapter(this, ctx),
      eventBus: eventBus,
      kvService: kvService,
      dataDir: dataDir,
      outputTransformer: workflowStepOutputTransformer,
    );
  }

  Future<void> _wireWorkflowRegistry(_CliWorkflowWiringCtx ctx) async {
    final workflowRoleDefaults = _buildWorkflowRoleDefaults();
    final continuityProviders = pool.runners
        .where((r) => r.harness.supportsSessionContinuity)
        .map((r) => r.providerId)
        .toSet();
    registry = WorkflowRegistry(
      parser: WorkflowDefinitionParser(),
      validator: WorkflowDefinitionValidator(roleDefaults: workflowRoleDefaults),
      continuityProviders: continuityProviders,
    );
    registry.skillRegistry = skillRegistry;
    await WorkflowMaterializer.materialize(
      dataDir: dataDir,
      assetResolver: assetResolver,
      preferSourceTree: preferSourceTreeAssets,
    );
    await registry.loadFromDirectory(WorkflowMaterializer.builtInDir(dataDir), source: WorkflowSource.materialized);
    await registry.loadFromDirectory(WorkflowMaterializer.customDir(dataDir));
    for (final projectDef in config.projects.definitions.values) {
      await registry.loadFromDirectory(p.join(configuredProjectDirectory(config, projectDef), 'workflows'));
    }
  }

  /// Tears down all services in reverse construction order.
  Future<void> dispose() async {
    await workflowService.dispose();
    await taskExecutor.stop();
    await _cleanupTrackedWorkflowGit(this);
    await taskCancellationSubscriber.dispose();
    await taskService.dispose();
    await pool.dispose();
    await kvService.dispose();
    remotePushService.dispose();
    await projectService.dispose();
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
        workflowCliRunner.providers.putIfAbsent(
          providerId,
          () => WorkflowCliProviderConfig(
            executable: _resolveProviderExecutable(config, providerId),
            environment: _providerEnvironment(providerId, _credentialRegistry),
            options: _providerOptions(config, providerId),
          ),
        );
        continue;
      }
      pool.addRunner(await _buildTaskRunner(providerId));
      workflowCliRunner.providers.putIfAbsent(
        providerId,
        () => WorkflowCliProviderConfig(
          executable: _resolveProviderExecutable(config, providerId),
          environment: _providerEnvironment(providerId, _credentialRegistry),
          options: _providerOptions(config, providerId),
        ),
      );
    }
  }

  Future<TurnRunner> _buildTaskRunner(String providerId) async {
    final harness = _harnessFactory.create(
      providerId,
      HarnessFactoryConfig(
        cwd: runtimeCwd,
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
