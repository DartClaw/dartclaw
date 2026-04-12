/// Configuration for the auth subsystem.
class AuthConfig {
  final bool cookieSecure;
  final List<String> trustedProxies;

  const AuthConfig({this.cookieSecure = false, this.trustedProxies = const []});

  /// Default configuration.
  const AuthConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AuthConfig && cookieSecure == other.cookieSecure && _listEquals(trustedProxies, other.trustedProxies);

  @override
  int get hashCode => Object.hash(cookieSecure, Object.hashAll(trustedProxies));

  static bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
