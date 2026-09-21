import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../concurrency/session_mutation_coordinator.dart';
import '../conversation/conversation_service.dart';
import '../conversation/human_command_catalog.dart';
import '../conversation/inbox_service.dart';
import '../conversation/product_conversation_search.dart';
import '../session/session_reset_service.dart';
import '../templates/sidebar.dart' show NavItem, SidebarData;
import '../turn_manager.dart' show TurnManager;
import '../temporary_conversation_capability.dart';
import 'api_helpers.dart';
import 'session_attachment_routes.dart';
import 'conversation_search_command_routes.dart';
import 'session_conversation_routes.dart';
import 'session_export_routes.dart';
import 'session_lifecycle_routes.dart';
import 'session_inbox_routes.dart';
import 'session_message_routes.dart';
import 'session_routes_support.dart';
import 'session_turn_status_routes.dart';
import 'sse_broadcast.dart';

final _log = Logger('SessionRoutes');

// ---------------------------------------------------------------------------
// Public route factory
// ---------------------------------------------------------------------------

/// Creates a [Router] exposing session CRUD and turn execution API endpoints.
///
/// Session CRUD (list/get/create/patch) is handled here; cohesive route groups
/// are registered from sibling `session_*_routes.dart` files.
Router sessionRoutes(
  SessionService sessions,
  MessageService messages,
  TurnManager turns,
  AgentHarness worker, {
  SessionResetService? resetService,
  MessageRedactor? redactor,
  ProjectService? projectService,
  Map<String, EffectiveContextCapabilities> contextCapabilities = const {},
  ModelCatalogueLookup modelCatalogues = noModelCatalogues,
  String defaultProvider = 'claude',
  TemporaryConversationCapability? temporaryConversationCapability,
  LogicalAgentSessionService? logicalAgentSessions,
  Future<SidebarData> Function({String? activeSessionId})? sidebarData,
  String Function({required SidebarData sidebarData, List<NavItem> navItems})? buildSidebarHtml,
  SseBroadcast? sseBroadcast,
  ConversationInboxService? inboxService,
  ProductConversationSearchService? conversationSearch,
  HumanCommandCatalog? commandCatalog,
  ConversationFailpoint? conversationFailpoint,
  void Function(ConversationService conversation)? onConversationCreated,
  AttachmentWriteFailpoint? attachmentWriteFailpoint,
  String Function()? attachmentIdFactory,
  ProcessAttachmentOwner? processAttachmentOwner,
}) {
  final router = Router();
  final sessionMutations = inboxService?.mutations ?? SessionMutationCoordinator();
  final inbox =
      inboxService ??
      ConversationInboxService(
        sessions: sessions,
        messages: messages,
        mutations: sessionMutations,
        updates: sseBroadcast,
        projects: projectService,
        isSessionRunning: turns.isActive,
      );
  final processAttachments = processAttachmentOwner ?? ProcessAttachmentOwner();
  final conversation = ConversationService(
    sessions: sessions,
    messages: messages,
    turns: turns,
    mutations: sessionMutations,
    updates: sseBroadcast,
    failpoint: conversationFailpoint,
    projects: projectService,
    contextCapabilities: contextCapabilities,
    defaultProvider: defaultProvider,
    titleAgents: logicalAgentSessions,
    processAttachmentResolver: processAttachments.resolve,
    redactor: redactor,
    approvalResponder: (sessionId, turnId, requestId, approved) =>
        turns.resolveToolApproval(sessionId: sessionId, turnId: turnId, requestId: requestId, approved: approved),
    approvalValidator: (sessionId, turnId, requestId) =>
        turns.canResolveToolApproval(sessionId: sessionId, turnId: turnId, requestId: requestId),
    referenceValidator: (references) async {
      for (final reference in references) {
        final type = reference['type'];
        final id = reference['id'];
        if (type is! String || id is! String) {
          throw const ConversationMutationException(409, 'REFERENCE_UNAVAILABLE', 'Retained reference is invalid');
        }
        final resolved = await resolveConversationReference(
          type: type,
          id: id,
          sessions: sessions,
          projects: projectService,
        );
        if (resolved.error != null) {
          throw const ConversationMutationException(
            409,
            'REFERENCE_UNAVAILABLE',
            'Retained reference is no longer available',
          );
        }
      }
    },
  );
  onConversationCreated?.call(conversation);
  turns.setToolApprovalObservers(
    requested: conversation.retainRuntimeApproval,
    closed: conversation.closeRuntimeApproval,
  );
  turns.setToolHistoryObserver(conversation.retainRuntimeToolEvent);
  turns.setContextTelemetryObserver((telemetry) async {
    await conversation.recordTelemetry(telemetry.sessionId, telemetry);
  });
  conversation.setInboxObservers(
    turnStarted: (sessionId) => inbox.handleWorkSignal(sessionId, InboxWorkSignal.turnStarted),
    inputRequested: (sessionId) => inbox.handleWorkSignal(sessionId, InboxWorkSignal.inputRequested),
  );
  inbox.bindApprovalResolver(conversation.resolveApproval);
  Future<({Session session, bool created})>? openNewChatPromise;

  Future<({Session session, bool created})> openNewChat() {
    final pending = openNewChatPromise;
    if (pending != null) return pending;

    late final Future<({Session session, bool created})> operation;
    operation = () async {
      try {
        return await _openNewChat(sessions, messages, turns, sessionMutations);
      } finally {
        if (identical(openNewChatPromise, operation)) openNewChatPromise = null;
      }
    }();
    openNewChatPromise = operation;
    return operation;
  }

  // GET /api/sessions
  router.get('/api/sessions', (Request request) async {
    try {
      final typeParam = request.url.queryParameters['type'];
      final typeFilter = typeParam != null ? SessionType.values.asNameMap()[typeParam] : null;
      final list = await sessions.listSessions(type: typeFilter);
      return jsonResponse(200, list.map((s) => s.toJson()).toList());
    } catch (e) {
      _log.warning('Failed to list sessions: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to list sessions');
    }
  });

  // GET /api/sessions/<id>
  router.get('/api/sessions/<id>', (Request request, String id) async {
    try {
      final session = await sessions.getSession(id);
      if (session == null) {
        return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
      }
      final response = jsonResponse(200, {
        ...session.toJson(),
        if (session.retention == ConversationRetention.process) 'temporaryEndState': sessions.temporaryEndState(id),
      });
      return session.retention == ConversationRetention.process
          ? response.change(headers: {'cache-control': 'no-store'})
          : response;
    } catch (e) {
      _log.warning('Failed to get session $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to get session');
    }
  });

  // POST /api/sessions
  router.post('/api/sessions', (Request request) async {
    try {
      final queryProvider = trimmedOrNull(request.url.queryParameters['provider']);
      final raw = await readRequestBody(request, maxBytes: defaultMaxJsonBodyBytes);
      if (raw.error != null) return raw.error!;
      var body = <String, dynamic>{};
      if (raw.body!.trim().isNotEmpty) {
        final parsed = decodeJsonObject(raw.body!);
        if (parsed.error != null) return parsed.error!;
        body = parsed.value!;
      }
      final provider = queryProvider ?? trimmedStringOrNull(body['provider']);
      if (provider != null) {
        return errorResponse(
          400,
          'PROVIDER_OVERRIDE_UNSUPPORTED',
          'Interactive sessions use the configured primary provider',
          {'field': 'provider'},
        );
      }
      final retention = body['retention'];
      if (retention != null && retention != 'process') {
        return errorResponse(400, 'INVALID_RETENTION', 'retention must be process when supplied');
      }
      if (retention == 'process') {
        if (body['disclosureAccepted'] != true) {
          return errorResponse(400, 'DISCLOSURE_REQUIRED', 'Temporary conversation disclosure must be accepted');
        }
        final capability = temporaryConversationCapability;
        if (capability == null || !capability.available) {
          return errorResponse(
            409,
            'TEMPORARY_UNAVAILABLE',
            capability?.reason.isNotEmpty == true
                ? capability!.reason
                : 'Temporary conversations are unavailable on this host',
          );
        }
        final session = await sessions.createSession(
          retention: ConversationRetention.process,
          provider: capability.providerId,
          securityProfile: capability.policy.containerProfile,
          executionMode: capability.policy.mode,
        );
        return Response(
          201,
          body: jsonEncode(session.toJson()),
          headers: {'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store'},
        );
      }
      final session = await sessions.createSession();
      return jsonResponse(201, session.toJson());
    } catch (e) {
      _log.warning('Failed to create session: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to create session');
    }
  });

  // POST /api/sessions/open — open the single reusable blank default chat.
  router.post('/api/sessions/open', (Request request) async {
    try {
      final result = await openNewChat();
      return jsonResponse(result.created ? 201 : 200, result.session.toJson());
    } catch (e) {
      _log.warning('Failed to open a new chat: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to open a new chat');
    }
  });

  // PATCH /api/sessions/<id>
  router.patch('/api/sessions/<id>', (Request request, String id) async {
    try {
      final parsed = await parseBodyField(request, 'title');
      if (parsed.error != null) return parsed.error!;
      final title = parsed.value;

      final titleValidation = _validateTitle(title);
      if (titleValidation != null) return titleValidation;

      final trimmed = title!.trim();
      return await sessionMutations.run(id, () async {
        final session = await sessions.getSession(id);
        if (session == null) {
          return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
        }
        if (session.type == SessionType.main) {
          return errorResponse(403, 'FORBIDDEN', 'Cannot rename main session');
        }
        await sessions.updateTitleWithProvenance(id, trimmed, provenance: SessionTitleProvenance.manual);
        final updated = await sessions.getSession(id);
        if (updated == null) {
          return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
        }
        return jsonResponse(200, updated.toJson());
      });
    } catch (e) {
      _log.warning('Failed to update session $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to update session');
    }
  });

  // Message history, chat-send, and SSE stream.
  registerSessionMessageRoutes(
    router,
    sessions: sessions,
    messages: messages,
    turns: turns,
    worker: worker,
    redactor: redactor,
    projectService: projectService,
    sessionMutations: sessionMutations,
    conversation: conversation,
  );

  // Attachment upload + reference autocomplete.
  registerSessionAttachmentRoutes(
    router,
    sessions: sessions,
    messages: messages,
    sessionMutations: sessionMutations,
    conversation: conversation,
    projectService: projectService,
    failpoint: attachmentWriteFailpoint,
    attachmentIdFactory: attachmentIdFactory,
    processAttachments: processAttachments,
  );
  registerSessionExportRoutes(
    router,
    sessions: sessions,
    conversation: conversation,
    processAttachments: processAttachments,
  );

  // Stuck-turn status + early-cancel endpoints (turn/stop, turn-status, turns/<turnId>/cancel).
  registerSessionTurnStatusRoutes(
    router,
    sessions: sessions,
    turns: turns,
    conversation: conversation,
    sessionMutations: sessionMutations,
  );

  registerSessionConversationRoutes(
    router,
    sessions: sessions,
    conversation: conversation,
    turns: turns,
    projects: projectService,
    contextCapabilities: contextCapabilities,
    modelCatalogues: modelCatalogues,
    defaultProvider: defaultProvider,
  );
  registerSessionInboxRoutes(router, inbox: inbox, modelCatalogues: modelCatalogues);
  if (conversationSearch != null && commandCatalog != null) {
    registerConversationSearchCommandRoutes(
      router,
      sessions: sessions,
      messages: messages,
      conversation: conversation,
      inbox: inbox,
      turns: turns,
      sessionMutations: sessionMutations,
      search: conversationSearch,
      catalog: commandCatalog,
      contextCapabilities: contextCapabilities,
      defaultProvider: defaultProvider,
      resetService: resetService,
    );
  }

  // Session lifecycle (delete / resume / archive / reset).
  registerSessionLifecycleRoutes(
    router,
    sessions: sessions,
    messages: messages,
    turns: turns,
    sessionMutations: sessionMutations,
    resetService: resetService,
    sidebarData: sidebarData,
    buildSidebarHtml: buildSidebarHtml,
    processAttachments: processAttachments,
  );

  return router;
}

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------

