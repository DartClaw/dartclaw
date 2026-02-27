import 'components.dart';
import 'helpers.dart';

// Patterns for special assistant messages stored by TurnManager.
final _guardBlockPattern = RegExp(r'^\[(?:Response )?[Bb]locked by guard: (.+)\]$', dotAll: true);
final _turnFailedPattern = RegExp(r'^\[Turn failed(?::\s*(.+))?\]$', dotAll: true);

/// Renders a list of messages as HTML fragments.
/// Returns [emptyStateTemplate] when [messages] is empty.
String messagesHtmlFragment(List<({String id, String role, String content})> messages) {
  if (messages.isEmpty) return emptyStateTemplate();

  final buffer = StringBuffer();
  for (final m in messages) {
    if (m.role == 'user') {
      buffer.write(
        '<div class="msg msg-user">\n'
        '  <div class="msg-role">You</div>\n'
        '  <div class="msg-content"><p>${htmlEscape(m.content)}</p></div>\n'
        '</div>\n',
      );
    } else {
      final guardMatch = _guardBlockPattern.firstMatch(m.content);
      final failedMatch = _turnFailedPattern.firstMatch(m.content);
      if (guardMatch != null) {
        final reason = htmlEscape(guardMatch.group(1) ?? m.content);
        buffer.write(
          '<div class="msg msg-guard-block">\n'
          '  <div class="guard-block-header">\n'
          '    <span class="guard-block-icon"></span>\n'
          '    <span class="guard-block-label">GUARD BLOCKED</span>\n'
          '  </div>\n'
          '  <div class="guard-block-reason">$reason</div>\n'
          '</div>\n',
        );
      } else if (failedMatch != null) {
        final detail = failedMatch.group(1);
        final detailHtml = detail != null ? '<div class="msg-turn-failed-detail">${htmlEscape(detail)}</div>' : '';
        buffer.write(
          '<div class="msg msg-turn-failed">\n'
          '  <div class="msg-turn-failed-header">\n'
          '    <span class="msg-turn-failed-icon">&#9888;</span>\n'
          '    <span class="msg-turn-failed-label">Turn failed</span>\n'
          '  </div>\n'
          '  $detailHtml\n'
          '</div>\n',
        );
      } else {
        buffer.write(
          '<div class="msg msg-assistant">\n'
          '  <div class="msg-role">Assistant</div>\n'
          '  <div class="msg-content" data-markdown>${htmlEscape(m.content)}</div>\n'
          '</div>\n',
        );
      }
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
}) {
  final escapedId = htmlEscape(sessionId);
  final placeholder = isStreaming ? 'Agent is responding...' : 'Type a message...';
  final disabledAttr = (isStreaming || readOnly) ? ' disabled' : '';

  final inputArea = readOnly
      ? '<div class="input-area">'
          '<div class="archive-notice">'
          'This is an archived session. Resume it to continue the conversation.'
          '</div></div>'
      : '<div class="input-area">\n'
          '    <form id="chat-form"\n'
          '          hx-post="/api/sessions/$escapedId/send"\n'
          '          hx-target="#sse-container"\n'
          '          hx-swap="innerHTML">\n'
          '      <label class="sr-only" for="message-input">Message</label>\n'
          '      <textarea id="message-input"\n'
          '                name="message"\n'
          '                rows="1"\n'
          '                placeholder="$placeholder"$disabledAttr></textarea>\n'
          '      <button id="send-btn"\n'
          '              class="btn btn-primary btn-send"\n'
          '              type="submit"$disabledAttr>Send</button>\n'
          '    </form>\n'
          '  </div>';

  return '<main class="chat-area" data-session-id="$escapedId" data-has-title="${hasTitle ? 'true' : 'false'}">\n'
      '  $bannerHtml'
      '  <div class="messages" id="messages">\n'
      '    $messagesHtml'
      '  </div>\n'
      '  <div id="sse-container"></div>\n'
      '  $inputArea\n'
      '</main>\n';
}
