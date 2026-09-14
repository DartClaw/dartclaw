import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../session/session_display_title.dart';
import '../concurrency/session_mutation_coordinator.dart';
import '../conversation/conversation_service.dart';
import 'api_helpers.dart';
import 'reference_suggestions.dart';
import 'session_routes_support.dart';

final _log = Logger('SessionAttachmentRoutes');
const _maxAttachmentBytes = 10 * 1024 * 1024;
const _maxAttachmentJsonBytes = 15 * 1024 * 1024;
typedef AttachmentWriteFailpoint = FutureOr<void> Function(String boundary, String attachmentId);

/// Registers session attachment-upload and reference-lookup endpoints.
///
/// Routes registered:
/// - `POST /api/sessions/<id>/attachments` — upload an attachment.
/// - `GET  /api/sessions/<id>/attachments/limits` — return the authoritative upload limits.
/// - `DELETE /api/sessions/<id>/attachments/<attachmentId>` — remove an unaccepted attachment.
/// - `GET  /api/sessions/<id>/references` — reference autocomplete suggestions.
void registerSessionAttachmentRoutes(
  Router router, {
  required SessionService sessions,
  required MessageService messages,
  required SessionMutationCoordinator sessionMutations,
  required ConversationService conversation,
  ProjectService? projectService,
  AttachmentWriteFailpoint? failpoint,
  String Function()? attachmentIdFactory,
}) {
  // POST /api/sessions/<id>/attachments
  router.post('/api/sessions/<id>/attachments', (Request request, String id) async {
    try {
      final session = await sessions.getSession(id);
      if (session == null) {
        return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
      }
      final parsed = await parseJsonObjectBody(request, maxBytes: _maxAttachmentJsonBytes);
      if (parsed.error != null) return parsed.error!;
      final metadata = _validateAttachmentPayload(parsed.json, attachmentIdFactory: attachmentIdFactory);
      if (metadata.error != null) return metadata.error!;

      final attachment = metadata.attachment!;
      final attachmentDir = Directory(p.join(messages.baseDir, id, 'attachments'));
      await attachmentDir.create(recursive: true);
      final bytes = metadata.bytes!;
      attachment['digest'] = 'sha256:${sha256.convert(bytes)}';
      attachment['owner'] = 'draft';
      final contentFile = File(p.join(attachmentDir.path, '${attachment['id']}.data'));
      await atomicWriteBytes(contentFile, bytes);
      await failpoint?.call('attachment_data', attachment['id'] as String);
      final file = File(p.join(attachmentDir.path, '${attachment['id']}.json'));
      await atomicWriteJson(file, attachment);
      await failpoint?.call('attachment_metadata', attachment['id'] as String);
      return jsonResponse(201, attachment);
    } catch (e) {
      _log.warning('Failed to add attachment for $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to add attachment');
    }
  });

  router.get('/api/sessions/<id>/attachments/limits', (Request request, String id) async {
    if (await sessions.getSession(id) == null) {
      return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
    }
    return jsonResponse(200, {'max_attachment_bytes': _maxAttachmentBytes});
  });

  router.delete('/api/sessions/<id>/attachments/<attachmentId>', (
    Request request,
    String id,
    String attachmentId,
  ) async {
    try {
      return await sessionMutations.run(id, () async {
        if (await sessions.getSession(id) == null) {
          return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
        }
        final state = await sessions.getConversationState(id);
        final claimed = state.submissions.any(
          (submission) => submission.attachments.any((attachment) => attachment.id == attachmentId),
        );
        if (claimed) {
          return errorResponse(409, 'ATTACHMENT_ACCEPTED', 'Accepted attachment cannot be removed from a draft');
        }
        final directory = p.join(messages.baseDir, id, 'attachments');
        final metadata = File(p.join(directory, '$attachmentId.json'));
        final data = File(p.join(directory, '$attachmentId.data'));
        if (!metadata.existsSync() && !data.existsSync()) {
          return errorResponse(404, 'ATTACHMENT_NOT_FOUND', 'Attachment not found');
        }
        if (metadata.existsSync()) await metadata.delete();
        if (data.existsSync()) await data.delete();
        return jsonResponse(200, {'status': 'removed', 'id': attachmentId});
      });
    } catch (e) {
      _log.warning('Failed to remove attachment $attachmentId for $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to remove attachment');
    }
  });

  // GET /api/sessions/<id>/references
  router.get('/api/sessions/<id>/references', (Request request, String id) async {
    try {
      final session = await sessions.getSession(id);
      if (session == null) {
        return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
      }
      final query = request.url.queryParameters['q']?.trim() ?? '';
      final context = await conversation.snapshot(id);
      final references = await _referenceSuggestions(
        sessions,
        projectService,
        query,
        referenceRoot: context.nextContext?.referenceRoot,
      );
      return jsonResponse(200, {'references': references});
    } catch (e) {
      _log.warning('Failed to lookup references for $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to lookup references');
    }
  });
}

