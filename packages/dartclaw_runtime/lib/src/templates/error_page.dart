import 'layout.dart';
import 'loader.dart';

/// Renders a full styled error page with design tokens.
///
/// Supply pre-rendered [sidebarHtml] and [topbarHtml] to land the error inside
/// the app shell with navigation intact. When either is null the page falls
/// back to the bare centred layout: the error paths that cannot reach shell
/// data must still render rather than throw from inside an error handler.
///
/// The skip link follows the same branch — the bare body has no `#main-content`
/// for it to point at.
String errorPageTemplate(
  int code,
  String title,
  String detail, {
  String appName = 'DartClaw',
  String? sidebarHtml,
  String? topbarHtml,
}) {
  final errorHtml = templateLoader.trellis.render(templateLoader.source('error_page'), {
    'code': code,
    'title': title,
    'detail': detail,
  });
  final shellWrapped = sidebarHtml != null && topbarHtml != null;
  final body = shellWrapped
      ? '<div class="shell" hx-history-elt>$sidebarHtml<div class="shell-main">$topbarHtml'
            '<main id="main-content" tabindex="-1" class="page-content">$errorHtml</main>'
            '</div></div>'
      : errorHtml;
  return layoutTemplate(
    title: '$code $title',
    body: body,
    appName: appName,
    scripts: shellWrapped ? standardShellScripts() : const [],
    showSkipLink: shellWrapped,
  );
}
