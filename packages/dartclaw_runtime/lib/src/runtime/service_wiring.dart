import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart' as config_tools;
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ProcessRunner,
        CliProviderAuthPreflight,
        CliSkillIntrospector,
        ProviderAuthPreflight,
        SkillIntrospector,
        WorkflowAssetSourceResolver,
        WorkflowPreflightException,
        WorkflowDefinitionParser,
        WorkflowDefinitionSource,
        WorkflowDefinitionValidator,
        WorkflowMaterializer,
        WorkspaceSkillInventory,
        WorkflowRegistry,
        WorkflowRoleDefaults,
        WorkflowStepExecutionRepository,
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

import '../server.dart'
    show ServerChannelDeps, ServerCoreDeps, ServerObservabilityDeps, ServerTaskDeps, ServerTurnDeps, ServerWebDeps;
import '../server_composition.dart';
import '../restart_service.dart' show consumeRestartPending;
import 'channel_wiring.dart';
import 'harness_wiring.dart';
import 'scheduling_wiring.dart';
import 'security_wiring.dart';
import 'storage_wiring.dart';
import 'task_wiring.dart';
import 'project_wiring.dart';

part 'service_wiring_workflow.dart';
part 'service_wiring_notifications.dart';
part 'service_wiring_mcp_tools.dart';
part 'service_wiring_result.dart';
part 'service_wiring_builder.dart';
part 'service_wiring_headless.dart';
part 'service_wiring_workflow_git.dart';

typedef PostMcpStartupHook = Future<void> Function(ChannelWiring channel);

/// The providers that present a credential, each mapped to the family whose
/// credential it presents.
///
/// A registrar-owned provider declaring `credentials_required: false` is
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

/// The assembled DartClaw runtime: every service `serve` needs, plus the
/// teardown that stops them.
///
/// Built by [build], which is the one entry point that assembles a runtime —
/// a caller outside the CLI app boots one without copying application code.
class DartclawRuntime {
  /// The HTTP/web/MCP surface, or `null` for a headless build.
  final DartclawServer? server;
  final Database searchDb;
  final AgentExecutionRepository agentExecutionRepository;
  final TaskService taskService;

  /// The primary interactive harness, or `null` when this build drives only
  /// coordinator workers, as standalone workflow execution does.
  final AgentHarness? harness;

  /// Execution allocation, or `null` in a lifecycle-only composition.
  ///
  /// See the class doc for the two build shapes: a lifecycle-only build
  /// composes no security or harness layer at all, so nothing here can lease a
  /// worker, reset provider continuity, or record a learning.
  final ExecutionCoordinator? executions;
  final ScheduleService? scheduleService;
  final KvService kvService;

  /// Provider-side continuity reset, or `null` in a lifecycle-only composition.
  final SessionResetService? resetService;

  /// Agent-authored learnings and error records, or `null` in a lifecycle-only
  /// composition.
  final SelfImprovementService? selfImprovement;
  final QmdManager? qmdManager;
  final ChannelManager? channelManager;
  final bool authEnabled;

  /// Whether this composition actually isolates execution, after an inferred
  /// posture wiring could not honour was corrected.
  final bool containerIsolationActive;
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
  final SessionService sessionService;
  final MessageService messageService;
  final WorkflowStepExecutionRepository workflowStepExecutionRepository;

  /// Manages this runtime's task and workflow worktrees, rooted at the
  /// repository the runtime operates on.
  final WorktreeManager worktreeManager;

  /// The queue consumer that runs tasks and workflow steps, or `null` in a
  /// lifecycle-only composition, which dispatches nothing.
  final TaskExecutor? taskExecutor;

  /// Workflow registry populated by [build]. Exposed so tests can assert that
  /// the shipped built-in workflow definitions (`plan-and-implement`,
  /// `spec-and-implement`, `code-review`) register against the runtime skill
  /// registry.
  final WorkflowRegistry workflowRegistry;

  /// The workflow orchestrator shared by in-`serve` and headless builds. Exposed
  /// so tests can assert on its provider-auth preflight; step execution itself
  /// leases a coordinator worker from [executions].
  final WorkflowService workflowService;

  /// The environment the skill-introspection and auth probes spawn the vendor
  /// CLI with, for [providerId].
  ///
  /// Both probes spawn through `SafeProcess.run` with no injectable starter, so
  /// there is no process seam downstream to observe what they were handed.
  @visibleForTesting
  final Future<Map<String, String>> Function(String providerId) providerProbeEnvironment;

  static final _log = Logger('DartclawRuntime');

  const new({
    required this.server,
    required this.searchDb,
    required this.agentExecutionRepository,
    required this.taskService,
    required this.harness,
    required this.executions,
    required this.scheduleService,
    required this.kvService,
    required this.resetService,
    required this.selfImprovement,
    required this.qmdManager,
    required this.channelManager,
    required this.authEnabled,
    required this.containerIsolationActive,
    required this.tokenService,
    required this.eventBus,
    required this.containerAuthorities,
    required this.shutdownExtras,
    this.prepareExecutionShutdown,
    required this.projectService,
    required this.configNotifier,
    this.outboundMcpPool,
    required this.sessionService,
    required this.messageService,
    required this.workflowStepExecutionRepository,
    required this.worktreeManager,
    required this.taskExecutor,
    required this.workflowRegistry,
    required this.workflowService,
    required this.providerProbeEnvironment,
  });

