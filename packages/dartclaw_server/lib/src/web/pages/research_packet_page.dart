import 'package:dartclaw_server/dartclaw_server.dart'
    show CitationPacket, CitationSourceIndexResolver, CitationSourceResolver;
import 'package:shelf/shelf.dart';

import '../../templates/source_attribution.dart';
import '../dashboard_page.dart';
import '../web_utils.dart';

/// Renders the read-only `context_research` packet view.
class ResearchPacketPage extends DashboardPage {
  ResearchPacketPage({CitationPacket Function()? packetGetter, CitationSourceResolver? resolver})
    : _packetGetter = packetGetter,
      _resolver = resolver ?? CitationSourceIndexResolver();

  final CitationPacket Function()? _packetGetter;
  final CitationSourceResolver _resolver;

  @override
  String get route => '/knowledge/research';

  @override
  String get title => 'Research';

  @override
  String? get icon => 'search';

  @override
  String get navGroup => 'system';

  @override
  Future<Response> handler(Request request, PageContext context) async {
    final sidebarData = await context.sidebar.build();
    final packet = _packetGetter?.call() ?? const CitationPacket(statements: [], sourceList: [], noSourcesFound: true);
    final page = await researchPacketTemplate(
      packet: packet,
      resolver: _resolver,
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      bannerHtml: context.restartBannerHtml(),
      appName: context.appDisplay.name,
    );

    return Response.ok(page, headers: htmlHeaders);
  }
}
