import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _repoRoot() {
  var current = Directory.current.absolute.path;
  while (true) {
    if (File(p.join(current, 'tool', 'embed_assets.dart')).existsSync() &&
        Directory(p.join(current, 'apps')).existsSync()) {
      return current;
    }

    final parent = p.dirname(current);
    if (parent == current) {
      throw StateError('Unable to locate repository root from $current');
    }
    current = parent;
  }
}

Future<ProcessResult> _runDartScript({
  required String scriptPath,
  required String workingDirectory,
  Map<String, String>? environment,
}) {
  return Process.run(
    Platform.resolvedExecutable,
    [scriptPath],
    workingDirectory: workingDirectory,
    environment: environment,
  );
}

Future<ProcessResult> _runCommand(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  Map<String, String>? environment,
}) {
  return Process.run(executable, arguments, workingDirectory: workingDirectory, environment: environment);
}

void _copyDirectory(Directory source, Directory target) {
  if (!target.existsSync()) {
    target.createSync(recursive: true);
  }
  for (final entity in source.listSync(followLinks: false)) {
    final relative = p.relative(entity.path, from: source.path);
    final destination = p.join(target.path, relative);
    if (entity is File) {
      File(destination).parent.createSync(recursive: true);
      entity.copySync(destination);
    } else if (entity is Directory) {
      _copyDirectory(entity, Directory(destination));
    }
  }
}

String _readFile(String path) => File(path).readAsStringSync();

void _writeFile(String path, String content) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

