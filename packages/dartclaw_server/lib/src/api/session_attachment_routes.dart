import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show Project;
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import 'api_helpers.dart';
import 'reference_suggestions.dart';
import 'session_routes_support.dart';

final _log = Logger('SessionAttachmentRoutes');
const _maxAttachmentBytes = 10 * 1024 * 1024;
const _maxAttachmentJsonBytes = 15 * 1024 * 1024;

/// Registers session attachment-upload and reference-lookup endpoints.
///
/// Routes registered:
/// - `POST /api/sessions/<id>/attachments` — upload an attachment.
/// - `GET  /api/sessions/<id>/references` — reference autocomplete suggestions.
void registerSessionAttachmentRoutes(
  Router router, {
  required SessionService sessions,
  required MessageService messages,
  ProjectService? projectService,
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
      final metadata = _validateAttachmentPayload(parsed.json);
      if (metadata.error != null) return metadata.error!;

      final attachment = metadata.attachment!;
      final attachmentDir = Directory(p.join(messages.baseDir, id, 'attachments'));
      await attachmentDir.create(recursive: true);
      final bytes = metadata.bytes!;
      final contentFile = File(p.join(attachmentDir.path, '${attachment['id']}.data'));
      await contentFile.writeAsBytes(bytes);
      final file = File(p.join(attachmentDir.path, '${attachment['id']}.json'));
      await file.writeAsString(jsonEncode(attachment));
      return jsonResponse(201, attachment);
    } catch (e) {
      _log.warning('Failed to add attachment for $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to add attachment');
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
      final references = await _referenceSuggestions(sessions, projectService, query);
      return jsonResponse(200, {'references': references});
    } catch (e) {
      _log.warning('Failed to lookup references for $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to lookup references');
    }
  });
}

({Map<String, dynamic>? attachment, List<int>? bytes, Response? error}) _validateAttachmentPayload(
  Map<String, dynamic> json,
) {
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
      'id': const Uuid().v4(),
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
  String query,
) async {
  final normalizedQuery = query.toLowerCase();
  bool matches(String value) => normalizedQuery.isEmpty || value.toLowerCase().contains(normalizedQuery);

  final references = <Map<String, dynamic>>[];
  final sessionList = await sessions.listSessions();
  for (final session in sessionList.take(20)) {
    final label = session.title?.trim().isNotEmpty ?? false ? session.title!.trim() : session.id;
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

  final root = Directory(await referenceRoot(projectService));
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
