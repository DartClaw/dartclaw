import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/request_auth_context.dart';
import '../conversation/conversation_service.dart';
import 'api_helpers.dart';
import 'session_attachment_routes.dart';

void registerSessionExportRoutes(
  Router router, {
  required SessionService sessions,
  required ConversationService conversation,
  required ProcessAttachmentOwner processAttachments,
}) {
  router.get('/api/sessions/<id>/export', (Request request, String id) async {
    if (!requestHasAdminAccess(request)) return errorResponse(403, 'FORBIDDEN', 'Admin access required');
    final session = await sessions.getSession(id);
    if (session == null) return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
    return jsonResponse(200, {
      'confirmation_required': true,
      'format': 'markdown',
      'durable_copy': true,
      'includes': [
        'visible redacted messages',
        'timestamps',
        'roles',
        'tool details',
        'branch lineage',
        'attachment manifest',
      ],
      'excludes': ['attachment bytes', 'hidden history', 'provider state'],
    });
  });

  router.post('/api/sessions/<id>/export', (Request request, String id) async {
    if (!requestHasAdminAccess(request)) return errorResponse(403, 'FORBIDDEN', 'Admin access required');
    final body = await readJsonObject(request);
    if (body.error != null) return body.error!;
    if (body.value!['confirmed'] != true || body.value!['durableCopyAccepted'] != true) {
      return errorResponse(400, 'CONFIRMATION_REQUIRED', 'Confirm creation of a durable Markdown copy');
    }
    final session = await sessions.getSession(id);
    if (session == null) return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
    final prepared = await conversation.preparedExport(
      id,
      attachmentAvailability: (attachment) {
        final available = session.retention == ConversationRetention.process
            ? processAttachments.contains(id, attachment.id)
            : File(p.join(conversation.messages.baseDir, id, 'attachments', '${attachment.id}.data')).existsSync();
        return {
          'available': available,
          'reason': available ? 'available at export time' : 'attachment content is no longer available',
        };
      },
    );
    final output = StringBuffer()
      ..writeln('# Conversation export')
      ..writeln()
      ..writeln('- Session: `${_escapeCode(session.id)}`')
      ..writeln('- Created: ${session.createdAt.toUtc().toIso8601String()}')
      ..writeln('- Retention at export: ${session.retention.name}')
      ..writeln('- This downloaded file is a durable copy.')
      ..writeln();
    for (final value in prepared['messages']! as List) {
      final message = value as Map<String, Object?>;
      final content = '${message['content']}';
      final fence = _messageFence(content);
      output
        ..writeln('## ${_escapeInline('${message['role']}')} · ${_escapeInline('${message['createdAt']}')}')
        ..writeln()
        ..writeln(fence)
        ..write(content);
      if (!content.endsWith('\n')) output.writeln();
      output
        ..writeln(fence)
        ..writeln();
    }
    final records = prepared['records']! as List;
    if (records.isNotEmpty) {
      output
        ..writeln('## Visible tool and approval details')
        ..writeln();
      for (final value in records) {
        final record = value as Map<String, Object?>;
        output.writeln(
          '- `${_escapeCode('${record['kind']}')}`: ${_escapeInline('${record['summary'] ?? record['status'] ?? ''}')}',
        );
      }
      output.writeln();
    }
    final branches = prepared['branches']! as List;
    output
      ..writeln('## Branch lineage')
      ..writeln();
    if (branches.isEmpty) {
      output.writeln('- None');
    } else {
      for (final value in branches) {
        final branch = value as Map<String, Object?>;
        output.writeln(
          '- ${_escapeInline('${branch['kind']}')} from `${_escapeCode('${branch['sourceSessionId']}')}` to `${_escapeCode('${branch['destinationSessionId']}')}`',
        );
      }
    }
    output
      ..writeln()
      ..writeln('## Attachment manifest')
      ..writeln()
      ..writeln('Attachment bytes are not included.');
    final attachments = prepared['attachments']! as List;
    if (attachments.isEmpty) {
      output.writeln('- None');
    } else {
      for (final value in attachments) {
        final attachment = value as Map<String, Object?>;
        output.writeln(
          '- ${_escapeInline('${attachment['filename']}')} · ${_escapeInline('${attachment['mediaType']}')} · ${attachment['size']} bytes · ${attachment['available'] == true ? 'available' : 'unavailable'} (${_escapeInline('${attachment['reason']}')})',
        );
      }
    }
    return Response.ok(
      Stream<List<int>>.value(utf8.encode(output.toString())),
      headers: {
        'content-type': 'text/markdown; charset=utf-8',
        'content-disposition': 'attachment; filename="dartclaw-conversation-$id.md"',
        'cache-control': 'no-store',
      },
    );
  });
}

String _escapeInline(String value) =>
    value.replaceAll(r'\', r'\\').replaceAllMapped(RegExp(r'([`*_{}\[\]()#+.!|>-])'), (m) => '\\${m[0]}');
String _escapeCode(String value) => value.replaceAll('`', r'\`');

String _messageFence(String content) {
  var longest = 0;
  var current = 0;
  for (final codeUnit in content.codeUnits) {
    if (codeUnit == 0x7e) {
      current += 1;
      if (current > longest) longest = current;
    } else {
      current = 0;
    }
  }
  return List.filled(longest < 3 ? 3 : longest + 1, '~').join();
}
