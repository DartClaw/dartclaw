import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'container_authority_cleanup_owner.dart';

/// Constructs and exposes security-layer services.
///
/// Owns container setup (host gateway, container authority lifecycle, health
/// monitor), guard chain, content guard, audit subscriber, and session
/// lifecycle subscriber.
///
/// **Security reload seam** — two participants are registered with [ConfigNotifier]:
///
/// 1. This class implements [Reconfigurable] for `guards.*` — on reconfigure,
///    rebuilds all guard instances from the updated [SecurityConfig] and atomically
///    swaps the guard list in the existing [GuardChain] (fail-safe: invalid configs
///    preserve the current live chain).
/// 2. [MessageRedactor] participates via [_MessageRedactorAdapter], which bridges
///    the `dartclaw_kernel` → `dartclaw_core` package boundary by implementing
///    [Reconfigurable] on behalf of the redactor without adding a cross-package dep.
///
/// Both registrations happen in [wire], after [ConfigNotifier] is available.
class SecurityWiring implements Reconfigurable {
  new({
    required this.config,
    required String dataDir,
    required EventBus eventBus,
    required ExitFn exitFn,
    PlatformCapabilities? platformCapabilities,
    ConfigNotifier? configNotifier,
    MessageRedactor? messageRedactor,
    McpProtocolHandler Function()? mcpHandlerRef,
    Map<String, CredentialEntry> Function()? subscriptionCredentials,
    CodexRefreshAuthority? codexRefresh,
  }) : _dataDir = dataDir,
       _codexRefresh = codexRefresh,
       _subscriptionCredentials = subscriptionCredentials ?? _noSubscriptionCredentials,
       _mcpHandlerRef = mcpHandlerRef,
       _eventBus = eventBus,
       _exitFn = exitFn,
       _platformCapabilities = platformCapabilities ?? PlatformCapabilities(),
       _configNotifier = configNotifier,
       _messageRedactorForRegistration = messageRedactor;

  final DartclawConfig config;
  final String _dataDir;
  final EventBus _eventBus;
  final ExitFn _exitFn;
  final PlatformCapabilities _platformCapabilities;
  final ConfigNotifier? _configNotifier;
  final MessageRedactor? _messageRedactorForRegistration;

  /// Re-read per resolution rather than snapshotted at wiring time, so a
  /// re-issued token reaches the next mediated request without a restart.
  final Map<String, CredentialEntry> Function() _subscriptionCredentials;

  /// The only thing that rotates the dedicated Codex store, shared with the
  /// host lanes so DartClaw's own refreshes stay single-flight across both
  /// execution boundaries. `null` leaves mediation on whatever the store holds.
  final CodexRefreshAuthority? _codexRefresh;

  static Map<String, CredentialEntry> _noSubscriptionCredentials() => const {};

  /// Resolved lazily: the MCP handler exists only after the server is built,
  /// while authorities are created at turn time.
  final McpProtocolHandler Function()? _mcpHandlerRef;

  static final _log = Logger('SecurityWiring');

  HostGateway? _gateway;
  BridgeBinaryProvisioner? _bridgeBinaries;
  String? _bridgeBinaryPath;
  ContainerHealthMonitor? _containerHealthMonitor;
  final Map<String, _ContainerTemplate> _containerTemplates = {};
  final ContainerAuthorityCleanupOwner _containerAuthorities = ContainerAuthorityCleanupOwner();
  // Lets a credential failure raised on an authority's own pipe find the lease
  // that owns its container; entries live exactly as long as the lease does.
  final Map<String, ContainerAuthorityLease> _authorityLeases = {};
  // Authority suffixes must not repeat across process restarts: ContainerManager
  // adopts a healthy same-named container, so a recycled name could hand a new
  // authority an orphan from a previous run.
  final String _authorityEpoch = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  var _nextAuthorityId = 1;
  GuardChain? _guardChain;
  late GuardAuditLogger _auditLogger;
  ContentGuard? _contentGuard;
  ContentClassifier? _contentClassifier;
  ContentScan? _contentScan;
  bool _contentGuardFailOpen = false;
  late ToolPolicyCascade _toolPolicyCascade;
  GuardAuditSubscriber? _guardAuditSubscriber;
  SessionLifecycleSubscriber? _sessionLifecycleSubscriber;

