import 'helpers.dart';

/// Banner notification. [type] is one of `error`, `warning`, or `info`.
/// [message] is HTML-escaped.
String bannerTemplate(String type, String message) {
  final safeType = const {'error', 'warning', 'info'}.contains(type) ? type : 'error';
  return '''
<div class="banner banner-$safeType">
  <span>${htmlEscape(message)}</span>
  <button class="dismiss" aria-label="Dismiss">&#215;</button>
</div>
''';
}

/// Empty state shown when a session has no messages yet.
String emptyStateTemplate() => '''
<div class="empty-state">
  <div class="icon">&#10095;_</div>
  <p><strong>No messages yet</strong></p>
  <p>Send a message to start the conversation.</p>
</div>
''';

/// Empty app state shown when no sessions exist yet.
String emptyAppStateTemplate() => '''
<main class="chat-area">
  <div class="empty-state" style="flex: 1;">
    <div class="icon">&#10095;_</div>
    <p><strong>No sessions yet</strong></p>
    <p>Create a new session to start chatting with DartClaw.</p>
    <button class="btn btn-primary" data-action="create-session">+ New Session</button>
  </div>
</main>
''';
