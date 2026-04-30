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

/// Spawn-target CWDs used by [SkillProvisioner.validateSpawnTargets].
List<String> workflowSkillSpawnTargetCwds(config_tools.DartclawConfig config, {required String fallbackCwd}) {
  final cwds = <String>{fallbackCwd};
  for (final def in config.projects.definitions.values) {
    final localPath = def.localPath;
    if (localPath != null && localPath.isNotEmpty) {
      cwds.add(localPath);
    }
  }
  return cwds.toList();
}

/// Data-dir scoped skill roots populated by [SkillProvisioner].
({String? claudeSkillsDir, String? agentsSkillsDir}) workflowDataDirSkillRoots(
  config_tools.DartclawConfig config, {
  required String dataDir,
}) {
  if (config.andthen.installScope == config_tools.AndthenInstallScope.user) {
    return (claudeSkillsDir: null, agentsSkillsDir: null);
  }
  final dataDirAbs = p.normalize(p.absolute(dataDir));
  return (
    claudeSkillsDir: p.join(dataDirAbs, '.claude', 'skills'),
    agentsSkillsDir: p.join(dataDirAbs, '.agents', 'skills'),
  );
}

/// Provisions AndThen-derived `dartclaw-*` skills plus DC-native skills.
Future<void> bootstrapAndthenSkills({
  required config_tools.DartclawConfig config,
  required String dataDir,
  required String? builtInSkillsSourceDir,
  required String fallbackCwd,
  Map<String, String>? environment,
  ProcessRunner? processRunner,
  List<String>? spawnTargetCwds,
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
    provisioner.validateSpawnTargets(spawnTargetCwds ?? workflowSkillSpawnTargetCwds(config, fallbackCwd: fallbackCwd));
  } on SkillProvisionConfigException catch (e) {
    throw SkillProvisionException(e.message);
  }

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
