import 'package:collection/collection.dart';

const _mcpClientsEquality = ListEquality<McpClientConfig>();

/// Configuration for the live-reload trigger.
class ReloadConfig {
  /// Reload trigger mode.
  ///
  /// - `'signal'` (default): reload on `SIGUSR1`; POSIX-only.
  /// - `'auto'`: reload through cross-platform file-watch; supported on Windows.
  /// - `'off'`: no reload triggers enabled.
  final String mode;

  /// Debounce delay in milliseconds for file-watch mode.
  ///
  /// Rapid successive file saves are coalesced into a single reload.
  /// Minimum: 100 ms. Default: 500 ms.
  final int debounceMs;

  /// const ReloadConfig({this.mode = 'signal', this.debounceMs = .
  const new({this.mode = 'signal', this.debounceMs = 500});

  /// Creates a [ReloadConfig.defaults] value.
  const new defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ReloadConfig && mode == other.mode && debounceMs == other.debounceMs;

  @override
  int get hashCode => Object.hash(mode, debounceMs);
}

/// One named MCP client permitted to reach `/mcp` in context-engine mode.
///
/// The token is always authored as a `${VAR}` reference: [tokenReference] keeps
/// the authored text so diagnostics, the config API and rendered pages can name
/// the credential, while [token] holds the resolved secret that only the `/mcp`
/// bearer comparison reads.
class McpClientConfig {
  /// Operator-chosen client name. The MCP audit principal is derived from it.
  final String name;

  /// Authored `${VAR}` text the token was resolved from.
  final String tokenReference;

  /// Resolved bearer credential. Never serialized, rendered or logged.
  final String token;

  /// Creates an [McpClientConfig] value.
  const new({required this.name, required this.tokenReference, required this.token});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is McpClientConfig && name == other.name && tokenReference == other.tokenReference && token == other.token;

  @override
  int get hashCode => Object.hash(name, tokenReference, token);
}

/// Configuration for the gateway subsystem.
class GatewayConfig {
  /// authMode.
  final String authMode;

  /// token.
  final String? token;

  /// hsts.
  final bool hsts;

  /// reload.
  final ReloadConfig reload;

  /// Named clients that may authenticate `/mcp` with their own token.
  ///
  /// Empty means context-engine mode is off and `/mcp` accepts the gateway
  /// token alone.
  final List<McpClientConfig> mcpClients;

  /// Creates a [GatewayConfig] value.
  const new({
    this.authMode = 'token',
    this.token,
    this.hsts = false,
    this.reload = const ReloadConfig.defaults(),
    this.mcpClients = const [],
  });

  /// Default configuration.
  const new defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GatewayConfig &&
          authMode == other.authMode &&
          token == other.token &&
          hsts == other.hsts &&
          reload == other.reload &&
          _mcpClientsEquality.equals(mcpClients, other.mcpClients);

  @override
  int get hashCode => Object.hash(authMode, token, hsts, reload, Object.hashAll(mcpClients));
}
