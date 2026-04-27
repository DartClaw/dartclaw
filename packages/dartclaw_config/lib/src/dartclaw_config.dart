import 'dart:collection';
import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart'
    show
        AgentDefinition,
        ChannelConfig,
        ChannelConfigProvider,
        ChannelScopeConfig,
        ChannelType,
        ContainerConfig,
        DmScope,
        GroupScope,
        SessionScopeConfig;
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'agent_config.dart';
import 'advisor_config.dart';
import 'alerts_config.dart';
import 'andthen_config.dart';
import 'auth_config.dart';
import 'canvas_config.dart';
import 'context_config.dart';
import 'credentials_config.dart';
import 'duration_parser.dart' show tryParseDuration;
import 'features_config.dart';
import 'gateway_config.dart';
import 'governance_config.dart';
import 'history_config.dart';
import 'logging_config.dart';
import 'memory_config.dart';
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
import 'session_maintenance_config.dart';
import 'task_config.dart';
import 'usage_config.dart';
import 'workflow_config.dart';
import 'workspace_config.dart';

part 'config_channel_provider.dart';
part 'config_extensions.dart';
part 'config_parser.dart';
part 'config_parser_governance.dart';

/// Immutable configuration for DartClaw runtime.
class DartclawConfig {
  // --- Composed section fields ---
  final ServerConfig server;
  final AgentConfig agent;
  final AdvisorConfig advisor;
  final AuthConfig auth;
  final CanvasConfig canvas;
  final GatewayConfig gateway;
  final SessionConfig sessions;
  final ContextConfig context;
  final SecurityConfig security;
  final MemoryConfig memory;
  final SearchConfig search;
  final ProvidersConfig providers;
  final CredentialsConfig credentials;
  final TaskConfig tasks;
  final SchedulingConfig scheduling;
  final WorkspaceConfig workspace;
  final WorkflowConfig workflow;
  final LoggingConfig logging;
  final UsageConfig usage;
  final ContainerConfig container;
  final ChannelConfig channels;
  final GovernanceConfig governance;
  final FeaturesConfig features;
  final ProjectConfig projects;
  final AlertsConfig alerts;
  final AndthenConfig andthen;

  /// Extension sections registered by private deployers via [registerExtensionParser].
  /// Unknown YAML keys with registered parsers produce typed entries here.
  /// Unknown YAML keys without registered parsers are stored as raw values
  /// (map, scalar, list, or null) for lossless forward-compatibility.
  final Map<String, Object?> extensions;

  /// Warnings collected during [load] and channel config parsing.
  /// Callers are responsible for surfacing these.
  final List<String> _warnings;

  List<String> get warnings => UnmodifiableListView(_warningSink());
  ChannelConfigProvider get channelConfigProvider => _ConfigChannelConfigProvider(this);

  // --- Derived path getters ---
  String get workspaceDir => p.join(server.dataDir, 'workspace');
  String get sessionsDir => p.join(server.dataDir, 'sessions');
  String get logsDir => p.join(server.dataDir, 'logs');
  String get searchDbPath => p.join(server.dataDir, 'search.db');
  String get tasksDbPath => p.join(server.dataDir, 'tasks.db');
  String get kvPath => p.join(server.dataDir, 'kv.json');
  String get projectsJsonPath => p.join(server.dataDir, 'projects.json');
  String get projectsClonesDir => p.join(server.dataDir, 'projects');

  const DartclawConfig({
    this.server = const ServerConfig.defaults(),
    this.agent = const AgentConfig.defaults(),
    this.advisor = const AdvisorConfig.defaults(),
    this.auth = const AuthConfig.defaults(),
    this.canvas = const CanvasConfig.defaults(),
    this.gateway = const GatewayConfig.defaults(),
    this.sessions = const SessionConfig.defaults(),
    this.context = const ContextConfig.defaults(),
    this.security = const SecurityConfig.defaults(),
    this.memory = const MemoryConfig.defaults(),
    this.search = const SearchConfig.defaults(),
    this.providers = const ProvidersConfig.defaults(),
    this.credentials = const CredentialsConfig.defaults(),
    this.tasks = const TaskConfig.defaults(),
    this.scheduling = const SchedulingConfig.defaults(),
    this.workspace = const WorkspaceConfig.defaults(),
    this.workflow = const WorkflowConfig.defaults(),
    this.logging = const LoggingConfig.defaults(),
    this.usage = const UsageConfig.defaults(),
    this.container = const ContainerConfig.disabled(),
    this.channels = const ChannelConfig.defaults(),
    this.governance = const GovernanceConfig.defaults(),
    this.features = const FeaturesConfig(),
    this.projects = const ProjectConfig.defaults(),
    this.alerts = const AlertsConfig.defaults(),
    this.andthen = const AndthenConfig.defaults(),
    this.extensions = const {},
    List<String> warnings = const [],
  }) : _warnings = warnings;

  /// All default values.
  const DartclawConfig.defaults() : this();

