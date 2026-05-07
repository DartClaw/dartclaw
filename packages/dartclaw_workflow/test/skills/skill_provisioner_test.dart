import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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

      for (final name in dcNativeSkillNames) {
        expect(File(p.join(dataDir, '.agents', 'skills', name, 'SKILL.md')).existsSync(), isTrue);
        expect(File(p.join(dataDir, '.claude', 'skills', name, 'SKILL.md')).existsSync(), isTrue);
      }
      expect(File(p.join(dataDir, '.agents', 'skills', 'dartclaw-spec', 'SKILL.md')).existsSync(), isFalse);
      expect(File(p.join(dataDir, '.claude', 'skills', 'dartclaw-review', 'SKILL.md')).existsSync(), isFalse);
    });

    test('fails when a bundled DC-native skill is missing', () async {
      Directory(p.join(sourceDir, dcNativeSkillNames.first)).deleteSync(recursive: true);
      final provisioner = SkillProvisioner(dataDir: dataDir, dcNativeSkillsSourceDir: sourceDir);

      expect(
        provisioner.ensureCacheCurrent,
        throwsA(isA<SkillProvisionException>().having((e) => e.message, 'message', contains(dcNativeSkillNames.first))),
      );
    });
  });
}

void _seedDcNativeSkills(String root) {
  for (final name in dcNativeSkillNames) {
    final dir = Directory(p.join(root, name))..createSync(recursive: true);
    File(p.join(dir.path, 'SKILL.md')).writeAsStringSync('---\nname: $name\n---\n\n# $name\n');
  }
}