/// Returns an error [Response] if [title] is invalid, otherwise null.
Response? _validateTitle(String? title) {
  if (title == null || title.trim().isEmpty) {
    return errorResponse(400, 'INVALID_INPUT', 'title must not be empty', {'field': 'title'});
  }
  if (title.trim().length > 120) {
    return errorResponse(400, 'INVALID_INPUT', 'title must not exceed 120 characters', {'field': 'title'});
  }
  return null;
}

Future<({Session session, bool created})> _openNewChat(
  SessionService sessions,
  MessageService messages,
  TurnManager turns,
  SessionMutationCoordinator sessionMutations,
) async {
  final candidates = await sessions.listSessions(type: SessionType.user);
  for (final session in candidates) {
    if (!_isReusableNewChatMetadata(session)) continue;
    if (turns.isActive(session.id)) continue;
    final reusable = await sessionMutations.run(session.id, () async {
      if ((await messages.getMessagesTail(session.id, count: 1)).isNotEmpty) return null;
      final current = await sessions.getSession(session.id);
      if (current == null || !_isReusableNewChatMetadata(current) || turns.isActive(current.id)) return null;
      return current;
    });
    if (reusable != null) return (session: reusable, created: false);
  }
  return (session: await sessions.createSession(), created: true);
}

bool _isReusableNewChatMetadata(Session session) =>
    session.type == SessionType.user &&
    session.channelKey == null &&
    !(session.provider?.trim().isNotEmpty ?? false) &&
    (session.title == null || session.title!.trim().isEmpty);