  HostGateway? get gateway => _gateway;
  ContainerHealthMonitor? get containerHealthMonitor => _containerHealthMonitor;

  /// Whether this deployment can run container executions at all.
  bool get containersEnabled => _gateway != null;
  GuardChain? get guardChain => _guardChain;
  GuardAuditLogger get auditLogger => _auditLogger;
  ContentGuard? get contentGuard => _contentGuard;
  ContentClassifier? get contentClassifier => _contentClassifier;

  /// The one scan every classification site shares, or null when no classifier
  /// is configured — a null scan means "no classification", never an implicit block.
  ContentScan? get contentScan => _contentScan;
  bool get contentGuardFailOpen => _contentGuardFailOpen;
  ToolPolicyCascade get toolPolicyCascade => _toolPolicyCascade;

  /// Container profiles this deployment can actually run.
  Set<String> get availableContainerProfiles => _containerTemplates.keys.toSet();

  Map<String, CanonicalTool> _mcpToolCanonicals = const {};

  /// Binds the canonical-name mapping bridged MCP authorization uses.
  ///
  /// Harness wiring owns the mapping and sets it during its own wire, which
  /// still precedes any container authority.
  set mcpToolCanonicals(Map<String, CanonicalTool> value) => _mcpToolCanonicals = Map.unmodifiable(value);

  CredentialHealthMonitor? _credentialHealth;

  /// Binds the single credential-health writer, which is built several wiring
  /// steps after this class and cannot be a constructor argument.
  ///
  /// Until it is bound — the window before the monitor exists, and any
  /// composition that has none — the refusal and classification paths degrade
  /// to their log lines rather than losing the signal.
  set credentialHealth(CredentialHealthMonitor value) => _credentialHealth = value;

  /// The sink [HostGateway] announces every credential refusal through, both at
  /// admission and mid-turn.
  ///
  /// Exposed because the gateway itself only exists in a Docker-enabled
  /// deployment, and this seam must be provable without one.
  @visibleForTesting
  CredentialRefusalSink get credentialRefusalSink => _reportCredentialRefusal;

  /// The sink the mediated Codex credential source reports refresh outcomes
  /// through. Exposed for the same reason: the source is private to its adapter.
  @visibleForTesting
  void Function(CodexRefreshOutcome outcome) get codexRefreshOutcomeSink => _reportCodexRefreshOutcome;

  /// Creates a container dedicated to one live execution authority, with its
  /// host mediation established.
  ///
  /// Every admitted container execution gets its own container, process
  /// namespace, and bridge processes, so a later authority cannot inherit a
  /// predecessor's PIDs, temp files, generated home, or pipes. The lease is
  /// returned only after every required surface has handshaked and is
  /// listening — a turn never starts on a partial boundary.
  Future<ContainerAuthorityLease> acquireContainerAuthority(
    GatewayPrincipal principal, {
    Set<String> allowedMcpTools = const {},
    String? artifactsDir,
  }) async {
    final profileId = principal.containerProfile;
    final template = profileId == null ? null : _containerTemplates[profileId];
    final gateway = _gateway;
    if (template == null || gateway == null) {
      throw StateError('No container profile "$profileId" is available in this deployment');
    }

    final containerName = ContainerManager.generateName(_dataDir, '$profileId-$_authorityEpoch${_nextAuthorityId++}');
    final manager = template(
      containerName,
      generatedStateDir: p.join(_dataDir, 'containers', containerName),
      hasMcpBridge: allowedMcpTools.isNotEmpty,
      artifactsDir: artifactsDir,
    );
    // Registration rejects a provider this deployment cannot mediate – an
    // unusable Claude auth mode included – before any container is created.
    final authority = gateway.register(principal: principal, allowedMcpTools: allowedMcpTools);
    final lease = _containerAuthorities.own(
      _ContainerAuthorityLease(
        manager: manager,
        authority: authority,
        gateway: gateway,
        eventBus: _eventBus,
        monitor: _containerHealthMonitor,
        onReleased: () => _authorityLeases.remove(authority.id),
      ),
    );
    _authorityLeases[authority.id] = lease;
    try {
      await manager.start();
      _eventBus.fire(
        ContainerStartedEvent(
          profileId: manager.profileId,
          containerName: manager.containerName,
          timestamp: DateTime.now(),
        ),
      );
      _containerHealthMonitor?.watch(manager.containerName, manager, taskId: principal.taskId);
      for (final surface in authority.requiredSurfaces) {
        final channel = await manager.startBridge(surface, bridgePortFor(surface));
        try {
          gateway.attach(authority, surface, channel);
        } catch (_) {
          // Nothing owns the process until the pipe does.
          await channel.close();
          rethrow;
        }
      }
      await authority.ready.timeout(_bridgeReadyTimeout);
    } catch (_) {
      await lease.release();
      rethrow;
    }
    return lease;
  }

