import 'package:collection/collection.dart';

const _mcpServerEntriesEquality = MapEquality<String, McpServerEntry>();
const _stringListEquality = ListEquality<String>();

/// Per-server outbound call rate-limit configuration.
class McpServerRateLimit {
  /// Maximum calls allowed within [window].
  final int calls;

  /// Sliding window used for [calls].
  final Duration window;

  /// Creates a per-server call rate limit.
  const McpServerRateLimit({this.calls = 0, this.window = const Duration(minutes: 1)});

  /// Whether this limit is disabled.
  bool get isDisabled => calls <= 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is McpServerRateLimit && calls == other.calls && window == other.window;

  @override
  int get hashCode => Object.hash(calls, window);
}

/// Per-server outbound token-budget configuration.
class McpServerTokenBudget {
  /// Maximum outbound-call tokens allowed within [window].
  final int tokens;

  /// Window used for [tokens].
  final Duration window;

  /// Creates a per-server token budget.
  const McpServerTokenBudget({this.tokens = 0, this.window = const Duration(minutes: 1)});

  /// Whether this budget is disabled.
  bool get isDisabled => tokens <= 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is McpServerTokenBudget && tokens == other.tokens && window == other.window;

  @override
  int get hashCode => Object.hash(tokens, window);
}

/// Network risk class for an external MCP server.
enum McpNetworkClass {
  /// Loopback or same-host subprocess/network access.
  local('local'),

  /// Private-network egress.
  private('private'),

  /// Public internet egress.
  public('public');

  /// YAML value for this network class.
  final String yamlValue;

  const McpNetworkClass(this.yamlValue);

  /// Accepted YAML values.
  static const knownValues = <String>['local', 'private', 'public'];

  /// Parses a YAML value into a network class.
  static McpNetworkClass? fromYaml(String value) {
    final normalized = value.trim();
    for (final networkClass in values) {
      if (networkClass.yamlValue == normalized) return networkClass;
    }
    return null;
  }
}

/// Configuration for a single external MCP server.
class McpServerEntry {
  /// Stdio command used to start the server.
  final String? command;

  /// HTTP endpoint URL for the server.
  final String? url;

  /// Whether this server is available to the outbound MCP client.
  final bool enabled;

  /// Network risk class used by the egress guard.
  final McpNetworkClass networkClass;

  /// Credential entry name referenced by this server.
  final String? credential;

  /// Optional call rate limit for this server.
  final McpServerRateLimit rateLimit;

  /// Optional token budget for this server.
  final McpServerTokenBudget tokenBudget;

  /// Tools allowed through the outbound egress guard. Empty means no tools allowed.
  final List<String> allowTools;

  /// Tools surfaced to harness-facing tool lists. Empty means no tools surfaced.
  final List<String> surfaceTools;

  /// Creates a [McpServerEntry] value.
  const McpServerEntry({
    this.command,
    this.url,
    this.enabled = true,
    required this.networkClass,
    this.credential,
    this.rateLimit = const McpServerRateLimit(),
    this.tokenBudget = const McpServerTokenBudget(),
    this.allowTools = const [],
    this.surfaceTools = const [],
  }) : assert((command == null) != (url == null), 'Exactly one of command or url must be set.');

  /// Whether this server uses stdio transport.
  bool get isStdio => command != null;

  /// Whether this server uses HTTP transport.
  bool get isHttp => url != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is McpServerEntry &&
          command == other.command &&
          url == other.url &&
          enabled == other.enabled &&
          networkClass == other.networkClass &&
          credential == other.credential &&
          rateLimit == other.rateLimit &&
          tokenBudget == other.tokenBudget &&
          _stringListEquality.equals(allowTools, other.allowTools) &&
          _stringListEquality.equals(surfaceTools, other.surfaceTools);

  @override
  int get hashCode => Object.hash(
    command,
    url,
    enabled,
    networkClass,
    credential,
    rateLimit,
    tokenBudget,
    _stringListEquality.hash(allowTools),
    _stringListEquality.hash(surfaceTools),
  );

  @override
  String toString() =>
      'McpServerEntry(command: $command, url: $url, enabled: $enabled, '
      'networkClass: ${networkClass.yamlValue}, credential: $credential, '
      'rateLimit: ${rateLimit.calls}/${rateLimit.window}, '
      'tokenBudget: ${tokenBudget.tokens}/${tokenBudget.window}, '
      'allowTools: $allowTools, '
      'surfaceTools: $surfaceTools)';
}

/// External MCP server registry configuration.
class McpServersConfig {
  /// Server entries keyed by operator-defined server name.
  final Map<String, McpServerEntry> entries;

  /// Creates a [McpServersConfig] value.
  const McpServersConfig({this.entries = const {}});

  /// Creates an empty [McpServersConfig].
  const McpServersConfig.defaults() : this();

  /// Returns the entry for [name], or `null` if not configured.
  McpServerEntry? operator [](String name) => entries[name];

  /// Whether no servers are configured.
  bool get isEmpty => entries.isEmpty;

  /// Validated registry surface consumed by outbound MCP runtime layers.
  Map<String, McpServerEntry> get enabledRegistry =>
      Map.unmodifiable(Map.fromEntries(entries.entries.where((entry) => entry.value.enabled)));

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is McpServersConfig && _mcpServerEntriesEquality.equals(entries, other.entries);

  @override
  int get hashCode => _mcpServerEntriesEquality.hash(entries);

  @override
  String toString() => 'McpServersConfig(entries: $entries)';
}
