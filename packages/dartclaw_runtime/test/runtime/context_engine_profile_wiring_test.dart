import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/mcp/context_engine_profile.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code) during profile wiring test');

/// The profile's totality against the *wired* registry, not a list review: a
/// tool added later that is write-classified cannot enter the profile without
/// failing here.
void main() {
  late Directory tempDir;
  late LogService logService;
  late MessageRedactor messageRedactor;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_context_engine_wiring_');
    messageRedactor = MessageRedactor();
    logService = LogService.fromConfig(
      format: 'human',
      level: 'SEVERE',
      redactor: LogRedactor(redactor: messageRedactor),
    );
  });

  tearDown(() async {
    await logService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<Map<String, McpToolAccess>> wiredToolAccess() async {
    final configFile = File(p.join(tempDir.path, 'dartclaw.yaml'))..writeAsStringSync('# test config\n');
    final harnessFactory = HarnessFactory()..register('claude', (_) => FakeAgentHarness());
    final runtime = await DartclawRuntime.build(
      DartclawConfig(
        agent: const AgentConfig(provider: 'claude'),
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        providers: ProvidersConfig(
          entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
        ),
        gateway: const GatewayConfig(authMode: 'none'),
        server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      ),
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: harnessFactory,
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      messageRedactor: messageRedactor,
      resolvedAssets: const ResolvedAssets.embedded(),
      runWorkflowSkillsBootstrap: false,
    );
    addTearDown(runtime.shutdown);
    return runtime.server!.mcpHandler.toolAccess;
  }

  test('every profile tool is wired and read-classified, and no write-classified tool is in the profile', () async {
    final access = await wiredToolAccess();

    expect(
      contextEngineProfileTools.difference(access.keys.toSet()),
      isEmpty,
      reason: 'the profile names a tool this runtime does not register',
    );
    final writeClassified = access.entries
        .where((entry) => entry.value == McpToolAccess.write)
        .map((entry) => entry.key)
        .toSet();
    expect(contextEngineProfileTools.intersection(writeClassified), isEmpty);
  });

  // The write classification is not what keeps the egress tools out — they are
  // classified read. The profile's whole argument is that reaching a third
  // party on the owner's credentials disqualifies a tool regardless of its
  // classification, and without this the argument is unguarded: adding a search
  // tool to the profile passes every other assertion here.
  test('no tool that reaches a third party on the owner credentials is in the profile', () async {
    final access = await wiredToolAccess();

    // Structural, not a name heuristic: a tool is egress when it maps to a web
    // canonical, which is what the harness layer already uses to decide what a
    // container may reach. `memory_search` is knowledge-local and carries none.
    const egressCanonicals = {CanonicalTool.webSearch, CanonicalTool.webFetch};
    final egress = access.keys.where((name) {
      final canonical = CanonicalTool.fromName(name);
      return canonical != null && egressCanonicals.contains(canonical);
    }).toSet();
    expect(egress, isNotEmpty, reason: 'an egress tool must be wired for the assertion to bite');
    expect(
      contextEngineProfileTools.intersection(egress),
      isEmpty,
      reason: 'a tool that spends the owner credentials on a third party stays out, read-classified or not',
    );
  });

  test('the wired runtime registers write and non-profile read tools the client cannot reach', () async {
    final access = await wiredToolAccess();
    final policy = ContextEngineCallerPolicy(principal: mcpClientPrincipal('ide'));

    final reachable = access.keys.where(policy.allows).toSet();
    expect(reachable, contextEngineProfileTools);
    expect(access.keys, contains('kg_add'), reason: 'a write-classified tool must exist for the assertion to bite');
    expect(access.keys.where((name) => !policy.allows(name)), isNotEmpty);
  });
}
