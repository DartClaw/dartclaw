// Fitness function: the fitness suite must stay import-free.
//
// What this enforces:
//   The suite is a workspace member, so every DartClaw package resolves from
//   it. Neither a declared dependency nor an import may reinstate that edge:
//   the member's pubspec carries an exact set of top-level keys - which admits
//   `dev_dependencies:` and nothing that can carry a production package - with
//   exactly `path` + `test` under it, and no `.dart` file under the member
//   imports or exports a DartClaw package.
//
// Why:
//   Every gate here is a text scanner over the repo, which is what lets the
//   suite govern packages it must not depend on. A gate that reaches for
//   production types couples repo-wide governance to one package's build and
//   re-creates the dependency the package topology work removed.
//
// How to resolve a failure:
//   A check that genuinely needs production types belongs in a `tool/` script
//   in the package that owns them, registered as a `dart run` step in
//   `dev/tools/fitness/run_all.sh` beside check_task_executor_workflow_refs.dart.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

// Pinned as an exact set rather than as an absent-`dependencies:` assertion:
// a negative assertion over a line parser passes whenever the parser fails to
// recognise the block, so `dependency_overrides:` or an unusually indented
// `dependencies:` would have been a silent bypass.
const _allowedTopLevelKeys = {'name', 'description', 'publish_to', 'environment', 'resolution', 'dev_dependencies'};

const _allowedDevDependencies = {'path', 'test'};

const _productionRoute =
    'A gate that needs production types belongs in a tool/ script in the package that owns those types, '
    'registered as a dart run step in dev/tools/fitness/run_all.sh.';

final _topLevelKey = RegExp(r'^([a-zA-Z_][a-zA-Z0-9_]*):');

final _dartclawDirective = RegExp('''^\\s*(?:import|export)\\s+['"](package:dartclaw(?:_[a-z0-9_]+)?/[^'"]+)['"]''');

void main() {
  late String repoRoot;

  setUpAll(() {
    repoRoot = findRepoRoot();
  });

  test('the suite pubspec carries no key that can declare a production package', () {
    final pubspecPath = '$fitnessSuiteDir/pubspec.yaml';
    final lines = File('$repoRoot/$pubspecPath').readAsLinesSync();

    final keys = <String>{
      for (final line in lines)
        if (_topLevelKey.firstMatch(line) case final match?) match.group(1)!,
    };
    final unexpectedKeys = keys.difference(_allowedTopLevelKeys).toList()..sort();
    final missingKeys = _allowedTopLevelKeys.difference(keys).toList()..sort();
    if (unexpectedKeys.isNotEmpty) {
      fail(
        "$pubspecPath: unexpected top-level key '${unexpectedKeys.first}' "
        '(allowed: ${_allowedTopLevelKeys.toList()..sort()}). $_productionRoute',
      );
    }
    if (missingKeys.isNotEmpty) {
      fail('$pubspecPath: missing expected top-level keys: ${missingKeys.join(', ')}');
    }

    final devDeps = topLevelKeysInBlock(lines, 'dev_dependencies:');
    final unexpected = devDeps.difference(_allowedDevDependencies).toList()..sort();
    final missing = _allowedDevDependencies.difference(devDeps).toList()..sort();
    if (unexpected.isNotEmpty) {
      fail(
        "$pubspecPath: unexpected dev_dependencies: key '${unexpected.first}' "
        '(allowed: ${_allowedDevDependencies.toList()..sort()}). $_productionRoute',
      );
    }
    if (missing.isNotEmpty) {
      fail('$pubspecPath: missing expected dev_dependencies: ${missing.join(', ')}');
    }
  });

  test('no file in the suite imports or exports a DartClaw package', () {
    final violations = <String>[];

    final files =
        Directory('$repoRoot/$fitnessSuiteDir')
            .listSync(recursive: true)
            .whereType<File>()
            .map((file) => relativeTo(file.path, repoRoot).replaceAll('\\', '/'))
            .where((path) => path.endsWith('.dart') && !path.split('/').any((segment) => segment.startsWith('.')))
            .toList()
          ..sort();

    for (final relativePath in files) {
      final lines = File('$repoRoot/$relativePath').readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final match = _dartclawDirective.firstMatch(lines[i]);
        if (match != null) {
          violations.add('$relativePath:${i + 1}: forbidden import/export ${match.group(1)}');
        }
      }
    }

    if (violations.isNotEmpty) {
      fail('Production imports in the fitness suite:\n  ${violations.join('\n  ')}\n$_productionRoute');
    }
  });
}