  /// How long a bridge has to handshake and start listening before the
  /// authority is abandoned. Startup is local process work, not model work.
  static const _bridgeReadyTimeout = Duration(seconds: 30);

  Future<void> wire({required List<AgentDefinition> agentDefs}) async {
    // Assigned before anything that can throw: dispose() flushes it, and a
    // partially-wired instance must still tear down cleanly.
    _auditLogger = GuardAuditLogger(dataDir: _dataDir);

    if (config.container.enabled) {
      if (!_platformCapabilities.containerIsolationAvailable) {
        const error = UnsupportedCapabilityError(
          capability: 'container isolation',
          attemptedContext: 'container.enabled: true on native Windows',
          remediation: 'Run DartClaw on POSIX (macOS/Linux) or inside WSL; native Windows isolation is unavailable.',
        );
        _log.severe(error.toString(), error);
        _exitFn(1);
      }
      final refusal = await _wireContainers();
      if (refusal != null) _warnHostAccess(refusal);
    } else if (_platformCapabilities.containerIsolationAvailable) {
      // Stated as a fact about this deployment rather than as a probe result:
      // the zero-server lane reaches here with the parsed posture, having run
      // no probe at all, and claiming one ran would simply be untrue there.
      _warnHostAccess(
        config.container.declaredEnabled == null
            ? 'no container runtime (${ContainerManager.runtimeBinaries.join(' or ')}) is in use on this host'
            : null,
      );
    } else {
      _log.warning(
        'Container isolation disabled — agent has full host access. '
        'Container isolation is unavailable on native Windows; '
        'run DartClaw on POSIX (macOS/Linux) or inside WSL for isolation.',
      );
    }

    _wireGuardChain(agentDefs);
    _wireAuditAndLifecycle();
    _wireContentGuard();

    // Register security-layer services with ConfigNotifier via adapters.
    // (dartclaw_kernel cannot depend on dartclaw_core — adapters bridge the gap.)
    if (_configNotifier != null) {
      if (_messageRedactorForRegistration != null) {
        final redactor = _messageRedactorForRegistration;
        _configNotifier.register(_MessageRedactorAdapter(redactor));
      }
      // Register self for guards.* hot-reload. Successful rebuilds swap the
      // entire guard list atomically.
      _configNotifier.register(this);
    }
  }

  // ---------------------------------------------------------------------------
  // Reconfigurable — security.* hot-reload (guards.* changes)
  // ---------------------------------------------------------------------------

  @override
  Set<String> get watchKeys => const {'security.*'};

  @override
  void reconfigure(ConfigDelta delta) {
    if (_guardChain == null) {
      _log.info('SecurityWiring: guards.* changed but guard chain is not active — skipping rebuild');
      return;
    }

    if (!delta.current.security.guards.enabled) {
      _log.warning(
        'SecurityWiring: guards.enabled changed to false — '
        'disabling guards requires a server restart to take effect safely',
      );
      return;
    }

    final result = buildGuardsFromConfig(
      securityConfig: delta.current.security,
      dataDir: _dataDir,
      toolPolicyCascade: _toolPolicyCascade,
    );

    switch (result) {
      case GuardBuildSuccess(:final guards):
        _guardChain!.replaceGuards(guards);
        _log.info('SecurityWiring: guard chain rebuilt (${guards.length} guards)');
      case GuardBuildFailure(:final errors):
        for (final e in errors) {
          _log.severe('SecurityWiring guard rebuild failed: $e');
        }
        _log.severe('SecurityWiring: guard chain NOT updated — preserving existing chain');
    }
  }