  /// Assembles the whole runtime from [config].
  ///
  /// This is the **full** build shape: every field below is non-null except the
  /// ones documented as surface-conditional. The other shape is
  /// **lifecycle-only**, reached through
  /// [HeadlessRuntimeStaging.completeForLifecycle], which composes no security
  /// or harness layer and therefore leaves [executions], [resetService],
  /// [selfImprovement] and [taskExecutor] null. Reading one of those on a
  /// lifecycle-only runtime is a composition error, not a state to handle: the
  /// verb that reached it cannot dispatch a step by construction.
  ///
  /// With [headless] left `false` this composes exactly what `serve` runs.
  /// With `headless: true` it constructs none of the inbound or scheduled
  /// surfaces — no [DartclawServer], channel manager, heartbeat, schedule
  /// service or token service — and the guarded execution, task and workflow
  /// stacks are assembled identically. [server] is non-null exactly when
  /// [headless] is false.
  ///
  /// [harnessRegistrars] contribute provider families this package does not
  /// name; the empty default composes exactly what a build with no registrar
  /// composes today. Either registrar member may throw to abort assembly
  /// fail-closed.
  static Future<DartclawRuntime> build(
    DartclawConfig config, {
    required String dataDir,
    required HarnessFactory harnessFactory,
    required SearchDbFactory searchDbFactory,
    required TaskDbFactory taskDbFactory,
    required WriteLine stderrLine,
    required ExitFn exitFn,
    required int port,
    required String resolvedConfigPath,
    required MessageRedactor messageRedactor,
    required ResolvedAssets resolvedAssets,
    bool headless = false,
    String? runtimeCwd,
    List<HarnessRegistrar> harnessRegistrars = const [],
    ServerFactory? serverFactory,
    PlatformCapabilities? platformCapabilities,
    OutboundMcpTransportFactory? outboundMcpTransportFactory,
    PostMcpStartupHook? postMcpStartupHook,
    bool runWorkflowSkillsBootstrap = true,
    bool preferSourceTreeAssets = false,
    Map<String, String>? skillProvisionerEnvironment,
    ProcessRunner? skillProvisionerProcessRunner,
    SkillIntrospector? skillIntrospector,
    ProviderAuthPreflight? providerAuthPreflight,
    RemotePushService? remotePushServiceOverride,
    PrCreator? prCreator,
    @visibleForTesting Map<String, String>? environment,
  }) => _assemblyFor(
    config,
    dataDir: dataDir,
    port: port,
    harnessFactory: harnessFactory,
    searchDbFactory: searchDbFactory,
    taskDbFactory: taskDbFactory,
    stderrLine: stderrLine,
    exitFn: exitFn,
    resolvedConfigPath: resolvedConfigPath,
    messageRedactor: messageRedactor,
    resolvedAssets: resolvedAssets,
    headless: headless,
    runtimeCwd: runtimeCwd,
    localRepositoryPosture: false,
    harnessRegistrars: harnessRegistrars,
    serverFactory: serverFactory,
    platformCapabilities: platformCapabilities,
    outboundMcpTransportFactory: outboundMcpTransportFactory,
    postMcpStartupHook: postMcpStartupHook,
    runWorkflowSkillsBootstrap: runWorkflowSkillsBootstrap,
    preferSourceTreeAssets: preferSourceTreeAssets,
    skillProvisionerEnvironment: skillProvisionerEnvironment,
    skillProvisionerProcessRunner: skillProvisionerProcessRunner,
    skillIntrospector: skillIntrospector,
    providerAuthPreflight: providerAuthPreflight,
    remotePushServiceOverride: remotePushServiceOverride,
    prCreator: prCreator,
    environment: environment,
  ).wire();

