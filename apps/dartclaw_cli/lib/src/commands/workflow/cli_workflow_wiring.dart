import 'dart:async' show FutureOr;
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart'
    show CredentialRegistry, DartclawConfig, ProviderEntry, ProviderIdentity;
import 'package:dartclaw_core/dartclaw_core.dart'
    show ArtifactKind, EventBus, HarnessFactory, KvService, MessageService, ProviderExecutionInventory, SessionService;
import 'package:dartclaw_security/dartclaw_security.dart' show MessageRedactor, SafeProcess, normalizeGitRefOperand;
import 'package:dartclaw_server/dartclaw_server.dart'
    show
        AssetResolver,
        AssetResolutionRequest,
        ArtifactCollector,
        BehaviorFileService,
        DiffGenerator,
        ExecutionCoordinator,
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
        WorkflowCliProcessStarter;
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
        WorkflowWorktreeBinding,
        WorkflowServiceOptions,
        WorkflowSkillPreflightConfig,
        WorkflowStartResolution,
        WorkflowTurnAdapter,
        WorkflowTurnOutcome,
        resolveIntegrationBranchName;
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
import 'workflow_skill_bootstrap.dart';
import 'credential_preflight.dart';
import 'project_definition_paths.dart';
import 'workflow_config_support.dart';
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
  final bool runWorkflowSkillsBootstrap;
  final ProcessRunner? skillProvisionerProcessRunner;
  final SkillIntrospector? skillIntrospector;
  final ProviderAuthPreflight? providerAuthPreflight;
  final RemotePushService? remotePushServiceOverride;
  final WorkflowCliProcessStarter? workflowCliProcessStarter;

  /// When true, the live source tree wins over embedded built-ins for skill
  /// provisioning and workflow YAML materialization. The
  /// maintainer profile (`dev/tools/dartclaw-workflows/run.sh`) sets this so
  /// edits to checked-out skills and YAMLs take effect immediately.
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
  late final ExecutionCoordinator executions;
  late final TaskExecutor taskExecutor;
  late final TaskCancellationSubscriber taskCancellationSubscriber;
  late final WorkflowRegistry registry;
  late final WorkflowService workflowService;
  late final WorkflowCliRunner workflowCliRunner;
  late final ProjectServiceImpl projectService;
  late final RemotePushService remotePushService;

  late final CredentialRegistry _credentialRegistry;
  late final SqliteWorkflowRunRepository _workflowRunRepository;

  // Two-phase wiring state. Base services are ready before provider auth is
  // checked; execution services are configured only for the providers the
  // workflow actually references.
  _CliWorkflowWiringCtx? _preludeCtx;
  _TaskHandles? _taskHandles;
  bool _baseServicesWired = false;
  bool _executionsWired = false;
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
    this.runWorkflowSkillsBootstrap = true,
    this.skillProvisionerProcessRunner,
    this.skillIntrospector,
    this.providerAuthPreflight,
    this.remotePushServiceOverride,
    this.workflowCliProcessStarter,
    this.prCreator,
    this.preferSourceTreeAssets = false,
  }) : runtimeCwd = runtimeCwd ?? Directory.current.path,
       environment = environment ?? Platform.environment,
       _harnessFactory = harnessFactory ?? HarnessFactory(),
       _searchDbFactory = searchDbFactory ?? openSearchDb,
       _taskDbFactory = taskDbFactory ?? openTaskDb,
       assetResolver = assetResolver ?? const AssetResolver();

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

  /// Constructs all services needed for headless workflow execution and
  /// configures capacity for the default provider.
  ///
  /// Does not start an HTTP server, initialize templates, connect channels,
  /// or wire scheduling. Call [dispose] when done.
  ///
  /// Convenience facade over the two-phase API ([wireBaseServices] +
  /// [wireExecutionServices]). Standalone run/resume paths call the two phases
  /// directly so they can run [preflightProviderAuth] in between.
  Future<void> wire() async {
    await wireBaseServices();
    await wireExecutionServices({config.agent.provider});
  }

  /// Completes registry/materialization, storage, and the task layer without
  /// configuring provider execution capacity.
  ///
  /// [registry] is usable after this returns; [wireExecutionServices] must run before
  /// [workflowService]/[executions]/[taskExecutor] are touched. Idempotent guard:
  /// safe to follow with [dispose] even if [wireExecutionServices] never runs.
  Future<void> wireBaseServices() async {
    final ctx = await _wirePrelude();
    await _wireStorage();
    final taskHandles = await _wireTaskLayer(ctx);
    await _wireWorkflowRegistry();
    _preludeCtx = ctx;
    _taskHandles = taskHandles;
    _baseServicesWired = true;
  }

  /// Configures execution capacity for [providers] and builds the dependent services.
  ///
  /// Workflow one-shots acquire capacity-only leases and never create a reusable harness.
  /// Requires [wireBaseServices] to have run.
  Future<void> wireExecutionServices(Set<String> providers) async {
    final ctx = _preludeCtx;
    final taskHandles = _taskHandles;
    if (ctx == null || taskHandles == null) {
      throw StateError('wireExecutionServices called before wireBaseServices');
    }
    final canonicalProviders = providers.map(ProviderIdentity.normalize).toSet();
    if (canonicalProviders.isEmpty) {
      await _wireWorkflowService(ctx, taskHandles);
      _workflowServiceWired = true;
      return;
    }
    final wiredCtx = await _wireExecutions(ctx, taskHandles, canonicalProviders);
    await _wireWorkflowService(
      wiredCtx,
      taskHandles,
      hydrateBinding: taskExecutor.hydrateWorkflowSharedWorktreeBinding,
    );
    _workflowServiceWired = true;
    _executionsWired = true;
  }

  Future<void> wireLifecycleOnly() async {
    final ctx = _preludeCtx;
    final taskHandles = _taskHandles;
    if (ctx == null || taskHandles == null) {
      throw StateError('wireLifecycleOnly called before wireBaseServices');
    }
    final workflowRoleDefaults = workflowRoleDefaultsFromConfig(config);
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
    final assetSkillsDir = resolvedAssets.skillsDir;
    final sourceSkillsDir = WorkflowAssetSourceResolver.resolveBuiltInSkillsSourceDir();
    final builtInSkillsSourceDir = preferSourceTreeAssets
        ? (sourceSkillsDir ?? assetSkillsDir)
        : (assetSkillsDir ?? sourceSkillsDir);
    if (runWorkflowSkillsBootstrap) {
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

  Future<_CliWorkflowWiringCtx> _wireExecutions(
    _CliWorkflowWiringCtx ctx,
    _TaskHandles taskHandles,
    Set<String> providers,
  ) async {
    final providerEntries = _effectiveWorkflowProviderEntries(config);
    final capacities = <String, int>{};
    for (final providerId in providers) {
      final providerEntry = providerEntries[providerId];
      if (providerEntry == null) {
        throw StateError('Provider "$providerId" is not configured for standalone workflow execution');
      }
      capacities[providerId] = providerEntry.effectivePoolSize;
    }
    executions = ExecutionCoordinator(
      providerCapacities: capacities,
      createWorker: (_) => throw StateError('Standalone workflows use capacity-only execution'),
    );
    final turns = TurnManager.fromCoordinator(coordinator: executions, sessions: sessionService);
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
        for (final providerId in providerEntries.keys)
          providerId: WorkflowCliProviderConfig(
            executable: _resolveProviderExecutable(config, providerId),
            environment: _providerEnvironment(config, providerId, _credentialRegistry),
            options: _providerOptions(config, providerId),
          ),
      },
      executionInventory: ProviderExecutionInventory.of(
        providerIds: providerEntries.keys,
        acpProviderIds: config.harness.acp.agents.keys.toSet(),
      ),
      diagnosticRedactor: MessageRedactor(extraPatterns: config.logging.redactPatterns),
      eventBus: eventBus,
      processStarter: workflowCliProcessStarter,
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
        defaultStepTimeout: config.governance.turnProgress.maxDuration,
      ),
      dataDir: dataDir,
      workspaceRoot: config.workspaceDir,
    );
    taskExecutor.start();
    return ctx.withTurns(turns);
  }

  WorkflowSkillPreflightConfig _buildSkillPreflightConfig() {
    return buildWorkflowSkillPreflightConfig(config);
  }

  Future<void> _wireWorkflowService(
    _CliWorkflowWiringCtx ctx,
    _TaskHandles taskHandles, {
    FutureOr<void> Function(WorkflowWorktreeBinding binding)? hydrateBinding,
  }) async {
    final workflowRoleDefaults = workflowRoleDefaultsFromConfig(config);
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
        hydrateBinding: hydrateBinding,
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
    final workflowRoleDefaults = workflowRoleDefaultsFromConfig(config);
    // Source continuity capability from unstarted harness probes (cwd:'/', no
    // spawn), so the registry loads before execution capacity is configured.
    final continuityProviders = _harnessFactory.probeContinuityProviders();
    registry = WorkflowRegistry(
      parser: WorkflowDefinitionParser(),
      validator: WorkflowDefinitionValidator(roleDefaults: workflowRoleDefaults),
      continuityProviders: continuityProviders,
    );
    await WorkflowMaterializer.materialize(dataDir: dataDir, preferSourceTree: preferSourceTreeAssets);
    await registry.loadFromDirectory(WorkflowMaterializer.builtInDir(dataDir), source: WorkflowSource.materialized);
    await registry.loadFromDirectory(WorkflowMaterializer.customDir(dataDir));
    await registry.loadFromDeprecatedLegacyDirectory(
      p.join(dataDir, 'workflows'),
      replacementDirectory: WorkflowMaterializer.customDir(dataDir),
    );
    for (final projectDef in config.projects.definitions.values) {
      await registry.loadFromDirectory(p.join(configuredProjectDirectory(config, projectDef), 'workflows'));
    }
  }

  /// Tears down all services in reverse construction order.
  ///
  /// Resilient to a base-services-only run: when [wireExecutionServices] never ran (e.g.
  /// an auth preflight aborted the run), execution teardown is skipped
  /// and only the storage/task layer is closed. A no-op when nothing wired.
  Future<void> dispose() async {
    if (_workflowServiceWired) {
      await workflowService.dispose();
    }
    if (_executionsWired) {
      await workflowCliRunner.cancelInflight(cancelFutureProcesses: true);
      await taskExecutor.stop();
      await _cleanupTrackedWorkflowGit(this);
      await taskCancellationSubscriber.dispose();
    }
    if (!_baseServicesWired) return;
    await taskService.dispose();
    if (_executionsWired) await executions.dispose();
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
  /// boundary so a standalone run can gate referenced-provider auth before
  /// configuring execution. Defaults to the same
  /// [CliProviderAuthPreflight] the workflow service would build. Requires
  /// [wireBaseServices] to have run (uses the credential registry).
  Future<void> preflightProviderAuth(Set<String> providers) async {
    final preflight =
        providerAuthPreflight ??
        CliProviderAuthPreflight(
          credentials: _credentialRegistry,
          environmentForProvider: (providerId) => _providerEnvironment(config, providerId, _credentialRegistry),
        );
    for (final provider in providers.map(ProviderIdentity.normalize).toSet()) {
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
  /// Available after [wireBaseServices] (the repository is part of the task
  /// layer), so resume/retry lifecycle paths can derive a run's referenced
  /// providers and preflight auth before [wireExecutionServices].
  Future<WorkflowRun?> loadRun(String runId) => _workflowRunRepository.getById(runId);
}

Map<String, ProviderEntry> _effectiveWorkflowProviderEntries(DartclawConfig config) {
  final entries = ProviderIdentity.normalizeKeys(config.providers.entries);
  final defaultProviderId = ProviderIdentity.normalize(config.agent.provider);
  entries.putIfAbsent(
    defaultProviderId,
    () => ProviderEntry(executable: _resolveProviderExecutable(config, defaultProviderId)),
  );
  return entries;
}
