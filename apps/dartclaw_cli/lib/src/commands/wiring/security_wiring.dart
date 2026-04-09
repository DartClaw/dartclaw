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
///
/// Implements [Reconfigurable] for `guards.*` config changes — on reconfigure,
/// rebuilds all guards from the updated security config and atomically swaps
/// the guard list in the existing [GuardChain].
class SecurityWiring implements Reconfigurable {
  SecurityWiring({
    required this.config,
    required String dataDir,
    required EventBus eventBus,
    required ExitFn exitFn,
    ConfigNotifier? configNotifier,
    MessageRedactor? messageRedactor,
  }) : _dataDir = dataDir,
       _eventBus = eventBus,
       _exitFn = exitFn,
       _configNotifier = configNotifier,
       _messageRedactorForRegistration = messageRedactor;

  final DartclawConfig config;
  final String _dataDir;
  final EventBus _eventBus;
  final ExitFn _exitFn;
  final ConfigNotifier? _configNotifier;
  final MessageRedactor? _messageRedactorForRegistration;

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
  // Reconfigurable — guards.* hot-reload
  // ---------------------------------------------------------------------------

  @override
  Set<String> get watchKeys => const {'guards.*'};

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
      SecurityProfile.workspace(
        workspaceDir: config.workspaceDir,
        projectDir: Directory.current.path,
        projectsClonesDir: config.projectsClonesDir,
      ),
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
    _credentialProxy = CredentialProxy(socketPath: p.join(_dataDir, 'proxy', 'proxy.sock'), apiKey: proxyApiKey);
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

    _containerHealthMonitor = ContainerHealthMonitor(containerManagers: _containerManagers, eventBus: _eventBus);
    _containerHealthMonitor!.start();

    _log.info('Container isolation enabled — ${_containerManagers.length} profiles (image: ${config.container.image})');
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

/// Builds a [List<Guard>] from [SecurityConfig], performing deduplication and
/// conflict detection on the extra rules before constructing guard instances.
///
/// Returns [GuardBuildSuccess] with the guards and any deduplication warnings,
/// or [GuardBuildFailure] with error descriptions when the config is invalid
/// (bad regex, conflicting rules). The caller decides whether to swap the chain
/// or log and preserve the existing one.
///
/// [toolPolicyCascade] is appended as-is (not rebuilt from config).
GuardBuildResult buildGuardsFromConfig({
  required SecurityConfig securityConfig,
  required String dataDir,
  required ToolPolicyCascade toolPolicyCascade,
  TaskToolFilterGuard? taskToolFilterGuard,
}) {
  final yaml = securityConfig.guardsYaml;
  final errors = <String>[];
  final warnings = <String>[];

  // --- Validate and deduplicate command.extra_blocked_patterns ---
  final commandYaml = yaml['command'];
  if (commandYaml is Map) {
    final rawExtra = commandYaml['extra_blocked_patterns'];
    if (rawExtra is List) {
      final seen = <String>{};
      final dupes = <String>[];
      for (final p in rawExtra) {
        if (p is String) {
          try {
            RegExp(p); // validate
          } catch (e) {
            errors.add('command.extra_blocked_patterns: invalid regex "$p": $e');
          }
          if (!seen.add(p)) dupes.add(p);
        }
      }
      for (final d in dupes) {
        warnings.add('command.extra_blocked_patterns: duplicate pattern "$d" removed');
      }
    }
  }

  // --- Validate and deduplicate file.extra_rules (detect conflicts) ---
  final fileYaml = yaml['file'];
  if (fileYaml is Map) {
    final rawRules = fileYaml['extra_rules'];
    if (rawRules is List) {
      // Map pattern → first-seen level; conflict = same pattern with different level
      final seen = <String, String>{};
      final dupeKeys = <String>{};
      for (final r in rawRules) {
        if (r is Map) {
          final pattern = r['pattern'];
          final level = r['level'];
          if (pattern is String && level is String) {
            if (seen.containsKey(pattern)) {
              if (seen[pattern] != level) {
                errors.add(
                  'file.extra_rules: conflicting rules for pattern "$pattern" '
                  '(levels: ${seen[pattern]} vs $level)',
                );
              } else {
                dupeKeys.add(pattern);
              }
            } else {
              seen[pattern] = level;
            }
          }
        }
      }
      for (final d in dupeKeys) {
        warnings.add('file.extra_rules: duplicate rule for pattern "$d" removed');
      }
    }
  }

  // --- Validate network.extra_exfil_patterns ---
  final networkYaml = yaml['network'];
  if (networkYaml is Map) {
    final rawExfil = networkYaml['extra_exfil_patterns'];
    if (rawExfil is List) {
      final seen = <String>{};
      final dupes = <String>[];
      for (final p in rawExfil) {
        if (p is String) {
          try {
            RegExp(p); // validate
          } catch (e) {
            errors.add('network.extra_exfil_patterns: invalid regex "$p": $e');
          }
          if (!seen.add(p)) dupes.add(p);
        }
      }
      for (final d in dupes) {
        warnings.add('network.extra_exfil_patterns: duplicate pattern "$d" removed');
      }
    }
  }

  // --- Validate input_sanitizer.extra_patterns ---
  final sanitizerYaml = yaml['input_sanitizer'];
  if (sanitizerYaml is Map) {
    final rawExtra = sanitizerYaml['extra_patterns'];
    if (rawExtra is List) {
      final seen = <String>{};
      final dupes = <String>[];
      for (final p in rawExtra) {
        if (p is String) {
          try {
            RegExp(p); // validate
          } catch (e) {
            errors.add('input_sanitizer.extra_patterns: invalid regex "$p": $e');
          }
          if (!seen.add(p)) dupes.add(p);
        }
      }
      for (final d in dupes) {
        warnings.add('input_sanitizer.extra_patterns: duplicate pattern "$d" removed');
      }
    }
  }

  if (errors.isNotEmpty) {
    return GuardBuildFailure(errors: errors);
  }

  // --- Construct guards ---
  final inputSanitizer = InputSanitizer(
    config: yaml['input_sanitizer'] is Map
        ? InputSanitizerConfig.fromYaml(Map<String, dynamic>.from(yaml['input_sanitizer'] as Map))
        : InputSanitizerConfig(
            enabled: securityConfig.inputSanitizerEnabled,
            channelsOnly: securityConfig.inputSanitizerChannelsOnly,
            patterns: InputSanitizerConfig.defaults().patterns,
          ),
  );

  final commandGuard = CommandGuard(
    config: yaml['command'] is Map
        ? CommandGuardConfig.fromYaml(Map<String, dynamic>.from(yaml['command'] as Map))
        : CommandGuardConfig.defaults(),
  );

  final fileGuard = FileGuard(
    config:
        (yaml['file'] is Map
                ? FileGuardConfig.fromYaml(Map<String, dynamic>.from(yaml['file'] as Map))
                : FileGuardConfig.defaults())
            .withSelfProtection(p.join(dataDir, 'dartclaw.yaml')),
  );

  final networkGuard = NetworkGuard(
    config: yaml['network'] is Map
        ? NetworkGuardConfig.fromYaml(Map<String, dynamic>.from(yaml['network'] as Map))
        : NetworkGuardConfig.defaults(),
  );

  final guards = <Guard>[
    inputSanitizer,
    commandGuard,
    fileGuard,
    networkGuard,
    ToolPolicyGuard(cascade: toolPolicyCascade),
    ?taskToolFilterGuard,
  ];

  return GuardBuildSuccess(guards: guards, warnings: warnings);
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
