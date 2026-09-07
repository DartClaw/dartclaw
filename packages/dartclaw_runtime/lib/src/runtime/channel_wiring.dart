import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartclaw_kernel/dartclaw_kernel.dart' as config_tools;
import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'channel_agent_binding.dart';
import 'channel_session_title.dart';
import 'feedback_observer_factory.dart';
import 'model_resolver.dart';
import 'reserved_command_handler.dart';
import 'storage_wiring.dart';
import 'task_wiring.dart';

/// Constructs and exposes channel-layer services.
///
/// Owns channel manager, WhatsApp, Signal, Google Chat (including Space Events),
/// task notification subscriber, and the dispatch helpers used by channel turns.
class ChannelWiring {
  new({
    required this.config,
    required String dataDir,
    required int port,
    required EventBus eventBus,
    required StorageWiring storage,
    required TaskWiring task,
    required String resolvedConfigPath,
    ChannelAgentBinder? agentBinder,
  }) : _dataDir = dataDir,
       _port = port,
       _eventBus = eventBus,
       _storage = storage,
       _task = task,
       _resolvedConfigPath = resolvedConfigPath,
       _agentBinder = agentBinder;

  final DartclawConfig config;
  final String _dataDir;
  final int _port;
  final EventBus _eventBus;
  final StorageWiring _storage;
  final TaskWiring _task;
  final String _resolvedConfigPath;
  final ChannelAgentBinder? _agentBinder;

  static final _log = Logger('ChannelWiring');

  ChannelManager? _channelManager;
  WhatsAppChannel? _whatsAppChannel;
  SignalChannel? _signalChannel;
  GoogleChatChannel? _googleChatChannel;
  GoogleChatWebhookHandler? _googleChatWebhookHandler;
  GoogleChatSpaceEventsWiring? _spaceEventsWiring;
  TaskNotificationSubscriber? _taskNotificationSubscriber;
  ThreadBindingStore? _threadBindingStore;
  PauseController? _pauseController;
  String? _webhookSecret;
  ChannelManager? _fallbackDeliveryChannelManager;
  List<ChannelGroupConfig>? _channelGroupConfigs;

  ChannelManager? get channelManager => _channelManager;
  WhatsAppChannel? get whatsAppChannel => _whatsAppChannel;
  SignalChannel? get signalChannel => _signalChannel;
  GoogleChatChannel? get googleChatChannel => _googleChatChannel;
  GoogleChatWebhookHandler? get googleChatWebhookHandler => _googleChatWebhookHandler;
  GoogleChatSpaceEventsWiring? get spaceEventsWiring => _spaceEventsWiring;
  TaskNotificationSubscriber? get taskNotificationSubscriber => _taskNotificationSubscriber;
  ThreadBindingStore? get threadBindingStore => _threadBindingStore;
  PauseController? get pauseController => _pauseController;
  String? get webhookSecret => _webhookSecret;
  ChannelManager? get fallbackDeliveryChannelManager => _fallbackDeliveryChannelManager;
  List<ChannelGroupConfig> get channelGroupConfigs => _channelGroupConfigs ?? const [];

