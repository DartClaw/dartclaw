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

void main() {
  test('built-in skill inventory reflects the vendored AndThen-derived skill library', () {
    final skillsDir = _skillsDir();

    expect(File(p.join(skillsDir, 'dartclaw-review', 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(skillsDir, 'dartclaw-quick-review', 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(skillsDir, 'dartclaw-prd', 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(skillsDir, 'dartclaw-plan', 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(skillsDir, 'dartclaw-verify-refine', 'SKILL.md')).existsSync(), isTrue);
    expect(
      File(p.join(skillsDir, 'dartclaw-spec-plan', 'SKILL.md')).existsSync(),
      isFalse,
      reason: 'dartclaw-spec-plan was absorbed into dartclaw-plan in 0.16.4 S26',
    );
    expect(
      File(p.join(skillsDir, 'dartclaw-review-code', 'SKILL.md')).existsSync(),
      isFalse,
      reason: 'dartclaw-review-code/-doc/-gap were folded into the unified dartclaw-review skill when re-porting against andthen 0.12.1 (AndThen 0.12.0 already unified review upstream)',
    );
    expect(File(p.join(skillsDir, 'dartclaw-review-doc', 'SKILL.md')).existsSync(), isFalse);
    expect(File(p.join(skillsDir, 'dartclaw-review-gap', 'SKILL.md')).existsSync(), isFalse);

    final skillDirs = Directory(skillsDir)
        .listSync()
        .whereType<Directory>()
        .map((dir) => p.basename(dir.path))
        .where((name) => name.startsWith('dartclaw-'))
        .toSet();
    expect(skillDirs.length, 11);
    expect(skillDirs, contains('dartclaw-review'));
    expect(skillDirs, contains('dartclaw-quick-review'));
    expect(skillDirs, contains('dartclaw-prd'));
    expect(skillDirs, contains('dartclaw-plan'));
    expect(skillDirs, contains('dartclaw-verify-refine'));
    expect(skillDirs, contains('dartclaw-validate-workflow'));
    expect(skillDirs, isNot(contains('dartclaw-spec-plan')));
    expect(skillDirs, isNot(contains('dartclaw-review-code')));
    expect(skillDirs, isNot(contains('dartclaw-review-doc')));
    expect(skillDirs, isNot(contains('dartclaw-review-gap')));

    // AndThen 0.13.0 retired the shared `plugin/references/` and `plugin/scripts/` directories.
    // Each skill is now self-contained: references, templates, scripts live inside the skill dir.
    // Verify the canonical per-skill placements for the duplicated assets.
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
    // Verification scripts now live inside the review skill.
    expect(File(p.join(skillsDir, 'dartclaw-review', 'scripts', 'check-stubs.sh')).existsSync(), isTrue);
    expect(File(p.join(skillsDir, 'dartclaw-review', 'scripts', 'check-wiring.sh')).existsSync(), isTrue);
    expect(File(p.join(skillsDir, 'dartclaw-exec-spec', 'scripts', 'check-stubs.sh')).existsSync(), isTrue);
    expect(File(p.join(skillsDir, 'dartclaw-exec-spec', 'scripts', 'check-wiring.sh')).existsSync(), isTrue);
    // Adversarial-challenge now lives inside review; execution-discipline inside exec-spec.
    expect(File(p.join(skillsDir, 'dartclaw-review', 'references', 'adversarial-challenge.md')).existsSync(), isTrue);
    expect(File(p.join(skillsDir, 'dartclaw-exec-spec', 'references', 'execution-discipline.md')).existsSync(), isTrue);
    // FIS authoring guidelines — canonical in spec, duplicated in plan + review with `source:` frontmatter.
    expect(File(p.join(skillsDir, 'dartclaw-spec', 'references', 'fis-authoring-guidelines.md')).existsSync(), isTrue);
    expect(File(p.join(skillsDir, 'dartclaw-plan', 'references', 'fis-authoring-guidelines.md')).existsSync(), isTrue);
    expect(File(p.join(skillsDir, 'dartclaw-review', 'references', 'fis-authoring-guidelines.md')).existsSync(), isTrue);
  });
}
