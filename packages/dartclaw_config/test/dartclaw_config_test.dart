import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/load_config.dart';

class _FakeGoogleChatConfig {
  final bool enabled;

  const _FakeGoogleChatConfig({this.enabled = false});
}

void _ensureTestGoogleChatRegistered() {
  DartclawConfig.registerChannelConfigParser(ChannelType.googlechat, (yaml, warns) {
    final enabled = yaml['enabled'];
    if (enabled != null && enabled is! bool) {
      warns.add('Invalid type for google_chat.enabled: "${enabled.runtimeType}" — using default');
    }
    return _FakeGoogleChatConfig(enabled: enabled is bool ? enabled : false);
  });
}

void main() {
  setUpAll(_ensureTestGoogleChatRegistered);

  group('DartclawConfig', () {
    group('defaults', () {
      test('all fields have expected default values', () {
        final config = const DartclawConfig.defaults();
        expect(config.server.port, 3333);
        expect(config.server.host, 'localhost');
        expect(config.server.dataDir, '~/.dartclaw');
        expect(config.server.workerTimeout, 600);
        expect(config.server.claudeExecutable, 'claude');
        expect(config.server.staticDir, 'packages/dartclaw_server/lib/src/static');
        expect(config.onboarding.expiryDays, 14);
        expect(config.warnings, isEmpty);
      });

      test('providers, credentials, and agent.provider have expected defaults', () {
        final config = const DartclawConfig.defaults();

        expect(config.providers, const ProvidersConfig.defaults());
        expect(config.providers.isEmpty, isTrue);
        expect(config.credentials, const CredentialsConfig.defaults());
        expect(config.credentials.isEmpty, isTrue);
        expect(config.agent.provider, 'claude');
      });
    });

    group('copyWith', () {
      test('replaces only the named section and preserves all others', () {
        final base = DartclawConfig(
          server: ServerConfig(dataDir: '/data'),
          knowledge: const KnowledgeConfig(
            inbox: KnowledgeInboxConfig(
              enabled: true,
              intervalMinutes: 15,
              maxBytes: 4096,
              retryAttempts: 5,
              processedRetentionDays: 7,
              deliveryMode: 'announce',
            ),
          ),
        );

        final updated = base.copyWith(security: base.security.copyWith(guardsYaml: const {'command': true}));

        // The replaced section carries the new value.
        expect(updated.security.guardsYaml, const {'command': true});
        // Every other section — including 0.17 additions like knowledge — survives.
        expect(updated.knowledge, base.knowledge);
        expect(updated.server, base.server);
        expect(updated.onboarding, base.onboarding);
        expect(updated.security.contentGuardEnabled, base.security.contentGuardEnabled);
      });
    });

    group('derived getters', () {
      final config = DartclawConfig(server: ServerConfig(dataDir: '/data'));
      final cases = [
        (name: 'sessionsDir', actual: config.sessionsDir, expected: '/data/sessions'),
        (name: 'searchDbPath', actual: config.searchDbPath, expected: '/data/search.db'),
        (name: 'tasksDbPath', actual: config.tasksDbPath, expected: '/data/tasks.db'),
        (name: 'kvPath', actual: config.kvPath, expected: '/data/kv.json'),
        (name: 'workspaceDir', actual: config.workspaceDir, expected: '/data/workspace'),
        (name: 'logsDir', actual: config.logsDir, expected: '/data/logs'),
        (name: 'projectsJsonPath', actual: config.projectsJsonPath, expected: '/data/projects.json'),
        (name: 'projectsClonesDir', actual: config.projectsClonesDir, expected: '/data/projects'),
      ];

      for (final testCase in cases) {
        test('${testCase.name} joins dataDir', () {
          expect(testCase.actual, testCase.expected);
        });
      }
    });

    group('load', () {
      test('exposes ChannelConfigProvider via adapter', () {
        final config = loadNoFile();
        expect(config, isNot(isA<ChannelConfigProvider>()));
        expect(config.channelConfigProvider, isA<ChannelConfigProvider>());
      });

      test('missing config file uses defaults', () {
        final config = loadNoFile();
        expect(config.server.port, 3333);
        expect(config.server.host, 'localhost');
        expect(config.server.dataDir, '/home/user/.dartclaw');
        expect(config.server.workerTimeout, 600);
        expect(config.warnings, isEmpty);
      });

      test('YAML parsing: flat keys parsed correctly', () {
        final config = loadYaml(
          'port: 8080\nhost: 0.0.0.0\ndata_dir: /custom/data\nworker_timeout: 300\ngateway:\n  hsts: true\n',
        );
        expect(config.server.port, 8080);
        expect(config.server.host, '0.0.0.0');
        expect(config.server.dataDir, '/custom/data');
        expect(config.server.workerTimeout, 300);
        expect(config.gateway.hsts, isTrue);
      });

      test('minimal workflow config loads with safe defaults', () {
        final config = loadYaml('''
data_dir: ./dartclaw
agent:
  provider: claude
  model: claude-sonnet-4-6
providers:
  claude:
    executable: claude
''', configPath: '/workspace/dartclaw/dartclaw.yaml');

        expect(config.server.port, 3333);
        expect(config.server.name, 'DartClaw');
        expect(config.server.dataDir, p.normalize('/workspace/dartclaw/dartclaw'));
        expect(config.gateway.authMode, 'token');
        expect(config.tasks.maxConcurrent, 3);
        expect(config.governance.rateLimits.perSender.messages, 0);
        expect(config.workflow.defaults.workflow.provider, 'claude');
      });

      test('onboarding expiry defaults and parses override', () {
        final defaults = loadNoFile();
        expect(defaults.onboarding.expiryDays, 14);

        final configured = loadYaml('onboarding:\n  expiry_days: 3\n');
        expect(configured.onboarding.expiryDays, 3);
      });

      test('google chat parser works after explicit package registration', () {
        final config = loadNoFile();
        final googleChatConfig = config.getChannelConfig<_FakeGoogleChatConfig>(ChannelType.googlechat);
        expect(googleChatConfig, isA<_FakeGoogleChatConfig>());
        expect(googleChatConfig.enabled, isFalse);
      });

      test('getChannelConfig rejects ChannelType.web', () {
        final config = loadNoFile();
        expect(() => config.getChannelConfig<Object>(ChannelType.web), throwsArgumentError);
      });

      test('getChannelConfig rejects unregistered extracted channels before type checking', () {
        final config = loadNoFile();
        expect(() => config.getChannelConfig<DartclawConfig>(ChannelType.signal), throwsStateError);
      });

      test('getChannelConfig keeps other extracted channels externally registered', () {
        final config = loadNoFile();
        final googleChatConfig = config.getChannelConfig<_FakeGoogleChatConfig>(ChannelType.googlechat);
        expect(googleChatConfig, isA<_FakeGoogleChatConfig>());
        expect(() => config.getChannelConfig<Object>(ChannelType.whatsapp), throwsStateError);
        expect(() => config.getChannelConfig<Object>(ChannelType.signal), throwsStateError);
      });

      test('resolution order: CLI > YAML > defaults', () {
        final config = loadYaml('port: 8080\nhost: 0.0.0.0\n', cli: const {'port': '9090'});
        // CLI wins for port
        expect(config.server.port, 9090);
        // YAML wins for host (no CLI override)
        expect(config.server.host, '0.0.0.0');
        // Default for workerTimeout (neither CLI nor YAML)
        expect(config.server.workerTimeout, 600);
      });

      test('\${ENV_VAR} substitution in YAML string values', () {
        final config = loadYaml('host: \${MY_HOST}\n', env: const {'HOME': defaultTestHome, 'MY_HOST': 'custom.host'});
        expect(config.server.host, 'custom.host');
      });

      test('unknown key collects warning', () {
        final config = loadYaml('port: 3000\nbogus_key: 42\n');
        expect(config.warnings, contains(contains('Unknown config key: bogus_key')));
      });

      test('projects: section parsed into DartclawConfig.projects — no unknown key warning', () {
        const yaml = '''
projects:
  my-app:
    remote: git@github.com:user/my-app.git
    branch: develop
    credentials: github-ssh
    default: true
    clone:
      strategy: full
    pr:
      strategy: github-pr
      draft: true
      labels: [agent, automated]
''';
        final config = loadYaml(yaml);

        expect(config.warnings, isNot(anyElement(contains('Unknown config key: projects'))));
        expect(config.projects.isEmpty, isFalse);
        final def = config.projects.definitions['my-app'];
        expect(def, isNotNull);
        expect(def!.remote, 'git@github.com:user/my-app.git');
        expect(def.branch, 'develop');
        expect(def.credentials, 'github-ssh');
        expect(def.isDefault, isTrue);
      });

      test('type mismatch (port: "abc") collects warning and uses default', () {
        final config = loadYaml('port: abc\n');
        expect(config.server.port, 3333);
        expect(config.warnings, anyElement(contains('Invalid type for port')));
      });

      test('DARTCLAW_CONFIG env var overrides file search path', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == '/etc/dartclaw.yaml') return 'port: 4444\n';
            return null;
          },
          env: {'HOME': '/home/user', 'DARTCLAW_CONFIG': '/etc/dartclaw.yaml'},
        );
        expect(config.server.port, 4444);
      });

      test('YAML parse error collects warning and uses defaults', () {
        final config = loadYaml('{\n  invalid: [unclosed');
        expect(config.server.port, 3333);
        expect(config.warnings, anyElement(contains('YAML parse error')));
      });

      test('~ expansion in data_dir', () {
        final config = loadYaml('data_dir: ~/my-data\n');
        expect(config.server.dataDir, '/home/user/my-data');
      });

      test('relative data_dir resolves absolute against config directory', () {
        final config = loadYaml('data_dir: .dartclaw-dev\n');

        expect(config.server.dataDir, '/home/user/.dartclaw/.dartclaw-dev');
        expect(p.isAbsolute(config.server.dataDir), isTrue);
      });

      test('relative data_dir remains absolute without home environment variables', () {
        final originalCwd = Directory.current;
        final cwd = Directory.systemTemp.createTempSync('dartclaw_config_no_home_');
        addTearDown(() {
          Directory.current = originalCwd;
          if (cwd.existsSync()) cwd.deleteSync(recursive: true);
        });

        Directory.current = cwd;
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (p.normalize(path) == p.normalize(p.join('.', '.dartclaw', 'dartclaw.yaml'))) {
              return 'data_dir: relative-data\n';
            }
            return null;
          },
          env: {},
        );

        expect(config.server.dataDir, p.normalize(p.absolute(p.join('.', '.dartclaw', 'relative-data'))));
        expect(p.isAbsolute(config.server.dataDir), isTrue);
      });

      test('example dev config resolves storage to the repository root default', () {
        final config = loadYaml('data_dir: ../.dartclaw-dev\n', configPath: '/repo/examples/dev.yaml');

        expect(config.server.dataDir, '/repo/.dartclaw-dev');
      });

      test('tilde expansion remains absolute', () {
        final config = loadYaml('data_dir: ~/my-data\n');

        expect(config.server.dataDir, '/home/user/my-data');
        expect(p.isAbsolute(config.server.dataDir), isTrue);
      });

      test('parsed data_dir stays stable across cwd changes', () {
        final originalCwd = Directory.current;
        final initialCwd = Directory.systemTemp.createTempSync('dartclaw_config_initial_');
        final laterCwd = Directory.systemTemp.createTempSync('dartclaw_config_later_');
        addTearDown(() {
          Directory.current = originalCwd;
          if (initialCwd.existsSync()) initialCwd.deleteSync(recursive: true);
          if (laterCwd.existsSync()) laterCwd.deleteSync(recursive: true);
        });

        Directory.current = initialCwd;
        final config = loadYaml('data_dir: relative-data\n');
        final parsedDataDir = config.server.dataDir;
        const expectedDataDir = '/home/user/.dartclaw/relative-data';

        Directory.current = laterCwd;
        expect(parsedDataDir, expectedDataDir);
      });

      test('explicit config path keeps relative data_dir stable across launch directories', () {
        final originalCwd = Directory.current;
        final firstCwd = Directory.systemTemp.createTempSync('dartclaw_config_first_');
        final secondCwd = Directory.systemTemp.createTempSync('dartclaw_config_second_');
        addTearDown(() {
          Directory.current = originalCwd;
          if (firstCwd.existsSync()) firstCwd.deleteSync(recursive: true);
          if (secondCwd.existsSync()) secondCwd.deleteSync(recursive: true);
        });

        String? reader(String path) => path == '/configs/dartclaw.yaml' ? 'data_dir: relative-data\n' : null;

        Directory.current = firstCwd;
        final firstConfig = DartclawConfig.load(
          configPath: '/configs/dartclaw.yaml',
          fileReader: reader,
          env: {'HOME': '/home/user'},
        );

        Directory.current = secondCwd;
        final secondConfig = DartclawConfig.load(
          configPath: '/configs/dartclaw.yaml',
          fileReader: reader,
          env: {'HOME': '/home/user'},
        );

        expect(firstConfig.server.dataDir, '/configs/relative-data');
        expect(secondConfig.server.dataDir, firstConfig.server.dataDir);
      });

      test('relative DARTCLAW_HOME remains launch-directory relative when data_dir is absent', () {
        final originalCwd = Directory.current;
        final cwd = Directory.systemTemp.createTempSync('dartclaw_config_home_');
        addTearDown(() {
          Directory.current = originalCwd;
          if (cwd.existsSync()) cwd.deleteSync(recursive: true);
        });

        Directory.current = cwd;
        final config = DartclawConfig.load(
          fileReader: (path) => path == p.join('instance', 'dartclaw.yaml') ? 'port: 4444\n' : null,
          env: {'HOME': '/home/user', 'DARTCLAW_HOME': 'instance'},
        );

        expect(config.server.dataDir, p.normalize(p.absolute('instance')));
      });

      test('~ expansion in logging.file', () {
        final config = loadYaml('logging:\n  file: ~/logs/dartclaw.log\n');
        expect(config.logging.file, '/home/user/logs/dartclaw.log');
      });

      test('~ expansion in CLI paths (claude_executable, static_dir, templates_dir)', () {
        final config = DartclawConfig.load(
          fileReader: (path) => null,
          cliOverrides: {
            'claude_executable': '~/bin/claude',
            'static_dir': '~/my-static',
            'templates_dir': '~/my-templates',
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.server.claudeExecutable, '/home/user/bin/claude');
        expect(config.server.staticDir, '/home/user/my-static');
        expect(config.server.templatesDir, '/home/user/my-templates');
      });

      test('~ expansion in provider executable', () {
        final config = loadYaml('providers:\n  my_agent:\n    executable: ~/bin/my-agent\n');
        final entry = config.providers.entries['my_agent'];
        expect(entry, isNotNull);
        expect(entry!.executable, '/home/user/bin/my-agent');
      });

      test('~ expansion in configPath', () {
        final config = DartclawConfig.load(
          configPath: '~/my-config.yaml',
          fileReader: (path) {
            if (path == '/home/user/my-config.yaml') return 'port: 9999\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.server.port, 9999);
      });

      test('~ expansion in DARTCLAW_CONFIG env var', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == '/home/user/custom.yaml') return 'port: 8888\n';
            return null;
          },
          env: {'HOME': '/home/user', 'DARTCLAW_CONFIG': '~/custom.yaml'},
        );
        expect(config.server.port, 8888);
      });

      test('YAML null value collects warning and uses default', () {
        final config = loadYaml('port: \n');
        expect(config.server.port, 3333);
        expect(config.warnings, anyElement(contains('null')));
      });

      test('non-map YAML root collects warning and uses defaults', () {
        final config = loadYaml('- item1\n- item2\n');
        expect(config.server.port, 3333);
        expect(config.warnings, anyElement(contains('not a map')));
      });

      test('DARTCLAW_CONFIG pointing to non-existent file collects warning and uses defaults', () {
        final config = DartclawConfig.load(
          fileReader: noFile,
          env: {'HOME': '/home/user', 'DARTCLAW_CONFIG': '/no/such/file.yaml'},
        );
        expect(config.server.port, 3333);
        expect(config.warnings, anyElement(contains('non-existent file')));
      });

      // --- DARTCLAW_HOME discovery (0.16.2) ---
      // DARTCLAW_HOME instance-root resolution and CWD-deprecation cases are
      // proven by config_discovery_unified_home_test.dart; only cases NOT
      // mirrored there are retained here.

      test('DARTCLAW_HOME with missing dartclaw.yaml collects warning and uses defaults', () {
        final config = DartclawConfig.load(
          fileReader: noFile,
          env: {'HOME': '/home/user', 'DARTCLAW_HOME': '/opt/badinstance'},
        );
        expect(config.server.port, 3333);
        expect(config.warnings, anyElement(contains('DARTCLAW_HOME')));
        expect(config.warnings, anyElement(contains('/opt/badinstance')));
      });

      test('DARTCLAW_CONFIG takes precedence over DARTCLAW_HOME', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == '/explicit/config.yaml') return 'port: 6100\n';
            if (path == '/opt/myinstance/dartclaw.yaml') return 'port: 6200\n';
            return null;
          },
          env: {'HOME': '/home/user', 'DARTCLAW_CONFIG': '/explicit/config.yaml', 'DARTCLAW_HOME': '/opt/myinstance'},
        );
        expect(config.server.port, 6100);
      });

      test('DARTCLAW_HOME falls back to default ~/.dartclaw when absent', () {
        final config = loadYaml('port: 6300\n');
        expect(config.server.port, 6300);
        expect(config.warnings, isEmpty);
      });

      test('configPath takes precedence over DARTCLAW_CONFIG env var', () {
        final config = DartclawConfig.load(
          configPath: '/explicit/config.yaml',
          fileReader: (path) {
            if (path == '/explicit/config.yaml') return 'port: 7777\n';
            if (path == '/env/config.yaml') return 'port: 8888\n';
            return null;
          },
          env: {'HOME': '/home/user', 'DARTCLAW_CONFIG': '/env/config.yaml'},
        );
        expect(config.server.port, 7777);
      });

      test('configPath pointing to non-existent file collects warning', () {
        final config = DartclawConfig.load(
          configPath: '/no/such/config.yaml',
          fileReader: noFile,
          env: {'HOME': '/home/user'},
        );
        expect(config.server.port, 3333);
        expect(config.warnings, anyElement(contains('--config points to non-existent file')));
      });

      test('configPath overrides CWD discovery', () {
        final config = DartclawConfig.load(
          configPath: '/custom/dartclaw.yaml',
          fileReader: (path) {
            if (path == '/custom/dartclaw.yaml') return 'port: 5555\n';
            if (path == 'dartclaw.yaml') return 'port: 6666\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.server.port, 5555);
      });

      test('claudeExecutable only from CLI, not YAML', () {
        final config = loadYaml('port: 5000\n', cli: const {'claude_executable': '/usr/local/bin/claude'});
        expect(config.server.claudeExecutable, '/usr/local/bin/claude');
        // staticDir uses default since no CLI or YAML override
        expect(config.server.staticDir, 'packages/dartclaw_server/lib/src/static');
      });

      test('staticDir and templatesDir from YAML', () {
        final config = loadYaml('static_dir: /opt/static\ntemplates_dir: /opt/templates\n');
        expect(config.server.staticDir, '/opt/static');
        expect(config.server.templatesDir, '/opt/templates');
      });

      test('source_dir resolves default static and templates paths', () {
        final config = DartclawConfig.load(
          cliOverrides: {'source_dir': '/opt/dartclaw'},
          fileReader: noFile,
          env: {'HOME': '/home/user'},
        );
        expect(config.server.staticDir, '/opt/dartclaw/packages/dartclaw_server/lib/src/static');
        expect(config.server.templatesDir, '/opt/dartclaw/packages/dartclaw_server/lib/src/templates');
      });

      test('source_dir from YAML resolves default paths', () {
        final config = loadYaml('source_dir: /opt/dartclaw\n');
        expect(config.server.staticDir, '/opt/dartclaw/packages/dartclaw_server/lib/src/static');
        expect(config.server.templatesDir, '/opt/dartclaw/packages/dartclaw_server/lib/src/templates');
      });

      test('explicit static_dir/templates_dir override source_dir', () {
        final config = DartclawConfig.load(
          cliOverrides: {'source_dir': '/opt/dartclaw', 'static_dir': '/my/static', 'templates_dir': '/my/templates'},
          fileReader: noFile,
          env: {'HOME': '/home/user'},
        );
        expect(config.server.staticDir, '/my/static');
        expect(config.server.templatesDir, '/my/templates');
      });

      test('default dataDir gets ~ expanded', () {
        final config = loadNoFile(env: const {'HOME': '/home/testuser'});
        expect(config.server.dataDir, '/home/testuser/.dartclaw');
      });

      test('existing config without providers or credentials loads successfully', () {
        final config = loadYaml('agent:\n  model: sonnet\n');

        expect(config.agent.model, 'sonnet');
        expect(config.agent.provider, 'claude');
        expect(config.providers, const ProvidersConfig.defaults());
        expect(config.providers.isEmpty, isTrue);
        expect(config.credentials, const CredentialsConfig.defaults());
        expect(config.credentials.isEmpty, isTrue);
        expect(config.warnings, isEmpty);
      });

      test('parses agent.provider from YAML', () {
        final config = loadYaml('agent:\n  provider: codex\n');
        expect(config.agent.provider, 'codex');
      });

      test('agent.model shorthand populates agent.provider and agent.model', () {
        final config = loadYaml('agent:\n  model: codex/gpt-5.4\n');
        expect(config.agent.provider, 'codex');
        expect(config.agent.model, 'gpt-5.4');
        expect(config.warnings, isEmpty);
      });

      test('invalid type for agent.provider produces warning and uses default', () {
        final config = loadYaml('agent:\n  provider: 42\n');
        expect(config.agent.provider, 'claude');
        expect(config.warnings, anyElement(contains('Invalid type for provider')));
      });
    });

    group('session scope config', () {
      test('default config has SessionScopeConfig.defaults()', () {
        final scope = loadNoFile().sessions.scopeConfig;
        expect(scope, const SessionScopeConfig.defaults());
        expect(scope.dmScope, DmScope.perChannelContact);
        expect(scope.groupScope, GroupScope.shared);
        expect(scope.channels, isEmpty);
      });

      final parseCases = [
        (
          name: 'sessions.dm_scope',
          yaml: 'sessions:\n  dm_scope: shared\n',
          assertConfig: (DartclawConfig config) => expect(config.sessions.scopeConfig.dmScope, DmScope.shared),
        ),
        (
          name: 'sessions.group_scope',
          yaml: 'sessions:\n  group_scope: per-member\n',
          assertConfig: (DartclawConfig config) => expect(config.sessions.scopeConfig.groupScope, GroupScope.perMember),
        ),
        (
          name: 'sessions.channels.signal.group_scope',
          yaml: 'sessions:\n  channels:\n    signal:\n      group_scope: per-member\n',
          assertConfig: (DartclawConfig config) {
            expect(config.sessions.scopeConfig.channels['signal']?.groupScope, GroupScope.perMember);
            expect(config.sessions.scopeConfig.channels['signal']?.dmScope, isNull);
          },
        ),
      ];

      for (final testCase in parseCases) {
        test('${testCase.name} parses without warnings', () {
          final config = loadYaml(testCase.yaml);
          testCase.assertConfig(config);
          expect(config.warnings, isEmpty);
        });
      }

      test('per-channel override merges dm_scope with channel group_scope', () {
        final config = loadYaml(
          'sessions:\n  dm_scope: per-contact\n  channels:\n    signal:\n      group_scope: per-member\n',
        );
        expect(config.sessions.scopeConfig.dmScope, DmScope.perContact);
        expect(config.sessions.scopeConfig.channels, hasLength(1));
        final signalScope = config.sessions.scopeConfig.forChannel('signal');
        expect(signalScope.groupScope, GroupScope.perMember);
        expect(signalScope.dmScope, DmScope.perContact);
        expect(config.warnings, isEmpty);
      });

      test('session model and effort parse globally and per channel', () {
        final config = loadYaml(
          'sessions:\n  model: sonnet\n  effort: medium\n  channels:\n    google_chat:\n      model: opus\n      effort: low\n',
        );
        expect(config.sessions.scopeConfig.model, 'sonnet');
        expect(config.sessions.scopeConfig.effort, 'medium');
        expect(config.sessions.scopeConfig.channels['google_chat']?.model, 'opus');
        expect(config.sessions.scopeConfig.channels['google_chat']?.effort, 'low');
      });

      final invalidScopeCases = [
        (
          name: 'invalid sessions.dm_scope',
          yaml: 'sessions:\n  dm_scope: invalid\n',
          warning: 'Invalid value for sessions.dm_scope',
        ),
        (
          name: 'invalid type for sessions.dm_scope',
          yaml: 'sessions:\n  dm_scope: 42\n',
          warning: 'Invalid type for dm_scope',
        ),
      ];

      for (final testCase in invalidScopeCases) {
        test('${testCase.name} warns and uses default', () {
          final config = loadYaml(testCase.yaml);
          expect(config.sessions.scopeConfig.dmScope, DmScope.perChannelContact);
          expect(config.warnings, anyElement(contains(testCase.warning)));
        });
      }

      test('unknown channel name in sessions.channels is parsed without error', () {
        final config = loadYaml('sessions:\n  channels:\n    unknown_channel:\n      dm_scope: shared\n');
        expect(config.sessions.scopeConfig.channels, hasLength(1));
        expect(config.sessions.scopeConfig.channels['unknown_channel']?.dmScope, DmScope.shared);
      });

      test('invalid type for sessions.model produces warning and uses default', () {
        final config = loadYaml('sessions:\n  model: 42\n');
        expect(config.sessions.scopeConfig.model, isNull);
        expect(config.warnings, anyElement(contains('Invalid type for model')));
      });

      test('invalid channel override value produces warning and omits the channel', () {
        final config = loadYaml('sessions:\n  channels:\n    signal:\n      dm_scope: bogus\n');
        // Invalid value ignored, channel not added (no valid overrides)
        expect(config.sessions.scopeConfig.channels, isEmpty);
        expect(config.warnings, anyElement(contains('Invalid value for sessions.channels.signal.dm_scope')));
      });
    });

    group('automation.scheduled_tasks deprecated alias', () {
      const legacyYaml = '''
automation:
  scheduled_tasks:
    - id: legacy-task-1
      schedule: "0 9 * * 1"
      task:
        title: Legacy Task
        description: A legacy task
        type: research
''';

      test('entries from automation.scheduled_tasks appear in automationScheduledTasks', () {
        final config = loadYaml(legacyYaml);
        expect(config.scheduling.taskDefinitions, hasLength(1));
        expect(config.scheduling.taskDefinitions.first.id, 'legacy-task-1');
        expect(config.scheduling.taskDefinitions.first.title, 'Legacy Task');
        expect(config.scheduling.taskDefinitions.first.type, TaskType.research);
      });

      test('deprecation warning generated for automation.scheduled_tasks', () {
        final config = loadYaml(legacyYaml);
        expect(config.warnings, anyElement(allOf(contains('automation.scheduled_tasks'), contains('deprecated'))));
      });

      test('coexistence: both scheduling.jobs[type:task] and automation.scheduled_tasks work', () {
        final config = loadYaml('''
scheduling:
  jobs:
    - id: modern-task-job
      prompt: unused
      type: task
      schedule: "0 10 * * *"
      task:
        title: Modern Task
        description: A modern task
        type: coding
automation:
  scheduled_tasks:
    - id: legacy-coexist
      schedule: "0 9 * * 1"
      task:
        title: Legacy Coexist
        description: A legacy task alongside modern
        type: research
''');
        expect(config.scheduling.taskDefinitions, hasLength(2));
        final ids = config.scheduling.taskDefinitions.map((d) => d.id).toSet();
        expect(ids, containsAll(['modern-task-job', 'legacy-coexist']));
      });

      test('legacy task.type field works (from automation.scheduled_tasks)', () {
        final config = loadYaml('''
automation:
  scheduled_tasks:
    - id: legacy-type-field
      schedule: "0 9 * * 1"
      task:
        title: Type Field Task
        description: Uses task.type not task_type
        type: analysis
''');
        expect(config.scheduling.taskDefinitions, hasLength(1));
        expect(config.scheduling.taskDefinitions.first.type, TaskType.analysis);
      });
    });

    group('features namespace', () {
      final cases = [
        (
          name: 'features.thread_binding.enabled',
          yaml: 'features:\n  thread_binding:\n    enabled: true\n',
          enabled: true,
          idleTimeoutMinutes: 60,
        ),
        (
          name: 'features.thread_binding.idle_timeout_minutes',
          yaml: 'features:\n  thread_binding:\n    enabled: true\n    idle_timeout_minutes: 30\n',
          enabled: true,
          idleTimeoutMinutes: 30,
        ),
        (name: 'missing features section', yaml: 'port: 3000\n', enabled: false, idleTimeoutMinutes: 60),
      ];

      for (final testCase in cases) {
        test('${testCase.name} parses', () {
          final config = loadYaml(testCase.yaml);
          expect(config.features.threadBinding.enabled, testCase.enabled);
          expect(config.features.threadBinding.idleTimeoutMinutes, testCase.idleTimeoutMinutes);
        });
      }

      test('old crowd_coding key produces unknown-key warning', () {
        final config = loadYaml('crowd_coding:\n  enabled: true\n');
        expect(config.features.threadBinding.enabled, isFalse);
        expect(config.warnings, contains(contains('Unknown config key: crowd_coding')));
      });

      test('old canvas key loads without throwing and produces unknown-key warning', () {
        final config = loadYaml('canvas:\n  enabled: true\n');
        expect(config.warnings, contains(contains('Unknown config key: canvas')));
      });
    });
  });
}
