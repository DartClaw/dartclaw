import 'package:collection/collection.dart';

import 'guard_config.dart';
import 'safe_process.dart';

/// class SecurityBashStepConfig {.
class SecurityBashStepConfig {
  /// envAllowlist.
  final List<String> envAllowlist;

  /// extraStripPatterns.
  final List<String> extraStripPatterns;

  /// Creates a [SecurityBashStepConfig] value.
  const new({this.envAllowlist = defaultBashStepEnvAllowlist, this.extraStripPatterns = const <String>[]});

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

  /// Whether a classification failure passes content through.
  ///
  /// False fails closed: content the classifier could not score is blocked.
  final bool contentGuardFailOpen;

  /// guardAuditMaxRetentionDays.
  final int guardAuditMaxRetentionDays;

  /// Creates a [SecurityConfig] value.
  const new({
    this.guards = const GuardConfig.defaults(),
    this.guardsYaml = const {},
    this.bashStep = const SecurityBashStepConfig(),
    this.contentGuardEnabled = true,
    this.contentGuardClassifier = 'claude_binary',
    this.contentGuardFailOpen = false,
    this.contentGuardModel = 'haiku',
    this.contentGuardMaxBytes = 50 * 1024,
    this.guardAuditMaxRetentionDays = 30,
  });

  /// Default configuration.
  const new defaults() : this();

  /// Returns a copy with the given fields replaced.
  SecurityConfig copyWith({
    GuardConfig? guards,
    Map<String, dynamic>? guardsYaml,
    SecurityBashStepConfig? bashStep,
    bool? contentGuardEnabled,
    String? contentGuardClassifier,
    bool? contentGuardFailOpen,
    String? contentGuardModel,
    int? contentGuardMaxBytes,
    int? guardAuditMaxRetentionDays,
  }) {
    return SecurityConfig(
      guards: guards ?? this.guards,
      guardsYaml: guardsYaml ?? this.guardsYaml,
      bashStep: bashStep ?? this.bashStep,
      contentGuardEnabled: contentGuardEnabled ?? this.contentGuardEnabled,
      contentGuardClassifier: contentGuardClassifier ?? this.contentGuardClassifier,
      contentGuardFailOpen: contentGuardFailOpen ?? this.contentGuardFailOpen,
      contentGuardModel: contentGuardModel ?? this.contentGuardModel,
      contentGuardMaxBytes: contentGuardMaxBytes ?? this.contentGuardMaxBytes,
      guardAuditMaxRetentionDays: guardAuditMaxRetentionDays ?? this.guardAuditMaxRetentionDays,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SecurityConfig &&
          guards == other.guards &&
          const DeepCollectionEquality().equals(guardsYaml, other.guardsYaml) &&
          bashStep == other.bashStep &&
          contentGuardEnabled == other.contentGuardEnabled &&
          contentGuardClassifier == other.contentGuardClassifier &&
          contentGuardFailOpen == other.contentGuardFailOpen &&
          contentGuardModel == other.contentGuardModel &&
          contentGuardMaxBytes == other.contentGuardMaxBytes &&
          guardAuditMaxRetentionDays == other.guardAuditMaxRetentionDays;

  @override
  int get hashCode => Object.hash(
    guards,
    const DeepCollectionEquality().hash(guardsYaml),
    bashStep,
    contentGuardEnabled,
    contentGuardClassifier,
    contentGuardFailOpen,
    contentGuardModel,
    contentGuardMaxBytes,
    guardAuditMaxRetentionDays,
  );
}
