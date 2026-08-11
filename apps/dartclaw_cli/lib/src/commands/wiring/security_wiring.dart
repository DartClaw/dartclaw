import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../serve_command.dart' show ExitFn;

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
///    the `dartclaw_security` → `dartclaw_core` package boundary by implementing
///    [Reconfigurable] on behalf of the redactor without adding a cross-package dep.
///
/// Both registrations happen in [wire], after [ConfigNotifier] is available.
class SecurityWiring implements Reconfigurable {
  SecurityWiring({
    required this.config,
    required String dataDir,
    required EventBus eventBus,
    required ExitFn exitFn,
    PlatformCapabilities? platformCapabilities,
    ConfigNotifier? configNotifier,
    MessageRedactor? messageRedactor,
    McpProtocolHandler Function()? mcpHandlerRef,
  }) : _dataDir = dataDir,
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

  /// Resolved lazily: the MCP handler exists only after the server is built,
  /// while authorities are created at turn time.
  final McpProtocolHandler Function()? _mcpHandlerRef;

  static final _log = Logger('SecurityWiring');

  HostGateway? _gateway;
  BridgeBinaryProvisioner? _bridgeBinaries;
  String? _bridgeBinaryPath;
  ContainerHealthMonitor? _containerHealthMonitor;
  final Map<String, ContainerManager Function(String containerName)> _containerTemplates = {};
  // Authority suffixes must not repeat across process restarts: ContainerManager
  // adopts a healthy same-named container, so a recycled name could hand a new
  // authority an orphan from a previous run.
  final String _authorityEpoch = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  var _nextAuthorityId = 1;
  GuardChain? _guardChain;
  late GuardAuditLogger _auditLogger;
  ContentGuard? _contentGuard;
  ContentClassifier? _contentClassifier;
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
  }) async {
    final profileId = principal.containerProfile;
    final template = profileId == null ? null : _containerTemplates[profileId];
    final gateway = _gateway;
    if (template == null || gateway == null) {
      throw StateError('No container profile "$profileId" is available in this deployment');
    }

    final manager = template(
      ContainerManager.generateName(_dataDir, '$profileId-$_authorityEpoch${_nextAuthorityId++}'),
    );
    final authority = gateway.register(principal: principal, allowedMcpTools: allowedMcpTools);
    final lease = _ContainerAuthorityLease(
      manager: manager,
      authority: authority,
      gateway: gateway,
      eventBus: _eventBus,
      monitor: _containerHealthMonitor,
    );
    try {
      await manager.start();
      _eventBus.fire(
        ContainerStartedEvent(
          profileId: manager.profileId,
          containerName: manager.containerName,
          timestamp: DateTime.now(),
        ),
      );
      _containerHealthMonitor?.watch(manager.containerName, manager);
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
      await _wireContainers();
    } else {
      if (_platformCapabilities.containerIsolationAvailable) {
        _log.warning(
          'Container isolation disabled — agent has full host access. '
          'Guards are the only security boundary. '
          'Enable container isolation for production use (see docs/guide/security.md).',
        );
      } else {
        _log.warning(
          'Container isolation disabled — agent has full host access. '
          'Container isolation is unavailable on native Windows; '
          'run DartClaw on POSIX (macOS/Linux) or inside WSL for isolation.',
        );
      }
    }

    _wireGuardChain(agentDefs);
    _wireAuditAndLifecycle();
    _wireContentGuard();

    // Register security-layer services with ConfigNotifier via adapters.
    // (dartclaw_security cannot depend on dartclaw_core — adapters bridge the gap.)
    if (_configNotifier != null) {
      if (_messageRedactorForRegistration != null) {
        final redactor = _messageRedactorForRegistration;
        _configNotifier.register(_MessageRedactorAdapter(redactor));
      }
      // Register self for guards.* hot-reload. Successful rebuilds swap the
      // entire guard list atomically, including InputSanitizer instances.
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
      case GuardBuildSuccess(:final guards, :final warnings):
        for (final w in warnings) {
          _log.fine('SecurityWiring guard rebuild: $w');
        }
        _guardChain!.replaceGuards(guards);
        _log.info('SecurityWiring: guard chain rebuilt (${guards.length} guards)');
      case GuardBuildFailure(:final errors):
        for (final e in errors) {
          _log.severe('SecurityWiring guard rebuild failed: $e');
        }
        _log.severe('SecurityWiring: guard chain NOT updated — preserving existing chain');
    }
  }

  Future<void> _wireContainers() async {
    final validationErrors = DockerValidator.validate(config.container);
    if (validationErrors.isNotEmpty) {
      for (final err in validationErrors) {
        _log.severe('Container config rejected: $err');
      }
      _exitFn(1);
    }

    final apiKey = Platform.environment['ANTHROPIC_API_KEY']?.trim();
    String? hostClaudeJsonPath;
    if (apiKey == null || apiKey.isEmpty) {
      final authResult = await Process.run(config.server.claudeExecutable, ['auth', 'status']);
      if (authResult.exitCode != 0) {
        _log.severe('Container mode requires ANTHROPIC_API_KEY or Claude OAuth/setup-token auth');
        _log.severe('Configure auth with `claude auth login`, `claude setup-token`, or ANTHROPIC_API_KEY');
        _exitFn(1);
      }
      try {
        final status = jsonDecode(authResult.stdout as String) as Map<String, dynamic>;
        if (status['loggedIn'] != true) {
          _log.severe('Container mode requires ANTHROPIC_API_KEY or Claude OAuth/setup-token auth');
          _log.severe('Configure auth with `claude auth login`, `claude setup-token`, or ANTHROPIC_API_KEY');
          _exitFn(1);
        }
      } on FormatException {
        _log.severe('Unable to verify Claude auth status for container mode');
        _exitFn(1);
      }

      final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home == null) {
        _log.severe('Cannot locate HOME to mount Claude OAuth credentials into the container');
        _exitFn(1);
      }
      final claudeJson = File(p.join(home, '.claude.json'));
      if (!claudeJson.existsSync()) {
        _log.severe('Claude OAuth appears configured, but ~/.claude.json was not found');
        _exitFn(1);
      }
      hostClaudeJsonPath = claudeJson.path;
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
    ContainerManager buildManager(SecurityProfile profile, String containerName) => ContainerManager(
      config: config.container,
      containerName: containerName,
      profileId: profile.id,
      workspaceMounts: profile.id == 'workspace'
          ? [...profile.workspaceMounts, ...localPathProjectMounts]
          : profile.workspaceMounts,
      localPathAllowlist: config.projects.localPathAllowlist,
      bridgeBinaryPath: _bridgeBinaryPath,
      hostClaudeJsonPath: hostClaudeJsonPath,
      buildContextDir: Directory.current.path,
      workingDir: profile.id == SecurityProfile.restricted.id ? '/tmp' : '/project',
    );

    final probe = buildManager(SecurityProfile.restricted, 'dartclaw-probe');
    if (!await probe.isDockerAvailable()) {
      _log.severe('Docker is required when container.enabled: true');
      _log.severe('Install or start Docker: https://docs.docker.com/get-docker/');
      _exitFn(1);
    }
    await probe.ensureImage();

    final architecture = await probe.serverArchitecture();
    if (architecture == null) {
      _log.severe('Unsupported Docker engine architecture; no container bridge binary ships for it');
      _exitFn(1);
    }
    _bridgeBinaries = BridgeBinaryProvisioner(dataDir: _dataDir);
    try {
      _bridgeBinaryPath = await _bridgeBinaries!.ensureAvailable(architecture);
    } on StateError catch (error) {
      _log.severe('Container isolation cannot start: ${error.message}');
      _exitFn(1);
    }

    for (final profile in profiles) {
      _containerTemplates[profile.id] = (containerName) => buildManager(profile, containerName);
    }

    _containerHealthMonitor = ContainerHealthMonitor(eventBus: _eventBus)..start();
    _gateway = HostGateway(
      providerAdapters: _buildProviderAdapters(),
      mcpHandler: _mcpHandlerRef,
      mcpToolCanonicals: () => _mcpToolCanonicals,
      onDenied: _auditGatewayDenial,
    );

    _log.info(
      'Container isolation enabled — ${_containerTemplates.length} profiles, host-mediated '
      'linux-$architecture bridge (image: ${config.container.image})',
    );
  }

  Map<String, ProviderMediator> _buildProviderAdapters() {
    final registry = CredentialRegistry(credentials: config.credentials, env: Platform.environment);
    // Each adapter owns one fixed upstream. Nothing downstream — least of all a
    // container — can retarget it, and there is deliberately no configuration
    // knob to point a credentialed adapter somewhere else.
    return {
      'claude': AnthropicMessagesAdapter(apiKey: () => registry.getApiKey('claude')),
      'codex': OpenAiResponsesAdapter(apiKey: () => registry.getApiKey('codex')),
    };
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
      case GuardBuildSuccess(:final guards, :final warnings):
        for (final w in warnings) {
          _log.fine('Guard build: $w');
        }
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
          'Set the environment variable or switch to classifier: claude_binary.',
        );
      }
    } else {
      _contentClassifier = ClaudeBinaryClassifier(
        claudeExecutable: config.server.claudeExecutable,
        model: config.security.contentGuardModel,
      );
      _contentGuardFailOpen = true;
    }

    if (_contentClassifier != null) {
      _contentGuard = ContentGuard(
        classifier: _contentClassifier!,
        maxContentBytes: config.security.contentGuardMaxBytes,
        failOpen: _contentGuardFailOpen,
      );
    }
  }

  Future<void> dispose() async {
    await _containerHealthMonitor?.stop();
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
/// fails, and repeat calls are no-ops.
class _ContainerAuthorityLease implements ContainerAuthorityLease {
  _ContainerAuthorityLease({
    required this.manager,
    required this.authority,
    required HostGateway gateway,
    required EventBus eventBus,
    required ContainerHealthMonitor? monitor,
  }) : _gateway = gateway,
       _eventBus = eventBus,
       _monitor = monitor;

  static final _log = Logger('ContainerAuthorityLease');

  final ContainerManager manager;
  final GatewayAuthority authority;
  final HostGateway _gateway;
  final EventBus _eventBus;
  final ContainerHealthMonitor? _monitor;

  bool _released = false;

  @override
  ContainerExecutor get container => manager;

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _monitor?.unwatch(manager.containerName);
    try {
      await _gateway.revoke(authority);
    } catch (error, stackTrace) {
      _log.severe('Failed to revoke gateway authority ${authority.id}', error, stackTrace);
    }
    try {
      // ContainerManager.stop() does not surface docker's exit codes, so this
      // event reports that teardown was attempted, not that it was confirmed.
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
    }
  }
}

/// Bridges [MessageRedactor] (in dartclaw_security, which cannot depend on
/// dartclaw_core) to the [Reconfigurable] interface (in dartclaw_core).
class _MessageRedactorAdapter implements Reconfigurable {
  final MessageRedactor _redactor;
  _MessageRedactorAdapter(this._redactor);

  @override
  Set<String> get watchKeys => const {'logging.*'};

  @override
  void reconfigure(ConfigDelta delta) {
    _redactor.recompilePatterns(delta.current.logging.redactPatterns);
  }
}
