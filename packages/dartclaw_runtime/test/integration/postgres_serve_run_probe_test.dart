@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/testing.dart' show FakeProviderAuthPreflight;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../../../dartclaw_core/test/storage/postgres_live_support.dart';

const _injectedDsn = 'postgresql://runtime:SqliteFreeProbeSecretX9@injected.invalid/dartclaw';
const _webhookSecret = 'signed-webhook-probe-secret';

void main() {
  setUpAll(initEmbeddedTemplates);
  tearDownAll(resetTemplates);

  test('PostgreSQL serve build, turn, signed webhook, and shutdown perform zero SQLite opens', () async {
    await withPostgresBackend((backend, _) async {
      final dataDir = Directory.systemTemp.createTempSync('postgres_serve_probe_');
      final observedSqliteOpens = <String?>[];
      final previousObserver = SqliteBackend.openObserver;
      SqliteBackend.openObserver = observedSqliteOpens.add;
      DartclawRuntime? runtime;
      try {
        final harness = FakeAgentHarness();
        final config = _config(dataDir);
        await seedCanonicalMemory(config.workspaceDir);
        final configFile = File(p.join(dataDir.path, 'dartclaw.yaml'))..writeAsStringSync('# SQLite-free probe\n');
        final key = 1000000 + Random.secure().nextInt(1000000000);

        runtime = await DartclawRuntime.build(
          config,
          dataDir: dataDir.path,
          port: 0,
          harnessFactory: HarnessFactory()..register('claude', (_) => harness),
          taskBackendFactory: (_) async => backend,
          searchBackendFactory: (_) async => throw StateError('PostgreSQL must not open a SQLite search backend'),
          stderrLine: (_) {},
          exitFn: (code) => throw StateError('Unexpected serve exit($code)'),
          resolvedConfigPath: configFile.path,
          messageRedactor: MessageRedactor(),
          resolvedAssets: const ResolvedAssets.embedded(),
          postgresInterlockFactory: () => PostgresInterlock(key: key),
          runWorkflowSkillsBootstrap: false,
          providerAuthPreflight: FakeProviderAuthPreflight(),
        );
        final server = runtime.server!;

        final createResponse = await server.handler(
          Request('POST', Uri.parse('http://localhost/api/sessions'), headers: const {'host': 'localhost'}),
        );
        expect(createResponse.statusCode, 201);
        final session = jsonDecode(await createResponse.readAsString()) as Map<String, dynamic>;
        final sessionId = session['id'] as String;

        final sendResponse = await server.handler(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sessions/$sessionId/send'),
            headers: const {'host': 'localhost', 'content-type': 'application/json'},
            body: jsonEncode({'message': 'Prove the PostgreSQL runtime turn.'}),
          ),
        );
        expect(sendResponse.statusCode, 200, reason: await sendResponse.readAsString());
        await harness.turnInvoked;
        harness.emit(DeltaEvent('PostgreSQL turn complete.'));
        harness.completeSuccess();
        final messages = await _eventuallyMessages(server, sessionId, expectedCount: 2);
        expect((messages.last as Map<String, dynamic>)['content'], 'PostgreSQL turn complete.');

        const webhookBody = '{"zen":"postgres serve probe"}';
        final digest = Hmac(sha256, utf8.encode(_webhookSecret)).convert(utf8.encode(webhookBody));
        final webhookResponse = await server.handler(
          Request(
            'POST',
            Uri.parse('http://localhost/webhook/github'),
            headers: {
              'host': 'localhost',
              'content-type': 'application/json',
              'x-github-event': 'ping',
              'x-github-delivery': 'postgres-serve-probe-delivery',
              'x-hub-signature-256': 'sha256=$digest',
            },
            body: webhookBody,
          ),
        );
        expect(webhookResponse.statusCode, 200);
        expect(jsonDecode(await webhookResponse.readAsString()), containsPair('ignored', true));

        await runtime.shutdown();
        runtime = null;
        expect(observedSqliteOpens, isEmpty);
        expect(_databaseArtifacts(dataDir), isEmpty);
      } finally {
        await runtime?.shutdown();
        SqliteBackend.openObserver = previousObserver;
        if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
      }
    });
  });
}

DartclawConfig _config(Directory dataDir) => DartclawConfig(
  agent: const AgentConfig(provider: 'claude'),
  credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
  providers: ProvidersConfig(entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)}),
  gateway: const GatewayConfig(authMode: 'none'),
  extensions: const {'github': GitHubWebhookConfig(enabled: true, webhookSecret: _webhookSecret)},
  database: const DatabaseConfig(
    backend: DatabaseBackendKind.postgres,
    url: _injectedDsn,
    urlEnvVars: ['DARTCLAW_TEST_POSTGRES_URL'],
    poolSize: 3,
  ),
  server: ServerConfig(dataDir: dataDir.path, claudeExecutable: Platform.resolvedExecutable),
);

Future<List<dynamic>> _eventuallyMessages(DartclawServer server, String sessionId, {required int expectedCount}) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final response = await server.handler(
      Request('GET', Uri.parse('http://localhost/api/sessions/$sessionId/messages')),
    );
    final messages = jsonDecode(await response.readAsString()) as List<dynamic>;
    if (messages.length >= expectedCount) return messages;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('The completed turn did not persist before the live-test deadline.');
}

List<String> _databaseArtifacts(Directory dataDir) => dataDir
    .listSync(recursive: true, followLinks: false)
    .whereType<File>()
    .where((file) => file.uri.pathSegments.last.contains('.db'))
    .map((file) => file.path)
    .toList(growable: false);
