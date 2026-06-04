/// Shared policy helpers for Claude provider options.
final class ClaudeProviderOptions {
  /// Provider option key for direct Claude user-scope settings inheritance.
  static const inheritUserSettingsKey = 'inherit_user_settings';

  /// Default for [inheritUserSettings] when the option is absent or invalid.
  static const defaultInheritUserSettings = true;

  const ClaudeProviderOptions._();

  /// Returns whether direct Claude spawns should inherit user-scope settings.
  static bool inheritUserSettings(Map<String, dynamic> options) {
    final value = options[inheritUserSettingsKey];
    return value is bool ? value : defaultInheritUserSettings;
  }

  /// Returns whether direct Claude spawns should force project-only settings.
  static bool useProjectSettingSources(Map<String, dynamic> options) => !inheritUserSettings(options);

  /// Normalizes a parsed `inherit_user_settings` value.
  static bool normalizeInheritUserSettings(Object? value) => value is bool ? value : defaultInheritUserSettings;
}
