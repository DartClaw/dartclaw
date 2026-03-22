import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../serve_command.dart' show ExitFn;

/// Constructs and exposes security-layer services.
///
/// Owns container setup (credential proxy, container managers, health monitor),
/// guard chain, content guard, audit subscriber, and session lifecycle subscriber.
class SecurityWiring {
  SecurityWiring({
    required this.config,
    required String dataDir,
    required EventBus eventBus,
    required ExitFn exitFn,
  })  : _dataDir = dataDir,
        _eventBus = eventBus,
        _exitFn = exitFn;

  final DartclawConfig config;
  final String _dataDir;
  final EventBus _eventBus;
  final ExitFn _exitFn;

  static final _log = Logger('SecurityWiring');

  CredentialProxy? _credentialProxy;
  ContainerHealthMonitor? _containerHealthMonitor;
  final Map<String, ContainerManager> _containerManagers = {};
  GuardChain? _guardChain;
  late GuardAuditLogger _auditLogger;
  ContentGuard? _contentGuard;
  ContentClassifier? _contentClassifier;
  bool _contentGuardFailOpen = false;
  late ToolPolicyCascade _toolPolicyCascade;
  late GuardAuditSubscriber _guardAuditSubscriber;
  late SessionLifecycleSubscriber _sessionLifecycleSubscriber;

  CredentialProxy? get credentialProxy => _credentialProxy;
  ContainerHealthMonitor? get containerHealthMonitor => _containerHealthMonitor;
  Map<String, ContainerManager> get containerManagers => Map.unmodifiable(_containerManagers);
  GuardChain? get guardChain => _guardChain;
  GuardAuditLogger get auditLogger => _auditLogger;
  ContentGuard? get contentGuard => _contentGuard;
  ContentClassifier? get contentClassifier => _contentClassifier;
  bool get contentGuardFailOpen => _contentGuardFailOpen;
  ToolPolicyCascade get toolPolicyCascade => _toolPolicyCascade;

