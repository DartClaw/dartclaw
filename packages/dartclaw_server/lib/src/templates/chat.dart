import 'dart:convert';

import 'components.dart';
import 'loader.dart';

// Patterns for special assistant messages stored by TurnManager.
final _guardBlockPattern = RegExp(r'^\[(?:Response )?[Bb]locked by guard: (.+)\]$', dotAll: true);
final _turnFailedPattern = RegExp(r'^\[Turn failed(?::\s*(.+))?\]$', dotAll: true);

/// Message type classification result.
enum MessageType { user, assistant, guardBlock, turnFailed }

/// Classified message with type and extracted detail (for guard-block / turn-failed).
typedef ClassifiedMessage = ({
  String id,
  String role,
  String content,
  MessageType messageType,
  String? detail,
  String? senderName,
  String? metadata,
});

/// Classifies a raw message into one of the four message types.
///
/// User messages are always [MessageType.user]. Assistant messages are checked
/// against guard-block and turn-failed patterns; unmatched ones are
/// [MessageType.assistant].
///
/// [senderName] is an optional display name for user messages — shown as a
/// prefix in the task detail chat view when present (e.g. "Alice: fix the
/// login bug"). Pass `null` for web/operator turns.
ClassifiedMessage classifyMessage({
  required String id,
  required String role,
  required String content,
  String? metadata,
  String? senderName,
}) {
  if (role == 'user') {
    return (
      id: id,
      role: role,
      content: content,
      messageType: MessageType.user,
      detail: null,
      senderName: senderName,
      metadata: metadata,
    );
  }

  final guardMatch = _guardBlockPattern.firstMatch(content);
  if (guardMatch != null) {
    return (
      id: id,
      role: role,
      content: content,
      messageType: MessageType.guardBlock,
      detail: guardMatch.group(1) ?? content,
      senderName: null,
      metadata: metadata,
    );
  }

  final failedMatch = _turnFailedPattern.firstMatch(content);
  if (failedMatch != null) {
    return (
      id: id,
      role: role,
      content: content,
      messageType: MessageType.turnFailed,
      detail: failedMatch.group(1),
      senderName: null,
      metadata: metadata,
    );
  }

  return (
    id: id,
    role: role,
    content: content,
    messageType: MessageType.assistant,
    detail: null,
    senderName: null,
    metadata: metadata,
  );
}

/// Renders a list of messages as HTML fragments.
/// Returns [emptyStateTemplate] when [messages] is empty.
///
/// Each message should already be classified via [classifyMessage].
String messagesHtmlFragment(List<ClassifiedMessage> messages) {
  if (messages.isEmpty) return emptyStateTemplate();

  final src = templateLoader.source('chat');
  final trellis = templateLoader.trellis;
  final buffer = StringBuffer();
  for (final m in messages) {
    switch (m.messageType) {
      case MessageType.user:
        buffer.write(
          trellis.renderFragment(
            src,
            fragment: 'userMessage',
            context: {
              'content': m.content,
              'senderName': m.senderName,
              'hasSenderName': m.senderName != null && m.senderName!.isNotEmpty,
              'richInputHtml': richInputHtmlFromMessageMetadata(m.metadata),
            },
          ),
        );
      case MessageType.assistant:
        buffer.write(trellis.renderFragment(src, fragment: 'assistantMessage', context: {'content': m.content}));
      case MessageType.guardBlock:
        buffer.write(trellis.renderFragment(src, fragment: 'guardBlock', context: {'detail': m.detail}));
      case MessageType.turnFailed:
        buffer.write(trellis.renderFragment(src, fragment: 'turnFailed', context: {'detail': m.detail}));
    }
  }
  return buffer.toString();
}

/// Renders durable rich input chips attached to a stored user message.
String? richInputHtmlFromMessageMetadata(String? metadata) {
  if (metadata == null || metadata.trim().isEmpty) return null;
  final decoded = _tryDecodeJson(metadata);
  if (decoded is! Map<String, dynamic>) return null;
  return richInputHtmlFromMetadataMap(decoded);
}

String? richInputHtmlFromMetadataMap(Map<String, dynamic>? metadata) {
  if (metadata == null) return null;
  final attachments = (metadata['attachments'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? const [];
  final references = (metadata['references'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? const [];
  if (attachments.isEmpty && references.isEmpty) return null;

  final buffer = StringBuffer('<div class="msg-rich-input" aria-label="Rich input context">');
  for (final attachment in attachments) {
    final filename = htmlEscape.convert((attachment['filename'] as String?) ?? 'attachment');
    final state = htmlEscape.convert((attachment['state'] as String?) ?? 'ready');
    buffer.write('<span class="composer-chip composer-chip-attachment">$filename <small>$state</small></span>');
  }
  for (final reference in references) {
    final type = htmlEscape.convert((reference['type'] as String?) ?? 'reference');
    final label = htmlEscape.convert((reference['label'] as String?) ?? (reference['id'] as String?) ?? 'reference');
    buffer.write('<span class="composer-chip composer-chip-reference">@$label <small>$type</small></span>');
  }
  buffer.write('</div>');
  return buffer.toString();
}

Object? _tryDecodeJson(String value) {
  try {
    return jsonDecode(value);
  } catch (_) {
    return null;
  }
}

/// Renders the full chat area, including the messages list and input form.
/// [bannerHtml] is optional pre-rendered banner HTML placed before the messages.
String chatAreaTemplate({
  required String sessionId,
  required String messagesHtml,
  bool isStreaming = false,
  bool hasTitle = false,
  String bannerHtml = '',
  bool readOnly = false,
  int? earliestCursor,
  bool hasEarlierMessages = false,
}) {
  final placeholder = isStreaming ? 'Agent is responding...' : 'Type a message...';
  final inputDisabled = isStreaming || readOnly;

  // Trellis auto-escapes attribute values set via tl:attr, so pass raw sessionId.
  return templateLoader.trellis.renderFragment(
    templateLoader.source('chat'),
    fragment: 'chatArea',
    context: {
      'sessionId': sessionId,
      'hasTitle': hasTitle ? 'true' : 'false',
      'earliestCursor': earliestCursor?.toString(),
      'loadEarlierHidden': hasEarlierMessages ? null : true,
      'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
      'messagesHtml': messagesHtml,
      'readOnly': readOnly,
      'sendUrl': '/api/sessions/$sessionId/send',
      'placeholder': placeholder,
      'inputDisabled': inputDisabled ? true : null,
    },
  );
}
