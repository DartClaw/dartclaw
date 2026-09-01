import 'dart:io';

import 'package:dartclaw_runtime/src/concurrency/session_lock_manager.dart'
    show SessionLockNow, SessionLockTimerFactory;
import 'package:dartclaw_runtime/src/runtime/harness_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show DartclawServer;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:dartclaw_testing/dartclaw_testing.dart' show seedCanonicalMemory;

const _workspacePromptFiles = {
  'SOUL.md': 'Soul prompt',
  'USER.md': 'User prompt',
  'TOOLS.md': 'Tool prompt',
  'AGENTS.md': '## Agent prompt',
};

/// Writes the behavior files plus one canonical learning and one canonical error.
///
/// Both have to go through the corpus authority: `learnings.md` and `errors.md`
/// are canonical member paths, so hand-written legacy Markdown at either path
/// fails corpus hydration.
Future<void> writeWorkspacePromptFiles(String workspaceDir) async {
  Directory(workspaceDir).createSync(recursive: true);
  for (final entry in _workspacePromptFiles.entries) {
    File(p.join(workspaceDir, entry.key)).writeAsStringSync(entry.value);
  }
  await seedCanonicalMemory(workspaceDir, learnings: const ['Recent learning'], errors: const ['Recent error']);
}

Future<StorageWiring> wireTestStorage({
  required DartclawConfig config,
  required EventBus eventBus,
  required Never Function(int) exitFn,
}) async {
  final storage = StorageWiring(
    config: config,
    eventBus: eventBus,
    searchDbFactory: (_) => sqlite3.openInMemory(),
    taskDbFactory: (_) => sqlite3.openInMemory(),
    exitFn: exitFn,
  );
  await storage.wire();
  return storage;
}

Future<SecurityWiring> wireTestSecurity({
  required DartclawConfig config,
  required String dataDir,
  required EventBus eventBus,
  required Never Function(int) exitFn,
}) async {
  final security = SecurityWiring(config: config, dataDir: dataDir, eventBus: eventBus, exitFn: exitFn);
  await security.wire(
    agentDefs: config.agent.definitions.isNotEmpty ? config.agent.definitions : [AgentDefinition.searchAgent()],
  );
  return security;
}

Future<HarnessWiring> wireTestHarness({
  required DartclawConfig config,
  required String dataDir,
  required HarnessFactory harnessFactory,
  required Never Function(int) exitFn,
  required StorageWiring storage,
  required SecurityWiring security,
  required EventBus eventBus,
  required DartclawServer Function() serverRefGetter,
  Map<String, CredentialEntry> Function()? subscriptionCredentials,
  List<HarnessRegistrar> harnessRegistrars = const [],
  bool headless = false,
  int port = 3333,
  Map<String, String>? environment,
  SessionLockTimerFactory? turnTimerFactory,
  SessionLockNow? turnNow,
}) async {
  final harnessWiring = HarnessWiring(
    config: config,
    dataDir: dataDir,
    port: port,
    harnessFactory: harnessFactory,
    exitFn: exitFn,
    storage: storage,
    security: security,
    messageRedactor: MessageRedactor(),
    eventBus: eventBus,
    subscriptionCredentials: subscriptionCredentials,
    harnessRegistrars: harnessRegistrars,
    headless: headless,
    environment: environment,
    turnTimerFactory: turnTimerFactory,
    turnNow: turnNow,
  );
  await harnessWiring.wire(serverRefGetter: serverRefGetter);
  return harnessWiring;
}
