/// Google Chat channel integration for DartClaw.
library;

import 'package:dartclaw_core/dartclaw_core.dart' show ChannelType, DartclawConfig;

import 'src/google_chat_config.dart';

export 'package:dartclaw_core/dartclaw_core.dart'
    show
        Channel,
        ChannelManager,
        ChannelResponse,
        ChannelType,
        DmAccessController,
        DmAccessMode,
        GroupAccessMode,
        MentionGating,
        TaskTriggerConfig;
export 'src/gcp_auth_service.dart' show GcpAuthService;
export 'src/chat_card_builder.dart' show ChatCardBuilder, cardDescriptionMaxLength;
export 'src/google_chat_channel.dart' show GoogleChatChannel;
export 'src/markdown_converter.dart' show markdownToGoogleChat;
export 'src/google_chat_config.dart'
    show
        GoogleChatFeedbackConfig,
        GoogleChatFeedbackStatusStyle,
        GoogleChatAudienceConfig,
        GoogleChatAudienceMode,
        GoogleChatConfig,
        PubSubConfig,
        QuoteReplyMode,
        ReactionsAuth,
        SpaceEventsConfig,
        TypingIndicatorMode;
export 'src/google_chat_feedback_strategy.dart' show GoogleChatFeedbackStrategy;
export 'src/google_chat_rest_client.dart' show GoogleChatApiException, GoogleChatRestClient, typingIndicatorEmoji;
export 'src/cloud_event_adapter.dart'
    show Acknowledged, AdapterResult, CloudEventAdapter, Filtered, LogOnly, MessageResult;
export 'src/pubsub_client.dart' show PubSubClient, PubSubHealthStatus, ReceivedMessage;
export 'src/pubsub_health_reporter.dart' show PubSubHealthReporter, SubscriptionCountGetter;
export 'src/workspace_events_manager.dart' show SpaceDiscoveryCallback, SubscriptionRecord, WorkspaceEventsManager;
export 'src/slash_command_parser.dart' show SlashCommand, SlashCommandParser;
export 'src/google_chat_utils.dart' show asMap, isBotMessage, resolveGroupJid, resolveMessageText;
export 'src/user_oauth_auth_service.dart' show UserOAuthAuthService;
export 'src/user_oauth_credential_store.dart' show StoredUserCredentials, UserOAuthCredentialStore;

bool _registerGoogleChatConfigParser() {
  DartclawConfig.registerChannelConfigParser(
    ChannelType.googlechat,
    (yaml, warns) => GoogleChatConfig.fromYaml(yaml, warns),
  );
  return true;
}

final bool _googleChatConfigParserRegistered = _registerGoogleChatConfigParser();

/// Forces the library to stay initialized for parser registration.
void ensureDartclawGoogleChatRegistered() {
  if (!_googleChatConfigParserRegistered) {
    throw StateError('dartclaw_google_chat failed to register its channel config parser.');
  }
}
