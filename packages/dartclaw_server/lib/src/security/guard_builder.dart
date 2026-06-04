import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show ToolPolicyCascade, ToolPolicyGuard;
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:path/path.dart' as p;

const _fileAccessLevels = {'no_access', 'read_only', 'no_delete'};

/// Builds a [List<Guard>] from [SecurityConfig], performing deduplication and
/// conflict detection on the extra rules before constructing guard instances.
///
/// Returns [GuardBuildSuccess] with the guards and any deduplication warnings,
/// or [GuardBuildFailure] with error descriptions when the config is invalid
/// (bad regex, conflicting rules). The caller decides whether to swap the chain
/// or log and preserve the existing one.
///
/// [toolPolicyCascade] is appended as-is.
GuardBuildResult buildGuardsFromConfig({
  required SecurityConfig securityConfig,
  required String dataDir,
  required ToolPolicyCascade toolPolicyCascade,
  TaskToolFilterGuard? taskToolFilterGuard,
}) {
  final yaml = securityConfig.guardsYaml;
  final errors = <String>[];
  final warnings = <String>[];

  final commandYaml = yaml['command'];
  if (commandYaml is Map) {
    final rawExtra = commandYaml['extra_blocked_patterns'];
    if (rawExtra is List) {
      final seen = <String>{};
      final dupes = <String>[];
      for (final pattern in rawExtra) {
        if (pattern is String) {
          try {
            RegExp(pattern);
          } catch (e) {
            errors.add('command.extra_blocked_patterns: invalid regex "$pattern": $e');
          }
          if (!seen.add(pattern)) dupes.add(pattern);
        }
      }
      for (final duplicate in dupes) {
        warnings.add('command.extra_blocked_patterns: duplicate pattern "$duplicate" removed');
      }
    }
  }

  final fileYaml = yaml['file'];
  if (fileYaml is Map) {
    final rawRules = fileYaml['extra_rules'];
    if (rawRules != null && rawRules is! List) {
      errors.add('file.extra_rules: must be a list of rule objects');
    } else if (rawRules is List) {
      final seen = <String, String>{};
      final dupeKeys = <String>{};
      for (var i = 0; i < rawRules.length; i++) {
        final rule = rawRules[i];
        if (rule is! Map) {
          errors.add('file.extra_rules[$i]: rule must be an object');
          continue;
        }
        final pattern = rule['pattern'];
        if (pattern is! String || pattern.trim().isEmpty) {
          errors.add('file.extra_rules[$i]: pattern must be a non-empty string');
          continue;
        }
        final level = rule['level'];
        if (level is! String || !_fileAccessLevels.contains(level)) {
          errors.add('file.extra_rules[$i]: level for "$pattern" must be one of ${_fileAccessLevels.join(', ')}');
          continue;
        }
        if (seen.containsKey(pattern)) {
          if (seen[pattern] != level) {
            errors.add(
              'file.extra_rules: conflicting rules for pattern "$pattern" '
              '(levels: ${seen[pattern]} vs $level)',
            );
          } else {
            dupeKeys.add(pattern);
          }
        } else {
          seen[pattern] = level;
        }
      }
      for (final duplicate in dupeKeys) {
        warnings.add('file.extra_rules: duplicate rule for pattern "$duplicate" removed');
      }
    }
  }

  final networkYaml = yaml['network'];
  if (networkYaml is Map) {
    final rawExfil = networkYaml['extra_exfil_patterns'];
    if (rawExfil is List) {
      final seen = <String>{};
      final dupes = <String>[];
      for (final pattern in rawExfil) {
        if (pattern is String) {
          try {
            RegExp(pattern);
          } catch (e) {
            errors.add('network.extra_exfil_patterns: invalid regex "$pattern": $e');
          }
          if (!seen.add(pattern)) dupes.add(pattern);
        }
      }
      for (final duplicate in dupes) {
        warnings.add('network.extra_exfil_patterns: duplicate pattern "$duplicate" removed');
      }
    }
  }

  final sanitizerYaml = yaml['input_sanitizer'];
  if (sanitizerYaml is Map) {
    final rawExtra = sanitizerYaml['extra_patterns'];
    if (rawExtra is List) {
      final seen = <String>{};
      final dupes = <String>[];
      for (final pattern in rawExtra) {
        if (pattern is String) {
          try {
            RegExp(pattern);
          } catch (e) {
            errors.add('input_sanitizer.extra_patterns: invalid regex "$pattern": $e');
          }
          if (!seen.add(pattern)) dupes.add(pattern);
        }
      }
      for (final duplicate in dupes) {
        warnings.add('input_sanitizer.extra_patterns: duplicate pattern "$duplicate" removed');
      }
    }
  }

  if (errors.isNotEmpty) {
    return GuardBuildFailure(errors: errors);
  }

  final inputSanitizer = InputSanitizer(
    config: yaml['input_sanitizer'] is Map
        ? InputSanitizerConfig.fromYaml(Map<String, dynamic>.from(yaml['input_sanitizer'] as Map))
        : InputSanitizerConfig(
            enabled: securityConfig.inputSanitizerEnabled,
            channelsOnly: securityConfig.inputSanitizerChannelsOnly,
            patterns: InputSanitizerConfig.defaults().patterns,
          ),
  );

  final commandGuard = CommandGuard(
    config: yaml['command'] is Map
        ? CommandGuardConfig.fromYaml(Map<String, dynamic>.from(yaml['command'] as Map))
        : CommandGuardConfig.defaults(),
  );

  final fileGuard = FileGuard(
    config:
        (yaml['file'] is Map
                ? FileGuardConfig.fromYaml(Map<String, dynamic>.from(yaml['file'] as Map))
                : FileGuardConfig.defaults())
            .withSelfProtection(p.join(dataDir, 'dartclaw.yaml')),
  );

  final networkGuard = NetworkGuard(
    config: yaml['network'] is Map
        ? NetworkGuardConfig.fromYaml(Map<String, dynamic>.from(yaml['network'] as Map))
        : NetworkGuardConfig.defaults(),
  );

  return GuardBuildSuccess(
    guards: [
      inputSanitizer,
      commandGuard,
      fileGuard,
      networkGuard,
      ToolPolicyGuard(cascade: toolPolicyCascade),
      ?taskToolFilterGuard,
    ],
    warnings: warnings,
  );
}
