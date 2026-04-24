import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _skillsDir() {
  var current = Directory.current;
  while (true) {
    final candidates = [
      p.join(current.path, 'skills'),
      p.join(current.path, 'packages', 'dartclaw_workflow', 'skills'),
    ];
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) {
        return candidate;
      }
    }

    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not locate built-in skills directory');
    }
    current = parent;
  }
}

const _expectedSkillDirs = <String>{
  'dartclaw-discover-project',
  'dartclaw-exec-spec',
  'dartclaw-plan',
  'dartclaw-prd',
  'dartclaw-quick-review',
  'dartclaw-remediate-findings',
  'dartclaw-review',
  'dartclaw-spec',
  'dartclaw-testing',
  'dartclaw-update-state',
  'dartclaw-validate-workflow',
};

const _syncVerbatimSkills = <String>{
  'dartclaw-spec',
  'dartclaw-exec-spec',
  'dartclaw-prd',
  'dartclaw-plan',
  'dartclaw-review',
  'dartclaw-remediate-findings',
  'dartclaw-quick-review',
  'dartclaw-testing',
};

void main() {
  group('built-in skill inventory', () {
    late String skillsDir;

    setUpAll(() {
      skillsDir = _skillsDir();
    });

    test('ships exactly the 11 vendored-plus-native skill directories', () {
      final skillDirs = Directory(skillsDir)
          .listSync()
          .whereType<Directory>()
          .map((dir) => p.basename(dir.path))
          .where((name) => name.startsWith('dartclaw-'))
          .toSet();
      expect(
        skillDirs,
        equals(_expectedSkillDirs),
        reason:
            'Exact skill set matters — a refactor that drops one skill and adds another must update this test explicitly',
      );
    });

    test('every expected skill has a SKILL.md', () {
      for (final skill in _expectedSkillDirs) {
        expect(File(p.join(skillsDir, skill, 'SKILL.md')).existsSync(), isTrue, reason: '$skill/SKILL.md is missing');
      }
    });

    test('discover-project documents project-index active story-spec contract', () {
      final content = File(p.join(skillsDir, 'dartclaw-discover-project', 'SKILL.md')).readAsStringSync();

      expect(content, isNot(contains('default_outputs:')));
      expect(content, contains('active_prd'));
      expect(content, contains('active_plan'));
      expect(content, contains('active_story_specs'));
    });

    test('skills from earlier ports (absorbed upstream) are gone', () {
      const absorbed = <String>[
        // Absorbed into dartclaw-plan when AndThen 0.13.0 folded spec-plan into plan
        'dartclaw-spec-plan',
        // Absorbed into dartclaw-review when AndThen 0.12.0 unified review-code/-doc/-gap
        'dartclaw-review-code',
        'dartclaw-review-doc',
        'dartclaw-review-gap',
        // Absorbed into dartclaw-review --council when AndThen 0.13.0 merged review-council
        'dartclaw-review-council',
      ];
      for (final skill in absorbed) {
        expect(
          File(p.join(skillsDir, skill, 'SKILL.md')).existsSync(),
          isFalse,
          reason: '$skill should have been deleted when the upstream merge landed',
        );
      }
    });

    test('self-contained layout: shared skills/references and skills/scripts are gone', () {
      // AndThen 0.13.0 retired the shared `plugin/references/` and `plugin/scripts/` sibling dirs.
      // Each skill is now self-contained.
      expect(
        Directory(p.join(skillsDir, 'references')).existsSync(),
        isFalse,
        reason: 'Shared top-level references/ retired in 0.13.0 self-contained refactor',
      );
      expect(
        Directory(p.join(skillsDir, 'scripts')).existsSync(),
        isFalse,
        reason: 'Shared top-level scripts/ retired in 0.13.0 self-contained refactor',
      );
    });

    test('SYNC-VERBATIM skills each have Codex agents/openai.yaml with DartClaw branding', () {
      for (final skill in _syncVerbatimSkills) {
        final yamlPath = p.join(skillsDir, skill, 'agents', 'openai.yaml');
        expect(
          File(yamlPath).existsSync(),
          isTrue,
          reason: '$skill/agents/openai.yaml is required for Codex invocation',
        );
        final content = File(yamlPath).readAsStringSync();
        expect(
          content,
          contains('allow_implicit_invocation: true'),
          reason: '$skill: Codex implicit-invocation policy must be preserved from upstream',
        );
        expect(
          content,
          contains('display_name: "DartClaw - '),
          reason:
              '$skill: display_name must be rewritten from "AndThen - …" to "DartClaw - …" per the brand-rewrite transform',
        );
        expect(
          content,
          isNot(contains('display_name: "AndThen - ')),
          reason: '$skill: upstream AndThen branding leaked into Codex display_name',
        );
      }
    });

    test('duplicated reference files carry the upstream source: provenance marker', () {
      // AndThen 0.13.0 self-contained skills duplicate shared content with a YAML
      // `source: plugin/skills/<owner>/...` frontmatter pointer on each copy.
      final duplicates = <String>[
        // fis-authoring-guidelines — canonical in spec, duplicated in plan + review
        p.join(skillsDir, 'dartclaw-plan', 'references', 'fis-authoring-guidelines.md'),
        p.join(skillsDir, 'dartclaw-review', 'references', 'fis-authoring-guidelines.md'),
        // fis-template — canonical in spec, duplicated in plan
        p.join(skillsDir, 'dartclaw-plan', 'templates', 'fis-template.md'),
        // plan-template — canonical in plan, duplicated in spec
        p.join(skillsDir, 'dartclaw-spec', 'templates', 'plan-template.md'),
        // prd-template — canonical in prd, duplicated in plan
        p.join(skillsDir, 'dartclaw-plan', 'templates', 'prd-template.md'),
      ];
      for (final dup in duplicates) {
        expect(File(dup).existsSync(), isTrue, reason: 'Expected duplicate missing: $dup');
        final head = File(dup).readAsLinesSync().take(5).join('\n');
        expect(
          head,
          contains('source: plugin/skills/'),
          reason: '$dup must carry the upstream `source: plugin/skills/<owner>/...` frontmatter pointer',
        );
      }
    });
  });
}
