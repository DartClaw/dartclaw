import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _dcNativeSkillNames = [
  'dartclaw-discover-andthen-spec',
  'dartclaw-discover-andthen-plan',
  'dartclaw-validate-workflow',
  'dartclaw-merge-resolve',
];

void main() {
  group('SkillProvisioner', () {
    late Directory tempRoot;
    late String dataDir;
    late String sourceDir;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('skill_provisioner_test_');
      dataDir = p.join(tempRoot.path, 'data');
      sourceDir = p.join(tempRoot.path, 'dc-native-skills');
      _seedDcNativeSkills(sourceDir);
    });

    tearDown(() {
      try {
        tempRoot.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('copies only DartClaw-native skills into provider skill roots', () async {
      final provisioner = SkillProvisioner(dataDir: dataDir, dcNativeSkillsSourceDir: sourceDir);

      await provisioner.ensureCacheCurrent();

      for (final name in _dcNativeSkillNames) {
        expect(File(p.join(dataDir, '.agents', 'skills', name, 'SKILL.md')).existsSync(), isTrue);
        expect(File(p.join(dataDir, '.claude', 'skills', name, 'SKILL.md')).existsSync(), isTrue);
      }
      expect(File(p.join(dataDir, '.agents', 'skills', 'dartclaw-spec', 'SKILL.md')).existsSync(), isFalse);
      expect(File(p.join(dataDir, '.claude', 'skills', 'dartclaw-review', 'SKILL.md')).existsSync(), isFalse);
    });

    test('fails when a bundled DC-native skill is missing', () async {
      Directory(p.join(sourceDir, _dcNativeSkillNames.first)).deleteSync(recursive: true);
      final provisioner = SkillProvisioner(dataDir: dataDir, dcNativeSkillsSourceDir: sourceDir);

      expect(
        provisioner.ensureCacheCurrent,
        throwsA(
          isA<SkillProvisionException>().having((e) => e.message, 'message', contains(_dcNativeSkillNames.first)),
        ),
      );
    });

    test('purges managed dartclaw-* skills absent from the manifest, keeps siblings', () async {
      // A stale managed skill left over from a prior version, plus an
      // unrelated non-dartclaw directory that must survive the purge.
      for (final root in ['.agents/skills', '.claude/skills']) {
        final stale = Directory(p.join(dataDir, root, 'dartclaw-old-skill'))..createSync(recursive: true);
        File(p.join(stale.path, 'SKILL.md')).writeAsStringSync('---\nname: dartclaw-old-skill\n---\n\n# legacy\n');
        final sibling = Directory(p.join(dataDir, root, 'operator-skill'))..createSync(recursive: true);
        File(p.join(sibling.path, 'SKILL.md')).writeAsStringSync('---\nname: operator-skill\n---\n\n# keep me\n');
      }
      final provisioner = SkillProvisioner(dataDir: dataDir, dcNativeSkillsSourceDir: sourceDir);

      await provisioner.ensureCacheCurrent();

      for (final root in ['.agents/skills', '.claude/skills']) {
        expect(
          Directory(p.join(dataDir, root, 'dartclaw-old-skill')).existsSync(),
          isFalse,
          reason: 'manifest-absent skill $root/dartclaw-old-skill should be purged on refresh',
        );
        expect(
          Directory(p.join(dataDir, root, 'operator-skill')).existsSync(),
          isTrue,
          reason: 'non-dartclaw sibling $root/operator-skill must not be purged',
        );
      }
    });

    test('persists the manifest names to the data-dir marker', () async {
      final provisioner = SkillProvisioner(dataDir: dataDir, dcNativeSkillsSourceDir: sourceDir);

      await provisioner.ensureCacheCurrent();

      final marker = File(p.join(dataDir, skillProvisionerMarkerFile));
      expect(marker.existsSync(), isTrue);
      final persisted = marker.readAsLinesSync().where((line) => line.trim().isNotEmpty).toSet();
      expect(persisted, equals(_dcNativeSkillNames.toSet()));
    });

    test('round-trip: the persisted marker binds WorkspaceSkillInventory to the manifest', () async {
      final provisioner = SkillProvisioner(dataDir: dataDir, dcNativeSkillsSourceDir: sourceDir);
      await provisioner.ensureCacheCurrent();

      // A stale managed skill appears on disk after provisioning (so the purge
      // did not see it); the real marker written by _writeMarker must still
      // exclude it from the inventory the linker consumes.
      File(p.join(dataDir, '.claude', 'skills', 'dartclaw-old-skill', 'SKILL.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('---\nname: dartclaw-old-skill\n---\n\n# legacy\n');

      final inventory = WorkspaceSkillInventory.fromDataDir(dataDir);

      expect(inventory.skillNames, isNot(contains('dartclaw-old-skill')));
      expect(inventory.skillNames.toSet(), equals(_dcNativeSkillNames.toSet()));
    });
  });
}

void _seedDcNativeSkills(String root) {
  File(p.join(root, 'dartclaw-native-skills.txt'))
    ..createSync(recursive: true)
    ..writeAsStringSync('${_dcNativeSkillNames.join('\n')}\n');
  for (final name in _dcNativeSkillNames) {
    final dir = Directory(p.join(root, name))..createSync(recursive: true);
    File(p.join(dir.path, 'SKILL.md')).writeAsStringSync('---\nname: $name\n---\n\n# $name\n');
  }
}
