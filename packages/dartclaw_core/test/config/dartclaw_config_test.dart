import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(ensureDartclawGoogleChatRegistered);

  group('DartclawConfig', () {
    group('defaults', () {
      test('all fields have expected default values', () {
        final config = const DartclawConfig.defaults();
        expect(config.server.port, 3000);
        expect(config.server.host, 'localhost');
        expect(config.server.dataDir, '~/.dartclaw');
        expect(config.server.workerTimeout, 600);
        expect(config.server.claudeExecutable, 'claude');
        expect(config.server.staticDir, 'packages/dartclaw_server/lib/src/static');
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

    group('derived getters', () {
      test('sessionsDir joins dataDir with sessions', () {
        final config = DartclawConfig(server: ServerConfig(dataDir: '/data'));
        expect(config.sessionsDir, '/data/sessions');
      });

      test('searchDbPath joins dataDir with search.db', () {
        final config = DartclawConfig(server: ServerConfig(dataDir: '/data'));
        expect(config.searchDbPath, '/data/search.db');
      });

      test('tasksDbPath joins dataDir with tasks.db', () {
        final config = DartclawConfig(server: ServerConfig(dataDir: '/data'));
        expect(config.tasksDbPath, '/data/tasks.db');
      });

      test('kvPath joins dataDir with kv.json', () {
        final config = DartclawConfig(server: ServerConfig(dataDir: '/data'));
        expect(config.kvPath, '/data/kv.json');
      });

      test('workspaceDir joins dataDir with workspace', () {
        final config = DartclawConfig(server: ServerConfig(dataDir: '/data'));
        expect(config.workspaceDir, '/data/workspace');
      });

      test('logsDir joins dataDir with logs', () {
        final config = DartclawConfig(server: ServerConfig(dataDir: '/data'));
        expect(config.logsDir, '/data/logs');
      });
    });

    group('load', () {
      // No config file found -> defaults
      String? noFile(String path) => null;

      test('exposes ChannelConfigProvider via adapter', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config, isNot(isA<ChannelConfigProvider>()));
        expect(config.channelConfigProvider, isA<ChannelConfigProvider>());
      });

      test('missing config file uses defaults', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.server.port, 3000);
        expect(config.server.host, 'localhost');
        expect(config.server.dataDir, '/home/user/.dartclaw');
        expect(config.server.workerTimeout, 600);
        expect(config.warnings, isEmpty);
      });

      test('YAML parsing: flat keys parsed correctly', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'port: 8080\nhost: 0.0.0.0\ndata_dir: /custom/data\nworker_timeout: 300\ngateway:\n  hsts: true\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.server.port, 8080);
        expect(config.server.host, '0.0.0.0');
        expect(config.server.dataDir, '/custom/data');
        expect(config.server.workerTimeout, 300);
        expect(config.gateway.hsts, isTrue);
      });

      test('google chat parser works after explicit package registration', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        final googleChatConfig = config.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat);
        expect(googleChatConfig, isA<GoogleChatConfig>());
        expect(googleChatConfig.enabled, isFalse);
      });

      test('getChannelConfig rejects ChannelType.web', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(() => config.getChannelConfig<Object>(ChannelType.web), throwsArgumentError);
      });

      test('getChannelConfig rejects unregistered extracted channels before type checking', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(() => config.getChannelConfig<DartclawConfig>(ChannelType.signal), throwsStateError);
      });

      test('getChannelConfig keeps other extracted channels externally registered', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        final googleChatConfig = config.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat);
        expect(googleChatConfig, isA<GoogleChatConfig>());
        expect(() => config.getChannelConfig<Object>(ChannelType.whatsapp), throwsStateError);
        expect(() => config.getChannelConfig<Object>(ChannelType.signal), throwsStateError);
      });

      test('gateway.hsts defaults to false when unset', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.gateway.hsts, isFalse);
      });

      test('auth.cookie_secure defaults to false when unset', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.auth.cookieSecure, isFalse);
      });

      test('auth.trusted_proxies defaults to empty when unset', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.auth.trustedProxies, isEmpty);
      });

      test('auth.cookie_secure parses when configured', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'auth:\n  cookie_secure: true\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.auth.cookieSecure, isTrue);
      });

      test('auth.trusted_proxies parses when configured', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'auth:\n  trusted_proxies:\n    - 192.168.1.100\n    - 192.168.1.101\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.auth.trustedProxies, ['192.168.1.100', '192.168.1.101']);
      });

      test('auth.cookie_secure invalid type collects warning and uses default', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'auth:\n  cookie_secure: yes\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.auth.cookieSecure, isFalse);
        expect(config.warnings, anyElement(contains('Invalid type for auth.cookie_secure')));
      });

      test('auth.trusted_proxies invalid type collects warning and uses default', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'auth:\n  trusted_proxies: 192.168.1.100\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.auth.trustedProxies, isEmpty);
        expect(config.warnings, anyElement(contains('Invalid type for auth.trusted_proxies')));
      });

      test('gateway.hsts invalid type collects warning and uses default', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'gateway:\n  hsts: yes\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.gateway.hsts, isFalse);
        expect(config.warnings, anyElement(contains('Invalid type for gateway.hsts')));
      });

      test('guard_audit.max_retention_days defaults to 30 when unset', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.security.guardAuditMaxRetentionDays, 30);
      });

      test('guard_audit.max_entries is ignored with deprecation warning when configured', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'guard_audit:\n  max_entries: 25000\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.warnings, anyElement(contains('guard_audit.max_entries is deprecated and ignored')));
      });

      test('guard_audit.max_retention_days parses when configured', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'guard_audit:\n  max_retention_days: 7\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.security.guardAuditMaxRetentionDays, 7);
      });

      test('guard_audit.max_retention_days is clamped to 0..365', () {
        final low = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'guard_audit:\n  max_retention_days: -5\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        final high = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'guard_audit:\n  max_retention_days: 999\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );

        expect(low.security.guardAuditMaxRetentionDays, 0);
        expect(high.security.guardAuditMaxRetentionDays, 365);
      });

      test('guard_audit.max_entries invalid type is ignored with deprecation warning', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'guard_audit:\n  max_entries: nope\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.warnings, anyElement(contains('guard_audit.max_entries is deprecated and ignored')));
      });

      test('tasks.artifact_retention_days defaults to 0 when unset', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.tasks.artifactRetentionDays, 0);
      });

      test('tasks.artifact_retention_days parses when configured', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'tasks:\n  artifact_retention_days: 90\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.tasks.artifactRetentionDays, 90);
      });

      test('tasks.artifact_retention_days is clamped to 0..3650', () {
        final low = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'tasks:\n  artifact_retention_days: -30\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        final high = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'tasks:\n  artifact_retention_days: 5000\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );

        expect(low.tasks.artifactRetentionDays, 0);
        expect(high.tasks.artifactRetentionDays, 3650);
      });

      test('parses memory.max_bytes from nested config', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'memory:\n  max_bytes: 65536\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );

        expect(config.memory.maxBytes, 65536);
      });

      test('falls back to top-level memory_max_bytes when memory.max_bytes is absent', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'memory_max_bytes: 65536\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );

        expect(config.memory.maxBytes, 65536);
      });

      test('CLI memory_max_bytes takes precedence over nested and top-level config', () {
        final config = DartclawConfig.load(
          cliOverrides: {'memory_max_bytes': '262144'},
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'memory_max_bytes: 131072\nmemory:\n  max_bytes: 65536\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );

        expect(config.memory.maxBytes, 262144);
      });

      test('nested memory.max_bytes takes precedence over top-level memory_max_bytes', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'memory_max_bytes: 131072\nmemory:\n  max_bytes: 65536\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );

        expect(config.memory.maxBytes, 65536);
      });

      test('emits deprecation warning for top-level memory_max_bytes', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'memory_max_bytes: 65536\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );

        expect(
          config.warnings,
          anyElement(allOf(contains('memory_max_bytes'), contains('memory.max_bytes'), contains('deprecated'))),
        );
      });

      test('no deprecation warning when using nested memory.max_bytes', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'memory:\n  max_bytes: 65536\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );

        expect(config.warnings, isNot(anyElement(contains('deprecated'))));
      });

      test('memory.pruning CLI overrides take precedence over YAML', () {
        final config = DartclawConfig.load(
          cliOverrides: {
            'memory_pruning_enabled': 'false',
            'memory_pruning_archive_after_days': '7',
            'memory_pruning_schedule': '0 4 * * *',
          },
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'memory:\n  pruning:\n    enabled: true\n    archive_after_days: 90\n    schedule: "0 3 * * *"\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );

        expect(config.memory.pruningEnabled, isFalse);
        expect(config.memory.archiveAfterDays, 7);
        expect(config.memory.pruningSchedule, '0 4 * * *');
      });

      test('resolution order: CLI > YAML > defaults', () {
        final config = DartclawConfig.load(
          cliOverrides: {'port': '9090'},
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'port: 8080\nhost: 0.0.0.0\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        // CLI wins for port
        expect(config.server.port, 9090);
        // YAML wins for host (no CLI override)
        expect(config.server.host, '0.0.0.0');
        // Default for workerTimeout (neither CLI nor YAML)
        expect(config.server.workerTimeout, 600);
      });

      test('\${ENV_VAR} substitution in YAML string values', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'host: \${MY_HOST}\n';
            return null;
          },
          env: {'HOME': '/home/user', 'MY_HOST': 'custom.host'},
        );
        expect(config.server.host, 'custom.host');
      });

      test('unknown key collects warning', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'port: 3000\nbogus_key: 42\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.warnings, contains(contains('Unknown config key: bogus_key')));
      });

      test('type mismatch (port: "abc") collects warning and uses default', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'port: abc\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.server.port, 3000);
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
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return '{\n  invalid: [unclosed';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.server.port, 3000);
        expect(config.warnings, anyElement(contains('YAML parse error')));
      });

      test('~ expansion in data_dir', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'data_dir: ~/my-data\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.server.dataDir, '/home/user/my-data');
      });

      test('YAML null value collects warning and uses default', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'port: \n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.server.port, 3000);
        expect(config.warnings, anyElement(contains('null')));
      });

      test('non-map YAML root collects warning and uses defaults', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return '- item1\n- item2\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.server.port, 3000);
        expect(config.warnings, anyElement(contains('not a map')));
      });

      test('DARTCLAW_CONFIG pointing to non-existent file collects warning and uses defaults', () {
        final config = DartclawConfig.load(
          fileReader: noFile,
          env: {'HOME': '/home/user', 'DARTCLAW_CONFIG': '/no/such/file.yaml'},
        );
        expect(config.server.port, 3000);
        expect(config.warnings, anyElement(contains('non-existent file')));
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
        expect(config.server.port, 3000);
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

      test('claudeExecutable and staticDir only from CLI, not YAML', () {
        final config = DartclawConfig.load(
          cliOverrides: {'claude_executable': '/usr/local/bin/claude'},
          fileReader: (path) {
            // Even if YAML had these keys they'd be unknown
            if (path == 'dartclaw.yaml') return 'port: 5000\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.server.claudeExecutable, '/usr/local/bin/claude');
        // staticDir uses default since no CLI override
        expect(config.server.staticDir, 'packages/dartclaw_server/lib/src/static');
      });

      test('default dataDir gets ~ expanded', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/testuser'});
        expect(config.server.dataDir, '/home/testuser/.dartclaw');
      });

      test('existing config without providers or credentials loads successfully', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'agent:\n  model: sonnet\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );

        expect(config.agent.model, 'sonnet');
        expect(config.agent.provider, 'claude');
        expect(config.providers, const ProvidersConfig.defaults());
        expect(config.providers.isEmpty, isTrue);
        expect(config.credentials, const CredentialsConfig.defaults());
        expect(config.credentials.isEmpty, isTrue);
        expect(config.warnings, isEmpty);
      });

      test('parses agent.provider from YAML', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'agent:\n  provider: codex\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );

        expect(config.agent.provider, 'codex');
      });

      test('invalid type for agent.provider produces warning and uses default', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'agent:\n  provider: 42\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );

        expect(config.agent.provider, 'claude');
        expect(config.warnings, anyElement(contains('Invalid type for agent.provider')));
      });
    });

    group('session scope config parsing', () {
      String? noFile(String path) => null;

      test('default config has SessionScopeConfig.defaults()', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.sessions.scopeConfig.dmScope, DmScope.perChannelContact);
        expect(config.sessions.scopeConfig.groupScope, GroupScope.shared);
        expect(config.sessions.scopeConfig.channels, isEmpty);
      });

      test('sessions.dm_scope: shared parses to DmScope.shared', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'sessions:\n  dm_scope: shared\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessions.scopeConfig.dmScope, DmScope.shared);
      });

      test('sessions.group_scope: per-member parses to GroupScope.perMember', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'sessions:\n  group_scope: per-member\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessions.scopeConfig.groupScope, GroupScope.perMember);
      });

      test('sessions.channels.signal.group_scope parses channel override', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'sessions:\n  channels:\n    signal:\n      group_scope: per-member\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessions.scopeConfig.channels['signal']?.groupScope, GroupScope.perMember);
        expect(config.sessions.scopeConfig.channels['signal']?.dmScope, isNull);
      });

      test('invalid sessions.dm_scope produces warning and uses default', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'sessions:\n  dm_scope: invalid\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessions.scopeConfig.dmScope, DmScope.perChannelContact);
        expect(config.warnings, anyElement(contains('Invalid value for sessions.dm_scope')));
      });

      test('invalid type for sessions.dm_scope produces warning and uses default', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'sessions:\n  dm_scope: 42\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessions.scopeConfig.dmScope, DmScope.perChannelContact);
        expect(config.warnings, anyElement(contains('Invalid type for sessions.dm_scope')));
      });

      test('unknown channel name in sessions.channels is parsed without error', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'sessions:\n  channels:\n    unknown_channel:\n      dm_scope: shared\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessions.scopeConfig.channels['unknown_channel']?.dmScope, DmScope.shared);
      });
    });

    group('guards config', () {
      String? noFile(String path) => null;

      test('missing guards section uses GuardConfig.defaults()', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.security.guards.failOpen, isFalse);
        expect(config.security.guards.enabled, isTrue);
      });

      test('guards: {fail_open: true} parsed correctly', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'guards:\n  fail_open: true\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.security.guards.failOpen, isTrue);
        expect(config.security.guards.enabled, isTrue);
        expect(config.warnings, isEmpty);
      });

      test('guards: {enabled: false} parsed correctly', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'guards:\n  enabled: false\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.security.guards.enabled, isFalse);
      });

      test('guards: {unknown_key: x} produces warning, defaults used', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'guards:\n  unknown_key: x\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.security.guards.failOpen, isFalse);
        expect(config.warnings, anyElement(contains('Unknown guards config key')));
      });

      test('guards: non-map type produces warning, defaults used', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'guards: true\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.security.guards.failOpen, isFalse);
        expect(config.warnings, anyElement(contains('Invalid type for guards')));
      });
    });

    group('search.providers config', () {
      String? noFile(String path) => null;

      test('no providers section returns empty map', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'search:\n  backend: fts5\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.search.providers, isEmpty);
        expect(config.warnings, isEmpty);
      });

      test('single provider enabled with API key parsed correctly', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'search:\n  providers:\n    brave:\n      enabled: true\n      api_key: my-key\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.search.providers, hasLength(1));
        expect(config.search.providers['brave']!.enabled, isTrue);
        expect(config.search.providers['brave']!.apiKey, 'my-key');
      });

      test('multiple providers parsed', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'search:\n  providers:\n    brave:\n      enabled: true\n      api_key: brave-key\n    tavily:\n      enabled: false\n      api_key: tavily-key\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.search.providers, hasLength(2));
        expect(config.search.providers['brave']!.enabled, isTrue);
        expect(config.search.providers['tavily']!.enabled, isFalse);
        expect(config.search.providers['tavily']!.apiKey, 'tavily-key');
      });

      test('provider with enabled: false parsed with enabled=false', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'search:\n  providers:\n    brave:\n      enabled: false\n      api_key: key\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.search.providers['brave']!.enabled, isFalse);
      });

      test('provider missing api_key skipped with warning', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'search:\n  providers:\n    brave:\n      enabled: true\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.search.providers, isEmpty);
        expect(config.warnings, anyElement(contains('missing "api_key"')));
      });

      test('provider with env var api_key substituted', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'search:\n  providers:\n    brave:\n      enabled: true\n      api_key: \${BRAVE_API_KEY}\n';
            }
            return null;
          },
          env: {'HOME': '/home/user', 'BRAVE_API_KEY': 'resolved-key'},
        );
        expect(config.search.providers['brave']!.apiKey, 'resolved-key');
      });

      test('invalid providers type produces warning', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'search:\n  providers: not-a-map\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.search.providers, isEmpty);
        expect(config.warnings, anyElement(contains('Invalid type for search.providers')));
      });

      test('no search section returns empty providers', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.search.providers, isEmpty);
      });
    });

    group('session scope config', () {
      String? noFile(String path) => null;

      test('default config has SessionScopeConfig.defaults()', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.sessions.scopeConfig, const SessionScopeConfig.defaults());
        expect(config.sessions.scopeConfig.dmScope, DmScope.perChannelContact);
        expect(config.sessions.scopeConfig.groupScope, GroupScope.shared);
      });

      test('sessions.dm_scope: shared parses to DmScope.shared', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'sessions:\n  dm_scope: shared\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessions.scopeConfig.dmScope, DmScope.shared);
        expect(config.warnings, isEmpty);
      });

      test('sessions.group_scope: per-member parses to GroupScope.perMember', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'sessions:\n  group_scope: per-member\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessions.scopeConfig.groupScope, GroupScope.perMember);
        expect(config.warnings, isEmpty);
      });

      test('per-channel override parsed correctly', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'sessions:\n  dm_scope: per-contact\n  channels:\n    signal:\n      group_scope: per-member\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessions.scopeConfig.dmScope, DmScope.perContact);
        expect(config.sessions.scopeConfig.channels, hasLength(1));
        final signalScope = config.sessions.scopeConfig.forChannel('signal');
        expect(signalScope.groupScope, GroupScope.perMember);
        expect(signalScope.dmScope, DmScope.perContact);
        expect(config.warnings, isEmpty);
      });

      test('invalid dm_scope value produces warning, uses default', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'sessions:\n  dm_scope: invalid\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessions.scopeConfig.dmScope, DmScope.perChannelContact);
        expect(config.warnings, anyElement(contains('Invalid value for sessions.dm_scope')));
      });

      test('invalid type for dm_scope produces warning, uses default', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'sessions:\n  dm_scope: 42\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessions.scopeConfig.dmScope, DmScope.perChannelContact);
        expect(config.warnings, anyElement(contains('Invalid type for sessions.dm_scope')));
      });

      test('unknown channel name in overrides produces warning', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'sessions:\n  channels:\n    unknown:\n      dm_scope: shared\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        // Still parses the override — unknown channel names are not rejected
        expect(config.sessions.scopeConfig.channels, hasLength(1));
        expect(config.sessions.scopeConfig.channels['unknown']?.dmScope, DmScope.shared);
      });

      test('invalid channel override value produces warning', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'sessions:\n  channels:\n    signal:\n      dm_scope: bogus\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        // Invalid value ignored, channel not added (no valid overrides)
        expect(config.sessions.scopeConfig.channels, isEmpty);
        expect(config.warnings, anyElement(contains('Invalid value for sessions.channels.signal.dm_scope')));
      });
    });

    group('automation.scheduled_tasks deprecated alias', () {
      test('entries from automation.scheduled_tasks appear in automationScheduledTasks', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return '''
automation:
  scheduled_tasks:
    - id: legacy-task-1
      schedule: "0 9 * * 1"
      task:
        title: Legacy Task
        description: A legacy task
        type: research
''';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.scheduling.taskDefinitions, hasLength(1));
        expect(config.scheduling.taskDefinitions.first.id, 'legacy-task-1');
        expect(config.scheduling.taskDefinitions.first.title, 'Legacy Task');
        expect(config.scheduling.taskDefinitions.first.type, TaskType.research);
      });

      test('deprecation warning generated for automation.scheduled_tasks', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return '''
automation:
  scheduled_tasks:
    - id: legacy-warn
      schedule: "0 9 * * 1"
      task:
        title: Warn Task
        description: Triggers a warning
        type: analysis
''';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.warnings, anyElement(allOf(contains('automation.scheduled_tasks'), contains('deprecated'))));
      });

      test('coexistence: both scheduling.jobs[type:task] and automation.scheduled_tasks work', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return '''
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
''';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.scheduling.taskDefinitions, hasLength(2));
        final ids = config.scheduling.taskDefinitions.map((d) => d.id).toSet();
        expect(ids, containsAll(['modern-task-job', 'legacy-coexist']));
      });

      test('legacy task.type field works (from automation.scheduled_tasks)', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return '''
automation:
  scheduled_tasks:
    - id: legacy-type-field
      schedule: "0 9 * * 1"
      task:
        title: Type Field Task
        description: Uses task.type not task_type
        type: analysis
''';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.scheduling.taskDefinitions, hasLength(1));
        expect(config.scheduling.taskDefinitions.first.type, TaskType.analysis);
      });
    });

    group('session maintenance config parsing', () {
      test('default config has SessionMaintenanceConfig.defaults()', () {
        final config = const DartclawConfig.defaults();
        expect(config.sessions.maintenanceConfig, const SessionMaintenanceConfig.defaults());
        expect(config.sessions.maintenanceConfig.mode, MaintenanceMode.warn);
        expect(config.sessions.maintenanceConfig.pruneAfterDays, 30);
        expect(config.sessions.maintenanceConfig.maxSessions, 500);
        expect(config.sessions.maintenanceConfig.maxDiskMb, 0);
        expect(config.sessions.maintenanceConfig.cronRetentionHours, 24);
        expect(config.sessions.maintenanceConfig.schedule, '0 3 * * *');
      });

      test('sessions.maintenance.mode: enforce parses correctly', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'sessions:\n  maintenance:\n    mode: enforce\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessions.maintenanceConfig.mode, MaintenanceMode.enforce);
      });

      test('sessions.maintenance.prune_after_days: 7 parses correctly', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'sessions:\n  maintenance:\n    prune_after_days: 7\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessions.maintenanceConfig.pruneAfterDays, 7);
      });

      test('all maintenance int fields parse correctly', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'sessions:\n  maintenance:\n    max_sessions: 100\n    max_disk_mb: 512\n    cron_retention_hours: 48\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessions.maintenanceConfig.maxSessions, 100);
        expect(config.sessions.maintenanceConfig.maxDiskMb, 512);
        expect(config.sessions.maintenanceConfig.cronRetentionHours, 48);
      });

      test('sessions.maintenance.schedule parses correctly', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'sessions:\n  maintenance:\n    schedule: "0 4 * * *"\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessions.maintenanceConfig.schedule, '0 4 * * *');
      });

      test('invalid sessions.maintenance.mode warns and uses default', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'sessions:\n  maintenance:\n    mode: invalid\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessions.maintenanceConfig.mode, MaintenanceMode.warn);
        expect(config.warnings, anyElement(contains('Invalid value for sessions.maintenance.mode')));
      });

      test('invalid type for maintenance int field warns and uses default', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'sessions:\n  maintenance:\n    prune_after_days: abc\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessions.maintenanceConfig.pruneAfterDays, 30);
        expect(config.warnings, anyElement(contains('Invalid type for sessions.maintenance.prune_after_days')));
      });

      test('invalid type for sessions.maintenance warns and uses defaults', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'sessions:\n  maintenance: true\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessions.maintenanceConfig, const SessionMaintenanceConfig.defaults());
        expect(config.warnings, anyElement(contains('Invalid type for sessions.maintenance')));
      });
    });

    // -------------------------------------------------------------------------
    // Extension registration (S05 / P7)
    // -------------------------------------------------------------------------

    group('extension registration', () {
      setUp(DartclawConfig.clearExtensionParsers);
      tearDown(DartclawConfig.clearExtensionParsers);

      // TC-E01: registered parser is called and result is accessible
      test('registered parser is invoked and result accessible via extension<T>()', () {
        DartclawConfig.registerExtensionParser(
          'slack',
          (yaml, warns) => _SlackConfig(webhook: yaml['webhook'] as String? ?? ''),
        );
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'slack:\n  webhook: https://hooks.example.com/abc\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.warnings, isEmpty);
        final slack = config.extension<_SlackConfig>('slack');
        expect(slack.webhook, 'https://hooks.example.com/abc');
      });

      // TC-E02: unknown key without parser produces warning and stores raw map
      test('unknown key without parser produces warning and stores raw map', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'my_custom_section:\n  foo: bar\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.warnings, anyElement(contains('Unknown config key: my_custom_section')));
        final raw = config.extensions['my_custom_section'];
        expect(raw, isA<Map<String, dynamic>>());
        expect((raw as Map<String, dynamic>)['foo'], 'bar');
      });

      // TC-E03: extension<T>() throws StateError for missing key
      test('extension<T>() throws StateError when key not present', () {
        final config = const DartclawConfig.defaults();
        expect(() => config.extension<_SlackConfig>('slack'), throwsStateError);
      });

      // TC-E04: extension<T>() throws ArgumentError for wrong type
      test('extension<T>() throws ArgumentError for type mismatch', () {
        final config = DartclawConfig(extensions: {'slack': _SlackConfig(webhook: 'x')});
        expect(() => config.extension<String>('slack'), throwsArgumentError);
      });

      // TC-E05: registerExtensionParser throws for built-in key
      test('registerExtensionParser throws ArgumentError for built-in key', () {
        expect(() => DartclawConfig.registerExtensionParser('agent', (a, b) => {}), throwsArgumentError);
      });

      // TC-E06: parser throwing stores raw map and adds warning
      test('parser exception falls back to raw map and warns', () {
        DartclawConfig.registerExtensionParser('bad_ext', (yaml, warns) {
          throw Exception('parse failed');
        });
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'bad_ext:\n  x: 1\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.warnings, anyElement(contains('Error parsing extension "bad_ext"')));
        final raw = config.extensions['bad_ext'];
        expect(raw, isA<Map<String, dynamic>>());
      });

      // TC-E07: empty YAML section produces empty map for registered parser
      test('empty YAML section passes empty map to parser', () {
        final captured = <String, dynamic>{};
        DartclawConfig.registerExtensionParser('empty_ext', (yaml, warns) {
          captured.addAll(yaml);
          return _SlackConfig(webhook: '');
        });
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'empty_ext:\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.warnings, isEmpty);
        expect(captured, isEmpty);
        expect(config.extension<_SlackConfig>('empty_ext').webhook, '');
      });

      // TC-E08: multiple extensions are all parsed independently
      test('multiple extensions are all parsed and retrievable', () {
        DartclawConfig.registerExtensionParser(
          'ext_a',
          (yaml, warns) => _SlackConfig(webhook: yaml['url'] as String? ?? ''),
        );
        DartclawConfig.registerExtensionParser(
          'ext_b',
          (yaml, warns) => _SlackConfig(webhook: yaml['endpoint'] as String? ?? ''),
        );
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'ext_a:\n  url: http://a\next_b:\n  endpoint: http://b\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.extension<_SlackConfig>('ext_a').webhook, 'http://a');
        expect(config.extension<_SlackConfig>('ext_b').webhook, 'http://b');
      });

      // TC-E10: scalar extension value preserved losslessly (no coercion to {})
      test('scalar extension value is preserved losslessly', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'feature_flag: true\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.extensions['feature_flag'], isTrue);
        expect(config.warnings, anyElement(contains('Unknown config key: feature_flag')));
      });

      // TC-E11: list extension value preserved losslessly
      test('list extension value is preserved losslessly', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'custom_list:\n  - alpha\n  - beta\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        final raw = config.extensions['custom_list'];
        expect(raw, isA<List<dynamic>>());
        expect(raw as List<dynamic>, ['alpha', 'beta']);
      });

      // TC-E12: null extension value preserved losslessly
      test('null extension value is preserved losslessly', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'placeholder_section:\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.extensions.containsKey('placeholder_section'), isTrue);
        expect(config.extensions['placeholder_section'], isNull);
      });

      // TC-E13: registered parser with non-map value warns and stores raw
      test('registered parser with non-map value warns and preserves raw', () {
        DartclawConfig.registerExtensionParser('flag_ext', (yaml, warns) => _SlackConfig(webhook: 'parsed'));
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'flag_ext: 42\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.warnings, anyElement(contains('Extension "flag_ext" expected a map')));
        // Raw scalar preserved, parser was NOT invoked
        expect(config.extensions['flag_ext'], 42);
      });

      // TC-E14: extension<T>() works with null values (distinguishes missing vs null)
      test('extension<T>() distinguishes missing key from null value', () {
        final config = DartclawConfig(extensions: {'present_null': null});
        // Missing key → StateError
        expect(() => config.extension<Object?>('absent'), throwsStateError);
        // Present null key → returns null (not StateError)
        expect(config.extension<Object?>('present_null'), isNull);
      });

      // TC-E09: clearExtensionParsers resets registry so subsequent load ignores parser
      test('clearExtensionParsers removes all registered parsers', () {
        DartclawConfig.registerExtensionParser('gone', (yaml, warns) => _SlackConfig(webhook: 'x'));
        DartclawConfig.clearExtensionParsers();
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'gone:\n  x: 1\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        // With no parser, the unknown key should warn and be stored as raw map
        expect(config.warnings, anyElement(contains('Unknown config key: gone')));
        expect(config.extensions['gone'], isA<Map<String, dynamic>>());
      });
    });

    group('features namespace', () {
      test('features.thread_binding.enabled parsed correctly', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'features:\n  thread_binding:\n    enabled: true\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.features.threadBinding.enabled, isTrue);
        expect(config.warnings, isEmpty);
      });

      test('features.thread_binding.idle_timeout_minutes parsed correctly', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'features:\n  thread_binding:\n    enabled: true\n    idle_timeout_minutes: 30\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.features.threadBinding.idleTimeoutMinutes, 30);
      });

      test('missing features section defaults to disabled', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'port: 3000\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.features.threadBinding.enabled, isFalse);
        expect(config.features.threadBinding.idleTimeoutMinutes, 60);
      });

      test('old crowd_coding key produces unknown-key warning', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') {
              return 'crowd_coding:\n  enabled: true\n';
            }
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.features.threadBinding.enabled, isFalse);
        expect(config.warnings, contains(contains('Unknown config key: crowd_coding')));
      });
    });
  });
}

// ---------------------------------------------------------------------------
// Test helper types
// ---------------------------------------------------------------------------

class _SlackConfig {
  final String webhook;
  const _SlackConfig({required this.webhook});
}