  Future<void> wire({required List<AgentDefinition> agentDefs}) async {
    if (config.container.enabled) {
      await _wireContainers();
    } else {
      _log.warning(
        'Container isolation disabled — agent has full host access. '
        'Guards are the only security boundary. '
        'Enable container isolation for production use (see docs/guide/security.md).',
      );
    }

    _wireGuardChain(agentDefs);
    _wireAuditAndLifecycle();
    _wireContentGuard();

    // Ensure agent session directories exist.
    for (final agent in agentDefs) {
      if (agent.sessionStorePath.isNotEmpty) {
        Directory(p.join(config.workspaceDir, agent.sessionStorePath)).createSync(recursive: true);
      }
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
        _log.severe('Configure auth with `claude login`, `claude setup-token`, or ANTHROPIC_API_KEY');
        _exitFn(1);
      }
      try {
        final status = jsonDecode(authResult.stdout as String) as Map<String, dynamic>;
        if (status['loggedIn'] != true) {
          _log.severe('Container mode requires ANTHROPIC_API_KEY or Claude OAuth/setup-token auth');
          _log.severe('Configure auth with `claude login`, `claude setup-token`, or ANTHROPIC_API_KEY');
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
      SecurityProfile.workspace(workspaceDir: config.workspaceDir, projectDir: Directory.current.path),
      SecurityProfile.restricted,
    ];
    final proxySocketDir = p.join(_dataDir, 'proxy');
    for (final profile in profiles) {
      _containerManagers[profile.id] = ContainerManager(
        config: config.container,
        containerName: ContainerManager.generateName(_dataDir, profile.id),
        profileId: profile.id,
        workspaceMounts: profile.workspaceMounts,
        proxySocketDir: proxySocketDir,
        hostClaudeJsonPath: hostClaudeJsonPath,
        buildContextDir: Directory.current.path,
        workingDir: profile.id == SecurityProfile.restricted.id ? '/tmp' : '/project',
      );
    }
    final workspaceContainerManager = _containerManagers['workspace']!;

    if (!await workspaceContainerManager.isDockerAvailable()) {
      _log.severe('Docker is required when container.enabled: true');
      _log.severe('Install or start Docker: https://docs.docker.com/get-docker/');
      _exitFn(1);
    }

    final proxyApiKey = Platform.environment['ANTHROPIC_API_KEY']?.trim();
    _credentialProxy = CredentialProxy(
      socketPath: p.join(_dataDir, 'proxy', 'proxy.sock'),
      apiKey: proxyApiKey,
    );
    await _credentialProxy!.start();

    try {
      await workspaceContainerManager.ensureImage();
      for (final entry in _containerManagers.entries) {
        await entry.value.start();
        _eventBus.fire(
          ContainerStartedEvent(
            profileId: entry.key,
            containerName: entry.value.containerName,
            timestamp: DateTime.now(),
          ),
        );
      }
    } catch (e) {
      for (final manager in _containerManagers.values) {
        try {
          await manager.stop();
        } catch (stopErr) {
          _log.fine('Error stopping container during startup failure cleanup', stopErr);
        }
      }
      await _credentialProxy!.stop();
      rethrow;
    }

    _containerHealthMonitor = ContainerHealthMonitor(
      containerManagers: _containerManagers,
      eventBus: _eventBus,
    );
    _containerHealthMonitor!.start();

    _log.info(
      'Container isolation enabled — ${_containerManagers.length} profiles (image: ${config.container.image})',
    );
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

    _auditLogger = GuardAuditLogger(dataDir: _dataDir);
    _guardChain = config.security.guards.enabled
        ? GuardChain(
            failOpen: config.security.guards.failOpen,
            guards: [
              InputSanitizer(
                config: config.security.guardsYaml['input_sanitizer'] is Map
                    ? InputSanitizerConfig.fromYaml(
                        Map<String, dynamic>.from(config.security.guardsYaml['input_sanitizer'] as Map),
                      )
                    : InputSanitizerConfig(
                        enabled: config.security.inputSanitizerEnabled,
                        channelsOnly: config.security.inputSanitizerChannelsOnly,
                        patterns: InputSanitizerConfig.defaults().patterns,
                      ),
              ),
              CommandGuard(
                config: config.security.guardsYaml['command'] is Map
                    ? CommandGuardConfig.fromYaml(
                        Map<String, dynamic>.from(config.security.guardsYaml['command'] as Map),
                      )
                    : CommandGuardConfig.defaults(),
              ),
              FileGuard(
                config: (config.security.guardsYaml['file'] is Map
                        ? FileGuardConfig.fromYaml(
                            Map<String, dynamic>.from(config.security.guardsYaml['file'] as Map),
                          )
                        : FileGuardConfig.defaults())
                    .withSelfProtection(p.join(_dataDir, 'dartclaw.yaml')),
              ),
              NetworkGuard(
                config: config.security.guardsYaml['network'] is Map
                    ? NetworkGuardConfig.fromYaml(
                        Map<String, dynamic>.from(config.security.guardsYaml['network'] as Map),
                      )
                    : NetworkGuardConfig.defaults(),
              ),
              ToolPolicyGuard(cascade: _toolPolicyCascade),
            ],
            onVerdict: (name, category, verdict, message, ctx) {
              _eventBus.fire(
                GuardBlockEvent(
                  guardName: name,
                  guardCategory: category,
                  verdict: verdict,
                  verdictMessage: message,
                  hookPoint: ctx.hookPoint,
                  sessionId: ctx.sessionId,
                  channel: ctx.source,
                  peerId: ctx.peerId,
                  timestamp: ctx.timestamp,
                ),
              );
            },
          )
        : null;
  }

  void _wireAuditAndLifecycle() {
    _guardAuditSubscriber = GuardAuditSubscriber(_auditLogger);
    _guardAuditSubscriber.subscribe(_eventBus);

    _sessionLifecycleSubscriber = SessionLifecycleSubscriber();
    _sessionLifecycleSubscriber.subscribe(_eventBus);
  }

  void _wireContentGuard() {
    if (!config.security.contentGuardEnabled) return;

    if (config.security.contentGuardClassifier == 'anthropic_api') {
      final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
      if (apiKey != null && apiKey.isNotEmpty) {
        _contentClassifier = AnthropicApiClassifier(
          apiKey: apiKey,
          model: config.security.contentGuardModel,
        );
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
    for (final entry in _containerManagers.entries) {
      try {
        await entry.value.stop();
        _eventBus.fire(
          ContainerStoppedEvent(
            profileId: entry.key,
            containerName: entry.value.containerName,
            timestamp: DateTime.now(),
          ),
        );
      } catch (e) {
        _log.fine('Error stopping container ${entry.key} during shutdown', e);
      }
    }
    await _credentialProxy?.stop();
    await _containerHealthMonitor?.stop();
  }
}
