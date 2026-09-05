// Fitness function: no library package under `packages/` declares a dependency
// on an application package under `apps/` — in `dependencies:` or in
// `dev_dependencies:`.
//
// Why: an application composes libraries, never the other way round. A
// dev-dependency edge is invisible to the gates that would otherwise catch it:
// `dependency_direction_test.dart` reads `dependencies:` and `lib/` imports
// only, and `package_cycles_test.dart` resolves the production graph. That gap
// is how 699 LOC of workflow git support came to live in the CLI while a
// library package reached into it from its test tree.
//
// The `dev_dependencies:` half is the part no other gate can see. The
// `dependencies:` half overlaps `dependency_direction_test.dart`, which already
// fails a production edge as an upward or declared-but-unimported one; it is
// kept here deliberately, because that gate decides from a tier assignment in
// dev/package_tiers.txt while this one decides from apps/ membership, and the
// message an operator gets should name the application package directly. The
// two definitions cannot drift silently: an app absent from the tier file fails
// dependency_direction_test's unassigned-member check.
//
// How to resolve a failure:
//   Move the declaration the library needs into the package that owns the
//   concern (a library package, not the app), then delete the edge. An
//   allowlist entry is a last resort and must name why the app is the only
//   possible owner.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

const _allowlistName = 'no_app_dependency.txt';

/// One library package's declared dependency names, per pubspec block.
typedef MemberDeclarations = ({String pubspec, Set<String> dependencies, Set<String> devDependencies});

/// The rule, over declarations rather than over the tree, so it can be
/// exercised against an injected violation.
List<({String key, String message})> appDependencyViolations(
  Iterable<MemberDeclarations> members,
  Set<String> appPackages,
) {
  final violations = <({String key, String message})>[];
  for (final member in members) {
    for (final block in const ['dependencies:', 'dev_dependencies:']) {
      final declared = block == 'dependencies:' ? member.dependencies : member.devDependencies;
      for (final app in (declared.intersection(appPackages).toList()..sort())) {
        violations.add((
          key: '${member.pubspec}:${block.substring(0, block.length - 1)}:$app',
          message: "${member.pubspec}: declares '$app' under $block — $app is an application package (apps/$app)",
        ));
      }
    }
  }
  return violations;
}

void main() {
  late String repoRoot;
  late Allowlist allowlist;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, _allowlistName);
  });

  tearDownAll(() => allowlist.assertNoStaleEntries());

  test('the allowlist is well-formed', () {
    assertAllowlistFormat(allowlistFile(repoRoot, _allowlistName), entryFormat: '<pubspec path>:<block>:<app package>');
  });

  test('no library package depends on an application package', () {
    final apps = <String>{};
    final libraries = <MemberDeclarations>[];
    for (final member in workspaceMembers(repoRoot)) {
      final relative = relativeTo(member.path, repoRoot);
      if (relative.startsWith('apps/')) {
        apps.add(member.name);
        continue;
      }
      if (!relative.startsWith('packages/')) continue;
      final lines = File('${member.path}/pubspec.yaml').readAsLinesSync();
      libraries.add((
        pubspec: '$relative/pubspec.yaml',
        dependencies: topLevelKeysInBlock(lines, 'dependencies:'),
        devDependencies: topLevelKeysInBlock(lines, 'dev_dependencies:'),
      ));
    }
    if (apps.isEmpty) fail('No application package found under apps/; the gate would pass vacuously');
    // `topLevelKeysInBlock` fails on a block it cannot parse, so this catches the
    // case it cannot see: a walk that found members but reached no pubspec block
    // at all. No dependency anywhere is a broken scan, not a clean tree.
    if (!libraries.any((member) => member.dependencies.isNotEmpty || member.devDependencies.isNotEmpty)) {
      fail('No dependency was parsed out of any packages/* pubspec; the block parser did not read this tree');
    }

    final unexcused = [
      for (final violation in appDependencyViolations(libraries, apps))
        if (!allowlist.containsKey(violation.key)) violation.message,
    ];
    if (unexcused.isNotEmpty) {
      fail(
        'Library packages depending on an application package (see $fitnessReadmePath):\n'
        '  ${unexcused.join('\n  ')}',
      );
    }
  });

  group('the rule fails on an injected violation', () {
    const apps = {'dartclaw_cli'};

    test('a production dependency on the app is reported with its block', () {
      final violations = appDependencyViolations(const [
        (
          pubspec: 'packages/dartclaw_workflow/pubspec.yaml',
          dependencies: {'dartclaw_cli'},
          devDependencies: <String>{},
        ),
      ], apps);
      expect(violations, hasLength(1));
      expect(violations.single.key, 'packages/dartclaw_workflow/pubspec.yaml:dependencies:dartclaw_cli');
      expect(violations.single.message, contains('under dependencies:'));
      expect(violations.single.message, contains('dartclaw_cli'));
    });

    test('a dev dependency on the app is reported too — the edge this gate exists for', () {
      final violations = appDependencyViolations(const [
        (
          pubspec: 'packages/dartclaw_workflow/pubspec.yaml',
          dependencies: <String>{},
          devDependencies: {'dartclaw_cli'},
        ),
      ], apps);
      expect(violations, hasLength(1));
      expect(violations.single.key, 'packages/dartclaw_workflow/pubspec.yaml:dev_dependencies:dartclaw_cli');
      expect(violations.single.message, contains('under dev_dependencies:'));
    });

    test('a dependency on a library package is not a violation', () {
      final violations = appDependencyViolations(const [
        (
          pubspec: 'packages/dartclaw_workflow/pubspec.yaml',
          dependencies: {'dartclaw_core'},
          devDependencies: {'dartclaw_testing'},
        ),
      ], apps);
      expect(violations, isEmpty);
    });
  });
}
