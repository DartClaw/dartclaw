import 'package:dartclaw_core/dartclaw_core.dart' show DmAccessMode, GroupAccessMode, TaskTriggerConfig;

/// Configuration for the Cloud Pub/Sub pull client.
class PubSubConfig {
  /// GCP project ID.
  final String? projectId;

  /// Pub/Sub subscription name.
  final String? subscription;

  /// Poll interval in seconds.
  final int pollIntervalSeconds;

  /// Maximum number of messages to pull per request.
  final int maxMessagesPerPull;

  /// Creates immutable Cloud Pub/Sub pull client configuration.
  const PubSubConfig({this.projectId, this.subscription, this.pollIntervalSeconds = 2, this.maxMessagesPerPull = 100});

  /// Creates a disabled (all-defaults) Pub/Sub configuration.
  const PubSubConfig.disabled() : this();

  /// Whether both [projectId] and [subscription] are configured.
  bool get isConfigured =>
      projectId != null && projectId!.isNotEmpty && subscription != null && subscription!.isNotEmpty;

  /// Parses Pub/Sub configuration from YAML, appending warnings to [warns].
  factory PubSubConfig.fromYaml(Map<String, dynamic> yaml, List<String> warns) {
    final projectIdRaw = yaml['project_id'];
    String? projectId;
    if (projectIdRaw is String) {
      projectId = projectIdRaw;
    } else if (projectIdRaw != null) {
      warns.add('Invalid type for google_chat.pubsub.project_id: "${projectIdRaw.runtimeType}" — using default');
    }

    final subscriptionRaw = yaml['subscription'];
    String? subscription;
    if (subscriptionRaw is String) {
      subscription = subscriptionRaw;
    } else if (subscriptionRaw != null) {
      warns.add('Invalid type for google_chat.pubsub.subscription: "${subscriptionRaw.runtimeType}" — using default');
    }

    var pollIntervalSeconds = 2;
    final pollIntervalRaw = yaml['poll_interval_seconds'];
    if (pollIntervalRaw is int) {
      pollIntervalSeconds = pollIntervalRaw < 1 ? 1 : pollIntervalRaw;
      if (pollIntervalRaw < 1) {
        warns.add('google_chat.pubsub.poll_interval_seconds must be >= 1 — clamped to 1');
      }
    } else if (pollIntervalRaw != null) {
      warns.add(
        'Invalid type for google_chat.pubsub.poll_interval_seconds: "${pollIntervalRaw.runtimeType}" — using default',
      );
    }

    var maxMessagesPerPull = 100;
    final maxMessagesRaw = yaml['max_messages_per_pull'];
    if (maxMessagesRaw is int) {
      if (maxMessagesRaw < 1) {
        maxMessagesPerPull = 1;
        warns.add('google_chat.pubsub.max_messages_per_pull must be >= 1 — clamped to 1');
      } else if (maxMessagesRaw > 100) {
        maxMessagesPerPull = 100;
        warns.add('google_chat.pubsub.max_messages_per_pull must be <= 100 — clamped to 100');
      } else {
        maxMessagesPerPull = maxMessagesRaw;
      }
    } else if (maxMessagesRaw != null) {
      warns.add(
        'Invalid type for google_chat.pubsub.max_messages_per_pull: "${maxMessagesRaw.runtimeType}" — using default',
      );
    }

    return PubSubConfig(
      projectId: projectId,
      subscription: subscription,
      pollIntervalSeconds: pollIntervalSeconds,
      maxMessagesPerPull: maxMessagesPerPull,
    );
  }
}

/// Configuration for Workspace Events API subscriptions.
class SpaceEventsConfig {
  static const _qualifiedPrefix = 'google.workspace.chat.';
  static const _userMessageScope = 'https://www.googleapis.com/auth/chat.messages.readonly';
  static const _userMembershipScope = 'https://www.googleapis.com/auth/chat.memberships.readonly';
  static const _userSpaceScope = 'https://www.googleapis.com/auth/chat.spaces.readonly';
  static const _appMessageScope = 'https://www.googleapis.com/auth/chat.app.messages.readonly';
  static const _appMembershipScope = 'https://www.googleapis.com/auth/chat.app.memberships';
  static const _appSpaceScope = 'https://www.googleapis.com/auth/chat.app.spaces';

  /// Whether Workspace Events subscriptions are enabled.
  final bool enabled;

  /// Target Pub/Sub topic for Workspace Events notifications.
  final String? pubsubTopic;