  /// The advisory-mode warning. [reason] names why this host has no OS
  /// boundary when one was inferred rather than declined outright.
  void _warnHostAccess(String? reason) {
    _log.warning(
      'Container isolation disabled — agent has full host access. '
      '${reason == null ? '' : 'This host is in advisory mode because $reason. '}'
      'Guards are the only security boundary; on Codex their host interception is bounded by the configured '
      'approval mode. '
      'Enable container isolation for production use (see docs/guide/security.md).',
    );
  }

  /// Wires container isolation, answering the refusal that stopped it or
  /// `null` once every profile is registered.
  ///
  /// The requested-vs-inferred asymmetry lives here and nowhere else: an
  /// operator who declared `container.enabled: true` gets every refusal
  /// fail-closed, while an inferred posture logs the same diagnosis and hands
  /// it back for advisory mode.
  Future<String?> _wireContainers() async {
    // Containerized Claude is mediated by the host adapter, which presents
    // either a stored subscription credential or a host-held API key — never
    // anything the container holds. This is a warning, not a startup failure: a
    // deployment may legitimately run only Codex or only host Claude. The
    // rejection itself happens at authority registration.
    if (!_resolveCredential(ProviderIdentity.claude).isPresent) {
      _log.warning(
        'No host-held Claude credential is configured – containerized Claude executions will be rejected. '
        'Run "claude setup-token" and store it with "dartclaw auth claude", set ANTHROPIC_API_KEY, '
        'or select execution: host for Claude agents.',
      );
    }

    final profiles = [
      SecurityProfile.workspace(
        workspaceDir: config.workspaceDir,
        projectDir: Directory.current.path,
        projectsClonesDir: config.projectsClonesDir,
      ),
      SecurityProfile.restricted,
    ];
    final localPathProjectMounts = _localPathProjectMounts();
    // A profile is a filesystem/capability template, not a running container:
    // each live container authority is built from it and owns its own
    // container, bridge processes, and generated state.
    ContainerManager buildManager(
      SecurityProfile profile,
      String containerName, {
      required String generatedStateDir,
      String? artifactsDir,
      bool hasMcpBridge = false,
    }) => ContainerManager(
      config: config.container,
      containerName: containerName,
      ownerLabel: ContainerManager.ownerLabel(_dataDir),
      profileId: profile.id,
      workspaceMounts: profile.id == 'workspace'
          ? [...profile.workspaceMounts, ...localPathProjectMounts]
          : profile.workspaceMounts,
      generatedStateDir: generatedStateDir,
      artifactsDir: artifactsDir,
      hasMcpBridge: hasMcpBridge,
      localPathAllowlist: config.projects.localPathAllowlist,
      bridgeBinaryPath: _bridgeBinaryPath,
      buildContextDir: Directory.current.path,
      workingDir: profile.id == SecurityProfile.restricted.id ? '/tmp' : '/project',
    );

    final probe = buildManager(
      SecurityProfile.restricted,
      'dartclaw-probe',
      generatedStateDir: p.join(_dataDir, 'containers', 'dartclaw-probe'),
    );
    final runtime = config.container.runtimeBinary;
    String refuse(String reason, [String? remediation]) {
      _log.severe('Container isolation cannot start: $reason');
      if (remediation != null) _log.severe(remediation);
      if (config.container.declaredEnabled == true) _exitFn(1);
      return reason;
    }

    if (!await probe.isRuntimeAvailable()) {
      return refuse('$runtime is required for container isolation', 'Install or start $runtime.');
    }
    await ContainerManager.reclaimOwnedContainers(_dataDir, runtimeBinary: runtime);
    try {
      await probe.ensureImage();
    } on StateError catch (error) {
      return refuse('the container image could not be built (${error.message})');
    }

    final architecture = await probe.serverArchitecture();
    if (architecture == null) {
      return refuse('the $runtime engine reports an architecture no container bridge binary ships for');
    }
    _bridgeBinaries = BridgeBinaryProvisioner(dataDir: _dataDir);
    try {
      _bridgeBinaryPath = await _bridgeBinaries!.ensureAvailable(architecture);
    } on StateError catch (error) {
      return refuse(error.message.toString());
    }

    for (final profile in profiles) {
      _containerTemplates[profile.id] =
          (containerName, {required generatedStateDir, required hasMcpBridge, required artifactsDir}) => buildManager(
            profile,
            containerName,
            generatedStateDir: generatedStateDir,
            artifactsDir: artifactsDir,
            hasMcpBridge: hasMcpBridge,
          );
    }

    _containerHealthMonitor = ContainerHealthMonitor(eventBus: _eventBus)..start();
    _gateway = HostGateway(
      providerAdapters: buildProviderAdapters(),
      mcpHandler: _mcpHandlerRef,
      mcpToolCanonicals: () => _mcpToolCanonicals,
      onDenied: _auditGatewayDenial,
      onCredentialRefused: _reportCredentialRefusal,
      onCredentialUnusable: _tearDownAuthority,
    );

    _log.info(
      'Container isolation enabled on $runtime — ${_containerTemplates.length} profiles, host-mediated '
      'linux-$architecture bridge (image: ${config.container.image})',
    );
    return null;
  }

