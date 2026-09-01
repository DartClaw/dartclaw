import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
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
        expect(env.supportsProviderSessionResume, isFalse);

        final dirPath = await env.setup();
        final repeatedSetupPath = await env.setup();

        expect(env.isSetup, isTrue);
        expect(env.supportsProviderSessionResume, isFalse);
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
        expect(env.supportsProviderSessionResume, isTrue);

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

    group('dedicated store mode', () {
      late Directory root;
      late String dedicatedHome;

      setUp(() {
        root = Directory.systemTemp.createTempSync('codex-dedicated-');
        dedicatedHome = p.join(root.path, 'data', 'credentials', 'codex');
        Directory(dedicatedHome).createSync(recursive: true);
      });
      tearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      CodexEnvironment build({String? mcpServerUrl, String? mcpGatewayToken}) => CodexEnvironment.dedicated(
        developerInstructions: 'be careful',
        homePath: dedicatedHome,
        mcpServerUrl: mcpServerUrl,
        mcpGatewayToken: mcpGatewayToken,
        // The operator's own login sits under this HOME. This lifecycle copies
        // the operator's plugin capabilities from it and never the credential.
        platformCapabilities: PlatformCapabilities(environment: {'HOME': root.path}),
      );

      /// The operator's interactive login, planted where the *seeded* lifecycle
      /// copies from — without it, "was not copied" would pass vacuously.
      Future<void> plantOperatorLogin() async {
        Directory(p.join(root.path, '.codex')).createSync(recursive: true);
        File(p.join(root.path, '.codex', 'auth.json')).writeAsStringSync('{"token":"OPERATOR-LOGIN"}');

        final seeded = CodexEnvironment(
          developerInstructions: 'control',
          useSystemCodexHome: false,
          platformCapabilities: PlatformCapabilities(environment: {'HOME': root.path}),
        );
        final seededHome = await seeded.setup();
        addTearDown(seeded.cleanup);
        expect(
          File(p.join(seededHome, 'auth.json')).readAsStringSync(),
          contains('OPERATOR-LOGIN'),
          reason: 'control: the seeded lifecycle must copy this source, or the dedicated assertion proves nothing',
        );
      }

      test('writes only generated configuration and never seeds the operator login', () async {
        await plantOperatorLogin();
        File(p.join(dedicatedHome, 'auth.json')).writeAsStringSync('{"tokens":{"access_token":"DEDICATED"}}');
        final environment = build(mcpServerUrl: 'http://127.0.0.1:8081/mcp', mcpGatewayToken: 'test-token');

        final home = await environment.setup();

        expect(home, dedicatedHome);
        expect(File(p.join(home, 'auth.json')).readAsStringSync(), contains('DEDICATED'));
        expect(File(p.join(home, 'auth.json')).readAsStringSync(), isNot(contains('OPERATOR-LOGIN')));
        expect(File(p.join(home, 'config.toml')).readAsStringSync(), contains('[mcp_servers.dartclaw]'));
      });

      test('points CODEX_HOME at the dedicated store', () async {
        final environment = build(mcpGatewayToken: 'test-token');
        await environment.setup();

        expect(environment.environmentOverrides(), {'CODEX_HOME': dedicatedHome, 'DARTCLAW_MCP_TOKEN': 'test-token'});
      });

      /// Gives the operator home the plugin state a real Codex install has:
      /// enable stanzas in its own config, the plugin cache, and a skill.
      void plantOperatorPlugins() {
        final operatorCodex = Directory(p.join(root.path, '.codex'))..createSync(recursive: true);
        File(p.join(operatorCodex.path, 'config.toml')).writeAsStringSync(
          'model = "gpt-5.6-sol"\n\n'
          '[projects."/elsewhere"]\ntrust_level = "trusted"\n\n'
          '[plugins."andthen@andthen"]\nenabled = true\n',
        );
        Directory(p.join(operatorCodex.path, 'plugins', 'cache', 'andthen', '0.40.4')).createSync(recursive: true);
        File(p.join(operatorCodex.path, 'plugins', 'cache', 'andthen', '0.40.4', 'plugin.json'))
            .writeAsStringSync('{"name":"andthen"}');
        Directory(p.join(operatorCodex.path, 'skills')).createSync(recursive: true);
        File(p.join(operatorCodex.path, 'skills', 'local-skill.md')).writeAsStringSync('# local');
      }

      test('mirrors the operator plugin stanzas, cache and skills into the store', () async {
        plantOperatorPlugins();
        final environment = build(mcpServerUrl: 'http://127.0.0.1:8081/mcp', mcpGatewayToken: 'test-token');

        final home = await environment.setup();

        final config = File(p.join(home, 'config.toml')).readAsStringSync();
        expect(config, contains('[plugins."andthen@andthen"]'), reason: 'a plugin is enabled by the home it runs in');
        expect(config, isNot(contains('trust_level')), reason: 'only plugin tables travel, not the whole config');
        expect(File(p.join(home, 'plugins', 'cache', 'andthen', '0.40.4', 'plugin.json')).existsSync(), isTrue);
        expect(File(p.join(home, 'skills', 'local-skill.md')).readAsStringSync(), '# local');
      });

      test('mirroring never carries the operator credential across', () async {
        plantOperatorPlugins();
        await plantOperatorLogin();
        File(p.join(dedicatedHome, 'auth.json')).writeAsStringSync('{"tokens":{"access_token":"DEDICATED"}}');

        final home = await build().setup();

        expect(File(p.join(home, 'auth.json')).readAsStringSync(), contains('DEDICATED'));
        expect(File(p.join(home, 'auth.json')).readAsStringSync(), isNot(contains('OPERATOR-LOGIN')));
      });

      test('generates exactly as before when the operator enables no plugins', () async {
        Directory(p.join(root.path, '.codex')).createSync(recursive: true);
        File(p.join(root.path, '.codex', 'config.toml')).writeAsStringSync('model = "gpt-5.6-sol"\n');

        final home = await build(mcpGatewayToken: 'test-token').setup();

        expect(File(p.join(home, 'config.toml')).readAsStringSync(), isNot(contains('[plugins.')));
        expect(Directory(p.join(home, 'plugins')).existsSync(), isFalse);
        expect(Directory(p.join(home, 'skills')).existsSync(), isFalse);
      });

      test('setup succeeds when the operator has no codex home at all', () async {
        final home = await build().setup();

        expect(home, dedicatedHome);
        expect(File(p.join(home, 'config.toml')).readAsStringSync(), isNot(contains('[plugins.')));
      });

      group('completeDedicatedCodexHome (probe lane)', () {
        test('completes a store no worker has prepared yet', () {
          plantOperatorPlugins();

          completeDedicatedCodexHome(
            dedicatedHome,
            platformCapabilities: PlatformCapabilities(environment: {'HOME': root.path}),
          );

          expect(
            File(p.join(dedicatedHome, 'config.toml')).readAsStringSync(),
            contains('[plugins."andthen@andthen"]'),
            reason: 'the probe reads the home before any worker writes one',
          );
          expect(
            File(p.join(dedicatedHome, 'plugins', 'cache', 'andthen', '0.40.4', 'plugin.json')).existsSync(),
            isTrue,
          );
        });

        test('leaves a worker-written config alone', () {
          plantOperatorPlugins();
          File(p.join(dedicatedHome, 'config.toml')).writeAsStringSync(
            'developer_instructions = """\nbe careful\n"""\n\n[plugins."andthen@andthen"]\nenabled = true\n',
          );

          completeDedicatedCodexHome(
            dedicatedHome,
            platformCapabilities: PlatformCapabilities(environment: {'HOME': root.path}),
          );

          final config = File(p.join(dedicatedHome, 'config.toml')).readAsStringSync();
          expect(config, contains('be careful'), reason: 'generated developer instructions must survive the probe');
          expect('[plugins."andthen@andthen"]'.allMatches(config).length, 1, reason: 'no duplicate stanza');
        });

        test('is inert when the operator enables no plugins', () {
          Directory(p.join(root.path, '.codex')).createSync(recursive: true);
          File(p.join(root.path, '.codex', 'config.toml')).writeAsStringSync('model = "gpt-5.6-sol"\n');

          completeDedicatedCodexHome(
            dedicatedHome,
            platformCapabilities: PlatformCapabilities(environment: {'HOME': root.path}),
          );

          expect(File(p.join(dedicatedHome, 'config.toml')).existsSync(), isFalse);
        });
      });

      group('mirror invalidation and the single config.toml writer', () {
        PlatformCapabilities operatorCapabilities() => PlatformCapabilities(environment: {'HOME': root.path});

        void resetDedicatedHome() {
          Directory(dedicatedHome).deleteSync(recursive: true);
          Directory(dedicatedHome).createSync(recursive: true);
        }

        /// Takes the plugin out of the operator's Codex the way an uninstall does.
        void uninstallOperatorPlugin() {
          File(p.join(root.path, '.codex', 'config.toml')).writeAsStringSync('model = "gpt-5.6-sol"\n');
          Directory(p.join(root.path, '.codex', 'plugins', 'cache', 'andthen')).deleteSync(recursive: true);
          File(p.join(root.path, '.codex', 'skills', 'local-skill.md')).deleteSync();
        }

        test('both lanes write the same config.toml whichever prepares the store first', () async {
          plantOperatorPlugins();
          final config = File(p.join(dedicatedHome, 'config.toml'));

          await build(mcpServerUrl: 'http://127.0.0.1:8081/mcp', mcpGatewayToken: 'test-token').setup();
          completeDedicatedCodexHome(dedicatedHome, platformCapabilities: operatorCapabilities());
          final workerFirst = config.readAsStringSync();

          resetDedicatedHome();
          completeDedicatedCodexHome(dedicatedHome, platformCapabilities: operatorCapabilities());
          await build(mcpServerUrl: 'http://127.0.0.1:8081/mcp', mcpGatewayToken: 'test-token').setup();

          expect(
            config.readAsStringSync(),
            workerFirst,
            reason: 'a worker spawn and a probe racing on a fresh store must not leave two different homes',
          );
          expect(workerFirst, contains('be careful'), reason: 'the generated half survives the probe');
          expect(workerFirst, contains('[plugins."andthen@andthen"]'));
        });

        test('a plugin the operator uninstalled loses its table and its mirrored payload', () async {
          plantOperatorPlugins();
          await build().setup();
          expect(File(p.join(dedicatedHome, 'skills', 'local-skill.md')).existsSync(), isTrue);

          uninstallOperatorPlugin();
          await build().setup();

          final config = File(p.join(dedicatedHome, 'config.toml')).readAsStringSync();
          expect(config, isNot(contains('[plugins.')), reason: 'a stale table keeps advertising a gone plugin');
          expect(config, contains('be careful'));
          expect(Directory(p.join(dedicatedHome, 'plugins', 'cache', 'andthen')).existsSync(), isFalse);
          expect(File(p.join(dedicatedHome, 'skills', 'local-skill.md')).existsSync(), isFalse);
        });

        test('the probe lane invalidates the same way, without the generated half', () async {
          plantOperatorPlugins();
          await build().setup();

          uninstallOperatorPlugin();
          completeDedicatedCodexHome(dedicatedHome, platformCapabilities: operatorCapabilities());

          final config = File(p.join(dedicatedHome, 'config.toml')).readAsStringSync();
          expect(config, isNot(contains('[plugins.')));
          expect(config, contains('be careful'), reason: 'a probe never clobbers a worker-written config');
          expect(Directory(p.join(dedicatedHome, 'plugins', 'cache', 'andthen')).existsSync(), isFalse);
        });

        test('what the operator installed into the dedicated home directly survives every prepare', () async {
          plantOperatorPlugins();
          await build().setup();

          // `CODEX_HOME=<dedicated> codex …` installs here, not in ~/.codex, so
          // these names never appear in the mirror's source to be re-derived.
          File(p.join(dedicatedHome, 'skills', 'native-skill.md')).writeAsStringSync('# native');
          Directory(p.join(dedicatedHome, 'plugins', 'cache', 'native')).createSync(recursive: true);
          File(p.join(dedicatedHome, 'plugins', 'cache', 'native', 'plugin.json')).writeAsStringSync('{}');
          final config = File(p.join(dedicatedHome, 'config.toml'));
          config.writeAsStringSync('${config.readAsStringSync()}\n[plugins."native@local"]\nenabled = true\n');

          uninstallOperatorPlugin();
          await build().setup();
          completeDedicatedCodexHome(dedicatedHome, platformCapabilities: operatorCapabilities());

          expect(File(p.join(dedicatedHome, 'skills', 'native-skill.md')).readAsStringSync(), '# native');
          expect(File(p.join(dedicatedHome, 'plugins', 'cache', 'native', 'plugin.json')).existsSync(), isTrue);
          expect(config.readAsStringSync(), contains('[plugins."native@local"]'));
          expect(config.readAsStringSync(), isNot(contains('andthen@andthen')));
        });

        test('replaces a mirrored tree whole, through a staging sibling it clears', () async {
          plantOperatorPlugins();
          await build().setup();
          final staging = Directory(p.join(dedicatedHome, '.dartclaw-mirror-staging'))..createSync(recursive: true);
          File(p.join(staging.path, 'residue')).writeAsStringSync('from an interrupted pass');

          // The operator upgrades: one version replaces another under the same
          // mirrored entry name.
          Directory(p.join(root.path, '.codex', 'plugins', 'cache', 'andthen', '0.40.4')).deleteSync(recursive: true);
          Directory(p.join(root.path, '.codex', 'plugins', 'cache', 'andthen', '0.41.0')).createSync(recursive: true);
          File(p.join(root.path, '.codex', 'plugins', 'cache', 'andthen', '0.41.0', 'plugin.json'))
              .writeAsStringSync('{"name":"andthen"}');

          await build().setup();

          final cache = p.join(dedicatedHome, 'plugins', 'cache', 'andthen');
          expect(File(p.join(cache, '0.41.0', 'plugin.json')).existsSync(), isTrue);
          expect(
            Directory(p.join(cache, '0.40.4')).existsSync(),
            isFalse,
            reason: 'the entry is replaced whole, not merged over',
          );
          expect(
            staging.existsSync(),
            isFalse,
            reason: 'the swap renames through a same-filesystem sibling of the home and clears it after',
          );
        });

        test('mirrors no credential material into a store that holds none', () async {
          plantOperatorPlugins();
          await plantOperatorLogin();

          await build().setup();
          completeDedicatedCodexHome(dedicatedHome, platformCapabilities: operatorCapabilities());

          expect(File(p.join(dedicatedHome, 'auth.json')).existsSync(), isFalse);
          final mirrored = Directory(dedicatedHome)
              .listSync(recursive: true)
              .whereType<File>()
              .map((file) => file.readAsStringSync());
          expect(
            mirrored,
            everyElement(isNot(contains('OPERATOR-LOGIN'))),
            reason: 'no path out of ~/.codex may carry the operator login into the dedicated store',
          );
        });

        test('refuses the whole mirror when the operator config leaves the supported subset', () async {
          plantOperatorPlugins();
          await build().setup();

          File(p.join(root.path, '.codex', 'config.toml')).writeAsStringSync(
            'model = "gpt-5.6-sol"\n\n[plugins]\nauto_update = false\n\n'
            '[plugins."other@other"]\nenabled = true\n',
          );
          await build().setup();

          final config = File(p.join(dedicatedHome, 'config.toml')).readAsStringSync();
          expect(config, isNot(contains('other@other')), reason: 'a half-understood config is not spliced');
          expect(config, contains('be careful'), reason: 'the generated half is still written');
        });
      });

      test('cleanup leaves the store and its credential intact', () async {
        File(p.join(dedicatedHome, 'auth.json')).writeAsStringSync('{"tokens":{"access_token":"DEDICATED"}}');
        final environment = build();
        await environment.setup();

        await environment.cleanup();

        expect(File(p.join(dedicatedHome, 'auth.json')).existsSync(), isTrue);
        expect(Directory(dedicatedHome).existsSync(), isTrue);
      });
    });
  });
}
