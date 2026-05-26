import 'package:collection/collection.dart';
import 'package:dartclaw_security/dartclaw_security.dart';

/// class SecurityBashStepConfig {.
class SecurityBashStepConfig {
  /// envAllowlist.
  final List<String> envAllowlist;

  /// extraStripPatterns.
  final List<String> extraStripPatterns;

  /// Creates a [SecurityBashStepConfig] value.
  const SecurityBashStepConfig({
    this.envAllowlist = defaultBashStepEnvAllowlist,
    this.extraStripPatterns = const <String>[],
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SecurityBashStepConfig &&
          const DeepCollectionEquality().equals(envAllowlist, other.envAllowlist) &&
          const DeepCollectionEquality().equals(extraStripPatterns, other.extraStripPatterns);

  @override
  int get hashCode => Object.hash(
    const DeepCollectionEquality().hash(envAllowlist),
    const DeepCollectionEquality().hash(extraStripPatterns),
  );
}

/// Configuration for the security subsystem.
class SecurityConfig {
  /// guards.
  final GuardConfig guards;

  /// guardsYaml.
  final Map<String, dynamic> guardsYaml;

  /// bashStep.
  final SecurityBashStepConfig bashStep;

  /// contentGuardEnabled.
  final bool contentGuardEnabled;

  /// contentGuardClassifier.
  final String contentGuardClassifier;

  /// contentGuardModel.
  final String contentGuardModel;

  /// contentGuardMaxBytes.
  final int contentGuardMaxBytes;

  /// inputSanitizerEnabled.
  final bool inputSanitizerEnabled;

  /// inputSanitizerChannelsOnly.
  final bool inputSanitizerChannelsOnly;

  /// guardAuditMaxRetentionDays.
  final int guardAuditMaxRetentionDays;

  /// Creates a [SecurityConfig] value.
  const SecurityConfig({
    this.guards = const GuardConfig.defaults(),
    this.guardsYaml = const {},
    this.bashStep = const SecurityBashStepConfig(),
    this.contentGuardEnabled = true,
    this.contentGuardClassifier = 'claude_binary',
    this.contentGuardModel = 'haiku',
    this.contentGuardMaxBytes = 50 * 1024,
    this.inputSanitizerEnabled = true,
    this.inputSanitizerChannelsOnly = true,
    this.guardAuditMaxRetentionDays = 30,
  });

  /// Default configuration.
  const SecurityConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SecurityConfig &&
          guards == other.guards &&
          const DeepCollectionEquality().equals(guardsYaml, other.guardsYaml) &&
          bashStep == other.bashStep &&
          contentGuardEnabled == other.contentGuardEnabled &&
          contentGuardClassifier == other.contentGuardClassifier &&
          contentGuardModel == other.contentGuardModel &&
          contentGuardMaxBytes == other.contentGuardMaxBytes &&
          inputSanitizerEnabled == other.inputSanitizerEnabled &&
          inputSanitizerChannelsOnly == other.inputSanitizerChannelsOnly &&
          guardAuditMaxRetentionDays == other.guardAuditMaxRetentionDays;

  @override
  int get hashCode => Object.hash(
    guards,
    const DeepCollectionEquality().hash(guardsYaml),
    bashStep,
    contentGuardEnabled,
    contentGuardClassifier,
    contentGuardModel,
    contentGuardMaxBytes,
    inputSanitizerEnabled,
    inputSanitizerChannelsOnly,
    guardAuditMaxRetentionDays,
  );
}
