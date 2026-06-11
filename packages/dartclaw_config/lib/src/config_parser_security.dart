part of 'dartclaw_config.dart';

SecurityConfig _parseSecurity(Map<String, dynamic> yaml, SecurityConfig defaults, List<String> warns) {
  final guardsMap = readMap('guards', yaml, warns);
  final guardsYaml = guardsMap ?? <String, dynamic>{};
  final guards = guardsMap == null
      ? const GuardConfig.defaults()
      : () {
          try {
            return GuardConfig.fromYaml(guardsYaml, warns);
          } catch (e) {
            warns.add('Error parsing guards config: $e — using defaults');
            return const GuardConfig.defaults();
          }
        }();

  var contentGuardEnabled = defaults.contentGuardEnabled;
  var contentGuardClassifier = defaults.contentGuardClassifier;
  var contentGuardModel = defaults.contentGuardModel;
  var contentGuardMaxBytes = defaults.contentGuardMaxBytes;
  final contentMap = guardsMap != null ? readMap('content', guardsMap, warns) : null;
  if (contentMap != null) {
    contentGuardEnabled =
        readBool('enabled', contentMap, warns, defaultValue: contentGuardEnabled) ?? contentGuardEnabled;
    final classifierVal = readString('classifier', contentMap, warns);
    if (classifierVal != null) {
      if (classifierVal == 'claude_binary' || classifierVal == 'anthropic_api') {
        contentGuardClassifier = classifierVal;
      } else {
        warns.add('Invalid guards.content.classifier: "$classifierVal" — using default');
      }
    }
    final modelVal = readString('model', contentMap, warns);
    if (modelVal != null) contentGuardModel = modelVal;
    contentGuardMaxBytes =
        readInt('max_bytes', contentMap, warns, defaultValue: defaults.contentGuardMaxBytes) ??
        defaults.contentGuardMaxBytes;
  }

  var inputSanitizerEnabled = defaults.inputSanitizerEnabled;
  var inputSanitizerChannelsOnly = defaults.inputSanitizerChannelsOnly;
  final isMap = guardsMap != null ? readMap('input_sanitizer', guardsMap, warns) : null;
  if (isMap != null) {
    inputSanitizerEnabled =
        readBool('enabled', isMap, warns, defaultValue: inputSanitizerEnabled) ?? inputSanitizerEnabled;
    inputSanitizerChannelsOnly =
        readBool('channels_only', isMap, warns, defaultValue: inputSanitizerChannelsOnly) ?? inputSanitizerChannelsOnly;
  }

  var bashStepEnvAllowlist = List<String>.from(defaults.bashStep.envAllowlist);
  var bashStepExtraStripPatterns = List<String>.from(defaults.bashStep.extraStripPatterns);
  final securityMap = readMap('security', yaml, warns);
  final bashStepMap = securityMap != null ? readMap('bash_step', securityMap, warns) : null;
  if (bashStepMap != null) {
    final allowlistList = readField<List<dynamic>>('env_allowlist', bashStepMap, warns);
    if (allowlistList != null) {
      final extensions = allowlistList.whereType<String>().map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      for (final e in allowlistList.where((e) => e is! String || e.trim().isEmpty)) {
        warns.add('Invalid value for security.bash_step.env_allowlist entry: "$e" — ignoring');
      }
      bashStepEnvAllowlist = {...defaults.bashStep.envAllowlist, ...extensions}.toList()..sort();
    }

    final extraStripList = readField<List<dynamic>>('extra_strip_patterns', bashStepMap, warns);
    if (extraStripList != null) {
      for (final e in extraStripList.where((e) => e is! String || e.trim().isEmpty)) {
        warns.add('Invalid value for security.bash_step.extra_strip_patterns entry: "$e" — ignoring');
      }
      bashStepExtraStripPatterns = extraStripList
          .whereType<String>()
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
  }

  final guardAuditMap = readMap('guard_audit', yaml, warns);
  if (guardAuditMap != null && guardAuditMap.containsKey('max_entries')) {
    warns.add(
      'guard_audit.max_entries is deprecated and ignored — '
      'use guard_audit.max_retention_days for audit retention',
    );
  }
  final guardAuditMaxRetentionDays =
      ((readInt('max_retention_days', guardAuditMap ?? {}, warns, defaultValue: defaults.guardAuditMaxRetentionDays) ??
              defaults.guardAuditMaxRetentionDays))
          .clamp(0, 365);

  return SecurityConfig(
    guards: guards,
    guardsYaml: guardsYaml,
    bashStep: SecurityBashStepConfig(
      envAllowlist: bashStepEnvAllowlist,
      extraStripPatterns: bashStepExtraStripPatterns,
    ),
    contentGuardEnabled: contentGuardEnabled,
    contentGuardClassifier: contentGuardClassifier,
    contentGuardModel: contentGuardModel,
    contentGuardMaxBytes: contentGuardMaxBytes,
    inputSanitizerEnabled: inputSanitizerEnabled,
    inputSanitizerChannelsOnly: inputSanitizerChannelsOnly,
    guardAuditMaxRetentionDays: guardAuditMaxRetentionDays,
  );
}