  /// Wires channel services. [serverRefGetter] resolves lazily for dispatch
  /// closures that must reference the server after it is built.
  /// [turnManagerGetter] resolves lazily for emergency stop — the
  /// [TurnManager] is created after channel wiring but before any channel
  /// messages arrive, so lazy resolution is safe.
  Future<void> wire({
    required DartclawServer Function() serverRefGetter,
    required TurnManager Function() turnManagerGetter,
    required SseBroadcast sseBroadcast,
    required MessageRedactor? messageRedactor,
    required HealthService healthService,
    BudgetEnforcer? budgetEnforcer,
  }) async {
    final sessions = _storage.sessions;
    final messages = _storage.messages;
    final taskService = _storage.taskService;

    final reviewHandler = _task.reviewHandler;

    final googleChatConfig = resolveChannelConfig<GoogleChatConfig>(config, ChannelType.googlechat);
    final whatsAppConfig = resolveChannelConfig<WhatsAppConfig>(config, ChannelType.whatsapp);
    final signalConfig = resolveChannelConfig<SignalConfig>(config, ChannelType.signal);

    final googleChatEnabled = googleChatConfig.enabled;
    final waEnabled = whatsAppConfig.enabled;
    final sigEnabled = signalConfig.enabled;

    final liveScopeConfig = LiveScopeConfig(config.sessions.scopeConfig);

    // The one row lookup, built before the channel manager so the session-key
    // derivation and both dispatch sites consume the same rows.
    final rows = GroupConfigResolver.fromChannelEntries(
      {
        ChannelType.whatsapp: whatsAppConfig.groupAllowlist,
        ChannelType.signal: signalConfig.groupAllowlist,
        ChannelType.googlechat: googleChatConfig.groupAllowlist,
      },
      dms: {
        ChannelType.whatsapp: whatsAppConfig.dmAllowlist,
        ChannelType.signal: signalConfig.dmAllowlist,
        ChannelType.googlechat: googleChatConfig.dmAllowlist,
      },
    );

    // Initialize ThreadBindingStore if thread binding is enabled.
    final threadBindingEnabled = config.features.threadBinding.enabled;
    if (threadBindingEnabled) {
      final bindingsFile = File(p.join(_dataDir, 'thread-bindings.json'));
      final store = ThreadBindingStore(bindingsFile);
      await store.load();
      _threadBindingStore = store;
      _log.info('ThreadBindingStore initialized (features.thread_binding.enabled)');
    }

    if (waEnabled || sigEnabled || googleChatEnabled) {
      // Build per-sender rate limiter from governance config.
      final governance = config.governance;
      final perSenderLimiter = governance.rateLimits.perSender.enabled
          ? SlidingWindowRateLimiter(
              limit: governance.rateLimits.perSender.messages,
              window: Duration(minutes: governance.rateLimits.perSender.windowMinutes),
            )
          : null;

      // Build PauseController — in-memory pause state for admin /pause and /resume commands.
      final pauseController = PauseController();
      _pauseController = pauseController;

      _channelManager = _buildChannelManager(
        config: config,
        googleChatConfig: googleChatConfig,
        liveScopeConfig: liveScopeConfig,
        rows: rows,
        sessions: sessions,
        messages: messages,
        turnManagerGetter: turnManagerGetter,
        redactor: messageRedactor,
        pauseController: pauseController,
        taskBridge: ChannelTaskBridge(
          // Reserved command handler: /stop (and stop! for WA/Signal), /pause, /resume, /bind, /unbind.
          // TurnManager resolved lazily — created after channel wiring but
          // before any inbound channel messages can arrive.
          reservedCommandHandler: (message, channel) => ReservedCommandHandler.handle(
            message,
            channel,
            governance: governance,
            turnManagerGetter: turnManagerGetter,
            taskService: taskService,
            eventBus: _eventBus,
            sseBroadcast: sseBroadcast,
            pauseController: pauseController,
            replayPausedTurns: (collapsed) =>
                ReservedCommandHandler.drainPauseQueue(collapsed: collapsed, queue: _channelManager!.queue),
            threadBindingStore: _threadBindingStore,
          ),
          perSenderRateLimiter: perSenderLimiter,
          isAdmin: governance.isAdmin,
          isReservedCommand: isReservedChannelCommand,
          threadBindings: _threadBindingStore,
          threadBindingEnabled: threadBindingEnabled,
        ),
      );
    }

    if (waEnabled && _channelManager != null) {
      try {
        final webhookSecretBytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
        _webhookSecret = base64Url.encode(webhookSecretBytes).replaceAll('=', '');
        final webhookUrl = 'http://localhost:$_port/webhook/whatsapp?secret=$_webhookSecret';

        final gowaManager = GowaManager(
          executable: whatsAppConfig.gowaExecutable,
          host: whatsAppConfig.gowaHost,
          port: whatsAppConfig.gowaPort,
          dbUri: whatsAppConfig.gowaDbUri,
          webhookUrl: webhookUrl,
          osName: config.server.name,
        );
        final waChannel = WhatsAppChannel(
          gowa: gowaManager,
          config: whatsAppConfig,
          dmAccess: DmAccessController(mode: whatsAppConfig.dmAccess, allowlist: whatsAppConfig.dmIds.toSet()),
          mentionGating: MentionGating(
            requireMention: whatsAppConfig.requireMention,
            mentionPatterns: whatsAppConfig.mentionPatterns,
            ownJid: '',
          ),
          channelManager: _channelManager!,
        );
        _channelManager!.registerChannel(waChannel);
        _whatsAppChannel = waChannel;
        _log.info('WhatsApp channel registered');
      } catch (e) {
        _log.warning('Failed to initialize WhatsApp channel: $e');
      }
    }

    if (googleChatEnabled && _channelManager != null) {
      try {
        final activeChannelManager = _channelManager!;
        final audience = googleChatConfig.audience;
        if (audience == null) {
          throw StateError('Google Chat audience is required when the channel is enabled');
        }

        final credentialJson = await GcpAuthService.resolveCredentialJsonAsync(
          configValue: googleChatConfig.serviceAccount,
        );
        if (credentialJson == null) {
          throw StateError('Google Chat service account credentials could not be resolved');
        }

        final authClient = await GcpAuthService(
          serviceAccountJson: credentialJson,
          scopes: const ['https://www.googleapis.com/auth/chat.bot'],
        ).initialize();
        http.Client? reactionClient;
        if (googleChatConfig.reactionsAuth == ReactionsAuth.user) {
          final credentialStore = UserOAuthCredentialStore(dataDir: _dataDir);
          final userCredentials = credentialStore.load();
          if (userCredentials == null) {
            _log.warning(
              'reactions_auth is "user" but no user OAuth credentials found. '
              'Run "dartclaw google-auth" to authenticate. Continuing without a reactions user OAuth client.',
            );
          } else {
            final missingScopes = googleChatConfig.requiredReactionScopes.difference(userCredentials.scopes.toSet());
            if (missingScopes.isEmpty) {
              try {
                reactionClient = UserOAuthAuthService.createClient(credentials: userCredentials);
                _log.info('Google Chat reactions using user OAuth authentication');
              } catch (e) {
                _log.warning('Failed to create Google Chat reactions user OAuth client: $e');
              }
            } else {
              _log.warning(
                'Stored user OAuth credentials are missing required Google Chat reaction scopes: '
                '${missingScopes.join(', ')}. '
                'Run "dartclaw google-auth --force" to refresh them. Continuing without a reactions user OAuth client.',
              );
            }
          }
        }
        if (googleChatConfig.quoteReplyMode == QuoteReplyMode.native) {
          _log.warning(
            'quote_reply: native requires user-level auth (chat.messages.create scope) — '
            'the chat.bot service-account scope does not support quotedMessageMetadata. '
            'Consider quote_reply: text as an alternative that works with service accounts.',
          );
        }
        final googleChatDmAccess = DmAccessController(
          mode: googleChatConfig.dmAccess,
          allowlist: googleChatConfig.dmIds.toSet(),
        );
        final googleChatMentionGating = MentionGating(
          requireMention: googleChatConfig.requireMention,
          mentionPatterns: const [],
          ownJid: googleChatConfig.botUser ?? '',
        );
        final channel = GoogleChatChannel(
          config: googleChatConfig,
          restClient: GoogleChatRestClient(authClient: authClient, reactionClient: reactionClient),
          channelManager: activeChannelManager,
          dmAccess: googleChatDmAccess,
          mentionGating: googleChatMentionGating,
        );

        final slashCommandParser = const SlashCommandParser();
        final slashCommandHandler = SlashCommandHandler(
          taskService: taskService,
          sessionService: sessions,
          channelManager: activeChannelManager,
          budgetEnforcer: budgetEnforcer,
          pauseController: _pauseController,
          onEmergencyStop: (stoppedBy) => EmergencyStopHandler(
            turnManager: turnManagerGetter(),
            taskService: taskService,
            eventBus: _eventBus,
            sseBroadcast: sseBroadcast,
          ).execute(stoppedBy: stoppedBy),
          isAdmin: config.governance.isAdmin,
          onDrain: (collapsed) =>
              ReservedCommandHandler.drainPauseQueue(collapsed: collapsed, queue: activeChannelManager.queue),
        );

        // Phase 1: Create dedup + subscription manager before webhook handler.
        MessageDeduplicator? deduplicator;
        WorkspaceEventsManager? subscriptionManager;
        if (googleChatConfig.spaceEvents.enabled && googleChatConfig.pubsub.isConfigured) {
          // Workspace Events subscriptions authenticate solely via user OAuth.
          // On missing/insufficient credentials the helper logs an actionable
          // error and returns null; there is no service-account fallback.
          final spaceEventsAuthClient = resolveSpaceEventsUserOAuthClient(
            spaceEvents: googleChatConfig.spaceEvents,
            dataDir: _dataDir,
            log: _log,
          );
          if (spaceEventsAuthClient != null) {
            try {
              deduplicator = MessageDeduplicator();
              subscriptionManager = WorkspaceEventsManager(
                authClient: spaceEventsAuthClient,
                config: googleChatConfig.spaceEvents,
                dataDir: _dataDir,
                discoverSpaces: channel.restClient.listSpaces,
              );
              _log.info('Space Events infrastructure initialized (dedup + subscription manager)');
            } catch (e) {
              _log.warning('Failed to initialize Space Events infrastructure: $e – space events disabled');
              deduplicator = null;
              subscriptionManager = null;
            }
          }
        } else if (googleChatConfig.spaceEvents.enabled && !googleChatConfig.pubsub.isConfigured) {
          _log.warning(
            'space_events.enabled is true but pubsub is not configured – '
            'Space Events disabled. Configure pubsub.project_id and pubsub.subscription.',
          );
        }

        final webhookHandler = GoogleChatWebhookHandler(
          channel: channel,
          jwtVerifier: GoogleChatJwtVerifier(audience: audience),
          config: googleChatConfig,
          channelManager: activeChannelManager,
          reviewHandler: reviewHandler,
          dmAccess: googleChatDmAccess,
          mentionGating: googleChatMentionGating,
          eventBus: _eventBus,
          trustedProxies: config.auth.trustedProxies,
          slashCommandParser: slashCommandParser,
          slashCommandHandler: slashCommandHandler,
          deduplicator: deduplicator,
          subscriptionManager: subscriptionManager,
          dispatchMessage: (message) => _dispatchInboundChannelMessage(
            channelManager: activeChannelManager,
            sessions: sessions,
            messages: messages,
            serverRef: serverRefGetter,
            config: config,
            message: message,
            agentBinder: _agentBinder,
          ),
        );

        // Phase 2: Create PubSubClient + full space events wiring.
        // Pub/Sub pull only needs the pubsub scope (GCP IAM, not user delegation).
        if (deduplicator != null && subscriptionManager != null) {
          try {
            final adapter = CloudEventAdapter(botUser: googleChatConfig.botUser);
            final pubsubAuthClient = await GcpAuthService(
              serviceAccountJson: credentialJson,
              scopes: const ['https://www.googleapis.com/auth/pubsub'],
            ).initialize();
            final pubSubClient = PubSubClient.fromConfig(
              authClient: pubsubAuthClient,
              config: googleChatConfig.pubsub,
              onMessage: (message) async {
                final wiring = _spaceEventsWiring;
                if (wiring == null) return true;
                return wiring.processMessage(message);
              },
            );
            _spaceEventsWiring = GoogleChatSpaceEventsWiring(
              pubSubClient: pubSubClient,
              subscriptionManager: subscriptionManager,
              adapter: adapter,
              deduplicator: deduplicator,
              channelManager: activeChannelManager,
              channel: channel,
            );
            _log.info('Space Events Pub/Sub wiring created');

            // Inject Pub/Sub health reporter now that wiring is available.
            final activeSubManager = subscriptionManager;
            healthService.pubsubReporter = PubSubHealthReporter(
              client: pubSubClient,
              subscriptionCount: () => activeSubManager.activeSubscriptionCount,
              enabled: true,
            );
          } catch (e) {
            _log.warning('Failed to create Space Events Pub/Sub wiring: $e');
          }
        }

        activeChannelManager.registerChannel(channel);
        _googleChatChannel = channel;
        _googleChatWebhookHandler = webhookHandler;
        _log.info('Google Chat channel registered');
      } catch (e) {
        _log.warning('Failed to initialize Google Chat channel: $e');
      }
    }

    // Signal channel wiring — must come after Google Chat (configWriter needed).
    final configWriter = config_tools.ConfigWriter(configPath: _resolvedConfigPath);

    if (sigEnabled && _channelManager != null) {
      try {
        final sidecar = SignalCliManager(
          executable: signalConfig.executable,
          host: signalConfig.host,
          port: signalConfig.port,
          phoneNumber: signalConfig.phoneNumber,
          onRegistered: (phone) {
            _log.info('Signal: writing registered phone $phone to config');
            unawaited(
              configWriter
                  .updateFields({'channels.signal.phone_number': phone})
                  .catchError((Object e) => _log.warning('Failed to write Signal phone to config', e)),
            );
          },
        );

        final sigDmAccess = DmAccessController(mode: signalConfig.dmAccess, allowlist: signalConfig.dmIds.toSet());
        final sigMentionGating = MentionGating(
          requireMention: signalConfig.requireMention,
          mentionPatterns: signalConfig.mentionPatterns,
          ownJid: signalConfig.phoneNumber,
        );

        final sigChannel = SignalChannel(
          sidecar: sidecar,
          config: signalConfig,
          dmAccess: sigDmAccess,
          mentionGating: sigMentionGating,
          channelManager: _channelManager!,
          dataDir: _dataDir,
        );
        _channelManager!.registerChannel(sigChannel);
        _signalChannel = sigChannel;
        _log.info('Signal channel registered');
      } catch (e) {
        _log.warning('Failed to initialize Signal channel: $e');
      }
    }

    if (_channelManager != null) {
      _taskNotificationSubscriber = TaskNotificationSubscriber(
        tasks: taskService,
        channelManager: _channelManager!,
        threadBindings: _threadBindingStore,
        threadBindingEnabled: threadBindingEnabled,
        baseUrl: config.server.baseUrl,
      );
      _taskNotificationSubscriber!.subscribe(_eventBus);
    }

    // Build per-channel group configs for GroupSessionInitializer.
    final groupConfigs = <ChannelGroupConfig>[];
    if (_whatsAppChannel != null) {
      final waConf = _whatsAppChannel!.config;
      groupConfigs.add(
        ChannelGroupConfig(
          channelType: 'whatsapp',
          groupAccessEnabled: waConf.groupAccess != GroupAccessMode.disabled,
          groupEntries: waConf.groupAllowlist,
        ),
      );
    }
    if (_signalChannel != null) {
      final sigConf = _signalChannel!.config;
      groupConfigs.add(
        ChannelGroupConfig(
          channelType: 'signal',
          groupAccessEnabled: sigConf.groupAccess != GroupAccessMode.disabled,
          groupEntries: sigConf.groupAllowlist,
        ),
      );
    }
    if (_googleChatChannel != null) {
      final gcConf = _googleChatChannel!.config;
      groupConfigs.add(
        ChannelGroupConfig(
          channelType: 'googlechat',
          groupAccessEnabled: gcConf.groupAccess != GroupAccessMode.disabled,
          groupEntries: gcConf.groupAllowlist,
        ),
      );
    }
    _channelGroupConfigs = groupConfigs;
  }

