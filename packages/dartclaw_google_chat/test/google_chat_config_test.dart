import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:test/test.dart';

typedef _GoogleChatExpectation = void Function(GoogleChatConfig config, List<String> warnings);
typedef _PubSubExpectation = void Function(PubSubConfig config, List<String> warnings);
typedef _SpaceEventsExpectation = void Function(SpaceEventsConfig config, List<String> warnings);

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
          'typing_indicator': false,
          'dm_access': 'allowlist',
          'dm_allowlist': ['spaces/AAA/users/1'],
          'group_access': 'allowlist',
          'group_allowlist': ['spaces/AAA'],
          'require_mention': false,
          'quote_reply': true,
          'task_trigger': {'enabled': true, 'prefix': 'do:', 'default_type': 'automation', 'auto_start': false},
        }, warns);

        expect(warns, isEmpty);
        expect(config.enabled, isTrue);
        expect(config.serviceAccount, '{"type":"service_account"}');
        expect(config.oauthCredentials, '/tmp/google-oauth-client.json');
        expect(config.audience!.mode, GoogleChatAudienceMode.appUrl);
        expect(config.audience!.value, 'https://example.com/integrations/googlechat');
        expect(config.webhookPath, '/hooks/google-chat');
        expect(config.botUser, 'users/123456');
        expect(config.typingIndicatorMode, TypingIndicatorMode.disabled);
        expect(config.dmAccess, DmAccessMode.allowlist);
        expect(config.dmAllowlist, ['spaces/AAA/users/1']);
        expect(config.groupAccess, GroupAccessMode.allowlist);
        expect(config.groupIds, ['spaces/AAA']);
        expect(config.requireMention, isFalse);
        expect(config.quoteReplyMode, QuoteReplyMode.sender);
        expect(config.taskTrigger.enabled, isTrue);
        expect(config.taskTrigger.prefix, 'do:');
        expect(config.taskTrigger.defaultType, 'automation');
        expect(config.taskTrigger.autoStart, isFalse);
      });

      final cases = <({String name, Map<String, Object?> yaml, _GoogleChatExpectation expectConfig})>[
        (
          name: 'audience app-url mode',
          yaml: {
            'audience': {'type': 'app-url', 'value': 'https://example.com'},
          },
          expectConfig: (config, warnings) {
            expect(warnings, isEmpty);
            expect(config.audience!.mode, GoogleChatAudienceMode.appUrl);
          },
        ),
        (
          name: 'audience project-number mode',
          yaml: {
            'audience': {'type': 'project-number', 'value': '12345'},
          },
          expectConfig: (config, warnings) {
            expect(warnings, isEmpty);
            expect(config.audience!.mode, GoogleChatAudienceMode.projectNumber);
          },
        ),
        (
          name: 'optional defaults',
          yaml: {
            'enabled': true,
            'service_account': '{"type":"service_account"}',
            'audience': {'type': 'project-number', 'value': '12345'},
          },
          expectConfig: (config, warnings) {
            expect(warnings, isEmpty);
            expect(config.webhookPath, '/integrations/googlechat');
            expect(config.typingIndicatorMode, TypingIndicatorMode.message);
            expect(config.dmAccess, DmAccessMode.pairing);
            expect(config.dmAllowlist, isEmpty);
            expect(config.groupAccess, GroupAccessMode.disabled);
            expect(config.groupIds, isEmpty);
            expect(config.requireMention, isTrue);
            expect(config.quoteReplyMode, QuoteReplyMode.disabled);
            expect(config.taskTrigger.enabled, isFalse);
          },
        ),
        (
          name: 'invalid quote_reply type',
          yaml: {'quote_reply': 'yes'},
          expectConfig: (config, warnings) {
            expect(config.quoteReplyMode, QuoteReplyMode.disabled);
            expect(warnings, contains(contains('google_chat.quote_reply')));
          },
        ),
        (
          name: 'default reactions_auth',
          yaml: {},
          expectConfig: (config, warnings) {
            expect(config.reactionsAuth, ReactionsAuth.disabled);
            expect(config.requiredReactionScopes, isEmpty);
          },
        ),
        (
          name: 'reactions_auth user',
          yaml: {'reactions_auth': 'user'},
          expectConfig: (config, warnings) {
            expect(warnings, isEmpty);
            expect(config.reactionsAuth, ReactionsAuth.user);
            expect(config.requiredReactionScopes, {'https://www.googleapis.com/auth/chat.messages.reactions'});
          },
        ),
        (
          name: 'invalid reactions_auth value',
          yaml: {'reactions_auth': 'service_account'},
          expectConfig: (config, warnings) {
            expect(config.reactionsAuth, ReactionsAuth.disabled);
            expect(config.requiredReactionScopes, isEmpty);
            expect(warnings, contains(contains('google_chat.reactions_auth')));
          },
        ),
        (
          name: 'feedback progress settings',
          yaml: {
            'feedback': {
              'enabled': true,
              'min_feedback_delay': '2s',
              'status_interval': '30s',
              'status_style': 'minimal',
            },
          },
          expectConfig: (config, warnings) {
            expect(warnings, isEmpty);
            expect(config.feedback.enabled, isTrue);
            expect(config.feedback.minFeedbackDelay, const Duration(seconds: 2));
            expect(config.feedback.statusInterval, const Duration(seconds: 30));
            expect(config.feedback.statusStyle, GoogleChatFeedbackStatusStyle.minimal);
          },
        ),
        (
          name: 'feedback defaults',
          yaml: {},
          expectConfig: (config, warnings) => expect(config.feedback.enabled, isFalse),
        ),
        (
          name: 'invalid scalar types',
          yaml: {
            'enabled': 'yes',
            'service_account': 123,
            'oauth_credentials': false,
            'audience': 'bad',
            'webhook_path': false,
            'bot_user': 99,
            'typing_indicator': 'yes',
            'dm_access': 7,
            'group_access': 9,
            'require_mention': 'no',
          },
          expectConfig: (config, warnings) => expect(warnings, hasLength(10)),
        ),
        (
          name: 'invalid dm_access value',
          yaml: {'dm_access': 'invalid'},
          expectConfig: (config, warnings) {
            expect(config.dmAccess, DmAccessMode.pairing);
            expect(warnings, contains(contains('google_chat.dm_access')));
          },
        ),
        (
          name: 'invalid group_access value',
          yaml: {'group_access': 'invalid'},
          expectConfig: (config, warnings) {
            expect(config.groupAccess, GroupAccessMode.disabled);
            expect(warnings, contains(contains('google_chat.group_access')));
          },
        ),
        (
          name: 'invalid audience type',
          yaml: {
            'audience': {'type': 'unknown', 'value': 'abc'},
          },
          expectConfig: (config, warnings) {
            expect(config.audience, isNull);
            expect(warnings, contains(contains('google_chat.audience.type')));
          },
        ),
        (
          name: 'enabled without required fields',
          yaml: {'enabled': true},
          expectConfig: (config, warnings) {
            expect(config.enabled, isTrue);
            expect(warnings, contains('Missing required google_chat.service_account when channel is enabled'));
            expect(warnings, contains('Missing or invalid google_chat.audience when channel is enabled'));
          },
        ),
        (
          name: 'enabled with blank service account',
          yaml: {
            'enabled': true,
            'service_account': '   ',
            'audience': {'type': 'project-number', 'value': '12345'},
          },
          expectConfig: (config, warnings) {
            expect(config.serviceAccount, isNull);
            expect(warnings, contains('Missing required google_chat.service_account when channel is enabled'));
          },
        ),
        (
          name: 'enabled with whitespace audience',
          yaml: {
            'enabled': true,
            'service_account': '/tmp/google-service-account.json',
            'audience': {'type': 'app-url', 'value': '   '},
          },
          expectConfig: (config, warnings) {
            expect(config.audience, isNull);
            expect(warnings, contains('Missing or invalid google_chat.audience when channel is enabled'));
          },
        ),
        (
          name: 'unsupported space event type for user OAuth',
          yaml: {
            'enabled': true,
            'service_account': '/tmp/google-service-account.json',
            'audience': {'type': 'project-number', 'value': '12345'},
            'pubsub': {'project_id': 'my-project', 'subscription': 'my-sub'},
            'space_events': {
              'enabled': true,
              'pubsub_topic': 'projects/my-project/topics/chat-events',
              'event_types': ['reaction.created'],
            },
          },
          expectConfig: (config, warnings) =>
              expect(warnings, contains(contains('do not have a supported scope mapping'))),
        ),
      ];

      for (final testCase in cases) {
        test(testCase.name, () {
          final warnings = <String>[];
          final config = GoogleChatConfig.fromYaml(testCase.yaml, warnings);
          testCase.expectConfig(config, warnings);
        });
      }

      test('pubsub and space_events parse/default/warn through GoogleChatConfig', () {
        final parsedWarnings = <String>[];
        final parsed = GoogleChatConfig.fromYaml({
          'pubsub': {'project_id': 'my-gcp-project', 'subscription': 'dartclaw-chat-pull'},
          'space_events': {'enabled': true, 'pubsub_topic': 'projects/my-project/topics/chat-events'},
        }, parsedWarnings);
        expect(parsedWarnings, isEmpty);
        expect(parsed.pubsub.projectId, 'my-gcp-project');
        expect(parsed.pubsub.subscription, 'dartclaw-chat-pull');
        expect(parsed.spaceEvents.enabled, isTrue);
        expect(parsed.spaceEvents.pubsubTopic, 'projects/my-project/topics/chat-events');

        final defaults = GoogleChatConfig.fromYaml({}, []);
        expect(defaults.pubsub.projectId, isNull);
        expect(defaults.pubsub.subscription, isNull);
        expect(defaults.spaceEvents.enabled, isFalse);

        final warnings = <String>[];
        GoogleChatConfig.fromYaml({'pubsub': 'bad', 'space_events': 42}, warnings);
        expect(warnings, contains(contains('google_chat.pubsub')));
        expect(warnings, contains(contains('google_chat.space_events')));
      });

      test('space_events required-field warnings', () {
        final cases = [
          (
            yaml: {
              'space_events': {'enabled': true, 'pubsub_topic': 'projects/p/topics/t'},
              'pubsub': {'subscription': 'my-sub'},
            },
            warning: 'pubsub.project_id',
          ),
          (
            yaml: {
              'space_events': {'enabled': true, 'pubsub_topic': 'projects/p/topics/t'},
              'pubsub': {'project_id': 'my-project'},
            },
            warning: 'pubsub.subscription',
          ),
          (
            yaml: {
              'space_events': {'enabled': true},
              'pubsub': {'project_id': 'my-project', 'subscription': 'my-sub'},
            },
            warning: 'space_events.pubsub_topic',
          ),
        ];

        for (final testCase in cases) {
          final warnings = <String>[];
          GoogleChatConfig.fromYaml(testCase.yaml, warnings);
          expect(warnings, contains(contains(testCase.warning)), reason: testCase.warning);
        }

        final validWarnings = <String>[];
        GoogleChatConfig.fromYaml({
          'space_events': {'enabled': true, 'pubsub_topic': 'projects/my-project/topics/chat-events'},
          'pubsub': {'project_id': 'my-project', 'subscription': 'my-sub'},
        }, validWarnings);
        expect(validWarnings.where((w) => w.contains('required') && w.contains('space_events')), isEmpty);
        expect(validWarnings.where((w) => w.contains('required') && w.contains('pubsub')), isEmpty);
      });

      test('group_allowlist supports legacy strings and structured entries', () {
        final warnings = <String>[];
        final mixed = GoogleChatConfig.fromYaml({
          'group_allowlist': [
            'spaces/AAA',
            {'id': 'spaces/BBB', 'name': 'Dev Space', 'model': 'sonnet'},
            {'id': 'spaces/CCC'},
          ],
        }, warnings);
        expect(warnings, isEmpty);
        expect(mixed.groupIds, ['spaces/AAA', 'spaces/BBB', 'spaces/CCC']);
        expect(mixed.groupAllowlist[1].name, 'Dev Space');
        expect(mixed.groupAllowlist[1].model, 'sonnet');
        expect(mixed.groupAllowlist[0].name, isNull);

        final legacy = GoogleChatConfig.fromYaml({
          'group_allowlist': ['spaces/AAA', 'spaces/BBB'],
        }, []);
        expect(legacy.groupIds, ['spaces/AAA', 'spaces/BBB']);
      });
    });
  });

  group('PubSubConfig.fromYaml', () {
    test('parses explicit values and defaults', () {
      final warnings = <String>[];
      final explicit = PubSubConfig.fromYaml({
        'project_id': 'my-gcp-project',
        'subscription': 'dartclaw-chat-pull',
        'poll_interval_seconds': 5,
        'max_messages_per_pull': 50,
      }, warnings);
      expect(warnings, isEmpty);
      expect(explicit.projectId, 'my-gcp-project');
      expect(explicit.subscription, 'dartclaw-chat-pull');
      expect(explicit.pollIntervalSeconds, 5);
      expect(explicit.maxMessagesPerPull, 50);

      final defaults = PubSubConfig.fromYaml({}, warnings);
      expect(defaults.projectId, isNull);
      expect(defaults.subscription, isNull);
      expect(defaults.pollIntervalSeconds, 2);
      expect(defaults.maxMessagesPerPull, 100);
    });

    final cases = <({String name, Map<String, Object?> yaml, _PubSubExpectation expectConfig})>[
      (
        name: 'configured',
        yaml: {'project_id': 'my-project', 'subscription': 'my-sub'},
        expectConfig: (config, warnings) => expect(config.isConfigured, isTrue),
      ),
      (
        name: 'missing project_id',
        yaml: {'subscription': 'my-sub'},
        expectConfig: (config, warnings) => expect(config.isConfigured, isFalse),
      ),
      (
        name: 'missing subscription',
        yaml: {'project_id': 'my-project'},
        expectConfig: (config, warnings) => expect(config.isConfigured, isFalse),
      ),
      (
        name: 'invalid types',
        yaml: {'project_id': 42, 'subscription': true},
        expectConfig: (config, warnings) {
          expect(warnings, hasLength(2));
          expect(warnings, contains(contains('google_chat.pubsub.project_id')));
          expect(warnings, contains(contains('google_chat.pubsub.subscription')));
        },
      ),
      (
        name: 'poll_interval_seconds minimum',
        yaml: {'poll_interval_seconds': 0},
        expectConfig: (config, warnings) {
          expect(config.pollIntervalSeconds, 1);
          expect(warnings, contains(contains('poll_interval_seconds')));
        },
      ),
      (
        name: 'max_messages_per_pull minimum',
        yaml: {'max_messages_per_pull': 0},
        expectConfig: (config, warnings) {
          expect(config.maxMessagesPerPull, 1);
          expect(warnings, contains(contains('max_messages_per_pull')));
        },
      ),
      (
        name: 'max_messages_per_pull maximum',
        yaml: {'max_messages_per_pull': 200},
        expectConfig: (config, warnings) {
          expect(config.maxMessagesPerPull, 100);
          expect(warnings, contains(contains('max_messages_per_pull')));
        },
      ),
    ];

    for (final testCase in cases) {
      test(testCase.name, () {
        final warnings = <String>[];
        final config = PubSubConfig.fromYaml(testCase.yaml, warnings);
        testCase.expectConfig(config, warnings);
      });
    }
  });

  group('SpaceEventsConfig.fromYaml', () {
    test('parses explicit values and defaults', () {
      final warnings = <String>[];
      final explicit = SpaceEventsConfig.fromYaml({
        'enabled': true,
        'pubsub_topic': 'projects/my-project/topics/dartclaw-chat-events',
        'event_types': ['message.created', 'message.updated'],
        'include_resource': false,
      }, warnings);
      expect(warnings, isEmpty);
      expect(explicit.enabled, isTrue);
      expect(explicit.pubsubTopic, 'projects/my-project/topics/dartclaw-chat-events');
      expect(explicit.eventTypes, ['message.created', 'message.updated']);
      expect(explicit.includeResource, isFalse);

      final defaults = SpaceEventsConfig.fromYaml({}, []);
      expect(defaults.enabled, isFalse);
      expect(defaults.pubsubTopic, isNull);
      expect(defaults.eventTypes, ['message.created']);
      expect(defaults.includeResource, isTrue);
    });

    final cases = <({String name, Map<String, Object?> yaml, _SpaceEventsExpectation expectConfig})>[
      (
        name: 'invalid enabled type',
        yaml: {'enabled': 'yes'},
        expectConfig: (config, warnings) {
          expect(config.enabled, isFalse);
          expect(warnings, contains(contains('space_events.enabled')));
        },
      ),
      (
        name: 'filters non-string event_types entries',
        yaml: {
          'event_types': [42, 'message.created', true],
        },
        expectConfig: (config, warnings) => expect(config.eventTypes, ['message.created']),
      ),
      (
        name: 'warns on retired auth_mode key',
        yaml: {'auth_mode': 'app'},
        expectConfig: (config, warnings) {
          expect(config.enabled, isFalse);
          expect(warnings, contains('Unknown config key: google_chat.space_events.auth_mode'));
        },
      ),
      (
        name: 'warns on non-list event_types',
        yaml: {'event_types': 'message.created'},
        expectConfig: (config, warnings) {
          expect(config.eventTypes, ['message.created']);
          expect(warnings, contains(contains('space_events.event_types')));
        },
      ),
    ];

    for (final testCase in cases) {
      test(testCase.name, () {
        final warnings = <String>[];
        final config = SpaceEventsConfig.fromYaml(testCase.yaml, warnings);
        testCase.expectConfig(config, warnings);
      });
    }

    test('derives user-auth scopes and unsupported event types', () {
      const config = SpaceEventsConfig(eventTypes: ['message.created', 'membership.updated', 'space.deleted']);
      expect(config.requiredUserAuthScopes, {
        'https://www.googleapis.com/auth/chat.messages.readonly',
        'https://www.googleapis.com/auth/chat.memberships.readonly',
        'https://www.googleapis.com/auth/chat.spaces.readonly',
      });

      const unsupportedConfig = SpaceEventsConfig(eventTypes: ['reaction.created', 'message.created']);
      expect(unsupportedConfig.unsupportedEventTypes, ['reaction.created']);
    });
  });

  group('Google Chat config registration', () {
    setUpAll(ensureDartclawGoogleChatRegistered);

    test('provider returns disabled defaults when package is imported', () {
      final config = DartclawConfig.load(fileReader: (_) => null, env: {'HOME': '/home/user'});
      final googleChatConfig = config.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat);

      expect(googleChatConfig.enabled, isFalse);
      expect(googleChatConfig.webhookPath, '/integrations/googlechat');
      expect(googleChatConfig.groupAccess, GroupAccessMode.disabled);
      expect(googleChatConfig.requireMention, isTrue);
      expect(googleChatConfig.taskTrigger.enabled, isFalse);
    });

    test('provider parses google chat config when package is imported', () {
      final config = DartclawConfig.load(
        configPath: 'dartclaw.yaml',
        fileReader: (path) => path == 'dartclaw.yaml'
            ? '''
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
'''
            : null,
        env: {'HOME': '/home/user'},
      );
      final googleChatConfig = config.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat);

      expect(googleChatConfig.enabled, isTrue);
      expect(googleChatConfig.serviceAccount, '/tmp/google-service-account.json');
      expect(googleChatConfig.audience!.mode, GoogleChatAudienceMode.appUrl);
      expect(googleChatConfig.botUser, 'users/123');
      expect(googleChatConfig.typingIndicatorMode, TypingIndicatorMode.disabled);
      expect(googleChatConfig.dmAccess, DmAccessMode.allowlist);
      expect(googleChatConfig.groupAccess, GroupAccessMode.open);
      expect(googleChatConfig.requireMention, isFalse);
      expect(googleChatConfig.taskTrigger.enabled, isTrue);
      expect(googleChatConfig.taskTrigger.prefix, 'do:');
      expect(googleChatConfig.taskTrigger.defaultType, 'custom');
      expect(googleChatConfig.taskTrigger.autoStart, isFalse);
    });

    test('channel config warnings are surfaced during load and cached', () {
      final config = DartclawConfig.load(
        configPath: 'dartclaw.yaml',
        fileReader: (path) => path == 'dartclaw.yaml'
            ? '''
channels:
  google_chat:
    enabled: true
    service_account: /tmp/google-service-account.json
    audience:
      type: app-url
      value: https://example.com/integrations/googlechat
    group_access: 123
'''
            : null,
        env: {'HOME': '/home/user'},
      );

      expect(config.warnings, anyElement(contains('Invalid type for google_chat.group_access')));
      config.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat);

      final warningCount = config.warnings.length;
      config.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat);
      expect(config.warnings, hasLength(warningCount));
    });

    test('provider parses pubsub and space_events sections', () {
      final config = DartclawConfig.load(
        configPath: 'dartclaw.yaml',
        fileReader: (path) => path == 'dartclaw.yaml'
            ? '''
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
'''
            : null,
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
    });
  });
}
