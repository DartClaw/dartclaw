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
import 'package:dartclaw_security/dartclaw_security.dart' show SafeProcess;
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
        TaskCancellationSubscriber,
        TaskEventRecorder,
        WorkflowCliProviderConfig,
        WorkflowCliRunner,
        TaskExecutor,
        WorktreeManager,
        WorkflowGitPortProcess,
        TaskService,
        TurnManager,
        TurnRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        SkillRegistryImpl,
        WorkflowDefinitionParser,
        WorkflowDefinitionValidator,
        WorkflowRegistry,
        WorkflowRoleDefault,
        WorkflowRoleDefaults,
        WorkflowSource,
        WorkflowStepOutputTransformer,
        WorkflowService,
        WorkflowGitBootstrapResult,
        WorkflowGitPublishResult,
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
import '../workflow_skill_materializer.dart';
import 'credential_preflight.dart';
import 'project_definition_paths.dart';
import 'workflow_git_support.dart';
import 'workflow_local_path_preflight.dart';

/// Outcome of a standalone-mode pull-request creation hook.
///
/// Mirrors the three-state contract used by the server-backed publish path
/// (`success`, `manual`, `failed`). [CliWorkflowWiring.prCreator] returns one
/// of these after a successful branch push; the value is threaded through
/// `WorkflowGitPublishResult.prUrl` into the workflow context as
/// `publish.pr_url`.
class CliWorkflowPrResult {
  final String status;
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
  final String? skillsHomeDir;
  final Map<String, String> environment;
  final HarnessFactory _harnessFactory;
  final SearchDbFactory _searchDbFactory;
  final TaskDbFactory _taskDbFactory;
  final AssetResolver assetResolver;
  final WorkflowStepOutputTransformer? workflowStepOutputTransformer;

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

  late final CredentialRegistry _credentialRegistry;
  late final HarnessConfig _harnessConfig;

  CliWorkflowWiring({
    required this.config,
    required this.dataDir,
    this.skillsHomeDir,
    Map<String, String>? environment,
    HarnessFactory? harnessFactory,
    SearchDbFactory? searchDbFactory,
    TaskDbFactory? taskDbFactory,
    AssetResolver? assetResolver,
    this.workflowStepOutputTransformer,
    this.prCreator,
  }) : environment = environment ?? Platform.environment,
       _harnessFactory = harnessFactory ?? HarnessFactory(),
       _searchDbFactory = searchDbFactory ?? openSearchDb,
       _taskDbFactory = taskDbFactory ?? openTaskDb,
       assetResolver = assetResolver ?? AssetResolver();

