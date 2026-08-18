import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/harness_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/security_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/storage_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessConfig;
import 'package:dartclaw_server/dartclaw_server.dart' show DartclawServer;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const _workspacePromptFiles = {
  'SOUL.md': 'Soul prompt',
  'USER.md': 'User prompt',
  'TOOLS.md': 'Tool prompt',
  'AGENTS.md': '## Agent prompt',
  'errors.md': '## Recent error',
  'learnings.md': '- [2026-08-10 10:00] Recent learning\n',
};

void writeWorkspacePromptFiles(String workspaceDir) {
  Directory(workspaceDir).createSync(recursive: true);
  for (final entry in _workspacePromptFiles.entries) {
    File(p.join(workspaceDir, entry.key)).writeAsStringSync(entry.value);
  }
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
  int port = 3333,
  Map<String, String>? environment,
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
    environment: environment,
  );
  await harnessWiring.wire(serverRefGetter: serverRefGetter);
  return harnessWiring;
}
