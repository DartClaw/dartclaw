// Fitness function: the cross-compiled bridge package must remain dependency-free.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

const _allowedDevDependencies = {'async', 'test', 'lints'};

void main() {
  late String repoRoot;
  final tempDirs = <Directory>[];

  setUpAll(() {
    repoRoot = findRepoRoot();
  });

  tearDownAll(() {
    for (final tempDir in tempDirs) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('the zero-dependency allowlist stays empty', () {
    final file = allowlistFile(repoRoot, 'bridge_package_deps.txt');
    assertAllowlistFormat(file);
    expect(
      readAllowlist(repoRoot, 'bridge_package_deps.txt'),
      isEmpty,
      reason: 'dartclaw_bridge dependencies are not allowlistable; see ADR-051',
    );
  });

  test('dartclaw_bridge stays dependency-free with exact development dependencies', () async {
    final shape = await _dependencyShape('$repoRoot/packages/dartclaw_bridge');

    _assertExactShape(shape);
  });

  test('flow-style production dependencies remain visible to the exact-set check', () async {
    final packageRoot = _writeFixture(tempDirs, 'dependencies: {sqlite3: ^3.3.1}');
    final shape = await _dependencyShape(packageRoot);

    expect(shape.dependencies, contains('sqlite3'));
    expect(() => _assertExactShape(shape), throwsA(_unexpectedDependencyFailure));
  });

  test('comments before block dependencies do not hide them from the exact-set check', () async {
    final packageRoot = _writeFixture(tempDirs, '''
dependencies:
# The comment is valid YAML and does not end the mapping.
  sqlite3: ^3.3.1
''');
    final shape = await _dependencyShape(packageRoot);

    expect(shape.dependencies, contains('sqlite3'));
    expect(() => _assertExactShape(shape), throwsA(_unexpectedDependencyFailure));
  });
}

Future<({Set<String> dependencies, Set<String> devDependencies})> _dependencyShape(String packageRoot) async {
  return resolvedPackageDependencyShape(packageRoot, 'dartclaw_bridge');
}

final _unexpectedDependencyFailure = isA<TestFailure>().having(
  (failure) => failure.message,
  'message',
  allOf(contains('packages/dartclaw_bridge/pubspec.yaml'), contains('sqlite3'), contains('ADR-051')),
);

void _assertExactShape(({Set<String> dependencies, Set<String> devDependencies}) shape) {
  final dependencies = shape.dependencies.toList()..sort();
  final devDependencies = shape.devDependencies;
  final unexpectedDevDependencies = devDependencies.difference(_allowedDevDependencies).toList()..sort();
  final missingDevDependencies = _allowedDevDependencies.difference(devDependencies).toList()..sort();

  if (dependencies.isNotEmpty) {
    fail(
      'packages/dartclaw_bridge/pubspec.yaml: unexpected dependency '
      "'${dependencies.first}' under dependencies:. ADR-051 requires dartclaw_bridge to have zero dependencies "
      'because any hosted or workspace dependency can bring a build hook into the graph and break the cross-compile.',
    );
  }
  if (unexpectedDevDependencies.isNotEmpty) {
    fail(
      'packages/dartclaw_bridge/pubspec.yaml: unexpected dev dependency '
      "'${unexpectedDevDependencies.first}' (allowed: ${_allowedDevDependencies.toList()..sort()}). "
      'ADR-051 pins the complete package shape.',
    );
  }
  if (missingDevDependencies.isNotEmpty) {
    fail(
      'packages/dartclaw_bridge/pubspec.yaml: missing expected dev dependencies: '
      '${missingDevDependencies.join(', ')}. ADR-051 pins the complete package shape.',
    );
  }
}

String _writeFixture(List<Directory> tempDirs, String dependencies) {
  final tempDir = Directory.systemTemp.createTempSync('dartclaw_bridge_deps_');
  tempDirs.add(tempDir);
  File('${tempDir.path}/pubspec.yaml').writeAsStringSync('''
name: dartclaw_bridge
environment:
  sdk: ^3.13.0

$dependencies

dev_dependencies:
  async: ^2.13.0
  test: ^1.31.0
  lints: ^6.1.0
''');
  return tempDir.path;
}
