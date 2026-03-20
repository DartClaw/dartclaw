/// Configuration for the auth subsystem.
class AuthConfig {
  final bool cookieSecure;
  final List<String> trustedProxies;

  const AuthConfig({
    this.cookieSecure = false,
    this.trustedProxies = const [],
  });

  /// Default configuration.
  const AuthConfig.defaults() : this();
}
