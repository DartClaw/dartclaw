/// Google Chat channel integration for DartClaw.
library;

export 'package:dartclaw_core/dartclaw_core.dart'
    show Channel, ChannelManager, ChannelResponse, DmAccessController, DmAccessMode, MentionGating;

export 'src/gcp_auth_service.dart' show GcpAuthService;
export 'src/chat_card_builder.dart' show ChatCardBuilder, cardDescriptionMaxLength;
export 'src/google_chat_channel.dart' show GoogleChatChannel;
export 'src/markdown_converter.dart' show markdownToGoogleChat, markdownToGoogleChatPlainText;
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
export 'src/google_chat_utils.dart' show asMap, isBotMessage, resolveGroupJid, resolveSpaceType, resolveMessageText;
export 'src/user_oauth_auth_service.dart' show UserOAuthAuthService;
export 'src/user_oauth_credential_store.dart' show StoredUserCredentials, UserOAuthCredentialStore;
export 'src/slash_command_executor.dart' show SlashCommandExecutor;
export 'src/google_chat_webhook.dart' show GoogleChatMessageDispatcher, GoogleChatWebhookHandler;
export 'src/google_chat_jwt_verifier.dart' show GoogleChatJwtVerifier;
export 'src/google_chat_space_events_wiring.dart' show GoogleChatSpaceEventsWiring;
export 'src/google_chat_subscription_routes.dart' show googleChatSubscriptionRoutes;
export 'src/space_events_auth.dart' show resolveSpaceEventsUserOAuthClient;
export 'src/google_oauth_setup.dart'
    show GoogleOAuthSetupException, parseGoogleOAuthClientCredentials, resolveGoogleOAuthScopes;
