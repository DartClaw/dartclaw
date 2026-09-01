import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show ToolPolicyCascade, ToolPolicyGuard;
import 'package:path/path.dart' as p;

const _fileAccessLevels = {'no_access', 'read_only', 'no_delete'};

/// Builds a [List<Guard>] from [SecurityConfig], validating the extra rules
/// before constructing guard instances.
///
/// Returns [GuardBuildSuccess] with the guards, or [GuardBuildFailure] with
/// error descriptions when the config is invalid (bad regex, conflicting
/// rules). The caller decides whether to swap the chain or log and preserve the
/// existing one.
///
/// The result is the *base* guard list — the list a `guards.*` reload replaces
/// wholesale via `GuardChain.replaceGuards`. Per-runner guards that must survive
/// a reload (notably `TaskToolFilterGuard`) belong in a `GuardChain.layered`
/// layer over this base, never in the base list itself.
///
/// [toolPolicyCascade] is appended as-is.
GuardBuildResult buildGuardsFromConfig({
  required SecurityConfig securityConfig,
  required String dataDir,
  required ToolPolicyCascade toolPolicyCascade,
}) {
  final yaml = securityConfig.guardsYaml;
  final errors = <String>[];

  final commandYaml = yaml['command'];
  if (commandYaml is Map) {
    final rawExtra = commandYaml['extra_blocked_patterns'];
    if (rawExtra is List) {
      for (final pattern in rawExtra) {
        if (pattern is String) {
          try {
            RegExp(pattern);
          } catch (e) {
            errors.add('command.extra_blocked_patterns: invalid regex "$pattern": $e');
          }
        }
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
          }
        } else {
          seen[pattern] = level;
        }
      }
    }
  }

  final networkYaml = yaml['network'];
  if (networkYaml is Map) {
    final rawExfil = networkYaml['extra_exfil_patterns'];
    if (rawExfil is List) {
      for (final pattern in rawExfil) {
        if (pattern is String) {
          try {
            RegExp(pattern);
          } catch (e) {
            errors.add('network.extra_exfil_patterns: invalid regex "$pattern": $e');
          }
        }
      }
    }
  }

  if (errors.isNotEmpty) {
    return GuardBuildFailure(errors: errors);
  }

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
      commandGuard,
      fileGuard,
      networkGuard,
      ToolPolicyGuard(cascade: toolPolicyCascade),
    ],
  );
}
