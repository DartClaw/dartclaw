import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' as config_tools;
import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart' show ensureDartclawGoogleChatRegistered;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ProcessRunner,
        CliSkillIntrospector,
        WorkflowDefinitionParser,
        WorkflowDefinitionValidator,
        WorkflowRegistry,
        WorkflowRoleDefault,
        WorkflowRoleDefaults,
        WorkflowSource,
        WorkflowService,
        WorkflowGitContext,
        WorkflowGitIntegrationBranchResult,
        WorkflowPersistencePorts,
        WorkflowGitPromotionConflict,
        WorkflowGitPromotionError,
        WorkflowGitPromotionSuccess,
        WorkflowGitPublishResult,
        WorkflowPublishStatus,
        WorkflowServiceOptions,
        WorkflowSkillPreflightConfig,
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
import 'workflow/workflow_skill_preflight_config.dart';
import 'workflow_asset_source_resolver.dart';
import 'wiring/scheduling_wiring.dart';
import 'wiring/security_wiring.dart';
import 'wiring/storage_wiring.dart';
import 'wiring/task_wiring.dart';
import 'wiring/project_wiring.dart';

part 'service_wiring_workflow.dart';
part 'service_wiring_notifications.dart';
part 'service_wiring_mcp_tools.dart';
part 'service_wiring_result.dart';
part 'service_wiring_builder.dart';

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
    required this.workflowRegistry,
  });
}

/// Cross-cutting deps threaded through [ServiceWiring._wireXxx] methods.
///
/// Late slots (builder, serverRef, serverTurns) are bound via setters as
/// construction proceeds; closures capture them via getters so late-binding
/// order is preserved across method boundaries.
final class _WiringContext {
  final EventBus eventBus;
  final ConfigNotifier configNotifier;
  final String dataDir;
  final int port;
  final AssetResolver assetResolver;
  final ResolvedAssetPaths? resolvedAssets;
  final String? builtInSkillsSourceDir;
  final MessageRedactor messageRedactor;

  late DartclawServerBuilder builder;
  late DartclawServer _serverRef;
  late TurnManager _serverTurns;

  _WiringContext({
    required this.eventBus,
    required this.configNotifier,
    required this.dataDir,
    required this.port,
    required this.assetResolver,
    required this.resolvedAssets,
    required this.builtInSkillsSourceDir,
    required this.messageRedactor,
  });

  void bindServer(DartclawServer server) => _serverRef = server;
  void bindTurns(TurnManager turns) => _serverTurns = turns;

  DartclawServer Function() get serverRefGetter =>
      () => _serverRef;
  TurnManager Function() get turnManagerGetter =>
      () => _serverTurns;
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
  /// callers leave the default. Tests opt out when they do not need native
  /// workflow skill materialization.
  final bool runAndthenSkillsBootstrap;

  /// Environment passed to [SkillProvisioner] when [runAndthenSkillsBootstrap]
  /// is true. Defaults to [Platform.environment] in production. Tests inject a
  /// controlled `HOME` here so optional user-tier discovery cannot read the
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

    final resolvedAssets = assetResolver.resolve();
    final builtInSkillsSourceDir =
        resolvedAssets?.skillsDir ?? WorkflowAssetSourceResolver.resolveBuiltInSkillsSourceDir();

    // 0.5. Skill bootstrap – must run before workflow execution so native
    // DartClaw skills are on disk for provider introspection and invocation.
    await _wireAndthenSkillsBootstrap(builtInSkillsSourceDir);
    final ctx = _WiringContext(
      eventBus: EventBus(),
      configNotifier: ConfigNotifier(config),
      dataDir: dataDir,
      port: port,
      assetResolver: assetResolver,
      resolvedAssets: resolvedAssets,
      builtInSkillsSourceDir: builtInSkillsSourceDir,
      messageRedactor: messageRedactor,
    );

