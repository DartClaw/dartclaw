import 'dart:io';

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
  final workflow = File(p.join(repoRoot, '.github', 'workflows', 'release-binaries.yml')).readAsStringSync();
  final document = loadYaml(workflow) as YamlMap;
  final jobs = document['jobs'] as YamlMap;
  final buildJob = (document['jobs'] as YamlMap)['build'] as YamlMap;
  final matrix = (buildJob['strategy'] as YamlMap)['matrix'] as YamlMap;
  final includes = (matrix['include'] as YamlList).cast<YamlMap>();
  final steps = (buildJob['steps'] as YamlList).cast<YamlMap>();

  YamlMap stepNamed(String name) => steps.singleWhere((step) => step['name'] == name);

  test('release workflow matrix publishes the platform and checksum contract', () {
    final expectedTargets = {
      'macos-arm64': 'macos-15',
      'macos-x64': 'macos-15-intel',
      'linux-x64': 'ubuntu-latest',
      'linux-arm64': 'ubuntu-24.04-arm',
    };

    for (final entry in expectedTargets.entries) {
      final target = entry.key;
      final runsOn = entry.value;
      final os = target.substring(0, target.lastIndexOf('-'));
      final arch = target.substring(target.lastIndexOf('-') + 1);
      expect(workflow, contains('runs_on: $runsOn'));
      expect(workflow, contains('target: $target'));
      expect(workflow, contains('os_name: $os'));
      expect(workflow, contains('arch_name: $arch'));
      expect(workflow, contains('DARTCLAW_RELEASE_TARGET: \${{ matrix.target }}'));
    }

    final windows = includes.singleWhere((row) => row['target'] == 'windows-x64');
    expect(windows, {'runs_on': 'windows-latest', 'os_name': 'windows', 'arch_name': 'x64', 'target': 'windows-x64'});

    final validation = stepNamed('Test Windows artifact validation');
    final build = stepNamed('Use qualified Windows artifact');
    final normalizeChecksum = stepNamed('Normalize Windows checksum sidecar');
    final publish = stepNamed('Publish Windows release asset');
    expect(validation['if'], "runner.os == 'Windows'");
    expect(validation['shell'], 'pwsh');
    expect(validation['run'], './dev/tools/build_windows_test.ps1');
    expect(validation.containsKey('continue-on-error'), isFalse);
    expect(build['if'], "runner.os == 'Windows'");
    expect(build['shell'], 'pwsh');
    expect(build['run'], contains('Tagged runtime/build tree differs from the qualified Windows source.'));
    expect(
      build['run'],
      contains('Downloaded Windows release artifact does not match qualified evidence and checksum.'),
    );
    expect(
      build['run'],
      contains('Windows qualification closure run is not one successful trusted workflow execution.'),
    );
    expect(build['run'], contains('Tag-time Windows artifact/evidence closure failed.'));
    expect(build.containsKey('continue-on-error'), isFalse);
    expect(normalizeChecksum['if'], "runner.os == 'Windows'");
    expect(normalizeChecksum['shell'], 'pwsh');
    expect(normalizeChecksum['run'], contains('[IO.File]::WriteAllText'));
    expect(normalizeChecksum['run'], contains('[Text.UTF8Encoding]::new(\$false)'));
    expect(normalizeChecksum.containsKey('continue-on-error'), isFalse);
    expect(publish['if'], "runner.os == 'Windows'");
    expect(publish['uses'], startsWith('softprops/action-gh-release@'));
    expect(publish.containsKey('continue-on-error'), isFalse);
    expect(steps.indexOf(validation), lessThan(steps.indexOf(publish)));
    expect(steps.indexOf(build), lessThan(steps.indexOf(publish)));
    expect(steps.indexOf(normalizeChecksum), lessThan(steps.indexOf(publish)));
    final windowsFiles = ((publish['with'] as YamlMap)['files'] as String).trim().split('\n');
    expect(windowsFiles, [
      r'build/dartclaw-v${{ env.DARTCLAW_VERSION }}-windows-x64.zip',
      r'build/dartclaw-v${{ env.DARTCLAW_VERSION }}-windows-x64.zip.sha256',
    ]);

    expect(workflow, contains('build/dartclaw-v\${{ env.DARTCLAW_VERSION }}-\${{ matrix.target }}.tar.gz'));
    expect(workflow, contains('build/dartclaw-v\${{ env.DARTCLAW_VERSION }}-\${{ matrix.target }}.tar.gz.sha256'));
    expect(workflow, contains('bash dev/tools/check_versions.sh "\$DARTCLAW_VERSION"'));
    expect(RegExp(r'run: dart pub get --enforce-lockfile').allMatches(workflow), hasLength(3));
    expect(workflow, isNot(contains('run: dart pub get\n')));
    expect(workflow, isNot(contains('sync_version.dart')));
    expect(workflow, contains('TAG_VERSION="\${GITHUB_REF_NAME#v}"'));
    expect(workflow, contains('Tag \$GITHUB_REF_NAME does not match dartclawVersion \$DARTCLAW_VERSION'));
    expect(workflow, isNot(contains('publish_assets')));
    expect(workflow, isNot(contains('dartclaw-assets')));
    expect(workflow, contains('SHA256SUMS.txt'));
    // The aggregate-checksums job has no checkout, so `gh release download`
    // must get the repo from GH_REPO or it fails with "not a git repository".
    expect(workflow, contains('GH_REPO: \${{ github.repository }}'));
  });

  test('publication jobs use the protected environment and least-privilege credentials', () {
    expect(document['permissions'], {'contents': 'read'});
    expect(buildJob['permissions'], {'actions': 'read', 'contents': 'write'});
    expect((jobs['checksums'] as YamlMap)['permissions'], {'contents': 'write'});
    for (final name in ['homebrew', 'windows-installer', 'scoop']) {
      expect((jobs[name] as YamlMap).containsKey('permissions'), isFalse);
    }

    for (final job in jobs.values.cast<YamlMap>()) {
      final jobSteps = (job['steps'] as YamlList).cast<YamlMap>();
      for (final checkout in jobSteps.where((step) => '${step['uses']}'.startsWith('actions/checkout@'))) {
        expect((checkout['with'] as YamlMap)['persist-credentials'], isFalse);
      }
    }

    for (final name in ['homebrew', 'scoop']) {
      final job = jobs[name] as YamlMap;
      expect(job['environment'], 'distribution-publication');
      final steps = (job['steps'] as YamlList).cast<YamlMap>();
      final checkout = steps.singleWhere((step) => step['name'] == 'Checkout');
      expect((checkout['with'] as YamlMap)['persist-credentials'], isFalse);
      final publish = steps.singleWhere(
        (step) => step['env'] is YamlMap && (step['env'] as YamlMap).containsKey('HOMEBREW_TAP_TOKEN'),
      );
      expect((publish['env'] as YamlMap)['HOMEBREW_TAP_TOKEN'], r'${{ secrets.HOMEBREW_TAP_TOKEN }}');
      expect(publish['run'], contains(r'x-access-token:${HOMEBREW_TAP_TOKEN}@github.com'));
      expect(publish['run'], isNot(contains('SCOOP_BUCKET_TOKEN')));
    }
  });
}
