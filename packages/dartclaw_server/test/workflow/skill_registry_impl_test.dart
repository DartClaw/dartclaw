import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart' show SkillSource;
import 'package:dartclaw_server/dartclaw_server.dart' show SkillRegistryImpl;
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
  Directory makeSkill(
    Directory parent,
    String skillName, {
    String? name,
    String description = '',
  }) {
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
      makeSkill(claudeSkills, 'review-code', name: 'andthen:review-code', description: 'Reviews code');

      final registry = makeRegistry();
      registry.discover(
        projectDir: projectDir.path,
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
      );

      final skills = registry.listAll();
      expect(skills.length, 1);
      expect(skills.first.name, 'andthen:review-code');
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
      );

      final skills = registry.listAll();
      expect(skills.length, 1);
      expect(skills.first.name, 'codex-skill');
      expect(skills.first.source, SkillSource.projectCodex);
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
      );

      final skills = registry.listAll();
      expect(skills.length, 1);
      expect(skills.first.name, 'shared-skill');
      expect(skills.first.source, SkillSource.projectClaude); // highest priority wins
      expect(skills.first.nativeHarnesses, {'claude', 'codex'}); // merged
    });

    test('workspace skills have empty nativeHarnesses set', () {
      final wsSkills = Directory('${workspaceDir.path}/skills')..createSync();
      makeSkill(wsSkills, 'ws-skill', name: 'ws-skill');

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
      );

      final skills = registry.listAll();
      expect(skills.length, 1);
      expect(skills.first.source, SkillSource.workspace);
      expect(skills.first.nativeHarnesses, isEmpty);
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
      );

      expect(registry.listAll(), isEmpty);
    });

    test('frontmatter missing name -> falls back to directory name', () {
      final wsSkills = Directory('${workspaceDir.path}/skills')..createSync();
      final skillDir = Directory('${wsSkills.path}/my-skill')..createSync();
      // SKILL.md with frontmatter but no name field
      File('${skillDir.path}/SKILL.md').writeAsStringSync(
        '---\ndescription: A skill without name\n---\n\n# content',
      );

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
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
        pluginDirs: [pluginDir.path],
      );

      final skills = registry.listAll();
      expect(skills.length, 1);
      expect(skills.first.source, SkillSource.plugin);
      expect(skills.first.nativeHarnesses, isEmpty);
    });

    test('symlinked skill directory -> skipped silently', () {
      final wsSkills = Directory('${workspaceDir.path}/skills')..createSync();
      // Create a real skill dir elsewhere and symlink it into skills/.
      final realSkillDir = Directory('${tmpDir.path}/real-skill')..createSync();
      File('${realSkillDir.path}/SKILL.md').writeAsStringSync(
        '---\nname: symlinked-skill\n---\n',
      );
      Link('${wsSkills.path}/symlinked-skill').createSync(realSkillDir.path);

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
      );

      // Symlinked directory should be skipped.
      expect(registry.listAll(), isEmpty);
    });

    test('symlinked SKILL.md -> directory skipped', () {
      final wsSkills = Directory('${workspaceDir.path}/skills')..createSync();
      final skillDir = Directory('${wsSkills.path}/link-skill')..createSync();
      // Create a real SKILL.md elsewhere and symlink it into skill dir.
      final realMd = File('${tmpDir.path}/SKILL.md')
        ..writeAsStringSync('---\nname: link-skill\n---\n');
      Link('${skillDir.path}/SKILL.md').createSync(realMd.path);

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
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
      makeSkill(wsSkills, 'review-code', name: 'andthen:review-code');
      makeSkill(wsSkills, 'implement', name: 'andthen:implement');

      registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
      );
    });

    test('validateRef for existing skill -> null (valid)', () {
      expect(registry.validateRef('andthen:review-code'), isNull);
    });

    test('validateRef for missing skill -> error message with available alternatives', () {
      final error = registry.validateRef('andthen:unknown');
      expect(error, isNotNull);
      expect(error, contains('andthen:unknown'));
      expect(error, contains('not found'));
    });

    test('validateRef with no skills discovered -> "No skills discovered"', () {
      final emptyRegistry = makeRegistry();
      emptyRegistry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
      );
      // Override with empty discover
      final emptyWs = Directory('${tmpDir.path}/empty')..createSync();
      final fresh = makeRegistry();
      fresh.discover(
        workspaceDir: emptyWs.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
      );
      final error = fresh.validateRef('missing');
      expect(error, contains('No skills discovered'));
    });
  });

  group('SkillRegistryImpl.isNativeFor', () {
    late SkillRegistryImpl registry;

    setUp(() {
      final projectDir = Directory('${tmpDir.path}/project')..createSync();
      final claudeSkills = Directory('${projectDir.path}/.claude/skills')..createSync(recursive: true);
      makeSkill(claudeSkills, 'review-code', name: 'andthen:review-code');

      registry = makeRegistry();
      registry.discover(
        projectDir: projectDir.path,
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
      );
    });

    test('skill in claude harness -> true for "claude"', () {
      expect(registry.isNativeFor('andthen:review-code', 'claude'), isTrue);
    });

    test('skill in claude harness -> false for "codex"', () {
      expect(registry.isNativeFor('andthen:review-code', 'codex'), isFalse);
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
      );

      expect(registry.getByName('unknown'), isNull);
    });
  });
}
