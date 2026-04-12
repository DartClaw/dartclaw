import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow_skill_materializer.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show embeddedSkills;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Map<String, Map<String, String>> _snapshotEmbeddedSkills() => {
  for (final entry in embeddedSkills.entries) entry.key: Map<String, String>.from(entry.value),
};

void _restoreEmbeddedSkills(Map<String, Map<String, String>> snapshot) {
  embeddedSkills
    ..clear()
    ..addAll({for (final entry in snapshot.entries) entry.key: Map<String, String>.from(entry.value)});
}

Map<String, dynamic> _readManagedMarker(String skillDir) {
  final marker = File(p.join(skillDir, '.dartclaw-managed'));
  return jsonDecode(marker.readAsStringSync()) as Map<String, dynamic>;
}

String _readManagedFingerprint(String skillDir) => _readManagedMarker(skillDir)['fingerprint'] as String;

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('workflow_skill_materializer_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('resolveSkillsHomeDir falls back to an instance-scoped directory when HOME is unavailable', () {
    final resolved = WorkflowSkillMaterializer.resolveSkillsHomeDir(
      dataDir: '/tmp/dartclaw-data',
      environment: const {},
    );
    expect(resolved, '/tmp/dartclaw-data/.harness-home');
  });

  test('materializes embedded skills and preserves user overrides', () async {
    final snapshot = _snapshotEmbeddedSkills();
    addTearDown(() => _restoreEmbeddedSkills(snapshot));

    embeddedSkills
      ..clear()
      ..addAll({
        'dartclaw-review-code': {
          'SKILL.md': '---\nname: dartclaw-review-code\ndescription: Embedded review skill\n---\n\n# review',
          'agents/claude.yaml': 'provider: claude\n',
          'notes/spec.txt': 'embedded notes\n',
        },
      });

    final homeDir = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);
    final preservedDir = Directory(p.join(homeDir.path, '.claude', 'skills', 'dartclaw-review-code'))
      ..createSync(recursive: true);
    File(p.join(preservedDir.path, 'SKILL.md')).writeAsStringSync('user override\n');

    await WorkflowSkillMaterializer.materialize(
      activeHarnessTypes: {'claude', 'codex'},
      homeDir: homeDir.path,
      resolveSourceDir: () => null,
    );

    expect(File(p.join(preservedDir.path, 'SKILL.md')).readAsStringSync(), 'user override\n');

    final managedDir = Directory(p.join(homeDir.path, '.agents', 'skills', 'dartclaw-review-code'));
    expect(File(p.join(managedDir.path, 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(managedDir.path, 'agents', 'claude.yaml')).existsSync(), isTrue);
    expect(File(p.join(managedDir.path, '.dartclaw-managed')).existsSync(), isTrue);
    expect(_readManagedFingerprint(managedDir.path), isNotEmpty);
    expect(_readManagedMarker(managedDir.path)['source'], 'embedded');
  });

  test('preserves managed copies owned by a different install', () async {
    final snapshot = _snapshotEmbeddedSkills();
    addTearDown(() => _restoreEmbeddedSkills(snapshot));

    embeddedSkills
      ..clear()
      ..addAll({
        'dartclaw-review-code': {
          'SKILL.md': '---\nname: dartclaw-review-code\ndescription: New embedded review skill\n---\n\n# review',
        },
      });

    final homeDir = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);
    final managedDir = Directory(p.join(homeDir.path, '.claude', 'skills', 'dartclaw-review-code'))
      ..createSync(recursive: true);
    File(p.join(managedDir.path, 'SKILL.md')).writeAsStringSync('existing managed copy\n');
    File(
      p.join(managedDir.path, '.dartclaw-managed'),
    ).writeAsStringSync('{"source":"embedded","owner":"different-install","fingerprint":"old-fingerprint"}');

    await WorkflowSkillMaterializer.materialize(
      activeHarnessTypes: {'claude'},
      homeDir: homeDir.path,
      resolveSourceDir: () => null,
    );

    expect(File(p.join(managedDir.path, 'SKILL.md')).readAsStringSync(), 'existing managed copy\n');
    expect(_readManagedMarker(managedDir.path)['owner'], 'different-install');
  });

  test('embedded and filesystem fingerprints match for equivalent content', () async {
    final snapshot = _snapshotEmbeddedSkills();
    addTearDown(() => _restoreEmbeddedSkills(snapshot));

    embeddedSkills
      ..clear()
      ..addAll({
        'dartclaw-review-code': {
          'SKILL.md': '---\nname: dartclaw-review-code\ndescription: Embedded review skill\n---\n\n# review',
          'agents/openai.yaml': 'provider: openai\n',
          'notes/spec.txt': 'line one\nline two\n',
        },
      });

    final embeddedHome = Directory(p.join(tempDir.path, 'embedded-home'))..createSync(recursive: true);
    final filesystemHome = Directory(p.join(tempDir.path, 'filesystem-home'))..createSync(recursive: true);
    final filesystemSource = Directory(p.join(tempDir.path, 'filesystem-source', 'dartclaw-review-code'))
      ..createSync(recursive: true);
    File(
      p.join(filesystemSource.path, 'SKILL.md'),
    ).writeAsStringSync('---\nname: dartclaw-review-code\ndescription: Embedded review skill\n---\n\n# review');
    File(p.join(filesystemSource.path, 'agents', 'openai.yaml')).createSync(recursive: true);
    File(p.join(filesystemSource.path, 'agents', 'openai.yaml')).writeAsStringSync('provider: openai\n');
    File(p.join(filesystemSource.path, 'notes', 'spec.txt')).createSync(recursive: true);
    File(p.join(filesystemSource.path, 'notes', 'spec.txt')).writeAsStringSync('line one\nline two\n');

    await WorkflowSkillMaterializer.materialize(
      activeHarnessTypes: {'claude'},
      homeDir: embeddedHome.path,
      resolveSourceDir: () => null,
    );
    await WorkflowSkillMaterializer.materialize(
      activeHarnessTypes: {'claude'},
      homeDir: filesystemHome.path,
      sourceDir: filesystemSource.parent.path,
    );

    final embeddedFingerprint = _readManagedFingerprint(
      p.join(embeddedHome.path, '.claude', 'skills', 'dartclaw-review-code'),
    );
    final filesystemFingerprint = _readManagedFingerprint(
      p.join(filesystemHome.path, '.claude', 'skills', 'dartclaw-review-code'),
    );

    expect(embeddedFingerprint, filesystemFingerprint);
  });

  test('records install owner in managed markers', () async {
    final snapshot = _snapshotEmbeddedSkills();
    addTearDown(() => _restoreEmbeddedSkills(snapshot));

    embeddedSkills
      ..clear()
      ..addAll({
        'dartclaw-review-code': {
          'SKILL.md': '---\nname: dartclaw-review-code\ndescription: Embedded review skill\n---\n\n# review',
        },
      });

    final homeDir = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);
    await WorkflowSkillMaterializer.materialize(
      activeHarnessTypes: {'claude'},
      homeDir: homeDir.path,
      resolveSourceDir: () => null,
    );

    final marker = _readManagedMarker(p.join(homeDir.path, '.claude', 'skills', 'dartclaw-review-code'));
    expect(marker['owner'], isNotEmpty);
  });
}
