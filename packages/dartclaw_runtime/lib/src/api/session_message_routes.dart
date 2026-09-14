import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../conversation/conversation_service.dart';
import '../concurrency/session_mutation_coordinator.dart';
import '../execution_coordinator.dart';
import '../session/session_display_title.dart';
import '../templates/chat.dart' show richInputHtmlFromMetadataMap;
import '../templates/loader.dart';
import '../turn_manager.dart' show TurnManager;
import 'api_helpers.dart';
import 'session_routes_support.dart';
import 'stream_handler.dart';

final _log = Logger('SessionMessageRoutes');
const _maxRichInputMetadataFieldChars = 64 * 1024;

/// Registers session message-history, chat-send, and stream endpoints.
///
/// Routes registered:
/// - `GET  /api/sessions/<id>/messages` — message history.
/// - `POST /api/sessions/<id>/send` — send a chat message + launch a turn.
/// - `GET  /api/sessions/<id>/stream` — SSE stream for an active/recent turn.
void registerSessionMessageRoutes(
  Router router, {
  required SessionService sessions,
  required MessageService messages,
  required TurnManager turns,
  required AgentHarness worker,
  MessageRedactor? redactor,
  ProjectService? projectService,
  required SessionMutationCoordinator sessionMutations,
  required ConversationService conversation,
}) {
  // GET /api/sessions/<id>/messages
  router.get('/api/sessions/<id>/messages', (Request request, String id) async {
    try {
      final session = await sessions.getSession(id);
      if (session == null) {
        return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
      }

      final state = await sessions.getConversationState(id);
      final list = (await messages.getMessages(id)).where((message) => state.includesMessage(message.id));
      return jsonResponse(200, list.map(_messageToJson).toList());
    } catch (e) {
      _log.warning('Failed to get messages for $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to get messages');
    }
  });

  // POST /api/sessions/<id>/send
  router.post('/api/sessions/<id>/send', (Request request, String id) async {
    try {
      // 1. Look up session
      final session = await sessions.getSession(id);
      final sessionValidation = _validateSessionForSend(session, turns.executions);
      if (sessionValidation != null) return sessionValidation;

      // 2. Parse + validate message
      final parsed = await parseBodyFields(request);
      if (parsed.error != null) return parsed.error!;
      final fields = parsed.fields;
      final rawMessage = fields['message'];
      final richInput = await _parseRichInput(
        fields,
        sessionId: id,
        sessions: sessions,
        conversation: conversation,
        projects: projectService,
      );
      if (richInput.error != null) return richInput.error!;
      final trimmedMessage = rawMessage?.trim() ?? '';
      final messageValidation = _validateMessage(trimmedMessage, richInput.metadata != null);
      if (messageValidation != null) return messageValidation;
      if (session!.type != SessionType.user && session.type != SessionType.main) {
        return await _sendExistingSessionTurn(
          sessionId: id,
          message: trimmedMessage,
          richInput: richInput,
          sessions: sessions,
          messages: messages,
          turns: turns,
          conversation: conversation,
          sessionMutations: sessionMutations,
        );
      }
      final submissionId = _stableId(fields['submission_id']);
      final revisionId = _stableId(fields['revision_id']);
      final admission = await conversation.submit(
        sessionId: id,
        submissionId: submissionId,
        revisionId: revisionId,
        message: trimmedMessage,
        attachments:
            (richInput.metadata?['attachments'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? const [],
        references:
            (richInput.metadata?['references'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? const [],
      );
      if (request.headers['accept']?.contains('application/json') ?? false) {
        return jsonResponse(admission.replayed ? 200 : 202, admission.toJson());
      }
      final queued = admission.submission.queueId != null && admission.submission.turnId == null;
      final html = templateLoader.trellis.renderFragment(
        templateLoader.source('chat'),
        fragment: queued ? 'queuedResponse' : 'sendResponse',
        context: {
          'message': trimmedMessage,
          'richInputHtml': richInputHtmlFromMetadataMap(richInput.metadata),
          'sseUrl': admission.submission.turnId == null
              ? ''
              : '/api/sessions/$id/stream?turn=${admission.submission.turnId}',
          'queueId': admission.submission.queueId ?? '',
        },
      );
      return Response(
        queued ? 202 : 200,
        body: html,
        headers: {
          'content-type': 'text/html; charset=utf-8',
          'x-dartclaw-submission-id': admission.submission.submissionId,
          'x-dartclaw-revision-id': admission.submission.revisionId,
          'x-dartclaw-conversation-revision': '${admission.snapshot.revision}',
        },
      );
    } on ConversationMutationException catch (e) {
      return errorResponse(e.statusCode, e.code, e.message, {
        if (e.current != null) 'conversation_revision': e.current!.revision,
      });
    } catch (e) {
      _log.warning('Failed to send message for $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to send message');
    }
  });

  // GET /api/sessions/<id>/stream
  router.get('/api/sessions/<id>/stream', (Request request, String id) async {
    final turnId = request.url.queryParameters['turn'];
    if (turnId == null || turnId.isEmpty) {
      return errorResponse(404, 'TURN_NOT_FOUND', 'turn query parameter is required');
    }

    final isActive = turns.isActiveTurn(id, turnId);
    final outcome = turns.recentOutcome(id, turnId);

    if (!isActive && outcome == null) {
      return errorResponse(404, 'TURN_NOT_FOUND', 'Turn not found or expired');
    }

    return sseStreamResponse(worker, turns, id, turnId, redactor: redactor);
  });
}

Future<Response> _sendExistingSessionTurn({
  required String sessionId,
  required String message,
  required ({
    Map<String, dynamic>? metadata,
    Map<String, dynamic>? turnContextMetadata,
    String? metadataJson,
    Response? error,
  })
  richInput,
  required SessionService sessions,
  required MessageService messages,
  required TurnManager turns,
  required ConversationService conversation,
  required SessionMutationCoordinator sessionMutations,
}) async {
  final result = await sessionMutations.run(sessionId, () async {
    final current = await sessions.getSession(sessionId);
    final validation = _validateSessionForSend(current, turns.executions);
    if (validation != null) return (turnId: null, response: validation);
    final String turnId;
    try {
      turnId = await turns.reserveTurn(
        sessionId,
        isHumanInput: true,
        promptScope: PromptScope.primary,
        origin: (channel: ChannelType.web.name, contact: null, group: false),
      );
    } on BusyTurnException {
      return (
        turnId: null,
        response: errorResponse(409, 'AGENT_BUSY_PROVIDER', 'No idle ${current!.provider} workers available', {
          'provider': current.provider,
        }),
      );
    }
    try {
      final persisted = await messages.insertMessage(
        sessionId: sessionId,
        role: 'user',
        content: message,
        metadata: richInput.metadataJson,
      );
      final history = await conversation.messagesForTurn(sessionId, persisted.id);
      turns.executeTurn(sessionId, turnId, history, source: 'web');
      return (turnId: turnId, response: null);
    } catch (_) {
      turns.releaseTurn(sessionId, turnId);
      rethrow;
    }
  });
  if (result.response != null) return result.response!;
  final html = templateLoader.trellis.renderFragment(
    templateLoader.source('chat'),
    fragment: 'sendResponse',
    context: {
      'message': message,
      'richInputHtml': richInputHtmlFromMetadataMap(richInput.metadata),
      'sseUrl': '/api/sessions/$sessionId/stream?turn=${result.turnId}',
    },
  );
  return Response.ok(html, headers: {'content-type': 'text/html; charset=utf-8'});
}

String _stableId(String? value) {
  final trimmed = value?.trim();
  if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  return const Uuid().v4();
}

// ---------------------------------------------------------------------------
// Serialization helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _messageToJson(Message m) => {
  'id': m.id,
  'sessionId': m.sessionId,
  'role': m.role,
  'content': m.content,
  'cursor': m.cursor,
  'metadata': m.metadata != null ? _tryParseJson(m.metadata!) : null,
  'createdAt': m.createdAt.toIso8601String(),
};

dynamic _tryParseJson(String s) {
  try {
    return jsonDecode(s);
  } catch (e) {
    return s;
  }
}

// ---------------------------------------------------------------------------
// Rich-input parsing + resolution
// ---------------------------------------------------------------------------

Future<
  ({Map<String, dynamic>? metadata, Map<String, dynamic>? turnContextMetadata, String? metadataJson, Response? error})
>
_parseRichInput(
  Map<String, String> fields, {
  required String sessionId,
  required SessionService sessions,
  required ConversationService conversation,
  required ProjectService? projects,
}) async {
  final attachmentsField = fields['attachments'];
  if (attachmentsField != null && attachmentsField.length > _maxRichInputMetadataFieldChars) {
    return (
      metadata: null,
      turnContextMetadata: null,
      metadataJson: null,
      error: errorResponse(413, 'REQUEST_TOO_LARGE', 'attachments metadata is too large'),
    );
  }
  final referencesField = fields['references'];
  if (referencesField != null && referencesField.length > _maxRichInputMetadataFieldChars) {
    return (
      metadata: null,
      turnContextMetadata: null,
      metadataJson: null,
      error: errorResponse(413, 'REQUEST_TOO_LARGE', 'references metadata is too large'),
    );
  }

  final attachmentsResult = _parseJsonListField(fields['attachments'], field: 'attachments');
  if (attachmentsResult.error != null) {
    return (metadata: null, turnContextMetadata: null, metadataJson: null, error: attachmentsResult.error);
  }
  final referencesResult = _parseJsonListField(fields['references'], field: 'references');
  if (referencesResult.error != null) {
    return (metadata: null, turnContextMetadata: null, metadataJson: null, error: referencesResult.error);
  }

  final references = <Map<String, dynamic>>[];
  for (final item in referencesResult.items) {
    final state = item['state'] as String? ?? 'resolved';
    if (state != 'resolved') {
      return (
        metadata: null,
        turnContextMetadata: null,
        metadataJson: null,
        error: errorResponse(400, 'UNRESOLVED_REFERENCE', 'Unresolved references must be resolved or removed', {
          'field': 'references',
        }),
      );
    }
    final type = trimmedOrNull(item['type'] as String?);
    final id = trimmedOrNull(item['id'] as String?);
    if (type == null || id == null) {
      return (
        metadata: null,
        turnContextMetadata: null,
        metadataJson: null,
        error: errorResponse(400, 'INVALID_REFERENCE', 'reference type and id are required', {'field': 'references'}),
      );
    }
    final resolved = await _resolveReference(type: type, id: id, sessions: sessions, projects: projects);
    if (resolved.error != null) {
      return (metadata: null, turnContextMetadata: null, metadataJson: null, error: resolved.error);
    }
    references.add(resolved.reference!..['state'] = state);
  }

  final attachments = <Map<String, dynamic>>[];
  for (final item in attachmentsResult.items) {
    final id = trimmedOrNull(item['id'] as String?);
    final state = item['state'] as String? ?? 'ready';
    if (id == null || state != 'ready') {
      return (
        metadata: null,
        turnContextMetadata: null,
        metadataJson: null,
        error: errorResponse(400, 'INVALID_ATTACHMENT', 'ready attachment id is required', {'field': 'attachments'}),
      );
    }
    try {
      attachments.add(await conversation.resolveAttachment(sessionId, id));
    } on ConversationMutationException catch (error) {
      return (
        metadata: null,
        turnContextMetadata: null,
        metadataJson: null,
        error: errorResponse(error.statusCode, error.code, error.message),
      );
    }
  }

  if (attachments.isEmpty && references.isEmpty) {
    return (metadata: null, turnContextMetadata: null, metadataJson: null, error: null);
  }
  final turnContextMetadata = <String, dynamic>{
    'richInput': true,
    'attachments': attachments,
    'references': references,
  };
  final metadata = _metadataWithoutAttachmentContent(turnContextMetadata);
  return (
    metadata: metadata,
    turnContextMetadata: turnContextMetadata,
    metadataJson: jsonEncode(metadata),
    error: null,
  );
}

Map<String, dynamic> _metadataWithoutAttachmentContent(Map<String, dynamic> metadata) {
  final copy = Map<String, dynamic>.from(metadata);
  final attachments = (metadata['attachments'] as List?)?.whereType<Map<String, dynamic>>().map((attachment) {
    final sanitized = Map<String, dynamic>.from(attachment)..remove('contentText');
    return sanitized;
  }).toList();
  if (attachments != null) copy['attachments'] = attachments;
  return copy;
}

Future<({Map<String, dynamic>? reference, Response? error})> _resolveReference({
  required String type,
  required String id,
  required SessionService sessions,
  required ProjectService? projects,
}) async {
  if (type == 'session') {
    final session = await sessions.getSession(id);
    if (session == null) {
      return (reference: null, error: errorResponse(400, 'UNKNOWN_REFERENCE', 'Reference could not be resolved'));
    }
    final label = displaySessionTitle(session.title, session.type, emptyTitle: session.id);
    return (reference: {'type': 'session', 'id': session.id, 'label': label}, error: null);
  }
  if (type == 'project') {
    final project = await projects?.get(id);
    if (project == null) {
      return (reference: null, error: errorResponse(400, 'UNKNOWN_REFERENCE', 'Reference could not be resolved'));
    }
    return (reference: {'type': 'project', 'id': project.id, 'label': project.name}, error: null);
  }
  if (type == 'file') {
    final normalized = p.normalize(id);
    if (p.isAbsolute(normalized) || normalized.startsWith('..${p.separator}') || normalized == '..') {
      return (reference: null, error: errorResponse(400, 'UNKNOWN_REFERENCE', 'Reference could not be resolved'));
    }
    final root = await referenceRoot(projects);
    if (_hasHiddenPathSegment(normalized)) {
      return (reference: null, error: errorResponse(400, 'UNKNOWN_REFERENCE', 'Reference could not be resolved'));
    }
    final target = File(p.join(root, normalized));
    if (!await target.exists()) {
      return (reference: null, error: errorResponse(400, 'UNKNOWN_REFERENCE', 'Reference could not be resolved'));
    }
    return (reference: {'type': 'file', 'id': normalized, 'label': p.basename(normalized)}, error: null);
  }
  if (type == 'memory') {
    if (id != 'MEMORY.md') {
      return (reference: null, error: errorResponse(400, 'UNKNOWN_REFERENCE', 'Reference could not be resolved'));
    }
    return (reference: {'type': 'memory', 'id': id, 'label': id}, error: null);
  }
  if (type == 'tool') {
    const tools = {'memory_search', 'memory_read', 'kg_query', 'kg_timeline', 'workflow'};
    if (!tools.contains(id)) {
      return (reference: null, error: errorResponse(400, 'UNKNOWN_REFERENCE', 'Reference could not be resolved'));
    }
    return (reference: {'type': 'tool', 'id': id, 'label': id}, error: null);
  }
  return (reference: null, error: errorResponse(400, 'UNSUPPORTED_REFERENCE_TYPE', 'Reference type is not supported'));
}

bool _hasHiddenPathSegment(String path) =>
    p.split(path).any((segment) => segment.startsWith('.') && segment != '.' && segment != '..');

({List<Map<String, dynamic>> items, Response? error}) _parseJsonListField(String? value, {required String field}) {
  if (value == null || value.trim().isEmpty) {
    return (items: const [], error: null);
  }
  try {
    final decoded = jsonDecode(value);
    if (decoded is! List) {
      return (items: const [], error: errorResponse(400, 'INVALID_INPUT', '$field must be a JSON array'));
    }
    final items = <Map<String, dynamic>>[];
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) {
        return (items: const [], error: errorResponse(400, 'INVALID_INPUT', '$field entries must be objects'));
      }
      items.add(item);
    }
    return (items: items, error: null);
  } on FormatException {
    return (items: const [], error: errorResponse(400, 'INVALID_INPUT', '$field must be valid JSON'));
  }
}

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------

/// Returns an error [Response] if [message] is invalid, otherwise null.
Response? _validateMessage(String message, bool hasRichInput) {
  if (message.isEmpty && !hasRichInput) {
    return errorResponse(400, 'INVALID_INPUT', 'message must not be empty', {'field': 'message'});
  }
  if (message.length > 20000) {
    return errorResponse(400, 'INVALID_INPUT', 'message must not exceed 20000 characters', {'field': 'message'});
  }
  return null;
}

Response? _validateSessionProviderForSend(Session session, ExecutionCoordinator executions) {
  if (session.type != SessionType.logicalAgent && session.type != SessionType.cron) {
    return null;
  }
  final provider = session.provider;
  if (provider == null) {
    return errorResponse(409, 'PROVIDER_UNAVAILABLE', 'Worker session has no pinned provider');
  }
  if (executions.snapshot.providers.containsKey(provider)) {
    return null;
  }
  return errorResponse(409, 'PROVIDER_UNAVAILABLE', 'Provider "$provider" is not available for session overrides', {
    'provider': provider,
  });
}

Response? _validateSessionForSend(Session? session, ExecutionCoordinator executions) {
  if (session == null) {
    return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
  }
  if (session.type == SessionType.archive) {
    return errorResponse(403, 'FORBIDDEN', 'Cannot send to archived session');
  }
  if (session.type == SessionType.task) {
    return errorResponse(403, 'FORBIDDEN', 'Task sessions are managed via the task API');
  }
  return _validateSessionProviderForSend(session, executions);
}
