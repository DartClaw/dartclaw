/// Configuration for the gateway subsystem.
class GatewayConfig {
  final String authMode;
  final String? token;
  final bool hsts;

  const GatewayConfig({
    this.authMode = 'token',
    this.token,
    this.hsts = false,
  });

  /// Default configuration.
  const GatewayConfig.defaults() : this();
}
