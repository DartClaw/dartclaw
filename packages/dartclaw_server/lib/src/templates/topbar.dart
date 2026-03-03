import 'package:dartclaw_core/dartclaw_core.dart';

import 'loader.dart';

/// Top navigation bar.
///
/// When [sessionId] is non-null, renders an editable `<input>` for the title
/// and action buttons. Behavior varies by [sessionType]:
/// - main/channel: reset button, no delete
/// - user: reset button (manual reset still allowed)
/// - archive: resume button, read-only
///
/// All dynamic values are auto-escaped by Trellis (`tl:text`, `tl:attr`).
String topbarTemplate({String? title, String? sessionId, SessionType? sessionType}) {
  final src = templateLoader.source('topbar');

  if (sessionId == null) {
    return templateLoader.trellis.renderFragment(src, fragment: 'plainTopbar', context: const {});
  }

  final displayTitle = (title == null || title.trim().isEmpty) ? 'New Session' : title;
  final isArchive = sessionType == SessionType.archive;

  return templateLoader.trellis.renderFragment(src, fragment: 'sessionTopbar', context: {
    'displayTitle': displayTitle,
    'sessionId': sessionId,
    'isArchive': isArchive,
    'showResume': isArchive,
    'showReset': !isArchive,
    'infoHref': '/sessions/$sessionId/info',
    'resetHref': '/api/sessions/$sessionId/reset',
  });
}

/// Topbar for standalone pages (settings, health dashboard, scheduling, session info).
///
/// Simpler than [topbarTemplate] — static title, optional back link, no session actions.
/// All dynamic values are auto-escaped by Trellis (`tl:text`, `tl:attr`).
String pageTopbarTemplate({
  required String title,
  String? backHref,
  String? backLabel,
}) {
  return templateLoader.trellis.renderFragment(
    templateLoader.source('topbar'),
    fragment: 'pageTopbar',
    context: {
      'title': title,
      'backHref': backHref,
      'backLabel': backLabel ?? 'Back',
    },
  );
}
