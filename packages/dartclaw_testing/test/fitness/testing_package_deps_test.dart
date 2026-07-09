// Fitness function: dartclaw_testing must not depend on shipped implementation packages.
//
// How to resolve a failure:
//   Move server/storage-only test needs to dev_dependencies, or extract the
//   interface needed by a fake into a lower-level package.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

const _allowedDependencies = {
  'dartclaw_config',
  'dartclaw_core',
  'dartclaw_google_chat',
  'dartclaw_models',
  'dartclaw_security',
  'dartclaw_workflow',
  'http',
  'logging',
  'path',
};

void main() {
  late String repoRoot;

  setUpAll(() {
    repoRoot = findRepoRoot();
    readAllowlist(repoRoot, 'testing_package_deps.txt');
  });

  test('allowlist entries have required rationale format', () {
    assertAllowlistFormat(File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/testing_package_deps.txt'));
  });

  test('dartclaw_testing dependencies stay at the post-S11 shape', () {
    final pubspec = File('$repoRoot/packages/dartclaw_testing/pubspec.yaml');
    final deps = _topLevelKeysInBlock(pubspec.readAsLinesSync(), 'dependencies:');
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

Set<String> _topLevelKeysInBlock(List<String> lines, String heading) {
  final keys = <String>{};
  var inBlock = false;
  for (final line in lines) {
    if (!line.startsWith(' ') && line.trim() == heading) {
      inBlock = true;
      continue;
    }
    if (inBlock && line.isNotEmpty && !line.startsWith(' ')) {
      break;
    }
    if (!inBlock || !line.startsWith('  ') || line.startsWith('    ')) continue;
    final match = RegExp(r'^\s{2}([a-zA-Z_][a-zA-Z0-9_]*):').firstMatch(line);
    if (match != null) keys.add(match.group(1)!);
  }
  return keys;
}
