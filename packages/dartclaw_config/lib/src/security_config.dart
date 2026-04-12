import 'package:collection/collection.dart';
import 'package:dartclaw_security/dartclaw_security.dart';

/// Configuration for the security subsystem.
class SecurityConfig {
  final GuardConfig guards;
  final Map<String, dynamic> guardsYaml;
  final bool contentGuardEnabled;
  final String contentGuardClassifier;
  final String contentGuardModel;
  final int contentGuardMaxBytes;
  final bool inputSanitizerEnabled;
  final bool inputSanitizerChannelsOnly;
  final int guardAuditMaxRetentionDays;

  const SecurityConfig({
    this.guards = const GuardConfig.defaults(),
    this.guardsYaml = const {},
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
    contentGuardEnabled,
    contentGuardClassifier,
    contentGuardModel,
    contentGuardMaxBytes,
    inputSanitizerEnabled,
    inputSanitizerChannelsOnly,
    guardAuditMaxRetentionDays,
  );
}