  /// Builds the shared [ChannelManager] used by all messaging channels.
  ///
  /// The dispatcher resolves [turnManagerGetter] lazily because turns are
  /// wired after channels and before inbound messages can arrive.
  ChannelManager _buildChannelManager({
    required DartclawConfig config,
    required GoogleChatConfig googleChatConfig,
    required LiveScopeConfig liveScopeConfig,
    required GroupConfigResolver rows,
    required SessionService sessions,
    required MessageService messages,
    required TurnManager Function() turnManagerGetter,
    MessageRedactor? redactor,
    ChannelTaskBridge? taskBridge,
    PauseController? pauseController,
  }) {
    final messageQueue = MessageQueue(
      debounceWindow: config.channels.debounceWindow,
      maxConcurrentTurns: config.server.maxParallelTurns,
      maxQueueDepth: config.channels.maxQueueDepth,
      maxQueued: config.governance.rateLimits.perSender.maxQueued,
      defaultRetryPolicy: config.channels.defaultRetryPolicy,
      queueStrategy: config.governance.queueStrategy,
      redactor: redactor,
      isAdmin: config.governance.isAdmin,
      turnObserver: FeedbackObserverFactory.build(
        googleChatConfig: googleChatConfig,
        sessions: sessions,
        turnManagerGetter: turnManagerGetter,
      ),
      dispatcher:
          (
            sessionKey,
            message, {
            required ChannelType channelType,
            String? senderJid,
            String? senderDisplayName,
            String? groupJid,
          }) async {
            final row = rows.resolveRow(channelType, groupId: groupJid, peerId: senderJid);
            final overrides = resolveChannelTurnOverrides(sessionKey: sessionKey, config: config, row: row);
            return dispatchChannelTurn(
              sessions: sessions,
              messages: messages,
              turnManagerGetter: turnManagerGetter,
              sessionKey: sessionKey,
              message: message,
              channelType: channelType,
              senderJid: senderJid,
              senderDisplayName: senderDisplayName,
              groupJid: groupJid,
              model: overrides.model,
              effort: overrides.effort,
              binding: _agentBinder?.bind(row),
            );
          },
    );
    return ChannelManager(
      queue: messageQueue,
      config: config.channels,
      liveScopeConfig: liveScopeConfig,
      groupConfigResolver: rows,
      taskBridge: taskBridge,
      isPaused: pauseController != null ? () => pauseController.isPaused : null,
      enqueueForPause: pauseController != null
          ? (msg, ch, sk) =>
                pauseController.enqueue(
                  msg,
                  ch,
                  sk,
                  maxPauseQueued: config.governance.rateLimits.perSender.maxPauseQueued,
                  isAdmin: config.governance.isAdmin,
                ) ==
                QueueResult.queued
          : null,
      pausedByName: pauseController != null ? () => pauseController.pausedBy ?? 'admin' : null,
    );
  }