  /// Assembles the headless base services and stops there, so a caller can read
  /// the workflow registry and the persisted runs — and gate the providers a
  /// definition references — before any execution capacity is provisioned.
  ///
  /// This is the staging the zero-server `dartclaw workflow` lane needs: the
  /// provider-auth gate has to run between base-service assembly and execution
  /// assembly, and the provider set is only known once the definition resolves.
  /// It is the same assembly [build] runs, paused; it composes no second
  /// service graph. Complete it through [HeadlessRuntimeStaging], which owns
  /// teardown until it does.
  static Future<HeadlessRuntimeStaging> stageHeadless(
    DartclawConfig config, {
    required String dataDir,
    required HarnessFactory harnessFactory,
    required SearchDbFactory searchDbFactory,
    required TaskDbFactory taskDbFactory,
    required WriteLine stderrLine,
    required ExitFn exitFn,
    String? runtimeCwd,
    ResolvedAssets? resolvedAssets,
    MessageRedactor? messageRedactor,
    List<HarnessRegistrar> harnessRegistrars = const [],
    PlatformCapabilities? platformCapabilities,
    bool runWorkflowSkillsBootstrap = true,
    bool preferSourceTreeAssets = false,
    Map<String, String>? skillProvisionerEnvironment,
    ProcessRunner? skillProvisionerProcessRunner,
    SkillIntrospector? skillIntrospector,
    ProviderAuthPreflight? providerAuthPreflight,
    RemotePushService? remotePushServiceOverride,
    PrCreator? prCreator,

    /// The environment the dedicated credential stores and the skill
    /// provisioner resolve against. A production input here, unlike on [build]:
    /// the zero-server lane is its own process and passes the one it was
    /// invoked with.
    Map<String, String>? environment,
  }) async {
    final assembly = _assemblyFor(
      config,
      dataDir: dataDir,
      port: 0,
      harnessFactory: harnessFactory,
      searchDbFactory: searchDbFactory,
      taskDbFactory: taskDbFactory,
      stderrLine: stderrLine,
      exitFn: exitFn,
      resolvedConfigPath: '',
      messageRedactor: messageRedactor,
      resolvedAssets: resolvedAssets,
      headless: true,
      runtimeCwd: runtimeCwd,
      localRepositoryPosture: true,
      harnessRegistrars: harnessRegistrars,
      platformCapabilities: platformCapabilities,
      runWorkflowSkillsBootstrap: runWorkflowSkillsBootstrap,
      preferSourceTreeAssets: preferSourceTreeAssets,
      skillProvisionerEnvironment: skillProvisionerEnvironment,
      skillProvisionerProcessRunner: skillProvisionerProcessRunner,
      skillIntrospector: skillIntrospector,
      providerAuthPreflight: providerAuthPreflight,
      remotePushServiceOverride: remotePushServiceOverride,
      prCreator: prCreator,
      environment: environment,
    );
    await assembly.wireBase();
    return HeadlessRuntimeStaging._(assembly);
  }

  static _RuntimeAssembly _assemblyFor(
    DartclawConfig config, {
    required String dataDir,
    required int port,
    required HarnessFactory harnessFactory,
    required SearchDbFactory searchDbFactory,
    required TaskDbFactory taskDbFactory,
    required WriteLine stderrLine,
    required ExitFn exitFn,
    required String resolvedConfigPath,
    required MessageRedactor? messageRedactor,
    required ResolvedAssets? resolvedAssets,
    required bool headless,
    required String? runtimeCwd,
    required bool localRepositoryPosture,
    required List<HarnessRegistrar> harnessRegistrars,
    ServerFactory? serverFactory,
    PlatformCapabilities? platformCapabilities,
    OutboundMcpTransportFactory? outboundMcpTransportFactory,
    PostMcpStartupHook? postMcpStartupHook,
    required bool runWorkflowSkillsBootstrap,
    required bool preferSourceTreeAssets,
    Map<String, String>? skillProvisionerEnvironment,
    ProcessRunner? skillProvisionerProcessRunner,
    SkillIntrospector? skillIntrospector,
    ProviderAuthPreflight? providerAuthPreflight,
    RemotePushService? remotePushServiceOverride,
    PrCreator? prCreator,
    Map<String, String>? environment,
  }) => _RuntimeAssembly(
    config: config,
    dataDir: dataDir,
    port: port,
    harnessFactory: harnessFactory,
    searchDbFactory: searchDbFactory,
    taskDbFactory: taskDbFactory,
    stderrLine: stderrLine,
    exitFn: exitFn,
    resolvedConfigPath: resolvedConfigPath,
    messageRedactor: messageRedactor ?? MessageRedactor(extraPatterns: config.logging.redactPatterns),
    resolvedAssets: resolvedAssets,
    headless: headless,
    runtimeCwd: runtimeCwd,
    localRepositoryPosture: localRepositoryPosture,
    harnessRegistrars: harnessRegistrars,
    serverFactory: serverFactory,
    platformCapabilities: platformCapabilities,
    outboundMcpTransportFactory: outboundMcpTransportFactory,
    postMcpStartupHook: postMcpStartupHook,
    runWorkflowSkillsBootstrap: runWorkflowSkillsBootstrap,
    preferSourceTreeAssets: preferSourceTreeAssets,
    skillProvisionerEnvironment: skillProvisionerEnvironment,
    skillProvisionerProcessRunner: skillProvisionerProcessRunner,
    skillIntrospector: skillIntrospector,
    providerAuthPreflight: providerAuthPreflight,
    remotePushServiceOverride: remotePushServiceOverride,
    prCreator: prCreator,
    environment: environment,
  );

  /// Stops every service this runtime assembled, in dependency order, ending
  /// with the search database.
  ///
  /// Disposal of the services after the server is best-effort — each failure is
  /// logged and the remaining steps still run. A failure in the execution
  /// prepare-shutdown or the server shutdown propagates to the caller, which
  /// owns the overall shutdown deadline.
  Future<void> shutdown() async {
    scheduleService?.stop();
    resetService?.dispose();
    try {
      await prepareExecutionShutdown?.call();
      await server?.shutdown();
      await _disposeExtras();
    } finally {
      searchDb.close();
    }
  }

