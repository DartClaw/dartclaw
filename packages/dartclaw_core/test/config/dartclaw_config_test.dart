import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(ensureDartclawGoogleChatRegistered);

  group('DartclawConfig', () {
    group('defaults', () {
      test('all fields have expected default values', () {
        final config = const DartclawConfig.defaults();
        expect(config.port, 3000);
        expect(config.host, 'localhost');
        expect(config.dataDir, '~/.dartclaw');
        expect(config.workerTimeout, 600);
        expect(config.claudeExecutable, 'claude');
        expect(config.staticDir, 'packages/dartclaw_server/lib/src/static');
        expect(config.warnings, isEmpty);
      });
    });

    group('derived getters', () {
      test('sessionsDir joins dataDir with sessions', () {
        final config = DartclawConfig(dataDir: '/data');
        expect(config.sessionsDir, '/data/sessions');
      });

      test('searchDbPath joins dataDir with search.db', () {
        final config = DartclawConfig(dataDir: '/data');
        expect(config.searchDbPath, '/data/search.db');
      });

      test('tasksDbPath joins dataDir with tasks.db', () {
        final config = DartclawConfig(dataDir: '/data');
        expect(config.tasksDbPath, '/data/tasks.db');
      });

      test('kvPath joins dataDir with kv.json', () {
        final config = DartclawConfig(dataDir: '/data');
        expect(config.kvPath, '/data/kv.json');
      });

      test('workspaceDir joins dataDir with workspace', () {
        final config = DartclawConfig(dataDir: '/data');
        expect(config.workspaceDir, '/data/workspace');
      });

      test('logsDir joins dataDir with logs', () {
        final config = DartclawConfig(dataDir: '/data');
        expect(config.logsDir, '/data/logs');
      });
    });

    group('load', () {
      // No config file found -> defaults
      String? noFile(String path) => null;

      test('implements ChannelConfigProvider', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config, isA<ChannelConfigProvider>());
      });

      test('missing config file uses defaults', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.port, 3000);
        expect(config.host, 'localhost');
        expect(config.dataDir, '/home/user/.dartclaw');
        expect(config.workerTimeout, 600);
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
        expect(config.port, 8080);
        expect(config.host, '0.0.0.0');
        expect(config.dataDir, '/custom/data');
        expect(config.workerTimeout, 300);
        expect(config.gatewayHsts, isTrue);
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
        expect(config.gatewayHsts, isFalse);
      });

      test('auth.cookie_secure defaults to false when unset', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.cookieSecure, isFalse);
      });

      test('auth.trusted_proxies defaults to empty when unset', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.trustedProxies, isEmpty);
      });

      test('auth.cookie_secure parses when configured', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'auth:\n  cookie_secure: true\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.cookieSecure, isTrue);
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
        expect(config.trustedProxies, ['192.168.1.100', '192.168.1.101']);
      });

      test('auth.cookie_secure invalid type collects warning and uses default', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'auth:\n  cookie_secure: yes\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.cookieSecure, isFalse);
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
        expect(config.trustedProxies, isEmpty);
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
        expect(config.gatewayHsts, isFalse);
        expect(config.warnings, anyElement(contains('Invalid type for gateway.hsts')));
      });

      test('guard_audit.max_entries defaults to 10000 when unset', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.guardAuditMaxEntries, 10000);
      });

      test('guard_audit.max_retention_days defaults to 30 when unset', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.guardAuditMaxRetentionDays, 30);
      });

      test('guard_audit.max_entries is ignored with deprecation warning when configured', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'guard_audit:\n  max_entries: 25000\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.guardAuditMaxEntries, 10000);
        expect(
          config.warnings,
          anyElement(contains('guard_audit.max_entries is deprecated and ignored')),
        );
      });

      test('guard_audit.max_retention_days parses when configured', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'guard_audit:\n  max_retention_days: 7\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.guardAuditMaxRetentionDays, 7);
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

        expect(low.guardAuditMaxRetentionDays, 0);
        expect(high.guardAuditMaxRetentionDays, 365);
      });

      test('guard_audit.max_entries invalid type is ignored with deprecation warning', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'guard_audit:\n  max_entries: nope\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.guardAuditMaxEntries, 10000);
        expect(
          config.warnings,
          anyElement(contains('guard_audit.max_entries is deprecated and ignored')),
        );
      });

      test('tasks.artifact_retention_days defaults to 0 when unset', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.tasksArtifactRetentionDays, 0);
      });

      test('tasks.artifact_retention_days parses when configured', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'tasks:\n  artifact_retention_days: 90\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.tasksArtifactRetentionDays, 90);
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

        expect(low.tasksArtifactRetentionDays, 0);
        expect(high.tasksArtifactRetentionDays, 3650);
      });

      test('parses memory.max_bytes from nested config', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'memory:\n  max_bytes: 65536\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );

        expect(config.memoryMaxBytes, 65536);
      });

      test('falls back to top-level memory_max_bytes when memory.max_bytes is absent', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'memory_max_bytes: 65536\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );

        expect(config.memoryMaxBytes, 65536);
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

        expect(config.memoryMaxBytes, 262144);
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

        expect(config.memoryMaxBytes, 65536);
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

        expect(config.memoryPruningEnabled, isFalse);
        expect(config.memoryArchiveAfterDays, 7);
        expect(config.memoryPruningSchedule, '0 4 * * *');
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
        expect(config.port, 9090);
        // YAML wins for host (no CLI override)
        expect(config.host, '0.0.0.0');
        // Default for workerTimeout (neither CLI nor YAML)
        expect(config.workerTimeout, 600);
      });

      test('\${ENV_VAR} substitution in YAML string values', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'host: \${MY_HOST}\n';
            return null;
          },
          env: {'HOME': '/home/user', 'MY_HOST': 'custom.host'},
        );
        expect(config.host, 'custom.host');
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
        expect(config.port, 3000);
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
        expect(config.port, 4444);
      });

      test('YAML parse error collects warning and uses defaults', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return '{\n  invalid: [unclosed';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.port, 3000);
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
        expect(config.dataDir, '/home/user/my-data');
      });

      test('YAML null value collects warning and uses default', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'port: \n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.port, 3000);
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
        expect(config.port, 3000);
        expect(config.warnings, anyElement(contains('not a map')));
      });

      test('DARTCLAW_CONFIG pointing to non-existent file collects warning and uses defaults', () {
        final config = DartclawConfig.load(
          fileReader: noFile,
          env: {'HOME': '/home/user', 'DARTCLAW_CONFIG': '/no/such/file.yaml'},
        );
        expect(config.port, 3000);
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
        expect(config.port, 7777);
      });

      test('configPath pointing to non-existent file collects warning', () {
        final config = DartclawConfig.load(
          configPath: '/no/such/config.yaml',
          fileReader: noFile,
          env: {'HOME': '/home/user'},
        );
        expect(config.port, 3000);
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
        expect(config.port, 5555);
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
        expect(config.claudeExecutable, '/usr/local/bin/claude');
        // staticDir uses default since no CLI override
        expect(config.staticDir, 'packages/dartclaw_server/lib/src/static');
      });

      test('default dataDir gets ~ expanded', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/testuser'});
        expect(config.dataDir, '/home/testuser/.dartclaw');
      });
    });

    group('session scope config parsing', () {
      String? noFile(String path) => null;

      test('default config has SessionScopeConfig.defaults()', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.sessionScopeConfig.dmScope, DmScope.perContact);
        expect(config.sessionScopeConfig.groupScope, GroupScope.shared);
        expect(config.sessionScopeConfig.channels, isEmpty);
      });

      test('sessions.dm_scope: shared parses to DmScope.shared', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'sessions:\n  dm_scope: shared\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessionScopeConfig.dmScope, DmScope.shared);
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
        expect(config.sessionScopeConfig.groupScope, GroupScope.perMember);
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
        expect(config.sessionScopeConfig.channels['signal']?.groupScope, GroupScope.perMember);
        expect(config.sessionScopeConfig.channels['signal']?.dmScope, isNull);
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
        expect(config.sessionScopeConfig.dmScope, DmScope.perContact);
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
        expect(config.sessionScopeConfig.dmScope, DmScope.perContact);
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
        expect(config.sessionScopeConfig.channels['unknown_channel']?.dmScope, DmScope.shared);
      });
    });

    group('guards config', () {
      String? noFile(String path) => null;

      test('missing guards section uses GuardConfig.defaults()', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.guards.failOpen, isFalse);
        expect(config.guards.enabled, isTrue);
      });

      test('guards: {fail_open: true} parsed correctly', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'guards:\n  fail_open: true\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.guards.failOpen, isTrue);
        expect(config.guards.enabled, isTrue);
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
        expect(config.guards.enabled, isFalse);
      });

      test('guards: {unknown_key: x} produces warning, defaults used', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'guards:\n  unknown_key: x\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.guards.failOpen, isFalse);
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
        expect(config.guards.failOpen, isFalse);
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
        expect(config.searchProviders, isEmpty);
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
        expect(config.searchProviders, hasLength(1));
        expect(config.searchProviders['brave']!.enabled, isTrue);
        expect(config.searchProviders['brave']!.apiKey, 'my-key');
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
        expect(config.searchProviders, hasLength(2));
        expect(config.searchProviders['brave']!.enabled, isTrue);
        expect(config.searchProviders['tavily']!.enabled, isFalse);
        expect(config.searchProviders['tavily']!.apiKey, 'tavily-key');
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
        expect(config.searchProviders['brave']!.enabled, isFalse);
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
        expect(config.searchProviders, isEmpty);
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
        expect(config.searchProviders['brave']!.apiKey, 'resolved-key');
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
        expect(config.searchProviders, isEmpty);
        expect(config.warnings, anyElement(contains('Invalid type for search.providers')));
      });

      test('no search section returns empty providers', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.searchProviders, isEmpty);
      });
    });

    group('session scope config', () {
      String? noFile(String path) => null;

      test('default config has SessionScopeConfig.defaults()', () {
        final config = DartclawConfig.load(fileReader: noFile, env: {'HOME': '/home/user'});
        expect(config.sessionScopeConfig, const SessionScopeConfig.defaults());
        expect(config.sessionScopeConfig.dmScope, DmScope.perContact);
        expect(config.sessionScopeConfig.groupScope, GroupScope.shared);
      });

      test('sessions.dm_scope: shared parses to DmScope.shared', () {
        final config = DartclawConfig.load(
          fileReader: (path) {
            if (path == 'dartclaw.yaml') return 'sessions:\n  dm_scope: shared\n';
            return null;
          },
          env: {'HOME': '/home/user'},
        );
        expect(config.sessionScopeConfig.dmScope, DmScope.shared);
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
        expect(config.sessionScopeConfig.groupScope, GroupScope.perMember);
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
        expect(config.sessionScopeConfig.dmScope, DmScope.perContact);
        expect(config.sessionScopeConfig.channels, hasLength(1));
        final signalScope = config.sessionScopeConfig.forChannel('signal');
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
        expect(config.sessionScopeConfig.dmScope, DmScope.perContact);
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
        expect(config.sessionScopeConfig.dmScope, DmScope.perContact);
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
        expect(config.sessionScopeConfig.channels, hasLength(1));
        expect(config.sessionScopeConfig.channels['unknown']?.dmScope, DmScope.shared);
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
        expect(config.sessionScopeConfig.channels, isEmpty);
        expect(config.warnings, anyElement(contains('Invalid value for sessions.channels.signal.dm_scope')));
      });
    });

    group('session maintenance config parsing', () {
      test('default config has SessionMaintenanceConfig.defaults()', () {
        final config = const DartclawConfig.defaults();
        expect(config.sessionMaintenanceConfig, const SessionMaintenanceConfig.defaults());
        expect(config.sessionMaintenanceConfig.mode, MaintenanceMode.warn);
        expect(config.sessionMaintenanceConfig.pruneAfterDays, 30);
        expect(config.sessionMaintenanceConfig.maxSessions, 500);
        expect(config.sessionMaintenanceConfig.maxDiskMb, 0);
        expect(config.sessionMaintenanceConfig.cronRetentionHours, 24);
        expect(config.sessionMaintenanceConfig.schedule, '0 3 * * *');
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
        expect(config.sessionMaintenanceConfig.mode, MaintenanceMode.enforce);
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
        expect(config.sessionMaintenanceConfig.pruneAfterDays, 7);
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
        expect(config.sessionMaintenanceConfig.maxSessions, 100);
        expect(config.sessionMaintenanceConfig.maxDiskMb, 512);
        expect(config.sessionMaintenanceConfig.cronRetentionHours, 48);
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
        expect(config.sessionMaintenanceConfig.schedule, '0 4 * * *');
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
        expect(config.sessionMaintenanceConfig.mode, MaintenanceMode.warn);
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
        expect(config.sessionMaintenanceConfig.pruneAfterDays, 30);
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
        expect(config.sessionMaintenanceConfig, const SessionMaintenanceConfig.defaults());
        expect(config.warnings, anyElement(contains('Invalid type for sessions.maintenance')));
      });
    });
  });
}