void main() {
  final repoRoot = _repoRoot();
  final scriptPath = p.join(repoRoot, 'tool', 'embed_assets.dart');
  final buildScriptPath = p.join(repoRoot, 'tool', 'build.sh');
  final assetsStubPath = p.join(repoRoot, 'packages', 'dartclaw_server', 'lib', 'src', 'embedded_assets.dart');
  final skillsStubPath = p.join(repoRoot, 'packages', 'dartclaw_workflow', 'lib', 'src', 'embedded_skills.dart');
  final serverTemplatesDir = Directory(p.join(repoRoot, 'packages', 'dartclaw_server', 'lib', 'src', 'templates'));
  final serverStaticDir = Directory(p.join(repoRoot, 'packages', 'dartclaw_server', 'lib', 'src', 'static'));
  final workflowSkillsDir = Directory(p.join(repoRoot, 'packages', 'dartclaw_workflow', 'skills'));

  group('embed_assets.dart', () {
    test('populates stubs deterministically and is idempotent', () async {
      final tempRoot = Directory.systemTemp.createTempSync('dartclaw_embed_assets_fixture_');
      addTearDown(() {
        if (tempRoot.existsSync()) {
          tempRoot.deleteSync(recursive: true);
        }
      });

      _copyDirectory(
        serverTemplatesDir,
        Directory(p.join(tempRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'templates')),
      );
      _copyDirectory(
        serverStaticDir,
        Directory(p.join(tempRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'static')),
      );
      _copyDirectory(workflowSkillsDir, Directory(p.join(tempRoot.path, 'packages', 'dartclaw_workflow', 'skills')));
      _writeFile(
        p.join(tempRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'embedded_assets.dart'),
        _readFile(assetsStubPath),
      );
      _writeFile(
        p.join(tempRoot.path, 'packages', 'dartclaw_workflow', 'lib', 'src', 'embedded_skills.dart'),
        _readFile(skillsStubPath),
      );

      final first = await _runDartScript(scriptPath: scriptPath, workingDirectory: tempRoot.path);
      expect(first.exitCode, 0, reason: first.stderr.toString());

      final assetsAfterFirst = _readFile(
        p.join(tempRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'embedded_assets.dart'),
      );
      final skillsAfterFirst = _readFile(
        p.join(tempRoot.path, 'packages', 'dartclaw_workflow', 'lib', 'src', 'embedded_skills.dart'),
      );

      expect(assetsAfterFirst, contains('const _encodedTemplates = <String, String>{'));
      expect(assetsAfterFirst, contains('layout'));
      expect(assetsAfterFirst, contains('app.js'));
      expect(assetsAfterFirst, isNot(contains('VENDORS.md')));
      expect(skillsAfterFirst, contains('const _encodedSkills = <String, Map<String, String>>{'));
      expect(skillsAfterFirst, contains('dartclaw-review-code'));
      expect(skillsAfterFirst, contains('agents/openai.yaml'));

      final second = await _runDartScript(scriptPath: scriptPath, workingDirectory: tempRoot.path);
      expect(second.exitCode, 0, reason: second.stderr.toString());

      expect(
        _readFile(p.join(tempRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'embedded_assets.dart')),
        equals(assetsAfterFirst),
      );
      expect(
        _readFile(p.join(tempRoot.path, 'packages', 'dartclaw_workflow', 'lib', 'src', 'embedded_skills.dart')),
        equals(skillsAfterFirst),
      );
    });

    test('fails when an expected template is missing', () async {
      final tempRoot = Directory.systemTemp.createTempSync('dartclaw_embed_assets_missing_template_');
      addTearDown(() {
        if (tempRoot.existsSync()) {
          tempRoot.deleteSync(recursive: true);
        }
      });

      _copyDirectory(
        serverTemplatesDir,
        Directory(p.join(tempRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'templates')),
      );
      _copyDirectory(
        serverStaticDir,
        Directory(p.join(tempRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'static')),
      );
      _copyDirectory(workflowSkillsDir, Directory(p.join(tempRoot.path, 'packages', 'dartclaw_workflow', 'skills')));
      _writeFile(
        p.join(tempRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'embedded_assets.dart'),
        _readFile(assetsStubPath),
      );
      _writeFile(
        p.join(tempRoot.path, 'packages', 'dartclaw_workflow', 'lib', 'src', 'embedded_skills.dart'),
        _readFile(skillsStubPath),
      );

      File(p.join(tempRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'templates', 'layout.html')).deleteSync();

      final result = await _runDartScript(scriptPath: scriptPath, workingDirectory: tempRoot.path);
      expect(result.exitCode, isNot(0));
      expect(result.stderr.toString(), contains('Missing template'));
    });

    test('fails when an expected skill is missing', () async {
      final tempRoot = Directory.systemTemp.createTempSync('dartclaw_embed_assets_missing_skill_');
      addTearDown(() {
        if (tempRoot.existsSync()) {
          tempRoot.deleteSync(recursive: true);
        }
      });

      _copyDirectory(
        serverTemplatesDir,
        Directory(p.join(tempRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'templates')),
      );
      _copyDirectory(
        serverStaticDir,
        Directory(p.join(tempRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'static')),
      );
      _copyDirectory(workflowSkillsDir, Directory(p.join(tempRoot.path, 'packages', 'dartclaw_workflow', 'skills')));
      _writeFile(
        p.join(tempRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'embedded_assets.dart'),
        _readFile(assetsStubPath),
      );
      _writeFile(
        p.join(tempRoot.path, 'packages', 'dartclaw_workflow', 'lib', 'src', 'embedded_skills.dart'),
        _readFile(skillsStubPath),
      );

      Directory(
        p.join(tempRoot.path, 'packages', 'dartclaw_workflow', 'skills', 'dartclaw-plan'),
      ).deleteSync(recursive: true);

      final result = await _runDartScript(scriptPath: scriptPath, workingDirectory: tempRoot.path);
      expect(result.exitCode, isNot(0));
      expect(result.stderr.toString(), contains('Missing skill'));
    });
  });

  group('build.sh', () {
    test('produces build/dartclaw and restores stubs on success', () async {
      final assetsBefore = _readFile(assetsStubPath);
      final skillsBefore = _readFile(skillsStubPath);
      addTearDown(() {
        _writeFile(assetsStubPath, assetsBefore);
        _writeFile(skillsStubPath, skillsBefore);
      });

      final result = await _runCommand('bash', [buildScriptPath], workingDirectory: repoRoot);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(File(p.join(repoRoot, 'build', 'dartclaw')).existsSync(), isTrue);
      expect(result.stdout.toString(), contains('==> Build complete: build/dartclaw ('));
      expect(_readFile(assetsStubPath), equals(assetsBefore));
      expect(_readFile(skillsStubPath), equals(skillsBefore));
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('restores canonical stubs from a dirty worktree when compilation fails', () async {
      final assetsBefore = _readFile(assetsStubPath);
      final skillsBefore = _readFile(skillsStubPath);
      addTearDown(() {
        _writeFile(assetsStubPath, assetsBefore);
        _writeFile(skillsStubPath, skillsBefore);
      });

      _writeFile(
        assetsStubPath,
        "import 'dart:convert';\n\nconst _encodedTemplates = <String, String>{'dirty': 'Zm9v'};\n",
      );
      _writeFile(
        skillsStubPath,
        "import 'dart:convert';\n\nconst _encodedSkills = <String, Map<String, String>>{'dirty': {'SKILL.md': 'YmFy'}};\n",
      );

      final tempBin = Directory.systemTemp.createTempSync('dartclaw_fake_dart_dirty_');
      addTearDown(() {
        if (tempBin.existsSync()) {
          tempBin.deleteSync(recursive: true);
        }
      });

      final wrapper = File(p.join(tempBin.path, 'dart'));
      wrapper.writeAsStringSync(r'''#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "run" ]]; then
  exec "$REAL_DART" "$@"
fi
if [[ "${1:-}" == "compile" && "${2:-}" == "exe" ]]; then
  echo "simulated compile failure" >&2
  exit 42
fi
exec "$REAL_DART" "$@"
''');
      await _runCommand('chmod', ['+x', wrapper.path], workingDirectory: repoRoot);

      final result = await _runCommand(
        'bash',
        [buildScriptPath],
        workingDirectory: repoRoot,
        environment: {
          ...Platform.environment,
          'PATH': '${tempBin.path}:${Platform.environment['PATH'] ?? ''}',
          'REAL_DART': Platform.resolvedExecutable,
        },
      );

      expect(result.exitCode, 42, reason: result.stderr.toString());
      expect(_readFile(assetsStubPath), equals(assetsBefore));
      expect(_readFile(skillsStubPath), equals(skillsBefore));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('restores stubs when compilation fails after embedding', () async {
      final assetsBefore = _readFile(assetsStubPath);
      final skillsBefore = _readFile(skillsStubPath);
      addTearDown(() {
        _writeFile(assetsStubPath, assetsBefore);
        _writeFile(skillsStubPath, skillsBefore);
      });

      final tempBin = Directory.systemTemp.createTempSync('dartclaw_fake_dart_');
      addTearDown(() {
        if (tempBin.existsSync()) {
          tempBin.deleteSync(recursive: true);
        }
      });

      final wrapper = File(p.join(tempBin.path, 'dart'));
      wrapper.writeAsStringSync(r'''#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "run" ]]; then
  exec "$REAL_DART" "$@"
fi
if [[ "${1:-}" == "compile" && "${2:-}" == "exe" ]]; then
  echo "simulated compile failure" >&2
  exit 42
fi
exec "$REAL_DART" "$@"
''');
      await _runCommand('chmod', ['+x', wrapper.path], workingDirectory: repoRoot);

      final result = await _runCommand(
        'bash',
        [buildScriptPath],
        workingDirectory: repoRoot,
        environment: {
          ...Platform.environment,
          'PATH': '${tempBin.path}:${Platform.environment['PATH'] ?? ''}',
          'REAL_DART': Platform.resolvedExecutable,
        },
      );

      expect(result.exitCode, 42, reason: result.stderr.toString());
      expect(_readFile(assetsStubPath), equals(assetsBefore));
      expect(_readFile(skillsStubPath), equals(skillsBefore));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
