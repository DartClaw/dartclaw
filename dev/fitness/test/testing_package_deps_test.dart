// Fitness function: dartclaw_testing must not depend on shipped implementation packages.
//
// How to resolve a failure:
//   Move server/storage-only test needs to dev_dependencies, or extract the
//   interface needed by a fake into a lower-level package.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

const _allowedDependencies = {'dartclaw_core', 'dartclaw_kernel'};

void main() {
  late String repoRoot;
  late Allowlist allowlist;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'testing_package_deps.txt');
  });

  // The gate decides on the exact-set const below and never consults a key, so
  // there is nothing an entry could waive. It is committed empty and stays so.
  test('the allowlist stays empty', () {
    assertAllowlistFormat(allowlistFile(repoRoot, 'testing_package_deps.txt'));
    expect(allowlist, isEmpty, reason: 'dartclaw_testing dependencies are not allowlistable; see $fitnessReadmePath');
  });

  test('dartclaw_testing dependencies stay at the core-and-below shape', () {
    final pubspec = File('$repoRoot/packages/dartclaw_testing/pubspec.yaml');
    final deps = topLevelKeysInBlock(pubspec.readAsLinesSync(), 'dependencies:');
    final unexpected = deps.difference(_allowedDependencies).toList()..sort();
    final missing = _allowedDependencies.difference(deps).toList()..sort();

    if (unexpected.isNotEmpty) {
      fail(
        'packages/dartclaw_testing/pubspec.yaml: unexpected dependency '
        "'${unexpected.first}' under dependencies: (allowed: ${_allowedDependencies.toList()..sort()})",
      );
    }
    if (missing.isNotEmpty) {
      fail('packages/dartclaw_testing/pubspec.yaml: missing expected dependencies: ${missing.join(', ')}');
    }
  });
}
