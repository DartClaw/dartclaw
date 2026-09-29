import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/request_auth_context.dart';
import '../concurrency/session_mutation_coordinator.dart';
import '../conversation/conversation_service.dart';
import '../conversation/human_command_catalog.dart';
import '../conversation/inbox_service.dart';
import '../conversation/product_conversation_search.dart';
import '../session/session_reset_service.dart';
import '../turn_manager.dart' show TurnManager;
import 'api_helpers.dart';

void registerConversationSearchCommandRoutes(
  Router router, {
  required SessionService sessions,
  required MessageService messages,
  required ConversationService conversation,
  required ConversationInboxService inbox,
  required TurnManager turns,
  required SessionMutationCoordinator sessionMutations,
  required ProductConversationSearchService search,
  required HumanCommandCatalog catalog,
  required Map<String, EffectiveContextCapabilities> contextCapabilities,
  required String defaultProvider,
  SessionResetService? resetService,
}) {
  Future<HumanCommandContext?> contextFor(String? sessionId) async {
    if (sessionId == null || sessionId.isEmpty) {
      return HumanCommandContext(principal: 'owner', provider: defaultProvider, revision: 0);
    }
    final session = await sessions.getSession(sessionId);
    if (session == null) return null;
    final visible = await conversation.visibleMessages(session.id);
    final state = await sessions.getConversationState(session.id);
    final provider =
        state.nextContext?.provider ?? state.currentContext?.provider ?? session.provider ?? defaultProvider;
    final capabilities = contextCapabilities[provider] ?? EffectiveContextCapabilities.unavailable;
    return HumanCommandContext(
      principal: 'owner',
      provider: provider,
      revision: state.revision,
      sessionId: session.id,
      workspaceDir: session.workspace?.directory,
      modelEditable: capabilities.model,
      effortEditable: capabilities.effort,
      turnActive: turns.isActive(session.id),
      forkAvailable: visible.isNotEmpty && session.type != SessionType.archive,
      settleAvailable: session.type != SessionType.archive && session.settledAt == null,
      readOnly: session.type == SessionType.archive,
    );
  }

  router.get('/api/conversation-search', (Request request) async {
    if (!requestHasAdminAccess(request)) {
      return errorResponse(403, 'CONVERSATION_SEARCH_FORBIDDEN', 'Conversation search requires operator/admin access');
    }
    final query = request.url.queryParameters;
    final scope = ConversationSearchScope.values.asNameMap()[query['scope'] ?? 'global'];
    final lifecycle = ConversationSearchLifecycle.values.asNameMap()[query['lifecycle'] ?? 'all'];
    final limit = int.tryParse(query['limit'] ?? '20');
    if (scope == null || lifecycle == null || limit == null) {
      return errorResponse(400, 'INVALID_SEARCH_SCOPE', 'Search scope, lifecycle, or page size is unavailable');
    }
    try {
      final outcome = await search.find(
        query: query['q'] ?? '',
        scope: scope,
        lifecycle: lifecycle,
        currentSessionId: query['session_id'],
        projectId: query['project_id'],
        limit: limit,
      );
      if (!outcome.succeeded) {
        return errorResponse(503, outcome.failure!, 'Conversation search is temporarily unavailable');
      }
      return jsonResponse(200, {
        'request_token': query['request_token'],
        'total': outcome.total,
        'results': outcome.results.map((result) => result.toJson()).toList(growable: false),
      });
    } on ArgumentError catch (error) {
      return errorResponse(400, 'INVALID_SEARCH_REQUEST', error.message?.toString() ?? 'Invalid search request');
    }
  });

  router.get('/api/conversation-search/target', (Request request) async {
    if (!requestHasAdminAccess(request)) {
      return errorResponse(403, 'CONVERSATION_SEARCH_FORBIDDEN', 'Conversation search requires operator/admin access');
    }
    final sessionId = request.url.queryParameters['session_id'];
    final messageId = request.url.queryParameters['message_id'];
    if (sessionId == null || messageId == null) {
      return errorResponse(400, 'INVALID_SEARCH_TARGET', 'session_id and message_id are required');
    }
    final target = await search.resolveTarget(sessionId: sessionId, messageId: messageId);
    if (target == null) {
      return errorResponse(404, 'SEARCH_TARGET_UNAVAILABLE', 'That message is no longer available');
    }
    return jsonResponse(200, target.toJson());
  });

  router.get('/api/command-catalog', (Request request) async {
    if (!requestHasAdminAccess(request)) {
      return errorResponse(403, 'COMMAND_CATALOG_FORBIDDEN', 'Command catalog requires operator/admin access');
    }
    final surface = HumanCommandSurface.values.asNameMap()[request.url.queryParameters['surface'] ?? 'global'];
    if (surface == null) return errorResponse(400, 'INVALID_COMMAND_SURFACE', 'Command surface is unavailable');
    final context = await contextFor(request.url.queryParameters['session_id']);
    if (context == null) return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
    final snapshot = await catalog.resolve(context, surface);
    return jsonResponse(200, {
      'identity_token': snapshot.identityToken,
      'conversation_revision': context.revision,
      'entries': snapshot.entries.map((entry) => entry.toJson()).toList(growable: false),
    });
  });

  router.post('/api/command-actions', (Request request) async {
    if (!requestHasAdminAccess(request)) {
      return errorResponse(403, 'COMMAND_ACTION_FORBIDDEN', 'Command actions require operator/admin access');
    }
    final parsed = await readJsonObject(request);
    if (parsed.error != null) return parsed.error!;
    final body = parsed.value!;
    final commandId = body['command_id'];
    final identityToken = body['identity_token'];
    final sessionId = body['session_id'];
    if (commandId is! String || identityToken is! String || sessionId != null && sessionId is! String) {
      return errorResponse(400, 'INVALID_COMMAND_ACTION', 'command_id and identity_token are required');
    }
    final context = await contextFor(sessionId as String?);
    if (context == null) return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
    final snapshot = await catalog.resolve(context, HumanCommandSurface.global);
    if (identityToken != snapshot.identityToken) {
      return errorResponse(409, 'STALE_COMMAND_CONTEXT', 'Command context changed', {
        'conversation_revision': context.revision,
        'identity_token': snapshot.identityToken,
      });
    }
    final entry = snapshot.entries.where((candidate) => candidate.id == commandId).firstOrNull;
    if (entry == null) return errorResponse(404, 'COMMAND_UNAVAILABLE', 'Command is unavailable');
    if (!entry.enabled) return errorResponse(409, 'COMMAND_DISABLED', entry.disabledReason ?? 'Command is disabled');
    if (entry.confirmation != null && body['confirmed'] != true) {
      return errorResponse(409, 'CONFIRMATION_REQUIRED', entry.confirmation!);
    }
    try {
      return await _dispatchCommand(
        entry,
        body,
        context,
        sessions: sessions,
        conversation: conversation,
        inbox: inbox,
        turns: turns,
        sessionMutations: sessionMutations,
        resetService: resetService,
      );
    } on ConversationMutationException catch (error) {
      return errorResponse(error.statusCode, error.code, error.message);
    } on InboxMutationException catch (error) {
      return errorResponse(error.statusCode, error.code, error.message);
    }
  });
}

