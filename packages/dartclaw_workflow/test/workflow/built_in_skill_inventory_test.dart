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

// DC-native skills shipped with DartClaw (not sourced from AndThen).
const _expectedSkillDirs = <String>{
  'dartclaw-discover-project',
  'dartclaw-validate-workflow',
};

void main() {
  group('built-in skill inventory', () {
    late String skillsDir;

    setUpAll(() {
      skillsDir = _skillsDir();
    });

    test('ships exactly the 2 DC-native skill directories', () {
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
            'Post-ADR-025 migration: only DC-native skills (dartclaw-discover-project, '
            'dartclaw-validate-workflow) should remain. The 8 ported SYNC-VERBATIM skills '
            'and dartclaw-update-state were removed; their functionality now resolves via '
            'the user-installed andthen-* skills (runtime prerequisite: AndThen >= 0.14.0).',
      );
    });

    test('every expected DC-native skill has a SKILL.md', () {
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

    test('no no-longer-shipped ported skills remain', () {
      const retired = <String>[
        // Ported skills removed by ADR-025 migration (S51)
        'dartclaw-spec',
        'dartclaw-exec-spec',
        'dartclaw-prd',
        'dartclaw-plan',
        'dartclaw-review',
        'dartclaw-remediate-findings',
        'dartclaw-quick-review',
        'dartclaw-testing',
        'dartclaw-update-state',
        // Previously absorbed upstream (retained for regression)
        'dartclaw-spec-plan',
        'dartclaw-review-code',
        'dartclaw-review-doc',
        'dartclaw-review-gap',
        'dartclaw-review-council',
      ];
      for (final skill in retired) {
        expect(
          Directory(p.join(skillsDir, skill)).existsSync(),
          isFalse,
          reason: '$skill should have been removed by the AndThen-as-runtime-prerequisite migration (ADR-025)',
        );
      }
    });

    test('self-contained layout: shared skills/references and skills/scripts are gone', () {
      // AndThen 0.13.0 retired the shared `plugin/references/` and `plugin/scripts/` sibling dirs.
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
  });
}