  /// Constructs all services needed for headless workflow execution.
  ///
  /// Does not start an HTTP server, initialize templates, connect channels,
  /// or wire scheduling. Call [dispose] when done.
  Future<void> wire() async {
    final wiringLog = Logger('CliWorkflowWiring');
    final preflight = CredentialPreflight.validate(config, environment);
    for (final warning in preflight.warnings) {
      wiringLog.warning(warning);
    }
    if (preflight.hasHardErrors) {
      throw CredentialPreflightException(preflight.hardErrors);
    }

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

    // Skill registry — discovered before the workflow service so the
    // executor can honor skill-declared default_prompt/default_outputs.
    skillRegistry = SkillRegistryImpl();
    skillRegistry.discover(
      projectDirs: projectDirs,
      workspaceDir: config.workspaceDir,
      dataDir: dataDir,
      builtInSkillsDir: builtInSkillsSourceDir,
    );

    // Storage layer
    searchDb = _searchDbFactory(config.searchDbPath);
    taskDb = _taskDbFactory(config.tasksDbPath);
    kvService = KvService(filePath: config.kvPath);
    sessionService = SessionService(baseDir: config.sessionsDir, eventBus: eventBus);
    messageService = MessageService(baseDir: config.sessionsDir);

    await sessionService.getOrCreateMain();

    // Task layer
    final agentExecutionRepository = SqliteAgentExecutionRepository(taskDb, eventBus: eventBus);
    final workflowStepExecutionRepository = SqliteWorkflowStepExecutionRepository(taskDb);
    final executionRepositoryTransactor = SqliteExecutionRepositoryTransactor(taskDb);
    final taskRepository = SqliteTaskRepository(taskDb);
    final workflowRunRepository = SqliteWorkflowRunRepository(taskDb);
    final taskEventRecorder = TaskEventRecorder(eventService: TaskEventService(taskDb), eventBus: eventBus);
    final taskServiceInst = TaskService(
      taskRepository,
      agentExecutionRepository: agentExecutionRepository,
      executionTransactor: executionRepositoryTransactor,
      eventBus: eventBus,
      eventRecorder: taskEventRecorder,
    );
    taskService = taskServiceInst;
    projectService = ProjectServiceImpl(
      dataDir: dataDir,
      projectConfig: config.projects,
      credentials: config.credentials,
      eventBus: eventBus,
    );
    await projectService.initialize();
    worktreeManager = WorktreeManager(
      dataDir: dataDir,
      baseRef: config.tasks.worktreeBaseRef,
      staleTimeoutHours: config.tasks.worktreeStaleTimeoutHours,
      worktreesDir: p.join(config.workspaceDir, '.dartclaw', 'worktrees'),
      taskLookup: taskServiceInst.get,
      projectLookup: projectService.get,
    );
    await worktreeManager.detectStaleWorktrees();

    // Harness: minimal config — no MCP server, no container, no guards.
    final defaultProviderId = config.agent.provider;
    final providerEntry = config.providers[defaultProviderId];
    wiringLog.info(
      'Provider "$defaultProviderId": entry=${providerEntry != null ? providerEntry.toString() : "null"}, '
      'options=${providerEntry?.options}',
    );
    _credentialRegistry = CredentialRegistry(credentials: config.credentials, env: environment);
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
      diffGenerator: DiffGenerator(projectDir: Directory.current.path),
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
      tasks: taskService,
      sessions: sessionService,
      messages: messageService,
      turns: turns,
      artifactCollector: artifactCollector,
      worktreeManager: worktreeManager,
      workflowStepExecutionRepository: workflowStepExecutionRepository,
      workflowRunRepository: workflowRunRepository,
      kvService: kvService,
      eventBus: eventBus,
      eventRecorder: taskEventRecorder,
      dataDir: dataDir,
      workspaceDir: config.workspaceDir,
      maxMemoryBytes: config.memory.maxBytes,
      compactInstructions: config.context.compactInstructions,
      identifierPreservation: config.context.identifierPreservation,
      identifierInstructions: config.context.identifierInstructions,
      budgetConfig: config.tasks.budget,
      workflowCliRunner: workflowCliRunner,
      projectService: projectService,
    );
    taskExecutor.start();

