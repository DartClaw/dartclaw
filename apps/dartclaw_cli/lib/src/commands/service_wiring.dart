import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' as config_tools;
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart' show ensureDartclawGoogleChatRegistered;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ProcessRunner,
        SkillRegistryImpl,
        WorkflowDefinitionParser,
        WorkflowDefinitionValidator,
        WorkflowRegistry,
        WorkflowRoleDefault,
        WorkflowRoleDefaults,
        WorkflowSource,
        WorkflowService,
        WorkflowGitIntegrationBranchResult,
        WorkflowGitPromotionConflict,
        WorkflowGitPromotionError,
        WorkflowGitPromotionSuccess,
        WorkflowGitPublishResult,
        WorkflowPublishStatus,
        WorkflowStartResolution,
        WorkflowTurnAdapter,
        WorkflowTurnOutcome;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'serve_command.dart';
import 'wiring/channel_wiring.dart';
import 'wiring/harness_wiring.dart';
import 'workflow_materializer.dart';
import 'workflow/andthen_skill_bootstrap.dart';
import 'workflow/project_definition_paths.dart';
import 'workflow/workflow_git_support.dart';
import 'workflow/workflow_local_path_preflight.dart';
import 'workflow_skill_source_resolver.dart';
import 'wiring/scheduling_wiring.dart';
import 'wiring/security_wiring.dart';
import 'wiring/storage_wiring.dart';
import 'wiring/task_wiring.dart';
import 'wiring/project_wiring.dart';

/// Immutable holder for services produced by [ServiceWiring.wire].
///
/// Contains the references needed by the serve command and integration tests
/// for HTTP server startup, startup banner, channel connection, graceful
/// shutdown, and workflow-skill bootstrap verification.
class WiringResult {
  final DartclawServer server;
  final Database searchDb;
  final AgentExecutionRepository agentExecutionRepository;
  final TaskService taskService;
  final AgentHarness harness;
  final HarnessPool pool;
  final HeartbeatScheduler? heartbeat;
  final ScheduleService? scheduleService;
  final KvService kvService;
  final SessionResetService resetService;
  final SelfImprovementService selfImprovement;
  final QmdManager? qmdManager;
  final ChannelManager? channelManager;
  final bool authEnabled;
  final TokenService? tokenService;
  final EventBus eventBus;
  final Map<String, ContainerManager> containerManagers;
  final Future<void> Function() shutdownExtras;
  final ProjectService projectService;
  final ConfigNotifier configNotifier;

  /// Skill registry populated by [ServiceWiring.wire]. Exposed so tests can
  /// assert that workflow skills resolve through the production discovery path.
  final SkillRegistryImpl skillRegistry;

  /// Workflow registry populated by [ServiceWiring.wire]. Exposed so tests can
  /// assert that the shipped built-in workflow definitions (`plan-and-implement`,
  /// `spec-and-implement`, `code-review`) register against the runtime skill
  /// registry.
  final WorkflowRegistry workflowRegistry;

  const WiringResult({
    required this.server,
    required this.searchDb,
    required this.agentExecutionRepository,
    required this.taskService,
    required this.harness,
    required this.pool,
    required this.heartbeat,
    required this.scheduleService,
    required this.kvService,
    required this.resetService,
    required this.selfImprovement,
    required this.qmdManager,
    required this.channelManager,
    required this.authEnabled,
    required this.tokenService,
    required this.eventBus,
    required this.containerManagers,
    required this.shutdownExtras,
    required this.projectService,
    required this.configNotifier,
    required this.skillRegistry,
    required this.workflowRegistry,
  });
}

/// Thin coordinator that composes domain-specific wiring modules in dependency
/// order and returns a [WiringResult] for [ServeCommand].
///
/// Domain modules ([StorageWiring], [SecurityWiring], [HarnessWiring],
/// [ChannelWiring], [TaskWiring], [SchedulingWiring]) own service construction.
/// This class threads cross-domain dependencies and performs the final server
/// build and MCP tool registration.
class ServiceWiring {
  final DartclawConfig config;
  final String dataDir;
  final int port;
  final HarnessFactory harnessFactory;
  final ServerFactory serverFactory;
  final SearchDbFactory searchDbFactory;
  final TaskDbFactory taskDbFactory;
  final WriteLine stderrLine;
  final ExitFn exitFn;
  final String resolvedConfigPath;
  final LogService logService;
  final MessageRedactor messageRedactor;
  final AssetResolver assetResolver;

  /// When `false`, [wire] skips the [SkillProvisioner] bootstrap. Production
  /// callers leave the default. Tests opt out when they don't pre-stage a fake
  /// AndThen source cache and don't want network/clone cost.
  final bool runAndthenSkillsBootstrap;

  /// Environment passed to [SkillProvisioner] when [runAndthenSkillsBootstrap]
  /// is true. Defaults to [Platform.environment] in production. Tests inject a
  /// controlled `HOME` here so user-tier installs cannot leak into the
  /// developer's real `~/.agents` or `~/.claude` trees.
  final Map<String, String>? skillProvisionerEnvironment;

  /// Child-process seam passed to [SkillProvisioner] for deterministic tests.
  final ProcessRunner? skillProvisionerProcessRunner;

  static final _log = Logger('ServiceWiring');

  ServiceWiring({
    required this.config,
    required this.dataDir,
    required this.port,
    required this.harnessFactory,
    required this.serverFactory,
    required this.searchDbFactory,
    required this.taskDbFactory,
    required this.stderrLine,
    required this.exitFn,
    required this.resolvedConfigPath,
    required this.logService,
    required this.messageRedactor,
    AssetResolver? assetResolver,
    this.runAndthenSkillsBootstrap = true,
    this.skillProvisionerEnvironment,
    this.skillProvisionerProcessRunner,
  }) : assetResolver = assetResolver ?? AssetResolver();

