import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' as config_tools;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ProcessRunner,
        SkillProvisionConfigException,
        SkillProvisionException,
        SkillProvisioner,
        WorkspaceSkillInventory,
        WorkspaceSkillLinker,
        dcNativeSkillNames;
import 'package:path/path.dart' as p;

import 'project_definition_paths.dart';

/// Project directories searched for workflow skills.
List<String> workflowSkillProjectDirs(config_tools.DartclawConfig config, {required String fallbackCwd}) {
  if (config.projects.definitions.isEmpty) {
    return [fallbackCwd];
  }
  return configuredProjectDirectories(config);
}

({String claudeSkillsDir, String agentsSkillsDir}) workflowDataDirSkillRoots(String dataDir) {
  return (claudeSkillsDir: p.join(dataDir, '.claude', 'skills'), agentsSkillsDir: p.join(dataDir, '.agents', 'skills'));
}

({String claudeSkillsDir, String agentsSkillsDir})? workflowOptionalUserSkillRoots(Map<String, String>? environment) {
  final env = environment ?? Platform.environment;
  final home = (env['HOME'] ?? env['USERPROFILE'] ?? '').trim();
  if (home.isEmpty) return null;
  return (
    claudeSkillsDir: config_tools.expandHome('~/.claude/skills', env: env),
    agentsSkillsDir: config_tools.expandHome('~/.agents/skills', env: env),
  );
}

/// Provisions DartClaw-native workflow skills into provider-native roots.
Future<void> bootstrapWorkflowSkills({
  required config_tools.DartclawConfig config,
  required String dataDir,
  required String? builtInSkillsSourceDir,
  String? fallbackWorkspaceDir,
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
    dataDir: dataDir,
    dcNativeSkillsSourceDir: builtInSkillsSourceDir,
    environment: environment,
    processRunner: processRunner,
  );

  try {
    await provisioner.ensureCacheCurrent();
    final inventory = WorkspaceSkillInventory.fromDataDir(dataDir);
    final linker = WorkspaceSkillLinker();
    final workspaceDirs = _workspaceMaterializationDirs(config, fallbackWorkspaceDir: fallbackWorkspaceDir);
    for (final workspaceDir in workspaceDirs) {
      linker.materialize(
        dataDir: dataDir,
        workspaceDir: workspaceDir,
        skillNames: inventory.skillNames,
        agentMdNames: inventory.agentMdNames,
        agentTomlNames: inventory.agentTomlNames,
      );
    }
  } on SkillProvisionConfigException catch (e) {
    // Config errors keep their original message — they are not provisioning
    // failures and the operator-facing wording should reflect that.
    throw SkillProvisionException(e.message);
  } on SkillProvisionException catch (e) {
    throw SkillProvisionException('DartClaw-native skill provisioning failed: ${e.message}');
  }
}

List<String> _workspaceMaterializationDirs(
  config_tools.DartclawConfig config, {
  required String? fallbackWorkspaceDir,
}) {
  if (config.projects.definitions.isEmpty) {
    return [?fallbackWorkspaceDir];
  }

  return [
    for (final definition in config.projects.definitions.values)
      if (definition.localPath != null || _isGitWorkspace(configuredProjectDirectory(config, definition)))
        configuredProjectDirectory(config, definition),
  ];
}

bool _isGitWorkspace(String path) {
  final gitPath = p.join(path, '.git');
  final type = FileSystemEntity.typeSync(gitPath, followLinks: false);
  return type == FileSystemEntityType.directory || type == FileSystemEntityType.file;
}