  static Future<String> _dispatchInboundChannelMessage({
    required ChannelManager channelManager,
    required SessionService sessions,
    required MessageService messages,
    required DartclawServer Function() serverRef,
    required DartclawConfig config,
    required ChannelMessage message,
    ChannelAgentBinder? agentBinder,
  }) {
    final sessionKey = channelManager.deriveSessionKey(message);
    final row = channelManager.resolveRow(message);
    final overrides = resolveChannelTurnOverrides(sessionKey: sessionKey, config: config, row: row);
    return dispatchChannelTurn(
      sessions: sessions,
      messages: messages,
      turnManagerGetter: () => serverRef().turns,
      sessionKey: sessionKey,
      message: message.text,
      channelType: message.channelType,
      senderJid: message.senderJid,
      senderDisplayName: message.senderDisplayName,
      groupJid: message.groupJid,
      model: overrides.model,
      effort: overrides.effort,
      binding: agentBinder?.bind(row),
    );
  }
}

/// Dispatches the shared human-facing channel turn path.
///
/// With a [binding] the session is created pinned to the agent's provider and
/// execution policy and the turn runs under the agent's name with the persona
/// as its behaviour – the logical-agent recipe, minus `systemPromptOverride`.
/// [model] and [effort] arrive resolved through the channel chain and win over
/// the agent's own. The getter is the runtime [TurnManager] because
/// `behaviorOverride` is a runtime type that `dartclaw_core`'s interface
/// cannot carry.
Future<String> dispatchChannelTurn({
  required SessionService sessions,
  required MessageService messages,
  required TurnManager Function() turnManagerGetter,
  required String sessionKey,
  required String message,
  required ChannelType channelType,
  String? senderJid,
  String? senderDisplayName,
  String? groupJid,
  String? model,
  String? effort,
  ChannelAgentBinding? binding,
}) async {
  final session = binding == null
      ? await sessions.getOrCreateByKey(sessionKey, type: SessionType.channel)
      : await sessions.getOrCreateByKey(
          sessionKey,
          type: SessionType.channel,
          provider: binding.providerId,
          securityProfile: binding.policy.containerProfile,
          executionMode: binding.policy.mode,
        );
  final metadata = senderDisplayName != null ? jsonEncode({'senderDisplayName': senderDisplayName}) : null;
  await messages.insertMessage(sessionId: session.id, role: 'user', content: message, metadata: metadata);

  if (session.title == null && senderJid != null) {
    await sessions.updateTitle(session.id, channelSessionTitle(channelType, senderJid));
  }

  // The current message is already persisted; pass full history so channel
  // continuity matches the web route.
  final history = await messages.getMessages(session.id);
  final messagesList = history.map((m) => <String, dynamic>{'role': m.role, 'content': m.content}).toList();

  final turns = turnManagerGetter();
  final origin = (channel: channelType.name, contact: senderDisplayName ?? senderJid, group: groupJid != null);
  final String turnId;
  if (binding == null) {
    turnId = await turns.startTurn(
      session.id,
      messagesList,
      source: 'channel',
      isHumanInput: true,
      model: model,
      effort: effort,
      promptScope: PromptScope.primary,
      origin: origin,
    );
  } else {
    final agent = binding.definition;
    turnId = await turns.reserveTurn(
      session.id,
      agentName: agent.id,
      model: model ?? _nonBlank(agent.model),
      effort: effort ?? _nonBlank(agent.effort),
      isHumanInput: true,
      behaviorOverride: binding.behavior,
      promptScope: binding.promptScope,
      origin: origin,
    );
    try {
      turns.executeTurn(session.id, turnId, messagesList, source: 'channel', agentName: agent.id);
    } catch (_) {
      turns.releaseTurn(session.id, turnId);
      rethrow;
    }
  }
  final outcome = await turns.waitForOutcome(session.id, turnId);
  return outcome.responseText ?? '';
}

String? _nonBlank(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
