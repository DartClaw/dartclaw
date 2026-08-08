import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Renders one wiki markdown document inside the app shell.
///
/// [markdown] is escaped into a `data-markdown` container and rendered
/// client-side by the shared marked + DOMPurify pipeline, so the raw source
/// never reaches the page as markup.
String wikiDocumentTemplate({
  required String title,
  required String markdown,
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  String restartBannerHtml = '',
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final topbar = pageTopbarTemplate(
    title: title,
    backHref: '/knowledge',
    backLabel: 'Knowledge',
    restartBannerHtml: restartBannerHtml,
  );
  final context = <String, dynamic>{'sidebar': sidebar, 'topbar': topbar, 'markdown': markdown};

  final body = templateLoader.trellis.render(templateLoader.source('wiki_document'), context);
  return layoutTemplate(title: title, body: body, appName: appName, scripts: standardShellScripts());
}
