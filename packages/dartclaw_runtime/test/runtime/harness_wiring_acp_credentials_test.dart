import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_acp/dartclaw_acp.dart';
import 'package:dartclaw_runtime/src/runtime/harness_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness_wiring_fixture.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code) during ACP credential test');

const _storedSetupToken = 'sk-ant-oat01-STORED';

/// What an ACP agent's own process finds in its environment.
///
/// ACP registrations are credential-isolated from DartClaw's first-party
/// provider auth: `model_provider` routes and validates, it does not select a
/// credential, and no subscription token is ever handed to a third-party client.
/// The assertions read the real spawned process's environment rather than the
/// wiring's intent, because the whole property is about what crosses that
/// boundary.
void main() {
  late Directory tempDir;
  late Directory shimDir;
  late String shimDill;
  late File envFile;
  late DartclawConfig config;
  late EventBus eventBus;
  StorageWiring? storage;
  SecurityWiring? security;
  HarnessWiring? harnessWiring;

  setUpAll(() async {
    // The shim reports its own environment, then speaks just enough ACP to complete the initialize handshake
    // wiring waits on. Compiled once: spawning it from source recompiles per test and exceeds the harness's
    // 10-second initialize timeout on a loaded CI runner.
    shimDir = Directory.systemTemp.createTempSync('dartclaw_acp_shim_');
    final shimSource = File(p.join(shimDir.path, 'fake_acp.dart'))
      ..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  File(args.single).writeAsStringSync(jsonEncode(Platform.environment));
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': {
          'protocolVersion': 1,
          'auth': {'status': 'authenticated'},
        },
      }));
    }
  }
}
''');
    shimDill = p.join(shimDir.path, 'fake_acp.dill');
    final compile = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      shimSource.path,
      '-o',
      shimDill,
    ]);
    if (compile.exitCode != 0) {
      fail('fake ACP shim failed to compile: ${compile.stderr}');
    }
  });

  tearDownAll(() {
    if (shimDir.existsSync()) shimDir.deleteSync(recursive: true);
  });

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_acp_credentials_');
    envFile = File(p.join(tempDir.path, 'acp-env.json'));
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'goose'),
      harness: HarnessConfig(
        sections: {
          'acp': {
            'agents': {
              'goose': {
                'binary': Platform.resolvedExecutable,
                'args': [shimDill, envFile.path],
                'topology': 'direct',
                'model_provider': 'anthropic',
                'verification': 'a0_1_goose_direct',
                'required_builtins': const ['developer'],
              },
            },
          },
        },
      ),
      credentials: const CredentialsConfig(
        entries: {
          'anthropic': CredentialEntry(apiKey: 'anthropic-key', envVars: ['ANTHROPIC_API_KEY']),
          'project': CredentialEntry.githubToken(token: 'ghp-token', envVars: ['GITHUB_TOKEN']),
        },
      ),
      gateway: const GatewayConfig(authMode: 'none'),
    );
    await writeWorkspacePromptFiles(config.workspaceDir);
    eventBus = EventBus();
  });

  tearDown(() async {
    await harnessWiring?.executions.dispose();
    await security?.dispose();
    await storage?.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Reconfigures the registered ACP agent, preserving the shim invocation.
  void reconfigureAgent({String? credential, String? modelProvider}) {
    final agent = Map<String, dynamic>.from((config.harness.sections['acp']!['agents'] as Map)['goose'] as Map);
    config = config.copyWith(
      harness: HarnessConfig(
        sections: {
          'acp': {
            'agents': {
              'goose': {...agent, 'model_provider': ?modelProvider, 'credential': ?credential},
            },
          },
        },
      ),
    );
  }

  /// Wires the deployment and returns the environment the ACP process was
  /// really spawned with.
  Future<Map<String, String>> acpSpawnEnvironment({Map<String, CredentialEntry> Function()? subscriptions}) async {
    storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: _unexpectedExit);
    security = await wireTestSecurity(
      config: config,
      dataDir: tempDir.path,
      eventBus: eventBus,
      exitFn: _unexpectedExit,
    );
    harnessWiring = await wireTestHarness(
      config: config,
      dataDir: tempDir.path,
      harnessFactory: HarnessFactory(),
      exitFn: _unexpectedExit,
      storage: storage!,
      security: security!,
      eventBus: eventBus,
      subscriptionCredentials: subscriptions,
      harnessRegistrars: const [AcpHarnessRegistrar()],
      environment: const {'PATH': '/usr/bin', 'ANTHROPIC_API_KEY': 'sk-ant-inherited'},
      serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called'),
    );
    final decoded = jsonDecode(envFile.readAsStringSync()) as Map<String, dynamic>;
    return decoded.map((key, value) => MapEntry(key, '$value'));
  }

  Map<String, CredentialEntry> storedClaudeToken() => {
    'claude': CredentialEntry.subscription(token: _storedSetupToken),
  };

  test('model_provider: anthropic selects no first-party credential for the agent', () async {
    final environment = await acpSpawnEnvironment(subscriptions: storedClaudeToken);

    expect(
      environment['CLAUDE_CODE_OAUTH_TOKEN'],
      isNull,
      reason: 'a subscription token must never be forwarded to a third-party ACP client',
    );
    expect(
      environment['ANTHROPIC_API_KEY'],
      isNull,
      reason:
          'credentials.anthropic belongs to DartClaw\'s own Claude provider, not to whatever ACP agent '
          'declares the same model_provider',
    );
    expect(
      environment.containsKey('PATH'),
      isTrue,
      reason: 'isolation is about the credential, not about a crippled environment',
    );
  });

  test('a forced providers.claude.auth: subscription neither injects nor refuses', () async {
    config = config.copyWith(
      providers: const ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: 'claude', auth: ProviderAuth.subscription)},
      ),
    );

    final environment = await acpSpawnEnvironment(subscriptions: storedClaudeToken);

    expect(environment['CLAUDE_CODE_OAUTH_TOKEN'], isNull);
    expect(environment['ANTHROPIC_API_KEY'], isNull);
    expect(
      harnessWiring,
      isNotNull,
      reason:
          'an ACP agent is never refused on credential grounds, so a forced first-party selection it does not '
          'participate in cannot fail its startup',
    );
  });

  test('an explicit credential reference is the one thing presented, whatever providers.* selects', () async {
    reconfigureAgent(credential: 'anthropic');
    // The discriminating half: the mapping this replaces routed the agent
    // through `providers.claude.auth`, where a forced subscription starved it
    // of exactly this key.
    config = config.copyWith(
      providers: const ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: 'claude', auth: ProviderAuth.subscription)},
      ),
    );

    final environment = await acpSpawnEnvironment(subscriptions: storedClaudeToken);

    expect(environment['ANTHROPIC_API_KEY'], 'anthropic-key');
    expect(
      environment['CLAUDE_CODE_OAUTH_TOKEN'],
      isNull,
      reason: 'naming an API key opts into that key alone, never into the stored subscription',
    );
  });

  test('a non-api_key credential reference presents nothing', () async {
    reconfigureAgent(credential: 'project');

    final environment = await acpSpawnEnvironment();

    expect(environment['GITHUB_TOKEN'], isNull);
    expect(environment['ANTHROPIC_API_KEY'], isNull);
    // The parse warns and drops the reference; a directly constructed
    // registration reaches the overlay instead, which must fail closed on the
    // same rule rather than handing an ACP agent the operator's GitHub token.
    expect(
      overlayAcpCredential(
        environment: {},
        credentials: config.credentials,
        agent: const AcpAgentConfig(binary: 'goose', credential: 'project'),
      ),
      isEmpty,
    );
  });
}
