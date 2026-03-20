import 'session_scope_config.dart';

/// Mutable wrapper for the current session scope configuration.
class LiveScopeConfig {
  SessionScopeConfig _current;

  LiveScopeConfig(SessionScopeConfig initialConfig) : _current = initialConfig;

  SessionScopeConfig get current => _current;

  void update(SessionScopeConfig newConfig) {
    _current = newConfig;
  }
}