  /// Registers a parser for a channel config type that lives outside core.
  ///
  /// Channel packages currently call this from top-level import side effects in
  /// their public libraries. Bootstrap code that bundles channels must import
  /// those packages and ensure registration before calling [DartclawConfig.load].
  static void registerChannelConfigParser(
    ChannelType channelType,
    Object Function(Map<String, dynamic> yaml, List<String> warns) parser,
  ) {
    _registerChannelConfigParser(channelType, parser);
  }

  /// Registers a parser for a custom top-level YAML section.
  ///
  /// Call this before [DartclawConfig.load] — typically in the private
  /// overlay's bootstrap, mirroring the [registerChannelConfigParser] pattern.
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

  T getChannelConfig<T>(ChannelType channelType) {
    final cachedConfig = _channelConfigForConfig(this, channelType);
    if (cachedConfig is! T) {
      throw ArgumentError(
        'Channel ${channelType.name} expects ${cachedConfig.runtimeType}, which is not assignable to $T.',
      );
    }
    return cachedConfig as T;
  }

  /// Load config with resolution: CLI overrides > YAML file > defaults.
  ///
  /// [configPath] — explicit config file path (e.g. from `--config` flag).
  ///   Takes precedence over `DARTCLAW_CONFIG` env var and CWD discovery.
  /// [cliOverrides] — key/value pairs from CLI flags (snake_case keys).
  /// [env] — environment variables (defaults to `Platform.environment`).
  /// [fileReader] — returns file contents or null; injectable for tests.
  factory DartclawConfig.load({
    String? configPath,
    Map<String, String>? cliOverrides,
    Map<String, String>? env,
    String? Function(String path)? fileReader,
  }) {
    final environment = env ?? Platform.environment;
    final reader = fileReader ?? _defaultFileReader;
    final cli = cliOverrides ?? {};
    final warns = <String>[];

    final yaml = _loadYaml(environment, reader, warns, configPath: configPath);

    final server = _parseTopLevel(yaml, cli, environment, const ServerConfig.defaults(), warns);
    final logging = _parseLogging(yaml, cli, environment, const LoggingConfig.defaults(), warns);
    final agent = _parseAgent(yaml, const AgentConfig.defaults(), warns);
    final advisor = _parseAdvisor(yaml, const AdvisorConfig.defaults(), warns);
    final auth = _parseAuth(yaml, const AuthConfig.defaults(), warns);
    final canvas = _parseCanvas(yaml, const CanvasConfig.defaults(), warns);
    final gateway = _parseGateway(yaml, environment, const GatewayConfig.defaults(), warns);
    final sessions = _parseSessions(yaml, const SessionConfig.defaults(), warns);
    final context = _parseContext(yaml, const ContextConfig.defaults(), warns);
    final workspace = _parseWorkspace(yaml, const WorkspaceConfig.defaults(), warns);
    final workflow = parseWorkflowConfig(_sectionMap('workflow', yaml, warns), warns, env: environment);
    final scheduling = _parseScheduling(yaml, const SchedulingConfig.defaults(), warns);
    final search = _parseSearch(yaml, environment, const SearchConfig.defaults(), warns);
    final providers = _parseProviders(yaml, environment, const ProvidersConfig.defaults(), warns);
    final credentials = _parseCredentials(yaml, environment, const CredentialsConfig.defaults(), warns);
    final security = _parseSecurity(yaml, const SecurityConfig.defaults(), warns);
    final usage = _parseUsage(yaml, const UsageConfig.defaults(), warns);
    final memory = _parseMemory(yaml, cli, const MemoryConfig.defaults(), warns);
    final container = _parseContainer(yaml, warns);
    final channels = _parseChannels(yaml, warns);
    final tasks = _parseTasks(yaml, const TaskConfig.defaults(), warns);
    final governance = _parseGovernance(yaml, const GovernanceConfig.defaults(), warns);
    final features = _parseFeatures(yaml);
    final projects = parseProjectConfig(_sectionMap('projects', yaml, warns), warns);
    final alerts = _parseAlerts(yaml, const AlertsConfig.defaults(), warns);
    final andthen = _parseAndthen(yaml, const AndthenConfig.defaults(), warns);
    final extensions = _parseExtensions(yaml, warns);

    final config = DartclawConfig(
      server: server,
      agent: agent,
      advisor: advisor,
      auth: auth,
      canvas: canvas,
      gateway: gateway,
      sessions: sessions,
      context: context,
      security: security,
      memory: memory,
      search: search,
      providers: providers,
      credentials: credentials,
      tasks: tasks,
      scheduling: scheduling,
      workspace: workspace,
      workflow: workflow,
      logging: logging,
      usage: usage,
      container: container,
      channels: channels,
      governance: governance,
      features: features,
      projects: projects,
      alerts: alerts,
      andthen: andthen,
      extensions: extensions,
      warnings: warns,
    );

    config._primeChannelConfigs();
    return config;
  }

  void _primeChannelConfigs() => _primeChannelConfigsForConfig(this);

  List<String> _warningSink() => _warningSinkForConfig(this);
}
