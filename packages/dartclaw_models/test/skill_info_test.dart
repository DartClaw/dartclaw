import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:test/test.dart';

void main() {
  group('SkillSource', () {
    test('displayName returns correct label for each source', () {
      expect(SkillSource.projectClaude.displayName, 'project (.claude)');
      expect(SkillSource.projectAgents.displayName, 'project (.agents)');
      expect(SkillSource.workspace.displayName, 'workspace');
      expect(SkillSource.userClaude.displayName, 'user (.claude)');
      expect(SkillSource.userAgents.displayName, 'user (.agents)');
      expect(SkillSource.userDartclaw.displayName, 'user (dartclaw)');
      expect(SkillSource.dartclaw.displayName, 'DartClaw Built-in');
      expect(SkillSource.plugin.displayName, 'plugin');
    });
  });

  group('SkillInfo', () {
    const skill = SkillInfo(
      name: 'dartclaw-review-code',
      description: 'Reviews code for correctness and style',
      source: SkillSource.projectClaude,
      path: '/project/.claude/skills/review-code',
      nativeHarnesses: {'claude'},
    );

    test('toJson round-trips via fromJson', () {
      final json = skill.toJson();
      final restored = SkillInfo.fromJson(json);
      expect(restored.name, skill.name);
      expect(restored.description, skill.description);
      expect(restored.source, skill.source);
      expect(restored.path, skill.path);
      expect(restored.nativeHarnesses, skill.nativeHarnesses);
    });

    test('toJson serializes nativeHarnesses as sorted list', () {
      const multi = SkillInfo(
        name: 'shared-skill',
        description: '',
        source: SkillSource.workspace,
        path: '/ws/skills/shared-skill',
        nativeHarnesses: {'codex', 'claude'},
      );
      final json = multi.toJson();
      expect(json['nativeHarnesses'], ['claude', 'codex']); // sorted
    });

    test('fromJson handles missing description', () {
      final json = {
        'name': 'my-skill',
        'source': 'workspace',
        'path': '/ws/skills/my-skill',
        'nativeHarnesses': <String>[],
      };
      final info = SkillInfo.fromJson(json);
      expect(info.description, '');
    });

    test('fromJson handles empty nativeHarnesses', () {
      final json = {
        'name': 'my-skill',
        'description': 'desc',
        'source': 'workspace',
        'path': '/ws/skills/my-skill',
        'nativeHarnesses': <String>[],
      };
      final info = SkillInfo.fromJson(json);
      expect(info.nativeHarnesses, isEmpty);
    });

    test('mergeHarnesses adds additional harnesses', () {
      final merged = skill.mergeHarnesses({'codex'});
      expect(merged.nativeHarnesses, {'claude', 'codex'});
      // Original unchanged
      expect(skill.nativeHarnesses, {'claude'});
    });

    test('mergeHarnesses preserves other fields', () {
      final merged = skill.mergeHarnesses({'codex'});
      expect(merged.name, skill.name);
      expect(merged.description, skill.description);
      expect(merged.source, skill.source);
      expect(merged.path, skill.path);
    });

    test('mergeHarnesses with empty set leaves harnesses unchanged', () {
      final merged = skill.mergeHarnesses({});
      expect(merged.nativeHarnesses, {'claude'});
    });

    test('default nativeHarnesses is empty', () {
      const bare = SkillInfo(name: 'bare', description: '', source: SkillSource.workspace, path: '/ws/skills/bare');
      expect(bare.nativeHarnesses, isEmpty);
    });
  });
}