Future<Response> _dispatchCommand(
  HumanCommandEntry entry,
  Map<String, dynamic> body,
  HumanCommandContext context, {
  required SessionService sessions,
  required ConversationService conversation,
  required ConversationInboxService inbox,
  required TurnManager turns,
  required SessionMutationCoordinator sessionMutations,
  required SessionResetService? resetService,
}) async {
  if (entry.id.startsWith('skill:')) {
    return jsonResponse(200, {'action': 'send_provider', 'message': entry.nativeInvocation});
  }
  final sessionId = context.sessionId;
  switch (entry.id) {
    case 'built-in:new':
      final created = await sessions.createSession();
      return jsonResponse(201, {'action': 'navigate', 'href': '/sessions/${created.id}'});
    case 'built-in:reset':
      if (resetService == null) return errorResponse(501, 'RESET_UNAVAILABLE', 'Reset service is unavailable');
      await sessionMutations.run(sessionId!, () async {
        final current = await sessions.getConversationState(sessionId);
        if (current.revision != context.revision) {
          throw ConversationMutationException(
            409,
            'STALE_CONVERSATION_REVISION',
            'Conversation changed since this action was shown',
            current: current,
          );
        }
        if (turns.isActive(sessionId)) {
          throw const ConversationMutationException(409, 'SESSION_BUSY', 'Cannot reset a running conversation');
        }
        await turns.resetSessionContinuity(sessionId);
        await resetService.resetSession(sessionId, resetContinuity: false);
      });
      return jsonResponse(200, {'action': 'navigate', 'href': '/'});
    case 'built-in:stop':
      final status = turns.turnStatus(sessionId!);
      if (status.turnId == null || !status.canCancel) {
        return errorResponse(409, 'STOP_UNAVAILABLE', 'No cancellable turn is running');
      }
      final state = await conversation.stop(
        sessionId: sessionId,
        turnId: status.turnId!,
        expectedRevision: context.revision,
      );
      return jsonResponse(200, {'action': 'refresh', 'conversation_revision': state.revision});
    case 'built-in:status':
      final state = await conversation.snapshot(sessionId!);
      return jsonResponse(200, {
        'action': 'status',
        'conversation_revision': state.revision,
        'turn': turns.turnStatus(sessionId).toJson(),
      });
    case 'built-in:fork':
      final sourceMessageId = body['source_message_id'];
      final mutationId = body['mutation_id'];
      if (sourceMessageId is! String || mutationId is! String) {
        return errorResponse(400, 'INVALID_COMMAND_ACTION', 'source_message_id and mutation_id are required');
      }
      final branch = await conversation.branchFromMessage(
        sessionId: sessionId!,
        sourceMessageId: sourceMessageId,
        mutationId: mutationId,
        kind: ConversationBranchKind.fork,
        expectedRevision: context.revision,
      );
      return jsonResponse(200, {'action': 'navigate', 'href': '/sessions/${branch['destinationSessionId']}'});
    case 'built-in:settle':
      final result = (await inbox.settleMany([(sessionId: sessionId!, expectedRevision: context.revision)])).single;
      if (!result.accepted) return errorResponse(409, result.code, result.message, {'revision': result.revision});
      return jsonResponse(200, {'action': 'navigate', 'href': '/'});
    case 'built-in:model':
      return jsonResponse(200, {'action': 'open_context', 'field': 'model'});
    case 'built-in:effort':
      return jsonResponse(200, {'action': 'open_context', 'field': 'effort'});
    case 'built-in:help':
      return jsonResponse(200, {'action': 'show_help'});
    default:
      return errorResponse(404, 'COMMAND_UNAVAILABLE', 'Command is unavailable');
  }
}
