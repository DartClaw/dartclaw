import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('GoogleChatConfig', () {
    group('construction', () {
      test('defaults to disabled', () {
        const config = GoogleChatConfig();
        expect(config.enabled, isFalse);
        expect(config.serviceAccount, isNull);
        expect(config.audience, isNull);
        expect(config.webhookPath, '/integrations/googlechat');
        expect(config.typingIndicator, isTrue);
        expect(config.dmAccess, DmAccessMode.pairing);
        expect(config.groupAccess, GroupAccessMode.disabled);
        expect(config.requireMention, isTrue);
      });

      test('disabled is same as default', () {
        const config = GoogleChatConfig.disabled();
        expect(config.enabled, isFalse);
        expect(config.serviceAccount, isNull);
        expect(config.audience, isNull);
      });
    });

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

      test('parses dm_allowlist', () {
        final config = GoogleChatConfig.fromYaml({
          'dm_allowlist': ['a', 'b'],
        }, []);
        expect(config.dmAllowlist, ['a', 'b']);
      });

      test('parses group_allowlist', () {
        final config = GoogleChatConfig.fromYaml({
          'group_allowlist': ['a', 'b'],
        }, []);
        expect(config.groupAllowlist, ['a', 'b']);
      });

      test('empty map returns defaults', () {
        final warns = <String>[];
        const defaults = GoogleChatConfig();
        final config = GoogleChatConfig.fromYaml({}, warns);

        expect(warns, isEmpty);
        expect(config.enabled, defaults.enabled);
        expect(config.serviceAccount, defaults.serviceAccount);
        expect(config.audience, defaults.audience);
        expect(config.webhookPath, defaults.webhookPath);
      });
    });
  });
}
