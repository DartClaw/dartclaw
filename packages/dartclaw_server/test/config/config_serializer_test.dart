import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  const serializer = ConfigSerializer();

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

      // Nested sections
      final agent = json['agent'] as Map<String, dynamic>;
      expect(agent['model'], isNull);
      expect(agent['maxTurns'], isNull);
      expect(agent['context1m'], false);

      final auth = json['auth'] as Map<String, dynamic>;
      expect(auth['cookieSecure'], false);
      expect(auth['trustedProxies'], isEmpty);

      final concurrency = json['concurrency'] as Map<String, dynamic>;
      expect(concurrency['maxParallelTurns'], 3);

      final guardAudit = json['guardAudit'] as Map<String, dynamic>;
      expect(guardAudit['maxEntries'], 10000);

      final sessions = json['sessions'] as Map<String, dynamic>;
      expect(sessions['resetHour'], 4);
      expect(sessions['idleTimeoutMinutes'], 0);

      final logging = json['logging'] as Map<String, dynamic>;
      expect(logging['level'], 'INFO');
      expect(logging['format'], 'human');
    });

    test('gateway.token masked as "***" when non-null', () {
      final config = const DartclawConfig(gatewayToken: 'super-secret-token');
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final gateway = json['gateway'] as Map<String, dynamic>;
      expect(gateway['token'], '***');
      expect(gateway['authMode'], 'token');
      expect(gateway['hsts'], false);
    });

    test('gateway.hsts is serialized', () {
      final config = const DartclawConfig(gatewayHsts: true);
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final gateway = json['gateway'] as Map<String, dynamic>;
      expect(gateway['hsts'], true);
    });

    test('auth cookie settings and guardAudit.maxEntries serialize custom values', () {
      final config = const DartclawConfig(
        cookieSecure: true,
        trustedProxies: ['192.168.1.100'],
        guardAuditMaxEntries: 25000,
      );
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      expect((json['auth'] as Map<String, dynamic>)['cookieSecure'], true);
      expect((json['auth'] as Map<String, dynamic>)['trustedProxies'], ['192.168.1.100']);
      expect((json['guardAudit'] as Map<String, dynamic>)['maxEntries'], 25000);
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
      final config = const DartclawConfig(heartbeatEnabled: true, gitSyncEnabled: true, gitSyncPushEnabled: true);
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
      expect(sessions['dmScope'], 'per-contact');
      expect(sessions['groupScope'], 'shared');
      expect(sessions['channels'], isEmpty);
    });

    test('config with channel overrides serializes correctly', () {
      final config = DartclawConfig(
        sessionScopeConfig: SessionScopeConfig(
          dmScope: DmScope.shared,
          groupScope: GroupScope.perMember,
          channels: {
            'signal': const ChannelScopeConfig(dmScope: DmScope.perChannelContact, groupScope: GroupScope.shared),
          },
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
        sessionScopeConfig: SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
          channels: {'whatsapp': const ChannelScopeConfig(groupScope: GroupScope.perMember)},
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
        sessionMaintenanceConfig: const SessionMaintenanceConfig(
          mode: MaintenanceMode.enforce,
          pruneAfterDays: 7,
          maxSessions: 100,
          maxDiskMb: 512,
          cronRetentionHours: 48,
          schedule: '0 4 * * *',
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

    test('scheduling.jobs included from config', () {
      final config = DartclawConfig(
        schedulingJobs: [
          {'name': 'test-job', 'schedule': '0 7 * * *', 'prompt': 'hello', 'delivery': 'announce'},
        ],
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
        googleChatConfig: const GoogleChatConfig(
          enabled: true,
          serviceAccount: '/tmp/google-service-account.json',
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
        ),
      );
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true, gitSyncPushEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final channels = json['channels'] as Map<String, dynamic>;
      final googleChat = channels['googleChat'] as Map<String, dynamic>;

      expect(googleChat['enabled'], isTrue);
      expect(googleChat['serviceAccount'], '/tmp/google-service-account.json');
      expect(googleChat['audience'], {'type': 'app-url', 'value': 'https://example.com/integrations/googlechat'});
      expect(googleChat['webhookPath'], '/integrations/googlechat');
      expect(googleChat['botUser'], 'users/123');
      expect(googleChat['typingIndicator'], isFalse);
      expect(googleChat['dmAccess'], 'allowlist');
      expect(googleChat['dmAllowlist'], ['spaces/AAA/users/1']);
      expect(googleChat['groupAccess'], 'open');
      expect(googleChat['groupAllowlist'], ['spaces/AAA']);
      expect(googleChat['requireMention'], isFalse);
    });

    test('google chat inline service account is redacted to client email', () {
      final config = DartclawConfig(
        googleChatConfig: const GoogleChatConfig(
          enabled: true,
          serviceAccount:
              '{"type":"service_account","client_email":"chat-bot@example.iam.gserviceaccount.com","private_key":"secret"}',
          audience: GoogleChatAudienceConfig(mode: GoogleChatAudienceMode.projectNumber, value: '123456789'),
        ),
      );
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true, gitSyncPushEnabled: true);

      final json = serializer.toJson(config, runtime: runtime);
      final channels = json['channels'] as Map<String, dynamic>;
      final googleChat = channels['googleChat'] as Map<String, dynamic>;

      expect(googleChat['serviceAccount'], 'chat-bot@example.iam.gserviceaccount.com');
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
