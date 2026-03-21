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
export 'src/google_chat_config.dart'
    show GoogleChatAudienceConfig, GoogleChatAudienceMode, GoogleChatConfig, PubSubConfig, SpaceEventsConfig;
export 'src/google_chat_rest_client.dart' show GoogleChatApiException, GoogleChatRestClient;
export 'src/cloud_event_adapter.dart' show Acknowledged, AdapterResult, CloudEventAdapter, Filtered, LogOnly, MessageResult;
export 'src/pubsub_client.dart' show PubSubClient, PubSubHealthStatus, ReceivedMessage;
export 'src/pubsub_health_reporter.dart' show PubSubHealthReporter, SubscriptionCountGetter;
export 'src/workspace_events_manager.dart' show SubscriptionRecord, WorkspaceEventsManager;
export 'src/slash_command_parser.dart' show SlashCommand, SlashCommandParser;

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
