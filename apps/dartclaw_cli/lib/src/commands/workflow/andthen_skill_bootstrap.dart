import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' as config_tools;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show ProcessRunner, SkillProvisionConfigException, SkillProvisionException, SkillProvisioner, dcNativeSkillNames;
import 'package:path/path.dart' as p;

import 'project_definition_paths.dart';

/// Project directories searched for workflow skills.
List<String> workflowSkillProjectDirs(config_tools.DartclawConfig config, {required String fallbackCwd}) {
  if (config.projects.definitions.isEmpty) {
    return [fallbackCwd];
  }
  return configuredProjectDirectories(config);
}

({String claudeSkillsDir, String agentsSkillsDir}) workflowUserSkillRoots(Map<String, String>? environment) {
  final env = environment ?? Platform.environment;
  final home = (env['HOME'] ?? env['USERPROFILE'] ?? '').trim();
  if (home.isEmpty) {
    // Symmetric with SkillProvisioner._resolveDestinations: fail fast instead
    // of letting expandHome return literal-tilde paths that silently match
    // nothing during discovery.
    throw const SkillProvisionException(
      'Cannot resolve HOME/USERPROFILE for native workflow skill discovery. '
      'Set HOME or USERPROFILE so DartClaw can locate user-tier skills.',
    );
  }
  return (
    claudeSkillsDir: config_tools.expandHome('~/.claude/skills', env: env),
    agentsSkillsDir: config_tools.expandHome('~/.agents/skills', env: env),
  );
}

/// Provisions AndThen-derived `dartclaw-*` skills plus DC-native skills.
Future<void> bootstrapAndthenSkills({
  required config_tools.DartclawConfig config,
  required String dataDir,
  required String? builtInSkillsSourceDir,
  Map<String, String>? environment,
  ProcessRunner? processRunner,
}) async {
  if (builtInSkillsSourceDir == null) {
    throw const SkillProvisionException(
      'built-in skills source missing or invalid: null. '
      'Tests that intentionally skip this step set runAndthenSkillsBootstrap: false.',
    );
  }
  for (final skillName in dcNativeSkillNames) {
    if (!Directory(p.join(builtInSkillsSourceDir, skillName)).existsSync()) {
      throw SkillProvisionException(
        'built-in skills source missing or invalid: $builtInSkillsSourceDir (missing $skillName). '
        'Tests that intentionally skip this step set runAndthenSkillsBootstrap: false.',
      );
    }
  }

  final provisioner = SkillProvisioner(
    config: config.andthen,
    dataDir: dataDir,
    dcNativeSkillsSourceDir: builtInSkillsSourceDir,
    environment: environment,
    processRunner: processRunner,
  );

  try {
    await provisioner.ensureCacheCurrent();
  } on SkillProvisionConfigException catch (e) {
    // Config errors keep their original message — they are not provisioning
    // failures and the operator-facing wording should reflect that.
    throw SkillProvisionException(e.message);
  } on SkillProvisionException catch (e) {
    throw SkillProvisionException('AndThen skills provisioning failed: ${e.message}');
  }
}
