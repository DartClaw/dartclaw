import 'dart:collection';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'agent_config.dart';
import 'agent_definition.dart';
import 'alerts_config.dart';
import 'auth_config.dart';
import 'claude_provider_options.dart';
import 'channel_config.dart';
import 'container_config.dart';
import 'config_constraints.dart';
import 'config_load_warnings.dart';
import 'config_meta.dart';
import 'config_numeric_bounds.dart';
import 'config_validator.dart' show unknownConfigFieldMessage;
import 'context_config.dart';
import 'credentials_config.dart';
import 'duration_parser.dart' show tryParseDuration;
import 'env_substitute.dart';
import 'execution_policy.dart';
import 'features_config.dart';
import 'gateway_config.dart';
import 'guard_config.dart';
import 'harness_config.dart';
import 'governance_config.dart';
import 'history_config.dart';
import 'identifier_preservation_mode.dart';
import 'knowledge_config.dart';
import 'logging_config.dart';
import 'memory_config.dart';
import 'mcp_servers_config.dart';
import 'onboarding_config.dart';
import 'path_utils.dart';
import 'project_config.dart';
import 'provider_identity.dart';
import 'providers_config.dart';
import 'scheduled_task_definition.dart';
import 'scheduling_config.dart';
import 'search_config.dart';
import 'security_config.dart';
import 'server_config.dart';
import 'session_config.dart';
import 'session_scope_config.dart';
import 'session_maintenance_config.dart';
import 'task_config.dart';
import 'turn_limits_validation.dart';
import 'usage_config.dart';
import 'workflow_config.dart';
import 'workspace_config.dart';
import 'yaml_type_safe_reader.dart';

part 'config_accept_set.dart';
part 'config_extensions.dart';
part 'config_parser.dart';
part 'config_parser_governance.dart';
part 'config_parser_harness.dart';
part 'config_parser_providers.dart';
part 'config_parser_security.dart';

/// Immutable configuration for DartClaw runtime.
class DartclawConfig {
  // --- Composed section fields ---
  /// server.
  final ServerConfig server;

  /// agent.
  final AgentConfig agent;

  /// auth.
  final AuthConfig auth;

  /// gateway.
  final GatewayConfig gateway;

  /// harness.
  final HarnessConfig harness;

  /// sessions.
  final SessionConfig sessions;

  /// context.
  final ContextConfig context;

  /// security.
  final SecurityConfig security;

  /// memory.
  final MemoryConfig memory;

  /// Knowledge job scheduler settings.
  final KnowledgeConfig knowledge;

  /// search.
  final SearchConfig search;

  /// External MCP server registry.
  final McpServersConfig mcpServers;

  /// providers.
  final ProvidersConfig providers;

  /// credentials.
  final CredentialsConfig credentials;

  /// tasks.
  final TaskConfig tasks;

  /// scheduling.
  final SchedulingConfig scheduling;

  /// workspace.
  final WorkspaceConfig workspace;

  /// onboarding.
  final OnboardingConfig onboarding;

  /// workflow.
  final WorkflowConfig workflow;

  /// logging.
  final LoggingConfig logging;

  /// usage.
  final UsageConfig usage;

  /// container.
  final ContainerConfig container;

  /// channels.
  final ChannelConfig channels;

  /// governance.
  final GovernanceConfig governance;

  /// features.
  final FeaturesConfig features;

  /// projects.
  final ProjectConfig projects;

  /// alerts.
  final AlertsConfig alerts;

  /// Extension sections registered by private deployers via
  /// [registerExtensionParser], each holding what its parser returned.
  ///
  /// Only registered keys appear: a top-level section with no parser refuses
  /// the load rather than arriving here unparsed.
  final Map<String, Object?> extensions;

  /// Warnings collected during [load] and by parsers run through
  /// [parseWithLoadWarnings].
  /// Callers are responsible for surfacing these.
  final List<String> _warnings;

  /// warnings.
  List<String> get warnings => UnmodifiableListView(_warningSink());

  /// Load diagnostics that indicate invalid input or fallback behavior.
  List<String> get reloadBlockingWarnings {
    final warnings = _warningSink();
    return UnmodifiableListView(warnings is ConfigLoadWarnings ? warnings.blockingWarnings : warnings);
  }

  // --- Derived path getters ---
  /// workspaceDir.
  String get workspaceDir => p.join(server.dataDir, 'workspace');

  /// sessionsDir.
  String get sessionsDir => p.join(server.dataDir, 'sessions');

  /// logsDir.
  String get logsDir => p.join(server.dataDir, 'logs');

  /// searchDbPath.
  String get searchDbPath => p.join(server.dataDir, 'search.db');

