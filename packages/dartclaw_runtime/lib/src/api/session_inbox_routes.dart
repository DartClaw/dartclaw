import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/request_auth_context.dart';
import '../conversation/inbox_service.dart';
import '../conversation/conversation_service.dart';
import 'api_helpers.dart';
import 'session_routes_support.dart' show ModelCatalogueLookup, contextModelLabel, noModelCatalogues;

void registerSessionInboxRoutes(
  Router router, {
  required ConversationInboxService inbox,
  ModelCatalogueLookup modelCatalogues = noModelCatalogues,
}) {
  router.get('/api/inbox', (Request request) async {
    if (!requestHasAdminAccess(request)) return errorResponse(403, 'FORBIDDEN', 'Admin access required');
    try {
      final query = request.url.queryParameters;
      final filter = InboxFilter.values.asNameMap()[query['filter'] ?? 'all'];
      if (filter == null) return errorResponse(400, 'INVALID_INBOX_FILTER', 'Inbox filter is unavailable');
      final limit = int.tryParse(query['limit'] ?? '50');
      if (limit == null) return errorResponse(400, 'INVALID_PAGE_SIZE', 'Page size must be an integer');
      final page = await inbox.inbox(
        filter: filter,
        search: query['search'] ?? '',
        cursor: query['cursor'],
        limit: limit,
        settled: query['settled'] == 'true' || query['settled'] == '1',
        currentSessionId: query['current_session_id'],
        localDraftSessionIds: _csv(query['local_draft_session_ids']),
      );
      return jsonResponse(200, {
        'entries': [for (final entry in page.entries) _entryJson(entry, modelCatalogues)],
        'total': page.total,
        'filtered_total': page.filteredTotal,
        'waiting_total': page.waitingTotal,
        'next_cursor': page.nextCursor,
        'next_attention_session_id': page.nextAttentionSessionId,
      });
    } on InboxMutationException catch (error) {
      return errorResponse(error.statusCode, error.code, error.message);
    }
  });

  router.get('/api/attention', (Request request) async {
    if (!requestHasAdminAccess(request)) return errorResponse(403, 'FORBIDDEN', 'Admin access required');
    try {
      final limit = int.tryParse(request.url.queryParameters['limit'] ?? '50');
      if (limit == null) return errorResponse(400, 'INVALID_PAGE_SIZE', 'Page size must be an integer');
      final page = await inbox.attention(cursor: request.url.queryParameters['cursor'], limit: limit);
      return jsonResponse(200, {
        'items': page.items.map(_attentionJson).toList(growable: false),
        'total': page.total,
        'unread_total': page.unreadTotal,
        'next_cursor': page.nextCursor,
      });
    } on InboxMutationException catch (error) {
      return errorResponse(error.statusCode, error.code, error.message);
    }
  });

  router.post('/api/inbox/settle', (Request request) async {
    if (!requestHasAdminAccess(request)) return errorResponse(403, 'FORBIDDEN', 'Admin access required');
    final parsed = await readJsonObject(request);
    if (parsed.error != null) return parsed.error!;
    final rawMembers = parsed.value!['members'];
    if (rawMembers is! List || rawMembers.isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', 'members must be a non-empty list');
    }
    final members = <({String sessionId, int expectedRevision})>[];
    for (final raw in rawMembers) {
      if (raw is! Map || raw['session_id'] is! String || raw['conversation_revision'] is! int) {
        return errorResponse(400, 'INVALID_INPUT', 'Each member requires session_id and conversation_revision');
      }
      members.add((sessionId: raw['session_id'] as String, expectedRevision: raw['conversation_revision'] as int));
    }
    final drafts = (parsed.value!['local_draft_session_ids'] as List?)?.whereType<String>().toSet() ?? const <String>{};
    final results = await inbox.settleMany(members, localDraftSessionIds: drafts);
    return jsonResponse(200, {'results': results.map((result) => result.toJson()).toList(growable: false)});
  });

  router.post('/api/inbox/<id>/restore', (Request request, String id) async {
    if (!requestHasAdminAccess(request)) return errorResponse(403, 'FORBIDDEN', 'Admin access required');
    final revision = await _revision(request);
    if (revision.error != null) return revision.error!;
    return _mutation(() => inbox.restore(decodePathSegment(id), revision.value!));
  });

  router.post('/api/inbox/<id>/read', (Request request, String id) async {
    if (!requestHasAdminAccess(request)) return errorResponse(403, 'FORBIDDEN', 'Admin access required');
    final parsed = await readJsonObject(request);
    if (parsed.error != null) return parsed.error!;
    final revision = parsed.value!['conversation_revision'];
    final visibleMessageId = parsed.value!['visible_message_id'];
    final foreground = parsed.value!['foreground'];
    final rawDrafts = parsed.value!['local_draft_session_ids'];
    if (revision is! int || visibleMessageId is! String || foreground is! bool) {
      return errorResponse(
        400,
        'INVALID_INPUT',
        'conversation_revision, visible_message_id and foreground are required',
      );
    }
    if (rawDrafts != null &&
        (rawDrafts is! List ||
            rawDrafts.length > ConversationInboxService.maxPageSize ||
            rawDrafts.any((value) => value is! String || value.isEmpty))) {
      return errorResponse(400, 'INVALID_INPUT', 'local_draft_session_ids must contain at most 200 session IDs');
    }
    return _mutation(
      () => inbox.advanceRead(
        sessionId: decodePathSegment(id),
        expectedRevision: revision,
        visibleMessageId: visibleMessageId,
        foreground: foreground,
        localDraftSessionIds: (rawDrafts as List?)?.cast<String>().toSet() ?? const {},
      ),
    );
  });

  router.post('/api/attention/read', (Request request) async {
    if (!requestHasAdminAccess(request)) return errorResponse(403, 'FORBIDDEN', 'Admin access required');
    final values = await _attentionMarker(request);
    if (values.error != null) return values.error!;
    final value = values.value!;
    return _mutation(
      () =>
          inbox.markAttentionRead(sessionId: value.sessionId, expectedRevision: value.revision, eventId: value.eventId),
    );
  });

  router.post('/api/attention/dismiss', (Request request) async {
    if (!requestHasAdminAccess(request)) return errorResponse(403, 'FORBIDDEN', 'Admin access required');
    final values = await _attentionMarker(request);
    if (values.error != null) return values.error!;
    final value = values.value!;
    return _mutation(
      () =>
          inbox.dismissAttention(sessionId: value.sessionId, expectedRevision: value.revision, eventId: value.eventId),
    );
  });

  router.post('/api/attention/action', (Request request) async {
    if (!requestHasAdminAccess(request)) return errorResponse(403, 'FORBIDDEN', 'Admin access required');
    final parsed = await readJsonObject(request);
    if (parsed.error != null) return parsed.error!;
    final body = parsed.value!;
    if (body['event_id'] is! String ||
        body['session_id'] is! String ||
        body['attempt_id'] is! String ||
        body['turn_id'] is! String ||
        body['request_id'] is! String ||
        body['conversation_revision'] is! int ||
        body['approved'] is! bool) {
      return errorResponse(400, 'INVALID_INPUT', 'Exact attention action identity is required');
    }
    try {
      final result = await inbox.resolveAttention(
        principal: 'owner',
        eventId: body['event_id'] as String,
        sessionId: body['session_id'] as String,
        attemptId: body['attempt_id'] as String,
        turnId: body['turn_id'] as String,
        requestId: body['request_id'] as String,
        expectedRevision: body['conversation_revision'] as int,
        approved: body['approved'] as bool,
      );
      return jsonResponse(200, {'record': result.toJson()});
    } on InboxMutationException catch (error) {
      return errorResponse(error.statusCode, error.code, error.message);
    } on ConversationMutationException catch (error) {
      return errorResponse(error.statusCode, error.code, error.message);
    }
  });
}

