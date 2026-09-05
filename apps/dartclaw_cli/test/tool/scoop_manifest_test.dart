import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart' show dartclawVersion;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String _repoRoot() {
  final start =
      Platform.environment['DARTCLAW_REPO_ROOT'] ??
      Platform.environment['GITHUB_WORKSPACE'] ??
      Platform.environment['PWD'] ??
      Directory.current.absolute.path;
  var current = start;
  while (true) {
    if (File(p.join(current, '.github', 'workflows', 'release-binaries.yml')).existsSync() &&
        Directory(p.join(current, 'apps')).existsSync()) {
      return current;
    }

    final parent = p.dirname(current);
    if (parent == current) {
      throw StateError('Unable to locate repository root from $start');
    }
    current = parent;
  }
}

void main() {
  final repoRoot = _repoRoot();

  final toolDir = Directory.systemTemp.createTempSync('dc-scoop-tool');
  final toolPath = p.join(toolDir.path, 'render_scoop_manifest.dart');
  File(p.join(repoRoot, 'dev', 'tools', 'render_scoop_manifest.dart')).copySync(toolPath);
  tearDownAll(() => toolDir.deleteSync(recursive: true));

  ProcessResult runTool(List<String> args) =>
      Process.runSync(Platform.resolvedExecutable, [toolPath, ...args], workingDirectory: toolDir.path);

  /// Stages both Windows checksum files with distinct digests, so a renderer
  /// that picked the wrong artifact would inject the other one's digest.
  String stageChecksums(Directory dir, String artifact) {
    const digests = {'dartclaw': 'ab', 'dartclaw-workflow': 'cd'};
    for (final entry in digests.entries) {
      final archive = '${entry.key}-v$dartclawVersion-windows-x64.zip';
      File(p.join(dir.path, '$archive.sha256')).writeAsStringSync('${entry.value * 32}  $archive\n');
    }
    return digests[artifact]! * 32;
  }

  for (final artifact in ['dartclaw', 'dartclaw-workflow']) {
    final manifestPath = p.join(repoRoot, 'package', 'scoop', '$artifact.json');
    final artifactArgs = artifact == 'dartclaw' ? const <String>[] : ['--artifact', artifact];

    test('Scoop $artifact manifest pins the Windows release asset and executable', () {
      final manifest = jsonDecode(File(manifestPath).readAsStringSync()) as Map<String, dynamic>;
      final architecture = manifest['architecture'] as Map<String, dynamic>;
      final x64 = architecture['64bit'] as Map<String, dynamic>;

      expect(manifest['version'], dartclawVersion);
      expect(architecture.keys, ['64bit']);
      expect(
        x64['url'],
        'https://github.com/DartClaw/dartclaw/releases/download/'
        'v$dartclawVersion/$artifact-v$dartclawVersion-windows-x64.zip',
      );
      expect(x64['hash'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(_hashSlotCount(manifest), 1);
      expect(manifest['bin'], 'bin\\$artifact.exe');
      final autoupdate = manifest['autoupdate'] as Map<String, dynamic>;
      final autoupdateArchitecture = autoupdate['architecture'] as Map<String, dynamic>;
      final autoupdateX64 = autoupdateArchitecture['64bit'] as Map<String, dynamic>;
      expect(
        autoupdateX64['url'],
        'https://github.com/DartClaw/dartclaw/releases/download/v\$version/'
        '$artifact-v\$version-windows-x64.zip',
      );
    });

    test('Scoop $artifact renderer injects its own published Windows checksum', () {
      final tempDir = Directory.systemTemp.createTempSync('dc-scoop-render');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final digest = stageChecksums(tempDir, artifact);
      final outputPath = p.join(tempDir.path, '$artifact.json');
      final result = runTool([
        '--manifest',
        manifestPath,
        ...artifactArgs,
        '--checksums-dir',
        tempDir.path,
        '--version',
        dartclawVersion,
        '--output',
        outputPath,
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final rendered = jsonDecode(File(outputPath).readAsStringSync()) as Map<String, dynamic>;
      final x64 = (rendered['architecture'] as Map<String, dynamic>)['64bit'] as Map<String, dynamic>;
      expect(rendered['version'], dartclawVersion);
      expect(x64['hash'], digest);
      expect(x64['url'], contains('$artifact-v$dartclawVersion-windows-x64.zip'));
      expect(rendered['bin'], 'bin\\$artifact.exe');
      expect(_hashSlotCount(rendered), 1);
    });

    test('Scoop $artifact renderer refuses a missing checksum for its own artifact', () {
      final tempDir = Directory.systemTemp.createTempSync('dc-scoop-missing');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final other = artifact == 'dartclaw' ? 'dartclaw-workflow' : 'dartclaw';
      final archive = '$other-v$dartclawVersion-windows-x64.zip';
      File(p.join(tempDir.path, '$archive.sha256')).writeAsStringSync('${'ef' * 32}  $archive\n');

      final result = runTool([
        '--manifest',
        manifestPath,
        ...artifactArgs,
        '--checksums-dir',
        tempDir.path,
        '--version',
        dartclawVersion,
      ]);

      expect(result.exitCode, isNonZero);
      expect('${result.stderr}', contains('$artifact-v$dartclawVersion-windows-x64.zip.sha256'));
    });

    test('Scoop $artifact renderer rejects version drift', () {
      final tempDir = Directory.systemTemp.createTempSync('dc-scoop-drift');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final result = runTool([
        '--manifest',
        manifestPath,
        ...artifactArgs,
        '--checksums-dir',
        tempDir.path,
        '--version',
        '0.0.0-nonmatching',
      ]);

      expect(result.exitCode, isNonZero);
      expect('${result.stderr}', contains('lockstep'));
    });

    test('Scoop $artifact renderer rejects a literal \$version in the concrete release URL', () {
      final tempDir = Directory.systemTemp.createTempSync('dc-scoop-url-template');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final manifest = jsonDecode(File(manifestPath).readAsStringSync()) as Map<String, dynamic>;
      final architecture = manifest['architecture'] as Map<String, dynamic>;
      final x64 = architecture['64bit'] as Map<String, dynamic>;
      x64['url'] =
          'https://github.com/DartClaw/dartclaw/releases/download/v\$version/'
          '$artifact-v$dartclawVersion-windows-x64.zip';
      final malformedManifestPath = p.join(tempDir.path, 'malformed.json');
      File(malformedManifestPath).writeAsStringSync(jsonEncode(manifest));

      final result = runTool([
        '--manifest',
        malformedManifestPath,
        ...artifactArgs,
        '--checksums-dir',
        tempDir.path,
        '--version',
        dartclawVersion,
      ]);

      expect(result.exitCode, isNonZero);
      expect('${result.stderr}', contains('architecture.64bit.url'));
    });

    test('Scoop $artifact renderer rejects a foreign artifact URL', () {
      final tempDir = Directory.systemTemp.createTempSync('dc-scoop-foreign-url');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      stageChecksums(tempDir, artifact);
      final other = artifact == 'dartclaw' ? 'dartclaw-workflow' : 'dartclaw';
      final foreignManifestPath = p.join(tempDir.path, 'foreign.json');
      File(foreignManifestPath)
          .writeAsStringSync(File(p.join(repoRoot, 'package', 'scoop', '$other.json')).readAsStringSync());

      final result = runTool([
        '--manifest',
        foreignManifestPath,
        ...artifactArgs,
        '--checksums-dir',
        tempDir.path,
        '--version',
        dartclawVersion,
      ]);

      expect(result.exitCode, isNonZero);
      expect('${result.stderr}', contains('architecture.64bit.url'));
    });

    test('Scoop $artifact renderer rejects multiple hash slots', () {
      final tempDir = Directory.systemTemp.createTempSync('dc-scoop-hash-slots');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final manifest = jsonDecode(File(manifestPath).readAsStringSync()) as Map<String, dynamic>;
      manifest['hash'] = 'ff' * 32;
      final malformedManifestPath = p.join(tempDir.path, 'malformed.json');
      File(malformedManifestPath).writeAsStringSync(jsonEncode(manifest));
      final result = runTool([
        '--manifest',
        malformedManifestPath,
        ...artifactArgs,
        '--checksums-dir',
        tempDir.path,
        '--version',
        dartclawVersion,
      ]);

      expect(result.exitCode, isNonZero);
      expect('${result.stderr}', contains('exactly one 64-bit hash slot'));
    });
  }

  test('release workflow publishes both rendered manifests to the Scoop bucket', () {
    final workflow =
        loadYaml(File(p.join(repoRoot, '.github', 'workflows', 'release-binaries.yml')).readAsStringSync()) as YamlMap;
    final scoop = (workflow['jobs'] as YamlMap)['scoop'] as YamlMap;
    final steps = (scoop['steps'] as YamlList).cast<YamlMap>();
    final download = steps.singleWhere((step) => step['name'] == 'Download Windows checksum');
    final render = steps.singleWhere((step) => step['name'] == 'Render Scoop manifest');
    final publish = steps.singleWhere((step) => step['name'] == 'Publish manifest to Scoop bucket');

    expect(scoop['needs'], 'publish');
    expect(scoop['environment'], 'distribution-publication');
    expect(download['run'], contains("--pattern 'dartclaw-v*-windows-x64.zip.sha256'"));
    expect(download['run'], contains("--pattern 'dartclaw-workflow-v*-windows-x64.zip.sha256'"));
    expect(render['run'], contains('dev/tools/render_scoop_manifest.dart'));
    expect(render['run'], contains('--manifest package/scoop/dartclaw-workflow.json'));
    expect(render['run'], contains('--artifact dartclaw-workflow'));
    expect(publish['run'], contains('DartClaw/scoop-dartclaw.git'));
    expect(publish['run'], contains('bucket/dartclaw.json bucket/dartclaw-workflow.json'));
    expect((publish['env'] as YamlMap)['HOMEBREW_TAP_TOKEN'], r'${{ secrets.HOMEBREW_TAP_TOKEN }}');
    expect(publish['run'], contains('HOMEBREW_TAP_TOKEN not configured; skipping bucket update.'));
    expect(publish['run'], contains(r'x-access-token:${HOMEBREW_TAP_TOKEN}@github.com'));
    expect(publish['run'], isNot(contains('SCOOP_BUCKET_TOKEN')));
  });
}

int _hashSlotCount(Object? value) {
  return switch (value) {
    Map<dynamic, dynamic> map =>
      map.entries.where((entry) => entry.key == 'hash').length +
          map.values.fold(0, (count, child) => count + _hashSlotCount(child)),
    Iterable<dynamic> values => values.fold(0, (count, child) => count + _hashSlotCount(child)),
    _ => 0,
  };
}
