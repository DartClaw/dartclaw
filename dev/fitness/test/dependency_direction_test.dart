// Fitness function: workspace package edges follow the declared tier order, and
// every declared dependency is imported and every imported package is declared.
//
// How to resolve a failure:
//   Wrong-direction or same-tier edge: move the shared type down, or split a
//   tier in dev/package_tiers.txt. There is no per-edge exception.
//   Declared-but-unimported: delete the dependency from the pubspec.
//   Imported-but-undeclared: add it, then re-check its direction.
//   Unassigned member: give it a tier in dev/package_tiers.txt.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

final _packageDirective = RegExp(r'''^\s*(?:import|export)\s+['"]package:([a-zA-Z_][a-zA-Z0-9_]*)/''');

void main() {
  late String repoRoot;
  late Map<String, int> tiers;
  late List<String> members;

  setUpAll(() {
    repoRoot = findRepoRoot();
    tiers = readPackageTiers(repoRoot);
    members = workspaceMemberNames(repoRoot);
  });

  test('every workspace member carries a tier assignment', () {
    final violations = unassignedMemberViolations(members, tiers);
    if (violations.isNotEmpty) {
      fail(
        'Workspace members with no tier in $packageTiersPath:\n'
        '  ${violations.join('\n  ')}',
      );
    }
  });

  test('every tier assignment names a workspace member', () {
    final unknown = tiers.keys.where((name) => !members.contains(name)).toList()..sort();
    if (unknown.isNotEmpty) {
      fail(
        '$packageTiersPath names packages that are not workspace members:\n'
        '  ${unknown.join('\n  ')}\n'
        'Remove the entry or add the member to the root pubspec workspace list.',
      );
    }
  });

  test('package edges point at a strictly lower tier', () {
    final violations = directionViolations(tiers, _workspaceEdges(repoRoot));
    if (violations.isNotEmpty) {
      fail(
        'Dependency direction violations (see $packageTiersPath):\n'
        '  ${violations.join('\n  ')}',
      );
    }
  });

  test('declared dependencies and imported packages are the same set', () {
    final used = <String, Set<String>>{};
    for (final edge in _workspaceEdges(repoRoot)) {
      (used[edge.from] ??= <String>{}).add(edge.to);
    }
    final violations = <String>[];
    for (final member in workspaceMembers(repoRoot)) {
      violations.addAll(
        declarationViolations(
          member.name,
          declared: declaredDartclawDependencies(member.path),
          used: used[member.name] ?? const <String>{},
        ),
      );
    }
    if (violations.isNotEmpty) {
      fail('Declared/imported dependency mismatches:\n  ${violations.join('\n  ')}');
    }
  });

  // The injected-violation group below exercises the rule against a synthetic
  // map. These pin the shipped file, so a placement change that re-legalises a
  // forbidden edge fails here rather than passing with the suite green.
  group('the shipped tier order keeps ADR-056\'s forbidden edges forbidden', () {
    test('the adapter sits on the runtime\'s own tier', () {
      expect(
        tiers['dartclaw_acp'],
        equals(tiers['dartclaw_runtime']),
        reason:
            'ADR-056 forbidden edge 3: same-tier edges are forbidden in both directions, so this is the only '
            'placement under which the runtime cannot reach the adapter and the adapter cannot reach the runtime',
      );
    });

    test('the client sits on core\'s own tier', () {
      expect(
        tiers['dartclaw_client'],
        equals(tiers['dartclaw_core']),
        reason: 'ADR-056 forbidden edge 2: the kernel is the only workspace package dartclaw_client may reach',
      );
    });

    test('only the application and the two non-shipping members sit above the runtime', () {
      final runtimeTier = tiers['dartclaw_runtime']!;
      final above = tiers.entries.where((entry) => entry.value > runtimeTier).map((entry) => entry.key).toSet();
      expect(
        above,
        equals({'dartclaw_cli', 'dartclaw_fitness', 'dartclaw_testing'}),
        reason:
            'ADR-056 forbidden edge 1: dartclaw_cli is the only member that may depend on dartclaw_runtime. '
            'dartclaw_fitness and dartclaw_testing outrank it so nothing that ships can depend on them; that they '
            'take no runtime edge themselves is held by fitness_suite_deps_test.dart and '
            'testing_package_deps_test.dart, which pin their dependency sets exactly',
      );
    });
  });

  group('the rule fails on an injected violation', () {
    const injected = {
      'dartclaw_kernel': 0,
      'dartclaw_core': 1,
      'dartclaw_signal': 2,
      'dartclaw_whatsapp': 2,
      'dartclaw_runtime': 3,
      'dartclaw_cli': 5,
    };

    test('a channel package reaching up into the runtime fails, naming both tiers', () {
      final violations = directionViolations(injected, const [
        PackageEdge('dartclaw_signal', 'dartclaw_runtime', 'packages/dartclaw_signal/lib/src/x.dart:4'),
      ]);

      expect(violations, hasLength(1));
      expect(violations.single, contains('dartclaw_signal (T2)'));
      expect(violations.single, contains('dartclaw_runtime (T3)'));
    });

    test('a same-tier sibling edge fails because tiers are strict', () {
      final violations = directionViolations(injected, const [
        PackageEdge('dartclaw_signal', 'dartclaw_whatsapp', 'packages/dartclaw_signal/lib/src/x.dart:9'),
      ]);

      expect(violations, hasLength(1));
      expect(violations.single, contains('same tier'));
    });

    test('an edge from an untiered package fails rather than passing unchecked', () {
      final violations = directionViolations(injected, const [
        PackageEdge('dartclaw_newthing', 'dartclaw_core', 'packages/dartclaw_newthing/lib/x.dart:1'),
      ]);

      expect(violations.single, contains('dartclaw_newthing'));
      expect(violations.single, contains('no tier'));
    });

    test('a downward edge passes', () {
      expect(
        directionViolations(injected, const [
          PackageEdge('dartclaw_cli', 'dartclaw_runtime', 'apps/dartclaw_cli/lib/x.dart:1'),
        ]),
        isEmpty,
      );
    });

    test('an unassigned member is named with the required action', () {
      final violations = unassignedMemberViolations(const ['dartclaw_core', 'dartclaw_newthing'], injected);

      expect(violations.single, contains('dartclaw_newthing'));
      expect(violations.single, contains(packageTiersPath));
    });

    test('a declared-but-unimported edge and an imported-but-undeclared edge both fail', () {
      expect(
        declarationViolations('dartclaw_security', declared: {'dartclaw_models'}, used: {}).single,
        allOf(contains('dartclaw_security'), contains('dartclaw_models'), contains('declares')),
      );
      expect(
        declarationViolations('dartclaw_signal', declared: {}, used: {'dartclaw_core'}).single,
        allOf(contains('dartclaw_signal'), contains('dartclaw_core'), contains('imports')),
      );
      expect(declarationViolations('dartclaw_core', declared: {'dartclaw_kernel'}, used: {'dartclaw_kernel'}), isEmpty);
    });
  });
}