  /// Builds the provider mediation adapters this deployment's gateway installs,
  /// keyed by the provider id an execution actually names.
  ///
  /// One adapter per mediable provider id rather than one per family: a
  /// container authority registers under the id its execution names, and the
  /// credential it presents must come from *that* entry's `providers.<id>.auth`
  /// — a family-keyed adapter would mediate an alias on the family's selection
  /// and silently ignore an opt-out the host spawn path honors.
  ///
  /// Exposed so a test can assert what a configuration actually presents
  /// upstream without standing up Docker.
  @visibleForTesting
  Map<String, ProviderMediator> buildProviderAdapters() {
    // The two canonical ids are always mediable: a deployment that configures
    // no `providers` entry at all still runs them.
    final providerIds = {
      ProviderIdentity.claude,
      ProviderIdentity.codex,
      ...config.providers.entries.keys.map(ProviderIdentity.normalize),
    };
    return {for (final providerId in providerIds) providerId: ?_buildProviderAdapter(providerId)};
  }

  /// The adapter mediating [providerId], or `null` for a provider family this
  /// build speaks no protocol for — which stays a registration refusal rather
  /// than becoming an unmediated container.
  ProviderMediator? _buildProviderAdapter(String providerId) {
    final entry = config.providers[providerId];
    // resolveFamily, not family: plain normalization reads an alias as its own
    // family, which is how an aliased Claude provider ends up resolving no
    // credential at all.
    final family = ProviderIdentity.resolveFamily(providerId, options: entry?.options, executable: entry?.executable);
    // Each adapter owns its fixed upstreams. Nothing downstream — least of all a
    // container — can retarget one, and there is deliberately no configuration
    // knob to point a credentialed adapter somewhere else.
    return switch (family) {
      ProviderIdentity.claude => AnthropicMessagesAdapter(
        providerId: providerId,
        credentialsDir: config.credentialsDir,
        credential: ProviderCredentialSource(() => _resolveCredential(providerId, family: family)),
      ),
      ProviderIdentity.codex => OpenAiResponsesAdapter(
        providerId: providerId,
        credentialsDir: config.credentialsDir,
        credential: CodexCredentialSource(
          providerId: providerId,
          resolve: () => _resolveCredential(providerId, family: family),
          authority: _codexRefresh,
          onRefreshOutcome: (outcome) => _reportCodexRefreshOutcome(outcome, providerId: providerId),
        ),
        onRejection: (rejection) => _reportCodexRejection(rejection, providerId: providerId),
      ),
      _ => null,
    };
  }