    // Workflow layer
    workflowService = WorkflowService(
      repository: workflowRunRepository,
      taskService: taskService,
      messageService: messageService,
      bashStepEnvAllowlist: config.security.bashStep.envAllowlist,
      bashStepExtraStripPatterns: config.security.bashStep.extraStripPatterns,
      taskRepository: taskRepository,
      agentExecutionRepository: agentExecutionRepository,
      workflowStepExecutionRepository: workflowStepExecutionRepository,
      executionRepositoryTransactor: executionRepositoryTransactor,
      projectService: projectService,
      workflowGitPort: WorkflowGitPortProcess(worktreeManager: worktreeManager),
      roleDefaults: WorkflowRoleDefaults(
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
      ),
      structuredOutputFallbackRecorder: taskEventRecorder.recordStructuredOutputFallbackUsed,
      skillRegistry: skillRegistry,
      hydrateWorkflowWorktreeBinding: taskExecutor.hydrateWorkflowSharedWorktreeBinding,
      turnAdapter: WorkflowTurnAdapter(
        workflowWorkspaceDir: config.workflow.workspaceDir ?? p.join(dataDir, 'workflow-workspace'),
        resolveStartContext: (definition, variables, {projectId, allowDirtyLocalPath = false}) async {
          final declaresProject = definition.variables.containsKey('PROJECT');
          final declaresBranch = definition.variables.containsKey('BRANCH');
          final resolvedProjectId = (projectId ?? variables['PROJECT'])?.trim();
          final workflowProjectDir = await _resolveWorkflowProjectDir(resolvedProjectId);
          final resolvedProject = resolvedProjectId == null || resolvedProjectId.isEmpty
              ? null
              : await projectService.get(resolvedProjectId);
          String? resolvedBranch;
          if (declaresBranch) {
            final requested = variables['BRANCH']?.trim();
            if (requested != null && requested.isNotEmpty) {
              final exists = await _localRefExists(workflowProjectDir, requested);
              if (!exists) {
                throw ArgumentError('Ref "$requested" not found in project repository');
              }
              resolvedBranch = requested;
            } else if (resolvedProject != null) {
              resolvedBranch = await projectService.resolveWorkflowBaseRef(resolvedProject);
            } else {
              resolvedBranch = await _resolveSymbolicHeadBranch(workflowProjectDir) ?? 'main';
            }
          }
          if (resolvedProject != null) {
            await ensureWorkflowProjectReady(
              project: resolvedProject,
              publishEnabled: definition.gitStrategy?.publish?.enabled == true,
              allowDirty: allowDirtyLocalPath,
              hasExplicitBranch: (variables['BRANCH']?.trim().isNotEmpty ?? false),
            );
          }
          return WorkflowStartResolution(
            projectId: declaresProject ? resolvedProjectId : null,
            branch: declaresBranch ? resolvedBranch : null,
          );
        },
        bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async {
          final resolvedProject = await projectService.get(projectId);
          final effectiveBaseRef = resolvedProject != null
              ? await projectService.resolveWorkflowBaseRef(resolvedProject, requestedBranch: baseRef)
              : ((baseRef.trim().isNotEmpty)
                    ? baseRef
                    : (await _resolveSymbolicHeadBranch(await _resolveWorkflowProjectDir(projectId)) ?? 'main'));
          final integrationBranch = perMapItem
              ? 'dartclaw/workflow/${runId.replaceAll('-', '')}/integration'
              : 'dartclaw/workflow/${runId.replaceAll('-', '')}';
          await _ensureLocalBranch(
            projectDir: await _resolveWorkflowProjectDir(projectId),
            branch: integrationBranch,
            baseRef: effectiveBaseRef,
          );
          return WorkflowGitBootstrapResult(integrationBranch: integrationBranch);
        },
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async {
              return promoteWorkflowBranchLocally(
                projectDir: await _resolveWorkflowProjectDir(projectId),
                runId: runId,
                branch: branch,
                integrationBranch: integrationBranch,
                strategy: strategy,
                storyId: storyId,
              );
            },
        publishWorkflowBranch: ({required runId, required projectId, required branch}) async {
          final pushResult = await publishWorkflowBranchLocally(
            projectDir: await _resolveWorkflowProjectDir(projectId),
            branch: branch,
          );
          if (pushResult.status != 'success') {
            return pushResult;
          }

          // Optional PR-creation hook. Production CLI leaves prCreator null, so
          // publish.pr_url stays empty and the operator creates the PR manually.
          // When a hook is injected (tests / alternative entry points), its
          // result replaces the push-only outcome so the URL flows through
          // WorkflowGitPublishResult.prUrl into `publish.pr_url` context.
          var result = pushResult;
          if (prCreator != null) {
            final prResult = await prCreator!(runId: runId, projectId: projectId, branch: branch);
            result = WorkflowGitPublishResult(
              status: prResult.status,
              branch: pushResult.branch,
              remote: pushResult.remote,
              prUrl: prResult.prUrl,
              error: prResult.error,
            );
          }

          final workflowTasks = (await taskService.list()).where((task) => task.workflowRunId == runId).toList()
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
          final artifactTaskId = workflowTasks.isEmpty ? null : workflowTasks.last.id;
          if (artifactTaskId != null) {
            final artifactPath = result.prUrl.isNotEmpty ? result.prUrl : branch;
            await taskService.addArtifact(
              id: 'workflow-publish-$runId-${DateTime.now().microsecondsSinceEpoch}',
              taskId: artifactTaskId,
              name: 'Workflow Publish',
              kind: ArtifactKind.pr,
              path: artifactPath,
            );
          }
          return result;
        },
        cleanupWorkflowGit: ({required runId, required projectId, required status, required preserveWorktrees}) async {
          if (preserveWorktrees) return;
          await _cleanupWorkflowGitRun(runId);
        },
        cleanupWorktreeForRetry: ({required projectId, required branch, required preAttemptSha}) async {
          final projectDir = await _resolveWorkflowProjectDir(projectId);
          return cleanupWorktreeForRetry(
            projectDir: projectDir,
            branch: branch,
            preAttemptSha: preAttemptSha,
          );
        },
        captureWorkflowBranchSha: ({required projectId, required branch}) async {
          final projectDir = await _resolveWorkflowProjectDir(projectId);
          return captureWorkflowBranchSha(projectDir: projectDir, branch: branch);
        },
        captureAndCleanWorktreeForRetry: ({required projectId, required branch, preAttemptSha}) async {
          final projectDir = await _resolveWorkflowProjectDir(projectId);
          final result = await captureAndCleanWorktreeForRetry(
            projectDir: projectDir,
            branch: branch,
            preAttemptSha: preAttemptSha,
          );
          return (sha: result.sha, isDirty: result.isDirty, cleanupError: result.cleanupError);
        },
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
      outputTransformer: workflowStepOutputTransformer,
    );

    // Registry — materialize built-in workflows, then discover custom ones.
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
    await WorkflowMaterializer.materialize(dataDir: dataDir, assetResolver: assetResolver);
    await registry.loadFromDirectory(WorkflowMaterializer.definitionsDir(dataDir), source: WorkflowSource.materialized);
    for (final projectDef in config.projects.definitions.values) {
      await registry.loadFromDirectory(p.join(configuredProjectDirectory(config, projectDef), 'workflows'));
    }
  }

