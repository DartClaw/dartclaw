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
  final workflowPath = p.join(_repoRoot(), '.github', 'workflows', 'release-binaries.yml');
  final workflow = File(workflowPath).readAsStringSync();
  final document = loadYaml(workflow) as YamlMap;
  final jobs = document['jobs'] as YamlMap;
  final buildJob = jobs['build'] as YamlMap;
  final buildSteps = (buildJob['steps'] as YamlList).cast<YamlMap>();

  YamlMap buildStep(String name) => buildSteps.singleWhere((step) => step['name'] == name);

  test('build matrix stages every supported release artifact', () {
    final matrix = (buildJob['strategy'] as YamlMap)['matrix'] as YamlMap;
    final includes = (matrix['include'] as YamlList).cast<YamlMap>();
    expect(includes, [
      {'runs_on': 'ubuntu-latest', 'target': 'linux-x64', 'archive_ext': 'tar.gz'},
      {'runs_on': 'ubuntu-24.04-arm', 'target': 'linux-arm64', 'archive_ext': 'tar.gz'},
      {'runs_on': 'macos-15', 'target': 'macos-arm64', 'archive_ext': 'tar.gz'},
      {'runs_on': 'macos-15-intel', 'target': 'macos-x64', 'archive_ext': 'tar.gz'},
      {'runs_on': 'windows-latest', 'target': 'windows-x64', 'archive_ext': 'zip'},
    ]);

    expect(buildStep('Build standalone binary')['run'], 'bash dev/tools/build.sh');
    expect(
      buildStep('Build Windows standalone binary')['run'],
      './dev/tools/build_windows.ps1 -ReleaseTarget windows-x64',
    );
    final smoke = buildStep('Smoke-test Windows release artifact');
    expect(smoke['run'], contains('-ArtifactPath "build/dartclaw-v\$env:DARTCLAW_VERSION-windows-x64.zip"'));
    expect(smoke['run'], contains('-SkipProviders'));

    final upload = buildStep('Upload staged release artifact');
    expect(upload['uses'], startsWith('actions/upload-artifact@'));
    expect((upload['with'] as YamlMap)['name'], r'release-${{ matrix.target }}');
    expect((upload['with'] as YamlMap)['if-no-files-found'], 'error');
    // S09: neither artifact prefix matches the other, so both need explicit paths.
    expect(((upload['with'] as YamlMap)['path'] as String).trim().split('\n'), [
      r'build/dartclaw-v*-${{ matrix.target }}.${{ matrix.archive_ext }}',
      r'build/dartclaw-v*-${{ matrix.target }}.${{ matrix.archive_ext }}.sha256',
      r'build/dartclaw-workflow-v*-${{ matrix.target }}.${{ matrix.archive_ext }}',
      r'build/dartclaw-workflow-v*-${{ matrix.target }}.${{ matrix.archive_ext }}.sha256',
    ]);
    expect(buildSteps.any((step) => '${step['uses']}'.startsWith('softprops/action-gh-release@')), isFalse);
  });

  test('fresh release checkouts generate embedded assets before platform builds', () {
    final stepNames = buildSteps.map((step) => step['name']).toList();
    expect(
      stepNames,
      contains('Generate embedded assets'),
      reason: 'Generated Dart libraries are gitignored and must exist before either platform build starts.',
    );

    final generateIndex = stepNames.indexOf('Generate embedded assets');
    expect(generateIndex, lessThan(stepNames.indexOf('Build standalone binary')));
    expect(generateIndex, lessThan(stepNames.indexOf('Build Windows standalone binary')));
    expect(buildStep('Generate embedded assets')['if'], "runner.os == 'Windows'");
    expect(buildStep('Generate embedded assets')['run'], 'dart run dev/tools/embed_assets.dart');
  });

  test('installer gates one atomic publication job', () {
    final installer = jobs['windows-installer'] as YamlMap;
    expect(installer['needs'], 'build');
    final installerSteps = (installer['steps'] as YamlList).cast<YamlMap>();
    final download = installerSteps.singleWhere((step) => step['name'] == 'Download staged Windows artifact');
    expect(download['uses'], startsWith('actions/download-artifact@'));
    expect((download['with'] as YamlMap)['name'], 'release-windows-x64');
    final testInstaller = installerSteps.singleWhere((step) => step['name'] == 'Test installer');
    expect(testInstaller['run'], contains('-TestDownloadPath'));

    final publish = jobs['publish'] as YamlMap;
    expect((publish['needs'] as YamlList).toList(), ['build', 'windows-installer']);
    expect(publish['permissions'], {'contents': 'write'});
    final publishSteps = (publish['steps'] as YamlList).cast<YamlMap>();
    final stagedDownload = publishSteps.singleWhere((step) => step['name'] == 'Download staged release artifacts');
    expect((stagedDownload['with'] as YamlMap)['pattern'], 'release-*');
    expect((stagedDownload['with'] as YamlMap)['merge-multiple'], true);
    final checksum = publishSteps.singleWhere(
      (step) => step['name'] == 'Verify staged artifacts and build aggregate checksums',
    );
    expect(checksum['run'], contains('shasum -a 256 -c'));
    expect(checksum['run'], contains('SHA256SUMS.txt'));
    final archives = RegExp(r'"(dartclaw(?:-workflow)?-v\$\{VERSION\}-[^"\n]+)"')
        .allMatches(checksum['run'] as String)
        .map((match) => match[1])
        .toList();
    expect(archives, [
      for (final artifact in ['dartclaw', 'dartclaw-workflow'])
        for (final target in ['linux-x64', 'linux-arm64', 'macos-arm64', 'macos-x64', 'windows-x64'])
          '$artifact-v\${VERSION}-$target.${target == 'windows-x64' ? 'zip' : 'tar.gz'}',
    ]);
    final publisher = publishSteps.singleWhere((step) => step['name'] == 'Publish release assets');
    expect(publisher['uses'], startsWith('softprops/action-gh-release@'));
    expect(RegExp('softprops/action-gh-release@').allMatches(workflow), hasLength(1));

    expect((jobs['homebrew'] as YamlMap)['needs'], 'publish');
    final homebrewSteps = ((jobs['homebrew'] as YamlMap)['steps'] as YamlList).cast<YamlMap>();
    final checksums = homebrewSteps.singleWhere((step) => step['name'] == 'Download platform checksums');
    expect(checksums['run'], contains("--pattern 'dartclaw-v*.tar.gz.sha256'"));
    expect(checksums['run'], contains("--pattern 'dartclaw-workflow-v*.tar.gz.sha256'"));
    final render = homebrewSteps.singleWhere((step) => step['name'] == 'Render Homebrew formula');
    final tap = homebrewSteps.singleWhere((step) => step['name'] == 'Publish formula to tap');
    for (final artifact in ['dartclaw', 'dartclaw-workflow']) {
      expect(render['run'], contains('--formula package/homebrew/$artifact.rb'));
      expect(render['run'], contains('--output rendered-$artifact.rb'));
      expect(tap['run'], contains('cp rendered-$artifact.rb tap-repo/Formula/$artifact.rb'));
    }
    expect(render['run'], contains('--artifact dartclaw-workflow'));
    expect(tap['run'], contains('git add Formula/dartclaw.rb Formula/dartclaw-workflow.rb'));
    expect(RegExp('git commit ').allMatches(tap['run'] as String), hasLength(1));
    expect((jobs['homebrew'] as YamlMap)['environment'], 'distribution-publication');
    expect((jobs['scoop'] as YamlMap)['needs'], 'publish');
  });

  test('a dispatched dry run validates the artifact and distributes nothing', () {
    final triggers = (document['on'] ?? document[true]) as YamlMap;
    expect(
      triggers.containsKey('workflow_dispatch'),
      isTrue,
      reason: 'Nothing else exercises the release matrix until a tag is pushed.',
    );
    expect(((triggers['push'] as YamlMap)['tags'] as YamlList).toList(), ['v*']);

    // Everything up to and including the installer test runs on a dry run; the
    // one job that distributes is gated, and its dependants inherit the skip.
    for (final validating in ['build', 'windows-installer']) {
      expect((jobs[validating] as YamlMap)['if'], isNull, reason: '$validating must run on a dry run');
    }
    expect((jobs['publish'] as YamlMap)['if'], "github.ref_type == 'tag'");
    expect((jobs['homebrew'] as YamlMap)['needs'], 'publish');
    expect((jobs['scoop'] as YamlMap)['needs'], 'publish');

    // The tag-name comparison has nothing to compare against off a tag, but the
    // workspace lockstep check must still run.
    for (final lockstep in ['Verify release version lockstep', 'Verify release version lockstep (Windows)']) {
      final run = buildStep(lockstep)['run'] as String;
      expect(run, contains('dev/tools/check_versions.sh'));
      expect(run, contains('GITHUB_REF_TYPE'));
    }
  });

  test('workflow keeps publication privileges narrow and excludes spike coupling', () {
    expect(document['permissions'], {'contents': 'read'});
    for (final entry in jobs.entries) {
      final job = entry.value as YamlMap;
      expect(job.containsKey('permissions'), entry.key == 'publish');
      final steps = (job['steps'] as YamlList).cast<YamlMap>();
      for (final checkout in steps.where((step) => '${step['uses']}'.startsWith('actions/checkout@'))) {
        expect((checkout['with'] as YamlMap)['persist-credentials'], false);
      }
    }

    expect(workflow, contains('dart pub get --enforce-lockfile'));
    expect(workflow, isNot(contains('windows-harness-turns')));
    expect(workflow, isNot(contains('feat/0.21')));
    expect(workflow, isNot(contains('ProviderEvidencePath')));
    expect(workflow, isNot(contains('ExpectedClaudeVersion')));
    expect(workflow, isNot(contains('ExpectedCodexVersion')));
    expect(workflow, isNot(contains('run-id')));
  });
}