  /// Event types to subscribe to.
  final List<String> eventTypes;

  /// Whether to include the full resource in event payloads.
  final bool includeResource;

  /// Auth mode: 'user' (GA) or 'app' (Developer Preview).
  final String authMode;

  /// Creates immutable Workspace Events subscription configuration.
  const SpaceEventsConfig({
    this.enabled = false,
    this.pubsubTopic,
    this.eventTypes = const ['message.created'],
    this.includeResource = true,
    this.authMode = 'user',
  });

  /// Creates a disabled (all-defaults) Space Events configuration.
  const SpaceEventsConfig.disabled() : this();

  /// Event types expanded to fully-qualified Workspace Events names.
  List<String> get expandedEventTypes => eventTypes.map(expandEventType).toList();

  /// OAuth scopes required for user auth with the configured [eventTypes].
  Set<String> get requiredUserAuthScopes => requiredUserAuthScopesFor(eventTypes);

  /// OAuth scopes required for app auth with the configured [eventTypes].
  Set<String> get requiredAppAuthScopes => requiredAppAuthScopesFor(eventTypes);

  /// Event types that this auth mode does not have a known scope mapping for.
  List<String> unsupportedEventTypesForAuthMode(String authMode) =>
      unsupportedEventTypesFor(eventTypes, authMode: authMode);

  /// Expands shorthand event types to fully-qualified Workspace Events names.
  static String expandEventType(String type) {
    if (type.startsWith(_qualifiedPrefix)) {
      return type;
    }
    final dotIndex = type.indexOf('.');
    if (dotIndex == -1) {
      return type;
    }
    final resource = type.substring(0, dotIndex);
    final action = type.substring(dotIndex + 1);
    return '$_qualifiedPrefix$resource.v1.$action';
  }

  /// Returns required user-auth scopes for the given [eventTypes].
  static Set<String> requiredUserAuthScopesFor(List<String> eventTypes) =>
      _requiredAuthScopesFor(eventTypes, appAuth: false);

  /// Returns required app-auth scopes for the given [eventTypes].
  static Set<String> requiredAppAuthScopesFor(List<String> eventTypes) =>
      _requiredAuthScopesFor(eventTypes, appAuth: true);

  /// Returns event types without a verified scope mapping for [authMode].
  static List<String> unsupportedEventTypesFor(List<String> eventTypes, {required String authMode}) {
    final appAuth = authMode == 'app';
    return eventTypes
        .where((type) => _scopeSetForResource(_resourceForEventType(type), appAuth: appAuth).isEmpty)
        .toList();
  }

  static Set<String> _requiredAuthScopesFor(List<String> eventTypes, {required bool appAuth}) {
    final scopes = <String>{};
    for (final type in eventTypes) {
      scopes.addAll(_scopeSetForResource(_resourceForEventType(type), appAuth: appAuth));
    }
    return scopes;
  }

  static String? _resourceForEventType(String type) {
    final expanded = expandEventType(type);
    if (!expanded.startsWith(_qualifiedPrefix)) {
      return null;
    }
    final remainder = expanded.substring(_qualifiedPrefix.length);
    final versionIndex = remainder.indexOf('.v1.');
    if (versionIndex == -1) {
      return null;
    }
    return remainder.substring(0, versionIndex);
  }

  static Set<String> _scopeSetForResource(String? resource, {required bool appAuth}) {
    return switch ((resource, appAuth)) {
      ('message', false) => {_userMessageScope},
      ('membership', false) => {_userMembershipScope},
      ('space', false) => {_userSpaceScope},
      ('message', true) => {_appMessageScope},
      ('membership', true) => {_appMembershipScope},
      ('space', true) => {_appSpaceScope},
      _ => const <String>{},
    };
  }

