import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:test/test.dart';

void main() {
  const serializer = ConfigSerializer();

  setUpAll(() {
    ensureDartclawGoogleChatRegistered();
    ensureDartclawSignalRegistered();
    ensureDartclawWhatsappRegistered();
  });

  group('ConfigSerializer.toJson', () {
    test('default config produces correct nested camelCase JSON', () {
      final config = const DartclawConfig.defaults();
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true, gitSyncPushEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);

      expect(json['port'], 3000);
      expect(json['host'], 'localhost');
      expect(json['dataDir'], '~/.dartclaw');
      expect(json['workerTimeout'], 600);
      expect(json['memoryMaxBytes'], 32 * 1024);

      final memory = json['memory'] as Map<String, dynamic>;
      expect(memory['maxBytes'], 32 * 1024);
      expect(memory['pruning'], {'enabled': true, 'archiveAfterDays': 90, 'schedule': '0 3 * * *'});

      // Nested sections
      final agent = json['agent'] as Map<String, dynamic>;
      expect(agent['model'], isNull);
      expect(agent['maxTurns'], isNull);
      expect(agent['effort'], isNull);

      final auth = json['auth'] as Map<String, dynamic>;
      expect(auth['cookieSecure'], false);
      expect(auth['trustedProxies'], isEmpty);

      final concurrency = json['concurrency'] as Map<String, dynamic>;
      expect(concurrency['maxParallelTurns'], 3);

      final guardAudit = json['guardAudit'] as Map<String, dynamic>;
      expect(guardAudit['maxRetentionDays'], 30);
      expect(guardAudit.containsKey('maxEntries'), isFalse);

      final tasks = json['tasks'] as Map<String, dynamic>;
      expect(tasks['maxConcurrent'], 3);
      expect(tasks['artifactRetentionDays'], 0);
      expect(tasks['worktree'], {'baseRef': 'main', 'staleTimeoutHours': 24, 'mergeStrategy': 'squash'});

      final sessions = json['sessions'] as Map<String, dynamic>;
      expect(sessions['resetHour'], 4);
      expect(sessions['idleTimeoutMinutes'], 0);

      final logging = json['logging'] as Map<String, dynamic>;
      expect(logging['level'], 'INFO');
      expect(logging['format'], 'human');
    });

    test('gateway.token masked as "***" when non-null', () {
      final config = const DartclawConfig(gateway: GatewayConfig(token: 'super-secret-token'));
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final gateway = json['gateway'] as Map<String, dynamic>;
      expect(gateway['token'], '***');
      expect(gateway['authMode'], 'token');
      expect(gateway['hsts'], false);
    });

    test('gateway.hsts is serialized', () {
      final config = const DartclawConfig(gateway: GatewayConfig(hsts: true));
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final gateway = json['gateway'] as Map<String, dynamic>;
      expect(gateway['hsts'], true);
    });

    test('auth cookie settings and retention config serialize custom values', () {
      final config = const DartclawConfig(
        auth: AuthConfig(cookieSecure: true, trustedProxies: ['192.168.1.100']),
        security: SecurityConfig(guardAuditMaxRetentionDays: 14),
        tasks: TaskConfig(
          maxConcurrent: 5,
          artifactRetentionDays: 90,
          worktreeBaseRef: 'develop',
          worktreeStaleTimeoutHours: 72,
          worktreeMergeStrategy: 'merge',
        ),
      );
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      expect((json['auth'] as Map<String, dynamic>)['cookieSecure'], true);
      expect((json['auth'] as Map<String, dynamic>)['trustedProxies'], ['192.168.1.100']);
      expect((json['guardAudit'] as Map<String, dynamic>)['maxRetentionDays'], 14);
      expect((json['guardAudit'] as Map<String, dynamic>).containsKey('maxEntries'), isFalse);
      expect((json['tasks'] as Map<String, dynamic>)['maxConcurrent'], 5);
      expect((json['tasks'] as Map<String, dynamic>)['artifactRetentionDays'], 90);
      expect((json['tasks'] as Map<String, dynamic>)['worktree'], {
        'baseRef': 'develop',
        'staleTimeoutHours': 72,
        'mergeStrategy': 'merge',
      });
    });

    test('gateway.token is null when config has null token', () {
      final config = const DartclawConfig.defaults();
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final gateway = json['gateway'] as Map<String, dynamic>;
      expect(gateway['token'], isNull);
    });

    test('live-mutable fields read from RuntimeConfig, not DartclawConfig', () {
      // Config says enabled, but runtime says disabled
      final config = const DartclawConfig(
        scheduling: SchedulingConfig(heartbeatEnabled: true),
        workspace: WorkspaceConfig(gitSyncEnabled: true, gitSyncPushEnabled: true),
      );
      final runtime = RuntimeConfig(heartbeatEnabled: false, gitSyncEnabled: false, gitSyncPushEnabled: false);

      final json = serializer.toJson(config, runtime: runtime);

      final heartbeat = (json['scheduling'] as Map)['heartbeat'] as Map;
      expect(heartbeat['enabled'], false);

      final gitSync = (json['workspace'] as Map)['gitSync'] as Map;
      expect(gitSync['enabled'], false);
      expect(gitSync['pushEnabled'], false);
    });

    test('default config serializes scope fields with defaults', () {
      final config = const DartclawConfig.defaults();
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true, gitSyncPushEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final sessions = json['sessions'] as Map<String, dynamic>;
      expect(sessions['dmScope'], 'per-channel-contact');
      expect(sessions['groupScope'], 'shared');
      expect(sessions['channels'], isEmpty);
    });

    test('config with channel overrides serializes correctly', () {
      final config = DartclawConfig(
        sessions: SessionConfig(
          scopeConfig: SessionScopeConfig(
            dmScope: DmScope.shared,
            groupScope: GroupScope.perMember,
            channels: {
              'signal': const ChannelScopeConfig(dmScope: DmScope.perChannelContact, groupScope: GroupScope.shared),
            },
          ),
        ),
      );
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true, gitSyncPushEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final sessions = json['sessions'] as Map<String, dynamic>;
      expect(sessions['dmScope'], 'shared');
      expect(sessions['groupScope'], 'per-member');
      final channels = sessions['channels'] as Map<String, dynamic>;
      expect(channels, hasLength(1));
      final signal = channels['signal'] as Map<String, dynamic>;
      expect(signal['dmScope'], 'per-channel-contact');
      expect(signal['groupScope'], 'shared');
    });

    test('channel override with only one field omits the other', () {
      final config = DartclawConfig(
        sessions: SessionConfig(
          scopeConfig: SessionScopeConfig(
            dmScope: DmScope.perContact,
            groupScope: GroupScope.shared,
            channels: {'whatsapp': const ChannelScopeConfig(groupScope: GroupScope.perMember)},
          ),
        ),
      );
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true, gitSyncPushEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final sessions = json['sessions'] as Map<String, dynamic>;
      final channels = sessions['channels'] as Map<String, dynamic>;
      final whatsapp = channels['whatsapp'] as Map<String, dynamic>;
      expect(whatsapp.containsKey('dmScope'), isFalse);
      expect(whatsapp['groupScope'], 'per-member');
    });

    test('default config serializes maintenance fields with defaults', () {
      final config = const DartclawConfig.defaults();
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true, gitSyncPushEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final sessions = json['sessions'] as Map<String, dynamic>;
      final maintenance = sessions['maintenance'] as Map<String, dynamic>;
      expect(maintenance['mode'], 'warn');
      expect(maintenance['pruneAfterDays'], 30);
      expect(maintenance['maxSessions'], 500);
      expect(maintenance['maxDiskMb'], 0);
      expect(maintenance['cronRetentionHours'], 24);
      expect(maintenance['schedule'], '0 3 * * *');
    });

    test('config with custom maintenance values serializes correctly', () {
      final config = DartclawConfig(
        sessions: SessionConfig(
          maintenanceConfig: const SessionMaintenanceConfig(
            mode: MaintenanceMode.enforce,
            pruneAfterDays: 7,
            maxSessions: 100,
            maxDiskMb: 512,
            cronRetentionHours: 48,
            schedule: '0 4 * * *',
          ),
        ),
      );
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true, gitSyncPushEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final sessions = json['sessions'] as Map<String, dynamic>;
      final maintenance = sessions['maintenance'] as Map<String, dynamic>;
      expect(maintenance['mode'], 'enforce');
      expect(maintenance['pruneAfterDays'], 7);
      expect(maintenance['maxSessions'], 100);
      expect(maintenance['maxDiskMb'], 512);
      expect(maintenance['cronRetentionHours'], 48);
      expect(maintenance['schedule'], '0 4 * * *');
    });

    test('default config serializes context fields with correct defaults', () {
      final config = const DartclawConfig.defaults();
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true, gitSyncPushEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final context = json['context'] as Map<String, dynamic>;
      expect(context['warningThreshold'], 80);
      expect(context['explorationSummaryThreshold'], 25000);
      expect(context['compactInstructions'], isNull);
    });

    test('custom context values serialize to camelCase JSON', () {
      final config = const DartclawConfig(
        context: ContextConfig(
          warningThreshold: 90,
          explorationSummaryThreshold: 50000,
          compactInstructions: 'Preserve all user preferences and task state.',
        ),
      );
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true, gitSyncPushEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final context = json['context'] as Map<String, dynamic>;
      expect(context['warningThreshold'], 90);
      expect(context['explorationSummaryThreshold'], 50000);
      expect(context['compactInstructions'], 'Preserve all user preferences and task state.');
    });

    test('scheduling.jobs included from config', () {
      final config = DartclawConfig(
        scheduling: SchedulingConfig(
          jobs: [
            {'name': 'test-job', 'schedule': '0 7 * * *', 'prompt': 'hello', 'delivery': 'announce'},
          ],
        ),
      );
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final scheduling = json['scheduling'] as Map<String, dynamic>;
      final jobs = scheduling['jobs'] as List;
      expect(jobs, hasLength(1));
      expect((jobs[0] as Map)['name'], 'test-job');
    });

    test('google chat config serializes with camelCase keys', () {
      final config = DartclawConfig(
        channels: ChannelConfig(
          channelConfigs: {
            'google_chat': _googleChatChannelConfig(
              const GoogleChatConfig(
                enabled: true,
                serviceAccount: '/tmp/google-service-account.json',
                oauthCredentials: '/tmp/google-oauth-client.json',
                audience: GoogleChatAudienceConfig(
                  mode: GoogleChatAudienceMode.appUrl,
                  value: 'https://example.com/integrations/googlechat',
                ),
                webhookPath: '/integrations/googlechat',
                botUser: 'users/123',
                typingIndicator: false,
                dmAccess: DmAccessMode.allowlist,
                dmAllowlist: ['spaces/AAA/users/1'],
                groupAccess: GroupAccessMode.open,
                groupAllowlist: ['spaces/AAA'],
                requireMention: false,
                taskTrigger: TaskTriggerConfig(
                  enabled: true,
                  prefix: 'do:',
                  defaultType: 'automation',
                  autoStart: false,
                ),
              ),
            ),
          },
        ),
      );
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true, gitSyncPushEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final channels = json['channels'] as Map<String, dynamic>;
      final googleChat = channels['googleChat'] as Map<String, dynamic>;

      expect(googleChat['enabled'], isTrue);
      expect(googleChat['serviceAccount'], '/tmp/google-service-account.json');
      expect(googleChat['oauthCredentials'], '/tmp/google-oauth-client.json');
      expect(googleChat['audience'], {'type': 'app-url', 'value': 'https://example.com/integrations/googlechat'});
      expect(googleChat['webhookPath'], '/integrations/googlechat');
      expect(googleChat['botUser'], 'users/123');
      expect(googleChat['typingIndicator'], isFalse);
      expect(googleChat['dmAccess'], 'allowlist');
      expect(googleChat['dmAllowlist'], ['spaces/AAA/users/1']);
      expect(googleChat['groupAccess'], 'open');
      expect(googleChat['groupAllowlist'], ['spaces/AAA']);
      expect(googleChat['requireMention'], isFalse);
      expect(googleChat['taskTrigger'], {
        'enabled': true,
        'prefix': 'do:',
        'defaultType': 'automation',
        'autoStart': false,
      });
    });

    test('google chat inline service account is redacted to client email', () {
      final config = DartclawConfig(
        channels: ChannelConfig(
          channelConfigs: {
            'google_chat': _googleChatChannelConfig(
              const GoogleChatConfig(
                enabled: true,
                serviceAccount:
                    '{"type":"service_account","client_email":"chat-bot@example.iam.gserviceaccount.com","private_key":"secret"}',
                audience: GoogleChatAudienceConfig(mode: GoogleChatAudienceMode.projectNumber, value: '123456789'),
              ),
            ),
          },
        ),
      );
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true, gitSyncPushEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final channels = json['channels'] as Map<String, dynamic>;
      final googleChat = channels['googleChat'] as Map<String, dynamic>;

      expect(googleChat['serviceAccount'], 'chat-bot@example.iam.gserviceaccount.com');
    });

    test('whatsapp config serializes from parsed typed config', () {
      final config = DartclawConfig(
        channels: const ChannelConfig(
          channelConfigs: {
            'whatsapp': {
              'enabled': 'yes',
              'dm_access': 'invalid',
              'group_access': 'invalid',
              'require_mention': 'invalid',
            },
          },
        ),
      );
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true, gitSyncPushEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final channels = json['channels'] as Map<String, dynamic>;
      final whatsapp = channels['whatsapp'] as Map<String, dynamic>;

      expect(whatsapp['enabled'], isFalse);
      expect(whatsapp['dmAccess'], 'pairing');
      expect(whatsapp['groupAccess'], 'disabled');
      expect(whatsapp['requireMention'], isTrue);
      expect(whatsapp['taskTrigger'], {
        'enabled': false,
        'prefix': 'task:',
        'defaultType': 'research',
        'autoStart': true,
      });
    });

    test('signal config serializes from parsed typed config', () {
      final config = DartclawConfig(
        channels: const ChannelConfig(
          channelConfigs: {
            'signal': {
              'enabled': 'yes',
              'dm_access': 'invalid',
              'group_access': 'invalid',
              'require_mention': 'invalid',
            },
          },
        ),
      );
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true, gitSyncPushEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final channels = json['channels'] as Map<String, dynamic>;
      final signal = channels['signal'] as Map<String, dynamic>;

      expect(signal['enabled'], isFalse);
      expect(signal['dmAccess'], 'allowlist');
      expect(signal['groupAccess'], 'disabled');
      expect(signal['requireMention'], isTrue);
      expect(signal['taskTrigger'], {
        'enabled': false,
        'prefix': 'task:',
        'defaultType': 'research',
        'autoStart': true,
      });
    });
  });

  group('ConfigSerializer.metaJson', () {
    test('contains all ConfigMeta entries', () {
      final meta = serializer.metaJson();
      expect(meta.length, ConfigMeta.fields.length);
      for (final path in ConfigMeta.fields.keys) {
        expect(meta.containsKey(path), isTrue, reason: 'Missing field: $path');
      }
    });

    test('int entries have min/max when defined', () {
      final meta = serializer.metaJson();
      final port = meta['port'] as Map<String, dynamic>;
      expect(port['type'], 'int');
      expect(port['mutable'], 'restart');
      expect(port['min'], 1);
      expect(port['max'], 65535);
    });

    test('new retention entries include integer constraints', () {
      final meta = serializer.metaJson();
      expect(meta.containsKey('guard_audit.max_entries'), isFalse);
      final guardAuditRetention = meta['guard_audit.max_retention_days'] as Map<String, dynamic>;
      expect(guardAuditRetention['type'], 'int');
      expect(guardAuditRetention['mutable'], 'restart');
      expect(guardAuditRetention['min'], 0);
      expect(guardAuditRetention['max'], 365);

      final taskArtifactsRetention = meta['tasks.artifact_retention_days'] as Map<String, dynamic>;
      expect(taskArtifactsRetention['type'], 'int');
      expect(taskArtifactsRetention['mutable'], 'restart');
      expect(taskArtifactsRetention['min'], 0);
      expect(taskArtifactsRetention['max'], 3650);
    });

    test('memory.max_bytes metadata is exposed; legacy root key is not present', () {
      final meta = serializer.metaJson();
      final nested = meta['memory.max_bytes'] as Map<String, dynamic>;
      expect(nested['type'], 'int');
      expect(nested['mutable'], 'restart');
      expect(nested['min'], 1);

      expect(meta.containsKey('memory_max_bytes'), isFalse);
    });

    test('enum entries have allowedValues', () {
      final meta = serializer.metaJson();
      final level = meta['logging.level'] as Map<String, dynamic>;
      expect(level['type'], 'enum');
      expect(level['allowedValues'], ['FINE', 'INFO', 'WARNING', 'SEVERE']);
    });

    test('live-mutable fields have mutable: "live"', () {
      final meta = serializer.metaJson();
      final hb = meta['scheduling.heartbeat.enabled'] as Map<String, dynamic>;
      expect(hb['mutable'], 'live');
      expect(hb['type'], 'bool');
    });

    test('nullable fields have nullable: true', () {
      final meta = serializer.metaJson();
      final model = meta['agent.model'] as Map<String, dynamic>;
      expect(model['nullable'], true);
    });

    test('non-nullable fields omit nullable key', () {
      final meta = serializer.metaJson();
      final port = meta['port'] as Map<String, dynamic>;
      expect(port.containsKey('nullable'), isFalse);
    });

    test('readonly fields have mutable: "readonly"', () {
      final meta = serializer.metaJson();
      final authMode = meta['gateway.auth_mode'] as Map<String, dynamic>;
      expect(authMode['mutable'], 'readonly');
    });
  });
}

Map<String, dynamic> _googleChatChannelConfig(GoogleChatConfig config) => {
  'enabled': config.enabled,
  if (config.serviceAccount != null) 'service_account': config.serviceAccount,
  if (config.oauthCredentials != null) 'oauth_credentials': config.oauthCredentials,
  if (config.audience != null)
    'audience': {
      'type': switch (config.audience!.mode) {
        GoogleChatAudienceMode.appUrl => 'app-url',
        GoogleChatAudienceMode.projectNumber => 'project-number',
      },
      'value': config.audience!.value,
    },
  'webhook_path': config.webhookPath,
  if (config.botUser != null) 'bot_user': config.botUser,
  'typing_indicator': config.typingIndicator,
  'dm_access': config.dmAccess.name,
  'dm_allowlist': config.dmAllowlist,
  'group_access': config.groupAccess.name,
  'group_allowlist': config.groupAllowlist,
  'require_mention': config.requireMention,
  'task_trigger': {
    'enabled': config.taskTrigger.enabled,
    'prefix': config.taskTrigger.prefix,
    'default_type': config.taskTrigger.defaultType,
    'auto_start': config.taskTrigger.autoStart,
  },
};
