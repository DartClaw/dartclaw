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
          'oauth_credentials': '/tmp/google-oauth-client.json',
          'audience': {'type': 'app-url', 'value': 'https://example.com/integrations/googlechat'},
          'webhook_path': '/hooks/google-chat',
          'bot_user': 'users/123456',
          'typing_indicator': 'emoji',
          'quote_reply': true,
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
        expect(config.oauthCredentials, '/tmp/google-oauth-client.json');
        expect(config.audience, isNotNull);
        expect(config.audience!.mode, GoogleChatAudienceMode.appUrl);
        expect(config.audience!.value, 'https://example.com/integrations/googlechat');
        expect(config.webhookPath, '/hooks/google-chat');
        expect(config.botUser, 'users/123456');
        expect(config.typingIndicatorMode, TypingIndicatorMode.emoji);
        expect(config.typingIndicator, isTrue);
        expect(config.quoteReply, isTrue);
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
        expect(config.typingIndicatorMode, TypingIndicatorMode.message);
        expect(config.typingIndicator, isTrue);
        expect(config.quoteReply, isFalse);
        expect(config.dmAccess, DmAccessMode.pairing);
        expect(config.dmAllowlist, isEmpty);
        expect(config.groupAccess, GroupAccessMode.disabled);
        expect(config.groupAllowlist, isEmpty);
        expect(config.requireMention, isTrue);
        expect(config.taskTrigger.enabled, isFalse);
      });

      test('parses typing_indicator aliases', () {
        final cases = <({Object? raw, TypingIndicatorMode expected})>[
          (raw: true, expected: TypingIndicatorMode.message),
          (raw: false, expected: TypingIndicatorMode.disabled),
          (raw: 'message', expected: TypingIndicatorMode.message),
          (raw: 'emoji', expected: TypingIndicatorMode.emoji),
          (raw: 'disabled', expected: TypingIndicatorMode.disabled),
          (raw: 'true', expected: TypingIndicatorMode.message),
          (raw: 'false', expected: TypingIndicatorMode.disabled),
        ];

        for (final testCase in cases) {
          final warns = <String>[];
          final config = GoogleChatConfig.fromYaml({'typing_indicator': testCase.raw}, warns);

          expect(warns, isEmpty, reason: 'unexpected warning for ${testCase.raw}');
          expect(config.typingIndicatorMode, testCase.expected);
        }
      });

      test('trims whitespace around typing_indicator enum values', () {
        final cases = <({String raw, TypingIndicatorMode expected})>[
          (raw: 'emoji ', expected: TypingIndicatorMode.emoji),
          (raw: ' disabled ', expected: TypingIndicatorMode.disabled),
          (raw: ' message\t', expected: TypingIndicatorMode.message),
        ];

        for (final testCase in cases) {
          final warns = <String>[];
          final config = GoogleChatConfig.fromYaml({'typing_indicator': testCase.raw}, warns);

          expect(warns, isEmpty, reason: 'unexpected warning for ${testCase.raw}');
          expect(config.typingIndicatorMode, testCase.expected);
        }
      });

      test('warns on invalid typing_indicator and quote_reply types', () {
        final warns = <String>[];
        GoogleChatConfig.fromYaml({
          'enabled': 'yes',
          'service_account': 123,
          'oauth_credentials': false,
          'audience': 'bad',
          'webhook_path': false,
          'bot_user': 99,
          'typing_indicator': 123,
          'quote_reply': 'yes',
          'dm_access': 7,
          'group_access': 9,
          'require_mention': 'no',
        }, warns);
        expect(warns, contains(contains('google_chat.typing_indicator')));
        expect(warns, contains(contains('google_chat.quote_reply')));
        expect(warns, contains(contains('google_chat.enabled')));
        expect(warns, contains(contains('google_chat.service_account')));
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

      test('defaults quote_reply to false when absent', () {
        final config = GoogleChatConfig.fromYaml({}, []);
        expect(config.quoteReply, isFalse);
      });

      test('warns on invalid quote_reply type', () {
        final warns = <String>[];
        final config = GoogleChatConfig.fromYaml({'quote_reply': 'yes'}, warns);
        expect(config.quoteReply, isFalse);
        expect(warns, contains(contains('google_chat.quote_reply')));
      });

      test('warns when enabled space events use unsupported event types for auth mode', () {
        final warns = <String>[];
        GoogleChatConfig.fromYaml({
          'enabled': true,
          'service_account': '/tmp/google-service-account.json',
          'audience': {'type': 'project-number', 'value': '12345'},
          'pubsub': {'project_id': 'my-project', 'subscription': 'my-sub'},
          'space_events': {
            'enabled': true,
            'pubsub_topic': 'projects/my-project/topics/chat-events',
            'auth_mode': 'app',
            'event_types': ['reaction.created'],
          },
        }, warns);

        expect(warns, contains(contains('do not have a supported scope mapping')));
      });

      test('parses pubsub section', () {
        final warns = <String>[];
        final config = GoogleChatConfig.fromYaml({
          'pubsub': {'project_id': 'my-gcp-project', 'subscription': 'dartclaw-chat-pull'},
        }, warns);
        expect(warns, isEmpty);
        expect(config.pubsub.projectId, 'my-gcp-project');
        expect(config.pubsub.subscription, 'dartclaw-chat-pull');
      });

      test('parses space_events section', () {
        final warns = <String>[];
        final config = GoogleChatConfig.fromYaml({
          'space_events': {'enabled': true, 'pubsub_topic': 'projects/my-project/topics/chat-events'},
          'pubsub': {'project_id': 'my-project', 'subscription': 'my-sub'},
        }, warns);
        expect(config.spaceEvents.enabled, isTrue);
        expect(config.spaceEvents.pubsubTopic, 'projects/my-project/topics/chat-events');
      });

      test('defaults pubsub when absent', () {
        final config = GoogleChatConfig.fromYaml({}, []);
        expect(config.pubsub.projectId, isNull);
        expect(config.pubsub.subscription, isNull);
      });

      test('defaults space_events when absent', () {
        final config = GoogleChatConfig.fromYaml({}, []);
        expect(config.spaceEvents.enabled, isFalse);
      });

      test('warns on invalid pubsub type', () {
        final warns = <String>[];
        GoogleChatConfig.fromYaml({'pubsub': 'bad'}, warns);
        expect(warns, contains(contains('google_chat.pubsub')));
      });

      test('warns on invalid space_events type', () {
        final warns = <String>[];
        GoogleChatConfig.fromYaml({'space_events': 42}, warns);
        expect(warns, contains(contains('google_chat.space_events')));
      });

      test('warns when space_events enabled without pubsub.project_id', () {
        final warns = <String>[];
        GoogleChatConfig.fromYaml({
          'space_events': {'enabled': true, 'pubsub_topic': 'projects/p/topics/t'},
          'pubsub': {'subscription': 'my-sub'},
        }, warns);
        expect(warns, contains(contains('pubsub.project_id')));
      });

      test('warns when space_events enabled without pubsub.subscription', () {
        final warns = <String>[];
        GoogleChatConfig.fromYaml({
          'space_events': {'enabled': true, 'pubsub_topic': 'projects/p/topics/t'},
          'pubsub': {'project_id': 'my-project'},
        }, warns);
        expect(warns, contains(contains('pubsub.subscription')));
      });

      test('warns when space_events enabled without pubsub_topic', () {
        final warns = <String>[];
        GoogleChatConfig.fromYaml({
          'space_events': {'enabled': true},
          'pubsub': {'project_id': 'my-project', 'subscription': 'my-sub'},
        }, warns);
        expect(warns, contains(contains('space_events.pubsub_topic')));
      });

      test('no warnings when space_events enabled with all required fields', () {
        final warns = <String>[];
        GoogleChatConfig.fromYaml({
          'space_events': {'enabled': true, 'pubsub_topic': 'projects/my-project/topics/chat-events'},
          'pubsub': {'project_id': 'my-project', 'subscription': 'my-sub'},
        }, warns);
        expect(warns.where((w) => w.contains('required') && w.contains('space_events')), isEmpty);
        expect(warns.where((w) => w.contains('required') && w.contains('pubsub')), isEmpty);
      });
    });
  });

  group('PubSubConfig', () {
    group('fromYaml', () {
      test('parses all fields', () {
        final warns = <String>[];
        final config = PubSubConfig.fromYaml({
          'project_id': 'my-gcp-project',
          'subscription': 'dartclaw-chat-pull',
          'poll_interval_seconds': 5,
          'max_messages_per_pull': 50,
        }, warns);

        expect(warns, isEmpty);
        expect(config.projectId, 'my-gcp-project');
        expect(config.subscription, 'dartclaw-chat-pull');
        expect(config.pollIntervalSeconds, 5);
        expect(config.maxMessagesPerPull, 50);
      });

      test('defaults when absent', () {
        final warns = <String>[];
        final config = PubSubConfig.fromYaml({}, warns);

        expect(warns, isEmpty);
        expect(config.projectId, isNull);
        expect(config.subscription, isNull);
        expect(config.pollIntervalSeconds, 2);
        expect(config.maxMessagesPerPull, 100);
      });

      test('isConfigured is true when both project_id and subscription present', () {
        final config = PubSubConfig.fromYaml({'project_id': 'my-project', 'subscription': 'my-sub'}, []);
        expect(config.isConfigured, isTrue);
      });

      test('isConfigured is false when project_id missing', () {
        final config = PubSubConfig.fromYaml({'subscription': 'my-sub'}, []);
        expect(config.isConfigured, isFalse);
      });

      test('isConfigured is false when subscription missing', () {
        final config = PubSubConfig.fromYaml({'project_id': 'my-project'}, []);
        expect(config.isConfigured, isFalse);
      });

      test('warns on invalid types', () {
        final warns = <String>[];
        PubSubConfig.fromYaml({'project_id': 42, 'subscription': true}, warns);
        expect(warns, hasLength(2));
        expect(warns, contains(contains('google_chat.pubsub.project_id')));
        expect(warns, contains(contains('google_chat.pubsub.subscription')));
      });

      test('clamps poll_interval_seconds to minimum 1', () {
        final warns = <String>[];
        final config = PubSubConfig.fromYaml({'poll_interval_seconds': 0}, warns);
        expect(config.pollIntervalSeconds, 1);
        expect(warns, contains(contains('poll_interval_seconds')));
      });

      test('clamps max_messages_per_pull to minimum 1', () {
        final warns = <String>[];
        final config = PubSubConfig.fromYaml({'max_messages_per_pull': 0}, warns);
        expect(config.maxMessagesPerPull, 1);
        expect(warns, contains(contains('max_messages_per_pull')));
      });

      test('clamps max_messages_per_pull to maximum 100', () {
        final warns = <String>[];
        final config = PubSubConfig.fromYaml({'max_messages_per_pull': 200}, warns);
        expect(config.maxMessagesPerPull, 100);
        expect(warns, contains(contains('max_messages_per_pull')));
      });
    });
  });

  group('SpaceEventsConfig', () {
    group('fromYaml', () {
      test('parses all fields', () {
        final warns = <String>[];
        final config = SpaceEventsConfig.fromYaml({
          'enabled': true,
          'pubsub_topic': 'projects/my-project/topics/dartclaw-chat-events',
          'event_types': ['message.created', 'message.updated'],
          'include_resource': false,
          'auth_mode': 'app',
        }, warns);

        expect(warns, isEmpty);
        expect(config.enabled, isTrue);
        expect(config.pubsubTopic, 'projects/my-project/topics/dartclaw-chat-events');
        expect(config.eventTypes, ['message.created', 'message.updated']);
        expect(config.includeResource, isFalse);
        expect(config.authMode, 'app');
      });

      test('defaults when absent', () {
        final warns = <String>[];
        final config = SpaceEventsConfig.fromYaml({}, warns);

        expect(warns, isEmpty);
        expect(config.enabled, isFalse);
        expect(config.pubsubTopic, isNull);
        expect(config.eventTypes, ['message.created']);
        expect(config.includeResource, isTrue);
        expect(config.authMode, 'user');
      });

      test('warns on invalid enabled type', () {
        final warns = <String>[];
        final config = SpaceEventsConfig.fromYaml({'enabled': 'yes'}, warns);
        expect(config.enabled, isFalse);
        expect(warns, contains(contains('space_events.enabled')));
      });

      test('warns on invalid auth_mode value', () {
        final warns = <String>[];
        final config = SpaceEventsConfig.fromYaml({'auth_mode': 'service_account'}, warns);
        expect(config.authMode, 'user');
        expect(warns, contains(contains('space_events.auth_mode')));
      });

      test('derives required user auth scopes from event types', () {
        const config = SpaceEventsConfig(eventTypes: ['message.created', 'membership.updated', 'space.deleted']);

        expect(config.requiredUserAuthScopes, {
          'https://www.googleapis.com/auth/chat.messages.readonly',
          'https://www.googleapis.com/auth/chat.memberships.readonly',
          'https://www.googleapis.com/auth/chat.spaces.readonly',
        });
      });

      test('derives required app auth scopes from event types', () {
        const config = SpaceEventsConfig(eventTypes: ['message.created', 'membership.updated', 'space.deleted']);

        expect(config.requiredAppAuthScopes, {
          'https://www.googleapis.com/auth/chat.app.messages.readonly',
          'https://www.googleapis.com/auth/chat.app.memberships',
          'https://www.googleapis.com/auth/chat.app.spaces',
        });
      });

      test('flags unsupported event types for app auth', () {
        const config = SpaceEventsConfig(eventTypes: ['reaction.created', 'message.created'], authMode: 'app');

        expect(config.unsupportedEventTypesForAuthMode('app'), ['reaction.created']);
      });

      test('filters non-string event_types entries', () {
        final warns = <String>[];
        final config = SpaceEventsConfig.fromYaml({
          'event_types': [42, 'message.created', true],
        }, warns);
        expect(config.eventTypes, ['message.created']);
      });

      test('warns on non-list event_types', () {
        final warns = <String>[];
        final config = SpaceEventsConfig.fromYaml({'event_types': 'message.created'}, warns);
        expect(config.eventTypes, ['message.created']);
        expect(warns, contains(contains('space_events.event_types')));
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
      expect(googleChatConfig.typingIndicatorMode, TypingIndicatorMode.message);
      expect(googleChatConfig.quoteReply, isFalse);
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
    typing_indicator: emoji
    quote_reply: true
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
      expect(googleChatConfig.typingIndicatorMode, TypingIndicatorMode.emoji);
      expect(googleChatConfig.quoteReply, isTrue);
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

    test('provider parses pubsub and space_events sections', () {
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
      type: project-number
      value: "12345"
    pubsub:
      project_id: my-gcp-project
      subscription: dartclaw-chat-pull
      poll_interval_seconds: 5
      max_messages_per_pull: 50
    space_events:
      enabled: true
      pubsub_topic: projects/my-gcp-project/topics/dartclaw-chat-events
      event_types:
        - message.created
        - message.updated
      include_resource: false
      auth_mode: user
''';
          }
          return null;
        },
        env: {'HOME': '/home/user'},
      );
      final googleChatConfig = config.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat);

      expect(googleChatConfig.pubsub.projectId, 'my-gcp-project');
      expect(googleChatConfig.pubsub.subscription, 'dartclaw-chat-pull');
      expect(googleChatConfig.pubsub.pollIntervalSeconds, 5);
      expect(googleChatConfig.pubsub.maxMessagesPerPull, 50);
      expect(googleChatConfig.spaceEvents.enabled, isTrue);
      expect(googleChatConfig.spaceEvents.pubsubTopic, 'projects/my-gcp-project/topics/dartclaw-chat-events');
      expect(googleChatConfig.spaceEvents.eventTypes, ['message.created', 'message.updated']);
      expect(googleChatConfig.spaceEvents.includeResource, isFalse);
      expect(googleChatConfig.spaceEvents.authMode, 'user');
    });
  });
}
