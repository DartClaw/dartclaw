import 'package:dartclaw_core/dartclaw_core.dart';

import 'helpers.dart';

/// Top navigation bar.
///
/// When [sessionId] is non-null, renders an editable `<input>` for the title
/// and action buttons. Behavior varies by [sessionType]:
/// - main/channel: reset button, no delete
/// - user: reset button (manual reset still allowed)
/// - archive: resume button, read-only
String topbarTemplate({String? title, String? sessionId, SessionType? sessionType}) {
  final displayTitle = (title == null || title.trim().isEmpty) ? 'New Session' : htmlEscape(title);

  final String titleElement;
  final String resetButton;
  final String infoButton;
  final String resumeButton;

  if (sessionId != null) {
    final escapedId = htmlEscape(sessionId);
    final isArchive = sessionType == SessionType.archive;

    titleElement = isArchive
        ? '<span class="session-title">$displayTitle</span>'
        : '<input id="session-title" class="session-title" type="text"'
            ' value="$displayTitle"'
            ' maxlength="100"'
            ' data-session-id="$escapedId"'
            ' data-original-title="$displayTitle"'
            ' aria-label="Session title">';

    resetButton = isArchive
        ? ''
        : '<button class="btn btn-ghost btn-sm btn-reset" '
            'hx-post="/api/sessions/$escapedId/reset" '
            'hx-confirm="Reset this session? Conversation will be archived." '
            'hx-on::after-request="location.reload()" '
            'aria-label="Reset session">Reset</button>';

    infoButton =
        '<a href="/sessions/$escapedId/info" class="btn btn-icon btn-ghost" aria-label="Session info">&#9432;</a>';

    resumeButton = isArchive
        ? '<button class="btn btn-ghost btn-sm" data-action="resume-archive" '
            'data-session-id="$escapedId">Resume</button>'
        : '';
  } else {
    titleElement = '<span class="session-title">DartClaw</span>';
    resetButton = '';
    infoButton = '';
    resumeButton = '';
  }

  return '''
<header class="topbar">
  <button class="btn btn-icon btn-ghost menu-toggle" aria-label="Open sidebar">&#9776;</button>
  $titleElement
  <div class="topbar-actions">
    $infoButton
    $resumeButton
    $resetButton
    <button class="theme-toggle" aria-label="Toggle theme"></button>
  </div>
</header>
''';
}
