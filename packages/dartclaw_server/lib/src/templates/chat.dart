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
  String? senderName,
}) {
  if (role == 'user') {
    return (id: id, role: role, content: content, messageType: MessageType.user, detail: null, senderName: senderName);
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
    );
  }

  return (id: id, role: role, content: content, messageType: MessageType.assistant, detail: null, senderName: null);
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