  /// Constructs all services, wires them together via [DartclawServerBuilder],
  /// and registers MCP tools on the built server.
  ///
  /// Returns a [WiringResult] containing everything [ServeCommand.run] needs
  /// to start the HTTP server, print the startup banner, and wire shutdown.
  Future<WiringResult> wire() async {
    ensureDartclawGoogleChatRegistered();

    final eventBus = EventBus();
    // Create ConfigNotifier — holds live config, notifies registered services on reload.
    final configNotifier = ConfigNotifier(config);

    // 0. Projects — initialize before other services to allow project-aware wiring.
    final project = ProjectWiring(config: config, dataDir: dataDir, eventBus: eventBus);
    await project.wire();

    final projectDirs = workflowSkillProjectDirs(config, fallbackCwd: Directory.current.path);
    final resolvedAssets = assetResolver.resolve();
    final builtInSkillsSourceDir =
        resolvedAssets?.skillsDir ?? WorkflowSkillSourceResolver.resolveBuiltInSkillsSourceDir();

    // 0.5. AndThen skills bootstrap — clone AndThen, install dartclaw-* skills
    // through native user-tier skill loading, and copy DC-native skills per
    // ADR-025.
    if (runAndthenSkillsBootstrap) {
      await bootstrapAndthenSkills(
        config: config,
        dataDir: dataDir,
        builtInSkillsSourceDir: builtInSkillsSourceDir,
        environment: skillProvisionerEnvironment,
        processRunner: skillProvisionerProcessRunner,
      );
    }

    // Skill registry — discover Agent Skills from native prioritized sources.
    // Built here (before WorkflowService / task executor) so downstream
    // services that need the registry (workflow executor skill defaults,
    // MCP/SSE handlers, etc.) can reference the same instance.
    final userSkillRoots = workflowUserSkillRoots(skillProvisionerEnvironment);
    final skillRegistry = SkillRegistryImpl();
    skillRegistry.discover(
      projectDirs: projectDirs,
      workspaceDir: config.workspaceDir,
      dataDir: dataDir,
      builtInSkillsDir: builtInSkillsSourceDir,
      userClaudeSkillsDir: userSkillRoots.claudeSkillsDir,
      userAgentsSkillsDir: userSkillRoots.agentsSkillsDir,
    );

    // 1. Storage — databases, sessions, messages, memory, KV, QMD.
    final storage = StorageWiring(
      config: config,
      eventBus: eventBus,
      searchDbFactory: searchDbFactory,
      taskDbFactory: taskDbFactory,
      exitFn: exitFn,
    );
    await storage.wire();
    await _dropLegacySessionCostEntries(storage.kvService);

    // Derive agent definitions early — needed by both SecurityWiring (guard
    // chain per-agent policies) and HarnessWiring (MCP initialize payload).
    final agentDefs = config.agent.definitions.isNotEmpty ? config.agent.definitions : [AgentDefinition.searchAgent()];

    // 2. Security — guards, audit, content classifier, container setup.
    final security = SecurityWiring(
      config: config,
      dataDir: dataDir,
      eventBus: eventBus,
      exitFn: exitFn,
      configNotifier: configNotifier,
      messageRedactor: messageRedactor,
    );
    await security.wire(agentDefs: agentDefs);

    // 3. Harness — agent harness pool, turn runners, behavior, context, auth.
    final harness = HarnessWiring(
      config: config,
      dataDir: dataDir,
      port: port,
      harnessFactory: harnessFactory,
      exitFn: exitFn,
      storage: storage,
      security: security,
      messageRedactor: messageRedactor,
      eventBus: eventBus,
      configNotifier: configNotifier,
    );
    // Server ref resolved lazily — closures in harness capture the getter.
    late DartclawServer serverRef;
    // TurnManager resolved lazily — built after channel wiring completes but
    // before any inbound channel messages arrive.
    late TurnManager serverTurns;
    await harness.wire(serverRefGetter: () => serverRef);

    // 4. Tasks (pre-server) — review handler needed by ChannelWiring.
    final task = TaskWiring(
      config: config,
      dataDir: dataDir,
      eventBus: eventBus,
      storage: storage,
      project: project,
      containerManagers: security.containerManagers,
    );
    await task.wirePreServer();

    // 5. Channels — channel manager, WhatsApp, Signal, Google Chat, space events.
    final channel = ChannelWiring(
      config: config,
      dataDir: dataDir,
      port: port,
      eventBus: eventBus,
      storage: storage,
      task: task,
      resolvedConfigPath: resolvedConfigPath,
    );
    await channel.wire(
      serverRefGetter: () => serverRef,
      turnManagerGetter: () => serverTurns,
      sseBroadcast: harness.sseBroadcast,
      messageRedactor: messageRedactor,
      healthService: harness.healthService,
      budgetEnforcer: harness.budgetEnforcer,
    );
    _configureBudgetWarningNotifiers(
      pool: harness.pool,
      sessions: storage.sessions,
      taskService: storage.taskService,
      channelManager: channel.channelManager,
    );
    _configureLoopDetectionNotifiers(
      pool: harness.pool,
      sessions: storage.sessions,
      taskService: storage.taskService,
      channelManager: channel.channelManager,
    );

    Channel? lookupAlertChannel(String channelTypeName) {
      final manager = channel.channelManager;
      if (manager == null) return null;
      for (final candidate in manager.channels) {
        if (candidate.type.name == channelTypeName) {
          return candidate;
        }
      }
      return null;
    }

    final alertRouter = AlertRouter(
      bus: eventBus,
      adapter: AlertDeliveryAdapter(lookupAlertChannel),
      config: config.alerts,
      taskLookup: storage.taskService.get,
    );
    configNotifier.register(alertRouter);

    // 6. Build server — all pre-server deps known, now create the HTTP server.
    final configWriter = config_tools.ConfigWriter(configPath: resolvedConfigPath);

    // Detect and clear restart.pending from previous graceful restart.
    final restartPendingFile = File(p.join(dataDir, 'restart.pending'));
    if (restartPendingFile.existsSync()) {
      try {
        final content = jsonDecode(restartPendingFile.readAsStringSync()) as Map<String, dynamic>;
        final fields = (content['fields'] as List?)?.join(', ') ?? 'unknown';
        stderrLine('Restarted after config change (pending: $fields)');
      } catch (e) {
        _log.fine('Could not parse restart.pending file, using generic message', e);
        stderrLine('Restarted after config change');
      }
      restartPendingFile.deleteSync();
    }

    final providerStatus = ProviderStatusService(
      providers: config.providers,
      registry: CredentialRegistry(credentials: config.credentials, env: Platform.environment),
      defaultProvider: config.agent.provider,
      pool: harness.pool,
    );
    await providerStatus.probe();
    final canvasService = config.canvas.enabled
        ? CanvasService(maxConnections: config.canvas.share.maxConnections)
        : null;
    WorkshopCanvasSubscriber? workshopCanvasSubscriber;
    AdvisorSubscriber? advisorSubscriber;

    final builder = DartclawServerBuilder()
      ..sessions = storage.sessions
      ..messages = storage.messages
      ..traceService = storage.traceService
      ..taskEventService = storage.taskEventService
      ..worker = harness.harness
      ..staticDir = resolvedAssets?.staticDir ?? config.server.staticDir
      ..behavior = harness.behavior
      ..memoryFile = storage.memoryFile
      ..guardChain = security.guardChain
      ..kv = storage.kvService
      ..healthService = harness.healthService
      ..tokenService = harness.tokenService
      ..lockManager = harness.lockManager
      ..resetService = harness.resetService
      ..contextMonitor = harness.contextMonitor
      ..explorationSummarizer = harness.explorationSummarizer
      ..channelManager = channel.channelManager
      ..whatsAppChannel = channel.whatsAppChannel
      ..googleChatWebhookHandler = channel.googleChatWebhookHandler
      ..signalChannel = channel.signalChannel
      ..webhookSecret = channel.webhookSecret
      ..redactor = messageRedactor
      ..gatewayToken = harness.resolvedGatewayToken
      ..selfImprovement = harness.selfImprovement
      ..usageTracker = harness.usageTracker
      ..eventBus = eventBus
      ..canvasService = canvasService
      ..authEnabled = harness.authEnabled
      ..pool = harness.pool
      ..contentGuardDisplay = ContentGuardDisplayParams(
        enabled: config.security.contentGuardEnabled,
        classifier: config.security.contentGuardClassifier,
        model: config.security.contentGuardModel,
        maxBytes: config.security.contentGuardMaxBytes,
        apiKeyConfigured:
            config.security.contentGuardClassifier == 'claude_binary' ||
            (Platform.environment['ANTHROPIC_API_KEY']?.isNotEmpty ?? false),
        failOpen: security.contentGuardFailOpen,
      )
      ..heartbeatDisplay = HeartbeatDisplayParams(
        enabled: config.scheduling.heartbeatEnabled,
        intervalMinutes: config.scheduling.heartbeatIntervalMinutes,
      )
      ..workspaceDisplay = WorkspaceDisplayParams(path: config.workspaceDir)
      ..appDisplay = AppDisplayParams(name: config.server.name, dataDir: dataDir);

    // TurnManager built here — needed by TaskWiring (post-server) and
    // SchedulingWiring. Assigned to the late variable captured by the
    // emergency stop closure in ChannelWiring.
    serverTurns = builder.buildTurns();
    await serverTurns.detectAndCleanOrphanedTurns();
    configNotifier.register(serverTurns);

    // 7. Tasks (post-server) — executor, artifacts, observer — need live turns.
    await task.wirePostServer(turns: serverTurns, pool: harness.pool, onSpawnNeeded: harness.onSpawnNeeded);

    final workflowRoleDefaults = WorkflowRoleDefaults(
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

    // Workflow service — wired after task executor so TaskService is live.
    final workflowService = WorkflowService(
      repository: storage.workflowRunRepository,
      taskService: storage.taskService,
      messageService: storage.messages,
      bashStepEnvAllowlist: config.security.bashStep.envAllowlist,
      bashStepExtraStripPatterns: config.security.bashStep.extraStripPatterns,
      roleDefaults: workflowRoleDefaults,
      workflowGitPort: WorkflowGitPortProcess(
        worktreeManager: task.worktreeManager,
        remotePushService: task.remotePushService,
      ),
      turnAdapter: WorkflowTurnAdapter(
        workflowWorkspaceDir: config.workflow.workspaceDir ?? p.join(dataDir, 'workflow-workspace'),
        resolveStartContext: (definition, variables, {projectId, allowDirtyLocalPath = false}) async {
          final declaresProject = definition.variables.containsKey('PROJECT');
          final declaresBranch = definition.variables.containsKey('BRANCH');
          final projectService = project.projectService;

          var effectiveProjectId = (projectId ?? variables['PROJECT'])?.trim();
          Project resolvedProject;
          if (effectiveProjectId != null && effectiveProjectId.isNotEmpty) {
            final found = await projectService.get(effectiveProjectId);
            if (found == null) {
              throw ArgumentError('Project "$effectiveProjectId" not found');
            }
            resolvedProject = found;
          } else {
            resolvedProject = await projectService.getDefaultProject();
            if (declaresProject) {
              effectiveProjectId = resolvedProject.id;
            }
          }

          String? effectiveBranch;
          if (declaresBranch) {
            final requestedBranch = variables['BRANCH']?.trim();
            if (requestedBranch != null && requestedBranch.isNotEmpty) {
              if (resolvedProject.remoteUrl.isEmpty) {
                final exists = await _localRefExists(resolvedProject.localPath, requestedBranch);
                if (!exists) {
                  throw ArgumentError('Ref "$requestedBranch" not found in project repository');
                }
              }
              effectiveBranch = requestedBranch;
            } else {
              effectiveBranch = await projectService.resolveWorkflowBaseRef(resolvedProject);
            }
          }

          await ensureWorkflowProjectReady(
            project: resolvedProject,
            publishEnabled: definition.gitStrategy?.publish?.enabled == true,
            allowDirty: allowDirtyLocalPath,
            hasExplicitBranch: (variables['BRANCH']?.trim().isNotEmpty ?? false),
          );

          final refToValidate = _workflowFreshnessRefForProject(resolvedProject, effectiveBranch);
          await projectService.ensureFresh(resolvedProject, ref: refToValidate, strict: true);
          return WorkflowStartResolution(
            projectId: declaresProject ? effectiveProjectId : null,
            branch: declaresBranch ? effectiveBranch : null,
          );
        },
        initializeWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async {
          final resolvedProject = await project.projectService.get(projectId);
          if (resolvedProject == null) {
            throw ArgumentError('Project "$projectId" not found');
          }
          final effectiveBaseRef = await project.projectService.resolveWorkflowBaseRef(
            resolvedProject,
            requestedBranch: baseRef,
          );
          final integrationBranch = perMapItem
              ? 'dartclaw/workflow/${runId.replaceAll('-', '')}/integration'
              : 'dartclaw/workflow/${runId.replaceAll('-', '')}';
          await _ensureLocalBranch(
            projectDir: resolvedProject.localPath,
            branch: integrationBranch,
            baseRef: effectiveBaseRef,
            remoteBacked: resolvedProject.remoteUrl.isNotEmpty,
          );
          return WorkflowGitIntegrationBranchResult(integrationBranch: integrationBranch);
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
              final resolvedProject = await project.projectService.get(projectId);
              if (resolvedProject == null) {
                return WorkflowGitPromotionError('Project "$projectId" not found');
              }
              try {
                await commitWorkflowWorktreeChangesIfNeeded(
                  projectDir: resolvedProject.localPath,
                  branch: branch,
                  commitMessage: 'workflow(${storyId ?? runId}): prepare promotion',
                );
              } catch (error) {
                return WorkflowGitPromotionError(error.toString());
              }
              final expectedBaseShaResult = await _workflowGit([
                'rev-parse',
                integrationBranch,
              ], workingDirectory: resolvedProject.localPath);
              if (expectedBaseShaResult.exitCode != 0) {
                return WorkflowGitPromotionError(
                  'Failed to record merge target "$integrationBranch": ${expectedBaseShaResult.stderr}',
                );
              }
              final mergeExecutor = MergeExecutor(
                projectDir: resolvedProject.localPath,
                defaultStrategy: strategy == 'merge' ? MergeStrategy.merge : MergeStrategy.squash,
              );
              final mergeResult = await mergeExecutor.merge(
                branch: branch,
                baseRef: integrationBranch,
                taskId: storyId ?? runId,
                taskTitle: storyId == null ? 'workflow promotion' : 'promote $storyId',
                expectedBaseSha: (expectedBaseShaResult.stdout as String).trim(),
                strategy: strategy == 'merge' ? MergeStrategy.merge : MergeStrategy.squash,
              );
              return switch (mergeResult) {
                MergeSuccess(:final commitSha) => WorkflowGitPromotionSuccess(commitSha: commitSha),
                MergeConflict(:final conflictingFiles, :final details) => WorkflowGitPromotionConflict(
                  conflictingFiles: conflictingFiles,
                  details: details,
                ),
              };
            },
        publishWorkflowBranch: ({required runId, required projectId, required branch}) {
          return publishWorkflowBranchWithProjectAuth(
            runId: runId,
            projectId: projectId,
            branch: branch,
            projectService: project.projectService,
            taskService: storage.taskService,
            remotePushService: task.remotePushService,
            prCreator: task.prCreator,
          );
        },
        cleanupWorkflowGit: ({required runId, required projectId, required status, required preserveWorktrees}) async {
          if (preserveWorktrees) return;
          final resolvedProject = await project.projectService.get(projectId);
          if (resolvedProject == null) return;
          final workflowRun = await storage.workflowRunRepository.getById(runId);
          final restoreRef = workflowRun?.variablesJson['BRANCH']?.trim();
          final runTasks = (await storage.taskService.list())
              .where((candidate) => candidate.workflowRunId == runId)
              .toList();
          final cleanupPlan = buildWorkflowCleanupPlan(runId, runTasks);
          final gitDir = resolvedProject.localPath;
          final cleanupLog = Logger('ServiceWiring');

          if (config.workflow.cleanup.deleteRemoteBranchOnFailure && status == 'failed') {
            final pushedBranches = await pushedWorkflowBranches(storage.taskService, runTasks);
            for (final branch in pushedBranches) {
              final result = await _workflowGit(['push', 'origin', '--delete', branch], workingDirectory: gitDir);
              final detail = result.exitCode == 0 ? 'succeeded' : 'failed: ${(result.stderr as String).trim()}';
              cleanupLog.info('Remote workflow branch cleanup for "$branch" $detail');
            }
          }

          for (final worktreePath in cleanupPlan.worktreePaths) {
            final result = await _workflowGit([
              'worktree',
              'remove',
              '--force',
              worktreePath,
            ], workingDirectory: gitDir);
            if (result.exitCode != 0) {
              cleanupLog.warning(
                'Workflow worktree cleanup for "$worktreePath" failed: ${_processFailureDetail(result)}',
              );
            }
          }
          final localBranches = cleanupPlan.branches.where((branch) => !branch.startsWith('origin/')).toSet();
          if (localBranches.isNotEmpty) {
            final restoreError = await restoreCheckoutBeforeWorkflowBranchDeletion(
              projectDir: gitDir,
              workflowBranches: localBranches,
              restoreRef: restoreRef,
            );
            if (restoreError != null) {
              cleanupLog.warning(restoreError);
            }
          }
          for (final branch in localBranches) {
            final result = await _workflowGit(['branch', '--delete', '--force', branch], workingDirectory: gitDir);
            if (result.exitCode != 0) {
              cleanupLog.warning(
                'Local workflow branch cleanup for "$branch" failed: ${_processFailureDetail(result)}',
              );
            }
          }
        },
        cleanupWorktreeForRetry: ({required projectId, required branch, required preAttemptSha}) async {
          final resolvedProject = await project.projectService.get(projectId);
          if (resolvedProject == null) return 'project "$projectId" not found';
          return cleanupWorktreeForRetry(
            projectDir: resolvedProject.localPath,
            branch: branch,
            preAttemptSha: preAttemptSha,
          );
        },
        captureWorkflowBranchSha: ({required projectId, required branch}) async {
          final resolvedProject = await project.projectService.get(projectId);
          if (resolvedProject == null) return null;
          return captureWorkflowBranchSha(projectDir: resolvedProject.localPath, branch: branch);
        },
        captureAndCleanWorktreeForRetry: ({required projectId, required branch, preAttemptSha}) async {
          final resolvedProject = await project.projectService.get(projectId);
          if (resolvedProject == null) {
            return (sha: null, isDirty: false, cleanupError: 'project "$projectId" not found');
          }
          final result = await captureAndCleanWorktreeForRetry(
            projectDir: resolvedProject.localPath,
            branch: branch,
            preAttemptSha: preAttemptSha,
          );
          return (sha: result.sha, isDirty: result.isDirty, cleanupError: result.cleanupError);
        },
        reserveTurn: serverTurns.reserveTurn,
        reserveTurnWithWorkflowWorkspaceDir: (sessionId, workflowWorkspaceDir) => serverTurns.reserveTurn(
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
        executeTurn: serverTurns.executeTurn,
        waitForOutcome: (sessionId, turnId) async {
          final outcome = await serverTurns.waitForOutcome(sessionId, turnId);
          return WorkflowTurnOutcome(status: outcome.status.name);
        },
        availableRunnerCount: () => serverTurns.availableRunnerCount,
      ),
      structuredOutputFallbackRecorder: storage.taskEventRecorder.recordStructuredOutputFallbackUsed,
      hydrateWorkflowWorktreeBinding: task.taskExecutor.hydrateWorkflowSharedWorktreeBinding,
      skillRegistry: skillRegistry,
      taskRepository: storage.taskRepository,
      agentExecutionRepository: storage.agentExecutionRepository,
      workflowStepExecutionRepository: storage.workflowStepExecutionRepository,
      executionRepositoryTransactor: storage.executionRepositoryTransactor,
      projectService: project.projectService,
      eventBus: eventBus,
      kvService: storage.kvService,
      dataDir: dataDir,
    );
    await workflowService.recoverIncompleteRuns();

    // Workflow registry — materialize built-in workflows, then discover custom ones
    // from workspace and per-project directories.
    final continuityProviders = harness.pool.runners
        .where((r) => r.harness.supportsSessionContinuity)
        .map((r) => r.providerId)
        .toSet();
    await WorkflowMaterializer.materialize(dataDir: dataDir, assetResolver: assetResolver);
    final workflowRegistry = WorkflowRegistry(
      parser: WorkflowDefinitionParser(),
      validator: WorkflowDefinitionValidator(roleDefaults: workflowRoleDefaults),
      continuityProviders: continuityProviders,
    );
    workflowRegistry.skillRegistry = skillRegistry;
    await workflowRegistry.loadFromDirectory(
      WorkflowMaterializer.definitionsDir(dataDir),
      source: WorkflowSource.materialized,
    );
    for (final projectDef in config.projects.definitions.values) {
      await workflowRegistry.loadFromDirectory(p.join(configuredProjectDirectory(config, projectDef), 'workflows'));
    }

    // Thread binding reconciliation — prune bindings for terminal tasks.
    final threadBindingStore = channel.threadBindingStore;
    ThreadBindingLifecycleManager? lifecycleManager;
    if (threadBindingStore != null) {
      final allTasks = await storage.taskService.list();
      final activeIds = allTasks.where((t) => !t.status.terminal).map((t) => t.id).toSet();
      final pruned = await threadBindingStore.reconcile(activeIds);
      if (pruned > 0) {
        _log.info('Pruned $pruned stale thread binding(s) during startup reconciliation');
      }

      // Start lifecycle manager — auto-unbind on terminal task states + idle timeout cleanup.
      final idleTimeoutMinutes = config.features.threadBinding.idleTimeoutMinutes;
      lifecycleManager = ThreadBindingLifecycleManager(
        store: threadBindingStore,
        eventBus: eventBus,
        idleTimeout: Duration(minutes: idleTimeoutMinutes),
      );
      lifecycleManager.start();
      _log.info('ThreadBindingLifecycleManager started (idle timeout: ${idleTimeoutMinutes}m)');
    }

    // Push-back feedback delivery — delivers feedback as a new turn to the task's session.
    // Only available when thread binding is enabled (threadBindingStore is non-null).
    PushBackFeedbackDelivery? pushBackFeedbackDelivery;
    if (threadBindingStore != null) {
      pushBackFeedbackDelivery = ({required taskId, required sessionKey, required feedback}) async {
        final session = await storage.sessions.getOrCreateByKey(sessionKey, type: SessionType.channel);
        final messages = [
          {'role': 'user', 'content': feedback},
        ];
        await serverRef.turns.startTurn(session.id, messages, source: 'push-back');
      };
    }
    task.setPushBackFeedbackDelivery(pushBackFeedbackDelivery);

    // 8. Scheduling — cron, heartbeat, maintenance, delivery, git sync.
    final scheduling = SchedulingWiring(
      config: config,
      eventBus: eventBus,
      storage: storage,
      channel: channel,
      security: security,
      sseBroadcast: harness.sseBroadcast,
      configNotifier: configNotifier,
    );
    await scheduling.wire(serverRefGetter: () => serverRef, turns: serverTurns, contextMonitor: harness.contextMonitor);

    // Scope reconciler — reacts to ConfigChangedEvent to update live scope.
    final scopeReconciler = ScopeReconciler(liveScopeConfig: LiveScopeConfig(config.sessions.scopeConfig));
    scopeReconciler.subscribe(eventBus);

    // Pre-create group sessions for allowlisted groups.
    final groupSessionInit = GroupSessionInitializer(
      sessions: storage.sessions,
      eventBus: eventBus,
      channelConfigs: channel.channelGroupConfigs,
      displayNameResolver: (channelType, groupId) async {
        if (channelType != 'googlechat') return null;
        final googleChatChannel = channel.googleChatChannel;
        if (googleChatChannel == null) return null;
        final space = await googleChatChannel.restClient.getSpace(groupId);
        return space?.displayName;
      },
    );
    await groupSessionInit.initialize();

    // Set remaining runtime deps on the builder and build the server.
    final restartService = RestartService(
      turns: serverTurns,
      drainDeadline: const Duration(seconds: 30),
      exit: exitFn,
      broadcastSse: harness.sseBroadcast.broadcast,
      writeRestartPending: writeRestartPending,
      dataDir: dataDir,
    );

    builder
      ..heartbeat = scheduling.heartbeat
      ..scheduleService = scheduling.scheduleService
      ..gitSync = scheduling.gitSync
      ..runtimeConfig = scheduling.runtimeConfig
      ..memoryStatusService = scheduling.memoryStatusService
      ..memoryPruner = scheduling.memoryPruner
      ..configWriter = configWriter
      ..config = config
      ..configNotifier = configNotifier
      ..restartService = restartService
      ..sseBroadcast = harness.sseBroadcast
      ..providerStatus = providerStatus
      ..projectService = project.projectService
      ..goalService = storage.goalService
      ..taskService = storage.taskService
      ..taskReviewService = task.taskReviewService
      ..worktreeManager = task.worktreeManager
      ..taskFileGuard = task.taskFileGuard
      ..agentObserver = task.agentObserver
      ..mergeExecutor = task.mergeExecutor
      ..mergeStrategy = config.tasks.worktreeMergeStrategy
      ..baseRef = config.tasks.worktreeBaseRef
      ..spaceEventsWiring = channel.spaceEventsWiring
      ..threadBindingStore = channel.threadBindingStore
      ..workflowService = workflowService
      ..workflowDefinitionSource = workflowRegistry
      ..skillRegistry = skillRegistry
      ..schedulingDisplay = SchedulingDisplayParams(
        jobs: scheduling.displayJobs,
        systemJobNames: scheduling.systemJobNames,
        scheduledTasks: config.scheduling.taskDefinitions,
      );

    final server = serverFactory(builder);
    serverRef = server;

    // Register MCP tools on the internal MCP server (/mcp HTTP endpoint).
    final handlers = harness.memoryHandlers;
    server.registerTool(SessionsSendTool(delegate: harness.sessionDelegate));
    server.registerTool(SessionsSpawnTool(delegate: harness.sessionDelegate));
    server.registerTool(MemorySaveTool(handler: handlers.onSave));
    server.registerTool(MemorySearchTool(handler: handlers.onSearch));
    server.registerTool(MemoryReadTool(handler: handlers.onRead));
    server.registerTool(
      WebFetchTool(classifier: security.contentClassifier, failOpenOnClassification: security.contentGuardFailOpen),
    );
    if (canvasService != null) {
      server.registerTool(
        CanvasTool(
          canvasService: canvasService,
          sessionKey: SessionKey.webSession(),
          baseUrl: config.server.baseUrl,
          defaultPermission: config.canvas.share.defaultPermission == 'view'
              ? CanvasPermission.view
              : CanvasPermission.interact,
          defaultTtl: Duration(minutes: config.canvas.share.defaultTtlMinutes),
        ),
      );
    }

    if (canvasService != null &&
        (config.canvas.workshopMode.taskBoard ||
            config.canvas.workshopMode.showContributorStats ||
            config.canvas.workshopMode.showBudgetBar)) {
      workshopCanvasSubscriber = WorkshopCanvasSubscriber(
        canvasService: canvasService,
        taskService: storage.taskService,
        usageTracker: harness.usageTracker,
        sessionKey: SessionKey.webSession(),
        dailyBudgetTokens: config.governance.budget.dailyTokens,
        serverStartTime: DateTime.now(),
        taskBoardEnabled: config.canvas.workshopMode.taskBoard,
        statsBarEnabled: config.canvas.workshopMode.showContributorStats || config.canvas.workshopMode.showBudgetBar,
        threadBindings: channel.threadBindingStore,
      );
      workshopCanvasSubscriber.subscribe(eventBus);
    }

    if (config.advisor.enabled) {
      advisorSubscriber = AdvisorSubscriber(
        pool: harness.pool,
        sessions: storage.sessions,
        taskService: storage.taskService,
        channelManager: channel.channelManager,
        eventBus: eventBus,
        traceService: storage.traceService,
        threadBindings: channel.threadBindingStore,
        canvasService: canvasService,
        canvasSessionKey: SessionKey.webSession(),
        triggers: config.advisor.triggers,
        periodicIntervalMinutes: config.advisor.periodicIntervalMinutes,
        maxWindowTurns: config.advisor.maxWindowTurns,
        maxPriorReflections: config.advisor.maxPriorReflections,
        model: config.advisor.model,
        effort: config.advisor.effort,
      );
      advisorSubscriber.subscribe();
    }

    // Register search tools based on config.
    for (final entry in config.search.providers.entries) {
      final providerName = entry.key;
      final providerConfig = entry.value;
      if (!providerConfig.enabled || providerConfig.apiKey.isEmpty) continue;

      switch (providerName) {
        case 'brave':
          server.registerTool(
            BraveSearchTool(
              provider: BraveSearchProvider(apiKey: providerConfig.apiKey),
              contentGuard: security.contentGuard,
            ),
          );
          _log.info('Registered brave_search MCP tool');
        case 'tavily':
          server.registerTool(
            TavilySearchTool(
              provider: TavilySearchProvider(apiKey: providerConfig.apiKey),
              contentGuard: security.contentGuard,
            ),
          );
          _log.info('Registered tavily_search MCP tool');
        default:
          _log.warning('Unknown search provider: $providerName — skipping');
      }
    }

    // Start Space Events Pub/Sub pipeline.
    if (channel.spaceEventsWiring != null) {
      await channel.spaceEventsWiring!.start();
    }

    return WiringResult(
      server: server,
      searchDb: storage.searchDb,
      agentExecutionRepository: storage.agentExecutionRepository,
      taskService: storage.taskService,
      harness: harness.harness,
      pool: harness.pool,
      heartbeat: scheduling.heartbeat,
      scheduleService: scheduling.scheduleService,
      kvService: storage.kvService,
      resetService: harness.resetService,
      selfImprovement: harness.selfImprovement,
      qmdManager: storage.qmdManager,
      channelManager: channel.channelManager,
      authEnabled: harness.authEnabled,
      tokenService: harness.tokenService,
      eventBus: eventBus,
      containerManagers: security.containerManagers,
      projectService: project.projectService,
      configNotifier: configNotifier,
      skillRegistry: skillRegistry,
      workflowRegistry: workflowRegistry,
      shutdownExtras: () async {
        lifecycleManager?.dispose();
        await workflowService.dispose();
        await task.dispose();
        await alertRouter.cancel();
        await channel.taskNotificationSubscriber?.dispose();
        await security.dispose();
        groupSessionInit.dispose();
        await scopeReconciler.cancel();
        await storage.turnStateStore.dispose();
        await scheduling.dispose();
        await project.dispose();
        await workshopCanvasSubscriber?.dispose();
        await advisorSubscriber?.dispose();
      },
    );
  }

  /// Tears down server + DB-backed services without HTTP server (used when bind fails).
  ///
  /// Also used by [ServeCommand] for the same purpose.
  static Future<void> teardown(
    DartclawServer? server,
    Database? searchDb,
    AgentHarness? harness,
    TaskService? taskService,
  ) async {
    try {
      if (server != null) {
        await server.shutdown();
      } else if (harness != null) {
        await harness.stop();
      }
    } catch (e) {
      _log.fine('Error during server/harness shutdown', e);
    }
    try {
      await taskService?.dispose();
    } catch (e) {
      _log.fine('Error disposing task service', e);
    }
    try {
      searchDb?.close();
    } catch (e) {
      _log.fine('Error closing search database', e);
    }
  }

  /// Writes sample log rotation configs for newsyslog (macOS) and logrotate
  /// (Linux).
  static void writeLogRotationSamples(String logsDir) {
    final logPath = p.join(logsDir, 'dartclaw.log');

    // macOS newsyslog.d sample
    final newsyslog = File(p.join(logsDir, 'newsyslog.conf.sample'));
    if (!newsyslog.existsSync()) {
      newsyslog.writeAsStringSync(
        '# newsyslog.d config for DartClaw log rotation (macOS)\n'
        '# Copy to /etc/newsyslog.d/dartclaw.conf\n'
        '$logPath\t\t644\t7\t1024\t*\tJ\n',
      );
    }

    // Linux logrotate sample
    final logrotate = File(p.join(logsDir, 'logrotate.conf.sample'));
    if (!logrotate.existsSync()) {
      logrotate.writeAsStringSync(
        '# logrotate config for DartClaw log rotation (Linux)\n'
        '# Copy to /etc/logrotate.d/dartclaw\n'
        '$logPath {\n'
        '    daily\n'
        '    rotate 7\n'
        '    compress\n'
        '    missingok\n'
        '    notifempty\n'
        '    size 1024k\n'
        '}\n',
      );
    }

    _log.info('Log rotation configs generated in $logsDir');
  }

  void _configureBudgetWarningNotifiers({
    required HarnessPool pool,
    required SessionService sessions,
    required TaskService taskService,
    required ChannelManager? channelManager,
  }) {
    if (channelManager == null) {
      return;
    }

    for (final runner in pool.runners) {
      runner.budgetWarningNotifier = (sessionId, result) async {
        await _notifyChannelBudgetWarning(
          sessionId: sessionId,
          result: result,
          sessions: sessions,
          taskService: taskService,
          channelManager: channelManager,
        );
      };
    }
  }

  Future<void> _notifyChannelBudgetWarning({
    required String sessionId,
    required BudgetCheckResult result,
    required SessionService sessions,
    required TaskService taskService,
    required ChannelManager channelManager,
  }) async {
    final suffix = result.decision == BudgetDecision.block ? ' New turns will be blocked until the budget resets.' : '';
    final text =
        'Warning: daily token budget is at ${result.percentage}% (${result.tokensUsed}/${result.budget} tokens).$suffix';
    await _sendNotificationToOriginChannel(
      sessionId: sessionId,
      text: text,
      label: 'budget warning',
      sessions: sessions,
      taskService: taskService,
      channelManager: channelManager,
    );
  }

  /// Sends a best-effort notification to the channel that originated [sessionId].
  ///
  /// Resolves the originating channel via task origin or session key fallback.
  /// Failures are logged and swallowed — notifications are non-critical.
  Future<void> _sendNotificationToOriginChannel({
    required String sessionId,
    required String text,
    required String label,
    required SessionService sessions,
    required TaskService taskService,
    required ChannelManager channelManager,
  }) async {
    final route = await _resolveChannelRoute(sessionId: sessionId, sessions: sessions, taskService: taskService);
    if (route == null) return;

    Channel? targetChannel;
    for (final candidate in channelManager.channels) {
      if (candidate.type == route.channelType) {
        targetChannel = candidate;
        break;
      }
    }
    if (targetChannel == null) return;

    try {
      await targetChannel.sendMessage(route.recipientId, ChannelResponse(text: text));
    } catch (error, stackTrace) {
      _log.warning(
        'Failed to send $label notification to ${route.channelType.name}:${route.recipientId}',
        error,
        stackTrace,
      );
    }
  }

  Future<({ChannelType channelType, String recipientId})?> _resolveChannelRoute({
    required String sessionId,
    required SessionService sessions,
    required TaskService taskService,
  }) async {
    final tasks = await taskService.list();
    for (final task in tasks) {
      if (task.sessionId != sessionId) continue;

      final origin = TaskOrigin.fromConfigJson(task.configJson);
      if (origin == null) continue;

      final channelType = ChannelType.values.asNameMap()[origin.channelType];
      if (channelType != null) {
        return (channelType: channelType, recipientId: origin.recipientId);
      }
    }

    final session = await sessions.getSession(sessionId);
    final channelKey = session?.channelKey;
    if (channelKey == null || channelKey.isEmpty) return null;

    try {
      final parsed = SessionKey.parse(channelKey);
      final parts = parsed.identifiers.split(':');
      if (parts.isEmpty) return null;

      final channelTypeName = Uri.decodeComponent(parts.first);
      final channelType = ChannelType.values.asNameMap()[channelTypeName];
      if (channelType == null) return null;

      return switch (parsed.scope) {
        'dm' when parts.length == 2 && parts.first != 'contact' => (
          channelType: channelType,
          recipientId: Uri.decodeComponent(parts[1]),
        ),
        'group' when parts.length >= 2 => (channelType: channelType, recipientId: Uri.decodeComponent(parts[1])),
        _ => null,
      };
    } on FormatException catch (error, stackTrace) {
      _log.warning('Failed to parse session key for channel route: $channelKey', error, stackTrace);
      return null;
    }
  }

  void _configureLoopDetectionNotifiers({
    required HarnessPool pool,
    required SessionService sessions,
    required TaskService taskService,
    required ChannelManager? channelManager,
  }) {
    if (channelManager == null) {
      return;
    }

    for (final runner in pool.runners) {
      runner.loopDetectionNotifier = (sessionId, detection, action) async {
        await _notifyChannelLoopDetection(
          sessionId: sessionId,
          detection: detection,
          action: action,
          sessions: sessions,
          taskService: taskService,
          channelManager: channelManager,
        );
      };
    }
  }

  Future<void> _notifyChannelLoopDetection({
    required String sessionId,
    required LoopDetection detection,
    required String action,
    required SessionService sessions,
    required TaskService taskService,
    required ChannelManager channelManager,
  }) async {
    final suffix = action == 'abort' ? ' The task has been cancelled.' : '';
    final text = 'Loop detected: ${detection.message}. Action: $action.$suffix';
    await _sendNotificationToOriginChannel(
      sessionId: sessionId,
      text: text,
      label: 'loop detection',
      sessions: sessions,
      taskService: taskService,
      channelManager: channelManager,
    );
  }
}

const _legacySessionCostFreshInputKey =
    'new_'
    'input_tokens';
final _serviceWiringLog = Logger('ServiceWiring');

String? _workflowFreshnessRefForProject(Project project, String? branch) {
  if (branch == null || branch.isEmpty) return null;
  if (project.remoteUrl.isNotEmpty && branch.startsWith('origin/')) {
    final trimmed = branch.substring('origin/'.length).trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return branch;
}

Future<bool> _localRefExists(String workingDirectory, String ref) async {
  final candidates = <String>{ref};
  if (!ref.startsWith('origin/') && !ref.startsWith('refs/')) {
    candidates.add('origin/$ref');
  }
  for (final candidate in candidates) {
    final result = await _workflowGit([
      'rev-parse',
      '--verify',
      '--quiet',
      candidate,
    ], workingDirectory: workingDirectory);
    if (result.exitCode == 0) {
      return true;
    }
  }
  return false;
}

Future<void> _ensureLocalBranch({
  required String projectDir,
  required String branch,
  required String baseRef,
  required bool remoteBacked,
}) async {
  final normalizedBaseRef = remoteBacked && !baseRef.startsWith('origin/') ? 'origin/$baseRef' : baseRef;
  final existing = await _workflowGit(['rev-parse', '--verify', branch], workingDirectory: projectDir);
  if (existing.exitCode == 0) {
    return;
  }
  final create = await _workflowGit(['branch', branch, normalizedBaseRef], workingDirectory: projectDir);
  if (create.exitCode != 0) {
    final stderr = (create.stderr as String).trim();
    throw StateError('Failed to create workflow branch "$branch" from "$normalizedBaseRef": $stderr');
  }
}

Future<void> _persistWorkflowArtifact(
  TaskService taskService,
  String runId,
  String? taskId,
  String name,
  ArtifactKind kind,
  String content,
) async {
  if (taskId == null || taskId.isEmpty) return;
  await taskService.addArtifact(
    id: 'workflow-publish-$runId-${kind.name}-${DateTime.now().microsecondsSinceEpoch}',
    taskId: taskId,
    name: name,
    kind: kind,
    path: content,
  );
}

Future<WorkflowGitPublishResult> publishWorkflowBranchWithProjectAuth({
  required String runId,
  required String projectId,
  required String branch,
  required ProjectService projectService,
  required TaskService taskService,
  required RemotePushService remotePushService,
  required PrCreator prCreator,
}) async {
  final resolvedProject = await projectService.get(projectId);
  if (resolvedProject == null) {
    return WorkflowGitPublishResult(
      status: WorkflowPublishStatus.failed,
      branch: branch,
      remote: 'origin',
      prUrl: '',
      error: 'Project "$projectId" not found',
    );
  }

  final pushResult = await remotePushService.push(project: resolvedProject, branch: branch);
  switch (pushResult) {
    case PushSuccess():
      final runTasks = (await taskService.list()).where((candidate) => candidate.workflowRunId == runId).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final artifactTask = runTasks.isEmpty ? null : runTasks.last;
      await _persistWorkflowArtifact(
        taskService,
        runId,
        artifactTask?.id,
        'Workflow Branch',
        ArtifactKind.branch,
        branch,
      );
      if (resolvedProject.pr.strategy == PrStrategy.githubPr) {
        final syntheticTask =
            artifactTask ??
            Task(
              id: 'workflow-$runId',
              title: 'workflow($runId)',
              description: 'Workflow publish from $branch',
              type: TaskType.coding,
              createdAt: DateTime.now(),
            );
        final prResult = await prCreator.create(project: resolvedProject, task: syntheticTask, branch: branch);
        switch (prResult) {
          case PrCreated(:final url):
            await _persistWorkflowArtifact(
              taskService,
              runId,
              artifactTask?.id,
              'Workflow Pull Request',
              ArtifactKind.pr,
              url,
            );
            return WorkflowGitPublishResult(
              status: WorkflowPublishStatus.success,
              branch: branch,
              remote: 'origin',
              prUrl: url,
            );
          case PrGhNotFound():
            return WorkflowGitPublishResult(
              status: WorkflowPublishStatus.manual,
              branch: branch,
              remote: 'origin',
              prUrl: '',
            );
          case PrCreationFailed(:final error, :final details):
            return WorkflowGitPublishResult(
              status: WorkflowPublishStatus.failed,
              branch: branch,
              remote: 'origin',
              prUrl: '',
              error: '$error: $details',
            );
        }
      }
      return WorkflowGitPublishResult(
        status: WorkflowPublishStatus.success,
        branch: branch,
        remote: 'origin',
        prUrl: '',
      );
    case PushAuthFailure(:final details):
      return WorkflowGitPublishResult(
        status: WorkflowPublishStatus.failed,
        branch: branch,
        remote: 'origin',
        prUrl: '',
        error: 'Authentication failed: $details',
      );
    case PushRejected(:final reason):
      return WorkflowGitPublishResult(
        status: WorkflowPublishStatus.failed,
        branch: branch,
        remote: 'origin',
        prUrl: '',
        error: 'Remote rejected push: $reason',
      );
    case PushError(:final message):
      return WorkflowGitPublishResult(
        status: WorkflowPublishStatus.failed,
        branch: branch,
        remote: 'origin',
        prUrl: '',
        error: message,
      );
  }
}

class WorkflowGitCleanupPlan {
  final Set<String> worktreePaths;
  final Set<String> branches;

  const WorkflowGitCleanupPlan({required this.worktreePaths, required this.branches});
}

Future<Set<String>> pushedWorkflowBranches(TaskService taskService, List<Task> runTasks) async {
  final branches = <String>{};
  for (final task in runTasks) {
    final artifacts = await taskService.listArtifacts(task.id);
    for (final artifact in artifacts) {
      if (artifact.kind == ArtifactKind.branch && artifact.path.trim().isNotEmpty) {
        branches.add(artifact.path.trim());
      }
    }
  }
  return branches;
}

Future<ProcessResult> _workflowGit(List<String> args, {required String workingDirectory}) {
  return SafeProcess.git(
    args,
    plan: const GitCredentialPlan.none(),
    workingDirectory: workingDirectory,
    noSystemConfig: true,
  );
}

String _processFailureDetail(ProcessResult result) {
  final stderr = (result.stderr as String).trim();
  final stdout = (result.stdout as String).trim();
  final detail = stderr.isNotEmpty ? stderr : stdout;
  return detail.isEmpty ? 'exit=${result.exitCode}' : 'exit=${result.exitCode}: $detail';
}

WorkflowGitCleanupPlan buildWorkflowCleanupPlan(String runId, List<Task> runTasks) {
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
  return WorkflowGitCleanupPlan(worktreePaths: worktreePaths, branches: branches);
}

Future<void> _dropLegacySessionCostEntries(KvService kvService) async {
  final entries = await kvService.getByPrefix('session_cost:');
  var dropped = 0;
  for (final entry in entries.entries) {
    try {
      final decoded = jsonDecode(entry.value);
      if (decoded is Map<String, dynamic> && decoded.containsKey(_legacySessionCostFreshInputKey)) {
        await kvService.delete(entry.key);
        dropped++;
      }
    } catch (_) {
      continue;
    }
  }
  _serviceWiringLog.info('Dropped $dropped legacy session_cost entries (pre-Tier-1b schema)');
}