  /// tasksDbPath.
  String get tasksDbPath => p.join(server.dataDir, 'tasks.db');

  /// kvPath.
  String get kvPath => p.join(server.dataDir, 'kv.json');

  /// projectsJsonPath.
  String get projectsJsonPath => p.join(server.dataDir, 'projects.json');

  /// projectsClonesDir.
  String get projectsClonesDir => p.join(server.dataDir, 'projects');

  /// Directory holding DartClaw's dedicated provider credential stores.
  String get credentialsDir => credentialsDirFor(server.dataDir);

  /// The credential store root under [dataDir].
  ///
  /// Exists so [load] can name the same directory as [credentialsDir] before a
  /// [DartclawConfig] is built to ask.
  static String credentialsDirFor(String dataDir) => p.join(dataDir, 'credentials');

  /// Creates a [DartclawConfig] value.
  const new({
    this.server = const ServerConfig.defaults(),
    this.agent = const AgentConfig.defaults(),
    this.auth = const AuthConfig.defaults(),
    this.gateway = const GatewayConfig.defaults(),
    this.harness = const HarnessConfig.defaults(),
    this.sessions = const SessionConfig.defaults(),
    this.context = const ContextConfig.defaults(),
    this.security = const SecurityConfig.defaults(),
    this.memory = const MemoryConfig.defaults(),
    this.knowledge = const KnowledgeConfig.defaults(),
    this.search = const SearchConfig.defaults(),
    this.mcpServers = const McpServersConfig.defaults(),
    this.providers = const ProvidersConfig.defaults(),
    this.credentials = const CredentialsConfig.defaults(),
    this.tasks = const TaskConfig.defaults(),
    this.scheduling = const SchedulingConfig.defaults(),
    this.workspace = const WorkspaceConfig.defaults(),
    this.onboarding = const OnboardingConfig.defaults(),
    this.workflow = const WorkflowConfig.defaults(),
    this.logging = const LoggingConfig.defaults(),
    this.usage = const UsageConfig.defaults(),
    this.container = const ContainerConfig(),
    this.channels = const ChannelConfig.defaults(),
    this.governance = const GovernanceConfig.defaults(),
    this.features = const FeaturesConfig(),
    this.projects = const ProjectConfig.defaults(),
    this.alerts = const AlertsConfig.defaults(),
    this.extensions = const {},
    List<String> warnings = const [],
  }) : _warnings = warnings;

  /// All default values.
  const new defaults() : this();

  /// Returns a copy with the given sections replaced, preserving every other
  /// section (including [warnings]).
  ///
  /// Prefer this over manually re-listing the constructor when replacing a
  /// single section: a hand-rolled reconstruction silently drops any section it
  /// forgets to copy when new top-level sections are added.
  DartclawConfig copyWith({
    ServerConfig? server,
    AgentConfig? agent,
    AuthConfig? auth,
    GatewayConfig? gateway,
    HarnessConfig? harness,
    SessionConfig? sessions,
    ContextConfig? context,
    SecurityConfig? security,
    MemoryConfig? memory,
    KnowledgeConfig? knowledge,
    SearchConfig? search,
    McpServersConfig? mcpServers,
    ProvidersConfig? providers,
    CredentialsConfig? credentials,
    TaskConfig? tasks,
    SchedulingConfig? scheduling,
    WorkspaceConfig? workspace,
    OnboardingConfig? onboarding,
    WorkflowConfig? workflow,
    LoggingConfig? logging,
    UsageConfig? usage,
    ContainerConfig? container,
    ChannelConfig? channels,
    GovernanceConfig? governance,
    FeaturesConfig? features,
    ProjectConfig? projects,
    AlertsConfig? alerts,
    Map<String, Object?>? extensions,
    List<String>? warnings,
  }) {
    return DartclawConfig(
      server: server ?? this.server,
      agent: agent ?? this.agent,
      auth: auth ?? this.auth,
      gateway: gateway ?? this.gateway,
      harness: harness ?? this.harness,
      sessions: sessions ?? this.sessions,
      context: context ?? this.context,
      security: security ?? this.security,
      memory: memory ?? this.memory,
      knowledge: knowledge ?? this.knowledge,
      search: search ?? this.search,
      mcpServers: mcpServers ?? this.mcpServers,
      providers: providers ?? this.providers,
      credentials: credentials ?? this.credentials,
      tasks: tasks ?? this.tasks,
      scheduling: scheduling ?? this.scheduling,
      workspace: workspace ?? this.workspace,
      onboarding: onboarding ?? this.onboarding,
      workflow: workflow ?? this.workflow,
      logging: logging ?? this.logging,
      usage: usage ?? this.usage,
      container: container ?? this.container,
      channels: channels ?? this.channels,
      governance: governance ?? this.governance,
      features: features ?? this.features,
      projects: projects ?? this.projects,
      alerts: alerts ?? this.alerts,
      extensions: extensions ?? this.extensions,
      warnings: warnings ?? _warningSink(),
    );
  }

