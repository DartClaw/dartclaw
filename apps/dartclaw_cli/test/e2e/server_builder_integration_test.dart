@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/service_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

String _staticDir() {
  const fromPkg = 'packages/dartclaw_server/lib/src/static';
  if (Directory(fromPkg).existsSync()) return fromPkg;
  return p.join('..', '..', 'packages', 'dartclaw_server', 'lib', 'src', 'static');
}

String _templatesDir() {
  const fromWorkspace = 'packages/dartclaw_server/lib/src/templates';
  if (Directory(fromWorkspace).existsSync()) return fromWorkspace;
  return p.join('..', '..', 'packages', 'dartclaw_server', 'lib', 'src', 'templates');
}

HarnessFactory _harnessFactoryFor(AgentHarness harness) {
  final factory = HarnessFactory();
  factory.register('claude', (_) => harness);
  return factory;
}

Never _unexpectedExit(int code) {
  throw StateError('Unexpected exit($code) during server builder integration test');
}

class _RecordingChannel extends Channel {
  final List<(String, ChannelResponse)> sent = [];

  @override
  String get name => 'recording-googlechat';

  @override
  ChannelType get type => ChannelType.googlechat;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  bool ownsJid(String jid) => true;

  @override
  Future<void> sendMessage(String recipientJid, ChannelResponse response) async {
    sent.add((recipientJid, response));
  }
}

Future<void> _disposeWiringResult(WiringResult result, LogService logService) async {
  await result.server.shutdown();
  await result.shutdownExtras();
  result.heartbeat?.stop();
  result.scheduleService?.stop();
  result.resetService.dispose();
  await result.kvService.dispose();
  await result.selfImprovement.dispose();
  await result.taskService.dispose();
  await result.eventBus.dispose();
  await result.qmdManager?.stop();
  result.searchDb.close();
  await logService.dispose();
}

void main() {
  late Directory tempDir;
  late File configFile;
  late FakeAgentHarness worker;
  late MessageRedactor messageRedactor;
  late LogService logService;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_server_builder_integration_');
    configFile = File(p.join(tempDir.path, 'dartclaw.yaml'))..writeAsStringSync('# test config\n');
    worker = FakeAgentHarness();

    messageRedactor = MessageRedactor();
    logService = LogService.fromConfig(
      format: 'human',
      level: 'INFO',
      redactor: LogRedactor(redactor: messageRedactor),
    );
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('ServiceWiring builds a server that serves / and /health', () async {
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );

    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    final handler = result.server.handler;

    final rootResponse = await handler(Request('GET', Uri.parse('http://localhost/')));
    expect(rootResponse.statusCode, equals(302));
    expect(rootResponse.headers['location'], startsWith('/sessions/'));

    final healthResponse = await handler(Request('GET', Uri.parse('http://localhost/health')));
    expect(healthResponse.statusCode, equals(200));

    final healthBody = jsonDecode(await healthResponse.readAsString()) as Map<String, dynamic>;
    expect(healthBody['status'], equals('healthy'));
  });

  test('ServiceWiring wires AlertRouter into the production EventBus', () async {
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      alerts: const AlertsConfig(
        enabled: true,
        targets: [AlertTarget(channel: 'googlechat', recipient: 'spaces/abc')],
      ),
      channels: const ChannelConfig(
        channelConfigs: {
          'google_chat': {'enabled': true},
        },
      ),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );

    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    final channel = _RecordingChannel();
    result.channelManager!.registerChannel(channel);

    result.eventBus.fire(
      GuardBlockEvent(
        guardName: 'bash-guard',
        guardCategory: 'file',
        verdict: 'block',
        hookPoint: 'PreToolUse',
        timestamp: DateTime.now(),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(channel.sent, hasLength(1));
    expect(channel.sent.single.$1, equals('spaces/abc'));
    expect(channel.sent.single.$2.text, contains('Guard Block'));
  });
}