  /// Parses Space Events configuration from YAML, appending warnings to [warns].
  factory SpaceEventsConfig.fromYaml(Map<String, dynamic> yaml, List<String> warns) {
    var enabled = false;
    final enabledRaw = yaml['enabled'];
    if (enabledRaw is bool) {
      enabled = enabledRaw;
    } else if (enabledRaw != null) {
      warns.add('Invalid type for google_chat.space_events.enabled: "${enabledRaw.runtimeType}" — using default');
    }

    final pubsubTopicRaw = yaml['pubsub_topic'];
    String? pubsubTopic;
    if (pubsubTopicRaw is String) {
      pubsubTopic = pubsubTopicRaw;
    } else if (pubsubTopicRaw != null) {
      warns.add(
        'Invalid type for google_chat.space_events.pubsub_topic: "${pubsubTopicRaw.runtimeType}" — using default',
      );
    }

    var eventTypes = const <String>['message.created'];
    final eventTypesRaw = yaml['event_types'];
    if (eventTypesRaw is List) {
      eventTypes = eventTypesRaw.whereType<String>().toList();
    } else if (eventTypesRaw != null) {
      warns.add(
        'Invalid type for google_chat.space_events.event_types: "${eventTypesRaw.runtimeType}" — using default',
      );
    }

    var includeResource = true;
    final includeResourceRaw = yaml['include_resource'];
    if (includeResourceRaw is bool) {
      includeResource = includeResourceRaw;
    } else if (includeResourceRaw != null) {
      warns.add(
        'Invalid type for google_chat.space_events.include_resource: "${includeResourceRaw.runtimeType}" — using default',
      );
    }

    var authMode = 'user';
    final authModeRaw = yaml['auth_mode'];
    if (authModeRaw is String) {
      if (authModeRaw == 'user' || authModeRaw == 'app') {
        authMode = authModeRaw;
      } else {
        warns.add('Invalid value for google_chat.space_events.auth_mode: "$authModeRaw" — using default');
      }
    } else if (authModeRaw != null) {
      warns.add('Invalid type for google_chat.space_events.auth_mode: "${authModeRaw.runtimeType}" — using default');
    }

    return SpaceEventsConfig(
      enabled: enabled,
      pubsubTopic: pubsubTopic,
      eventTypes: eventTypes,
      includeResource: includeResource,
      authMode: authMode,
    );
  }
}

/// Audience format used when validating Google Chat JWT tokens.
enum GoogleChatAudienceMode {
  /// Audience is the HTTPS app URL configured for the Chat app.
  appUrl,

  /// Audience is the numeric Google Cloud project number.
  projectNumber,
}

/// Audience settings required to validate Google Chat signed requests.
class GoogleChatAudienceConfig {
  /// Expected audience format.
  final GoogleChatAudienceMode mode;

  /// Concrete expected audience value.
  final String value;

  /// Creates immutable Google Chat audience settings.
  const GoogleChatAudienceConfig({required this.mode, required this.value});
}

/// Runtime configuration for the Google Chat channel integration.
class GoogleChatConfig {
  /// Whether the Google Chat integration is enabled.
  final bool enabled;

  /// Service-account JSON or filesystem path used for API authentication.
  final String? serviceAccount;

  /// Optional OAuth client credentials JSON path for user auth bootstrap.
  final String? oauthCredentials;

  /// Audience settings used to validate inbound Google Chat JWTs.
  final GoogleChatAudienceConfig? audience;

  /// HTTP path where the webhook endpoint is mounted.
  final String webhookPath;

  /// Optional bot user resource name used for mention detection.
  final String? botUser;

  /// Whether the server should create and replace typing placeholders.
  final bool typingIndicator;

  /// Direct-message access policy for one-to-one Google Chat spaces.
  final DmAccessMode dmAccess;

  /// Approved direct-message space identifiers when [dmAccess] is restricted.
  final List<String> dmAllowlist;

  /// Group-space access policy.
  final GroupAccessMode groupAccess;

  /// Approved group space identifiers when [groupAccess] is restricted.
  final List<String> groupAllowlist;

  /// Whether group messages must mention the bot.
  final bool requireMention;

  /// Per-channel task trigger configuration.
  final TaskTriggerConfig taskTrigger;

  /// Cloud Pub/Sub pull client configuration.
  final PubSubConfig pubsub;

  /// Workspace Events subscription configuration.
  final SpaceEventsConfig spaceEvents;

  /// Creates immutable Google Chat channel configuration.
  const GoogleChatConfig({
    this.enabled = false,
    this.serviceAccount,
    this.oauthCredentials,
    this.audience,
    this.webhookPath = '/integrations/googlechat',
    this.botUser,
    this.typingIndicator = true,
    this.dmAccess = DmAccessMode.pairing,
    this.dmAllowlist = const [],
    this.groupAccess = GroupAccessMode.disabled,
    this.groupAllowlist = const [],
    this.requireMention = true,
    this.taskTrigger = const TaskTriggerConfig.disabled(),
    this.pubsub = const PubSubConfig.disabled(),
    this.spaceEvents = const SpaceEventsConfig.disabled(),
  });

