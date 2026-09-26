import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import '../session/session_display_title.dart';
import 'loader.dart';
import 'restart_banner.dart';

/// Top navigation bar.
///
/// When [sessionId] is non-null, renders the session title and action buttons.
/// Behavior varies by [sessionType]:
/// - main: fixed Agent workspace identity, reset button
/// - channel: editable title, reset button
/// - user: reset button (manual reset still allowed)
/// - archive: resume button, read-only
///
/// [restartBannerHtml] is pre-rendered restart-banner markup for the shell's
/// restart slot; see [_withRestartSlot].
///
/// All dynamic values are auto-escaped by Trellis (`tl:text`, `tl:attr`).
String topbarTemplate({
  String? title,
  String? sessionId,
  SessionType? sessionType,
  String appName = 'DartClaw',
  String restartBannerHtml = '',
  String? projectId,
  String? projectName,
  String? providerLabel,
  String? model,
}) {
  final src = templateLoader.source('topbar');

  if (sessionId == null) {
    return _withRestartSlot(
      templateLoader.trellis.renderFragment(src, fragment: 'plainTopbar', context: {'appName': appName}),
      restartBannerHtml,
    );
  }

  final displayTitle = displaySessionTitle(title, sessionType);
  final isWorkspace = sessionType == SessionType.main;
  final isArchive = sessionType == SessionType.archive;
  // The crumb renders once the conversation has a provider. A conversation with
  // no project says so in the same words the rail rows use rather than dropping
  // the segment, so the two surfaces never disagree about what is known.
  const noProjectLabel = 'General chat';
  final resolvedProject = (projectName ?? '').trim();
  final resolvedProvider = (providerLabel ?? '').trim();
  final resolvedModel = (model ?? '').trim();
  final hasCrumb = resolvedProvider.isNotEmpty;
  final crumbProject = resolvedProject.isEmpty ? noProjectLabel : resolvedProject;

  return _withRestartSlot(
    templateLoader.trellis.renderFragment(
      src,
      fragment: 'sessionTopbar',
      context: {
        'displayTitle': displayTitle,
        'sessionId': sessionId,
        'isWorkspace': isWorkspace,
        'isArchive': isArchive,
        'isEditable': !isWorkspace && !isArchive,
        'showResume': isArchive,
        'showReset': !isArchive,
        'infoHref': '/sessions/$sessionId/info',
        'hasCrumb': hasCrumb,
        'hasProject': projectId != null && projectId.isNotEmpty,
        'projectId': projectId ?? '',
        'projectName': crumbProject,
        'noProject': resolvedProject.isEmpty,
        // The crumb's identicon is 14px and the project name is right beside it;
        // the shared two-letter form is for surfaces that carry no label.
        'projectInitial': resolvedProject.isEmpty ? '·' : resolvedProject.substring(0, 1),
        'providerLabel': resolvedProvider,
        'hasModel': resolvedModel.isNotEmpty,
        'model': resolvedModel,
      },
    ),
    restartBannerHtml,
  );
}

/// Topbar for standalone pages (settings, health dashboard, scheduling, session info).
///
/// Simpler than [topbarTemplate] — static title, optional back link, no session actions.
/// A page with a parent renders [backHref]/[backLabel] as a `.topbar-back` control
/// before the title.
///
/// All dynamic values are auto-escaped by Trellis (`tl:text`, `tl:attr`).
String pageTopbarTemplate({required String title, String? backHref, String? backLabel, String restartBannerHtml = ''}) {
  return _withRestartSlot(
    templateLoader.trellis.renderFragment(
      templateLoader.source('topbar'),
      fragment: 'pageTopbar',
      context: {'title': title, 'backHref': backHref, 'backLabel': backLabel ?? 'Back'},
    ),
    restartBannerHtml,
  );
}

/// Appends the shell's restart slot after a rendered `#topbar` fragment.
///
/// The slot is always emitted and always holds exactly one `#restart-banner`
/// node — dormant (hidden, `inert`, empty field list) when [restartBannerHtml]
/// is empty. Client state reveals and re-hides that one node rather than
/// synthesizing markup, and every `hx-select-oob` that selects `#topbar` also
/// selects `#restart-banner-slot` so navigation replaces both siblings.
String _withRestartSlot(String topbarHtml, String restartBannerHtml) {
  final banner = restartBannerHtml.isNotEmpty ? restartBannerHtml : restartBannerTemplate(pendingFields: const []);
  return '$topbarHtml<div id="restart-banner-slot">$banner</div>';
}
