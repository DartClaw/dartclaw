/// Shared policy helpers for Claude provider options.
///
/// Covers the two orthogonal trusted-run axes that mirror the Codex provider's
/// vocabulary: [approvalKey] (prompt gating → Claude permission-mode) and
/// [sandboxKey] (OS isolation → Claude `sandbox` settings block). The axes are
/// independent: an `approval` value never changes the sandbox block, and a
/// `sandbox` value never relaxes prompt gating.
final class ClaudeProviderOptions {
  /// Provider option key for direct Claude user-scope settings inheritance.
  static const inheritUserSettingsKey = 'inherit_user_settings';

  /// Default for [inheritUserSettings] when the option is absent or invalid.
  static const defaultInheritUserSettings = true;

  /// Provider option key for the prompt-gating (approval) axis.
  static const approvalKey = 'approval';

  /// Provider option key for the OS-isolation (sandbox) axis.
  static const sandboxKey = 'sandbox';

  /// Accepted `approval` values (the Codex provider vocabulary, reused).
  static const approvalValues = {'on-request', 'unless-allow-listed', 'never'};

  /// Accepted coarse string `sandbox` values (the Codex provider vocabulary).
  ///
  /// A map-valued `sandbox` is a raw native Claude settings block and bypasses
  /// this vocabulary entirely (advanced escape hatch).
  static const sandboxValues = {'read-only', 'workspace-write', 'danger-full-access'};

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

  /// Returns the validated coarse `approval` string from [options], or `null`
  /// when absent or not one of [approvalValues].
  static String? approval(Map<String, dynamic> options) {
    final value = options[approvalKey];
    return value is String && approvalValues.contains(value) ? value : null;
  }

  /// Whether the resolved [approval] opts the run into full access (no prompt
  /// gating). `never` is the only full-access value; every other value keeps the
  /// allow-list + `dontAsk` default.
  static bool isFullAccessApproval(Map<String, dynamic> options) => approval(options) == 'never';

  /// Maps the coarse `approval` value to a Claude permission-mode, or `null`
  /// when the value keeps the current default (`dontAsk` + allow-list).
  ///
  /// Claude's one-shot path has no interactive prompt channel, so only `never`
  /// translates (to `bypassPermissions`); `on-request`/`unless-allow-listed`
  /// fall through to the allow-list default.
  static String? approvalPermissionMode(Map<String, dynamic> options) =>
      isFullAccessApproval(options) ? 'bypassPermissions' : null;

  /// Returns the validated coarse `sandbox` string from [options], or `null`
  /// when absent, map-valued (raw native passthrough), or not one of
  /// [sandboxValues].
  static String? coarseSandbox(Map<String, dynamic> options) {
    final value = options[sandboxKey];
    return value is String && sandboxValues.contains(value) ? value : null;
  }
}
