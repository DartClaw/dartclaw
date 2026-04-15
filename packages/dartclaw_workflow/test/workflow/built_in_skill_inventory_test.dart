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
    expect(File(p.join(skillsDir, 'dartclaw-review-code', 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(skillsDir, 'dartclaw-review-doc', 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(skillsDir, 'dartclaw-review-gap', 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(skillsDir, 'dartclaw-quick-review', 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(skillsDir, 'dartclaw-spec-plan', 'SKILL.md')).existsSync(), isTrue);

    final skillDirs = Directory(skillsDir)
        .listSync()
        .whereType<Directory>()
        .map((dir) => p.basename(dir.path))
        .where((name) => name.startsWith('dartclaw-'))
        .toSet();
    expect(skillDirs.length, 13);
    expect(skillDirs, contains('dartclaw-review'));
    expect(skillDirs, contains('dartclaw-review-code'));
    expect(skillDirs, contains('dartclaw-review-doc'));
    expect(skillDirs, contains('dartclaw-review-gap'));
    expect(skillDirs, contains('dartclaw-quick-review'));
    expect(skillDirs, contains('dartclaw-spec-plan'));

    expect(File(p.join(skillsDir, 'references', 'verification-patterns.md')).existsSync(), isTrue);
    expect(File(p.join(skillsDir, 'references', 'structured-output-protocols.md')).existsSync(), isTrue);
    expect(File(p.join(skillsDir, 'references', 'adversarial-challenge.md')).existsSync(), isTrue);
    expect(File(p.join(skillsDir, 'scripts', 'check-stubs.sh')).existsSync(), isTrue);
    expect(File(p.join(skillsDir, 'scripts', 'check-wiring.sh')).existsSync(), isTrue);
  });
}