  void _reportCodexRefreshOutcome(CodexRefreshOutcome outcome, {String providerId = ProviderIdentity.codex}) {
    switch (outcome) {
      case CodexCredentialPresented():
        break;
      case CodexCredentialRotatedAway():
        // Losing the rotation race is the designed outcome of concurrent
        // demand on a one-time-use token, not a degradation to announce.
        _log.fine('Codex credential was rotated by another writer; continuing on the current token');
      case CodexReauthRequired(:final detail, :final remediation):
        _reportCodexCredentialHealth(
          detail,
          providerId: providerId,
          state: CredentialHealthState.reauthRequired,
          remediation: remediation,
        );
      case CodexRefreshFailed(:final detail):
        _reportCodexCredentialHealth(detail, providerId: providerId, state: CredentialHealthState.refreshFailure);
    }
  }

  void _reportCodexRejection(CodexRejection rejection, {String providerId = ProviderIdentity.codex}) {
    // A plan limit resets on its own and a rejected model is a configuration
    // choice: neither says anything about the credential, and reporting either
    // as credential health would page the operator to re-authenticate one that
    // works. Both still reach the operator through the log below.
    final state = switch (rejection.kind) {
      CodexRejectionKind.authExpired => CredentialHealthState.reauthRequired,
      CodexRejectionKind.contractBreak => CredentialHealthState.contractBreak,
      CodexRejectionKind.usageLimit || CodexRejectionKind.modelUnsupported => null,
    };
    _reportCodexCredentialHealth(rejection.describe(), providerId: providerId, state: state);
  }

  /// The one place a Codex credential signal leaves the mediation adapters.
  ///
  /// A [state] reports through the single credential-health writer, which owns
  /// the transition dedup, the alert and the provider-status update — so a
  /// refresh outage announces once rather than once per mediated request. A
  /// null [state], or an unbound monitor, falls back to the log line:
  /// credential health must degrade rather than go silent.
  void _reportCodexCredentialHealth(
    String detail, {
    required String providerId,
    CredentialHealthState? state,
    String? remediation,
  }) {
    final monitor = _credentialHealth;
    if (state == null || monitor == null) {
      _log.warning('Provider "$providerId": $detail${remediation == null ? '' : ' $remediation'}');
      return;
    }
    monitor.report(providerId: providerId, state: state, detail: detail, remediation: remediation);
  }

  /// Resolves what the host presents for [providerId], honoring
  /// `providers.<id>.auth` and the dedicated subscription stores.
  ///
  /// [family] is the provider's resolved credential family, so an alias reads
  /// its own `auth` first and inherits the family's only when it sets none.
  CredentialResolution _resolveCredential(String providerId, {String? family}) => CredentialRegistry(
    credentials: config.credentials,
    env: Platform.environment,
    providers: config.providers,
    subscriptions: _subscriptionCredentials(),
  ).resolve(providerId, family: family);

  /// Announces a credential the host cannot present, at the point of refusal.
  ///
  /// Every refusal path meets the operator here, so the announcement is one
  /// decision rather than one per detecting path. A refused credential is one
  /// the operator must re-authenticate, so it enters the credential-health
  /// writer as [CredentialHealthState.reauthRequired]; that writer dedups the
  /// transition and updates the provider cards as well as alerting. With no
  /// monitor bound the severe line stays the degradation — the fail-closed
  /// diagnostic itself still reaches the caller as the refusal's own error.
  void _reportCredentialRefusal(String providerId, String detail, {String? remediation}) {
    final monitor = _credentialHealth;
    if (monitor == null) {
      final fix = remediation == null || detail.contains(remediation) ? '' : ' $remediation';
      _log.severe('Provider "$providerId" credential unusable: $detail$fix');
      return;
    }
    monitor.report(
      providerId: providerId,
      state: CredentialHealthState.reauthRequired,
      detail: detail,
      remediation: remediation,
    );
  }

  /// Ends the authority whose credential turned unusable mid-turn, through the
  /// same lease path a normal release takes: revoke the mediation, then destroy
  /// the container.
  Future<void> _tearDownAuthority(GatewayAuthority authority) async {
    final lease = _authorityLeases.remove(authority.id);
    if (lease == null) {
      await _gateway?.revoke(authority);
      return;
    }
    try {
      await lease.release();
    } catch (error, stackTrace) {
      _log.severe('Failed to release authority ${authority.id} after a credential failure', error, stackTrace);
    }
  }

