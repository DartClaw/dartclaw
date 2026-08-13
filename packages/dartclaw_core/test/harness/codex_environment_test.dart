import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/src/harness/codex_environment.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('CodexEnvironment', () {
    group('isolated mode (useSystemCodexHome: false)', () {
      test('setup writes config.toml, AGENTS.md, and environment overrides', () async {
        final env = CodexEnvironment(
          developerInstructions: 'follow the rules',
          mcpServerUrl: 'http://127.0.0.1:3333/mcp',
          mcpGatewayToken: 'test-token',
          agentsMdContent: '# agent notes',
          useSystemCodexHome: false,
        );
        addTearDown(env.cleanup);

        expect(env.isSetup, isFalse);

        final dirPath = await env.setup();
        final repeatedSetupPath = await env.setup();

        expect(env.isSetup, isTrue);
        expect(Directory(dirPath).existsSync(), isTrue);
        expect(repeatedSetupPath, dirPath);

        final configFile = File(p.join(dirPath, 'config.toml'));
        final agentsFile = File(p.join(dirPath, 'AGENTS.md'));

        expect(configFile.existsSync(), isTrue);
        expect(agentsFile.existsSync(), isTrue);
        expect(configFile.readAsStringSync(), contains('developer_instructions = """'));
        expect(configFile.readAsStringSync(), contains('[mcp_servers.dartclaw]'));
        expect(configFile.readAsStringSync(), contains('bearer_token_env_var = "DARTCLAW_MCP_TOKEN"'));
        expect(agentsFile.readAsStringSync(), contains('# agent notes'));

        final overrides = env.environmentOverrides();
        expect(overrides['CODEX_HOME'], dirPath);
        expect(overrides['DARTCLAW_MCP_TOKEN'], 'test-token');
      });

      test('setup leaves AGENTS.md absent when agents content is not provided', () async {
        final env = CodexEnvironment(
          developerInstructions: 'follow the rules',
          mcpServerUrl: 'http://127.0.0.1:3333/mcp',
          useSystemCodexHome: false,
        );
        addTearDown(env.cleanup);

        expect(env.environmentOverrides(), isEmpty);

        final dirPath = await env.setup();
        final configFile = File(p.join(dirPath, 'config.toml'));
        final agentsFile = File(p.join(dirPath, 'AGENTS.md'));

        expect(configFile.existsSync(), isTrue);
        expect(configFile.readAsStringSync(), contains('developer_instructions = """'));
        expect(configFile.readAsStringSync(), isNot(contains('bearer_token_env_var')));
        expect(agentsFile.existsSync(), isFalse);
        expect(env.environmentOverrides(), {'CODEX_HOME': dirPath});
      });

      test('seeds authentication without merging user config into generated TOML', () async {
        final userHome = Directory.systemTemp.createTempSync('dartclaw-codex-user-');
        addTearDown(() => userHome.deleteSync(recursive: true));
        final sourceHome = Directory(p.join(userHome.path, '.codex'))..createSync();
        File(p.join(sourceHome.path, 'auth.json')).writeAsStringSync('{"tokens":{}}');
        File(
          p.join(sourceHome.path, 'config.toml'),
        ).writeAsStringSync('developer_instructions = "user"\n\n[mcp_servers.dartclaw]\nurl = "https://example.com"\n');
        final env = CodexEnvironment(
          developerInstructions: 'worker rules',
          mcpServerUrl: 'http://127.0.0.1:3333/mcp',
          useSystemCodexHome: false,
          platformCapabilities: PlatformCapabilities(operatingSystem: 'linux', environment: {'HOME': userHome.path}),
        );
        addTearDown(env.cleanup);

        final dirPath = await env.setup();
        final config = File(p.join(dirPath, 'config.toml')).readAsStringSync();

        expect(File(p.join(dirPath, 'auth.json')).readAsStringSync(), '{"tokens":{}}');
        expect('developer_instructions'.allMatches(config), hasLength(1));
        expect('[mcp_servers.dartclaw]'.allMatches(config), hasLength(1));
        expect(config, isNot(contains('https://example.com')));
      });

      test('cleanup removes the temp directory and is safe to call twice', () async {
        final env = CodexEnvironment(developerInstructions: 'cleanup test', useSystemCodexHome: false);
        final dirPath = await env.setup();
        final tempDir = Directory(dirPath);

        expect(tempDir.existsSync(), isTrue);
        expect(env.isSetup, isTrue);

        await env.cleanup();

        expect(tempDir.existsSync(), isFalse);
        expect(env.isSetup, isFalse);
        expect(env.environmentOverrides(), isEmpty);
        expect(() async => env.cleanup(), returnsNormally);
      });
    });

    group('system mode (useSystemCodexHome: true, the default)', () {
      test('setup returns ~/.codex without mutating anything and default is true', () async {
        final env = CodexEnvironment(
          developerInstructions: 'anything',
          platformCapabilities: PlatformCapabilities(
            operatingSystem: 'linux',
            environment: const {'HOME': '/home/dev'},
          ),
        );
        // Default value check — no explicit param.
        expect(env.useSystemCodexHome, isTrue);
        expect(env.isSetup, isTrue, reason: 'system mode is considered set up before setup() runs');

        final dirPath = await env.setup();
        expect(dirPath, p.join('/home/dev', '.codex'));
        expect(
          env.environmentOverrides().containsKey('CODEX_HOME'),
          isFalse,
          reason: 'system mode must NOT override CODEX_HOME — subprocess inherits from parent env',
        );
      });

      test('setup still exports the MCP bearer token env var when configured', () async {
        final env = CodexEnvironment(developerInstructions: 'irrelevant', mcpGatewayToken: 'bearer-xyz');
        await env.setup();
        final overrides = env.environmentOverrides();
        expect(overrides, {'DARTCLAW_MCP_TOKEN': 'bearer-xyz'});
      });

      test('cleanup is a no-op in system mode', () async {
        final env = CodexEnvironment(developerInstructions: 'nothing to clean');
        await env.setup();
        await env.cleanup();
        expect(() async => env.cleanup(), returnsNormally);
      });

      test('setup resolves a native Windows USERPROFILE through platform capabilities', () async {
        final env = CodexEnvironment(
          developerInstructions: 'anything',
          platformCapabilities: PlatformCapabilities(
            operatingSystem: 'windows',
            environment: const {'USERPROFILE': r'C:\Users\dev'},
          ),
        );

        expect(await env.setup(), r'C:\Users\dev\.codex');
      });

      test('setup converts a missing home into the structured capability error', () async {
        final env = CodexEnvironment(
          developerInstructions: 'anything',
          platformCapabilities: PlatformCapabilities(operatingSystem: 'windows', environment: const {}),
        );

        await expectLater(
          env.setup(),
          throwsA(
            isA<UnsupportedCapabilityError>()
                .having((error) => error.capability, 'capability', 'home directory')
                .having((error) => error.attemptedContext, 'attempted context', contains('HOME'))
                .having((error) => error.attemptedContext, 'attempted context', contains('USERPROFILE'))
                .having(
                  (error) => error.remediation,
                  'remediation',
                  'Set HOME or USERPROFILE before starting DartClaw.',
                ),
          ),
        );
      });
    });

    group('container auth-clean home', () {
      late Directory root;

      setUp(() => root = Directory.systemTemp.createTempSync('codex-auth-clean-'));
      tearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      CodexEnvironment build({String? mcpServerUrl, bool nativeWebSearch = true}) =>
          CodexEnvironment.containerAuthClean(
            developerInstructions: 'be careful',
            hostHomePath: p.join(root.path, 'codex-home'),
            containerHomePath: '/home/dartclaw/.dartclaw/codex-home',
            gatewayBaseUrl: 'http://127.0.0.1:8080/v1',
            nativeWebSearch: nativeWebSearch,
            mcpServerUrl: mcpServerUrl,
            // Points the seeding lifecycle's source at the temp root, so a home
            // planted below is genuinely copyable and the assertion can fail.
            platformCapabilities: PlatformCapabilities(environment: {'HOME': root.path}),
          );

      /// Plants a credentialed host home where the *seeded* lifecycle copies
      /// from, and proves that lifecycle really does copy it – without the
      /// control, "was not copied" would pass against an unreadable source.
      Future<void> plantCredentialedHostHome() async {
        Directory(p.join(root.path, '.codex')).createSync(recursive: true);
        File(p.join(root.path, '.codex', 'auth.json')).writeAsStringSync('{"token":"HOST-TOKEN"}');

        final seeded = CodexEnvironment(
          developerInstructions: 'control',
          useSystemCodexHome: false,
          platformCapabilities: PlatformCapabilities(environment: {'HOME': root.path}),
        );
        final seededHome = await seeded.setup();
        addTearDown(seeded.cleanup);
        expect(
          File(p.join(seededHome, 'auth.json')).existsSync(),
          isTrue,
          reason: 'control: the seeded lifecycle must copy this source, or the auth-clean assertion proves nothing',
        );
      }

      test('never copies host authentication, however credentialed the host home is', () async {
        await plantCredentialedHostHome();
        final environment = build();

        final home = await environment.setup();

        expect(Directory(home).listSync().map((entry) => p.basename(entry.path)), ['config.toml']);
        expect(File(p.join(home, 'config.toml')).readAsStringSync(), isNot(contains('HOST-TOKEN')));
      });

      test('replaces any residue left at the same path', () async {
        final home = Directory(p.join(root.path, 'codex-home'))..createSync(recursive: true);
        File(p.join(home.path, 'auth.json')).writeAsStringSync('{"token":"STALE"}');

        await build().setup();

        expect(File(p.join(home.path, 'auth.json')).existsSync(), isFalse);
      });

      test('points CODEX_HOME at the container path and exports no bearer', () async {
        final environment = build(mcpServerUrl: 'http://127.0.0.1:8081/mcp');
        await environment.setup();

        expect(environment.environmentOverrides(), {'CODEX_HOME': '/home/dartclaw/.dartclaw/codex-home'});
      });

      test('reports no overrides before setup, so a failed start cannot point at a missing home', () {
        expect(build().environmentOverrides(), isEmpty);
        expect(build().isSetup, isFalse);
      });

      test('cleanup removes the generated home', () async {
        final environment = build();
        final home = await environment.setup();

        await environment.cleanup();

        expect(Directory(home).existsSync(), isFalse);
      });
    });
  });
}