  /// Tears down all services in reverse construction order.
  Future<void> dispose() async {
    await workflowService.dispose();
    await taskExecutor.stop();
    await _cleanupTrackedWorkflowGit();
    await taskCancellationSubscriber.dispose();
    await taskService.dispose();
    await pool.dispose();
    await kvService.dispose();
    await projectService.dispose();
    searchDb.close();
    taskDb.close();
  }

  Future<String> _resolveWorkflowProjectDir(String? projectId) async {
    final trimmed = projectId?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == '_local') {
      return Directory.current.path;
    }
    final project = await projectService.get(trimmed);
    if (project == null) {
      throw StateError('Project "$trimmed" not found');
    }
    return project.localPath;
  }

  Future<void> _cleanupWorkflowGitRun(String runId) async {
    final runTasks = (await taskService.list()).where((task) => task.workflowRunId == runId).toList();
    final cleanupPlan = _buildWorkflowCleanupPlan(runId, runTasks);
    await _runWorkflowGitCleanupPlan(cleanupPlan);
  }

  Future<void> _cleanupTrackedWorkflowGit() async {
    final workflowTasks = (await taskService.list()).where((task) => task.workflowRunId != null).toList();
    if (workflowTasks.isEmpty) return;

    final worktreePaths = <String>{};
    final branches = <String>{};
    final runIds = workflowTasks.map((task) => task.workflowRunId).whereType<String>().toSet();
    for (final runId in runIds) {
      final cleanupPlan = _buildWorkflowCleanupPlan(
        runId,
        workflowTasks.where((task) => task.workflowRunId == runId).toList(),
      );
      worktreePaths.addAll(cleanupPlan.worktreePaths);
      branches.addAll(cleanupPlan.branches);
    }

    await _runWorkflowGitCleanupPlan(_WorkflowGitCleanupPlan(worktreePaths: worktreePaths, branches: branches));
  }

  Future<void> _runWorkflowGitCleanupPlan(_WorkflowGitCleanupPlan cleanupPlan) async {
    for (final worktreePath in cleanupPlan.worktreePaths) {
      await _workflowGit(['worktree', 'remove', '--force', worktreePath], workingDirectory: Directory.current.path);
    }
    for (final branch in cleanupPlan.branches) {
      if (branch.startsWith('origin/')) continue;
      await _workflowGit(['branch', '--delete', '--force', branch], workingDirectory: Directory.current.path);
    }
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
  return configuredProjectDirectories(config);
}