  /// Creates a disabled Google Chat configuration.
  const GoogleChatConfig.disabled() : this();

  /// Parses Google Chat configuration from YAML, appending warnings to [warns].
  factory GoogleChatConfig.fromYaml(Map<String, dynamic> yaml, List<String> warns) {
    final enabled = yaml['enabled'];
    if (enabled != null && enabled is! bool) {
      warns.add('Invalid type for google_chat.enabled: "${enabled.runtimeType}" — using default');
    }

    final serviceAccount = yaml['service_account'];
    if (serviceAccount != null && serviceAccount is! String) {
      warns.add('Invalid type for google_chat.service_account: "${serviceAccount.runtimeType}" — using default');
    }

    final oauthCredentials = yaml['oauth_credentials'];
    if (oauthCredentials != null && oauthCredentials is! String) {
      warns.add('Invalid type for google_chat.oauth_credentials: "${oauthCredentials.runtimeType}" — using default');
    }

    final audience = _parseAudience(yaml['audience'], warns);
    final webhookPath = yaml['webhook_path'];
    if (webhookPath != null && webhookPath is! String) {
      warns.add('Invalid type for google_chat.webhook_path: "${webhookPath.runtimeType}" — using default');
    }

    final botUser = yaml['bot_user'];
    if (botUser != null && botUser is! String) {
      warns.add('Invalid type for google_chat.bot_user: "${botUser.runtimeType}" — using default');
    }

    var typingIndicator = true;
    final typingIndicatorRaw = yaml['typing_indicator'];
    if (typingIndicatorRaw is bool) {
      typingIndicator = typingIndicatorRaw;
    } else if (typingIndicatorRaw != null) {
      warns.add('Invalid type for google_chat.typing_indicator: "${typingIndicatorRaw.runtimeType}" — using default');
    }

    var dmAccess = DmAccessMode.pairing;
    final dmAccessRaw = yaml['dm_access'];
    if (dmAccessRaw is String) {
      final parsed = DmAccessMode.values.where((value) => value.name == dmAccessRaw).firstOrNull;
      if (parsed != null) {
        dmAccess = parsed;
      } else {
        warns.add('Invalid google_chat.dm_access: "$dmAccessRaw" — using default');
      }
    } else if (dmAccessRaw != null) {
      warns.add('Invalid type for google_chat.dm_access: "${dmAccessRaw.runtimeType}" — using default');
    }

    var groupAccess = GroupAccessMode.disabled;
    final groupAccessRaw = yaml['group_access'];
    if (groupAccessRaw is String) {
      final parsed = GroupAccessMode.values.where((value) => value.name == groupAccessRaw).firstOrNull;
      if (parsed != null) {
        groupAccess = parsed;
      } else {
        warns.add('Invalid google_chat.group_access: "$groupAccessRaw" — using default');
      }
    } else if (groupAccessRaw != null) {
      warns.add('Invalid type for google_chat.group_access: "${groupAccessRaw.runtimeType}" — using default');
    }

    var requireMention = true;
    final requireMentionRaw = yaml['require_mention'];
    if (requireMentionRaw is bool) {
      requireMention = requireMentionRaw;
    } else if (requireMentionRaw != null) {
      warns.add('Invalid type for google_chat.require_mention: "${requireMentionRaw.runtimeType}" — using default');
    }

    var taskTrigger = const TaskTriggerConfig.disabled();
    final taskTriggerRaw = yaml['task_trigger'];
    if (taskTriggerRaw is Map) {
      taskTrigger = TaskTriggerConfig.fromYaml(Map<String, dynamic>.from(taskTriggerRaw), warns);
    } else if (taskTriggerRaw != null) {
      warns.add('Invalid type for google_chat.task_trigger: "${taskTriggerRaw.runtimeType}" — using default');
    }

    var pubsub = const PubSubConfig.disabled();
    final pubsubRaw = yaml['pubsub'];
    if (pubsubRaw is Map) {
      pubsub = PubSubConfig.fromYaml(Map<String, dynamic>.from(pubsubRaw), warns);
    } else if (pubsubRaw != null) {
      warns.add('Invalid type for google_chat.pubsub: "${pubsubRaw.runtimeType}" — using default');
    }

    var spaceEvents = const SpaceEventsConfig.disabled();
    final spaceEventsRaw = yaml['space_events'];
    if (spaceEventsRaw is Map) {
      spaceEvents = SpaceEventsConfig.fromYaml(Map<String, dynamic>.from(spaceEventsRaw), warns);
    } else if (spaceEventsRaw != null) {
      warns.add('Invalid type for google_chat.space_events: "${spaceEventsRaw.runtimeType}" — using default');
    }

    final normalizedServiceAccount = serviceAccount is String ? serviceAccount.trim() : null;
    final parsedServiceAccount = normalizedServiceAccount == null || normalizedServiceAccount.isEmpty
        ? null
        : normalizedServiceAccount;
    final normalizedOauthCredentials = oauthCredentials is String ? oauthCredentials.trim() : null;
    final parsedOauthCredentials = normalizedOauthCredentials == null || normalizedOauthCredentials.isEmpty
        ? null
        : normalizedOauthCredentials;
    final parsedEnabled = enabled is bool ? enabled : false;
    if (parsedEnabled && parsedServiceAccount == null) {
      warns.add('Missing required google_chat.service_account when channel is enabled');
    }
    if (parsedEnabled && audience == null) {
      warns.add('Missing or invalid google_chat.audience when channel is enabled');
    }

    if (spaceEvents.enabled) {
      if (pubsub.projectId == null || pubsub.projectId!.trim().isEmpty) {
        warns.add('Missing required google_chat.pubsub.project_id when space_events is enabled');
      }
      if (pubsub.subscription == null || pubsub.subscription!.trim().isEmpty) {
        warns.add('Missing required google_chat.pubsub.subscription when space_events is enabled');
      }
      if (spaceEvents.pubsubTopic == null || spaceEvents.pubsubTopic!.trim().isEmpty) {
        warns.add('Missing required google_chat.space_events.pubsub_topic when space_events is enabled');
      }
      if (spaceEvents.authMode == 'app') {
        warns.add(
          'google_chat.space_events.auth_mode "app" uses service account auth (Developer Preview) — '
          'requires Workspace admin approval. Consider auth_mode: user (GA, no admin approval)',
        );
      }
      final unsupportedEventTypes = spaceEvents.unsupportedEventTypesForAuthMode(spaceEvents.authMode);
      if (unsupportedEventTypes.isNotEmpty) {
        warns.add(
          'google_chat.space_events.event_types ${unsupportedEventTypes.join(', ')} do not have '
          'a supported scope mapping for auth_mode "${spaceEvents.authMode}"',
        );
      }
    }

    return GoogleChatConfig(
      enabled: parsedEnabled,
      serviceAccount: parsedServiceAccount,
      oauthCredentials: parsedOauthCredentials,
      audience: audience,
      webhookPath: webhookPath is String ? webhookPath : '/integrations/googlechat',
      botUser: botUser is String ? botUser : null,
      typingIndicator: typingIndicator,
      dmAccess: dmAccess,
      dmAllowlist: _parseStringList(yaml['dm_allowlist']),
      groupAccess: groupAccess,
      groupAllowlist: _parseStringList(yaml['group_allowlist']),
      requireMention: requireMention,
      taskTrigger: taskTrigger,
      pubsub: pubsub,
      spaceEvents: spaceEvents,
    );
  }

