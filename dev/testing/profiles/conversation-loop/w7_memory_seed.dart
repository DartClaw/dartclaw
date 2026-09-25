// The profile script lives outside a pub package and uses existing workspace test dependencies.
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show WorkspaceService;
import 'package:dartclaw_testing/dartclaw_testing.dart' show seedCanonicalMemory;
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: w7_memory_seed.dart <data-dir>');
    exitCode = 64;
    return;
  }
  final dataDir = args.single;
  final owner = p.join(dataDir, 'workspace');
  final agents = [
    for (final id in ['alpha', 'beta', 'empty', 'removed'])
      AgentWorkspace.managed(agentId: id, dataDir: dataDir, ownerWorkspaceDir: owner),
  ];
  await WorkspaceService(dataDir: dataDir).prepareManagedAgents(agents);
  await seedCanonicalMemory(
    owner,
    topics: const {
      'general': ['collisiontoken owner-only marker'],
    },
  );
  await seedCanonicalMemory(
    agents[0].directory,
    topics: const {
      'general': ['collisiontoken alpha-only marker'],
    },
    archive: const {
      'general': ['alpha archived marker'],
    },
  );
  await seedCanonicalMemory(
    agents[1].directory,
    topics: const {
      'general': ['collisiontoken beta-only marker'],
    },
  );
  await seedCanonicalMemory(
    agents[3].directory,
    topics: const {
      'general': ['collisiontoken removed-only marker'],
    },
    observations: const {
      '2026-02-23': ['retained source observation marker'],
    },
  );
}