    // 0. Projects
    final project = await _wireProjects(ctx);
    // 1. Storage
    final storage = await _wireStorage(ctx);
    // 2. Security
    final agentDefs = config.agent.definitions.isNotEmpty ? config.agent.definitions : [AgentDefinition.searchAgent()];
    final security = await _wireSecurity(ctx, agentDefs);
    // 3. Harness
    final harness = await _wireHarness(ctx, storage, security);
    // 4. Tasks (pre-server)
    final task = await _wirePreServerTasks(ctx, storage, project, security);
    // 5. Channels
    final channel = await _wireChannels(ctx, storage, task, harness);
    final alertRouter = _wireAlertRouter(ctx, storage, channel);
    // 6. Build server – restart sentinel, provider status, builder pre-server cascade
    _wireRestartSentinel(ctx);
    final (providerStatus, canvasService) = await _wireProviderStatusAndCanvas(harness, security);
    ctx.builder = _buildServerBuilderPreServer(config, ctx, storage, harness, task, channel, security, canvasService);
    ctx.bindTurns(ctx.builder.buildTurns());
    await ctx._serverTurns.detectAndCleanOrphanedTurns();
    ctx.configNotifier.register(ctx._serverTurns);
    // 7. Tasks (post-server)
    await task.wirePostServer(turns: ctx._serverTurns, pool: harness.pool, onSpawnNeeded: harness.onSpawnNeeded);
    final workflowRoleDefaults = _buildWorkflowRoleDefaults();
    final workflowService = await _wireWorkflowService(ctx, storage, task, project, workflowRoleDefaults);
    final workflowRegistry = await _wireWorkflowRegistry(ctx, harness, workflowRoleDefaults);
    final (lifecycleManager, pushBackFeedback) = await _wireThreadBinding(ctx, storage, channel);
    task.setPushBackFeedbackDelivery(pushBackFeedback);
    // 8. Scheduling
    final scheduling = await _wireScheduling(ctx, storage, channel, harness, security);
    final scopeReconciler = _wireScopeReconciler(ctx);
    final groupSessionInit = await _wireGroupSessionInit(ctx, storage, channel);
    final restartService = _buildRestartService(ctx, harness);
    _applyServerBuilderPostServer(
      config,
      resolvedConfigPath,
      ctx,
      storage,
      task,
      harness,
      scheduling,
      project,
      providerStatus,
      workflowService,
      workflowRegistry,
      restartService,
      channel,
    );
    final server = serverFactory(ctx.builder);
    ctx.bindServer(server);
    final (workshopSubscriber, advisorSubscriber) = _registerMcpTools(
      config,
      ctx,
      server,
      harness,
      storage,
      security,
      channel,
      canvasService,
    );
    if (channel.spaceEventsWiring != null) {
      await channel.spaceEventsWiring!.start();
    }
    return _assembleWiringResult(
      ctx,
      server,
      storage,
      harness,
      scheduling,
      channel,
      security,
      task,
      project,
      workflowRegistry,
      workflowService,
      alertRouter,
      lifecycleManager,
      scopeReconciler,
      groupSessionInit,
      workshopSubscriber,
      advisorSubscriber,
    );
  }

  Future<ProjectWiring> _wireProjects(_WiringContext ctx) async {
    final project = ProjectWiring(config: config, dataDir: ctx.dataDir, eventBus: ctx.eventBus);
    await project.wire();
    return project;
  }

  Future<void> _wireAndthenSkillsBootstrap(String? builtInSkillsSourceDir) async {
    if (!runAndthenSkillsBootstrap) return;
    await bootstrapWorkflowSkills(
      config: config,
      dataDir: dataDir,
      builtInSkillsSourceDir: builtInSkillsSourceDir,
      environment: skillProvisionerEnvironment,
      processRunner: skillProvisionerProcessRunner,
    );
  }

  Future<StorageWiring> _wireStorage(_WiringContext ctx) async {
    final storage = StorageWiring(
      config: config,
      eventBus: ctx.eventBus,
      searchDbFactory: searchDbFactory,
      taskDbFactory: taskDbFactory,
      exitFn: exitFn,
    );
    await storage.wire();
    await _dropLegacySessionCostEntries(storage.kvService);
    return storage;
  }

  Future<SecurityWiring> _wireSecurity(_WiringContext ctx, List<AgentDefinition> agentDefs) async {
    final security = SecurityWiring(
      config: config,
      dataDir: ctx.dataDir,
      eventBus: ctx.eventBus,
      exitFn: exitFn,
      configNotifier: ctx.configNotifier,
      messageRedactor: ctx.messageRedactor,
    );
    await security.wire(agentDefs: agentDefs);
    return security;
  }

  Future<HarnessWiring> _wireHarness(_WiringContext ctx, StorageWiring storage, SecurityWiring security) async {
    final harness = HarnessWiring(
      config: config,
      dataDir: ctx.dataDir,
      port: ctx.port,
      harnessFactory: harnessFactory,
      exitFn: exitFn,
      storage: storage,
      security: security,
      messageRedactor: ctx.messageRedactor,
      eventBus: ctx.eventBus,
      configNotifier: ctx.configNotifier,
    );
    // Server ref resolved lazily – closures in harness capture the getter.
    await harness.wire(serverRefGetter: ctx.serverRefGetter);
    return harness;
  }

  Future<TaskWiring> _wirePreServerTasks(
    _WiringContext ctx,
    StorageWiring storage,
    ProjectWiring project,
    SecurityWiring security,
  ) async {
    final task = TaskWiring(
      config: config,
      dataDir: ctx.dataDir,
      eventBus: ctx.eventBus,
      storage: storage,
      project: project,
      containerManagers: security.containerManagers,
    );
    await task.wirePreServer();
    return task;
  }

  Future<ChannelWiring> _wireChannels(
    _WiringContext ctx,
    StorageWiring storage,
    TaskWiring task,
    HarnessWiring harness,
  ) async {
    final channel = ChannelWiring(
      config: config,
      dataDir: ctx.dataDir,
      port: ctx.port,
      eventBus: ctx.eventBus,
      storage: storage,
      task: task,
      resolvedConfigPath: resolvedConfigPath,
    );
    await channel.wire(
      serverRefGetter: ctx.serverRefGetter,
      turnManagerGetter: ctx.turnManagerGetter,
      sseBroadcast: harness.sseBroadcast,
      messageRedactor: ctx.messageRedactor,
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
    return channel;
  }

  AlertRouter _wireAlertRouter(_WiringContext ctx, StorageWiring storage, ChannelWiring channel) {
    Channel? lookupAlertChannel(String channelTypeName) {
      final manager = channel.channelManager;
      if (manager == null) return null;
      for (final candidate in manager.channels) {
        if (candidate.type.name == channelTypeName) return candidate;
      }
      return null;
    }

    final alertRouter = AlertRouter(
      bus: ctx.eventBus,
      adapter: AlertDeliveryAdapter(lookupAlertChannel),
      config: config.alerts,
      taskLookup: storage.taskService.get,
    );
    ctx.configNotifier.register(alertRouter);
    return alertRouter;
  }

  void _wireRestartSentinel(_WiringContext ctx) {
    final restartPendingFile = File(p.join(ctx.dataDir, 'restart.pending'));
    if (!restartPendingFile.existsSync()) return;
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

  Future<(ProviderStatusService, CanvasService?)> _wireProviderStatusAndCanvas(
    HarnessWiring harness,
    SecurityWiring security,
  ) async {
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
    return (providerStatus, canvasService);
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

  Map<String, String> _providerProbeEnvironment(String providerId, config_tools.CredentialRegistry registry) {
    final environment = SafeProcess.sanitize(
      baseEnvironment: Platform.environment,
      sensitivePatterns: [...defaultSensitivePatterns, 'CLAUDE_CODE_SUBAGENT_MODEL'],
      extraEnvironment: claudeHardeningEnvVars,
    );
    final apiKey = registry.getApiKey(providerId);
    if (apiKey != null) {
      for (final envVar in config_tools.CredentialRegistry.envVarsFor(providerId)) {
        environment[envVar] = apiKey;
      }
    }
    return environment;
  }

  Future<WorkflowService> _wireWorkflowService(
    _WiringContext ctx,
    StorageWiring storage,
    TaskWiring task,
    ProjectWiring project,
    WorkflowRoleDefaults workflowRoleDefaults,
  ) async {
    final credentialRegistry = config_tools.CredentialRegistry(
      credentials: config.credentials,
      env: Platform.environment,
    );
    final workflowService = WorkflowService(
      repository: storage.workflowRunRepository,
      taskService: storage.taskService,
      messageService: storage.messages,
      persistencePorts: WorkflowPersistencePorts(
        taskRepository: storage.taskRepository,
        agentExecutionRepository: storage.agentExecutionRepository,
        workflowStepExecutionRepository: storage.workflowStepExecutionRepository,
        executionRepositoryTransactor: storage.executionRepositoryTransactor,
      ),
      gitContext: WorkflowGitContext(
        gitPort: WorkflowGitPortProcess(
          worktreeManager: task.worktreeManager,
          remotePushService: task.remotePushService,
        ),
        projectService: project.projectService,
        hydrateBinding: task.taskExecutor.hydrateWorkflowSharedWorktreeBinding,
      ),
      options: WorkflowServiceOptions(
        bashStepEnvAllowlist: config.security.bashStep.envAllowlist,
        bashStepExtraStripPatterns: config.security.bashStep.extraStripPatterns,
        roleDefaults: workflowRoleDefaults,
        structuredOutputFallbackRecorder: storage.taskEventRecorder.recordStructuredOutputFallbackUsed,
        skillIntrospector: CliSkillIntrospector(
          environmentForProvider: (providerId) => _providerProbeEnvironment(providerId, credentialRegistry),
        ),
        skillPreflightConfig: _buildSkillPreflightConfig(),
      ),
      turnAdapter: _buildWorkflowTurnAdapter(config, ctx, storage, task, project),
      eventBus: ctx.eventBus,
      kvService: storage.kvService,
      dataDir: ctx.dataDir,
    );
    await workflowService.recoverIncompleteRuns();
    return workflowService;
  }

  Future<WorkflowRegistry> _wireWorkflowRegistry(
    _WiringContext ctx,
    HarnessWiring harness,
    WorkflowRoleDefaults workflowRoleDefaults,
  ) async {
    final continuityProviders = harness.pool.runners
        .where((r) => r.harness.supportsSessionContinuity)
        .map((r) => r.providerId)
        .toSet();
    await WorkflowMaterializer.materialize(dataDir: ctx.dataDir, assetResolver: ctx.assetResolver);
    final workflowRegistry = WorkflowRegistry(
      parser: WorkflowDefinitionParser(),
      validator: WorkflowDefinitionValidator(roleDefaults: workflowRoleDefaults),
      continuityProviders: continuityProviders,
    );
    await workflowRegistry.loadFromDirectory(
      WorkflowMaterializer.builtInDir(ctx.dataDir),
      source: WorkflowSource.materialized,
    );
    await workflowRegistry.loadFromDirectory(WorkflowMaterializer.customDir(ctx.dataDir));
    await workflowRegistry.loadFromDirectory(p.join(ctx.dataDir, 'workflows'));
    for (final projectDef in config.projects.definitions.values) {
      await workflowRegistry.loadFromDirectory(p.join(configuredProjectDirectory(config, projectDef), 'workflows'));
    }
    return workflowRegistry;
  }

  Future<(ThreadBindingLifecycleManager?, PushBackFeedbackDelivery?)> _wireThreadBinding(
    _WiringContext ctx,
    StorageWiring storage,
    ChannelWiring channel,
  ) async {
    final threadBindingStore = channel.threadBindingStore;
    if (threadBindingStore == null) return (null, null);

    final allTasks = await storage.taskService.list();
    final activeIds = allTasks.where((t) => !t.status.terminal).map((t) => t.id).toSet();
    final pruned = await threadBindingStore.reconcile(activeIds);
    if (pruned > 0) {
      _log.info('Pruned $pruned stale thread binding(s) during startup reconciliation');
    }

    final idleTimeoutMinutes = config.features.threadBinding.idleTimeoutMinutes;
    final lifecycleManager = ThreadBindingLifecycleManager(
      store: threadBindingStore,
      eventBus: ctx.eventBus,
      idleTimeout: Duration(minutes: idleTimeoutMinutes),
    );
    lifecycleManager.start();
    _log.info('ThreadBindingLifecycleManager started (idle timeout: ${idleTimeoutMinutes}m)');

    // Push-back feedback delivery – delivers feedback as a new turn to the task's session.
    // Only available when thread binding is enabled (threadBindingStore is non-null).
    Future<void> pushBackFeedback({
      required String taskId,
      required String sessionKey,
      required String feedback,
    }) async {
      final session = await storage.sessions.getOrCreateByKey(sessionKey, type: SessionType.channel);
      final messages = [
        {'role': 'user', 'content': feedback},
      ];
      await ctx._serverRef.turns.startTurn(session.id, messages, source: 'push-back');
    }

    return (lifecycleManager, pushBackFeedback);
  }

  Future<SchedulingWiring> _wireScheduling(
    _WiringContext ctx,
    StorageWiring storage,
    ChannelWiring channel,
    HarnessWiring harness,
    SecurityWiring security,
  ) async {
    final scheduling = SchedulingWiring(
      config: config,
      eventBus: ctx.eventBus,
      storage: storage,
      channel: channel,
      security: security,
      sseBroadcast: harness.sseBroadcast,
      configNotifier: ctx.configNotifier,
    );
    await scheduling.wire(
      serverRefGetter: ctx.serverRefGetter,
      turns: ctx._serverTurns,
      contextMonitor: harness.contextMonitor,
    );
    return scheduling;
  }

  ScopeReconciler _wireScopeReconciler(_WiringContext ctx) {
    final scopeReconciler = ScopeReconciler(liveScopeConfig: LiveScopeConfig(config.sessions.scopeConfig));
    scopeReconciler.subscribe(ctx.eventBus);
    return scopeReconciler;
  }

  Future<GroupSessionInitializer> _wireGroupSessionInit(
    _WiringContext ctx,
    StorageWiring storage,
    ChannelWiring channel,
  ) async {
    final groupSessionInit = GroupSessionInitializer(
      sessions: storage.sessions,
      eventBus: ctx.eventBus,
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
    return groupSessionInit;
  }

  RestartService _buildRestartService(_WiringContext ctx, HarnessWiring harness) {
    return RestartService(
      turns: ctx._serverTurns,
      drainDeadline: const Duration(seconds: 30),
      exit: exitFn,
      broadcastSse: harness.sseBroadcast.broadcast,
      writeRestartPending: writeRestartPending,
      dataDir: ctx.dataDir,
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
}