  static GoogleChatAudienceConfig? _parseAudience(Object? raw, List<String> warns) {
    if (raw == null) {
      return null;
    }
    if (raw is! Map) {
      warns.add('Invalid type for google_chat.audience: "${raw.runtimeType}" — using default');
      return null;
    }

    final type = raw['type'];
    if (type != null && type is! String) {
      warns.add('Invalid type for google_chat.audience.type: "${type.runtimeType}" — using default');
    }

    final value = raw['value'];
    if (value != null && value is! String) {
      warns.add('Invalid type for google_chat.audience.value: "${value.runtimeType}" — using default');
    }

    final mode = switch (type) {
      'app-url' => GoogleChatAudienceMode.appUrl,
      'project-number' => GoogleChatAudienceMode.projectNumber,
      null => null,
      _ => () {
        warns.add('Invalid google_chat.audience.type: "$type" — using default');
        return null;
      }(),
    };
    final normalizedValue = value is String ? value.trim() : null;
    if (mode == null || normalizedValue == null || normalizedValue.isEmpty) {
      return null;
    }

    return GoogleChatAudienceConfig(mode: mode, value: normalizedValue);
  }

  static List<String> _parseStringList(Object? raw) {
    if (raw is List) {
      return raw.whereType<String>().toList();
    }
    return [];
  }
}