Future<String?> _resolveSymbolicHeadBranch(String workingDirectory) async {
  try {
    final result = await _workflowGit([
      'symbolic-ref',
      '--quiet',
      '--short',
      'HEAD',
    ], workingDirectory: workingDirectory);
    if (result.exitCode != 0) return null;
    final stdout = (result.stdout as String).trim();
    return stdout.isEmpty ? null : stdout;
  } catch (_) {
    return null;
  }
}

Future<bool> _localRefExists(String workingDirectory, String ref) async {
  final candidates = <String>{ref};
  if (!ref.startsWith('origin/') && !ref.startsWith('refs/')) {
    candidates.add('origin/$ref');
  }
  for (final candidate in candidates) {
    try {
      final result = await _workflowGit([
        'rev-parse',
        '--verify',
        '--quiet',
        candidate,
      ], workingDirectory: workingDirectory);
      if (result.exitCode == 0) return true;
    } catch (_) {}
  }
  return false;
}

class _WorkflowGitCleanupPlan {
  final Set<String> worktreePaths;
  final Set<String> branches;

  const _WorkflowGitCleanupPlan({required this.worktreePaths, required this.branches});
}

Future<ProcessResult> _workflowGit(List<String> args, {required String workingDirectory}) {
  return SafeProcess.git(
    args,
    plan: const GitCredentialPlan.none(),
    workingDirectory: workingDirectory,
    noSystemConfig: true,
  );
}

_WorkflowGitCleanupPlan _buildWorkflowCleanupPlan(String runId, List<Task> runTasks) {
  final runToken = runId.replaceAll('-', '');
  final worktreePaths = <String>{};
  final branches = <String>{'dartclaw/workflow/$runToken', 'dartclaw/workflow/$runToken/integration'};

  for (final task in runTasks) {
    final worktree = task.worktreeJson;
    if (worktree == null) continue;
    final path = worktree['path'];
    final branch = worktree['branch'];
    if (path is String && path.trim().isNotEmpty) {
      worktreePaths.add(path.trim());
    }
    if (branch is String && branch.trim().isNotEmpty) {
      branches.add(branch.trim());
    }
  }

  return _WorkflowGitCleanupPlan(worktreePaths: worktreePaths, branches: branches);
}

Future<void> _ensureLocalBranch({required String projectDir, required String branch, required String baseRef}) async {
  final existing = await _workflowGit(['rev-parse', '--verify', branch], workingDirectory: projectDir);
  if (existing.exitCode == 0) {
    return;
  }
  final create = await _workflowGit(['branch', branch, baseRef], workingDirectory: projectDir);
  if (create.exitCode != 0) {
    final stderr = (create.stderr as String).trim();
    throw StateError('Failed to create workflow branch "$branch" from "$baseRef": $stderr');
  }
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
