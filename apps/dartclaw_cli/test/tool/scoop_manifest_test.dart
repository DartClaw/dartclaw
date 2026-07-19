import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart' show dartclawVersion;
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
  final manifestPath = p.join(repoRoot, 'package', 'scoop', 'dartclaw.json');

  test('Scoop manifest pins the Windows release asset and executable', () {
    final manifest = jsonDecode(File(manifestPath).readAsStringSync()) as Map<String, dynamic>;
    final architecture = manifest['architecture'] as Map<String, dynamic>;
    final x64 = architecture['64bit'] as Map<String, dynamic>;

    expect(manifest['version'], dartclawVersion);
    expect(architecture.keys, ['64bit']);
    expect(
      x64['url'],
      'https://github.com/DartClaw/dartclaw/releases/download/'
      'v$dartclawVersion/dartclaw-v$dartclawVersion-windows-x64.zip',
    );
    expect(x64['hash'], matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(_hashSlotCount(manifest), 1);
    expect(manifest['bin'], r'bin\dartclaw.exe');
    final autoupdate = manifest['autoupdate'] as Map<String, dynamic>;
    final autoupdateArchitecture = autoupdate['architecture'] as Map<String, dynamic>;
    final autoupdateX64 = autoupdateArchitecture['64bit'] as Map<String, dynamic>;
    expect(
      autoupdateX64['url'],
      r'https://github.com/DartClaw/dartclaw/releases/download/v$version/dartclaw-v$version-windows-x64.zip',
    );
  });

  test('Scoop renderer injects the published Windows checksum', () {
    final toolDir = Directory.systemTemp.createTempSync('dc-scoop-tool');
    final toolPath = p.join(toolDir.path, 'render_scoop_manifest.dart');
    File(p.join(repoRoot, 'dev', 'tools', 'render_scoop_manifest.dart')).copySync(toolPath);
    addTearDown(() => toolDir.deleteSync(recursive: true));

    final archive = 'dartclaw-v$dartclawVersion-windows-x64.zip';
    final digest = 'ab' * 32;
    File(p.join(toolDir.path, '$archive.sha256')).writeAsStringSync('$digest  $archive\n');
    final outputPath = p.join(toolDir.path, 'dartclaw.json');
    final result = Process.runSync(Platform.resolvedExecutable, [
      toolPath,
      '--manifest',
      manifestPath,
      '--checksums-dir',
      toolDir.path,
      '--version',
      dartclawVersion,
      '--output',
      outputPath,
    ], workingDirectory: toolDir.path);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final rendered = jsonDecode(File(outputPath).readAsStringSync()) as Map<String, dynamic>;
    final x64 = (rendered['architecture'] as Map<String, dynamic>)['64bit'] as Map<String, dynamic>;
    expect(rendered['version'], dartclawVersion);
    expect(x64['hash'], digest);
    expect(_hashSlotCount(rendered), 1);
  });

  test('Scoop renderer rejects version drift', () {
    final toolDir = Directory.systemTemp.createTempSync('dc-scoop-drift');
    final toolPath = p.join(toolDir.path, 'render_scoop_manifest.dart');
    File(p.join(repoRoot, 'dev', 'tools', 'render_scoop_manifest.dart')).copySync(toolPath);
    addTearDown(() => toolDir.deleteSync(recursive: true));

    final result = Process.runSync(Platform.resolvedExecutable, [
      toolPath,
      '--manifest',
      manifestPath,
      '--checksums-dir',
      toolDir.path,
      '--version',
      '0.0.0-nonmatching',
    ], workingDirectory: toolDir.path);

    expect(result.exitCode, isNonZero);
    expect('${result.stderr}', contains('lockstep'));
  });

  test(r'Scoop renderer rejects a literal $version in the concrete release URL', () {
    final toolDir = Directory.systemTemp.createTempSync('dc-scoop-url-template');
    final toolPath = p.join(toolDir.path, 'render_scoop_manifest.dart');
    File(p.join(repoRoot, 'dev', 'tools', 'render_scoop_manifest.dart')).copySync(toolPath);
    addTearDown(() => toolDir.deleteSync(recursive: true));

    final manifest = jsonDecode(File(manifestPath).readAsStringSync()) as Map<String, dynamic>;
    final architecture = manifest['architecture'] as Map<String, dynamic>;
    final x64 = architecture['64bit'] as Map<String, dynamic>;
    x64['url'] =
        r'https://github.com/DartClaw/dartclaw/releases/download/v$version/'
        'dartclaw-v$dartclawVersion-windows-x64.zip';
    final malformedManifestPath = p.join(toolDir.path, 'malformed.json');
    File(malformedManifestPath).writeAsStringSync(jsonEncode(manifest));

    final result = Process.runSync(Platform.resolvedExecutable, [
      toolPath,
      '--manifest',
      malformedManifestPath,
      '--checksums-dir',
      toolDir.path,
      '--version',
      dartclawVersion,
    ], workingDirectory: toolDir.path);

    expect(result.exitCode, isNonZero);
    expect('${result.stderr}', contains('architecture.64bit.url'));
  });

  test('Scoop renderer rejects multiple hash slots', () {
    final toolDir = Directory.systemTemp.createTempSync('dc-scoop-hash-slots');
    final toolPath = p.join(toolDir.path, 'render_scoop_manifest.dart');
    File(p.join(repoRoot, 'dev', 'tools', 'render_scoop_manifest.dart')).copySync(toolPath);
    addTearDown(() => toolDir.deleteSync(recursive: true));

    final manifest = jsonDecode(File(manifestPath).readAsStringSync()) as Map<String, dynamic>;
    manifest['hash'] = 'ff' * 32;
    final malformedManifestPath = p.join(toolDir.path, 'malformed.json');
    File(malformedManifestPath).writeAsStringSync(jsonEncode(manifest));
    final result = Process.runSync(Platform.resolvedExecutable, [
      toolPath,
      '--manifest',
      malformedManifestPath,
      '--checksums-dir',
      toolDir.path,
      '--version',
      dartclawVersion,
    ], workingDirectory: toolDir.path);

    expect(result.exitCode, isNonZero);
    expect('${result.stderr}', contains('exactly one 64-bit hash slot'));
  });

  test('release workflow publishes the rendered manifest to the Scoop bucket', () {
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
    expect(render['run'], contains('dev/tools/render_scoop_manifest.dart'));
    expect(publish['run'], contains('DartClaw/scoop-dartclaw.git'));
    expect(publish['run'], contains('bucket/dartclaw.json'));
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