  Future<void> _disposeExtras() async {
    Future<void> attempt(String label, Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        _log.warning('Cleanup error during $label', error, stackTrace);
      }
    }

    await attempt('shutdownExtras', shutdownExtras);
    await attempt('kvService.dispose', kvService.dispose);
    final selfImprovement = this.selfImprovement;
    if (selfImprovement != null) {
      await attempt('selfImprovement.dispose', selfImprovement.dispose);
    }
    await attempt('taskService.dispose', taskService.dispose);
    await attempt('eventBus.dispose', eventBus.dispose);
    await attempt('qmdManager.stop', () async => await qmdManager?.stop());
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

/// Cross-cutting deps threaded through the assembly's `_wireXxx` methods.
///
/// Late slots (serverRef, serverTurns) are bound via setters as construction
/// proceeds; closures capture them via getters so late-binding order is
/// preserved across method boundaries.
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

  /// Bound when the server is composed. A headless build composes none, so the
  /// surfaces that need one resolve through [composedServerGetter], which
  /// refuses, while the ones that merely may have one read [serverRefGetter].
  DartclawServer? _serverRef;
  late TurnManager _serverTurns;

  /// The provider entries the composed harness registrars declared, bound once
  /// the harness is wired.
  ///
  /// The probe lane resolves through these so a registrar-owned provider is
  /// probed under its own credential isolation rather than DartClaw's
  /// first-party arm. A lane that has not wired a harness yet — the staged
  /// headless provider-auth preflight — composed no registrar either, so an
  /// empty map is the honest answer rather than a missing one.
  Map<String, ProviderEntry> registeredProviderEntries = const {};

  /// The credential overlay those registrations present, bound with them.
  Map<String, String>? Function(String, Map<String, String>)? registrarCredentialOverlay;

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

  DartclawServer? Function() get serverRefGetter =>
      () => _serverRef;
  DartclawServer Function() get composedServerGetter =>
      () => _serverRef ?? (throw StateError('This runtime composed no server'));
  TurnManager Function() get turnManagerGetter =>
      () => _serverTurns;
}

/// Thin coordinator that composes domain-specific wiring modules in dependency
/// order and produces the [DartclawRuntime].
///
/// Domain modules ([StorageWiring], [SecurityWiring], [HarnessWiring],
/// [ChannelWiring], [TaskWiring], [SchedulingWiring]) own service construction.
/// This class threads cross-domain dependencies and performs the final server
/// composition and MCP tool registration.
class _RuntimeAssembly {
  /// Not final: [_correctPostureIfDowngraded] settles an inferred posture
  /// wiring could not honour, keeping one authority for every later reader.
  DartclawConfig config;
  final String dataDir;
  final int port;
  final HarnessFactory harnessFactory;
  final ServerFactory serverFactory;
  final bool headless;
  final List<HarnessRegistrar> harnessRegistrars;
  final SearchDbFactory searchDbFactory;
  final TaskDbFactory taskDbFactory;
  final WriteLine stderrLine;
  final ExitFn exitFn;
  final String resolvedConfigPath;
  final MessageRedactor messageRedactor;
  final ResolvedAssets resolvedAssets;
  final PlatformCapabilities platformCapabilities;

  /// The repository this build operates on — the invocation cwd.
  ///
  /// Worktree placement, diff generation, the local-project fallback and the
  /// workflow output root all key off it. `serve` reads the same value it read
  /// as `Directory.current.path`; a headless caller injects one so a run
  /// started from a repository other than the launch directory still roots
  /// there.
  final String runtimeCwd;

  /// The directory a workflow run falls back to when it resolves no project —
  /// non-null only for the zero-server lane, and the one arm that selects its
  /// local-repository posture: worktree root, workflow output root, publish
  /// strategy, and the source-tree asset precedence a checkout run expects.
  final String? localFallbackDir;

  /// Inverts asset precedence so the live source tree wins over the embedded
  /// built-ins, for skills and workflow YAML alike. The maintainer profile
  /// depends on it; every other caller leaves it `false`.
  final bool preferSourceTreeAssets;

  final SkillIntrospector? skillIntrospector;
  final ProviderAuthPreflight? providerAuthPreflight;
  final RemotePushService? remotePushServiceOverride;
  final PrCreator? prCreatorOverride;

  /// The providers execution capacity is provisioned for, or `null` for every
  /// configured provider plus the primary lane. Bound at completion, because
  /// the zero-server lane only knows the set after its definition resolves.
  Set<String>? _workflowProviderScope;
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

  // Base-phase products, bound by [wireBase] and consumed by whichever
  // completion the caller chooses.
  late final _WiringContext _ctx;
  late final ProjectWiring _project;
  late final StorageWiring _storage;
  late final WorkflowRegistry _workflowRegistry;
  bool _baseWired = false;

  void _requireBaseWired() {
    if (!_baseWired) throw StateError('Runtime completion requested before base services were wired');
  }

  static final _log = Logger('DartclawRuntime');

