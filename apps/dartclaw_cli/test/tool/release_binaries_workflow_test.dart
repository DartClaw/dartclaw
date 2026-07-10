import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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

    expect(workflow, contains('build/dartclaw-v\${{ env.DARTCLAW_VERSION }}-\${{ matrix.target }}.tar.gz'));
    expect(workflow, contains('build/dartclaw-v\${{ env.DARTCLAW_VERSION }}-\${{ matrix.target }}.tar.gz.sha256'));
    expect(workflow, contains('bash dev/tools/check_versions.sh "\$DARTCLAW_VERSION"'));
    expect(workflow, contains('TAG_VERSION="\${GITHUB_REF_NAME#v}"'));
    expect(workflow, contains('Tag \$GITHUB_REF_NAME does not match dartclawVersion \$DARTCLAW_VERSION'));
    expect(workflow, isNot(contains('publish_assets')));
    expect(workflow, isNot(contains('dartclaw-assets')));
    expect(workflow, contains('SHA256SUMS.txt'));
    // The aggregate-checksums job has no checkout, so `gh release download`
    // must get the repo from GH_REPO or it fails with "not a git repository".
    expect(workflow, contains('GH_REPO: \${{ github.repository }}'));
  });
}