  /// Registers a parser for a custom top-level YAML section.
  ///
  /// Registration is *required*, not advisory: [DartclawConfig.load] refuses a
  /// top-level section neither the field registry nor a registered parser
  /// describes, so this must run before every load — typically in the private
  /// overlay's bootstrap.
  ///
  /// Throws [ArgumentError] if [name] conflicts with a built-in config key.
  static void registerExtensionParser(
    String name,
    Object Function(Map<String, dynamic> yaml, List<String> warns) parser,
  ) {
    _registerExtensionParser(name, parser);
  }

  /// Removes all registered extension parsers.
  ///
  /// Only for use in tests — call in [setUp]/[tearDown] to avoid cross-test
  /// parser leakage.
  @visibleForTesting
  static void clearExtensionParsers() => _clearExtensionParsers();

  /// Registers the source of credentials DartClaw stores on disk.
  ///
  /// Call this before [DartclawConfig.load] — typically in the CLI bootstrap,
  /// mirroring the [registerExtensionParser] pattern. [load] invokes the
  /// provider on *every* call, passing that load's [credentialsDir], and merges
  /// the result into `credentials` with the store winning; a re-read therefore
  /// picks up a credential stored since the last one, and no re-read path can
  /// forget the snapshot.
  ///
  /// This package opens no credential file: the registered closure owns the
  /// store, and owns the contract that an unusable one reads as no credentials.
  static void registerStoredCredentialProvider(Map<String, CredentialEntry> Function(String credentialsDir) provider) {
    _registerStoredCredentialProvider(provider);
  }

  /// Removes the registered stored-credential provider.
  ///
  /// Only for use in tests — call in [setUp]/[tearDown] to avoid cross-test
  /// registration leakage.
  @visibleForTesting
  static void clearStoredCredentialProvider() => _clearStoredCredentialProvider();

  /// Built-in top-level config keys known to the parser.
  @visibleForTesting
  static Set<String> knownTopLevelKeysForTesting() => _knownConfigKeys();

  /// Runs the load-time acceptance sweep over [yaml].
  ///
  /// [fields] and [tolerated] default to the live registry and accept-set; a
  /// test overrides them to exercise a deregistration this build has not made.
  @visibleForTesting
  static ConfigPathSweep sweepConfigPathsForTesting(
    Map<Object?, Object?> yaml, {
    Set<String> extensionKeys = const {},
    Map<String, FieldMeta> fields = ConfigMeta.fields,
    Map<String, ToleratedLegacyKey> tolerated = ConfigMeta.toleratedLegacyKeys,
  }) => _sweepConfigPaths(yaml, extensionKeys: extensionKeys, fields: fields, tolerated: tolerated);

  /// Registered extension parser keys.
  @visibleForTesting
  static Set<String> registeredExtensionKeysForTesting() => _registeredExtensionKeys();

  /// Returns the parsed extension section of type [T] registered under [name].
  ///
  /// Throws [StateError] if no extension is present for [name].
  /// Throws [ArgumentError] if the stored value is not assignable to [T].
  T extension<T>(String name) {
    if (!extensions.containsKey(name)) {
      throw StateError('No extension registered for "$name".');
    }
    final ext = extensions[name];
    if (ext is T) return ext;
    throw ArgumentError('Extension "$name" is ${ext.runtimeType}, not assignable to $T.');
  }

  /// Runs [parse] against this config's live load-warning sink, so warnings a
  /// parser outside this package emits reach [warnings] and
  /// [reloadBlockingWarnings] exactly like a built-in section's. A plain string
  /// added to the sink is blocking; mark an advisory with `addConfigAdvisory`,
  /// which this package exports for that purpose.
  ///
  /// The sink handed to [parse] is the collector itself. Rebuilding one from
  /// [warnings] instead would demote every advisory entry to blocking, because
  /// that getter returns an unmodifiable view rather than the collector.
  T parseWithLoadWarnings<T>(T Function(List<String> warns) parse) => parse(_warningSink());

