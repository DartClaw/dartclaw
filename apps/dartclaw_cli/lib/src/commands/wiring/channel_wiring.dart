import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartclaw_config/dartclaw_config.dart' as config_tools;
import 'package:http/http.dart' as http;
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'storage_wiring.dart';
import 'task_wiring.dart';

/// Constructs and exposes channel-layer services.
///
/// Owns channel manager, WhatsApp, Signal, Google Chat (including Space Events),
/// task notification subscriber, and the dispatch helpers used by channel turns.
class ChannelWiring {
  ChannelWiring({
    required this.config,
    required String dataDir,
    required int port,
    required EventBus eventBus,
    required StorageWiring storage,
    required TaskWiring task,
    required String resolvedConfigPath,
  }) : _dataDir = dataDir,
       _port = port,
       _eventBus = eventBus,
       _storage = storage,
       _task = task,
       _resolvedConfigPath = resolvedConfigPath;

  final DartclawConfig config;
  final String _dataDir;
  final int _port;
  final EventBus _eventBus;
  final StorageWiring _storage;
  final TaskWiring _task;
  final String _resolvedConfigPath;

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

    // Parse channel configs
    final waConfig = config.channels.channelConfigs['whatsapp'];
    final sigConfig = config.channels.channelConfigs['signal'];
    final googleChatConfig = config.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat);

    WhatsAppConfig? parsedWhatsAppConfig;
    SignalConfig? parsedSignalConfig;
    if (waConfig != null) {
      final warns = <String>[];
      parsedWhatsAppConfig = WhatsAppConfig.fromYaml(waConfig, warns);
      for (final w in warns) {
        _log.warning(w);
      }
    }
    if (sigConfig != null) {
      final warns = <String>[];
      parsedSignalConfig = SignalConfig.fromYaml(sigConfig, warns);
      for (final w in warns) {
        _log.warning('Signal config: $w');
      }
    }

    final googleChatEnabled = googleChatConfig.enabled;
    final waEnabled = parsedWhatsAppConfig?.enabled ?? false;
    final sigEnabled = parsedSignalConfig?.enabled ?? false;

    final taskTriggerConfigs = <ChannelType, TaskTriggerConfig>{
      if (parsedWhatsAppConfig != null) ChannelType.whatsapp: parsedWhatsAppConfig.taskTrigger,
      if (parsedSignalConfig != null) ChannelType.signal: parsedSignalConfig.taskTrigger,
      ChannelType.googlechat: googleChatConfig.taskTrigger,
    };

    final liveScopeConfig = LiveScopeConfig(config.sessions.scopeConfig);

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
        liveScopeConfig: liveScopeConfig,
        sessions: sessions,
        messages: messages,
        serverRef: serverRefGetter,
        redactor: messageRedactor,
        pauseController: pauseController,
        taskBridge: ChannelTaskBridge(
          // Reserved command handler: /stop (and stop! for WA/Signal), /pause, /resume.
          // TurnManager resolved lazily — created after channel wiring but
          // before any inbound channel messages can arrive.
          reservedCommandHandler: (message, channel) => _handleReservedCommand(
            message,
            channel,
            governance: governance,
            turnManagerGetter: turnManagerGetter,
            taskService: taskService,
            eventBus: _eventBus,
            sseBroadcast: sseBroadcast,
            pauseController: pauseController,
            sessions: sessions,
          ),
          taskCreator: taskService.create,
          taskLister: taskService.list,
          reviewCommandParser: const ReviewCommandParser(),
          reviewHandler: reviewHandler,
          triggerParser: const TaskTriggerParser(),
          taskTriggerConfigs: taskTriggerConfigs,
          perSenderRateLimiter: perSenderLimiter,
          isAdmin: governance.isAdmin,
          isReservedCommand: (text) {
            final lower = text.trim().toLowerCase();
            return lower == '/stop' ||
                lower.startsWith('/stop ') ||
                lower == 'stop!' ||
                lower.startsWith('/status') ||
                lower.startsWith('/pause') ||
                lower.startsWith('/resume');
          },
          threadBindings: _threadBindingStore,
          threadBindingEnabled: threadBindingEnabled,
        ),
      );
    }

    if (waEnabled && _channelManager != null) {
      try {
        final parsedConfig = parsedWhatsAppConfig!;
        final webhookSecretBytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
        _webhookSecret = base64Url.encode(webhookSecretBytes).replaceAll('=', '');
        final webhookUrl = 'http://localhost:$_port/webhook/whatsapp?secret=$_webhookSecret';

        final gowaManager = GowaManager(
          executable: parsedConfig.gowaExecutable,
          host: parsedConfig.gowaHost,
          port: parsedConfig.gowaPort,
          dbUri: parsedConfig.gowaDbUri,
          webhookUrl: webhookUrl,
          osName: config.server.name,
        );
        final waChannel = WhatsAppChannel(
          gowa: gowaManager,
          config: parsedConfig,
          dmAccess: DmAccessController(mode: parsedConfig.dmAccess, allowlist: parsedConfig.dmAllowlist.toSet()),
          mentionGating: MentionGating(
            requireMention: parsedConfig.requireMention,
            mentionPatterns: parsedConfig.mentionPatterns,
            ownJid: '',
          ),
          channelManager: _channelManager!,
          workspaceDir: config.workspaceDir,
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
        final googleChatDmAccess = DmAccessController(
          mode: googleChatConfig.dmAccess,
          allowlist: googleChatConfig.dmAllowlist.toSet(),
        );
        final googleChatMentionGating = MentionGating(
          requireMention: googleChatConfig.requireMention,
          mentionPatterns: const [],
          ownJid: googleChatConfig.botUser ?? '',
        );
        final channel = GoogleChatChannel(
          config: googleChatConfig,
          restClient: GoogleChatRestClient(authClient: authClient),
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
              _drainPauseQueue(collapsed: collapsed, sessions: sessions, turnManagerGetter: turnManagerGetter),
          defaultTaskType: googleChatConfig.taskTrigger.defaultType,
          autoStartTasks: googleChatConfig.taskTrigger.autoStart,
        );

        // Phase 1: Create dedup + subscription manager before webhook handler.
        MessageDeduplicator? deduplicator;
        WorkspaceEventsManager? subscriptionManager;
        if (googleChatConfig.spaceEvents.enabled && googleChatConfig.pubsub.isConfigured) {
          try {
            deduplicator = MessageDeduplicator();

            // Create auth client for Workspace Events subscription management.
            // User OAuth (GA) is preferred; service account (Developer Preview) is fallback.
            http.Client? spaceEventsAuthClient;
            if (googleChatConfig.spaceEvents.authMode == 'user') {
              final credentialStore = UserOAuthCredentialStore(dataDir: _dataDir);
              final userCredentials = credentialStore.load();
              if (userCredentials != null) {
                final requiredScopes = googleChatConfig.spaceEvents.requiredUserAuthScopes;
                final missingScopes = requiredScopes.difference(userCredentials.scopes.toSet());
                try {
                  if (missingScopes.isEmpty) {
                    spaceEventsAuthClient = UserOAuthAuthService.createClient(credentials: userCredentials);
                    _log.info('Space Events using user OAuth authentication');
                  } else {
                    _log.warning(
                      'Stored user OAuth credentials are missing required scopes for the configured '
                      'space_events.event_types: ${missingScopes.join(', ')}. '
                      'Run "dartclaw google-auth --force" to refresh them. Falling back to service account auth.',
                    );
                  }
                } catch (e) {
                  _log.warning('Failed to create user OAuth client: $e — falling back to service account');
                }
              } else {
                _log.warning(
                  'space_events.auth_mode is "user" but no user OAuth credentials found. '
                  'Run "dartclaw google-auth" to authenticate, or set auth_mode: app. '
                  'Falling back to service account auth.',
                );
              }
            }

            // Fall back to service account auth.
            spaceEventsAuthClient ??= await GcpAuthService(
              serviceAccountJson: credentialJson,
              scopes: <String>[
                'https://www.googleapis.com/auth/chat.bot',
                'https://www.googleapis.com/auth/chat.spaces.readonly',
                ...googleChatConfig.spaceEvents.requiredAppAuthScopes,
              ],
            ).initialize();

            subscriptionManager = WorkspaceEventsManager(
              authClient: spaceEventsAuthClient,
              config: googleChatConfig.spaceEvents,
              dataDir: _dataDir,
            );
            _log.info('Space Events infrastructure initialized (dedup + subscription manager)');
          } catch (e) {
            _log.warning('Failed to initialize Space Events infrastructure: $e — space events disabled');
            deduplicator = null;
            subscriptionManager = null;
          }
        } else if (googleChatConfig.spaceEvents.enabled && !googleChatConfig.pubsub.isConfigured) {
          _log.warning(
            'space_events.enabled is true but pubsub is not configured — '
            'Space Events disabled. Configure pubsub.project_id and pubsub.subscription.',
          );
        }

        final webhookHandler = GoogleChatWebhookHandler(
          channel: channel,
          jwtVerifier: GoogleJwtVerifier(audience: audience),
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
            message: message,
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
        final activeSignalConfig = parsedSignalConfig!;

        final sidecar = SignalCliManager(
          executable: activeSignalConfig.executable,
          host: activeSignalConfig.host,
          port: activeSignalConfig.port,
          phoneNumber: activeSignalConfig.phoneNumber,
          onRegistered: (phone) {
            _log.info('Signal: writing registered phone $phone to config');
            unawaited(
              configWriter
                  .updateFields({'channels.signal.phone_number': phone})
                  .catchError((Object e) => _log.warning('Failed to write Signal phone to config', e)),
            );
          },
        );

        final sigDmAccess = DmAccessController(
          mode: activeSignalConfig.dmAccess,
          allowlist: activeSignalConfig.dmAllowlist.toSet(),
        );
        final sigMentionGating = SignalMentionGating(
          requireMention: activeSignalConfig.requireMention,
          mentionPatterns: activeSignalConfig.mentionPatterns,
          ownNumber: activeSignalConfig.phoneNumber,
        );

        final sigChannel = SignalChannel(
          sidecar: sidecar,
          config: activeSignalConfig,
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
          groupAllowlist: waConf.groupAllowlist,
        ),
      );
    }
    if (_signalChannel != null) {
      final sigConf = _signalChannel!.config;
      groupConfigs.add(
        ChannelGroupConfig(
          channelType: 'signal',
          groupAccessEnabled: sigConf.groupAccess != SignalGroupAccessMode.disabled,
          groupAllowlist: sigConf.groupAllowlist,
        ),
      );
    }
    if (_googleChatChannel != null) {
      final gcConf = _googleChatChannel!.config;
      groupConfigs.add(
        ChannelGroupConfig(
          channelType: 'googlechat',
          groupAccessEnabled: gcConf.groupAccess != GroupAccessMode.disabled,
          groupAllowlist: gcConf.groupAllowlist,
        ),
      );
    }
    _channelGroupConfigs = groupConfigs;
  }

  /// Builds the shared [ChannelManager] used by all messaging channels.
  ///
  /// The dispatcher closure captures [serverRef] (a lazy callback) so the
  /// server reference is resolved at dispatch time, after it's been assigned.
  ChannelManager _buildChannelManager({
    required DartclawConfig config,
    required LiveScopeConfig liveScopeConfig,
    required SessionService sessions,
    required MessageService messages,
    required DartclawServer Function() serverRef,
    MessageRedactor? redactor,
    ChannelTaskBridge? taskBridge,
    PauseController? pauseController,
  }) {
    final messageQueue = MessageQueue(
      debounceWindow: config.channels.debounceWindow,
      maxConcurrentTurns: config.server.maxParallelTurns,
      maxQueueDepth: config.channels.maxQueueDepth,
      defaultRetryPolicy: config.channels.defaultRetryPolicy,
      redactor: redactor,
      dispatcher: (sessionKey, message, {String? senderJid, String? senderDisplayName}) async {
        return _dispatchChannelTurn(
          sessions: sessions,
          messages: messages,
          serverRef: serverRef,
          sessionKey: sessionKey,
          message: message,
          senderJid: senderJid,
          senderDisplayName: senderDisplayName,
        );
      },
    );
    return ChannelManager(
      queue: messageQueue,
      config: config.channels,
      liveScopeConfig: liveScopeConfig,
      taskBridge: taskBridge,
      isPaused: pauseController != null ? () => pauseController.isPaused : null,
      enqueueForPause: pauseController != null
          ? (msg, ch, sk) => pauseController.enqueue(msg, ch, sk) == QueueResult.queued
          : null,
      pausedByName: pauseController != null ? () => pauseController.pausedBy ?? 'admin' : null,
    );
  }

  static Future<String> _dispatchInboundChannelMessage({
    required ChannelManager channelManager,
    required SessionService sessions,
    required MessageService messages,
    required DartclawServer Function() serverRef,
    required ChannelMessage message,
  }) {
    return _dispatchChannelTurn(
      sessions: sessions,
      messages: messages,
      serverRef: serverRef,
      sessionKey: channelManager.deriveSessionKey(message),
      message: message.text,
      senderJid: message.senderJid,
      senderDisplayName: message.senderDisplayName,
    );
  }

  static Future<String> _dispatchChannelTurn({
    required SessionService sessions,
    required MessageService messages,
    required DartclawServer Function() serverRef,
    required String sessionKey,
    required String message,
    String? senderJid,
    String? senderDisplayName,
  }) async {
    final session = await sessions.getOrCreateByKey(sessionKey, type: SessionType.channel);
    final metadata = senderDisplayName != null ? jsonEncode({'senderDisplayName': senderDisplayName}) : null;
    await messages.insertMessage(sessionId: session.id, role: 'user', content: message, metadata: metadata);

    if (session.title == null && senderJid != null) {
      await sessions.updateTitle(session.id, _channelSessionTitle(senderJid));
    }

    final userMsg = <String, dynamic>{'role': 'user', 'content': message};
    final srv = serverRef();
    final turnId = await srv.turns.startTurn(session.id, [userMsg], source: 'channel', isHumanInput: true);
    final outcome = await srv.turns.waitForOutcome(session.id, turnId);
    return outcome.responseText ?? '';
  }

  /// Handles reserved commands: `/stop` (and `stop!`), `/pause`, `/resume`.
  ///
  /// Returns a non-null string when the command was consumed (handled or
  /// rejected). Returns null when the message is not a recognized reserved command.
  static Future<String?> _handleReservedCommand(
    ChannelMessage message,
    Channel channel, {
    required GovernanceConfig governance,
    required TurnManager Function() turnManagerGetter,
    required TaskService taskService,
    required EventBus eventBus,
    required SseBroadcast sseBroadcast,
    required PauseController pauseController,
    required SessionService sessions,
  }) async {
    final lower = message.text.trim().toLowerCase();

    final isStop = lower == '/stop' || lower.startsWith('/stop ') || lower == 'stop!';
    final isPause = lower.startsWith('/pause');
    final isResume = lower.startsWith('/resume');

    if (!isStop && !isPause && !isResume) return null;

    final senderId = message.senderJid;
    final senderName = message.senderDisplayName ?? senderId;
    final recipientId = resolveRecipientId(message);

    // Admin check — same for all reserved commands.
    if (!governance.isAdmin(senderId)) {
      try {
        await channel.sendMessage(recipientId, ChannelResponse(text: 'Only admin senders can use this command.'));
      } catch (e) {
        _log.warning('Failed to send reserved command rejection to $senderId', e);
      }
      return 'rejected';
    }

    if (isStop) {
      final stopHandler = EmergencyStopHandler(
        turnManager: turnManagerGetter(),
        taskService: taskService,
        eventBus: eventBus,
        sseBroadcast: sseBroadcast,
      );
      final result = await stopHandler.execute(stoppedBy: senderName);

      final turnCount = result.turnsCancelled;
      final taskCount = result.tasksCancelled;
      final responseText = result.hadActivity
          ? 'All activity stopped by $senderName. '
                '$turnCount turn${turnCount == 1 ? '' : 's'} cancelled, '
                '$taskCount task${taskCount == 1 ? '' : 's'} cancelled.'
          : 'No active tasks or turns to stop.';

      try {
        await channel.sendMessage(recipientId, ChannelResponse(text: responseText));
      } catch (e) {
        _log.warning('Failed to send stop confirmation to $senderId', e);
      }
      return 'executed';
    }

    if (isPause) {
      final wasNewlyPaused = pauseController.pause(senderName);
      final responseText = wasNewlyPaused
          ? 'Agent paused by $senderName. Incoming messages will be queued. Send /resume to continue.'
          : 'Agent is already paused by ${pauseController.pausedBy ?? senderName}.';
      try {
        await channel.sendMessage(recipientId, ChannelResponse(text: responseText));
      } catch (e) {
        _log.warning('Failed to send pause confirmation to $senderId', e);
      }
      return 'executed';
    }

    // isResume
    if (!pauseController.isPaused) {
      try {
        await channel.sendMessage(recipientId, ChannelResponse(text: 'Agent is not paused.'));
      } catch (e) {
        _log.warning('Failed to send resume response to $senderId', e);
      }
      return 'executed';
    }

    final queueDepth = pauseController.queueDepth;
    final collapsed = pauseController.drain();
    if (collapsed != null && collapsed.isNotEmpty) {
      await _drainPauseQueue(collapsed: collapsed, sessions: sessions, turnManagerGetter: turnManagerGetter);
    }

    final sessionCount = collapsed?.length ?? 0;
    final responseText = queueDepth == 0
        ? 'Agent resumed by $senderName. No messages were queued.'
        : 'Agent resumed by $senderName. $queueDepth queued message${queueDepth == 1 ? '' : 's'} '
              'from $sessionCount session${sessionCount == 1 ? '' : 's'} delivered.';
    try {
      await channel.sendMessage(recipientId, ChannelResponse(text: responseText));
    } catch (e) {
      _log.warning('Failed to send resume confirmation to $senderId', e);
    }
    return 'executed';
  }

  /// Delivers collapsed pause queue messages by creating turns via [TurnManager].
  ///
  /// Each session in [collapsed] gets one turn with the concatenated text.
  /// Errors per session are logged and skipped — partial delivery is acceptable.
  static Future<void> _drainPauseQueue({
    required Map<String, String> collapsed,
    required SessionService sessions,
    required TurnManager Function() turnManagerGetter,
  }) async {
    final turns = turnManagerGetter();
    for (final MapEntry(key: sessionKey, value: text) in collapsed.entries) {
      try {
        final session = await sessions.getOrCreateByKey(sessionKey, type: SessionType.channel);
        final messages = [
          {'role': 'user', 'content': text},
        ];
        await turns.startTurn(session.id, messages, source: 'pause-queue', isHumanInput: true);
      } catch (e, st) {
        _log.warning('Failed to deliver paused messages for session $sessionKey', e, st);
      }
    }
  }

  static String _channelSessionTitle(String senderJid) {
    if (senderJid.contains('@')) {
      return 'WA › ${senderJid.split('@').first}';
    }
    if (senderJid.startsWith('users/')) {
      return 'Google Chat › ${senderJid.substring('users/'.length)}';
    }
    if (senderJid.startsWith('spaces/')) {
      return 'Google Chat › ${senderJid.substring('spaces/'.length)}';
    }
    if (senderJid.startsWith('+')) {
      return 'Signal › $senderJid';
    }
    return 'Signal › ${senderJid.substring(0, min(8, senderJid.length))}';
  }
}
