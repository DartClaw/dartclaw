import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' as config_tools;
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart' show ensureDartclawGoogleChatRegistered;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ProcessRunner,
        CliProviderAuthPreflight,
        CliSkillIntrospector,
        WorkspaceSkillInventory,
        WorkflowDefinitionParser,
        WorkflowDefinitionValidator,
        WorkflowRegistry,
        WorkflowRoleDefaults,
        WorkflowSource,
        WorkflowService,
        WorkflowGitContext,
        WorkflowGitIntegrationBranchResult,
        WorkflowPersistencePorts,
        WorkflowGitPromotionError,
        WorkflowGitPublishResult,
        WorkflowPublishStatus,
        WorkflowRun,
        workflowBlockedOutcomeSummary,
        WorkflowServiceOptions,
        WorkflowSkillPreflightConfig,
        WorkflowStartResolution,
        WorkflowTurnAdapter,
        WorkflowTurnOutcome,
        resolveIntegrationBranchName;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'serve_command.dart';
import 'wiring/channel_wiring.dart';
import 'wiring/harness_wiring.dart';
import 'workflow_materializer.dart';
import 'workflow/agent_text_scrub.dart';
import 'workflow/workflow_skill_bootstrap.dart';
import 'workflow/project_definition_paths.dart';
import 'workflow/workflow_config_support.dart';
import 'workflow/workflow_git_support.dart';
import 'workflow/workflow_local_path_preflight.dart';
import 'workflow/workflow_provider_environment.dart';
import 'workflow/workflow_skill_preflight_config.dart';
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

typedef PostMcpStartupHook = Future<void> Function(ChannelWiring channel);

