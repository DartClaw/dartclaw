import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show ChannelAttachment, MessageService;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show Message;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../conversation/turn_attachments.dart';

final _log = Logger('ChannelTurnAttachments');

/// Stages [attachments] into [sessionId]'s `attachments/` directory in the web composer's on-disk form.
///
/// Returns each staged file as a resolved attachment (with inlined text where the type allows it). A file that cannot
/// be staged is logged and skipped: the turn still runs on the message text.
Future<List<Map<String, dynamic>>> stageChannelAttachments(
  MessageService messages,
  String sessionId,
  List<ChannelAttachment> attachments,
) async {
  if (attachments.isEmpty) return const [];
  final directory = p.join(messages.baseDir, sessionId, 'attachments');
  final staged = <Map<String, dynamic>>[];
  for (final attachment in attachments) {
    final id = const Uuid().v4();
    try {
      await writeStagedAttachment(
        directory,
        stagedAttachmentMetadata(
          id: id,
          filename: attachment.filename,
          mediaType: attachment.mediaType,
          bytes: attachment.bytes,
          owner: 'accepted',
        ),
        attachment.bytes,
      );
      staged.add({...await readStagedAttachment(directory, id), 'state': 'accepted'});
    } catch (error) {
      _log.warning('Could not stage a channel attachment for session $sessionId (${error.runtimeType})');
    }
  }
  return staged;
}

/// The persisted metadata of a channel user message: the sender's display name and the [staged] manifest, never the
/// attachments' content.
String? channelMessageMetadata(String? senderDisplayName, List<Map<String, dynamic>> staged) {
  final metadata = <String, dynamic>{
    'senderDisplayName': ?senderDisplayName,
    if (staged.isNotEmpty) ...{'richInput': true, 'attachments': staged},
  };
  return metadata.isEmpty ? null : jsonEncode(metadataWithoutAttachmentContent(metadata));
}

/// The turn entries for [history]: role and content, each message's attachments named in a context block, and the
/// active message ([activeId], with its [staged] files) carrying their text and its eligible images.
Future<List<Map<String, dynamic>>> channelTurnEntries(
  MessageService messages,
  String sessionId,
  List<Message> history, {
  required String activeId,
  required List<Map<String, dynamic>> staged,
}) async {
  final directory = p.join(messages.baseDir, sessionId, 'attachments');
  final entries = <Map<String, dynamic>>[];
  for (final message in history) {
    var content = message.content;
    var images = const <Map<String, dynamic>>[];
    final metadata = message.role == 'user' ? _decodeMetadata(message.metadata) : null;
    if (metadata != null && metadata['attachments'] is List) {
      if (message.id == activeId) {
        metadata['attachments'] = staged;
        images = await turnImages(directory, staged);
      }
      content = withRichInputContext(content, metadata);
    }
    entries.add({'role': message.role, 'content': content, if (images.isNotEmpty) 'images': images});
  }
  return entries;
}

Map<String, dynamic>? _decodeMetadata(String? json) {
  if (json == null) return null;
  try {
    final decoded = jsonDecode(json);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}
