import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart'
    show CredentialRegistry, DartclawConfig, ProviderEntry, ProviderIdentity;
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
        AssetResolutionRequest,
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
        CliProviderAuthPreflight,
        CliSkillIntrospector,
        ProcessRunner,
        ProviderAuthPreflight,
        WorkspaceSkillInventory,
        WorkspaceSkillLinker,
        SkillIntrospector,
        WorkflowDefinitionParser,
        WorkflowDefinitionValidator,
        WorkflowRegistry,
        WorkflowRoleDefault,
        WorkflowRoleDefaults,
        WorkflowSource,
        WorkflowStepOutputTransformer,
        WorkflowService,
        WorkflowGitContext,
        WorkflowGitIntegrationBranchResult,
        WorkflowPersistencePorts,
        WorkflowGitPublishResult,
        WorkflowPreflightException,
        WorkflowPublishStatus,
        WorkflowRun,
        WorkflowServiceOptions,
        WorkflowSkillPreflightConfig,
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
import '../workflow_asset_source_resolver.dart';
import 'andthen_skill_bootstrap.dart';
import 'credential_preflight.dart';
import 'project_definition_paths.dart';
import 'workflow_git_support.dart';
import 'workflow_local_path_preflight.dart';
import 'workflow_provider_environment.dart';
import 'workflow_skill_preflight_config.dart';

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
  final SkillIntrospector? skillIntrospector;
  final ProviderAuthPreflight? providerAuthPreflight;
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
  late final WorkflowRegistry registry;
  late final WorkflowService workflowService;
  late final WorkflowCliRunner workflowCliRunner;
  late final BehaviorFileService behavior;
  late final ProjectServiceImpl projectService;
  late final RemotePushService remotePushService;

  late final CredentialRegistry _credentialRegistry;
  late final HarnessConfig _harnessConfig;
  late final SqliteWorkflowRunRepository _workflowRunRepository;

  // Two-phase wiring state. Registry/materialization completes in the
  // pre-harness phase ([wirePreHarness]); provider harnesses start only in the
  // deferred phase ([startHarnesses]) keyed by an explicit provider set, so a
  // standalone run can preflight referenced-provider auth before any
  // `harness.start()`. These carry the prelude context and task-layer handles
  // between the two phases.
  _CliWorkflowWiringCtx? _preludeCtx;
  _TaskHandles? _taskHandles;
  bool _preHarnessWired = false;
  bool _harnessStarted = false;
  bool _workflowServiceWired = false;

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
    this.skillIntrospector,
    this.providerAuthPreflight,
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

  /// Constructs all services needed for headless workflow execution, starting
  /// harnesses for the configured default provider.
  ///
  /// Does not start an HTTP server, initialize templates, connect channels,
  /// or wire scheduling. Call [dispose] when done.
  ///
  /// Convenience facade over the two-phase API ([wirePreHarness] +
  /// [startHarnesses]) for callers that do not need to gate provider auth
  /// before harness startup. Standalone run/resume paths call the two phases
  /// directly so they can run [preflightProviderAuth] in between.
  Future<void> wire() async {
    await wirePreHarness();
    await startHarnesses({config.agent.provider});
  }

  /// Completes registry/materialization and every service that does not require
  /// a started provider harness — prelude, storage, the task layer, and the
  /// workflow registry — without starting any harness.
  ///
  /// [registry] is usable after this returns; [startHarnesses] must run before
  /// [workflowService]/[pool]/[taskExecutor] are touched. Idempotent guard:
  /// safe to follow with [dispose] even if [startHarnesses] never runs.
  Future<void> wirePreHarness() async {
    final ctx = await _wirePrelude();
    await _wireStorage();
    final taskHandles = await _wireTaskLayer(ctx);
    await _wireWorkflowRegistry();
    _preludeCtx = ctx;
    _taskHandles = taskHandles;
    _preHarnessWired = true;
  }

  /// Starts provider harnesses for [providers] and builds the turn/task/workflow
  /// services that depend on them.
  ///
  /// The pool primary is drawn from [providers] (preferring the configured
  /// default when it is referenced), not an unconditional `config.agent.provider`
  /// start — so a logged-out default provider a run never references is never
  /// started. Task runners are provisioned for every entry in [providers].
  /// Requires [wirePreHarness] to have run.
  Future<void> startHarnesses(Set<String> providers) async {
    final ctx = _preludeCtx;
    final taskHandles = _taskHandles;
    if (ctx == null || taskHandles == null) {
      throw StateError('startHarnesses called before wirePreHarness');
    }
    final wiredCtx = await _wireHarness(ctx, taskHandles, providers);
    await _wireWorkflowService(wiredCtx, taskHandles);
    _workflowServiceWired = true;
    _harnessStarted = true;
    await ensureTaskRunnersForProviders(providers);
  }

  Future<void> wireLifecycleOnly() async {
    final ctx = _preludeCtx;
    final taskHandles = _taskHandles;
    if (ctx == null || taskHandles == null) {
      throw StateError('wireLifecycleOnly called before wirePreHarness');
    }
    final workflowRoleDefaults = _buildWorkflowRoleDefaults();
    workflowService = WorkflowService.lifecycleOnly(
      repository: taskHandles.workflowRunRepository,
      taskService: taskService,
      messageService: messageService,
      eventBus: eventBus,
      kvService: kvService,
      dataDir: dataDir,
      options: WorkflowServiceOptions(
        roleDefaults: workflowRoleDefaults,
        approvalPolicyDefault: config.workflow.approvals,
      ),
    );
    _workflowServiceWired = true;
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
    final resolvedAssets = assetResolver.resolveAssets(const AssetResolutionRequest.noConfiguredAssets());
    final assetSkillsDir = resolvedAssets?.rootSkillsDir;
    final sourceSkillsDir = WorkflowAssetSourceResolver.resolveBuiltInSkillsSourceDir();
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
    _workflowRunRepository = workflowRunRepository;
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
      // Relative to the invocation cwd (the git repo being operated on), not
      // dataDir: worktrees are checkouts of the cwd repo, so they must live
      // beside it even when --config points the data dir elsewhere.
      worktreesDir: p.join(runtimeCwd, '.dartclaw', 'worktrees'),
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

  Future<_CliWorkflowWiringCtx> _wireHarness(
    _CliWorkflowWiringCtx ctx,
    _TaskHandles taskHandles,
    Set<String> providers,
  ) async {
    final wiringLog = Logger('CliWorkflowWiring');
    final primaryProviderId = _selectPrimaryProvider(providers);
    final providerEntry = config.providers[primaryProviderId];
    wiringLog.info(
      'Primary provider "$primaryProviderId": entry=${providerEntry != null ? providerEntry.toString() : "null"}, '
      'options=${providerEntry?.options}',
    );
    final harness = _harnessFactory.create(
      primaryProviderId,
      HarnessFactoryConfig(
        cwd: runtimeCwd,
        executable: _resolveProviderExecutable(config, primaryProviderId),
        harnessConfig: _harnessConfig,
        providerOptions: _providerOptions(config, primaryProviderId),
        environment: _providerEnvironment(config, primaryProviderId, _credentialRegistry),
      ),
    );
    await harness.start();
    behavior = BehaviorFileService(
      workspaceDir: config.workspaceDir,
      maxMemoryBytes: config.memory.maxBytes,
      onboardingExpiryDays: config.onboarding.expiryDays,
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
      providerId: primaryProviderId,
    );
    final maxConcurrentTasks = _standaloneTaskRunnerCapacity(config);
    // Pool starts with only the primary runner; per-provider task runners
    // (including the primary's configured `pool_size`) are filled by
    // [startHarnesses] via [ensureTaskRunnersForProviders] over the explicit
    // provider set, so harness startup is scoped to the run's referenced
    // providers rather than eagerly spawning the configured default's pool.
    pool = HarnessPool(runners: [primaryRunner], maxConcurrentTasks: maxConcurrentTasks);
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
            environment: _providerEnvironment(config, providerId, _credentialRegistry),
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
        defaultProviderId: config.agent.provider,
        stallTimeout: config.governance.turnProgress.stallTimeout,
        stallAction: config.governance.turnProgress.stallAction,
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

  WorkflowSkillPreflightConfig _buildSkillPreflightConfig() {
    return buildWorkflowSkillPreflightConfig(config);
  }

  Future<void> _wireWorkflowService(_CliWorkflowWiringCtx ctx, _TaskHandles taskHandles) async {
    final workflowRoleDefaults = _buildWorkflowRoleDefaults();
    workflowService = WorkflowService(
      repository: taskHandles.workflowRunRepository,
      taskService: taskService,
      messageService: messageService,
      persistencePorts: WorkflowPersistencePorts(
        taskRepository: taskHandles.taskRepository,
        agentExecutionRepository: taskHandles.agentExecutionRepository,
        workflowStepExecutionRepository: taskHandles.workflowStepExecutionRepository,
        executionRepositoryTransactor: taskHandles.executionRepositoryTransactor,
      ),
      gitContext: WorkflowGitContext(
        gitPort: WorkflowGitPortProcess(worktreeManager: worktreeManager),
        projectService: projectService,
        defaultWorkspaceRoot: runtimeCwd,
        hydrateBinding: taskExecutor.hydrateWorkflowSharedWorktreeBinding,
      ),
      options: WorkflowServiceOptions(
        bashStepEnvAllowlist: config.security.bashStep.envAllowlist,
        bashStepExtraStripPatterns: config.security.bashStep.extraStripPatterns,
        roleDefaults: workflowRoleDefaults,
        approvalPolicyDefault: config.workflow.approvals,
        structuredOutputFallbackRecorder: taskHandles.taskEventRecorder.recordStructuredOutputFallbackUsed,
        skillIntrospector:
            skillIntrospector ??
            CliSkillIntrospector(
              environmentForProvider: (providerId) => _providerEnvironment(config, providerId, _credentialRegistry),
            ),
        providerAuthPreflight:
            providerAuthPreflight ??
            CliProviderAuthPreflight(
              credentials: _credentialRegistry,
              environmentForProvider: (providerId) => _providerEnvironment(config, providerId, _credentialRegistry),
            ),
        skillPreflightConfig: _buildSkillPreflightConfig(),
        outputTransformer: workflowStepOutputTransformer,
      ),
      turnAdapter: _buildWorkflowTurnAdapter(this, ctx),
      eventBus: eventBus,
      kvService: kvService,
      dataDir: dataDir,
    );
  }

  Future<void> _wireWorkflowRegistry() async {
    final workflowRoleDefaults = _buildWorkflowRoleDefaults();
    // Source continuity capability from unstarted harness probes (cwd:'/', no
    // spawn) rather than `pool.runners`, so the registry loads in the
    // pre-harness phase before any provider harness starts.
    final continuityProviders = _harnessFactory.probeContinuityProviders();
    registry = WorkflowRegistry(
      parser: WorkflowDefinitionParser(),
      validator: WorkflowDefinitionValidator(roleDefaults: workflowRoleDefaults),
      continuityProviders: continuityProviders,
    );
    await WorkflowMaterializer.materialize(
      dataDir: dataDir,
      assetResolver: assetResolver,
      preferSourceTree: preferSourceTreeAssets,
    );
    await registry.loadFromDirectory(WorkflowMaterializer.builtInDir(dataDir), source: WorkflowSource.materialized);
    await registry.loadFromDirectory(WorkflowMaterializer.customDir(dataDir));
    await registry.loadFromDirectory(p.join(dataDir, 'workflows'));
    for (final projectDef in config.projects.definitions.values) {
      await registry.loadFromDirectory(p.join(configuredProjectDirectory(config, projectDef), 'workflows'));
    }
  }

  /// Tears down all services in reverse construction order.
  ///
  /// Resilient to a pre-harness-only run: when [startHarnesses] never ran (e.g.
  /// an auth preflight aborted the run), the harness-phase teardown is skipped
  /// and only the storage/task layer is closed. A no-op when nothing wired.
  Future<void> dispose() async {
    if (_workflowServiceWired) {
      await workflowService.dispose();
    }
    if (_harnessStarted) {
      await workflowCliRunner.cancelInflight();
      await taskExecutor.stop();
      await _cleanupTrackedWorkflowGit(this);
      await taskCancellationSubscriber.dispose();
    }
    if (!_preHarnessWired) return;
    await taskService.dispose();
    if (_harnessStarted) await pool.dispose();
    await kvService.dispose();
    remotePushService.dispose();
    await projectService.dispose();
    searchDb.close();
    taskDb.close();
  }

  /// Runs the injected [ProviderAuthPreflight] over [providers], raising a
  /// [WorkflowPreflightException] with the provider-named remediation message on
  /// the first unauthenticated provider.
  ///
  /// Mirrors the executor-level `_preflightProviderAuth`, but at the CLI wiring
  /// boundary so a standalone run can gate referenced-provider auth *before*
  /// [startHarnesses] reaches any `harness.start()`. Defaults to the same
  /// [CliProviderAuthPreflight] the workflow service would build. Requires
  /// [wirePreHarness] to have run (uses the credential registry).
  Future<void> preflightProviderAuth(Set<String> providers) async {
    final preflight =
        providerAuthPreflight ??
        CliProviderAuthPreflight(
          credentials: _credentialRegistry,
          environmentForProvider: (providerId) => _providerEnvironment(config, providerId, _credentialRegistry),
        );
    for (final provider in providers) {
      final result = await preflight.evaluate(
        provider: provider,
        executable: _resolveProviderExecutable(config, provider),
        providerOptions: _providerOptions(config, provider),
      );
      if (!result.authenticated) {
        throw WorkflowPreflightException(
          result.remediationMessage ?? 'Workflow provider "$provider" is not authenticated.',
        );
      }
    }
  }

  /// Loads a persisted workflow run by id from the run repository.
  ///
  /// Available after [wirePreHarness] (the repository is part of the task
  /// layer), so resume/retry lifecycle paths can derive a run's referenced
  /// providers and preflight auth before [startHarnesses].
  Future<WorkflowRun?> loadRun(String runId) => _workflowRunRepository.getById(runId);

  /// Picks the pool primary from [providers]: the configured default when it is
  /// referenced, otherwise the lowest-sorted referenced provider (deterministic).
  ///
  /// Falls back to `config.agent.provider` only when [providers] is empty. In
  /// headless workflow mode the primary serves no chat/cron/channel traffic, so
  /// drawing it from the referenced set (rather than an unconditional default
  /// start) keeps a logged-out default provider out of an unrelated run.
  String _selectPrimaryProvider(Set<String> providers) {
    if (providers.isEmpty) return config.agent.provider;
    if (providers.contains(config.agent.provider)) return config.agent.provider;
    final sorted = providers.toList()..sort();
    return sorted.first;
  }

  /// Ensures the pool contains task runners for every [providerIds] entry.
  ///
  /// Standalone workflow execution relies on task runners for agent-backed
  /// steps; without them, queued tasks never start in pool mode.
  Future<void> ensureTaskRunnersForProviders(Set<String> providerIds) async {
    final providerEntries = _effectiveWorkflowProviderEntries(config);
    // Resolve each requested provider to an entry. A workflow step may request a
    // built-in provider (claude/codex) that isn't the configured default; for
    // those, synthesize a default entry from the resolved executable rather than
    // refusing. Genuinely unknown providers still fail closed.
    final resolved = <String, ProviderEntry>{};
    var additionalRunners = 0;
    for (final providerId in providerIds) {
      final providerEntry = providerEntries[providerId] ?? _builtInProviderEntry(providerId);
      if (providerEntry == null) {
        throw StateError('Provider "$providerId" is not configured for standalone workflow execution');
      }
      resolved[providerId] = providerEntry;
      final have = pool.taskRunnerCountForProvider(providerId);
      final want = providerEntry.effectivePoolSize;
      if (want > have) additionalRunners += want - have;
    }
    // Initial pool capacity is sized from config; grow it to fit runners for any
    // additional workflow-required providers before adding them.
    pool.ensureCapacity(pool.taskRunnerCount + additionalRunners);
    for (final entry in resolved.entries) {
      final providerId = entry.key;
      final targetCount = entry.value.effectivePoolSize;
      while (pool.taskRunnerCountForProvider(providerId) < targetCount) {
        pool.addRunner(await _buildTaskRunner(providerId));
      }
      workflowCliRunner.providers.putIfAbsent(
        providerId,
        () => WorkflowCliProviderConfig(
          executable: _resolveProviderExecutable(config, providerId),
          environment: _providerEnvironment(config, providerId, _credentialRegistry),
          options: _providerOptions(config, providerId),
        ),
      );
    }
  }

  /// Synthesizes a default [ProviderEntry] for a built-in provider family
  /// (claude/codex) requested by a workflow but absent from config; returns null
  /// for unknown providers so they fail closed.
  ProviderEntry? _builtInProviderEntry(String providerId) {
    final family = ProviderIdentity.family(providerId);
    if (family != ProviderIdentity.claude && family != ProviderIdentity.codex) {
      return null;
    }
    return ProviderEntry(executable: _resolveProviderExecutable(config, providerId));
  }

  Future<TurnRunner> _buildTaskRunner(String providerId) async {
    final harness = _harnessFactory.create(
      providerId,
      HarnessFactoryConfig(
        cwd: runtimeCwd,
        executable: _resolveProviderExecutable(config, providerId),
        harnessConfig: _harnessConfig,
        providerOptions: _providerOptions(config, providerId),
        environment: _providerEnvironment(config, providerId, _credentialRegistry),
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

Map<String, ProviderEntry> _effectiveWorkflowProviderEntries(DartclawConfig config) {
  final entries = Map<String, ProviderEntry>.from(config.providers.entries);
  entries.putIfAbsent(
    config.agent.provider,
    () => ProviderEntry(executable: _resolveProviderExecutable(config, config.agent.provider)),
  );
  return entries;
}
