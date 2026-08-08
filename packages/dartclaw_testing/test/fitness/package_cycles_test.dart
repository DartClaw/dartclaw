// Fitness function: zero cycles in the workspace package dependency graph.
//
// What this enforces:
//   The dependency graph formed by workspace packages (packages/ and apps/)
//   must be a directed acyclic graph (DAG). Any cycle between DartClaw
//   workspace packages fails this check.
//
// Why:
//   Cyclic dependencies cause build instability, make incremental compilation
//   unreliable, and signal a failure to maintain clean architectural layers.
//   The expected-deps contract in arch_check.dart defines the intended DAG;
//   this test catches any deviation at PR time.
//
// How to resolve a failure:
//   Cycles must be broken, not allowlisted. Identify which import is the
//   "wrong direction" in the dependency cycle and either:
//   (a) move the shared type into a lower-level package (e.g. dartclaw_core),
//   (b) introduce an interface in a lower-level package and depend on that, or
//   (c) remove the dependency entirely.
//   Do not add cycle entries to allowlist/package_cycles.txt — any non-empty
//   allowlist entry here is an architectural finding that must be resolved.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

void main() {
  late String repoRoot;

  setUpAll(() {
    repoRoot = findRepoRoot();
  });

  test('allowlist entries have required rationale format', () {
    final allowlistFile = File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/package_cycles.txt');
    assertAllowlistFormat(allowlistFile);
  });

  test('workspace package graph has no cycles', () async {
    final result = await Process.run('dart', ['pub', 'deps', '--json'], workingDirectory: repoRoot);
    if (result.exitCode != 0) {
      fail('dart pub deps --json failed: ${(result.stderr as String).trim()}');
    }

    final decoded = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final packages = decoded['packages'] as List<dynamic>;

    // Build a map of workspace-package-name → direct dartclaw deps.
    final workspaceNames = <String>{};
    final deps = <String, Set<String>>{};

    for (final pkg in packages) {
      final pkgMap = pkg as Map<String, dynamic>;
      final name = pkgMap['name'] as String;
      if (!_isWorkspaceName(name)) continue;
      workspaceNames.add(name);

      // Use directDependencies (production deps only) to avoid false cycles
      // through dev_dependencies, which are legitimately allowed to depend on
      // lower-level packages that dev-dep on them in turn.
      final directDeps = (pkgMap['directDependencies'] as List<dynamic>? ?? []).cast<String>();
      deps[name] = directDeps.where(_isWorkspaceName).toSet();
    }

    final cycles = <String>[];
    for (final start in workspaceNames) {
      final cycle = _detectCycle(start, deps, workspaceNames);
      if (cycle != null && !cycles.any((c) => c.contains(start))) {
        cycles.add(cycle);
      }
    }

    if (cycles.isNotEmpty) {
      fail(
        'Workspace package cycles detected — break the cycle instead of allowlisting:\n'
        '  ${cycles.join('\n  ')}\n'
        'See packages/dartclaw_testing/test/fitness/README.md for resolution guidance.',
      );
    }
  });
}

bool _isWorkspaceName(String name) => name == 'dartclaw' || name == 'dartclaw_cli' || name.startsWith('dartclaw_');

/// DFS cycle detection starting from [start].
/// Returns a human-readable cycle path like "a -> b -> c -> a", or null if no cycle.
String? _detectCycle(String start, Map<String, Set<String>> deps, Set<String> workspace) {
  final visited = <String>{};
  final path = <String>[];

  String? dfs(String node) {
    if (path.contains(node)) {
      final cycleStart = path.indexOf(node);
      return '${path.sublist(cycleStart).join(' -> ')} -> $node';
    }
    if (visited.contains(node)) return null;
    visited.add(node);
    path.add(node);
    for (final dep in (deps[node] ?? <String>{})) {
      final result = dfs(dep);
      if (result != null) return result;
    }
    path.removeLast();
    return null;
  }

  return dfs(start);
}