({Map<String, dynamic>? attachment, List<int>? bytes, Response? error}) _validateAttachmentPayload(
  Map<String, dynamic> json, {
  String Function()? attachmentIdFactory,
}) {
  final filename = trimmedOrNull(json['filename'] as String?);
  final mediaType = trimmedOrNull(json['mediaType'] as String?);
  final size = json['size'];
  final contentBase64 = trimmedOrNull(json['contentBase64'] as String?);
  if (filename == null || mediaType == null || size is! int || contentBase64 == null) {
    return (
      attachment: null,
      bytes: null,
      error: errorResponse(400, 'INVALID_ATTACHMENT', 'filename, mediaType, size, and contentBase64 are required'),
    );
  }
  if (size <= 0) {
    return (
      attachment: null,
      bytes: null,
      error: errorResponse(400, 'INVALID_ATTACHMENT', 'attachment must not be empty'),
    );
  }
  if (size > _maxAttachmentBytes) {
    return (
      attachment: null,
      bytes: null,
      error: errorResponse(413, 'ATTACHMENT_TOO_LARGE', 'attachment must not exceed 10 MiB'),
    );
  }
  final bytes = _decodeAttachmentBytes(contentBase64);
  if (bytes == null || bytes.length != size) {
    return (
      attachment: null,
      bytes: null,
      error: errorResponse(400, 'INVALID_ATTACHMENT', 'attachment content does not match declared size'),
    );
  }
  final now = DateTime.now().toUtc().toIso8601String();
  return (
    attachment: {
      'id': attachmentIdFactory?.call() ?? const Uuid().v4(),
      'filename': filename,
      'mediaType': mediaType,
      'size': size,
      'state': 'ready',
      'createdAt': now,
    },
    bytes: bytes,
    error: null,
  );
}

List<int>? _decodeAttachmentBytes(String value) {
  try {
    return base64Decode(value);
  } on FormatException {
    return null;
  }
}

Future<List<Map<String, dynamic>>> _referenceSuggestions(
  SessionService sessions,
  ProjectService? projectService,
  String query, {
  String? referenceRoot,
}) async {
  final normalizedQuery = query.toLowerCase();
  bool matches(String value) => normalizedQuery.isEmpty || value.toLowerCase().contains(normalizedQuery);

  final references = <Map<String, dynamic>>[];
  final sessionList = await sessions.listSessions();
  for (final session in sessionList.take(20)) {
    final label = displaySessionTitle(session.title, session.type, emptyTitle: session.id);
    if (matches(label) || matches(session.id)) {
      references.add({'type': 'session', 'id': session.id, 'label': label});
    }
  }

  final projects = projectService == null ? const <Project>[] : await projectService.getAll();
  for (final project in projects.take(20)) {
    if (matches(project.name) || matches(project.id)) {
      references.add({'type': 'project', 'id': project.id, 'label': project.name});
    }
  }

  final root = Directory(referenceRoot ?? await sessionReferenceRoot(projectService));
  if (await root.exists()) {
    references.addAll(await collectFileReferenceSuggestions(root, normalizedQuery));
  }

  for (final tool in const ['memory_search', 'memory_read', 'kg_query', 'kg_timeline', 'workflow']) {
    if (matches(tool)) {
      references.add({'type': 'tool', 'id': tool, 'label': tool});
    }
  }

  if (matches('MEMORY.md')) {
    references.add({'type': 'memory', 'id': 'MEMORY.md', 'label': 'MEMORY.md'});
  }

  return references;
}