Set<String> _csv(String? value) => value == null || value.isEmpty ? const {} : value.split(',').toSet();

Map<String, Object?> _entryJson(InboxEntry entry, ModelCatalogueLookup modelCatalogues) => {
  'session': entry.session.toJson(),
  'conversation_revision': entry.revision,
  'latest_message_cursor': entry.latestMessageCursor,
  'unread': entry.unread,
  'waiting': entry.waiting,
  'running': entry.running,
  'failed': entry.failed,
  'done': entry.done,
  'local_draft': entry.localDraft,
  'parent_session_id': entry.parentSessionId,
  'running_since': entry.runningSince?.toIso8601String(),
  'project_id': entry.projectId,
  'project_name': entry.projectName,
  'provider': entry.provider,
  'model': entry.model,
  // The rail row and the topbar crumb name the model as the composer does.
  'model_label': entry.provider == null ? null : contextModelLabel(modelCatalogues(entry.provider!), entry.model),
};

Map<String, Object?> _attentionJson(AttentionItem item) => {
  'event_id': item.eventId,
  'session_id': item.sessionId,
  'title': item.title,
  'detail': item.detail,
  'source': item.source,
  'occurred_at': item.occurredAt.toIso8601String(),
  'status': item.status,
  'attempt_id': item.attemptId,
  'turn_id': item.turnId,
  'request_id': item.requestId,
  'message_id': item.messageId,
  'record_id': item.recordId,
  'unread': item.unread,
  'dismissible': item.dismissible,
  'action_available': item.actionAvailable,
  'conversation_revision': item.revision,
};

Future<Response> _mutation(Future<InboxMutationResult> Function() operation) async {
  try {
    final result = await operation();
    return jsonResponse(result.accepted ? 200 : 409, result.toJson());
  } on InboxMutationException catch (error) {
    return errorResponse(error.statusCode, error.code, error.message);
  }
}

Future<({int? value, Response? error})> _revision(Request request) async {
  final parsed = await readJsonObject(request);
  if (parsed.error != null) return (value: null, error: parsed.error);
  final value = parsed.value!['conversation_revision'];
  if (value is! int) {
    return (value: null, error: errorResponse(400, 'INVALID_INPUT', 'conversation_revision is required'));
  }
  return (value: value, error: null);
}

Future<({({String sessionId, String eventId, int revision})? value, Response? error})> _attentionMarker(
  Request request,
) async {
  final parsed = await readJsonObject(request);
  if (parsed.error != null) return (value: null, error: parsed.error);
  final sessionId = parsed.value!['session_id'];
  final eventId = parsed.value!['event_id'];
  final revision = parsed.value!['conversation_revision'];
  if (sessionId is! String || eventId is! String || revision is! int) {
    return (value: null, error: errorResponse(400, 'INVALID_INPUT', 'Attention marker identity is required'));
  }
  return (value: (sessionId: sessionId, eventId: eventId, revision: revision), error: null);
}
