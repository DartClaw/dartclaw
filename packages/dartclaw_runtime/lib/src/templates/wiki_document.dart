import '../knowledge/wiki_source_read.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'source_view.dart';
import 'topbar.dart';

/// Renders one wiki markdown document inside the app shell.
///
/// The page's markdown is escaped into a `data-markdown` container and rendered
/// client-side by the shared marked + DOMPurify pipeline, so the raw source
/// never reaches the page as markup. Its frontmatter shows only as the quiet
/// metadata line the standalone source page carries too.
String wikiDocumentTemplate({
  required WikiSourcePage page,
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  String restartBannerHtml = '',
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final topbar = pageTopbarTemplate(
    title: page.title,
    backHref: '/knowledge',
    backLabel: 'Knowledge',
    restartBannerHtml: restartBannerHtml,
  );
  final context = <String, dynamic>{
    'sidebar': sidebar,
    'topbar': topbar,
    'metaHtml': sourceMetadataHtml(page.metadata),
    'markdown': page.markdown,
  };

  final body = templateLoader.trellis.render(templateLoader.source('wiki_document'), context);
  return layoutTemplate(title: page.title, body: body, appName: appName, scripts: standardShellScripts());
}