/// The providers that present a credential, each mapped to the family whose
/// credential it presents.
///
/// A provider declaring `credentials_required: false` — an ACP agent — is
/// omitted: it has no credential to age, and reporting it unauthenticated would
/// page the operator for a login that does not exist. This is the exemption
/// `ProviderValidator` already applies at startup. The family is resolved
/// (honoring a `family` option and the executable name) so a provider alias is
/// aged against its vendor's window instead of falling through as unknown.
Map<String, String> credentialedProviderFamilies(Map<String, ProviderEntry> entries) => {
  for (final entry in entries.entries)
    if (entry.value.options['credentials_required'] != false)
      entry.key: ProviderIdentity.resolveFamily(
        entry.key,
        options: entry.value.options,
        executable: entry.value.executable,
      ),
};

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
  final ExecutionCoordinator executions;
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

  /// Leases a dedicated container authority for one containerized execution,
  /// or `null` in host-only deployments.
  final ContainerAuthorityProvider? containerAuthorities;
  final Future<void> Function() shutdownExtras;
  final Future<void> Function()? prepareExecutionShutdown;
  final ProjectService projectService;
  final ConfigNotifier configNotifier;
  final OutboundMcpPool? outboundMcpPool;

  /// Workflow registry populated by [ServiceWiring.wire]. Exposed so tests can
  /// assert that the shipped built-in workflow definitions (`plan-and-implement`,
  /// `spec-and-implement`, `code-review`) register against the runtime skill
  /// registry.
  final WorkflowRegistry workflowRegistry;

  /// The in-`serve` workflow one-shot lane. Exposed so tests can assert on the
  /// gates it was wired with — notably its provider-auth preflight, whose
  /// absence silently disables the engine's own backstop.
  final WorkflowService workflowService;

  const new({
    required this.server,
    required this.searchDb,
    required this.agentExecutionRepository,
    required this.taskService,
    required this.harness,
    required this.executions,
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
    required this.containerAuthorities,
    required this.shutdownExtras,
    this.prepareExecutionShutdown,
    required this.projectService,
    required this.configNotifier,
    this.outboundMcpPool,
    required this.workflowRegistry,
    required this.workflowService,
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
  final ResolvedAssets resolvedAssets;
  final String? builtInSkillsSourceDir;
  final MessageRedactor messageRedactor;

  /// Dedicated subscription credential stores, read per use so a re-issued
  /// token reaches the next spawn or mediated request without a restart.
  final SubscriptionCredentialStore subscriptions;

  /// One refresh authority per dedicated Codex store for the whole process.
  ///
  /// Single-flight is a property of this instance, so a second one would be a
  /// second refresher — exactly what the design forbids. Every DartClaw lane
  /// that touches the store shares this one.
  final CodexRefreshAuthority codexRefresh;

  late DartclawServerBuilder builder;
  late DartclawServer _serverRef;
  late TurnManager _serverTurns;

  new({
    required this.eventBus,
    required this.configNotifier,
    required this.dataDir,
    required this.port,
    required this.resolvedAssets,
    required this.builtInSkillsSourceDir,
    required this.messageRedactor,
    required this.subscriptions,
    required this.codexRefresh,
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
  final ResolvedAssets resolvedAssets;
  final PlatformCapabilities platformCapabilities;
  final OutboundMcpTransportFactory? outboundMcpTransportFactory;
  final PostMcpStartupHook postMcpStartupHook;

  /// When `false`, [wire] skips the [SkillProvisioner] bootstrap. Production
  /// callers leave the default. Tests opt out when they do not need native
  /// workflow skill materialization.
  final bool runWorkflowSkillsBootstrap;

  /// Environment passed to [SkillProvisioner] when [runWorkflowSkillsBootstrap]
  /// is true. Defaults to [Platform.environment] in production. Tests inject a
  /// controlled `HOME` here so optional user-tier discovery cannot read the
  /// developer's real `~/.agents` or `~/.claude` trees.
  final Map<String, String>? skillProvisionerEnvironment;

  /// Child-process seam passed to [SkillProvisioner] for deterministic tests.
  final ProcessRunner? skillProvisionerProcessRunner;

  /// Environment the dedicated credential stores resolve the operator's own
  /// login paths from, as [HarnessWiring] holds its own.
  ///
  /// Replaces the process environment rather than overlaying it, so a partial
  /// map silently narrows the login-collision guard: without `HOME` the guard
  /// stops covering `~/.codex` and `~/.claude` and checks only the relocation
  /// variables it was given. Pass a complete environment or none.
  final Map<String, String> _environment;

  /// Bound at step 8 of [wire] — the monitor needs the built
  /// `ProviderStatusService` — and read only by closures the probe lanes invoke
  /// long afterwards.
  CredentialHealthMonitor? _credentialHealth;

  late _WiringContext _ctx;

  static final _log = Logger('ServiceWiring');

  new({
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
    required this.resolvedAssets,
    PlatformCapabilities? platformCapabilities,
    this.outboundMcpTransportFactory,
    PostMcpStartupHook? postMcpStartupHook,
    this.runWorkflowSkillsBootstrap = true,
    this.skillProvisionerEnvironment,
    this.skillProvisionerProcessRunner,
    @visibleForTesting Map<String, String>? environment,
  }) : platformCapabilities = platformCapabilities ?? PlatformCapabilities(),
       _environment = environment ?? Platform.environment,
       postMcpStartupHook = postMcpStartupHook ?? _startSpaceEvents;

  /// Constructs all services, wires them together via [DartclawServerBuilder],
  /// and registers MCP tools on the built server.
  ///
  /// Returns a [WiringResult] containing everything [ServeCommand.run] needs
  /// to start the HTTP server, print the startup banner, and wire shutdown.
  Future<WiringResult> wire() async {
    ensureDartclawGoogleChatRegistered();

    final builtInSkillsSourceDir = _builtInSkillsSourceDir(resolvedAssets);

    // 0.5. Skill bootstrap – must run before workflow execution so native
    // DartClaw skills are on disk for provider introspection and invocation.
    await _wireWorkflowSkillsBootstrap(builtInSkillsSourceDir);
    // Opened once, before any consumer, so the login-collision guard runs
    // ahead of every credential read this deployment performs.
    final subscriptions = _openSubscriptionStore();
    final ctx = _WiringContext(
      eventBus: EventBus(),
      configNotifier: ConfigNotifier(config, platformCapabilities: platformCapabilities),
      dataDir: dataDir,
      port: port,
      resolvedAssets: resolvedAssets,
      builtInSkillsSourceDir: builtInSkillsSourceDir,
      messageRedactor: messageRedactor,
      subscriptions: subscriptions,
      codexRefresh: CodexRefreshAuthority(
        store: subscriptions,
        vendorRefresh: (codexHome) => refreshCodexAuth(
          codexHome,
          executable: resolveWorkflowProviderExecutable(config, config_tools.ProviderIdentity.codex),
        ),
      ),
    );
    _ctx = ctx;

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
    final task = await _wirePreServerTasks(ctx, storage, project, security, harness);
    // 5. Channels
    final channel = await _wireChannels(ctx, storage, task, harness);
    final alertRouter = _wireAlertRouter(ctx, storage, channel);
    // 6. Build server – restart sentinel, provider status, builder pre-server cascade
    _wireRestartSentinel(ctx);
    final providerStatus = await _wireProviderStatus(ctx, harness, security);
    ctx.builder = _buildServerBuilderPreServer(config, ctx, storage, harness, task, channel, security);
    ctx.bindTurns(ctx.builder.buildTurns());
    await ctx._serverTurns.detectAndCleanOrphanedTurns();
    ctx.configNotifier.register(ctx._serverTurns);
    // 7. Tasks (post-server)
    await task.wirePostServer(
      turns: ctx._serverTurns,
      executions: harness.executions,
      policyResolver: harness.policyResolver,
    );
    final workflowRoleDefaults = workflowRoleDefaultsFromConfig(config);
    final workflowService = await _wireWorkflowService(ctx, storage, task, project, workflowRoleDefaults);
    final workflowRegistry = await _wireWorkflowRegistry(ctx, harness, workflowRoleDefaults);
    final (lifecycleManager, pushBackFeedback) = await _wireThreadBinding(ctx, storage, channel);
    task.setPushBackFeedbackDelivery(pushBackFeedback);
    // 8. Scheduling
    final credentialHealth = _wireCredentialHealth(ctx, harness, providerStatus);
    // Bound here rather than constructed with the security and harness layers:
    // the monitor needs the ProviderStatusService the API reads, which exists
    // only once the server builder has run. Both boundaries announce through it
    // — the container's refusals via the gateway, the host's via admission and
    // the dedicated-home preparation. The workflow one-shot lane is a third
    // host producer: it prepares its own dedicated home per spawn, and those
    // spawns happen long after this step. The probe lane is the fourth, for the
    // same reason and with the same timing.
    security.credentialHealth = credentialHealth;
    harness.credentialHealth = credentialHealth;
    task.credentialHealth = credentialHealth;
    _credentialHealth = credentialHealth;
    final scheduling = await _wireScheduling(ctx, storage, channel, harness, security, credentialHealth);
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
    final (advisorSubscriber, outboundMcpPool) = await _registerMcpTools(
      config,
      ctx,
      server,
      harness,
      storage,
      security,
      channel,
      outboundMcpTransportFactory: outboundMcpTransportFactory,
    );
    try {
      await postMcpStartupHook(channel);
    } catch (error, stackTrace) {
      try {
        await outboundMcpPool?.close();
      } catch (closeError, closeStackTrace) {
        ServiceWiring._log.warning(
          'Failed to close outbound MCP pool after startup error: $closeError',
          closeError,
          closeStackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
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
      advisorSubscriber,
      outboundMcpPool,
    );
  }

  /// The collision guard is a security refusal, so it must reach the operator
  /// as an actionable line rather than an unhandled stack trace out of `wire()`.
  SubscriptionCredentialStore _openSubscriptionStore() {
    try {
      return SubscriptionCredentialStore.open(credentialsDir: config.credentialsDir, environment: _environment);
    } on LoginStoreCollisionError catch (error) {
      stderrLine(error.toString());
      exitFn(1);
    }
  }

  static Future<void> _startSpaceEvents(ChannelWiring channel) async {
    if (channel.spaceEventsWiring != null) {
      await channel.spaceEventsWiring!.start();
    }
  }

  static String? _builtInSkillsSourceDir(ResolvedAssets resolvedAssets) => resolvedAssets.skillsDir;

  Future<ProjectWiring> _wireProjects(_WiringContext ctx) async {
    final project = ProjectWiring(config: config, dataDir: ctx.dataDir, eventBus: ctx.eventBus);
    await project.wire();
    return project;
  }

  Future<void> _wireWorkflowSkillsBootstrap(String? builtInSkillsSourceDir) async {
    if (!runWorkflowSkillsBootstrap) return;
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
      platformCapabilities: platformCapabilities,
      configNotifier: ctx.configNotifier,
      messageRedactor: ctx.messageRedactor,
      subscriptionCredentials: ctx.subscriptions.readAll,
      codexRefresh: ctx.codexRefresh,
      // Server ref resolved lazily – the MCP registry exists only after the
      // server is built, while authorities are created at turn time.
      mcpHandlerRef: () => ctx.serverRefGetter().mcpHandler,
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
      subscriptionCredentials: ctx.subscriptions.readAll,
      codexRefresh: ctx.codexRefresh,
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
    HarnessWiring harness,
  ) async {
    final task = TaskWiring(
      config: config,
      dataDir: ctx.dataDir,
      eventBus: ctx.eventBus,
      storage: storage,
      project: project,
      containerAuthorities: security.containersEnabled ? security.acquireContainerAuthority : null,
      // The workflow lane's grant is derived by the one owner (HarnessWiring),
      // paired with container mediation so a containerized step's bridge grant
      // gets the same deny/servable treatment as every other execution.
      bridgedMcpToolsResolver: security.containersEnabled ? harness.workflowBridgedMcpTools : null,
      executionInventory: harness.executionInventory,
      messageRedactor: ctx.messageRedactor,
      subscriptionCredentials: ctx.subscriptions.readAll,
      codexRefresh: ctx.codexRefresh,
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
      executions: harness.executions,
      sessions: storage.sessions,
      taskService: storage.taskService,
      channelManager: channel.channelManager,
    );
    _configureLoopDetectionNotifiers(
      executions: harness.executions,
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

  Future<ProviderStatusService> _wireProviderStatus(
    _WiringContext ctx,
    HarnessWiring harness,
    SecurityWiring security,
  ) async {
    final providerStatus = ProviderStatusService(
      providers: ProvidersConfig(entries: harness.providerStatusEntries),
      registry: _credentialRegistry(ctx),
      defaultProvider: config.agent.provider,
      executions: harness.executions,
      credentialsDir: config.credentialsDir,
    );
    await providerStatus.probe();
    return providerStatus;
  }

  /// A registry over the current credential state, including the dedicated
  /// subscription stores, rebuilt per use so a re-issued token needs no restart.
  config_tools.CredentialRegistry _credentialRegistry(_WiringContext ctx, {config_tools.ProvidersConfig? providers}) =>
      config_tools.CredentialRegistry(
        credentials: config.credentials,
        env: Platform.environment,
        providers: providers ?? config.providers,
        subscriptions: ctx.subscriptions.readAll(),
      );

  CredentialHealthMonitor _wireCredentialHealth(
    _WiringContext ctx,
    HarnessWiring harness,
    ProviderStatusService providerStatus,
  ) {
    final providers = ProvidersConfig(entries: harness.providerStatusEntries);
    final credentialed = credentialedProviderFamilies(providers.entries);
    return CredentialHealthMonitor(
      eventBus: ctx.eventBus,
      providerStatus: providerStatus,
      credentialsDir: config.credentialsDir,
      // Re-read per probe: a credential renewed between runs must be seen
      // without a restart, and the registry holds a snapshot.
      resolveCredentials: () {
        final registry = _credentialRegistry(ctx, providers: providers);
        return {
          for (final entry in credentialed.entries)
            entry.key: (family: entry.value, resolution: registry.resolve(entry.key, family: entry.value)),
        };
      },
    );
  }

  WorkflowSkillPreflightConfig _buildSkillPreflightConfig() {
    return buildWorkflowSkillPreflightConfig(config);
  }

  /// The environment the skill-introspection and auth probes spawn the vendor
  /// CLI with. The registry is built here rather than passed in, so a credential
  /// stored or rotated after wiring is the one the probe presents.
  Future<Map<String, String>> _providerProbeEnvironment(_WiringContext ctx, String providerId) {
    return buildWorkflowProbeEnvironment(
      providerId: providerId,
      providerFamily: config_tools.ProviderIdentity.resolveFamily(
        providerId,
        executable: resolveWorkflowProviderExecutable(config, providerId),
        options: workflowProviderOptions(config, providerId),
      ),
      registry: _credentialRegistry(ctx),
      baseEnvironment: Platform.environment,
      codexRefresh: ctx.codexRefresh,
      credentialsDir: config.credentialsDir,
      onCredentialHealth: _reportProbeCredentialHealth,
    );
  }

  /// The probe environment for [providerId], for tests.
  ///
  /// Both probes spawn through `SafeProcess.run` with no injectable starter, so
  /// there is no process seam downstream to observe what they were handed — the
  /// same reason `CliWorkflowWiring` exposes its own.
  @visibleForTesting
  Future<Map<String, String>> providerProbeEnvironment(String providerId) =>
      _providerProbeEnvironment(_ctx, providerId);

  /// Announces a probe-lane Codex credential condition through the deployment's
  /// single credential-health writer.
  ///
  /// The probes run the vendor CLI on the host, so their refusals reach no
  /// gateway; and the hourly probe drives no refresh, so a spent or unreachable
  /// refresh lineage discovered while preparing a probe's dedicated `CODEX_HOME`
  /// would otherwise produce no FR6 event at all. The severe line is the
  /// degradation FR6 requires while no monitor is bound — probes run long after
  /// wiring, so that is only the case for a probe during startup.
  void _reportProbeCredentialHealth({
    required String providerId,
    required CredentialHealthState state,
    required String detail,
    String? remediation,
  }) {
    final monitor = _credentialHealth;
    if (monitor == null) {
      _log.severe('Provider "$providerId" credential unusable: $detail${remediation == null ? '' : ' $remediation'}');
      return;
    }
    monitor.report(providerId: providerId, state: state, detail: detail, remediation: remediation);
  }

  Future<WorkflowService> _wireWorkflowService(
    _WiringContext ctx,
    StorageWiring storage,
    TaskWiring task,
    ProjectWiring project,
    WorkflowRoleDefaults workflowRoleDefaults,
  ) async {
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
        approvalPolicyDefault: config.workflow.approvals,
        structuredOutputFallbackRecorder: storage.taskEventRecorder.recordStructuredOutputFallbackUsed,
        skillIntrospector: CliSkillIntrospector(
          environmentForProvider: (providerId) => _providerProbeEnvironment(ctx, providerId),
          provisionedSkills: WorkspaceSkillInventory.fromDataDir(ctx.dataDir).skillNames.toSet(),
        ),
        // The in-engine backstop is inert without this, so an in-`serve`
        // workflow step assigned to a provider with no usable credential would
        // otherwise spawn its host CLI ungated. The standalone lane injects the
        // same preflight; both must gate or the two lanes disagree.
        //
        // The registry is resolved per evaluation, like the `TaskWiring` spawn
        // this gate guards: a boot-time snapshot would refuse a step whose
        // credential the operator stored after `serve` started, while the
        // executor behind it would have run it.
        providerAuthPreflight: CliProviderAuthPreflight(
          credentials: () => _credentialRegistry(ctx),
          environmentForProvider: (providerId) => _providerProbeEnvironment(ctx, providerId),
          credentialsDir: config.credentialsDir,
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
    final continuityProviders = harness.continuityProviders;
    final resolvedWorkflowsDir = ctx.resolvedAssets.workflowsDir;
    await WorkflowMaterializer.materialize(
      dataDir: ctx.dataDir,
      sourceDir: resolvedWorkflowsDir,
      discoverSourceTree: false,
    );
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
    await workflowRegistry.loadFromDeprecatedLegacyDirectory(
      p.join(ctx.dataDir, 'workflows'),
      replacementDirectory: WorkflowMaterializer.customDir(ctx.dataDir),
    );
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
      await ctx._serverRef.turns.startTurn(
        session.id,
        messages,
        source: 'push-back',
        isHumanInput: true,
        promptScope: PromptScope.primary,
      );
    }

    return (lifecycleManager, pushBackFeedback);
  }

  Future<SchedulingWiring> _wireScheduling(
    _WiringContext ctx,
    StorageWiring storage,
    ChannelWiring channel,
    HarnessWiring harness,
    SecurityWiring security,
    CredentialHealthMonitor credentialHealth,
  ) async {
    final scheduling = SchedulingWiring(
      config: config,
      eventBus: ctx.eventBus,
      storage: storage,
      channel: channel,
      security: security,
      sseBroadcast: harness.sseBroadcast,
      memoryHandlers: harness.memoryHandlers,
      credentialHealth: credentialHealth,
      behavior: harness.behavior,
      configNotifier: ctx.configNotifier,
    );
    await scheduling.wire(
      serverRefGetter: ctx.serverRefGetter,
      turns: ctx._serverTurns,
      contextMonitor: harness.contextMonitor,
      policyResolver: harness.policyResolver,
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