  /// Load config with resolution: CLI overrides > YAML file > defaults.
  ///
  /// [configPath] — explicit config file path (e.g. from `--config` flag).
  ///   Takes precedence over `DARTCLAW_CONFIG` env var and CWD discovery.
  /// [cliOverrides] — key/value pairs from CLI flags (snake_case keys).
  /// [env] — environment variables (defaults to `Platform.environment`).
  /// [fileReader] — returns file contents or null; injectable for tests.
  factory load({
    String? configPath,
    Map<String, String>? cliOverrides,
    Map<String, String>? env,
    String? Function(String path)? fileReader,
  }) {
    final environment = env ?? Platform.environment;
    final reader = fileReader ?? _defaultFileReader;
    final cli = cliOverrides ?? {};
    final warns = ConfigLoadWarnings();

    final yaml = _loadYaml(environment, reader, warns, configPath: configPath);
    final configBaseDir = _loadedConfigBaseDir(environment, configPath: configPath);

    final server = _parseTopLevel(
      yaml,
      cli,
      environment,
      const ServerConfig.defaults(),
      warns,
      configBaseDir: configBaseDir,
    );
    final logging = _parseLogging(yaml, cli, environment, const LoggingConfig.defaults(), warns);
    final agent = _parseAgent(yaml, const AgentConfig.defaults(), warns);
    final auth = _parseAuth(yaml, const AuthConfig.defaults(), warns);
    final gateway = _parseGateway(yaml, environment, const GatewayConfig.defaults(), warns);
    final sessions = _parseSessions(yaml, const SessionConfig.defaults(), warns);
    final context = _parseContext(yaml, const ContextConfig.defaults(), warns);
    final workspace = _parseWorkspace(yaml, const WorkspaceConfig.defaults(), warns);
    final onboarding = _parseOnboarding(yaml, const OnboardingConfig.defaults(), warns);
    final workflow = parseWorkflowConfig(_sectionMap('workflow', yaml, warns), warns, env: environment);
    final scheduling = _parseScheduling(yaml, const SchedulingConfig.defaults(), warns);
    final credentials = _parseCredentials(
      yaml,
      environment,
      const CredentialsConfig.defaults(),
      warns,
      stored: _storedCredentials(credentialsDirFor(server.dataDir), warns),
    );
    final harness = _parseHarness(yaml, const HarnessConfig.defaults(), warns);
    // These sections reference credentials by name, so they parse after it.
    final search = _parseSearch(yaml, environment, const SearchConfig.defaults(), warns, credentials);
    final mcpServers = _parseMcpServers(yaml, credentials, const McpServersConfig.defaults(), warns);
    final providers = _parseProviders(yaml, environment, const ProvidersConfig.defaults(), warns);
    final security = _parseSecurity(yaml, const SecurityConfig.defaults(), warns);
    final usage = _parseUsage(yaml, const UsageConfig.defaults(), warns);
    final memory = _parseMemory(yaml, cli, const MemoryConfig.defaults(), warns);
    final knowledge = _parseKnowledge(yaml, const KnowledgeConfig.defaults(), warns);
    final container = _parseContainer(yaml, warns);
    final channels = _parseChannels(yaml, warns);
    final tasks = _parseTasks(yaml, const TaskConfig.defaults(), warns);
    final governance = _parseGovernance(yaml, const GovernanceConfig.defaults(), warns);
    final features = _parseFeatures(yaml);
    final projects = parseProjectConfig(_sectionMap('projects', yaml, warns), warns, base: configBaseDir);
    final alerts = _parseAlerts(yaml, const AlertsConfig.defaults(), warns);
    _warnRetiredAndthenConfig(yaml, warns);
    _warnRemovedAgentOrchestrationConfig(yaml, warns);
    final extensions = _parseExtensions(yaml, warns);

    final config = DartclawConfig(
      server: server,
      agent: agent,
      auth: auth,
      gateway: gateway,
      harness: harness,
      sessions: sessions,
      context: context,
      security: security,
      memory: memory,
      knowledge: knowledge,
      search: search,
      mcpServers: mcpServers,
      providers: providers,
      credentials: credentials,
      tasks: tasks,
      scheduling: scheduling,
      workspace: workspace,
      onboarding: onboarding,
      workflow: workflow,
      logging: logging,
      usage: usage,
      container: container,
      channels: channels,
      governance: governance,
      features: features,
      projects: projects,
      alerts: alerts,
      extensions: extensions,
      warnings: warns,
    );

    // An unset posture has no answer yet: the runtime probe that settles it
    // cannot run inside synchronous parsing, so resolution re-runs this.
    if (container.declaredEnabled != null) validateExecutionPolicySelections(config);
    return config;
  }

  List<String> _warningSink() => _lazyLoadWarnings[this] ??= ConfigLoadWarnings.copy(_warnings);
}

final Expando<List<String>> _lazyLoadWarnings = Expando('configLoadWarnings');
