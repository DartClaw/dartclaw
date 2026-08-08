import 'package:collection/collection.dart';

/// Configuration for the auth subsystem.
class AuthConfig {
  /// cookieSecure.
  final bool cookieSecure;

  /// trustedProxies.
  final List<String> trustedProxies;

  /// const AuthConfig({this.cookieSecure = false, this.trustedPro.
  const AuthConfig({this.cookieSecure = false, this.trustedProxies = const []});

  /// Default configuration.
  const AuthConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AuthConfig &&
          cookieSecure == other.cookieSecure &&
          const ListEquality<String>().equals(trustedProxies, other.trustedProxies);

  @override
  int get hashCode => Object.hash(cookieSecure, Object.hashAll(trustedProxies));
}