/// One production `import`/`export` of a DartClaw package by another.
class PackageEdge {
  const new(this.from, this.to, this.location);

  final String from;
  final String to;
  final String location;
}

/// Reports every edge that does not point at a strictly lower tier, naming both
/// packages and their tier positions.
List<String> directionViolations(Map<String, int> tiers, Iterable<PackageEdge> edges) {
  final violations = <String>[];
  for (final edge in edges) {
    final from = tiers[edge.from];
    final to = tiers[edge.to];
    if (from == null) {
      violations.add('${edge.location}: ${edge.from} has no tier in $packageTiersPath');
      continue;
    }
    if (to == null) {
      violations.add('${edge.location}: ${edge.to} has no tier in $packageTiersPath');
      continue;
    }
    if (from == to) {
      violations.add(
        '${edge.location}: ${edge.from} -> ${edge.to} are on the same tier (T$from); '
        'same-tier edges are forbidden',
      );
    } else if (from < to) {
      violations.add(
        '${edge.location}: ${edge.from} (T$from) -> ${edge.to} (T$to) points upward; '
        'an edge may only reach a strictly lower tier',
      );
    }
  }
  return violations;
}

List<String> unassignedMemberViolations(Iterable<String> members, Map<String, int> tiers) => [
  for (final member in members)
    if (!tiers.containsKey(member)) '$member: assign it a tier in $packageTiersPath',
];

List<String> declarationViolations(String member, {required Set<String> declared, required Set<String> used}) => [
  for (final dead in (declared.difference(used).toList()..sort()))
    '$member declares $dead but no library in it imports it — remove the dependency',
  for (final undeclared in (used.difference(declared).toList()..sort()))
    '$member imports $undeclared but its pubspec does not declare it — the workspace resolver is hiding the edge',
];

Iterable<PackageEdge> _workspaceEdges(String repoRoot) sync* {
  for (final member in workspaceMembers(repoRoot)) {
    final lib = Directory('${member.path}/lib');
    if (!lib.existsSync()) continue;
    for (final file in lib.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final relative = relativeTo(file.path, repoRoot);
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final pkg = _packageDirective.firstMatch(lines[i])?.group(1);
        if (pkg == null || pkg == member.name || !isDartclawPackage(pkg)) continue;
        yield PackageEdge(member.name, pkg, '$relative:${i + 1}');
      }
    }
  }
}