  /// Routes a bridge refusal into the existing guard audit trail.
  void _auditGatewayDenial(GatewayPrincipal principal, String reason) {
    _eventBus.fire(
      GuardBlockEvent(
        guardName: 'host-gateway',
        guardCategory: 'isolation',
        verdict: 'block',
        verdictMessage: reason,
        hookPoint: 'bridge',
        agentId: principal.logicalAgentId,
        sessionId: principal.sessionId,
        timestamp: DateTime.now(),
      ),
    );
  }

  List<String> _localPathProjectMounts() {
    final clonesDir = p.normalize(p.absolute(config.projectsClonesDir));
    final mounts = <String>[];
    for (final definition in config.projects.definitions.values) {
      final localPath = definition.localPath?.trim();
      if (localPath == null || localPath.isEmpty) {
        continue;
      }
      final normalizedLocalPath = p.normalize(p.absolute(localPath));
      if (p.equals(normalizedLocalPath, clonesDir) || p.isWithin(clonesDir, normalizedLocalPath)) {
        continue;
      }
      mounts.add('$normalizedLocalPath:${p.posix.join('/projects', definition.id)}:ro');
    }
    return mounts;
  }

  void _wireGuardChain(List<AgentDefinition> agentDefs) {
    final agentAllow = <String, Set<String>>{};
    final agentDeny = <String, Set<String>>{};
    for (final agent in agentDefs) {
      if (agent.allowedTools.isNotEmpty) agentAllow[agent.id] = agent.allowedTools;
      if (agent.deniedTools.isNotEmpty) agentDeny[agent.id] = agent.deniedTools;
    }
    _toolPolicyCascade = ToolPolicyCascade(
      globalDeny: config.agent.disallowedTools.toSet(),
      agentDeny: agentDeny,
      agentAllow: agentAllow,
    );

    if (!config.security.guards.enabled) {
      _guardChain = null;
      return;
    }

    final result = buildGuardsFromConfig(
      securityConfig: config.security,
      dataDir: _dataDir,
      toolPolicyCascade: _toolPolicyCascade,
    );

    switch (result) {
      case GuardBuildSuccess(:final guards):
        _guardChain = GuardChain(
          failOpen: config.security.guards.failOpen,
          guards: guards,
          onVerdict: (name, category, verdict, message, ctx) {
            _eventBus.fire(
              GuardBlockEvent(
                guardName: name,
                guardCategory: category,
                verdict: verdict,
                verdictMessage: message,
                hookPoint: ctx.hookPoint,
                rawProviderToolName: ctx.rawProviderToolName,
                toolName: ctx.toolName,
                agentId: ctx.agentId,
                sessionId: ctx.sessionId,
                channel: ctx.source,
                peerId: ctx.peerId,
                timestamp: ctx.timestamp,
              ),
            );
          },
        );
      case GuardBuildFailure(:final errors):
        // Fatal at startup.
        for (final e in errors) {
          _log.severe('Guard chain build failed: $e');
        }
        _exitFn(1);
    }
  }

  void _wireAuditAndLifecycle() {
    _guardAuditSubscriber = GuardAuditSubscriber(_auditLogger)..subscribe(_eventBus);
    _sessionLifecycleSubscriber = SessionLifecycleSubscriber()..subscribe(_eventBus);
  }