  new({
    required this.config,
    required this.dataDir,
    required this.port,
    required this.harnessFactory,
    required this.searchDbFactory,
    required this.taskDbFactory,
    required this.stderrLine,
    required this.exitFn,
    required this.resolvedConfigPath,
    required this.messageRedactor,
    required ResolvedAssets? resolvedAssets,
    this.headless = false,
    String? runtimeCwd,
    bool localRepositoryPosture = false,
    this.harnessRegistrars = const [],
    ServerFactory? serverFactory,
    PlatformCapabilities? platformCapabilities,
    this.outboundMcpTransportFactory,
    PostMcpStartupHook? postMcpStartupHook,
    this.runWorkflowSkillsBootstrap = true,
    this.preferSourceTreeAssets = false,
    this.skillProvisionerEnvironment,
    this.skillProvisionerProcessRunner,
    this.skillIntrospector,
    this.providerAuthPreflight,
    this.remotePushServiceOverride,
    PrCreator? prCreator,
    @visibleForTesting Map<String, String>? environment,
  }) : serverFactory = serverFactory ?? _identityServerFactory,
       platformCapabilities = platformCapabilities ?? PlatformCapabilities(),
       _environment = environment ?? Platform.environment,
       runtimeCwd = runtimeCwd ?? Directory.current.path,
       localFallbackDir = localRepositoryPosture ? (runtimeCwd ?? Directory.current.path) : null,
       resolvedAssets =
           resolvedAssets ?? const AssetResolver().resolveAssets(const AssetResolutionRequest.noConfiguredAssets()),
       prCreatorOverride = prCreator,
       postMcpStartupHook = postMcpStartupHook ?? _startSpaceEvents;

  static DartclawServer _identityServerFactory(DartclawServer server) => server;

  /// The base services a workflow definition can be resolved against: storage,
  /// projects and the workflow registry, with no execution capacity and no
  /// harness.
  ///
  /// Split out so the zero-server lane can gate provider auth between here and
  /// [completeWithExecution]; `serve` runs both back to back.
  Future<void> wireBase() async {
    final builtInSkillsSourceDir = _builtInSkillsSourceDir(resolvedAssets);

    // 0.5. Skill bootstrap – must run before workflow execution so native
    // DartClaw skills are on disk for provider introspection and invocation,
    // and before the registry so a definition naming a missing skill is
    // excluded at load rather than failing mid-run.
    await _wireWorkflowSkillsBootstrap(builtInSkillsSourceDir);
    // Opened once, before any consumer, so the login-collision guard runs
    // ahead of every credential read this deployment performs.
    final subscriptions = _openSubscriptionStore();
    final ctx = _WiringContext(
      eventBus: EventBus(),
      configNotifier: ConfigNotifier(
        config,
        platformCapabilities: platformCapabilities,
        // A registrar's section is parsed outside `dartclaw_kernel`, so a
        // reload triggered through the config API — which loads without the
        // composition root's prime — would otherwise be judged on a config
        // whose section warnings had never been raised.
        sectionPrimers: [for (final registrar in harnessRegistrars) registrar.primeConfigSections],
      ),
      dataDir: dataDir,
      port: port,
      resolvedAssets: resolvedAssets,
      builtInSkillsSourceDir: builtInSkillsSourceDir,
      messageRedactor: messageRedactor,
      subscriptions: subscriptions,
      codexRefresh: CodexRefreshAuthority(
        store: subscriptions,
        vendorRefresh: (codexHome) => refreshCodexAuth(codexHome, executable: resolveCodexVendorExecutable(config)),
      ),
    );
    _ctx = ctx;
    // 0. Projects
    _project = await _wireProjects(ctx);
    // 1. Storage
    _storage = await _wireStorage(ctx);
    // 2. Workflow registry – usable before any execution capacity exists, so a
    // caller can resolve the definition whose providers it is about to gate.
    _workflowRegistry = await _wireWorkflowRegistry(ctx, workflowRoleDefaultsFromConfig(config));
    _baseWired = true;
  }

  Future<DartclawRuntime> wire() async {
    await wireBase();
    return completeWithExecution(null);
  }

