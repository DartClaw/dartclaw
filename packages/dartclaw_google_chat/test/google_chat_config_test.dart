import 'package:dartclaw_core/dartclaw_core.dart' show ChannelType, DartclawConfig, DmAccessMode, GroupAccessMode;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:test/test.dart';

void main() {
  group('GoogleChatConfig', () {
    group('fromYaml', () {
      test('parses all fields', () {
        final warns = <String>[];
        final config = GoogleChatConfig.fromYaml({
          'enabled': true,
          'service_account': '{"type":"service_account"}',
          'audience': {'type': 'app-url', 'value': 'https://example.com/integrations/googlechat'},
          'webhook_path': '/hooks/google-chat',
          'bot_user': 'users/123456',
          'typing_indicator': false,
          'dm_access': 'allowlist',
          'dm_allowlist': ['spaces/AAA/users/1'],
          'group_access': 'allowlist',
          'group_allowlist': ['spaces/AAA'],
          'require_mention': false,
          'task_trigger': {'enabled': true, 'prefix': 'do:', 'default_type': 'automation', 'auto_start': false},
        }, warns);

        expect(warns, isEmpty);
        expect(config.enabled, isTrue);
        expect(config.serviceAccount, '{"type":"service_account"}');
        expect(config.audience, isNotNull);
        expect(config.audience!.mode, GoogleChatAudienceMode.appUrl);
        expect(config.audience!.value, 'https://example.com/integrations/googlechat');
        expect(config.webhookPath, '/hooks/google-chat');
        expect(config.botUser, 'users/123456');
        expect(config.typingIndicator, isFalse);
        expect(config.dmAccess, DmAccessMode.allowlist);
        expect(config.dmAllowlist, ['spaces/AAA/users/1']);
        expect(config.groupAccess, GroupAccessMode.allowlist);
        expect(config.groupAllowlist, ['spaces/AAA']);
        expect(config.requireMention, isFalse);
        expect(config.taskTrigger.enabled, isTrue);
        expect(config.taskTrigger.prefix, 'do:');
        expect(config.taskTrigger.defaultType, 'automation');
        expect(config.taskTrigger.autoStart, isFalse);
      });

      test('parses audience app-url mode', () {
        final config = GoogleChatConfig.fromYaml({
          'audience': {'type': 'app-url', 'value': 'https://example.com'},
        }, []);
        expect(config.audience!.mode, GoogleChatAudienceMode.appUrl);
      });

      test('parses audience project-number mode', () {
        final config = GoogleChatConfig.fromYaml({
          'audience': {'type': 'project-number', 'value': '12345'},
        }, []);
        expect(config.audience!.mode, GoogleChatAudienceMode.projectNumber);
      });

      test('defaults optional fields', () {
        final warns = <String>[];
        final config = GoogleChatConfig.fromYaml({
          'enabled': true,
          'service_account': '{"type":"service_account"}',
          'audience': {'type': 'project-number', 'value': '12345'},
        }, warns);

        expect(warns, isEmpty);
        expect(config.webhookPath, '/integrations/googlechat');
        expect(config.typingIndicator, isTrue);
        expect(config.dmAccess, DmAccessMode.pairing);
        expect(config.dmAllowlist, isEmpty);
        expect(config.groupAccess, GroupAccessMode.disabled);
        expect(config.groupAllowlist, isEmpty);
        expect(config.requireMention, isTrue);
        expect(config.taskTrigger.enabled, isFalse);
      });

      test('warns on invalid types', () {
        final warns = <String>[];
        GoogleChatConfig.fromYaml({
          'enabled': 'yes',
          'service_account': 123,
          'audience': 'bad',
          'webhook_path': false,
          'bot_user': 99,
          'typing_indicator': 'yes',
          'dm_access': 7,
          'group_access': 9,
          'require_mention': 'no',
        }, warns);
        expect(warns, hasLength(9));
      });

      test('warns on invalid dm_access value', () {
        final warns = <String>[];
        final config = GoogleChatConfig.fromYaml({'dm_access': 'invalid'}, warns);
        expect(config.dmAccess, DmAccessMode.pairing);
        expect(warns, contains(contains('google_chat.dm_access')));
      });

      test('warns on invalid group_access value', () {
        final warns = <String>[];
        final config = GoogleChatConfig.fromYaml({'group_access': 'invalid'}, warns);
        expect(config.groupAccess, GroupAccessMode.disabled);
        expect(warns, contains(contains('google_chat.group_access')));
      });

      test('warns on invalid audience type', () {
        final warns = <String>[];
        final config = GoogleChatConfig.fromYaml({
          'audience': {'type': 'unknown', 'value': 'abc'},
        }, warns);
        expect(config.audience, isNull);
        expect(warns, contains(contains('google_chat.audience.type')));
      });

      test('warns when enabled without required fields', () {
        final warns = <String>[];
        final config = GoogleChatConfig.fromYaml({'enabled': true}, warns);
        expect(config.enabled, isTrue);
        expect(warns, contains('Missing required google_chat.service_account when channel is enabled'));
        expect(warns, contains('Missing or invalid google_chat.audience when channel is enabled'));
      });

      test('warns when enabled with blank service account', () {
        final warns = <String>[];
        final config = GoogleChatConfig.fromYaml({
          'enabled': true,
          'service_account': '   ',
          'audience': {'type': 'project-number', 'value': '12345'},
        }, warns);

        expect(config.serviceAccount, isNull);
        expect(warns, contains('Missing required google_chat.service_account when channel is enabled'));
      });

      test('warns when enabled with whitespace-only audience value', () {
        final warns = <String>[];
        final config = GoogleChatConfig.fromYaml({
          'enabled': true,
          'service_account': '/tmp/google-service-account.json',
          'audience': {'type': 'app-url', 'value': '   '},
        }, warns);

        expect(config.audience, isNull);
        expect(warns, contains('Missing or invalid google_chat.audience when channel is enabled'));
      });

    });
  });

  group('Google Chat config registration', () {
    test('provider returns disabled defaults when package is imported', () {
      ensureDartclawGoogleChatRegistered();

      final config = DartclawConfig.load(fileReader: (_) => null, env: {'HOME': '/home/user'});
      final googleChatConfig = config.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat);

      expect(googleChatConfig.enabled, isFalse);
      expect(googleChatConfig.webhookPath, '/integrations/googlechat');
      expect(googleChatConfig.groupAccess, GroupAccessMode.disabled);
      expect(googleChatConfig.requireMention, isTrue);
      expect(googleChatConfig.taskTrigger.enabled, isFalse);
    });

    test('provider parses google chat config when package is imported', () {
      ensureDartclawGoogleChatRegistered();

      final config = DartclawConfig.load(
        fileReader: (path) {
          if (path == 'dartclaw.yaml') {
            return '''
channels:
  google_chat:
    enabled: true
    service_account: /tmp/google-service-account.json
    audience:
      type: app-url
      value: https://example.com/integrations/googlechat
    webhook_path: /integrations/googlechat
    bot_user: users/123
    typing_indicator: false
    dm_access: allowlist
    group_access: open
    require_mention: false
    task_trigger:
      enabled: true
      prefix: "do:"
      default_type: custom
      auto_start: false
''';
          }
          return null;
        },
        env: {'HOME': '/home/user'},
      );
      final googleChatConfig = config.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat);

      expect(googleChatConfig.enabled, isTrue);
      expect(googleChatConfig.serviceAccount, '/tmp/google-service-account.json');
      expect(googleChatConfig.audience, isNotNull);
      expect(googleChatConfig.audience!.mode, GoogleChatAudienceMode.appUrl);
      expect(googleChatConfig.botUser, 'users/123');
      expect(googleChatConfig.typingIndicator, isFalse);
      expect(googleChatConfig.dmAccess, DmAccessMode.allowlist);
      expect(googleChatConfig.groupAccess, GroupAccessMode.open);
      expect(googleChatConfig.requireMention, isFalse);
      expect(googleChatConfig.taskTrigger.enabled, isTrue);
      expect(googleChatConfig.taskTrigger.prefix, 'do:');
      expect(googleChatConfig.taskTrigger.defaultType, 'custom');
      expect(googleChatConfig.taskTrigger.autoStart, isFalse);
    });

    test('channel config warnings are surfaced during load and cached', () {
      ensureDartclawGoogleChatRegistered();

      final config = DartclawConfig.load(
        fileReader: (path) {
          if (path == 'dartclaw.yaml') {
            return '''
channels:
  google_chat:
    enabled: true
    service_account: /tmp/google-service-account.json
    audience:
      type: app-url
      value: https://example.com/integrations/googlechat
    group_access: 123
''';
          }
          return null;
        },
        env: {'HOME': '/home/user'},
      );

      expect(config.warnings, anyElement(contains('Invalid type for google_chat.group_access')));

      config.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat);

      final warningCount = config.warnings.length;
      config.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat);
      expect(config.warnings, hasLength(warningCount));
    });
  });
}
