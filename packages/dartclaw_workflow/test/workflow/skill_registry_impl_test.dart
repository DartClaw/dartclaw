@Tags(['component'])
library;

import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart' show OutputFormat, SkillSource;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show SkillRegistryImpl;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmpDir;
  late Directory workspaceDir;
  late Directory dataDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('skill_registry_test_');
    workspaceDir = Directory('${tmpDir.path}/workspace')..createSync();
    dataDir = Directory('${tmpDir.path}/data')..createSync();
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  /// Creates a minimal skill directory with SKILL.md at [parent]/[skillName]/.
  Directory makeSkill(Directory parent, String skillName, {String? name, String description = ''}) {
    final skillDir = Directory('${parent.path}/$skillName')..createSync(recursive: true);
    final frontmatter = StringBuffer('---\n');
    if (name != null) frontmatter.write('name: $name\n');
    if (description.isNotEmpty) frontmatter.write('description: $description\n');
    frontmatter.write('---\n\n# $skillName\n');
    File('${skillDir.path}/SKILL.md').writeAsStringSync(frontmatter.toString());
    return skillDir;
  }

  SkillRegistryImpl makeRegistry() => SkillRegistryImpl();

  group('SkillRegistryImpl.discover', () {
    test('skills in .claude/skills/ discovered with nativeHarnesses: {claude}', () {
      final projectDir = Directory('${tmpDir.path}/project')..createSync();
      final claudeSkills = Directory('${projectDir.path}/.claude/skills')..createSync(recursive: true);
      makeSkill(claudeSkills, 'review-code', name: 'dartclaw-review-code', description: 'Reviews code');

      final registry = makeRegistry();
      registry.discover(
        projectDir: projectDir.path,
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      final skills = registry.listAll();
      expect(skills.length, 1);
      expect(skills.first.name, 'dartclaw-review-code');
      expect(skills.first.source, SkillSource.projectClaude);
      expect(skills.first.nativeHarnesses, {'claude'});
      expect(skills.first.description, 'Reviews code');
    });

    test('skills in .agents/skills/ discovered with nativeHarnesses: {codex}', () {
      final projectDir = Directory('${tmpDir.path}/project')..createSync();
      final agentsSkills = Directory('${projectDir.path}/.agents/skills')..createSync(recursive: true);
      makeSkill(agentsSkills, 'codex-skill', name: 'codex-skill', description: 'A codex skill');

      final registry = makeRegistry();
      registry.discover(
        projectDir: projectDir.path,
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      final skills = registry.listAll();
      expect(skills.length, 1);
      expect(skills.first.name, 'codex-skill');
      expect(skills.first.source, SkillSource.projectAgents);
      expect(skills.first.nativeHarnesses, {'codex'});
    });

    test('same skill in both .claude/skills/ and .agents/skills/ -> one entry, merged harnesses', () {
      final projectDir = Directory('${tmpDir.path}/project')..createSync();
      final claudeSkills = Directory('${projectDir.path}/.claude/skills')..createSync(recursive: true);
      final agentsSkills = Directory('${projectDir.path}/.agents/skills')..createSync(recursive: true);
      makeSkill(claudeSkills, 'shared', name: 'shared-skill');
      makeSkill(agentsSkills, 'shared', name: 'shared-skill');

      final registry = makeRegistry();
      registry.discover(
        projectDir: projectDir.path,
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      final skills = registry.listAll();
      expect(skills.length, 1);
      expect(skills.first.name, 'shared-skill');
      expect(skills.first.source, SkillSource.projectClaude); // highest priority wins
      expect(skills.first.nativeHarnesses, {'claude', 'codex'}); // merged
    });

    test('skills in ~/.agents/skills/ discovered with nativeHarnesses: {codex}', () {
      final userAgentsSkills = Directory('${tmpDir.path}/home/.agents/skills')..createSync(recursive: true);
      makeSkill(userAgentsSkills, 'user-codex-skill', name: 'user-codex-skill', description: 'A user codex skill');

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: userAgentsSkills.path,
        builtInSkillsDir: '/nonexistent',
      );

      final skills = registry.listAll();
      expect(skills.length, 1);
      expect(skills.first.name, 'user-codex-skill');
      expect(skills.first.source, SkillSource.userAgents);
      expect(skills.first.nativeHarnesses, {'codex'});
    });

    test('workspace skills have empty nativeHarnesses set', () {
      final wsSkills = Directory('${workspaceDir.path}/skills')..createSync();
      makeSkill(wsSkills, 'ws-skill', name: 'ws-skill');

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      final skills = registry.listAll();
      expect(skills.length, 1);
      expect(skills.first.source, SkillSource.workspace);
      expect(skills.first.nativeHarnesses, isEmpty);
    });

    test('data-dir native skills resolve between workspace and user tiers', () {
      final dataClaudeSkills = Directory('${dataDir.path}/.claude/skills')..createSync(recursive: true);
      makeSkill(dataClaudeSkills, 'dartclaw-prd', name: 'dartclaw-prd');

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      final skill = registry.getByName('dartclaw-prd')!;
      expect(skill.source, SkillSource.dataDirNative);
      expect(skill.nativeHarnesses, {'claude'});
    });

    test('resolveRef maps canonical AndThen references to provider-native aliases', () {
      final claudeSkills = Directory('${tmpDir.path}/home/.claude/skills')..createSync(recursive: true);
      final agentsSkills = Directory('${tmpDir.path}/home/.agents/skills')..createSync(recursive: true);
      makeSkill(claudeSkills, 'andthen-spec', name: 'andthen:spec');
      makeSkill(agentsSkills, 'andthen-spec', name: 'andthen-spec');
      makeSkill(agentsSkills, 'custom-skill', name: 'custom-skill');

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: claudeSkills.path,
        userAgentsSkillsDir: agentsSkills.path,
        builtInSkillsDir: '/nonexistent',
      );

      expect(registry.resolveRef('andthen:spec', 'claude')?.invocationName, 'andthen:spec');
      expect(registry.resolveRef('andthen:spec', 'claude')?.skill.name, 'andthen:spec');
      expect(registry.resolveRef('andthen:spec', 'codex')?.invocationName, 'andthen-spec');
      expect(registry.resolveRef('andthen:spec', 'codex')?.skill.name, 'andthen-spec');
      expect(registry.resolveRef('custom-skill', 'codex')?.invocationName, 'custom-skill');
      expect(registry.resolveRef('andthen:missing', 'codex'), isNull);
    });

    test('missing SKILL.md -> directory skipped silently', () {
      final claudeSkills = Directory('${workspaceDir.path}/skills')..createSync();
      // Create a dir without SKILL.md
      Directory('${claudeSkills.path}/no-skill-md').createSync();

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      expect(registry.listAll(), isEmpty);
    });

    test('frontmatter missing name -> falls back to directory name', () {
      final wsSkills = Directory('${workspaceDir.path}/skills')..createSync();
      final skillDir = Directory('${wsSkills.path}/my-skill')..createSync();
      // SKILL.md with frontmatter but no name field
      File('${skillDir.path}/SKILL.md').writeAsStringSync('---\ndescription: A skill without name\n---\n\n# content');

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      final skills = registry.listAll();
      expect(skills.length, 1);
      expect(skills.first.name, 'my-skill'); // falls back to dir name
      expect(skills.first.description, 'A skill without name');
    });

    test('empty frontmatter -> uses directory name and empty description', () {
      final wsSkills = Directory('${workspaceDir.path}/skills')..createSync();
      final skillDir = Directory('${wsSkills.path}/bare-skill')..createSync();
      File('${skillDir.path}/SKILL.md').writeAsStringSync('# No frontmatter at all\n');

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      final skills = registry.listAll();
      expect(skills.length, 1);
      expect(skills.first.name, 'bare-skill');
      expect(skills.first.description, '');
    });

    test('SKILL.md > 512KB -> skipped', () {
      final wsSkills = Directory('${workspaceDir.path}/skills')..createSync();
      final skillDir = Directory('${wsSkills.path}/big-skill')..createSync();
      // Write a file > 512KB
      final bigContent = '---\nname: big-skill\n---\n${'X' * (512 * 1024 + 1)}';
      File('${skillDir.path}/SKILL.md').writeAsStringSync(bigContent);

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      expect(registry.listAll(), isEmpty);
    });

    test('non-directory entries in skill dir are ignored', () {
      final wsSkills = Directory('${workspaceDir.path}/skills')..createSync();
      // Create a file (not a directory) in skills dir
      File('${wsSkills.path}/not-a-skill.txt').writeAsStringSync('hello');

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      expect(registry.listAll(), isEmpty);
    });

    test('empty skills directory -> no skills discovered', () {
      Directory('${workspaceDir.path}/skills').createSync();

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      expect(registry.listAll(), isEmpty);
    });

    test('nonexistent skills directory -> no error, no skills', () {
      // workspaceDir/skills does not exist
      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      expect(registry.listAll(), isEmpty);
    });

    test('plugin directories are scanned with empty nativeHarnesses', () {
      final pluginDir = Directory('${tmpDir.path}/plugin')..createSync();
      makeSkill(pluginDir, 'plugin-skill', name: 'plugin-skill');

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
        pluginDirs: [pluginDir.path],
      );

      final skills = registry.listAll();
      expect(skills.length, 1);
      expect(skills.first.source, SkillSource.plugin);
      expect(skills.first.nativeHarnesses, isEmpty);
    });

    test('filesystem built-in skills are discovered when builtInSkillsDir is provided', () {
      final builtInDir = Directory('${tmpDir.path}/built-ins')..createSync(recursive: true);
      makeSkill(builtInDir, 'dartclaw-review', name: 'dartclaw-review', description: 'Filesystem copy');
      Directory('${builtInDir.path}/references').createSync(recursive: true);

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: builtInDir.path,
      );

      final skill = registry.getByName('dartclaw-review');
      expect(skill, isNotNull);
      expect(skill!.source, SkillSource.dartclaw);
      expect(skill.path, p.join(builtInDir.path, 'dartclaw-review'));
      expect(skill.description, 'Filesystem copy');
      expect(skill.nativeHarnesses, isEmpty);
      expect(registry.getByName('references'), isNull);
    });

    test('managed project skill copies are skipped in favor of built-in source', () {
      final projectDir = Directory('${tmpDir.path}/project')..createSync();
      final claudeSkills = Directory('${projectDir.path}/.claude/skills')..createSync(recursive: true);
      final managedCopy = makeSkill(claudeSkills, 'dartclaw-review', name: 'dartclaw-review');
      File('${managedCopy.path}/.dartclaw-managed').writeAsStringSync('{}');

      final builtInDir = Directory('${tmpDir.path}/built-ins')..createSync();
      makeSkill(builtInDir, 'dartclaw-review', name: 'dartclaw-review');

      final registry = makeRegistry();
      registry.discover(
        projectDir: projectDir.path,
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: builtInDir.path,
      );

      final skill = registry.getByName('dartclaw-review');
      expect(skill, isNotNull);
      expect(skill!.source, SkillSource.dartclaw);
    });

    test('managed user skill copies are skipped in favor of built-in source', () {
      final userClaudeSkills = Directory('${tmpDir.path}/home/.claude/skills')..createSync(recursive: true);
      final userCodexSkills = Directory('${tmpDir.path}/home/.agents/skills')..createSync(recursive: true);
      final managedClaudeCopy = makeSkill(userClaudeSkills, 'dartclaw-review', name: 'dartclaw-review');
      final managedCodexCopy = makeSkill(userCodexSkills, 'dartclaw-review', name: 'dartclaw-review');
      File('${managedClaudeCopy.path}/.dartclaw-managed').writeAsStringSync('{}');
      File('${managedCodexCopy.path}/.dartclaw-managed').writeAsStringSync('{}');

      final builtInDir = Directory('${tmpDir.path}/built-ins')..createSync();
      makeSkill(builtInDir, 'dartclaw-review', name: 'dartclaw-review');

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: userClaudeSkills.path,
        userAgentsSkillsDir: userCodexSkills.path,
        builtInSkillsDir: builtInDir.path,
      );

      final skill = registry.getByName('dartclaw-review');
      expect(skill, isNotNull);
      expect(skill!.source, SkillSource.dartclaw);
    });

    test('project override without managed marker wins over built-in source', () {
      final projectDir = Directory('${tmpDir.path}/project')..createSync();
      final claudeSkills = Directory('${projectDir.path}/.claude/skills')..createSync(recursive: true);
      makeSkill(claudeSkills, 'dartclaw-review', name: 'dartclaw-review');

      final builtInDir = Directory('${tmpDir.path}/built-ins')..createSync();
      makeSkill(builtInDir, 'dartclaw-review', name: 'dartclaw-review');

      final registry = makeRegistry();
      registry.discover(
        projectDir: projectDir.path,
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: builtInDir.path,
      );

      final skill = registry.getByName('dartclaw-review');
      expect(skill, isNotNull);
      expect(skill!.source, SkillSource.projectClaude);
      expect(skill.nativeHarnesses, {'claude'});
    });

    test('multiple project directories are scanned in priority order', () {
      final projectA = Directory('${tmpDir.path}/project-a')..createSync();
      final projectB = Directory('${tmpDir.path}/project-b')..createSync();
      makeSkill(
        Directory('${projectA.path}/.claude/skills')..createSync(recursive: true),
        'review-a',
        name: 'review-a',
      );
      makeSkill(
        Directory('${projectB.path}/.agents/skills')..createSync(recursive: true),
        'review-b',
        name: 'review-b',
      );

      final registry = makeRegistry();
      registry.discover(
        projectDirs: [projectA.path, projectB.path],
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      expect(registry.getByName('review-a')?.source, SkillSource.projectClaude);
      expect(registry.getByName('review-b')?.source, SkillSource.projectAgents);
    });

    test('symlinked skill directory -> skipped silently', () {
      final wsSkills = Directory('${workspaceDir.path}/skills')..createSync();
      // Create a real skill dir elsewhere and symlink it into skills/.
      final realSkillDir = Directory('${tmpDir.path}/real-skill')..createSync();
      File('${realSkillDir.path}/SKILL.md').writeAsStringSync('---\nname: symlinked-skill\n---\n');
      Link('${wsSkills.path}/symlinked-skill').createSync(realSkillDir.path);

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      // Symlinked directory should be skipped.
      expect(registry.listAll(), isEmpty);
    });

    test('symlinked SKILL.md -> directory skipped', () {
      final wsSkills = Directory('${workspaceDir.path}/skills')..createSync();
      final skillDir = Directory('${wsSkills.path}/link-skill')..createSync();
      // Create a real SKILL.md elsewhere and symlink it into skill dir.
      final realMd = File('${tmpDir.path}/SKILL.md')..writeAsStringSync('---\nname: link-skill\n---\n');
      Link('${skillDir.path}/SKILL.md').createSync(realMd.path);

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      // Symlinked SKILL.md should cause the skill to be skipped.
      expect(registry.listAll(), isEmpty);
    });

    test('executable .sh in skill dir -> skill still discovered (warning only)', () {
      final wsSkills = Directory('${workspaceDir.path}/skills')..createSync();
      final skillDir = makeSkill(wsSkills, 'exec-skill', name: 'exec-skill');
      // Add a .sh file alongside SKILL.md.
      File('${skillDir.path}/run.sh').writeAsStringSync('#!/bin/sh\necho hello\n');

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      // Skill is discovered despite the executable (warning is best-effort).
      final skills = registry.listAll();
      expect(skills.length, 1);
      expect(skills.first.name, 'exec-skill');
    });
  });

  group('SkillRegistryImpl.validateRef', () {
    late SkillRegistryImpl registry;

    setUp(() {
      final wsSkills = Directory('${workspaceDir.path}/skills')..createSync();
      makeSkill(wsSkills, 'review-code', name: 'dartclaw-review-code');
      makeSkill(wsSkills, 'implement', name: 'custom-implement');

      registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );
    });

    test('validateRef for existing skill -> null (valid)', () {
      expect(registry.validateRef('dartclaw-review-code'), isNull);
    });

    test('validateRef for missing skill -> error message with available alternatives', () {
      final error = registry.validateRef('dartclaw-unknown');
      expect(error, isNotNull);
      expect(error, contains('dartclaw-unknown'));
      expect(error, contains('not found'));
    });

    test('validateRef with no skills discovered -> "No skills discovered"', () {
      final emptyRegistry = makeRegistry();
      emptyRegistry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );
      // Override with empty discover
      final emptyWs = Directory('${tmpDir.path}/empty')..createSync();
      final fresh = makeRegistry();
      fresh.discover(
        workspaceDir: emptyWs.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );
      final error = fresh.validateRef('missing');
      expect(error, contains('No skills discovered'));
    });

    test('validateRef for missing canonical AndThen skill includes provider alias', () {
      final error = registry.validateRef('andthen:spec', provider: 'codex');
      expect(error, isNotNull);
      expect(error, contains('andthen:spec'), reason: 'error message should name the canonical skill');
      expect(error, contains('not found'), reason: 'error message should indicate skill was not found');
      expect(error, contains('codex'));
      expect(error, contains('andthen-spec'));
      expect(error, contains('Install AndThen'));
    });

    test('validateRef for missing canonical AndThen skill with no skills discovered includes searched alias', () {
      final emptyWs = Directory('${tmpDir.path}/empty2')..createSync();
      final fresh = makeRegistry();
      fresh.discover(
        workspaceDir: emptyWs.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );
      final error = fresh.validateRef('andthen:plan', provider: 'claude');
      expect(error, isNotNull);
      expect(error, contains('andthen:plan'));
      expect(error, contains('claude'));
    });

    test('validateRef for non-dartclaw missing skill does NOT include provisioning recovery hint', () {
      final error = registry.validateRef('some-other-skill');
      expect(error, isNotNull);
      expect(error, isNot(contains('SkillProvisioner')));
    });
  });

  group('SkillRegistryImpl.isNativeFor', () {
    late SkillRegistryImpl registry;

    setUp(() {
      final projectDir = Directory('${tmpDir.path}/project')..createSync();
      final claudeSkills = Directory('${projectDir.path}/.claude/skills')..createSync(recursive: true);
      makeSkill(claudeSkills, 'review-code', name: 'dartclaw-review-code');

      registry = makeRegistry();
      registry.discover(
        projectDir: projectDir.path,
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );
    });

    test('skill in claude harness -> true for "claude"', () {
      expect(registry.isNativeFor('dartclaw-review-code', 'claude'), isTrue);
    });

    test('skill in claude harness -> false for "codex"', () {
      expect(registry.isNativeFor('dartclaw-review-code', 'codex'), isFalse);
    });

    test('unknown skill -> false', () {
      expect(registry.isNativeFor('nonexistent', 'claude'), isFalse);
    });
  });

  group('SkillRegistryImpl.getByName', () {
    test('returns skill for known name', () {
      final wsSkills = Directory('${workspaceDir.path}/skills')..createSync();
      makeSkill(wsSkills, 'my-skill', name: 'my-skill', description: 'A skill');

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      final skill = registry.getByName('my-skill');
      expect(skill, isNotNull);
      expect(skill!.name, 'my-skill');
      expect(skill.description, 'A skill');
    });

    test('returns null for unknown name', () {
      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      expect(registry.getByName('unknown'), isNull);
    });
  });

  group('packaged dartclaw-merge-resolve manifest discovery', () {
    String locateBuiltInSkillsDir() {
      var current = Directory.current;
      while (true) {
        final candidates = [
          p.join(current.path, 'skills'),
          p.join(current.path, 'packages', 'dartclaw_workflow', 'skills'),
        ];
        for (final candidate in candidates) {
          if (Directory(candidate).existsSync()) return candidate;
        }
        final parent = current.parent;
        if (parent.path == current.path) {
          throw StateError('Could not locate built-in skills directory');
        }
        current = parent;
      }
    }

    test('all four merge_resolve.* defaultOutputs parse without warnings', () async {
      final builtInSkillsDir = locateBuiltInSkillsDir();

      // Capture warnings emitted during discovery so we can assert no
      // `workflow.default_outputs.*` parse failures (e.g. invalid format).
      // Logger.root.onRecord is async — drain pending microtasks before asserting.
      final warnings = <String>[];
      final originalLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((rec) {
        if (rec.level >= Level.WARNING) warnings.add(rec.message);
      });

      try {
        final registry = makeRegistry();
        registry.discover(
          workspaceDir: workspaceDir.path,
          dataDir: dataDir.path,
          userClaudeSkillsDir: '/nonexistent',
          userAgentsSkillsDir: '/nonexistent',
          builtInSkillsDir: builtInSkillsDir,
        );

        // Allow buffered LogRecord events to be delivered to the listener.
        await Future<void>.delayed(Duration.zero);

        final skill = registry.getByName('dartclaw-merge-resolve');
        expect(skill, isNotNull, reason: 'packaged dartclaw-merge-resolve must be discovered');

        final outputs = skill!.defaultOutputs;
        expect(outputs, isNotNull, reason: 'workflow.default_outputs must parse');
        const requiredKeys = {
          'merge_resolve.outcome',
          'merge_resolve.conflicted_files',
          'merge_resolve.resolution_summary',
          'merge_resolve.error_message',
        };
        expect(
          outputs!.keys.toSet().containsAll(requiredKeys),
          isTrue,
          reason: 'all four merge_resolve.* outputs must be present (got: ${outputs.keys})',
        );

        // Spec/runtime contract: outcome is a string-typed enum (runtime format=text);
        // conflicted_files is JSON; summary and error_message are text.
        expect(outputs['merge_resolve.outcome']!.format, OutputFormat.text);
        expect(outputs['merge_resolve.conflicted_files']!.format, OutputFormat.json);
        expect(outputs['merge_resolve.resolution_summary']!.format, OutputFormat.text);
        expect(outputs['merge_resolve.error_message']!.format, OutputFormat.text);

        final mrWarnings = warnings.where((w) => w.contains('default_outputs.merge_resolve.')).toList();
        expect(mrWarnings, isEmpty, reason: 'no parse warnings expected for merge_resolve outputs; got: $mrWarnings');
      } finally {
        await sub.cancel();
        Logger.root.level = originalLevel;
      }
    });
  });
}
