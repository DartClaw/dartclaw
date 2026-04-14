import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow_skill_materializer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Map<String, dynamic> _readManagedMarker(String skillDir) {
  final marker = File(p.join(skillDir, '.dartclaw-managed'));
  return jsonDecode(marker.readAsStringSync()) as Map<String, dynamic>;
}

String _readManagedFingerprint(String skillDir) => _readManagedMarker(skillDir)['fingerprint'] as String;

void _writeFilesystemSkillSource(Directory root, String name, {String description = 'Filesystem skill'}) {
  final skillDir = Directory(p.join(root.path, name))..createSync(recursive: true);
  File(
    p.join(skillDir.path, 'SKILL.md'),
  ).writeAsStringSync('---\nname: $name\ndescription: $description\n---\n\n# $name\n');
  File(p.join(skillDir.path, 'agents', 'claude.yaml')).createSync(recursive: true);
  File(p.join(skillDir.path, 'agents', 'claude.yaml')).writeAsStringSync('provider: claude\n');
  File(p.join(skillDir.path, 'notes', 'spec.txt')).createSync(recursive: true);
  File(p.join(skillDir.path, 'notes', 'spec.txt')).writeAsStringSync('filesystem notes\n');
}

void _writeSupportDir(Directory root, String name) {
  final dir = Directory(p.join(root.path, name))..createSync(recursive: true);
  File(p.join(dir.path, 'verification-patterns.md')).writeAsStringSync('# Verification patterns\n');
}

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

  test('materializes filesystem skills and preserves user overrides', () async {
    final sourceRoot = Directory(p.join(tempDir.path, 'source'))..createSync(recursive: true);
    _writeFilesystemSkillSource(sourceRoot, 'dartclaw-review-code');
    _writeSupportDir(sourceRoot, 'references');

    final homeDir = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);
    final preservedDir = Directory(p.join(homeDir.path, '.claude', 'skills', 'dartclaw-review-code'))
      ..createSync(recursive: true);
    File(p.join(preservedDir.path, 'SKILL.md')).writeAsStringSync('user override\n');

    await WorkflowSkillMaterializer.materialize(
      activeHarnessTypes: {'claude', 'codex'},
      homeDir: homeDir.path,
      sourceDir: sourceRoot.path,
    );

    expect(File(p.join(preservedDir.path, 'SKILL.md')).readAsStringSync(), 'user override\n');

    final managedClaudeDir = Directory(p.join(homeDir.path, '.claude', 'skills', 'references'));
    final managedCodexDir = Directory(p.join(homeDir.path, '.agents', 'skills', 'references'));
    final managedCodexSkillDir = Directory(p.join(homeDir.path, '.agents', 'skills', 'dartclaw-review-code'));

    expect(File(p.join(managedClaudeDir.path, 'verification-patterns.md')).existsSync(), isTrue);
    expect(File(p.join(managedCodexDir.path, 'verification-patterns.md')).existsSync(), isTrue);
    expect(File(p.join(managedCodexSkillDir.path, 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(managedCodexSkillDir.path, 'agents', 'claude.yaml')).existsSync(), isTrue);
    expect(File(p.join(managedCodexSkillDir.path, 'notes', 'spec.txt')).existsSync(), isTrue);
    expect(File(p.join(managedCodexSkillDir.path, '.dartclaw-managed')).existsSync(), isTrue);
    expect(_readManagedFingerprint(managedCodexSkillDir.path), isNotEmpty);
  });

  test('preserves managed copies owned by a different install', () async {
    final sourceRoot = Directory(p.join(tempDir.path, 'source'))..createSync(recursive: true);
    _writeFilesystemSkillSource(sourceRoot, 'dartclaw-review-code', description: 'New filesystem review skill');

    final homeDir = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);
    final managedDir = Directory(p.join(homeDir.path, '.claude', 'skills', 'dartclaw-review-code'))
      ..createSync(recursive: true);
    File(p.join(managedDir.path, 'SKILL.md')).writeAsStringSync('existing managed copy\n');
    File(
      p.join(managedDir.path, '.dartclaw-managed'),
    ).writeAsStringSync('{"source":"filesystem","owner":"different-install","fingerprint":"old-fingerprint"}');

    await WorkflowSkillMaterializer.materialize(
      activeHarnessTypes: {'claude'},
      homeDir: homeDir.path,
      sourceDir: sourceRoot.path,
    );

    expect(File(p.join(managedDir.path, 'SKILL.md')).readAsStringSync(), 'existing managed copy\n');
    expect(_readManagedMarker(managedDir.path)['owner'], 'different-install');
  });

  test('returns without materializing when no source directory can be resolved', () async {
    final homeDir = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);

    await WorkflowSkillMaterializer.materialize(
      activeHarnessTypes: {'claude'},
      homeDir: homeDir.path,
      resolveSourceDir: () => null,
    );

    expect(Directory(p.join(homeDir.path, '.claude', 'skills')).existsSync(), isFalse);
    expect(Directory(p.join(homeDir.path, '.agents', 'skills')).existsSync(), isFalse);
  });
}
