import 'dartclaw_config.dart';

/// Immutable snapshot of a configuration change produced by [ConfigNotifier].
///
/// Contains the previous and current [DartclawConfig], plus the set of
/// top-level section keys that changed (in the form `sectionName.*`).
///
/// Use [hasChanged] or [hasChangedAny] to check whether a specific key or
/// section is included in this delta before extracting values from [current].
class ConfigDelta {
  /// The configuration before the reload.
  final DartclawConfig previous;

  /// The configuration after the reload.
  final DartclawConfig current;

  /// Set of changed section keys, expressed as `sectionName.*` glob patterns
  /// (e.g. `'scheduling.*'`, `'security.*'`).
  final Set<String> changedKeys;

  const ConfigDelta({
    required this.previous,
    required this.current,
    required this.changedKeys,
  });

  /// Returns `true` if [key] is represented in this delta.
  ///
  /// Matching is bidirectional prefix-based:
  /// - A glob key like `'scheduling.*'` matches a changed key `'scheduling.*'`.
  /// - A specific key like `'scheduling.heartbeat.enabled'` also matches a
  ///   changed key `'scheduling.*'` because the changed section contains that
  ///   watched field.
  bool hasChanged(String key) {
    if (changedKeys.contains(key)) return true;
    // Specific watch key matches a section-level changed key if the watch key
    // starts with that section prefix (e.g. 'alerts.enabled' matches 'alerts.*').
    for (final changed in changedKeys) {
      if (changed.endsWith('.*')) {
        final prefix = changed.substring(0, changed.length - 2);
        if (key == changed || key.startsWith('$prefix.')) return true;
      }
    }
    // A glob watch key (e.g. 'scheduling.*') matches a changed key that starts
    // with the same prefix.
    if (key.endsWith('.*')) {
      final prefix = key.substring(0, key.length - 2);
      for (final changed in changedKeys) {
        if (changed == key || changed.startsWith('$prefix.')) return true;
      }
    }
    return false;
  }

  /// Returns `true` if any of the [keys] matches a changed key.
  bool hasChangedAny(Iterable<String> keys) => keys.any(hasChanged);

  /// Whether this delta contains at least one changed key.
  bool get isEmpty => changedKeys.isEmpty;
}