  void _wireContentGuard() {
    if (!config.security.contentGuardEnabled) return;

    if (config.security.contentGuardClassifier == 'anthropic_api') {
      final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
      if (apiKey != null && apiKey.isNotEmpty) {
        _contentClassifier = AnthropicApiClassifier(apiKey: apiKey, model: config.security.contentGuardModel);
      } else {
        _log.warning(
          'ANTHROPIC_API_KEY not set — content guard disabled. '
          'Set the environment variable or switch to classifier: claude_binary. '
          'With no classifier configured, web_fetch results and tool results from MCP servers '
          'declared network_class: public are not classified.',
        );
      }
    } else {
      _contentClassifier = ClaudeBinaryClassifier(
        claudeExecutable: config.server.claudeExecutable,
        model: config.security.contentGuardModel,
      );
    }

    if (_contentClassifier != null) {
      _contentGuardFailOpen = config.security.contentGuardFailOpen;
      if (_contentGuardFailOpen) {
        _log.warning(
          'guards.content.fail_open is true — content the classifier cannot score reaches the agent unchecked. '
          'Set guards.content.fail_open: false to block it instead.',
        );
      }
      _contentScan = ContentScan(
        classifier: _contentClassifier!,
        maxContentBytes: config.security.contentGuardMaxBytes,
        failOpen: _contentGuardFailOpen,
      );
      _contentGuard = ContentGuard(scan: _contentScan!);
    }
  }

  Future<void> dispose() async {
    await _containerHealthMonitor?.stop();
    await _containerAuthorities.dispose();
    if (_gateway != null) {
      await ContainerManager.reclaimOwnedContainers(_dataDir, runtimeBinary: config.container.runtimeBinary);
    }
    // Revoking every live authority also kills its bridge processes; the
    // containers themselves are destroyed by their own leases.
    await _gateway?.dispose();
    await _guardAuditSubscriber?.cancel();
    await _sessionLifecycleSubscriber?.cancel();
    // Cancelling stops new verdicts; queued NDJSON appends are fire-and-forget
    // and would otherwise be lost or half-written at shutdown.
    await _auditLogger.flush();
  }
}

/// One container authority's container, bridges, and registration held together.
///
/// Release order is the isolation order: stop watching (so teardown is not a
/// crash), revoke the pipes while the container still exists but can no longer
/// use them, then destroy the container. Every step runs even if an earlier one
/// fails. Confirmed release is idempotent; failed destruction stays retryable.
class _ContainerAuthorityLease implements ContainerAuthorityLease {
  new({
    required this.manager,
    required this.authority,
    required HostGateway gateway,
    required EventBus eventBus,
    required ContainerHealthMonitor? monitor,
    void Function()? onReleased,
  }) : _gateway = gateway,
       _eventBus = eventBus,
       _monitor = monitor,
       _onReleased = onReleased;

  static final _log = Logger('ContainerAuthorityLease');

  final ContainerManager manager;
  final GatewayAuthority authority;
  final HostGateway _gateway;
  final EventBus _eventBus;
  final ContainerHealthMonitor? _monitor;
  final void Function()? _onReleased;

  @override
  ContainerExecutor get container => manager;

  @override
  Future<void> release() async {
    _onReleased?.call();
    _monitor?.unwatch(manager.containerName);
    try {
      await _gateway.revoke(authority);
    } catch (error, stackTrace) {
      _log.severe('Failed to revoke gateway authority ${authority.id}', error, stackTrace);
    }
    try {
      // stop() throws when removal cannot be confirmed, so this event is only
      // reached once the container is gone.
      await manager.stop();
      _eventBus.fire(
        ContainerStoppedEvent(
          profileId: manager.profileId,
          containerName: manager.containerName,
          timestamp: DateTime.now(),
        ),
      );
    } catch (error, stackTrace) {
      _log.severe('Failed to destroy container ${manager.containerName}', error, stackTrace);
      rethrow;
    }
  }
}

/// Builds one live authority's container from a profile template.
typedef _ContainerTemplate = ContainerManager Function(
  String containerName, {
  required String generatedStateDir,
  required String? artifactsDir,
  required bool hasMcpBridge,
});

/// Bridges [MessageRedactor] (in dartclaw_kernel, which cannot depend on
/// dartclaw_core) to the [Reconfigurable] interface (in dartclaw_core).
class _MessageRedactorAdapter implements Reconfigurable {
  final MessageRedactor _redactor;
  new(this._redactor);

  @override
  Set<String> get watchKeys => const {'logging.*'};

  @override
  void reconfigure(ConfigDelta delta) {
    _redactor.recompilePatterns(delta.current.logging.redactPatterns);
  }
}
