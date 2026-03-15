/// Configuration for the guard system, parsed from `guards:` section of dartclaw.yaml.
class GuardConfig {
  /// Whether unexpected guard failures should warn instead of block.
  final bool failOpen;

  /// Whether the guard pipeline is enabled at all.
  final bool enabled;

  /// Creates the top-level guard configuration.
  const GuardConfig({this.failOpen = false, this.enabled = true});

  /// Safe defaults: fail-closed, guards enabled.
  const GuardConfig.defaults() : this();

  /// Parses from YAML map. Unknown keys and type errors produce warnings
  /// (appended to [warns]) and fall back to defaults.
  factory GuardConfig.fromYaml(Map<String, dynamic> yaml, List<String> warns) {
    const knownKeys = {'fail_open', 'enabled', 'command', 'file', 'network', 'content', 'input_sanitizer'};
    final defaults = const GuardConfig.defaults();

    for (final key in yaml.keys) {
      if (!knownKeys.contains(key)) {
        warns.add('Unknown guards config key: $key');
      }
    }

    final failOpen = _parseBool('fail_open', yaml['fail_open'], defaults.failOpen, warns);
    final enabled = _parseBool('enabled', yaml['enabled'], defaults.enabled, warns);

    return GuardConfig(failOpen: failOpen, enabled: enabled);
  }

  static bool _parseBool(String key, Object? value, bool defaultValue, List<String> warns) {
    if (value == null) return defaultValue;
    if (value is bool) return value;
    if (value is String) {
      if (value == 'true') return true;
      if (value == 'false') return false;
    }
    warns.add('Invalid type for guards.$key: "${value.runtimeType}" — using default');
    return defaultValue;
  }
}