  /// Finishes the assembly with provider execution capacity for
  /// [workflowProviderScope], or for every configured provider plus the primary
  /// lane when it is `null`.
  Future<DartclawRuntime> completeWithExecution(Set<String>? workflowProviderScope) async {
    _requireBaseWired();
    _workflowProviderScope = workflowProviderScope;
    final ctx = _ctx;
    final project = _project;
    final storage = _storage;
    final workflowRegistry = _workflowRegistry;
    // 3. Security
    final agentDefs = config.agent.definitions.isNotEmpty ? config.agent.definitions : [AgentDefinition.searchAgent()];
    final security = await _wireSecurity(ctx, agentDefs);
    _correctPostureIfDowngraded(security);
    // 4. Harness
    final harness = await _wireHarness(ctx, storage, security);
    // 5. Tasks (pre-server)
    final task = await _wirePreServerTasks(ctx, storage, project);
    // Injected before the channels are wired: it rebuilds the review handler
    // ChannelWiring.wire captures by value, so a later injection would leave
    // the chat review path on a delivery-less service.
    task.setPushBackFeedbackDelivery(_pushBackFeedbackDelivery(ctx, storage));
    // 5. Channels – an ingress surface, so a headless build has none.
    final channel = headless ? null : await _wireChannels(ctx, storage, task, harness);
    final alertRouter = channel == null ? null : _wireAlertRouter(ctx, storage, channel);
    // 6. Turn manager – restart sentinel, provider status, turn composition
    _wireRestartSentinel(ctx);
    final providerStatus = await _wireProviderStatus(ctx, harness, security);
    ctx.bindTurns(_composeTurns(config, ctx, storage, harness, security));
    // The sweep runs on the primary runner's state; a workflow-only build
    // has no primary lane and no long-lived turns to orphan.
    if (harness.executions.primary != null) {
      await ctx._serverTurns.detectAndCleanOrphanedTurns();
    }
    // 7. Tasks (post-server)
    await task.wirePostServer(
      turns: ctx._serverTurns,
      executions: harness.executions,
      policyResolver: harness.policyResolver,
    );
    final workflowRoleDefaults = workflowRoleDefaultsFromConfig(config);
    final workflowService = await _wireWorkflowService(ctx, storage, task, project, workflowRoleDefaults);
    final lifecycleManager = channel == null ? null : await _wireThreadBinding(ctx, storage, channel);
    // 8. Scheduling
    final credentialHealth = _wireCredentialHealth(ctx, harness, providerStatus);
    // Bound here rather than constructed with the security and harness layers:
    // the monitor needs the ProviderStatusService the API reads, which exists
    // only once the provider status probe has run. Both active boundaries
    // announce through it: the container via the gateway and host workers via
    // HarnessWiring admission and dedicated-home preparation. TaskWiring is
    // bound only for its retained, active-step-unreachable CLI compatibility
    // cluster. The probe lane reports through the assembly-level sink.
    security.credentialHealth = credentialHealth;
    harness.credentialHealth = credentialHealth;
    _credentialHealth = credentialHealth;
    final scheduling = channel == null
        ? null
        : await _wireScheduling(ctx, storage, channel, harness, security, credentialHealth);
    final scopeReconciler = _wireScopeReconciler(ctx);
    final groupSessionInit = channel == null ? null : await _wireGroupSessionInit(ctx, storage, channel);

    DartclawServer? server;
    OutboundMcpPool? outboundMcpPool;
    if (channel != null && scheduling != null) {
      // Constructed inside the branch that consumes it: the writer opens a
      // stream subscription and only the server disposes it, so a build that
      // composes no server must not create one.
      //
      // One instance for both the config API and the scheduling-mutation seam
      // the MCP tools consume — two would keep two backup timestamps.
      final configWriter = config_tools.ConfigWriter(configPath: resolvedConfigPath);
      server = serverFactory(
        _composeRuntimeServer(
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
          _buildRestartService(ctx, harness),
          channel,
          security,
          configWriter,
        ),
      );
      ctx.bindServer(server);
      outboundMcpPool = await _registerMcpTools(
        config,
        ctx,
        server,
        harness,
        storage,
        security,
        task,
        channel.threadBindingStore,
        scheduling,
        workflowRegistry,
        workflowService,
        configWriter,
        outboundMcpTransportFactory: outboundMcpTransportFactory,
      );
      try {
        await postMcpStartupHook(channel);
      } catch (error, stackTrace) {
        try {
          await outboundMcpPool?.close();
        } catch (closeError, closeStackTrace) {
          _log.warning(
            'Failed to close outbound MCP pool after startup error: $closeError',
            closeError,
            closeStackTrace,
          );
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
    return _assembleRuntime(
      ctx,
      (providerId) => _providerProbeEnvironment(ctx, providerId),
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
      outboundMcpPool,
      trackedWorkflowGitCleanup: _trackedWorkflowGitCleanup(storage, project, workflowService),
    );
  }

  /// The teardown sweep for the zero-server lane, or `null` for a build whose
  /// repository outlives it.
  Future<void> Function()? _trackedWorkflowGitCleanup(
    StorageWiring storage,
    ProjectWiring project,
    WorkflowService workflowService,
  ) {
    final localDir = localFallbackDir;
    if (localDir == null) return null;
    return () => cleanupTrackedWorkflowGit(
      taskService: storage.taskService,
      workflowService: workflowService,
      projectService: project.projectService,
      localFallbackDir: localDir,
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

  /// Where the built-in DartClaw skills are provisioned from.
  ///
  /// `serve` takes what its resolved assets name. A zero-server run is started
  /// from a checkout, so a source tree beside it is a legitimate source too —
  /// and [preferSourceTreeAssets] makes it the preferred one, which is what
  /// lets edits to checked-out skills take effect without a rebuild.
  String? _builtInSkillsSourceDir(ResolvedAssets resolvedAssets) {
    final assetSkillsDir = resolvedAssets.skillsDir;
    if (localFallbackDir == null) return assetSkillsDir;
    final sourceSkillsDir = WorkflowAssetSourceResolver.resolveBuiltInSkillsSourceDir();
    return preferSourceTreeAssets ? (sourceSkillsDir ?? assetSkillsDir) : (assetSkillsDir ?? sourceSkillsDir);
  }

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
      fallbackWorkspaceDir: localFallbackDir,
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

  /// Settles the posture where it is first knowable: an inferred
  /// `container.enabled` is a prediction and wiring is where it can decline.
  /// Left in force it gives two answers to "is this deployment isolated", and
  /// every later reader acts on a boundary nothing registered.
  void _correctPostureIfDowngraded(SecurityWiring security) {
    if (!config.container.enabled || security.containersEnabled) return;
    config = config.copyWith(container: config.container.resolved(enabled: false));
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
      // server is built, while authorities are created at turn time. A headless
      // build never builds one, so the gateway refuses a bridged-MCP grant with
      // its own message instead of resolving an unbound reference.
      mcpHandlerRef: headless ? null : () => ctx.composedServerGetter().mcpHandler,
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
      headless: headless,
      workflowProviderScope: _workflowProviderScope,
      harnessRegistrars: harnessRegistrars,
    );
    // Server ref resolved lazily – closures in harness capture the getter.
    await harness.wire(serverRefGetter: ctx.serverRefGetter);
    ctx.registeredProviderEntries = harness.registeredProviderEntries;
    ctx.registrarCredentialOverlay = harness.registrarCredentialOverlay;
    return harness;
  }

  Future<TaskWiring> _wirePreServerTasks(_WiringContext ctx, StorageWiring storage, ProjectWiring project) async {
    final task = TaskWiring(
      config: config,
      dataDir: ctx.dataDir,
      runtimeCwd: runtimeCwd,
      localFallbackDir: localFallbackDir,
      remotePushServiceOverride: remotePushServiceOverride,
      eventBus: ctx.eventBus,
      storage: storage,
      project: project,
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
      serverRefGetter: ctx.composedServerGetter,
      turnManagerGetter: ctx.turnManagerGetter,
      sseBroadcast: harness.sseBroadcast,
      messageRedactor: ctx.messageRedactor,
      healthService: harness.primaryHealthService,
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
    final pending = consumeRestartPending(ctx.dataDir);
    if (pending == null) return;
    final rawFields = pending['fields'];
    final fields = rawFields is List ? rawFields.join(', ') : null;
    stderrLine(fields == null ? 'Restarted after config change' : 'Restarted after config change (pending: $fields)');
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
    return buildProviderProbeEnvironment(
      target: resolveProviderTarget(config, providerId, registeredProviders: ctx.registeredProviderEntries),
      registry: _credentialRegistry(ctx),
      baseEnvironment: Platform.environment,
      codexRefresh: ctx.codexRefresh,
      credentialsDir: config.credentialsDir,
      onCredentialHealth: _reportProbeCredentialHealth,
      registrarOverlay: ctx.registrarCredentialOverlay,
    );
  }

  /// Announces a probe-lane Codex credential condition through the deployment's
  /// single credential-health writer.
  ///
  /// The probes run the vendor CLI on the host, so their refusals reach no
  /// gateway; and the hourly probe drives no refresh, so a spent or unreachable
  /// refresh lineage discovered while preparing a probe's dedicated `CODEX_HOME`
  /// would otherwise produce no credential-health event at all. The severe
  /// line is the required degradation while no monitor is bound — probes run after
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
        // Only the zero-server lane has one: a workflow step's declared output
        // is validated against the repository the run was invoked in.
        defaultWorkspaceRoot: localFallbackDir,
        hydrateBinding: task.taskExecutor.hydrateWorkflowSharedWorktreeBinding,
      ),
      options: WorkflowServiceOptions(
        bashStepEnvAllowlist: config.security.bashStep.envAllowlist,
        bashStepExtraStripPatterns: config.security.bashStep.extraStripPatterns,
        roleDefaults: workflowRoleDefaults,
        approvalPolicyDefault: config.workflow.approvals,
        structuredOutputFallbackRecorder: storage.taskEventRecorder.recordStructuredOutputFallbackUsed,
        skillIntrospector:
            skillIntrospector ?? _buildSkillIntrospector(ctx, (id) => _providerProbeEnvironment(ctx, id)),
        // The in-engine backstop is inert without this, so an in-`serve`
        // workflow step assigned to a provider with no usable credential would
        // otherwise acquire its coordinator worker ungated. The standalone lane injects the
        // same preflight; both must gate or the two lanes disagree.
        //
        // The registry is resolved per evaluation, like HarnessWiring's worker
        // creation behind this gate: a boot-time snapshot would refuse a step
        // whose newly stored credential the coordinator worker would use.
        providerAuthPreflight: _resolveProviderAuthPreflight(ctx),
        skillPreflightConfig: _buildSkillPreflightConfig(),
      ),
      turnAdapter: _buildWorkflowTurnAdapter(
        config,
        ctx,
        storage,
        task,
        project,
        localFallbackDir: localFallbackDir,
        prCreator: prCreatorOverride,
      ),
      eventBus: ctx.eventBus,
      kvService: storage.kvService,
      dataDir: ctx.dataDir,
    );
    await workflowService.recoverIncompleteRuns();
    return workflowService;
  }

  Future<WorkflowRegistry> _wireWorkflowRegistry(_WiringContext ctx, WorkflowRoleDefaults workflowRoleDefaults) async {
    // Capability probes only (`cwd: '/'`, no spawn), so the registry loads
    // before any execution capacity exists.
    final continuityProviders = harnessFactory.probeContinuityProviders();
    await WorkflowMaterializer.materialize(
      dataDir: ctx.dataDir,
      sourceDir: ctx.resolvedAssets.workflowsDir,
      preferSourceTree: preferSourceTreeAssets,
      // A zero-server run is started from the checkout it operates on, so a
      // source tree beside it is a legitimate definition source; `serve` takes
      // only what its resolved assets name.
      discoverSourceTree: localFallbackDir != null,
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

  Future<ThreadBindingLifecycleManager?> _wireThreadBinding(
    _WiringContext ctx,
    StorageWiring storage,
    ChannelWiring channel,
  ) async {
    final threadBindingStore = channel.threadBindingStore;
    if (threadBindingStore == null) return null;

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

    return lifecycleManager;
  }

  /// Delivers push-back feedback as a new turn on the task's own session.
  ///
  /// A closure rather than a bound reference: the composed server is bound
  /// after this runs, so resolving it eagerly would throw at wiring time.
  PushBackFeedbackDelivery _pushBackFeedbackDelivery(_WiringContext ctx, StorageWiring storage) {
    return ({required String taskId, required String sessionKey, required String feedback}) async {
      final session = await storage.sessions.getOrCreateByKey(sessionKey, type: SessionType.channel);
      final messages = [
        {'role': 'user', 'content': feedback},
      ];
      await ctx.composedServerGetter().turns.startTurn(
        session.id,
        messages,
        source: 'push-back',
        isHumanInput: true,
        promptScope: PromptScope.primary,
      );
    };
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

  /// Completes the assembly with a lifecycle-only workflow service.
  ///
  /// Persisted run state is mutable; nothing that could dispatch a step exists —
  /// no execution capacity, no task executor, no workflow CLI runner, and no
  /// turn seam, so an agent step refuses instead of spawning.
  Future<DartclawRuntime> completeLifecycleOnly() async {
    _requireBaseWired();
    _workflowProviderScope = const {};
    final ctx = _ctx;
    // Neither the security nor the harness layer is composed: nothing a
    // lifecycle verb does needs them, and composing them runs ACP validation
    // subprocesses and touches the container runtime, so a `cancel` could fail
    // over a misconfiguration it has no use for.
    final task = await _wirePreServerTasks(ctx, _storage, _project);
    final workflowService = WorkflowService.lifecycleOnly(
      repository: _storage.workflowRunRepository,
      taskService: _storage.taskService,
      messageService: _storage.messages,
      eventBus: ctx.eventBus,
      kvService: _storage.kvService,
      dataDir: ctx.dataDir,
      options: WorkflowServiceOptions(
        roleDefaults: workflowRoleDefaultsFromConfig(config),
        approvalPolicyDefault: config.workflow.approvals,
      ),
    );
    return _assembleRuntime(
      ctx,
      (providerId) => _providerProbeEnvironment(ctx, providerId),
      null,
      _storage,
      null,
      null,
      null,
      null,
      task,
      _project,
      _workflowRegistry,
      workflowService,
      null,
      null,
      _wireScopeReconciler(ctx),
      null,
      null,
    );
  }

  /// Tears down the base services when no completion ran — an aborted gate
  /// leaves open databases and a running project service behind otherwise.
  Future<void> disposeBase() async {
    if (!_baseWired) return;
    await _project.dispose();
    await _storage.kvService.dispose();
    // Closes the memory corpus, the turn-state store and both databases.
    await _storage.dispose();
    await _ctx.eventBus.dispose();
  }

  /// Gates [providers] before execution capacity is provisioned, raising
  /// [WorkflowPreflightException] with the provider-named remediation on the
  /// first unauthenticated one.
  ///
  /// This is the same gate `WorkflowServiceOptions.providerAuthPreflight`
  /// installs inside the engine, run early enough that a logged-out referenced
  /// provider aborts before any step dispatches.
  Future<void> preflightProviderAuth(Set<String> providers) async {
    _requireBaseWired();
    final preflight = _resolveProviderAuthPreflight(_ctx);
    for (final provider in providers.map(ProviderIdentity.normalize).toSet()) {
      final target = resolveProviderTarget(config, provider);
      final result = await preflight.evaluate(
        provider: provider,
        executable: target.executable,
        providerOptions: target.options,
      );
      if (!result.authenticated) {
        throw WorkflowPreflightException(
          result.remediationMessage ?? 'Workflow provider "$provider" is not authenticated.',
        );
      }
    }
  }

  ProviderAuthPreflight _resolveProviderAuthPreflight(_WiringContext ctx) =>
      providerAuthPreflight ??
      CliProviderAuthPreflight(
        credentials: () => _credentialRegistry(ctx),
        environmentForProvider: (providerId) => _providerProbeEnvironment(ctx, providerId),
        credentialsDir: config.credentialsDir,
      );

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
}
